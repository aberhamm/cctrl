#!/usr/bin/env python3
"""Local native Claude/Codex bridge. SQLite owns correlation and receipts.

Each actor has a real daemon process and native Claude callback endpoint. CLI
clients never send on that socket themselves. No history writers are acquired.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
import queue
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import uuid

from peer_identity import environment_identity, claude_ancestor_identity, session_value

LIMIT = 1024 * 1024
RECEIPT_PREFIX = "[cctrl-bridge receipt "
# Statuses meaning the native provider owns delivery (or may yet deliver): the
# message must never also be actionable in the default inbox.
# `steered` means the provider accepted the text into the recipient's running turn
# (not that the recipient handled it).
NATIVE_OWNED = ("persisted", "submitting", "submitted", "queued", "held", "released", "ambiguous", "steered")
# Policy outcomes that are not authorized work either.
# `lost`: an accepted steer that never appeared in the turn history. It is surfaced
# to the sender and never requeued automatically.
NOT_WORK = ("refused", "denied", "expired", "dropped", "lost")
VIEWS = ("actionable", "stranded", "history")

# Daemon protocol. A daemon outlives the CLI that started it, so after an upgrade
# the CLI may face a daemon from an older release. Daemons that predate this
# check wrote no protocol record (treated as protocol 1: no native-queue
# retirement, no sender envelope). Bump DAEMON_PROTOCOL when a CLI-visible daemon
# behavior is added; MIN_DAEMON_PROTOCOL is what the CLI needs to act safely.
DAEMON_PROTOCOL = 4
MIN_DAEMON_PROTOCOL = 2
DAEMON_CAPABILITIES = ("native_retirement", "reply_acks_original", "sender_envelope", "admission_gate", "retire_handled", "steer")
MIGRATION_DOC = "docs/bridge-daemon-migration.md"
# An outdated daemon allows only stop, list, status and inbox. Every action that
# goes through the daemon (send, ack, reply) is refused: ack/reply would drop the
# retirement/handled original, send would lose the sender envelope (no Sender line).
REQUIRED_CAPABILITIES = {
    "send": ("sender_envelope",),
    "ack": ("native_retirement",),
    "retire": ("native_retirement", "retire_handled"),
    "reply": ("native_retirement", "reply_acks_original", "sender_envelope"),
    "send_steer": ("steer",),
}
# `retire` (the sweep) and `send_steer` (a `--steer` send) are optional actions: a
# daemon lacking them is not "outdated" for send/ack/reply.
OPTIONAL_ACTIONS = ("retire", "send_steer")
ALL_REQUIRED = tuple(dict.fromkeys(c for a, caps in REQUIRED_CAPABILITIES.items() if a not in OPTIONAL_ACTIONS for c in caps))
OPTIONAL_REFUSAL = {"retire": "nothing was retired", "send_steer": "nothing was sent"}

# Steer admission (D4-D6). A steer is only attempted for a fresh row, for an opted-in
# recipient, and at most once per sender/recipient pair per window.
STEER_MAX_AGE = 60.0
STEER_RATE_WINDOW = 120.0
CONFIRM_WINDOW = 600.0
DELIVERIES = ("queue", "steer")
STEER_REASONS = {
    "declined": "recipient has not opted in to steering (or this sender is not on its allow list); queued instead",
    "stale": "the message was not dispatched within 60 seconds of being written; queued instead",
    "rate_limited": "at most one steer per sender and recipient every 2 minutes; queued instead",
}

# Exit code of `bridge retire` when the run finished but some rows errored (1 stays "refused / failed").
RETIRE_PARTIAL_EXIT = 3


class DaemonOutdated(ValueError):
    code = "daemon-outdated"
BASIS = re.compile(r"^[A-Za-z0-9:_./-]{1,60}$")
ENVELOPE_BASES = {
    "display_name": {"claimed:--name", "claimed:CCTRL_SESSION_NAME", "provider-registry", "provider-reported:thread/read", "unknown"},
    "harness": {"claimed:--harness", "claimed:CCTRL_HARNESS", "unknown"},
    "reported_source": {"provider-registry", "provider-reported:thread/read", "unknown"},
    "host": {"observed:local-host", "unknown"},
}
DERIVED_BASES = {"provider-registry", "provider-reported:thread/read", "observed:local-host"}
NOT_ADMITTED = ("held",) + NOT_WORK
WITHHELD = "[NOT ADMITTED: body withheld. Native delivery has not admitted this message; it is not authorized work and cannot be ACKed or replied to from the ledger.]"
LATE_CODEX_MARKERS = {
    "already_consumed": "late-native-delivery-after-handled",
    "absent": "late-native-delivery-possible", "race": "late-native-delivery-possible",
    "unknown": "late-native-delivery-possible", "identity_mismatch": "late-native-delivery-possible",
    "unknown_identity": "late-native-delivery-possible",
}
RETIRED_FINAL = {"retired", "absent", "already_consumed", "unsupported", "not_applicable"}


class RouteRefused(ValueError):
    code = "mailbox-route-refused"


def routes_to_mailbox(who, target, urgent):
    """True for a non-urgent Codex-to-Claude send: it goes to the mailbox.

    Every other direction, and --urgent, keeps the native bridge path.
    """
    return who.startswith("codex:") and target.startswith("claude:") and not urgent


def cctrl_command():
    return str(Path(__file__).resolve().parent.parent / "cctrl")


def _run_cctrl(args, body=None):
    # Same environment as the caller, so the mailbox sender identity is the
    # caller's own. The body travels on stdin, never in argv.
    return subprocess.run([cctrl_command(), *args], input=body, capture_output=True, text=True, timeout=60)


class UnknownOutcome(RouteRefused):
    """The mailbox write may or may not have happened; the ledger row must stay routing."""


def backing_peer(session_id):
    """The one mailbox peer backed by this Claude session, or RouteRefused."""
    hint = "Resend with --urgent to use the native bridge (it raises an admission prompt on the recipient's screen)."
    try:
        proc = _run_cctrl(["peer", "by-session", "claude:" + session_id, "--json"])
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RouteRefused(f"cannot resolve a mailbox peer for claude:{session_id} ({exc.__class__.__name__}); nothing was sent. {hint}")
    try:
        value = json.loads(proc.stdout)
    except ValueError:
        value = None
    if proc.returncode != 0 or not isinstance(value, dict) or value.get("ok") is False or not value.get("peer"):
        reason = ((value or {}).get("error") or {}).get("message") if isinstance(value, dict) else None
        raise RouteRefused(f"no unambiguous mailbox peer backs claude:{session_id} ({reason or 'lookup failed'}); nothing was sent. {hint}")
    return value["peer"]


def mailbox_send(peer, body):
    """Write one mailbox item to `peer` (the plain `peer send`) and return its JSON."""
    try:
        proc = _run_cctrl(["peer", "send", peer, "--json", "--body-file", "-"], body)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise UnknownOutcome(f"mailbox send to {peer} did not complete ({exc.__class__.__name__}); it may or may not have been written. Check cctrl peer outbox before retrying.")
    try:
        value = json.loads(proc.stdout)
    except ValueError:
        value = None
    if proc.returncode != 0 or not isinstance(value, dict) or not value.get("id"):
        reason = ((value or {}).get("error") or {}).get("message") if isinstance(value, dict) else None
        raise RouteRefused(f"mailbox send to {peer} failed ({reason or 'exit ' + str(proc.returncode)}); nothing was delivered. Retry, or resend with --urgent to use the native bridge.")
    return value


def route_to_mailbox(store, who, recipient, body, mid=None):
    """Send a non-urgent Codex-to-Claude message to the Claude's backing mailbox peer.

    The ledger row (kind routed) is written before the mailbox write, so a retry
    with the same --id never writes a second mailbox item.
    """
    if isinstance(body, str) and body.startswith(RECEIPT_PREFIX):
        raise ValueError("receipt text is a control fact and cannot be sent as a message")
    provider, session = recipient.split(":", 1)
    if session.startswith("cctrl-bridge-"):
        raise ValueError("address the actual provider session, not a bridge registry identity")
    recipient = actor(provider, session)
    session = session_value(session)
    existing = None
    if mid:
        try:
            existing = store.get(mid, who)
        except ValueError:
            existing = None
    if existing is not None and existing.get("kind") != "routed":
        raise RouteRefused(f"message {mid} was already used for a native send; reuse of its id for a mailbox route is refused. Use a new id, or resend with --urgent.")
    if existing is not None and existing["status"] == "mailbox":
        peer = None  # replay of a completed route: return the record, no lookup
    else:
        peer = backing_peer(session)
    mid, fresh = store.create(who, recipient, body, message_id=mid, initial_status="routing", kind="routed")
    if not fresh:
        row = store.get(mid, who)
        if row["status"] == "failed":
            store.event(mid, "routing", {"retry": True})
        elif row["status"] != "mailbox":
            raise RouteRefused(f"message {mid} was routed but its mailbox write is unconfirmed (a timeout or crash left it in routing); check cctrl peer outbox for this id before resending. Or resend with --urgent under a new id.")
    if fresh or store.get(mid, who)["status"] == "routing":
        try:
            sent = mailbox_send(peer, body)
        except UnknownOutcome as exc:
            store.event(mid, "routing", {"routed": "mailbox", "peer": peer, "unknown_outcome": True, "reason": str(exc)})
            raise
        except RouteRefused as exc:
            store.event(mid, "failed", {"routed": "mailbox", "peer": peer, "reason": str(exc)})
            raise
        store.event(mid, "mailbox", {"routed": "mailbox", "peer": peer, "mailbox_id": sent["id"]})
    row = store.get(mid, who)
    detail = next((json.loads(e["detail"]) for e in reversed(row["events"]) if e["kind"] == "mailbox" and e["detail"]), {})
    return {**row, "routed": "mailbox", "mailbox_id": detail.get("mailbox_id"), "mailbox_peer": detail.get("peer") or peer,
            "note": "Sent to the recipient's mailbox, not the native bridge: no admission prompt. Its reply arrives in your mailbox (cctrl peer recv --all)."}


def actor(provider, session):
    if provider not in {"claude", "codex"}:
        raise ValueError("provider must be claude or codex")
    return provider + ":" + session_value(session)


def own_identity():
    value = environment_identity(os.environ)
    if value is None and os.environ.get("CLAUDECODE"):
        value = claude_ancestor_identity(Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))) / "sessions")
    if not value:
        raise ValueError("no actual provider session ID; set CODEX_THREAD_ID or CLAUDE_CODE_SESSION_ID to your own native session ID")
    return value


def own_actor():
    value = own_identity()
    return actor(value["provider"], value["session_id"])


def own_registry(who):
    """The provider's own live record for this exact Claude session, if any."""
    provider, session = who.split(":", 1)
    if provider == "codex":
        try:
            from bridge_codex import thread_facts
            facts = thread_facts(session)
        except Exception:
            return None
        return ({"name": facts.get("name"), "kind": facts.get("source"),
                 "basis": "provider-reported:thread/read"} if facts else None)
    if provider != "claude":
        return None
    try:
        from bridge_claude import discover_sessions
        found = [r for r in discover_sessions() if r.get("session_id") == session]
    except Exception:
        return None
    return found[0] if len(found) == 1 else None


