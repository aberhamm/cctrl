"""Per-host HMAC seal for peer mail (plan 111 phase 2).

Run as `python3 -I -S peer_seal.py <mode> ...`. The key never touches argv,
env, stdout, stderr or a log: this helper reads the key file itself and only
ever prints MACs (which are not secret) and verification facts.

Modes:
  seal <host_id>    stdin: one message object. stdout: the hex MAC.
                    Creates the key on first use (atomic, create-once).
  verify <host_id> [--eligibility <since> [--allow <json>] [--seen <json>]]
                    stdin: a JSON array of messages. stdout: a JSON array of
                    verification objects, one per message, same order.
                    Never creates the key. With --eligibility (plan 111
                    phase 3) each object also carries `eligibility`: whether
                    the message may push or ring the Stop bell. <since> is
                    the effective attestation_since (ISO UTC), "" for none,
                    or "invalid". --allow (phase 4) is the resolved push
                    allowlist cctrl reads from doorbell.json (push_senders
                    and recipients.<to>.push_senders): {"default": A,
                    "recipients": {name: A} | "malformed"}, A = {"roles":
                    [...], "peers": [...]} or null (malformed: matches
                    nothing). Without it, the built-in default applies.
                    --seen (phase 5) is a JSON array of ids already in
                    messages-archive.jsonl: a line with one of them is a
                    replay (detail duplicate-id), never eligible.
  doctor <host_id>  stdin: a JSON array of messages. stdout: one JSON object
                    with the key status (path, exists, mode; never the key)
                    and verification counts. Never creates the key.
  seen <archive>    stdin: a JSON array of candidate ids. stdout: the JSON
                    array (sorted) of those ids that are the top-level `id`
                    of a line of <archive> (messages-archive.jsonl). Plan 111
                    phase 6 (p5 verify F1/F3): the archive never travels
                    through argv, and a line is matched on its id field only
                    (a body quoting an id is not a hit), in one pass. Exit 1
                    when the archive exists but is not a readable regular
                    file (the caller fails closed); a missing one is [].

This is a same-uid misuse barrier, not authentication: any process running as
this user can read the key file.

Key file: $CCTRL_PEER_SEAL_KEY_FILE, else $HOME/.local/state/cctrl/peer-seal.key
(pinned, not XDG_STATE_HOME, so every caller on the host resolves one file).
32 random bytes, file 0600, dir 0700. A key dir that is not 0700 and owned
by this user, or a key file with any group/other bit, makes the key unusable
(never chmod'ed): sends go unsealed, sealed mail reads seal-mismatch.
"""
import hashlib
import hmac
import json
import os
import signal
import stat
import sys
import time

KEY_LEN = 32
SEAL_VERSION = 1
DOMAIN = b"cctrl-peer-seal-v1\n"
# Every field written at send time. The mutable delivery fields (status,
# updated_at, delivered_at, acked_at, nudge_count, last_nudge_at,
# last_nudge_error, history, app_delivery_attempt, blocked_reason) are left
# out on purpose; body and subject are hashed.
SEALED_FIELDS = (
    "id", "from", "to", "created_at", "sender", "audit", "attest",
    "recipient_provider_task_id", "unknown_peer",
)
HASHED_FIELDS = ("body", "subject")
# Plan 111 phase 3: the built-in default push allowlist, used while
# doorbell.json has no push_senders (phase 4 makes it configurable). Push:
# orchestrators (fleet-manager is role orchestrator with orch_kind fleet). The
# Stop bell also admits level-session workers whatever the allowlist says: it
# carries fixed nudge text (BELL_ONLY_ROLES is not configurable).
PUSH_ROLES = ("orchestrator", "fleet-manager")
BUILTIN_SENDERS = {"roles": list(PUSH_ROLES), "peers": []}
BELL_ONLY_ROLES = ("worker",)
TMP_PREFIX = ".peer-seal."
TMP_SUFFIX = ".tmp"
TMP_STALE_SECONDS = 60
LEVEL_REASON = {
    "impersonated": "impersonated",
    "app-claimed": "app-claimed",
    "remote": "remote-unverified",
}


class SealKeyError(Exception):
    pass


def key_path():
    path = os.environ.get("CCTRL_PEER_SEAL_KEY_FILE", "")
    if path:
        return path
    home = os.environ.get("HOME", "")
    if not home:
        raise SealKeyError("no-home")
    return os.path.join(home, ".local", "state", "cctrl", "peer-seal.key")


