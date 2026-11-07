"""Per-host HMAC seal for peer mail (plan 111 phase 2).

Run as `python3 -I -S peer_seal.py <mode> ...`. The key never touches argv,
env, stdout, stderr or a log: this helper reads the key file itself and only
ever prints MACs (which are not secret) and verification facts.

Modes:
  seal <host_id>    stdin: one message object. stdout: the hex MAC.
                    Creates the key on first use (atomic, create-once).
  verify <host_id>  stdin: a JSON array of messages. stdout: a JSON array of
                    verification objects, one per message, same order.
                    Never creates the key.
  doctor <host_id>  stdin: a JSON array of messages. stdout: one JSON object
                    with the key status (path, exists, mode; never the key)
                    and verification counts. Never creates the key.

This is a same-uid misuse barrier, not authentication: any process running as
this user can read the key file.

Key file: $CCTRL_PEER_SEAL_KEY_FILE, else $HOME/.local/state/cctrl/peer-seal.key
(pinned, not XDG_STATE_HOME, so every caller on the host resolves one file).
32 random bytes, file 0600, dir 0700.
"""
import hashlib
import hmac
import json
import os
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


def read_key(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        raise
    except OSError:
        raise SealKeyError("unreadable")
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise SealKeyError("not-a-private-file")
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
    # O_EXCL temp file in the key dir, mode 0600 from creation (never
    # readable by others), fully written and synced, then published with
    # link(2): link never replaces an existing name, so two first senders
    # cannot end up with different keys, and the final name never holds a
    # partial key.
    tmp = os.path.join(directory, ".peer-seal.%d.%s.tmp" % (os.getpid(), os.urandom(4).hex()))
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
        try:
            os.link(tmp, path)
        except FileExistsError:
            pass
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    last = None
    for _ in range(5):
        try:
            return read_key(path)
        except (FileNotFoundError, SealKeyError) as exc:
            last = exc
            time.sleep(0.01)
    raise SealKeyError(str(last) or "unreadable")


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
    if not host_id or seal_host != host_id:
        out["reason"] = "other-host-seal"
        return out
    if key is None:
        out["reason"] = "seal-mismatch"
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
    key = ensure_key(key_path())
    sys.stdout.write(mac_for(message, host_id, key) + "\n")
    return 0


def cmd_verify(host_id):
    messages = _read_messages()
    key = _load_key_or_none()
    sys.stdout.write(json.dumps([verify_one(m, host_id, key) for m in messages], separators=(",", ":")) + "\n")
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
            try:
                dinfo = os.stat(os.path.dirname(path) or ".")
                status["dir_mode"] = "%04o" % stat.S_IMODE(dinfo.st_mode)
            except OSError:
                pass
        except FileNotFoundError:
            pass
        except OSError:
            status["exists"] = None
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


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: peer_seal.py seal|verify|doctor <host_id>\n")
        return 64
    mode, host_id = argv[1], (argv[2] if len(argv) > 2 else "")
    try:
        if mode == "seal":
            return cmd_seal(host_id)
        if mode == "verify":
            return cmd_verify(host_id)
        if mode == "doctor":
            return cmd_doctor(host_id)
    except (OSError, ValueError, SealKeyError) as exc:
        # Never echo key material: only the exception class.
        sys.stderr.write("peer_seal: %s failed (%s)\n" % (mode, type(exc).__name__))
        return 1
    sys.stderr.write("peer_seal: unknown mode\n")
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