def clean_text(value, limit=120):
    """One printable line: no control characters, bounded, never a header break."""
    if not isinstance(value, str):
        return None
    text = "".join(ch if ch.isprintable() else " " for ch in value)
    text = " ".join(text.split())[:limit]
    return text or None


def known(value, basis):
    value = clean_text(value)
    return {"value": value, "basis": basis if value else "unknown"}


def sender_envelope(who, identity_basis=None, env=None, registry=None, name_claim=None, harness_claim=None):
    """One snapshot of what is genuinely known about the sending session.

    Taken once, at the boundary that owns the session (the CLI/MCP client for an
    outbound send; the receiving daemon for native ingress), then persisted with
    the message. provider and session_id are routing facts. Every other field
    is {value, basis}: basis says where it came from, or "unknown". A
    provider-reported source (for example vscode) is never read as the harness,
    and nothing is inferred from cwd, title or labels. Only named variables are
    read; the environment is never copied.
    """
    env = os.environ if env is None else env
    provider, session = who.split(":", 1)
    name = known(name_claim, "claimed:--name")
    if not name["value"]:
        name = known(env.get("CCTRL_SESSION_NAME"), "claimed:CCTRL_SESSION_NAME")
    source = known(None, "unknown")
    if registry:
        # Exact provider-session match in the provider's own record only. A
        # provider-reported title outranks a caller claim; the reported source
        # (cli, vscode, ...) is the provider's origin, never the harness.
        basis = registry.get("basis") or "provider-registry"
        if clean_text(registry.get("name")) and registry.get("name") != registry.get("session_id"):
            name = known(registry.get("name"), basis)
        source = known(registry.get("kind"), basis)
    return {
        "v": 1, "provider": provider, "session_id": session,
        "identity_basis": clean_text(identity_basis) or "unknown",
        "display_name": name,
        "harness": (known(harness_claim, "claimed:--harness") if clean_text(harness_claim)
                    else known(env.get("CCTRL_HARNESS"), "claimed:CCTRL_HARNESS")),
        "reported_source": source,
        "host": known(socket.gethostname().split(".")[0], "observed:local-host"),
    }


def envelope_from_request(value, who):
    """Accept a client snapshot, but routing identity always comes from the actor."""
    provider, session = who.split(":", 1)
    if not isinstance(value, dict):
        return None
    out = {"v": 1, "provider": provider, "session_id": session,
           "identity_basis": clean_text(value.get("identity_basis")) or "unknown"}
    registry = None
    for key in ("display_name", "harness", "reported_source", "host"):
        item = value.get(key)
        item = item if isinstance(item, dict) else {}
        basis = clean_text(item.get("basis"), 60)
        text = clean_text(item.get("value"))
        if basis not in ENVELOPE_BASES[key]:
            basis = "claimed"
        elif text and basis in DERIVED_BASES:
            # Never trust a client-supplied provider-reported or observed
            # basis: the daemon re-derives the fact itself and demotes the
            # field to a plain claim unless it matches.
            if basis == "observed:local-host":
                expected = clean_text(socket.gethostname().split(".")[0])
            else:
                if registry is None:
                    registry = own_registry(who) or {}
                expected = clean_text(registry.get("kind" if key == "reported_source" else "name"))
                if registry.get("basis", "provider-registry") != basis:
                    expected = None
            if text != expected:
                basis = "claimed"
        out[key] = known(text, basis)
    return out


def start_identity(pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="],
                            env={**os.environ, "LC_ALL": "C", "TZ": "UTC"},
                            capture_output=True, text=True, timeout=2)
    return result.stdout.strip() if result.returncode == 0 else None