def _dir_private(directory):
    """The key dir must be a real directory owned by euid with no group or
    other bits (0700). A wide or foreign dir is never chmod'ed (the override
    can point anywhere, e.g. $HOME); the key is just treated as unusable, so
    sends go unsealed and `peer doctor` reports it."""
    try:
        info = os.lstat(directory)
    except OSError:
        return False
    return (stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid()
            and (info.st_mode & 0o077) == 0)


def read_key(path):
    # O_NONBLOCK: a FIFO (or other special file) at the key path must not
    # block the open; the fstat check below then refuses it. O_NOFOLLOW: a
    # symlink is refused (ELOOP), never followed.
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        raise
    except OSError:
        raise SealKeyError("unreadable")
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise SealKeyError("not-a-private-file")
        # A key file with any group/other bit may have been exposed (copied or
        # restored from a wider place): it stops verifying. Never chmod'ed.
        if info.st_mode & 0o077:
            raise SealKeyError("key-not-private")
        if not _dir_private(os.path.dirname(path) or "."):
            raise SealKeyError("dir-not-private")
        data = b""
        while len(data) <= KEY_LEN:
            chunk = os.read(fd, KEY_LEN + 1 - len(data))
            if not chunk:
                break
            data += chunk
    finally:
        os.close(fd)
    if len(data) != KEY_LEN:
        raise SealKeyError("bad-length")
    return data


def ensure_key(path):
    """Read the key, creating it once if absent. Never replaces a key."""
    try:
        return read_key(path)
    except FileNotFoundError:
        pass
    directory = os.path.dirname(path) or "."
    if not os.path.isdir(directory):
        try:
            os.makedirs(directory, mode=0o700)
            os.chmod(directory, 0o700)
        except FileExistsError:
            pass
    if not _dir_private(directory):
        raise SealKeyError("dir-not-private")
    # O_EXCL temp file in the key dir, mode 0600 from creation (never
    # readable by others), fully written and synced, then published with
    # link(2): link never replaces an existing name, so two first senders
    # cannot end up with different keys, and the final name never holds a
    # partial key.
    tmp = os.path.join(directory, "%s%d.%s%s" % (TMP_PREFIX, os.getpid(), os.urandom(4).hex(), TMP_SUFFIX))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        try:
            os.fchmod(fd, 0o600)
            data = os.urandom(KEY_LEN)
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        # The caller's time bound is a SIGALRM: held off between link and
        # unlink, so a kill can never leave the temp as a second hard link to
        # the live key (a pending alarm fires right after the unlink).
        _hold_alarm(True)
        try:
            os.link(tmp, path)
        except FileExistsError:
            pass
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        _hold_alarm(False)
    last = None
    for _ in range(5):
        try:
            return read_key(path)
        except (FileNotFoundError, SealKeyError) as exc:
            last = exc
            time.sleep(0.01)
    raise SealKeyError(str(last) or "unreadable")


def _hold_alarm(hold):
    try:
        signal.pthread_sigmask(signal.SIG_BLOCK if hold else signal.SIG_UNBLOCK, {signal.SIGALRM})
    except (AttributeError, OSError, ValueError):
        pass


def _stale_tmps(directory, sweep):
    """Temp files a killed first-key create left in the key dir: the pid in
    the name is gone, or the file is older than TMP_STALE_SECONDS. A live
    creator's fresh temp is never touched. With sweep, they are removed."""
    found = 0
    try:
        names = os.listdir(directory)
    except OSError:
        return 0
    now = time.time()
    for name in names:
        if not (name.startswith(TMP_PREFIX) and name.endswith(TMP_SUFFIX)):
            continue
        full = os.path.join(directory, name)
        try:
            info = os.lstat(full)
        except OSError:
            continue
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            continue
        alive = False
        try:
            pid = int(name[len(TMP_PREFIX):].split(".", 1)[0])
            os.kill(pid, 0)
            alive = True
        except (ValueError, ProcessLookupError):
            alive = False
        except PermissionError:
            alive = True
        except OSError:
            alive = False
        if alive and now - info.st_mtime < TMP_STALE_SECONDS:
            continue
        found += 1
        if sweep:
            try:
                os.unlink(full)
            except OSError:
                pass
    return found


def _text_digest(value):
    if isinstance(value, str):
        raw = b"s:" + value.encode("utf-8", errors="surrogatepass")
    else:
        raw = b"j:" + json.dumps(value, sort_keys=True, separators=(",", ":")).encode("ascii")
    return hashlib.sha256(raw).hexdigest()


