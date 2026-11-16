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


def actor(provider, session):
    if provider not in {"claude", "codex"}:
        raise ValueError("provider must be claude or codex")
    return provider + ":" + session_value(session)


def own_actor():
    value = environment_identity(os.environ)
    if value is None and os.environ.get("CLAUDECODE"):
        value = claude_ancestor_identity(Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))) / "sessions")
    if not value:
        raise ValueError("no actual provider session ID; set CODEX_THREAD_ID or CLAUDE_CODE_SESSION_ID to your own native session ID")
    return actor(value["provider"], value["session_id"])


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
            CREATE TABLE IF NOT EXISTS ownership (
              actor TEXT NOT NULL,pid INTEGER NOT NULL,started TEXT NOT NULL,
              resources TEXT NOT NULL, PRIMARY KEY(actor,pid,started));
            """)
            if "dispatcher" not in {r[1] for r in db.execute("PRAGMA table_info(messages)")}:
                db.execute("ALTER TABLE messages ADD COLUMN dispatcher TEXT")
                db.execute("UPDATE messages SET dispatcher=sender WHERE dispatcher IS NULL")
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
            return dict(row)
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
            if unresolved:
                raise ValueError("exited bridge cleanup failed; ownership manifest retained in ledger")

    def create(self, sender, recipient, body, reply_to=None, message_id=None, dispatcher=None, initial_status="persisted"):
        if initial_status not in {"persisted", "refused"}:
            raise ValueError("invalid initial bridge status")
        if not isinstance(body, str) or not body or len(body.encode()) > LIMIT // 2:
            raise ValueError("body must be nonempty UTF-8 text of at most 512 KiB")
        mid = str(uuid.UUID(message_id)) if message_id else str(uuid.uuid4())
        with self.db() as db:
            db.execute("BEGIN IMMEDIATE")
            old = db.execute("SELECT * FROM messages WHERE id=?", (mid,)).fetchone()
            if old:
                if (old["sender"], old["recipient"], old["body"], old["reply_to"]) != (sender, recipient, body, reply_to):
                    raise ValueError("message ID already belongs to different content")
                return mid, False
            db.execute("INSERT INTO messages(id,sender,recipient,body,reply_to,created,status,dispatcher) VALUES (?,?,?,?,?,?,?,?)",
                       (mid, sender, recipient, body, reply_to, time.time(), initial_status, dispatcher or sender))
            db.execute("INSERT INTO events(id,at,kind) VALUES (?,?,?)", (mid, time.time(), initial_status))
        return mid, True

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
                if not (kind in {"submitted", "queued", "failed", "ambiguous", "submitting"} and current in policy):
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
            return value

    def acknowledge(self, mid, who, reply=None):
        with self.db() as db:
            row = db.execute("SELECT * FROM messages WHERE id=?", (mid,)).fetchone()
            if not row or row["recipient"] != who:
                raise ValueError("only the actual recipient session may acknowledge or reply")
            first = row["received"] is None
            db.execute("UPDATE messages SET received=COALESCE(received,?),replied=COALESCE(?,replied) WHERE id=?", (time.time(), reply, mid))
            if first or reply:
                db.execute("INSERT INTO events(id,at,kind,detail) VALUES (?,?,?,?)", (mid, time.time(), "replied" if reply else "received", json.dumps({"actor": who, "reply": reply})))
            return dict(row), first


def wire_text(mid, sender, recipient, body, reply_to=None):
    header = f"[cctrl-bridge message={mid} from={sender} to={recipient}"
    if reply_to:
        header += f" reply_to={reply_to}"
    return (header + "]\n" + body + "\n\n"
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
            mid, fresh = self.store.create(source, self.who, frame.get("message", {}).get("content"), message_id=frame.get("msg_id"), dispatcher=self.who,
                                           initial_status="refused" if self.who.startswith("claude:") else "persisted")
            if fresh and self.who.startswith("claude:"):
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

    def send(self, recipient, body, reply_to=None, mid=None):
        provider, session = recipient.split(":", 1)
        recipient = actor(provider, session)
        if self.who.startswith("claude:") and provider == "claude":
            raise ValueError("use Claude ListAgents/SendMessage for Claude-to-Claude so native admission modes remain intact; nothing submitted")
        # Resolve Claude before persistence, so unavailable is definitively
        # not sent. A duplicate client id always returns its existing receipt.
        mid, _ = self.store.create(self.who, recipient, body, reply_to, mid)
        self.dispatch(mid)
        return self.store.get(mid, self.who)

    def dispatch(self, mid):
        if self.store.claim(mid, self.who):
            original = self.store.get(mid, self.who)
            result = self.deliver(original["recipient"], wire_text(mid, original["sender"], original["recipient"], original["body"], original["reply_to"]), mid)
            self.store.event(mid, self.outcome(result), result)

    def notify_receipt(self, original):
        mid = original["id"]
        text = f"[cctrl-bridge receipt message={mid} status=received by={self.who}]\nThe recipient explicitly acknowledged this message. No ACK of this receipt is needed."
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
        result = self.deliver(original["sender"], text, rid)
        outcome = self.outcome(result)
        with self.store.db() as db:
            db.execute("UPDATE receipt_attempts SET status=?,detail=? WHERE original=?", (outcome, json.dumps(result), mid))
        self.store.event(mid, "receipt-" + outcome, {"id": rid, **result})

    def handle(self, request):
        if request.get("actor") != self.who:
            raise ValueError("bridge endpoint belongs to a different session")
        action = request.get("action")
        if action == "send":
            return self.send(request["to"], request["body"], mid=request.get("id"))
        if action in {"ack", "reply"}:
            original = self.store.get(request["id"], self.who)
            if original["recipient"] != self.who:
                raise ValueError("only the actual recipient may reply")
            if action == "reply":
                value = self.send(original["sender"], request["body"], reply_to=original["id"], mid=request.get("reply_id"))
                # A failed/ambiguous reply is not proof of handling.
                if value["status"] in {"queued", "submitted", "released"}:
                    self.store.acknowledge(original["id"], self.who, value["id"])
                return value
            original, _ = self.store.acknowledge(original["id"], self.who)
            self.notify_receipt(original)
            return self.store.get(original["id"], self.who)
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
                    db.execute("INSERT OR REPLACE INTO endpoints VALUES (?,?,?,?,?,?,?)", (self.who, os.getpid(), started, str(self.control_path), str(self.native.socket_path), self.native.record.get("name"), self.cwd))
                signal.signal(signal.SIGTERM, lambda *_: self.stopping.set())
                signal.signal(signal.SIGINT, lambda *_: self.stopping.set())
                while not self.stopping.is_set():
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
                    db.execute("DELETE FROM ownership WHERE actor=? AND pid=?", (self.who, os.getpid()))


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


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.environ.get("CCTRL_NATIVE_BRIDGE_DIR", str(Path.home() / ".local/state/cctrl/native-bridge")))
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("enable", "list", "inbox", "stop"):
        item = sub.add_parser(name)
        item.add_argument("--json", action="store_true")
        if name == "inbox":
            item.add_argument("--after", type=int, default=0, help="row cursor from previous page")
            item.add_argument("--limit", type=int, default=20, help="page size, 1..100")
    for name in ("send", "reply", "ack", "status"):
        item = sub.add_parser(name)
        item.add_argument("target")
        item.add_argument("--json", action="store_true")
        if name == "status":
            item.add_argument("--reconcile", action="store_true", help="read-only native Codex queue lookup; absence never licenses replay")
        if name in {"send", "reply"}:
            item.add_argument("--id", help="stable UUID for idempotent client retries")
            item.add_argument("body", nargs="+")
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
            result = {"endpoints": store.endpoints(), "claude": [{**r, "actor": actor("claude", r["session_id"])} for r in discover_sessions() if not r["session_id"].startswith("cctrl-bridge-")]}
        else:
            who = own_actor()
            if args.command == "status":
                result = store.get(args.target, who)
                if args.reconcile and result["recipient"].startswith("codex:"):
                    from bridge_codex import reconcile
                    observed = reconcile(result["recipient"].split(":", 1)[1], wire_text(result["id"], result["sender"], result["recipient"], result["body"], result["reply_to"]), result["id"])
                    if observed.get("status") == "queued":
                        store.event(result["id"], "queued", observed)
                    result = {**store.get(args.target, who), "reconciliation": observed}
            elif args.command == "inbox":
                if not 1 <= args.limit <= 100 or args.after < 0:
                    raise ValueError("inbox limit must be 1..100 and after must be nonnegative")
                with store.db() as db:
                    rows = [dict(r) for r in db.execute("SELECT rowid AS cursor,* FROM messages WHERE recipient=? AND received IS NULL AND rowid>? ORDER BY rowid LIMIT ?", (who, args.after, args.limit + 1))]
                    result = {"actor": who, "messages": rows[:args.limit], "next_cursor": rows[args.limit - 1]["cursor"] if len(rows) > args.limit else None}
            else:
                row = store.endpoint(who) if args.command == "stop" else ensure_daemon(store, who)
                if args.command == "enable":
                    result = row
                elif row is None:
                    result = {"stopped": True}
                else:
                    request = {"actor": who, "action": args.command}
                    if args.command in {"send", "reply", "ack"}:
                        request["to" if args.command == "send" else "id"] = args.target
                    if args.command in {"send", "reply"}:
                        request["body"] = " ".join(args.body)
                        if args.id:
                            request["id" if args.command == "send" else "reply_id"] = str(uuid.UUID(args.id))
                    response = rpc(row, request)
                    if not response.get("ok"):
                        print(json.dumps(response))
                        return 1
                    result = response["data"]
                    if args.command == "stop":
                        for _ in range(100):
                            if store.endpoint(who) is None:
                                break
                            time.sleep(.05)
                        else:
                            raise ValueError("bridge cleanup remains pending; endpoint ownership retained")
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (ValueError, OSError, sqlite3.Error, subprocess.TimeoutExpired) as exc:
        print(json.dumps({"ok": False, "error": {"code": "bridge-error", "message": str(exc)}}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