def private_dir(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink() or path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o077:
        raise ValueError(f"bridge directory must be owned by you with mode 0700: {path}")


class Store:
    def __init__(self, root):
        self.root = Path(root)
        private_dir(self.root)
        path = self.root / "ledger.sqlite3"
        if path.is_symlink():
            raise ValueError("bridge ledger is a symlink")
        with self.db() as db:
            db.executescript("""
            CREATE TABLE IF NOT EXISTS endpoints (
              actor TEXT PRIMARY KEY, pid INTEGER, started TEXT, socket TEXT,
              native_socket TEXT, name TEXT, cwd TEXT);
            CREATE TABLE IF NOT EXISTS messages (
              id TEXT PRIMARY KEY, sender TEXT NOT NULL, recipient TEXT NOT NULL,
              body TEXT NOT NULL, reply_to TEXT, created REAL NOT NULL,
              status TEXT NOT NULL, detail TEXT, received REAL, replied TEXT);
            CREATE TABLE IF NOT EXISTS events (
              seq INTEGER PRIMARY KEY, id TEXT NOT NULL, at REAL NOT NULL,
              kind TEXT NOT NULL, detail TEXT);
            CREATE TABLE IF NOT EXISTS receipt_attempts (
              original TEXT PRIMARY KEY, id TEXT NOT NULL, recipient TEXT NOT NULL,
              body TEXT NOT NULL, status TEXT NOT NULL, detail TEXT);
            CREATE TABLE IF NOT EXISTS endpoint_protocol (
              actor TEXT NOT NULL, pid INTEGER NOT NULL, started TEXT NOT NULL,
              protocol INTEGER NOT NULL, capabilities TEXT NOT NULL,
              PRIMARY KEY(actor,pid,started));
            CREATE TABLE IF NOT EXISTS ownership (
              actor TEXT NOT NULL,pid INTEGER NOT NULL,started TEXT NOT NULL,
              resources TEXT NOT NULL, PRIMARY KEY(actor,pid,started));
            CREATE TABLE IF NOT EXISTS endpoint_policy (
              actor TEXT PRIMARY KEY, steer TEXT NOT NULL DEFAULT 'off',
              steer_from TEXT, updated REAL);
            """)
            if "dispatcher" not in {r[1] for r in db.execute("PRAGMA table_info(messages)")}:
                db.execute("ALTER TABLE messages ADD COLUMN dispatcher TEXT")
                db.execute("UPDATE messages SET dispatcher=sender WHERE dispatcher IS NULL")
            columns = {r[1] for r in db.execute("PRAGMA table_info(messages)")}
            if "kind" not in columns:
                db.execute("ALTER TABLE messages ADD COLUMN kind TEXT NOT NULL DEFAULT 'message'")
            if "envelope" not in columns:
                db.execute("ALTER TABLE messages ADD COLUMN envelope TEXT")
            if "delivery" not in columns:
                # NULL is read as 'queue', so rows written before steering are untouched.
                db.execute("ALTER TABLE messages ADD COLUMN delivery TEXT")
        os.chmod(path, 0o600)

    @contextlib.contextmanager
    def db(self):
        db = sqlite3.connect(str(self.root / "ledger.sqlite3"), timeout=10)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def endpoint(self, who):
        with self.db() as db:
            row = db.execute("SELECT * FROM endpoints WHERE actor=?", (who,)).fetchone()
        if row and isinstance(row["pid"], int) and row["pid"] > 1 and row["started"] and start_identity(row["pid"]) == row["started"]:
            value = dict(row)
            # Kept in a side table: old daemons write the 7-column endpoints row
            # positionally, so that table's shape must not change. A missing
            # record means a daemon from before protocol versioning.
            with self.db() as db:
                info = db.execute("SELECT protocol,capabilities FROM endpoint_protocol WHERE actor=? AND pid=? AND started=?",
                                  (who, row["pid"], row["started"])).fetchone()
            value["protocol"], value["capabilities"] = 1, []
            if info:
                try:
                    value["protocol"], value["capabilities"] = int(info["protocol"]), list(json.loads(info["capabilities"]))
                except (TypeError, ValueError):
                    pass
            return value
        return None

    def endpoints(self):
        with self.db() as db:
            actors = [r[0] for r in db.execute("SELECT actor FROM endpoints")]
        return [row for who in actors if (row := self.endpoint(who))]

    def clean_exited(self, who):
        """Remove only persisted inode-owned leaves of an exited daemon.

        Never interpret arbitrary registry records as cleanup authority. Failed
        cleanup retains its manifest, preventing silent replacement/forgetting.
        """
        with self.db() as db:
            rows = [dict(r) for r in db.execute("SELECT * FROM ownership WHERE actor=?", (who,))]
        for row in rows:
            current = start_identity(row["pid"])
            if current == row["started"]:
                continue
            if current is None:
                try:
                    os.kill(row["pid"], 0)
                except ProcessLookupError:
                    pass
                else:
                    raise ValueError("cannot establish exited bridge process identity; cleanup deferred")
            unresolved = []
            for resource in json.loads(row["resources"]):
                path = Path(resource["path"])
                try:
                    info = path.lstat()
                    if (info.st_dev, info.st_ino) != (resource["device"], resource["inode"]):
                        raise ValueError(f"owned bridge resource changed identity: {path}")
                    path.unlink()
                except FileNotFoundError:
                    pass
                except (OSError, ValueError):
                    unresolved.append(resource)
            with self.db() as db:
                if unresolved:
                    db.execute("UPDATE ownership SET resources=? WHERE actor=? AND pid=? AND started=?", (json.dumps(unresolved), who, row["pid"], row["started"]))
                else:
                    db.execute("DELETE FROM ownership WHERE actor=? AND pid=? AND started=?", (who, row["pid"], row["started"]))
                    db.execute("DELETE FROM endpoints WHERE actor=? AND pid=? AND started=?", (who, row["pid"], row["started"]))
                    db.execute("DELETE FROM endpoint_protocol WHERE actor=? AND pid=? AND started=?", (who, row["pid"], row["started"]))
            if unresolved:
                raise ValueError("exited bridge cleanup failed; ownership manifest retained in ledger")

    def policy(self, who):
        """The actor's own steer opt-in. No row means off; an empty allow list means any sender."""
        with self.db() as db:
            row = db.execute("SELECT steer,steer_from FROM endpoint_policy WHERE actor=?", (who,)).fetchone()
        if not row or row["steer"] != "allow":
            return {"steer": "off", "steer_from": list(json.loads(row["steer_from"] or "[]")) if row else []}
        return {"steer": "allow", "steer_from": list(json.loads(row["steer_from"] or "[]"))}

    def set_policy(self, who, steer, steer_from=None):
        if steer not in {"allow", "off"}:
            raise ValueError("steer policy must be allow or off")
        senders = sorted({str(a) for a in (steer_from or [])})
        with self.db() as db:
            db.execute("INSERT OR REPLACE INTO endpoint_policy(actor,steer,steer_from,updated) VALUES (?,?,?,?)",
                       (who, steer, json.dumps(senders), time.time()))

    def steer_attempts(self, sender, recipient, since, exclude=None):
        """Steers this pair actually tried recently and that were not skipped (they spend the D6 budget)."""
        with self.db() as db:
            return db.execute(
                "SELECT COUNT(*) FROM messages m WHERE m.sender=? AND m.recipient=? AND m.delivery='steer' AND m.id IS NOT ? "
                "AND m.status IN ('steered','ambiguous','lost') "
                "AND EXISTS (SELECT 1 FROM events e WHERE e.id=m.id AND e.kind='steering' AND e.at>?) "
                "AND NOT EXISTS (SELECT 1 FROM events q WHERE q.id=m.id AND q.kind='queueing')",
                (sender, recipient, exclude, since)).fetchone()[0]

    def steer_only(self, mid):
        """True when a steer was attempted and nothing was ever queued for this row."""
        with self.db() as db:
            return bool(db.execute(
                "SELECT 1 FROM events e WHERE e.id=? AND e.kind='steering' AND NOT EXISTS "
                "(SELECT 1 FROM events q WHERE q.id=e.id AND q.kind='queueing')", (mid,)).fetchone())

    def steered_turn(self, mid):
        """Turn the provider accepted the steer into, from the steered event."""
        with self.db() as db:
            row = db.execute("SELECT detail FROM events WHERE id=? AND kind='steered' ORDER BY seq DESC", (mid,)).fetchone()
        try:
            value = json.loads(row[0] or "null") if row else None
        except ValueError:
            return None
        return value.get("turn_id") if isinstance(value, dict) and isinstance(value.get("turn_id"), str) else None

    def create(self, sender, recipient, body, reply_to=None, message_id=None, dispatcher=None, initial_status="persisted", envelope=None, kind="message", delivery="queue"):
        if initial_status not in {"persisted", "refused", "routing"} or kind not in {"message", "routed"} or delivery not in DELIVERIES:
            raise ValueError("invalid initial bridge status")
        if not isinstance(body, str) or not body or len(body.encode()) > LIMIT // 2:
            raise ValueError("body must be nonempty UTF-8 text of at most 512 KiB")
        mid = str(uuid.UUID(message_id)) if message_id else str(uuid.uuid4())
        # A receipt is a control fact, never work: it is born handled, is never
        # dispatched (status is not persisted) and never enters an inbox.
        receipt = body.startswith(RECEIPT_PREFIX)
        with self.db() as db:
            db.execute("BEGIN IMMEDIATE")
            old = db.execute("SELECT * FROM messages WHERE id=?", (mid,)).fetchone()
            if old:
                if (old["sender"], old["recipient"], old["body"], old["reply_to"], old["delivery"] or "queue") != (sender, recipient, body, reply_to, delivery):
                    raise ValueError("message ID already belongs to different content")
                return mid, False
            now = time.time()
            db.execute("INSERT INTO messages(id,sender,recipient,body,reply_to,created,status,dispatcher,kind,envelope,received,delivery) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                       (mid, sender, recipient, body, reply_to, now, "receipt" if receipt else initial_status, dispatcher or sender,
                        "receipt" if receipt else kind, json.dumps(envelope) if envelope else None, now if receipt else None, delivery))
            db.execute("INSERT INTO events(id,at,kind) VALUES (?,?,?)", (mid, now, "receipt" if receipt else initial_status))
        return mid, True

    def note(self, mid, kind, detail=None):
        """Append an audit event without touching the message status."""
        with self.db() as db:
            db.execute("INSERT INTO events(id,at,kind,detail) VALUES (?,?,?,?)", (mid, time.time(), kind, json.dumps(detail)))

    def queued_identity(self, mid):
        """Queue ID of the native submission this bridge itself persisted, if any."""
        with self.db() as db:
            rows = db.execute("SELECT detail FROM events WHERE id=? AND kind='queued' ORDER BY seq DESC", (mid,)).fetchall()
        for row in rows:
            try:
                value = json.loads(row[0] or "null")
            except ValueError:
                continue
            if isinstance(value, dict) and isinstance(value.get("queued_submission_id"), str) and value["queued_submission_id"]:
                return value["queued_submission_id"]
        return None

    def note_once(self, mid, kind, detail=None):
        """Append an audit event unless one of this kind already exists."""
        with self.db() as db:
            if db.execute("SELECT 1 FROM events WHERE id=? AND kind=?", (mid, kind)).fetchone():
                return
            db.execute("INSERT INTO events(id,at,kind,detail) VALUES (?,?,?,?)", (mid, time.time(), kind, json.dumps(detail)))

    def pending_retirements(self, who):
        """IDs of messages `who` handled whose native retirement is not final.

        The single query behind `bridge retire --handled`. Rows without a
        persisted queue identity are returned separately: they cannot be
        retired without guessing, so they are never sent to the daemon.
        """
        final = ",".join("?" for _ in RETIRED_FINAL)
        with self.db() as db:
            rows = db.execute(
                "SELECT m.id FROM messages m WHERE m.recipient=? AND m.kind='message' "
                "AND (m.received IS NOT NULL OR m.replied IS NOT NULL) AND m.status IN ('queued','ambiguous') "
                "AND NOT EXISTS (SELECT 1 FROM events e WHERE e.id=m.id AND e.kind='native-retire' "
                f"AND json_extract(e.detail,'$.outcome') IN ({final})) "
                # A steer attempt that never queued has no queue item to retire or to report.
                "AND NOT (EXISTS (SELECT 1 FROM events s WHERE s.id=m.id AND s.kind='steering') "
                "AND NOT EXISTS (SELECT 1 FROM events q WHERE q.id=m.id AND q.kind='queueing')) ORDER BY m.created",
                (who, *sorted(RETIRED_FINAL))).fetchall()
        identified, anonymous = [], []
        for (mid,) in rows:
            (identified if self.queued_identity(mid) else anonymous).append(mid)
        return identified, anonymous

    def retirement(self, mid):
        """Latest recorded native retirement outcome for a message, or None."""
        with self.db() as db:
            row = db.execute("SELECT detail FROM events WHERE id=? AND kind='native-retire' ORDER BY seq DESC", (mid,)).fetchone()
        return json.loads(row[0]) if row and row[0] else None

    def claim(self, mid, who):
        with self.db() as db:
            changed = db.execute("UPDATE messages SET status='submitting' WHERE id=? AND dispatcher=? AND status='persisted'", (mid, who)).rowcount
            if changed:
                db.execute("INSERT INTO events(id,at,kind) VALUES (?,?,?)", (mid, time.time(), "submitting"))
            return bool(changed)

    def event(self, mid, kind, detail=None):
        with self.db() as db:
            if not db.execute("SELECT 1 FROM messages WHERE id=?", (mid,)).fetchone():
                raise ValueError("unknown bridge message")
            db.execute("INSERT INTO events(id,at,kind,detail) VALUES (?,?,?,?)", (mid, time.time(), kind, json.dumps(detail)))
            # Policy callbacks may race with socket-send completion. Preserve
            # held/refused/released facts instead of overwriting with submitted.
            if not kind.startswith("receipt-") and kind not in {"received", "replied"}:
                current = db.execute("SELECT status FROM messages WHERE id=?", (mid,)).fetchone()[0]
                policy = {"held", "denied", "expired", "released", "refused", "dropped"}
                if not (kind in {"submitted", "queued", "failed", "ambiguous", "submitting", "steered"} and current in policy):
                    db.execute("UPDATE messages SET status=?,detail=? WHERE id=?", (kind, json.dumps(detail), mid))

    def get(self, mid, who):
        with self.db() as db:
            row = db.execute("SELECT * FROM messages WHERE id=?", (mid,)).fetchone()
            if not row or who not in {row["sender"], row["recipient"]}:
                raise ValueError("bridge message is not visible to this session")
            value = dict(row)
            value["events"] = [dict(r) for r in db.execute("SELECT * FROM events WHERE id=? ORDER BY seq", (mid,))]
            receipt = db.execute("SELECT * FROM receipt_attempts WHERE original=?", (mid,)).fetchone()
            value["receipt_attempt"] = dict(receipt) if receipt else None
            value["envelope"] = json.loads(value["envelope"]) if value.get("envelope") else None
            value["delivery"] = value.get("delivery") or "queue"
            value["steer"] = steer_summary(value) if value["delivery"] == "steer" else None
            value["handled"] = value["received"] is not None
            value["late_native_delivery"] = any(e["kind"] == "late-native-delivery-after-handled" for e in value["events"])
            value["late_native_delivery_possible"] = any(e["kind"] == "late-native-delivery-possible" for e in value["events"])
            return value

    def inbox(self, who, view="actionable", after=0, limit=20):
        """Read-only listing. Only 'actionable' is a handling surface.

        Native delivery owns every message it accepted, so those never appear
        as actionable; 'stranded' shows unhandled items that native delivery
        did not cleanly take (held, refused, ambiguous, never dispatched) and
        'history' shows everything this actor sent or received.
        """
        if view not in VIEWS:
            raise ValueError("view must be one of " + ", ".join(VIEWS))
        marks = lambda names: ",".join("?" * len(names))
        if view == "actionable":
            where, args = "recipient=? AND kind='message' AND received IS NULL AND status='failed'", [who]
        elif view == "stranded":
            names = ("held", "ambiguous", "submitting", "persisted") + NOT_WORK
            where, args = f"recipient=? AND kind='message' AND received IS NULL AND status IN ({marks(names)})", [who, *names]
        else:
            where, args = "(recipient=? OR sender=?)", [who, who]
        with self.db() as db:
            rows = [dict(r) for r in db.execute(
                f"SELECT rowid AS cursor,* FROM messages WHERE {where} AND rowid>? ORDER BY rowid LIMIT ?", (*args, after, limit + 1))]
        page = rows[:limit]
        for row in page:
            row["envelope"] = json.loads(row["envelope"]) if row.get("envelope") else None
            row["actionable"] = view == "actionable"
            if view == "stranded":
                row["admitted"] = "unknown" if row["status"] not in NOT_ADMITTED else False
                if row["status"] in NOT_ADMITTED:
                    row["body"] = WITHHELD
            row["queued_submission_id"] = self.queued_identity(row["id"])
        return {"actor": who, "view": view, "messages": page,
                "next_cursor": rows[limit - 1]["cursor"] if len(rows) > limit else None}

    def acknowledge(self, mid, who, reply=None):
        with self.db() as db:
            row = db.execute("SELECT * FROM messages WHERE id=?", (mid,)).fetchone()
            if not row or row["recipient"] != who:
                raise ValueError("only the actual recipient session may acknowledge or reply")
            if row["kind"] == "receipt":
                raise ValueError("a receipt is a control fact: it needs no ACK and cannot be replied to")
            first = row["received"] is None
            db.execute("UPDATE messages SET received=COALESCE(received,?),replied=COALESCE(?,replied) WHERE id=?", (time.time(), reply, mid))
            if first or reply:
                db.execute("INSERT INTO events(id,at,kind,detail) VALUES (?,?,?,?)", (mid, time.time(), "replied" if reply else "received", json.dumps({"actor": who, "reply": reply})))
            return dict(row), first