def canonical(message, host_id):
    """The one canonical form: sorted keys, (",", ":"), ASCII escapes."""
    doc = {"seal_v": SEAL_VERSION, "host_id": host_id, "present": []}
    for field in SEALED_FIELDS:
        if field in message:
            doc["present"].append(field)
            doc[field] = message[field]
    for field in HASHED_FIELDS:
        if field in message:
            doc["present"].append(field)
            doc[field + "_sha256"] = _text_digest(message[field])
    attest = message.get("attest")
    if isinstance(attest, dict):
        # attest values as strings (a non-string value as its JSON text).
        doc["attest"] = {
            str(k): (v if isinstance(v, str) else json.dumps(v, sort_keys=True, separators=(",", ":")))
            for k, v in attest.items()
        }
    text = json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return DOMAIN + text.encode("ascii")


def mac_for(message, host_id, key):
    return hmac.new(key, canonical(message, host_id), hashlib.sha256).hexdigest()


def verify_one(message, host_id, key):
    out = {"verified": False, "level": None, "reason": None, "session": None, "host": None}
    if not isinstance(message, dict):
        out["reason"] = "legacy-unsealed"
        return out
    seal = message.get("seal")
    if not isinstance(seal, dict):
        out["reason"] = "legacy-unsealed"
        return out
    seal_host = seal.get("host_id")
    if isinstance(seal_host, str):
        out["host"] = seal_host
    mac = seal.get("mac")
    if seal.get("v") != SEAL_VERSION or not isinstance(mac, str) or not isinstance(seal_host, str):
        out["reason"] = "seal-mismatch"
        return out
    if not host_id:
        # This reader has no data/host-id, so it cannot tell which host
        # sealed the line: not evidence of another host.
        out["reason"] = "no-host-id"
        return out
    if seal_host != host_id:
        out["reason"] = "other-host-seal"
        return out
    if key is None:
        # Read-time reason unchanged (the plan: a lost key reads
        # seal-mismatch). The internal flag tells eligibility this is no
        # verdict on the line (key-unavailable), so a transient key problem
        # never records the mail as blocked (phase 5, p4 verify M1). cmd_verify
        # strips it from the output.
        out["reason"] = "seal-mismatch"
        out["_key_unavailable"] = True
        return out
    try:
        good = hmac.compare_digest(mac_for(message, seal_host, key), mac)
    except (TypeError, ValueError):
        good = False
    if not good:
        out["reason"] = "seal-mismatch"
        return out
    attest = message.get("attest")
    level = attest.get("level") if isinstance(attest, dict) else None
    if not isinstance(level, str):
        level = "none"
    out["level"] = level
    if level == "session":
        out["verified"] = True
        session = attest.get("session")
        out["session"] = session if isinstance(session, str) else None
    else:
        out["reason"] = LEVEL_REASON.get(level, "no-session")
    return out


def _status_edited(message):
    """status and history are outside the MAC. cctrl never moves a message
    back to queued, so a queued line that records a delivery or an ack was
    edited (a replay of acked mail)."""
    if message.get("status") != "queued":
        return False
    if message.get("delivered_at") or message.get("acked_at"):
        return True
    history = message.get("history")
    if isinstance(history, list):
        for entry in history:
            if isinstance(entry, dict) and entry.get("status") in ("delivered", "acked", "blocked"):
                return True
    return False


def _word_list(value):
    return isinstance(value, list) and all(isinstance(v, str) and v and not any(c.isspace() for c in v) for v in value)


def senders_for(allow, to):
    """The push allowlist that applies to mail addressed to `to`: a
    recipients.<to> override, else the default. None = malformed (matches
    nothing). No --allow at all = the built-in default."""
    if allow is None:
        return BUILTIN_SENDERS
    if not isinstance(allow, dict):
        return None
    recipients = allow.get("recipients")
    if recipients == "malformed":
        return None
    if isinstance(recipients, dict) and isinstance(to, str) and to in recipients:
        chosen = recipients[to]
    else:
        chosen = allow.get("default")
    if not isinstance(chosen, dict):
        return None
    roles, peers = chosen.get("roles", []), chosen.get("peers", [])
    if not (_word_list(roles) and _word_list(peers)):
        return None
    return {"roles": roles, "peers": peers}