def envelope_line(envelope):
    """Always one Sender line. Values are JSON-quoted so a claimed value cannot
    close its own field and forge a basis or another field; bases are charset-limited."""
    if not envelope:
        return "Sender: unknown (no envelope recorded)\n"
    def show(key):
        item = envelope.get(key) or {}
        value, basis = item.get("value"), item.get("basis") or "unknown"
        if not isinstance(value, str) or not value:
            return "unknown"
        basis = basis if isinstance(basis, str) and BASIS.match(basis) else "claimed"
        return json.dumps(value, ensure_ascii=False) + f" ({basis})"
    return ("Sender: name=" + show("display_name") + "; provider=" + str(envelope.get("provider")) +
            "; session=" + str(envelope.get("session_id")) + "; harness=" + show("harness") +
            "; reported_source=" + show("reported_source") + "; host=" + show("host") + "\n")


def steer_summary(row):
    """What happened to a steer request, from the row's own events: the sender's answer."""
    outcome, reason = None, None
    for event in row["events"]:
        try:
            detail = json.loads(event["detail"] or "null")
        except ValueError:
            detail = None
        detail = detail if isinstance(detail, dict) else {}
        if event["kind"] == "steer-skipped":
            outcome, reason = detail.get("outcome"), detail.get("reason")
        elif event["kind"] == "steered":
            outcome, reason = "steered", None
        elif event["kind"] == "lost":
            outcome, reason = "lost", detail.get("reason")
        elif event["kind"] == "ambiguous" and outcome is None:
            outcome, reason = "ambiguous", detail.get("reason")
    if row["status"] == "ambiguous" and outcome is None:
        outcome = "ambiguous"
    return {"requested": True, "outcome": outcome or "pending", "reason": reason}


STEER_NOTE = ("steering reaches only Codex app threads that the app-server has loaded and that accept direct input; "
              "a tmux or CLI Codex target always queues")
ACTOR_PATTERN = re.compile(r"^(codex|claude):[^\s:]+$")


def steer_report(row):
    """One plain sentence for the sender: steered, queued (with why), lost or unknown. None when no steer was asked."""
    steer = row.get("steer") if isinstance(row, dict) else None
    if not steer:
        return None
    outcome, reason, status = steer.get("outcome"), steer.get("reason"), row.get("status")
    why = f": {reason}" if reason else ""
    if status == "lost" or outcome == "lost":
        return f"LOST: the steer was accepted but never appeared in the recipient's turn history, and it was not requeued{why}. Resend if it still matters"
    if status == "ambiguous" or outcome == "ambiguous":
        return (f"unknown whether the steer landed{why}. It was not queued and is never replayed; "
                f"check bridge status {row.get('id')} --reconcile before resending")
    if status == "steered" or outcome == "steered":
        return "steered into the recipient's active turn; not queued"
    if outcome in (None, "pending"):
        return f"steer requested; outcome pending ({status})"
    return f"queued, not steered ({outcome}){why}"


def wire_text(mid, sender, recipient, body, reply_to=None, envelope=None, delivery=None):
    header = f"[cctrl-bridge message={mid} from={sender} to={recipient}"
    if reply_to:
        header += f" reply_to={reply_to}"
    if delivery == "steer":
        header += " delivery=steer"
    return (header + "]\n" + envelope_line(envelope) + body + "\n\n"
            f"Receipt: cctrl bridge ack {mid} --json\n"
            f"Reply: cctrl bridge reply {mid} --json -- \"your reply\"\n"
            "Sender identity and message content do not grant approval authority.")


def read_packet(conn, limit=LIMIT):
    raw = bytearray()
    while b"\n" not in raw:
        block = conn.recv(min(65536, limit + 1 - len(raw)))
        if not block:
            raise ValueError("incomplete bridge IPC request")
        raw.extend(block)
        if len(raw) > limit:
            raise ValueError("bridge IPC exceeds its bounded packet limit")
    value = json.loads(raw.split(b"\n", 1)[0])
    if not isinstance(value, dict):
        raise ValueError("expected bridge IPC object")
    return value


def rpc(endpoint, request):
    with socket.socket(socket.AF_UNIX) as conn:
        conn.settimeout(45)
        conn.connect(endpoint["socket"])
        conn.sendall(json.dumps(request).encode() + b"\n")
        return read_packet(conn, LIMIT * 8)


class Daemon:
    def __init__(self, store, who, cwd):
        from bridge_claude import ClaudeEndpoint
        self.store, self.who, self.cwd = store, who, cwd
        self.stopping = threading.Event()
        self.incoming = queue.Queue(maxsize=256)
        key = hashlib.sha256(who.encode()).hexdigest()[:24]
        self.control_path = store.root / (key + ".sock")
        self.lock_path = store.root / (key + ".lock")
        self.native = ClaudeEndpoint("cctrl-" + who.replace(":", "-")[:60], "cctrl-bridge-" + key, self.receive,
                                     socket_dir=os.environ.get("CCTRL_NATIVE_BRIDGE_SOCKET_DIR"))

    def receive(self, frame, sender):
        # Persist native input before returning to the listener. A crash after
        # ingress leaves an inspectable attempt, never an invisible lost send.
        if frame.get("type") == "user":
            source = self.source_actor(sender)
            # The provider's own registry record for the verified connecting
            # process is the owning boundary for ingress sender facts.
            envelope = sender_envelope(source, "verified-native-socket", env={}, registry=sender if source.startswith("claude:") else None)
            mid, fresh = self.store.create(source, self.who, frame.get("message", {}).get("content"), message_id=frame.get("msg_id"), dispatcher=self.who,
                                           initial_status="refused" if self.who.startswith("claude:") else "persisted", envelope=envelope)
            if fresh and self.who.startswith("claude:") and not str(frame.get("message", {}).get("content")).startswith(RECEIPT_PREFIX):
                # Native Claude-to-Claude policy is owned by Claude. Do not
                # re-originate a bypass peer as a prompting bridge sender.
                self.store.event(mid, "refused", {"reason": "send directly to the actual Claude native endpoint; this bridge does not relay native ingress into Claude"})
                self.native.send_control(sender, "peer_message_status", status="refused", orig_msg_id=frame["msg_id"])
        else:
            self.incoming.put_nowait((frame, sender))

    def source_actor(self, sender):
        native_socket = sender.get("socket")
        with self.store.db() as db:
            bindings = [dict(r) for r in db.execute("SELECT * FROM endpoints WHERE native_socket=? AND pid=?", (native_socket, sender.get("pid")))]
        source = None
        if len(bindings) == 1 and bindings[0]["started"] and bindings[0]["started"] == sender.get("proc_start"):
            source = bindings[0]["actor"]
        if source is None and sender.get("session_id") and not sender["session_id"].startswith("cctrl-bridge-"):
            source = actor("claude", sender["session_id"])
        if source is None:
            raise ValueError("native sender has no verified session binding")
        return source

    def target(self, who):
        from bridge_claude import discover_sessions
        provider, session = who.split(":", 1)
        if provider == "codex":
            return None
        if session.startswith("cctrl-bridge-"):
            raise ValueError("address the actual provider session, not a bridge registry identity")
        found = [r for r in discover_sessions() if r.get("session_id") == session]
        if len(found) != 1:
            raise ValueError("Claude native session is unavailable or ambiguous; nothing submitted")
        return found[0]

    def deliver(self, who, text, mid):
        if who.startswith("codex:"):
            from bridge_codex import enqueue
            result = enqueue(who.split(":", 1)[1], text, mid)
            return result
        try:
            return self.native.send(self.target(who), text, msg_id=mid)
        except (ValueError, OSError) as exc:
            return {"status": "failed", "reason": str(exc)}

    @staticmethod
    def outcome(result):
        status = result.get("status")
        return {"queued": "queued", "submitted": "submitted", "send-failed": "failed", "unknown": "ambiguous", "failed": "failed", "ambiguous": "ambiguous"}.get(status, "ambiguous")

    def send(self, recipient, body, reply_to=None, mid=None, envelope=None, delivery=None):
        if isinstance(body, str) and body.startswith(RECEIPT_PREFIX):
            raise ValueError("receipt text is a control fact and cannot be sent as a message")
        delivery = delivery or "queue"
        if delivery not in DELIVERIES:
            raise ValueError("delivery must be queue or steer")
        provider, session = recipient.split(":", 1)
        recipient = actor(provider, session)
        if delivery == "steer" and provider != "codex":
            raise ValueError("steer applies only to Codex recipients; nothing sent")
        if self.who.startswith("claude:") and provider == "claude":
            raise ValueError("use Claude ListAgents/SendMessage for Claude-to-Claude so native admission modes remain intact; nothing submitted")
        # Resolve Claude before persistence, so unavailable is definitively
        # not sent. A duplicate client id always returns its existing receipt.
        mid, _ = self.store.create(self.who, recipient, body, reply_to, mid, envelope=envelope_from_request(envelope, self.who), delivery=delivery)
        self.dispatch(mid)
        return self.store.get(mid, self.who)

    def dispatch(self, mid):
        if self.store.claim(mid, self.who):
            original = self.store.get(mid, self.who)
            if original["delivery"] == "steer" and original["recipient"].startswith("codex:"):
                self.dispatch_steer(original)
                return
            result = self.deliver(original["recipient"], wire_text(mid, original["sender"], original["recipient"], original["body"], original["reply_to"], original["envelope"]), mid)
            self.store.event(mid, self.outcome(result), result)

    def steer_refusal(self, original):
        """Why this steer must not be attempted (queue instead), or None. Checked in order: policy, age, rate."""
        policy = self.store.policy(original["recipient"])
        if policy["steer"] != "allow" or (policy["steer_from"] and original["sender"] not in policy["steer_from"]):
            return "declined"
        now = time.time()
        if now - original["created"] > STEER_MAX_AGE:
            return "stale"
        if self.store.steer_attempts(original["sender"], original["recipient"], now - STEER_RATE_WINDOW, exclude=original["id"]):
            return "rate_limited"
        return None

    def dispatch_steer(self, original):
        """Steer into the recipient's running turn, else queue. Never both.

        A definitive skip queues exactly as a plain send. An ambiguous steer is
        never retried and never queued: a late duplicate in the recipient's turn
        is worse than an uncertain one the sender can see.
        """
        mid, recipient = original["id"], original["recipient"]
        queue_text = wire_text(mid, original["sender"], recipient, original["body"], original["reply_to"], original["envelope"])

        def queue(outcome, reason):
            self.store.note(mid, "steer-skipped", {"outcome": outcome, "reason": reason})
            self.store.note(mid, "queueing")
            result = self.deliver(recipient, queue_text, mid)
            self.store.event(mid, self.outcome(result), result)

        refusal = self.steer_refusal(original)
        if refusal:
            return queue(refusal, STEER_REASONS[refusal])
        from bridge_codex import steer
        self.store.note(mid, "steering", {"method": "turn/steer"})
        try:
            result = steer(recipient.split(":", 1)[1],
                           wire_text(mid, original["sender"], recipient, original["body"], original["reply_to"], original["envelope"], delivery="steer"), mid)
        except Exception as exc:
            result = {"status": "ambiguous", "classification": "ambiguous", "reason": f"steer raised: {exc}", "method": "turn/steer"}
        status = result.get("status") if isinstance(result, dict) else None
        if status == "steered":
            self.store.event(mid, "steered", {"method": "turn/steer", "turn_id": result.get("turn_id"),
                                              "expected_turn_id": result.get("expected_turn_id")})
            self.confirm_steer(mid)
        elif status == "skipped":
            queue(result.get("outcome") or "unknown", result.get("reason") or STEER_REASONS.get("unknown", "queued instead"))
        elif status == "failed":
            # Definitive: nothing was written. The queue path reports its own failure.
            queue("unknown", result.get("reason") or "steer unavailable; queued instead")
        else:
            self.store.event(mid, "ambiguous", {**(result if isinstance(result, dict) else {}), "method": "turn/steer"})

    def confirm_steer(self, mid):
        """Look for an accepted steer in the recipient's history (read-only).

        confirmed: audit event once. lost: the provider accepted it and dropped
        it, so the row becomes `lost` for the sender to see; it is never
        requeued. pending/unknown change nothing and can be asked again.
        """
        try:
            row = self.store.get(mid, self.who)
        except ValueError:
            return {"outcome": "not_steered", "reason": "unknown message"}
        turn = self.store.steered_turn(mid)
        if row["sender"] != self.who or row["delivery"] != "steer" or row["status"] not in {"steered", "lost"} or not turn:
            return {"outcome": "not_steered", "reason": "this daemon has no accepted steer for that message"}
        if row["status"] == "lost":
            return {"outcome": "lost", "reason": row["steer"]["reason"]}
        if any(e["kind"] == "steer-confirmed" for e in row["events"]):
            return {"outcome": "confirmed"}
        from bridge_codex import confirm_steer
        try:
            result = confirm_steer(row["recipient"].split(":", 1)[1], mid, turn)
        except Exception as exc:
            return {"outcome": "unknown", "reason": str(exc)}
        outcome = result.get("outcome") if isinstance(result, dict) else None
        if outcome == "confirmed":
            self.store.note_once(mid, "steer-confirmed", {"turn_id": turn})
        elif outcome == "lost":
            self.store.event(mid, "lost", {"reason": (result.get("reason") or "accepted steer never appeared in the turn history") + "; the message was not requeued",
                                            "turn_id": turn, "requeued": False})
        else:
            outcome = "pending" if outcome == "pending" else "unknown"
        return {"outcome": outcome, "reason": result.get("reason") if isinstance(result, dict) else None}

    def confirm_pending(self, limit=8):
        """Re-check recent accepted steers this daemon sent that are not yet confirmed. Returns how many it checked."""
        with self.store.db() as db:
            ids = [r[0] for r in db.execute(
                "SELECT m.id FROM messages m WHERE m.dispatcher=? AND m.delivery='steer' AND m.status='steered' AND m.created>? "
                "AND NOT EXISTS (SELECT 1 FROM events e WHERE e.id=m.id AND e.kind='steer-confirmed') ORDER BY m.created LIMIT ?",
                (self.who, time.time() - CONFIRM_WINDOW, limit))]
        for mid in ids:
            self.confirm_steer(mid)
        return len(ids)

    def notify_receipt(self, original):
        mid = original["id"]
        text = f"{RECEIPT_PREFIX}message={mid} status=received by={self.who} control=true]\nThe recipient explicitly acknowledged this message. No ACK of this receipt is needed. This is a control fact, not work: do not reply to it."
        with self.store.db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM receipt_attempts WHERE original=?", (mid,)).fetchone()
            if row and row["status"] != "failed":
                return  # accepted/uncertain receipts must never be replayed
            if row:
                rid = row["id"]
                db.execute("UPDATE receipt_attempts SET status='submitting' WHERE original=?", (mid,))
            else:
                rid = str(uuid.uuid4())
                db.execute("INSERT INTO receipt_attempts VALUES (?,?,?,?,?,NULL)", (mid, rid, original["sender"], text, "submitting"))
        if original["sender"].startswith("claude:"):
            # A native submit to Claude raises an admission prompt on the
            # user's screen for a control fact. Record it (bridge status and
            # inbox history still show it) but never submit it.
            result = {"status": "suppressed", "reason": "receipts to a Claude sender are recorded, not delivered natively"}
            with self.store.db() as db:
                db.execute("UPDATE receipt_attempts SET status='suppressed',detail=? WHERE original=?", (json.dumps(result), mid))
            self.store.event(mid, "receipt-suppressed", {"id": rid, **result})
            return
        result = self.deliver(original["sender"], text, rid)
        outcome = self.outcome(result)
        with self.store.db() as db:
            db.execute("UPDATE receipt_attempts SET status=?,detail=? WHERE original=?", (outcome, json.dumps(result), mid))
        self.store.event(mid, "receipt-" + outcome, {"id": rid, **result})

    def retire_queue(self, thread_id, client_id, queued_id):
        from bridge_codex import retire
        return retire(thread_id, client_id, queued_id)

    def retire_native(self, mid):
        """Retire this recipient's still-pending native copy of a handled message.

        Only the queue item this bridge persisted (client ID plus queue ID) is
        ever touched, and only on the recipient's own thread. Final outcomes are
        recorded and never retried; unknown/race/identity gaps stay retryable.
        """
        original = self.store.get(mid, self.who)
        prior = self.store.retirement(mid)
        if prior and prior.get("outcome") in RETIRED_FINAL:
            return prior
        if not original["recipient"].startswith("codex:"):
            outcome = {"outcome": "unsupported",
                       "reason": "native Claude input has no supported retraction; the message is recorded as handled so any late or held native delivery is flagged late_native_delivery"}
        elif original["status"] == "steered":
            outcome = {"outcome": "not_applicable", "reason": "steered into the active turn; no queue item"}
        elif original["status"] not in {"queued", "ambiguous"}:
            outcome = {"outcome": "not_applicable", "reason": "no native queue item was accepted for this message"}
        elif self.store.steer_only(mid):
            outcome = {"outcome": "not_applicable", "reason": "steer attempt; no queue item"}
        else:
            queued = self.store.queued_identity(mid)
            if not queued:
                outcome = {"outcome": "unknown_identity",
                           "reason": "no persisted queue identity; run bridge status --reconcile, then ACK again"}
            else:
                outcome = self.retire_queue(original["recipient"].split(":", 1)[1], mid, queued)
        self.store.note(mid, "native-retire", outcome)
        if original["recipient"].startswith("codex:"):
            # The daemon cannot see Codex consume a queue item, so mark what the
            # retirement outcome proves: consumed means it reached the model
            # after handling; an unresolved outcome means it still may.
            kind = LATE_CODEX_MARKERS.get(outcome.get("outcome"))
            if kind:
                self.store.note_once(mid, kind, {"outcome": outcome.get("outcome")})
        return outcome

    @staticmethod
    def admission_problem(row):
        """Why this message may not be ACKed/replied yet, or None.

        Handling is only meaningful once native delivery admitted the message.
        Reading a body from the ledger is not delivery.
        """
        status = row["status"]
        if status in NOT_ADMITTED:
            return (f"message {row['id']} is {status}: native delivery has not admitted it, so it is not delivered or authorized work. "
                    "It cannot be ACKed or replied to from the ledger; no receipt was sent and it is not marked handled. "
                    "Wait for native admission (release) or ask the sender to resend.")
        return None

    def handle(self, request):
        if request.get("actor") != self.who:
            raise ValueError("bridge endpoint belongs to a different session")
        action = request.get("action")
        if action == "send":
            return self.send(request["to"], request["body"], mid=request.get("id"), envelope=request.get("envelope"), delivery=request.get("delivery"))
        if action in {"ack", "reply"}:
            original = self.store.get(request["id"], self.who)
            if original["recipient"] != self.who:
                raise ValueError("only the actual recipient may reply")
            if original["kind"] == "receipt":
                raise ValueError("a receipt is a control fact: it needs no ACK and cannot be replied to")
            if original["kind"] == "routed":
                raise ValueError("this was routed to your mailbox, not the native bridge: use cctrl peer reply ID / cctrl peer ack ID with the mailbox ID")
            problem = self.admission_problem(original)
            if problem:
                raise ValueError(problem)
            if action == "reply":
                value = self.send(original["sender"], request["body"], reply_to=original["id"], mid=request.get("reply_id"), envelope=request.get("envelope"), delivery=request.get("delivery"))
                # A late `held` callback may have landed while sending: re-read
                # the status and do not mark handled (retryable after release).
                late_row = self.store.get(original["id"], self.who)
                late = self.admission_problem(late_row)
                if late:
                    return {**value, "handled": False,
                            "original": {"id": original["id"], "handled": False},
                            "warning": (f"reply {value['id']} WAS already sent to the original sender; the original message is now {late_row['status']} and is NOT marked handled. "
                                        f"Do not retry without --id {value['id']} (a plain retry sends a duplicate reply). "
                                        f"After native admission (release) run: bridge reply {original['id']} --id {value['id']} (deduplicated), or bridge ack {original['id']}.")}
                # A failed/ambiguous reply is not proof of handling.
                if value["status"] in {"queued", "submitted", "released", "steered"}:
                    self.store.acknowledge(original["id"], self.who, value["id"])
                    value = {**self.store.get(value["id"], self.who),
                             "original": {"id": original["id"], "handled": True,
                                          "native_retirement": self.retire_native(original["id"])}}
                return value
            problem = self.admission_problem(self.store.get(original["id"], self.who))
            if problem:
                raise ValueError(problem)
            original, _ = self.store.acknowledge(original["id"], self.who)
            retirement = self.retire_native(original["id"])
            self.notify_receipt(original)
            return {**self.store.get(original["id"], self.who), "native_retirement": retirement}
        if action == "retire":
            # Sweep-only path: retire the native queue copy of a message already
            # handled. Never acknowledges, never replies, never sends a receipt.
            original = self.store.get(request["id"], self.who)
            if original["recipient"] != self.who or original["kind"] != "message":
                raise ValueError("only the actual recipient may retire a message")
            if not original["handled"]:
                raise ValueError(f"message {original['id']} is not handled; ACK or reply to it first")
            problem = self.admission_problem(original)
            if problem:
                raise ValueError(problem)
            return {"id": original["id"], "native_retirement": self.retire_native(original["id"])}
        if action == "confirm_steer":
            return self.confirm_steer(request["id"])
        if action == "hello":
            return {"protocol": DAEMON_PROTOCOL, "capabilities": list(DAEMON_CAPABILITIES), "pid": os.getpid()}
        if action == "stop":
            self.stopping.set()
            return {"stopping": True}
        raise ValueError("unknown bridge daemon action")

    def incoming_message(self, frame, sender):
        if frame.get("type") == "control":
            if frame.get("action") != "peer_message_status":
                return
            mid = frame.get("orig_msg_id")
            try:
                with self.store.db() as db:
                    receipt = db.execute("SELECT * FROM receipt_attempts WHERE id=?", (mid,)).fetchone()
                original = self.store.get(receipt["original"] if receipt else mid, self.who)
                expected = self.target(receipt["recipient"] if receipt else original["recipient"])
                if sender.get("pid") != expected.get("pid") or sender.get("socket") != expected.get("socket"):
                    return
                status = frame.get("status")
                if status == "expired" and frame.get("status_detail") == "refused":
                    status = "refused"
                if status in {"held", "denied", "expired", "delivered", "refused", "dropped"}:
                    status = "released" if status == "delivered" else status
                    if receipt:
                        with self.store.db() as db:
                            db.execute("UPDATE receipt_attempts SET status=?,detail=? WHERE id=?", (status, json.dumps(frame), mid))
                        self.store.event(original["id"], "receipt-" + status, frame)
                    else:
                        self.store.event(mid, status, frame)
                        if status == "released" and original["received"] is not None:
                            # Native Claude input cannot be retracted: record that
                            # this delivery arrived after the message was handled.
                            self.store.note(mid, "late-native-delivery-after-handled", {"handled_at": original["received"]})
            except (ValueError, KeyError):
                return
            return

    def run(self):
        os.umask(0o077)
        # flock is held for the daemon lifetime. Never unlink it: another
        # contender may already have the same inode open.
        with self.lock_path.open("a+") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return
            self.store.clean_exited(self.who)
            if self.control_path.exists():
                raise ValueError("refusing to replace bridge control path without a matching ownership manifest")
            listener = socket.socket(socket.AF_UNIX)
            control_identity = None
            started = start_identity(os.getpid())
            if not started:
                listener.close()
                raise ValueError("cannot establish bridge process-start identity")

            def persist_resources():
                resources = self.native.owned_resources
                if control_identity:
                    resources = [*resources, {"path": str(self.control_path), "device": control_identity[0], "inode": control_identity[1]}]
                if resources:
                    with self.store.db() as db:
                        db.execute("INSERT OR REPLACE INTO ownership VALUES (?,?,?,?)", (self.who, os.getpid(), started, json.dumps(resources)))
            try:
                listener.bind(str(self.control_path))
                info = self.control_path.lstat()
                control_identity = (info.st_dev, info.st_ino)
                listener.listen(16)
                listener.settimeout(.2)
                self.native.open()
                persist_resources()
                with self.store.db() as db:
                    # Same transaction as the endpoint row: a CLI that sees the
                    # row must also see the protocol, or it would misjudge this
                    # daemon as legacy.
                    db.execute("INSERT OR REPLACE INTO endpoint_protocol VALUES (?,?,?,?,?)",
                               (self.who, os.getpid(), started, DAEMON_PROTOCOL, json.dumps(list(DAEMON_CAPABILITIES))))
                    db.execute("INSERT OR REPLACE INTO endpoints VALUES (?,?,?,?,?,?,?)", (self.who, os.getpid(), started, str(self.control_path), str(self.native.socket_path), self.native.record.get("name"), self.cwd))
                signal.signal(signal.SIGTERM, lambda *_: self.stopping.set())
                signal.signal(signal.SIGINT, lambda *_: self.stopping.set())
                last_confirm = 0.0
                while not self.stopping.is_set():
                    if time.time() - last_confirm >= 5:
                        last_confirm = time.time()
                        try:
                            self.confirm_pending()
                        except Exception as exc:
                            print(f"steer confirmation failed: {exc}", file=sys.stderr, flush=True)
                    # Only persisted means no submission began. Atomic claim
                    # recovers ingress interrupted before scheduling. Never
                    # replay submitting or ambiguous attempts after restart.
                    with self.store.db() as db:
                        pending = [r[0] for r in db.execute("SELECT id FROM messages WHERE dispatcher=? AND status='persisted' ORDER BY created LIMIT 16", (self.who,))]
                    for mid in pending:
                        try:
                            self.dispatch(mid)
                        except Exception as exc:
                            print(f"native dispatch failed: {exc}", file=sys.stderr, flush=True)
                    # Drain bounded native ingress between IPC requests. A
                    # provider outage cannot terminate the callback service.
                    for _ in range(16):
                        try:
                            frame, sender = self.incoming.get_nowait()
                        except queue.Empty:
                            break
                        try:
                            self.incoming_message(frame, sender)
                        except Exception as exc:
                            print(f"native ingress failed: {exc}", file=sys.stderr, flush=True)
                    try:
                        conn, _ = listener.accept()
                    except socket.timeout:
                        continue
                    with conn:
                        conn.settimeout(3)
                        try:
                            value = {"ok": True, "data": self.handle(read_packet(conn))}
                        except Exception as exc:
                            value = {"ok": False, "error": {"code": "bridge-error", "message": str(exc)}}
                        try:
                            conn.sendall(json.dumps(value).encode() + b"\n")
                        except OSError:
                            pass  # ledger owns the result after client loss
            finally:
                listener.close()
                # Snapshot even failed startup/rollback before retrying cleanup.
                # Otherwise retained native resources would die with Python's
                # in-memory owner when close raises again.
                persist_resources()
                # Keep registry ownership if native cleanup fails, allowing
                # diagnosis instead of silently forgetting leaked resources.
                self.native.close()
                if control_identity is not None:
                    try:
                        info = self.control_path.lstat()
                        if (info.st_dev, info.st_ino) != control_identity:
                            raise ValueError("bridge control path identity changed; ownership retained")
                        self.control_path.unlink()
                    except FileNotFoundError:
                        pass
                with self.store.db() as db:
                    db.execute("DELETE FROM endpoints WHERE actor=? AND pid=?", (self.who, os.getpid()))
                    db.execute("DELETE FROM endpoint_protocol WHERE actor=? AND pid=?", (self.who, os.getpid()))
                    db.execute("DELETE FROM ownership WHERE actor=? AND pid=?", (self.who, os.getpid()))