def sender_allowed(senders, sender, attest):
    """By role (fleet-manager also matches role orchestrator with orch_kind
    fleet) or by name (the sealed `from`, or the attested session)."""
    if not isinstance(senders, dict):
        return False
    role = attest.get("role") if isinstance(attest.get("role"), str) else ""
    kind = attest.get("orch_kind") if isinstance(attest.get("orch_kind"), str) else ""
    roles, peers = senders["roles"], senders["peers"]
    if role and (role in roles or ("fleet-manager" in roles and role == "orchestrator" and kind == "fleet")):
        return True
    session = attest.get("session") if isinstance(attest.get("session"), str) else ""
    for name in (sender if isinstance(sender, str) else "", session):
        if name and name in peers:
            return True
    return False


def eligibility_one(message, ver, dup_ids, since, allow=None):
    """Plan 111 phase 3, per message: push needs a verified seal, level
    session, no replay sign, sealed created_at after `since`, and a sender on
    the recipient's push allowlist (phase 4: `allow`, see senders_for); the
    Stop bell also admits workers. Only sealed fields decide, except the
    replay checks, which can only take eligibility away."""
    out = {"push": False, "bell": False, "reason": "sender-unattested", "detail": None}
    if not isinstance(message, dict) or not ver.get("verified"):
        out["detail"] = ("key-unavailable" if ver.get("_key_unavailable")
                         else (ver.get("reason") or "legacy-unsealed"))
        return out
    mid = message.get("id")
    if not isinstance(mid, str) or mid in dup_ids:
        out["detail"] = "duplicate-id"
        return out
    if _status_edited(message):
        out["detail"] = "status-edited"
        return out
    if since == "invalid":
        out["detail"] = "attestation-since-invalid"
        return out
    created = message.get("created_at")
    if since and not (isinstance(created, str) and created > since):
        out["detail"] = "before-attestation-since"
        return out
    attest = message.get("attest") if isinstance(message.get("attest"), dict) else {}
    role = attest.get("role") if isinstance(attest.get("role"), str) else ""
    senders = senders_for(allow, message.get("to"))
    if sender_allowed(senders, message.get("from"), attest):
        out.update(push=True, bell=True, reason=None)
        return out
    out["reason"] = "sender-not-allowed"
    out["detail"] = "allowlist-malformed" if senders is None else "role:" + (role or "none")
    if role in BELL_ONLY_ROLES:
        out["bell"] = True
    return out


def _dup_ids(messages):
    seen, dups = set(), set()
    for m in messages:
        if isinstance(m, dict):
            mid = m.get("id")
            if isinstance(mid, str):
                if mid in seen:
                    dups.add(mid)
                seen.add(mid)
    return dups


def _load_key_or_none():
    try:
        return read_key(key_path())
    except (OSError, SealKeyError):
        return None


def _read_messages():
    doc = json.loads(sys.stdin.read() or "[]")
    if isinstance(doc, dict):
        doc = [doc]
    if not isinstance(doc, list):
        raise ValueError("expected a JSON array")
    return doc


def cmd_seal(host_id):
    if not host_id:
        return 2
    message = json.loads(sys.stdin.read())
    if not isinstance(message, dict):
        return 2
    path = key_path()
    key = ensure_key(path)
    sys.stdout.write(mac_for(message, host_id, key) + "\n")
    sys.stdout.flush()
    # Leftovers of a first-key create killed by the time bound.
    _stale_tmps(os.path.dirname(path) or ".", True)
    return 0


def cmd_verify(host_id, opts):
    eligibility = False
    since = ""
    allow = None
    seen = set()
    if opts:
        if len(opts) % 2 or opts[0] != "--eligibility":
            return 64
        eligibility, since = True, opts[1]
        rest = opts[2:]
        while rest:
            flag, value = rest[0], rest[1]
            rest = rest[2:]
            if flag == "--allow":
                try:
                    allow = json.loads(value)
                except ValueError:
                    allow = "malformed"
                if allow is None:
                    allow = "malformed"
            elif flag == "--seen":
                # Phase 5 (replay, p3 verify ruling 2): ids already in
                # messages-archive.jsonl (`peer gc`). A queued line with such
                # an id is a verbatim replay of archived mail: duplicate-id.
                try:
                    ids = json.loads(value)
                except ValueError:
                    return 64
                if not isinstance(ids, list):
                    return 64
                seen = set(i for i in ids if isinstance(i, str))
            else:
                return 64
    messages = _read_messages()
    key = _load_key_or_none()
    results = [verify_one(m, host_id, key) for m in messages]
    if eligibility:
        dups = _dup_ids(messages) | seen
        for m, ver in zip(messages, results):
            ver["eligibility"] = eligibility_one(m, ver, dups, since, allow)
    for ver in results:
        ver.pop("_key_unavailable", None)
    sys.stdout.write(json.dumps(results, separators=(",", ":")) + "\n")
    return 0


def cmd_doctor(host_id):
    messages = _read_messages()
    status = {"exists": False, "mode": None, "usable": False}
    try:
        path = key_path()
        status["path"] = path
        try:
            info = os.lstat(path)
            status["exists"] = True
            status["mode"] = "%04o" % stat.S_IMODE(info.st_mode)
            status["private"] = stat.S_ISREG(info.st_mode) and (info.st_mode & 0o077) == 0
        except FileNotFoundError:
            pass
        except OSError:
            status["exists"] = None
        directory = os.path.dirname(path) or "."
        try:
            dinfo = os.lstat(directory)
            status["dir_mode"] = "%04o" % stat.S_IMODE(dinfo.st_mode)
            status["dir_private"] = _dir_private(directory)
            status["dir_symlink"] = stat.S_ISLNK(dinfo.st_mode)
        except OSError:
            pass
        status["stale_tmp"] = _stale_tmps(directory, False)
    except SealKeyError as exc:
        status["error"] = str(exc)
    key = _load_key_or_none()
    status["usable"] = key is not None
    counts = {"verified": 0}
    sealed = 0
    for message in messages:
        result = verify_one(message, host_id, key)
        if isinstance(message, dict) and isinstance(message.get("seal"), dict):
            sealed += 1
        if result["verified"]:
            counts["verified"] += 1
        else:
            counts[result["reason"]] = counts.get(result["reason"], 0) + 1
    sys.stdout.write(json.dumps({"key": status, "sealed": sealed, "total": len(messages), "reasons": counts},
                                sort_keys=True, separators=(",", ":")) + "\n")
    return 0


ID_PREFIX = b'{"id":"'


def _line_id(line):
    """The top-level `id` of one archive line, or None. `peer gc` writes
    lines with `jq -c`, which keeps the message's key order, so `id` comes
    first: read it without parsing the line. Any other shape (another key
    order, an escaped id) is parsed in full, so no archived id is missed."""
    if line.startswith(ID_PREFIX):
        end = line.find(b'"', len(ID_PREFIX))
        if end > 0:
            raw = line[len(ID_PREFIX):end]
            if b"\\" not in raw:
                return raw
    elif b'"id"' not in line:
        return None
    try:
        doc = json.loads(line.decode("utf-8", errors="surrogatepass"))
    except ValueError:
        return None
    mid = doc.get("id") if isinstance(doc, dict) else None
    if not isinstance(mid, str):
        return None
    return mid.encode("utf-8", errors="surrogatepass")


def cmd_seen(archive):
    wanted = json.loads(sys.stdin.read() or "[]")
    if not isinstance(wanted, list):
        raise ValueError("expected a JSON array")
    want = set(i.encode("utf-8", errors="surrogatepass") for i in wanted if isinstance(i, str) and i)
    hits = set()
    if want:
        try:
            # O_NONBLOCK: a FIFO at the path must not block; fstat refuses it.
            fd = os.open(archive, os.O_RDONLY | os.O_NONBLOCK)
        except FileNotFoundError:
            fd = None
        if fd is not None:
            with os.fdopen(fd, "rb") as handle:
                if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
                    raise ValueError("archive is not a regular file")
                for line in handle:
                    mid = _line_id(line)
                    if mid is not None and mid in want:
                        hits.add(mid)
    out = sorted(h.decode("utf-8", errors="surrogatepass") for h in hits)
    sys.stdout.write(json.dumps(out, separators=(",", ":")) + "\n")
    return 0


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: peer_seal.py seal|verify|doctor <host_id> | seen <archive>\n")
        return 64
    mode, host_id = argv[1], (argv[2] if len(argv) > 2 else "")
    try:
        if mode == "seal":
            return cmd_seal(host_id)
        if mode == "verify":
            return cmd_verify(host_id, argv[3:])
        if mode == "doctor":
            return cmd_doctor(host_id)
        if mode == "seen":
            return cmd_seen(host_id)
    except (OSError, ValueError, SealKeyError) as exc:
        # Never echo key material: only the exception class.
        sys.stderr.write("peer_seal: %s failed (%s)\n" % (mode, type(exc).__name__))
        return 1
    sys.stderr.write("peer_seal: unknown mode\n")
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