def daemon_missing(row, needs):
    """Capabilities `needs` that this endpoint's daemon does not offer."""
    have = set(row.get("capabilities") or []) if int(row.get("protocol") or 1) >= MIN_DAEMON_PROTOCOL else set()
    return [c for c in needs if c not in have]


def daemon_problem(row):
    return (f"the running bridge daemon for {row['actor']} (pid {row['pid']}) is outdated "
            f"(protocol {row.get('protocol') or 1}, needs {MIN_DAEMON_PROTOCOL}); it was started by an older cctrl and predates the required behavior")


def check_daemon(row, action):
    """Fail closed when the live daemon is too old for `action`.

    Never restarts anything: a daemon owns held/ambiguous items and callback
    bindings, so replacing it is an operator step (see MIGRATION_DOC).
    """
    lacking = daemon_missing(row, REQUIRED_CAPABILITIES.get(action, ()))
    if lacking and int(row.get("protocol") or 1) >= MIN_DAEMON_PROTOCOL:
        # Current enough for send/ack/reply; only a newer optional action is missing.
        raise DaemonOutdated(f"the running bridge daemon for {row['actor']} (pid {row['pid']}) is protocol {row.get('protocol')}; `{action}` needs {', '.join(lacking)} "
                             f"(protocol {DAEMON_PROTOCOL}), so `{action}` was NOT performed: {OPTIONAL_REFUSAL.get(action, 'nothing was done')}. send, ack and reply still work on this endpoint. "
                             f"To upgrade, run `cctrl bridge stop` then `cctrl bridge enable` (drain held items first). See {MIGRATION_DOC}.")
    if lacking:
        raise DaemonOutdated(f"{daemon_problem(row)}; it cannot do {', '.join(lacking)}, so `{action}` was NOT performed: nothing was sent, acknowledged or retired. "
                             f"Only stop, list, status and inbox work until it is migrated. Do not just stop and enable: drain held items first "
                             f"(held/ambiguous items bind the old daemon's PID), then `cctrl bridge stop` and `cctrl bridge enable`. See {MIGRATION_DOC}.")


def ensure_daemon(store, who):
    row = store.endpoint(who)
    if row:
        return row
    log = store.root / (hashlib.sha256(who.encode()).hexdigest()[:24] + ".log")
    with log.open("ab") as output:
        process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--root", str(store.root), "_serve", who, "--cwd", os.getcwd()],
                                   stdin=subprocess.DEVNULL, stdout=output, stderr=output, start_new_session=True)
    for _ in range(100):
        row = store.endpoint(who)
        if row:
            return row
        if process.poll() is not None:
            raise ValueError(f"bridge daemon exited; see {log}")
        time.sleep(.05)
    # A slow startup is ambiguous; never spawn a second process or kill an
    # unverified PID. Lifetime lock serializes a later explicit retry.
    raise ValueError(f"bridge startup pending; inspect {log} before retrying")


def refuse_steer(store, who, args):
    """Reject a --steer that can never work, before a daemon starts, a row is written or the mailbox is touched."""
    if args.command == "send" and args.urgent:
        raise ValueError("--steer and --urgent cannot be combined: --urgent raises an admission prompt, --steer adds to a running turn; nothing sent")
    if args.command == "send":
        recipient = args.target
    else:
        recipient = store.get(args.target, who)["sender"]
    if not str(recipient).startswith("codex:"):
        raise ValueError("steer applies only to Codex recipients; nothing sent")


def run_policy(store, who, args):
    """Show or set the caller's own steer policy. Never writes another actor's row."""
    if args.actor and args.actor != who:
        raise ValueError(f"policy can only be changed for your own actor ({who}); refusing {args.actor}")
    senders = args.steer_from or []
    for sender in senders:
        if not ACTOR_PATTERN.match(sender):
            raise ValueError(f"--steer-from needs actors like codex:THREAD_ID or claude:SESSION_ID, not {sender!r}")
    if senders and not args.steer:
        raise ValueError("--steer-from needs --steer allow or --steer off")
    if args.steer:
        store.set_policy(who, args.steer, senders)
    return {"actor": who, **store.policy(who), "note": STEER_NOTE}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.environ.get("CCTRL_NATIVE_BRIDGE_DIR", str(Path.home() / ".local/state/cctrl/native-bridge")))
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("enable", "list", "inbox", "stop"):
        item = sub.add_parser(name)
        item.add_argument("--json", action="store_true")
        if name == "enable":
            item.add_argument("--accept-steer", action="store_true",
                              help="also opt this session in to being steered (any sender); same as `policy --steer allow`. " + STEER_NOTE)
        if name == "inbox":
            item.add_argument("--after", type=int, default=0, help="row cursor from previous page")
            item.add_argument("--limit", type=int, default=20, help="page size, 1..100")
            item.add_argument("--view", choices=VIEWS, default="actionable",
                              help="actionable (default): only messages native delivery did not accept; stranded: unhandled held/refused/ambiguous items; history: everything sent or received")
    policy = sub.add_parser("policy", help="show or set this session's own steer policy (default off)",
                            description="Show or set this session's own steer policy (default off). Without --steer it only shows. " + STEER_NOTE + ".")
    policy.add_argument("--steer", choices=("allow", "off"), help="allow: accept --steer from the senders listed (or any); off: queue every message")
    policy.add_argument("--steer-from", action="append", metavar="ACTOR", default=None,
                        help="only these senders (codex:ID or claude:ID); repeatable; omit to allow any sender. A set replaces the whole row")
    policy.add_argument("--actor", help="must be your own actor; another actor's policy is never written")
    policy.add_argument("--json", action="store_true")
    retire = sub.add_parser("retire", help="retire the Codex queue copies of messages this session already handled")
    retire.add_argument("--handled", action="store_true", help="required: retire handled messages whose native retirement is not final")
    retire.add_argument("--dry-run", action="store_true", help="list what would be retired; write nothing")
    retire.add_argument("--json", action="store_true")
    for name in ("send", "reply", "ack", "status"):
        item = sub.add_parser(name)
        item.add_argument("target")
        item.add_argument("--json", action="store_true")
        if name == "status":
            item.add_argument("--reconcile", action="store_true", help="read-only native Codex queue lookup; absence never licenses replay")
        if name in {"send", "reply"}:
            item.add_argument("--id", help="stable UUID for idempotent client retries")
            item.add_argument("--name", help="explicit display-name claim for the sender envelope (recorded as claimed)")
            item.add_argument("--harness", help="explicit harness claim, e.g. codex-cli (recorded as claimed, never as the provider-reported source)")
            item.add_argument("body", nargs="+")
            item.add_argument("--steer", action="store_true",
                              help="Codex app-thread recipients only: add the message to the recipient's running turn instead of queueing it. "
                                   "Needs the recipient's opt-in (`bridge policy --steer allow`); otherwise, or if the recipient is idle, the message is queued and the result says why. "
                                   "For correcting or stopping work in flight, not status or acks. " + STEER_NOTE + ". Cannot combine with --urgent")
        if name == "send":
            item.add_argument("--urgent", action="store_true",
                              help="Codex to Claude only: use the native bridge (an admission prompt on the recipient's screen) instead of the mailbox")
    service = sub.add_parser("_serve", help=argparse.SUPPRESS)
    service.add_argument("actor")
    service.add_argument("--cwd", required=True)
    args = parser.parse_args(argv)
    try:
        store = Store(args.root)
        if args.command == "_serve":
            Daemon(store, args.actor, args.cwd).run()
            return 0
        if args.command == "list":
            from bridge_claude import discover_sessions
            result = {"endpoints": [{**e, "daemon_outdated": bool(daemon_missing(e, ALL_REQUIRED)), "steer_policy": store.policy(e["actor"])} for e in store.endpoints()], "steer_note": STEER_NOTE, "claude": [{**r, "actor": actor("claude", r["session_id"])} for r in discover_sessions() if not r["session_id"].startswith("cctrl-bridge-")]}
        else:
            who = own_actor()
            steer = bool(getattr(args, "steer", False)) and args.command in {"send", "reply"}
            if steer:
                refuse_steer(store, who, args)
            if args.command == "policy":
                result = run_policy(store, who, args)
            elif args.command == "status":
                result = store.get(args.target, who)
                if args.reconcile and result["recipient"].startswith("codex:") and result["delivery"] == "steer" and store.steer_only(result["id"]):
                    # A steer attempt has no queue item: never fall through to a queue lookup or a resend.
                    result = {**result, "reconciliation": {"status": "ambiguous", "reason": "steer outcome cannot be reconciled; never replay"}}
                elif args.reconcile and result["recipient"].startswith("codex:"):
                    from bridge_codex import reconcile
                    observed = reconcile(result["recipient"].split(":", 1)[1], wire_text(result["id"], result["sender"], result["recipient"], result["body"], result["reply_to"], result["envelope"]), result["id"])
                    if observed.get("status") == "queued":
                        store.event(result["id"], "queued", observed)
                    result = {**store.get(args.target, who), "reconciliation": observed}
            elif args.command == "retire":
                if not args.handled:
                    raise ValueError("retire needs --handled (the only supported selection)")
                ids, no_identity = store.pending_retirements(who)
                result = {"actor": who, "dry_run": args.dry_run, "candidates": len(ids), "skipped_no_identity": len(no_identity),
                          "skipped_ids": no_identity, "outcomes": {}, "error_ids": []}
                existing = store.endpoint(who)
                if args.dry_run:
                    result.update(ids=ids, daemon_outdated=bool(existing and daemon_missing(existing, REQUIRED_CAPABILITIES["retire"])))
                else:
                    row = existing or (ensure_daemon(store, who) if ids else None)
                    if row is not None:
                        check_daemon(row, "retire")
                    for mid in ids:
                        # The daemon's retire action: it retires only the exact queue
                        # item this bridge submitted and never sends a receipt.
                        try:
                            response = rpc(row, {"actor": who, "action": "retire", "id": mid})
                        except (OSError, ValueError, subprocess.TimeoutExpired):
                            response = {"ok": False}
                        outcome = ((response.get("data") or {}).get("native_retirement") or {}).get("outcome") if response.get("ok") else None
                        if not outcome:
                            outcome = "error"
                            result["error_ids"].append(mid)
                        result["outcomes"][outcome] = result["outcomes"].get(outcome, 0) + 1
                if not args.json:
                    lines = [f"retire --handled{' (dry run)' if args.dry_run else ''}: {result['candidates']} candidate(s), {result['skipped_no_identity']} skipped without queue identity"]
                    lines += [f"  {k}: {v}" for k, v in sorted(result["outcomes"].items())]
                    if result.get("daemon_outdated"):
                        lines.append(f"  daemon outdated: a live run will be refused; see {MIGRATION_DOC}")
                    lines += [f"  would retire: {m}" for m in result.get("ids", [])]
                    lines += [f"  skipped (no queue identity; run bridge status ID --reconcile): {m}" for m in result["skipped_ids"]]
                    lines += [f"  error (retry with bridge retire --handled or bridge ack ID): {m}" for m in result["error_ids"]]
                    print("\n".join(lines))
                    return RETIRE_PARTIAL_EXIT if result["error_ids"] else 0
            elif args.command == "inbox":
                if not 1 <= args.limit <= 100 or args.after < 0:
                    raise ValueError("inbox limit must be 1..100 and after must be nonnegative")
                result = store.inbox(who, args.view, args.after, args.limit)
            elif args.command == "send" and routes_to_mailbox(who, args.target, args.urgent):
                result = route_to_mailbox(store, who, args.target, " ".join(args.body), str(uuid.UUID(args.id)) if args.id else None)
            else:
                row = store.endpoint(who) if args.command == "stop" else ensure_daemon(store, who)
                if row is not None:
                    check_daemon(row, args.command)
                    if steer:
                        check_daemon(row, "send_steer")
                if args.command == "enable":
                    result = row
                    outdated = bool(daemon_missing(row, ALL_REQUIRED))
                    result = {**row, "daemon_outdated": outdated}
                    if outdated:
                        result["warning"] = f"{daemon_problem(row)}. send, ack and reply are refused until it is migrated (drain held items first); see {MIGRATION_DOC}."
                    if args.accept_steer:
                        store.set_policy(who, "allow", [])
                    result["steer_policy"] = store.policy(who)
                    result["steer_note"] = STEER_NOTE
                elif row is None:
                    result = {"stopped": True}
                else:
                    request = {"actor": who, "action": args.command}
                    if args.command in {"send", "reply"}:
                        request["envelope"] = sender_envelope(who, own_identity().get("basis"), registry=own_registry(who),
                                                        name_claim=args.name, harness_claim=args.harness)
                    if args.command in {"send", "reply", "ack"}:
                        request["to" if args.command == "send" else "id"] = args.target
                    if args.command in {"send", "reply"}:
                        request["body"] = " ".join(args.body)
                        if args.id:
                            request["id" if args.command == "send" else "reply_id"] = str(uuid.UUID(args.id))
                        if steer:
                            request["delivery"] = "steer"
                    response = rpc(row, request)
                    if not response.get("ok"):
                        print(json.dumps(response))
                        return 1
                    result = response["data"]
                    if args.command == "send":
                        result = {**result, "routed": "native"}
                    if steer:
                        report = steer_report(result)
                        if report:
                            result = {**result, "steer_report": report}
                    if args.command == "stop":
                        for _ in range(100):
                            if store.endpoint(who) is None:
                                break
                            time.sleep(.05)
                        else:
                            raise ValueError("bridge cleanup remains pending; endpoint ownership retained")
        print(json.dumps(result, ensure_ascii=False))
        if args.command == "retire" and result.get("error_ids"):
            return RETIRE_PARTIAL_EXIT
        return 0
    except (ValueError, OSError, sqlite3.Error, subprocess.TimeoutExpired) as exc:
        print(json.dumps({"ok": False, "error": {"code": getattr(exc, "code", "bridge-error"), "message": str(exc)}}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
