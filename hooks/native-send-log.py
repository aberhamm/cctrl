#!/usr/bin/env python3
"""Plan 114 (b): host-local log of built-in SendMessage calls (sender side).

Hook mode (no arguments; run as `cctrl hooks run native-send-log` from a
PreToolUse and a PostToolUse entry with matcher "SendMessage"):
appends one JSONL line per phase to

    $CCTRL_NSL_DATA_DIR/native-sends.<host-id>.jsonl   (mode 0600)

The body is NEVER stored: no text, no first line, no `summary`, no raw
tool_response. What is kept: who sent, to whom, when, the outcome, the body
size, any cctrl message ids, and an HMAC-SHA256 of the exact body under a
per-host key ($CCTRL_NSL_DATA_DIR/native-sends.key, 0600, 32 random bytes).

Fail open, always: any problem exits 0 with no stdout and no stderr (hook
output can reach the model; a logging hook must never inject text or block a
send). A 1 s wall-clock budget is enforced. No tmux, no network, no socket,
no Claude session *.key file, no environment dump.

Reader mode (`--read ...`, used by `cctrl peer native-log`): read-only, joins
pre/post lines by tool_use_id and prints them.
"""

import os
import sys

MAX_LINE = 2048
MAX_TO = 300
MAX_IDS = 20
MSG_ID_RE = r"msg_\d{8}_\d{6}_[0-9a-f]{6}"


def _silence():
    try:
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, 1)
        os.dup2(devnull, 2)
        os.close(devnull)
    except OSError:
        pass


def _budget(seconds):
    try:
        import signal

        def _out(_signum, _frame):
            os._exit(0)

        signal.signal(signal.SIGALRM, _out)
        signal.setitimer(signal.ITIMER_REAL, seconds)
    except Exception:
        pass


def host_id(id_file):
    """The cctrl host id (read only, never created), else a nodename id."""
    import re

    try:
        if id_file and os.path.isfile(id_file) and not os.path.islink(id_file):
            with open(id_file, encoding="ascii") as stream:
                value = stream.read().strip()
            if re.fullmatch(r"[0-9a-f]{32}", value):
                return value
    except Exception:
        pass
    node = os.uname().nodename.split(".")[0] or "unknown"
    return "node-" + re.sub(r"[^A-Za-z0-9-]", "-", node)[:64]


def _key(data_dir):
    path = os.path.join(data_dir, "native-sends.key")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            os.write(fd, os.urandom(32))
        finally:
            os.close(fd)
    except FileExistsError:
        pass
    except OSError:
        return None
    try:
        fd = os.open(path, flags)
        try:
            import stat

            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or (st.st_mode & 0o077):
                return None
            key = os.read(fd, 64)
        finally:
            os.close(fd)
    except OSError:
        return None
    return key if len(key) == 32 else None


def _ps_ppid(pid):
    import subprocess

    try:
        out = subprocess.run(
            ["ps", "-o", "ppid=", "-p", str(pid)],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=0.5, check=False,
        ).stdout.decode("ascii", "replace").strip()
        return int(out) if out.isdigit() else None
    except Exception:
        return None


def _sender(sessions_dir, session_id):
    """First ancestor (<= 8 levels) with a Claude session file."""
    import json

    sender = {"pid": None, "session_id": session_id if isinstance(session_id, str) else None,
              "tmux": None, "socket": None}
    if not sessions_dir:
        return sender
    pid = os.getppid()
    for _ in range(8):
        if not pid or pid <= 1:
            break
        path = os.path.join(sessions_dir, "%d.json" % pid)
        if os.path.isfile(path) and not os.path.islink(path):
            sender["pid"] = pid
            try:
                with open(path, encoding="utf-8") as stream:
                    doc = json.load(stream)
                if isinstance(doc, dict):
                    if isinstance(doc.get("tmux"), str):
                        sender["tmux"] = doc["tmux"][:200]
                    if isinstance(doc.get("messagingSocketPath"), str):
                        sender["socket"] = doc["messagingSocketPath"][:200]
                    if sender["session_id"] is None and isinstance(doc.get("sessionId"), str):
                        sender["session_id"] = doc["sessionId"][:80]
            except Exception:
                pass
            break
        pid = _ps_ppid(pid)
    return sender


def _to_kind(to):
    import re

    if to == "main":
        return "main"
    if re.fullmatch(r"a[0-9a-z]*-[0-9a-z-]+", to):
        return "agent-id"
    if to.startswith(("uds:", "bridge:")) or re.search(r"\(TMUX--[^)]*\)|\[[0-9a-f]{6}\]$", to):
        return "session"
    if "@" in to:
        return "teammate"
    return "unknown"


def _outcome(response):
    import json

    if response is None:
        return "unknown"
    try:
        text = response if isinstance(response, str) else json.dumps(response, sort_keys=True)
    except Exception:
        return "unknown"
    text = text.lower()
    for outcome, words in (
        ("held", ("held", "awaiting approval", "pending approval", "requires approval")),
        ("refused", ("refused", "denied", "rejected", "not allowed", "blocked")),
        ("offline", ("offline", "not connected", "no such", "not found", "unreachable")),
        ("error", ("error", "failed", "failure")),
        ("sent", ("sent", "delivered", "success", "queued")),
    ):
        if any(word in text for word in words):
            return outcome
    return "unknown"


def _append(data_dir, host, record):
    import fcntl
    import json
    import stat

    line = json.dumps(record, separators=(",", ":"), ensure_ascii=True)
    if len(line) + 1 > MAX_LINE:
        record["msg_ids"] = []
        record["truncated"] = True
        line = json.dumps(record, separators=(",", ":"), ensure_ascii=True)
        if len(line) + 1 > MAX_LINE:
            return
    data = (line + "\n").encode("ascii")
    try:
        max_bytes = int(os.environ.get("CCTRL_NATIVE_LOG_MAX_BYTES", "") or 10 * 1024 * 1024)
    except ValueError:
        max_bytes = 10 * 1024 * 1024
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    log = os.path.join(data_dir, "native-sends.%s.jsonl" % host)
    lock = log + ".lock"
    os.umask(0o077)
    lfd = os.open(lock, os.O_WRONLY | os.O_CREAT | nofollow, 0o600)
    try:
        fcntl.flock(lfd, fcntl.LOCK_EX)
        try:
            st = os.lstat(log)
            if stat.S_ISREG(st.st_mode) and st.st_size >= max_bytes:
                os.replace(log, log + ".1")
        except FileNotFoundError:
            pass
        fd = os.open(log, os.O_WRONLY | os.O_APPEND | os.O_CREAT | nofollow, 0o600)
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
                return
            if st.st_mode & 0o077:
                os.fchmod(fd, 0o600)
            os.write(fd, data)
        finally:
            os.close(fd)
    finally:
        os.close(lfd)


def hook():
    _silence()
    _budget(1.0)
    import datetime
    import hashlib
    import hmac
    import json
    import re

    data_dir = os.environ.get("CCTRL_NSL_DATA_DIR", "")
    if not data_dir or not os.path.isdir(data_dir):
        return
    raw = sys.stdin.buffer.read(1024 * 1024)
    payload = json.loads(raw.decode("utf-8"))
    if not isinstance(payload, dict) or payload.get("tool_name") != "SendMessage":
        return
    event = payload.get("hook_event_name")
    phase = {"PreToolUse": "pre", "PostToolUse": "post"}.get(event)
    if phase is None:
        return
    tool_use_id = payload.get("tool_use_id")
    tool_use_id = tool_use_id[:120] if isinstance(tool_use_id, str) else None
    host = host_id(os.environ.get("CCTRL_NSL_HOST_ID_FILE", ""))
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    session_id = payload.get("session_id")
    session_id = session_id[:80] if isinstance(session_id, str) else None
    record = {"v": 1, "ts": now, "phase": phase, "tool_use_id": tool_use_id, "host": host}
    if phase == "post":
        record["session_id"] = session_id
        record["outcome"] = _outcome(payload.get("tool_response"))
        _append(data_dir, host, record)
        return

    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}
    to = tool_input.get("to")
    to = " ".join(to.split())[:MAX_TO] if isinstance(to, str) else ""
    message = tool_input.get("message")
    if message is None:
        text = ""
    elif isinstance(message, str):
        text = message
    else:
        text = json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    body = text.encode("utf-8", "surrogatepass")
    key = _key(data_dir)
    notify = tool_input.get("notify_when_idle") is True
    ids = []
    for match in re.findall(MSG_ID_RE, text):
        if match not in ids:
            ids.append(match)
    if text == "" and notify:
        kind = "subscription"
    elif ids and len(text) <= 400 and re.search(r"(?i)\b(new|mail|messages?|recv|inbox)\b", text):
        kind = "bell"
    else:
        kind = "note"
    record.update({
        "sender": _sender(os.environ.get("CCTRL_NSL_SESSIONS_DIR", ""), session_id),
        "to": to,
        "to_kind": _to_kind(to),
        "notify_when_idle": notify,
        "body": {
            "chars": len(text),
            "lines": (text.count("\n") + 1) if text else 0,
            "hmac": hmac.new(key, body, hashlib.sha256).hexdigest() if key else None,
        },
        "msg_ids": ids[:MAX_IDS],
        "kind": kind,
    })
    _append(data_dir, host, record)


def read(argv):
    """Read-only: print joined pre/post records for this host (newest last)."""
    import argparse
    import json

    parser = argparse.ArgumentParser(prog="cctrl peer native-log", add_help=True)
    parser.add_argument("--read", action="store_true")
    parser.add_argument("--since", default="")
    parser.add_argument("--to", default="")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.limit < 1:
        parser.error("--limit must be >= 1")
    data_dir = os.environ.get("CCTRL_NSL_DATA_DIR", "")
    host = host_id(os.environ.get("CCTRL_NSL_HOST_ID_FILE", ""))
    log = os.path.join(data_dir, "native-sends.%s.jsonl" % host)
    pres, posts, order = {}, {}, []
    for path in (log + ".1", log):
        try:
            with open(path, encoding="utf-8", errors="replace") as stream:
                lines = stream.readlines()
        except OSError:
            continue
        for n, line in enumerate(lines):
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not isinstance(rec, dict) or rec.get("v") != 1:
                continue
            key = rec.get("tool_use_id") or "%s:%d" % (path, n)
            if rec.get("phase") == "pre":
                if key not in pres:
                    order.append(key)
                pres[key] = rec
            elif rec.get("phase") == "post":
                posts[key] = rec
    rows = []
    for key in order:
        pre = pres[key]
        if args.since and str(pre.get("ts", "")) < args.since:
            continue
        if args.to and pre.get("to") != args.to:
            continue
        post = posts.get(key) or {}
        rows.append({
            "ts": pre.get("ts"), "tool_use_id": pre.get("tool_use_id"), "host": pre.get("host"),
            "sender": pre.get("sender"), "to": pre.get("to"), "to_kind": pre.get("to_kind"),
            "kind": pre.get("kind"), "notify_when_idle": pre.get("notify_when_idle"),
            "body": pre.get("body"), "msg_ids": pre.get("msg_ids") or [],
            "outcome": post.get("outcome", "pending"), "outcome_ts": post.get("ts"),
        })
    rows = rows[-args.limit:]
    if args.json:
        print(json.dumps({"ok": True, "host": host, "log": log, "count": len(rows), "sends": rows}))
        return 0
    if not rows:
        print("no native sends logged (%s)" % log)
        return 0
    for row in rows:
        sender = row.get("sender") or {}
        who = sender.get("tmux") or (("pid %s" % sender["pid"]) if sender.get("pid") else (sender.get("session_id") or "-"))
        body = row.get("body") or {}
        print("%s  %-8s %-6s %-12s to=%s  from=%s  chars=%s  ids=%s" % (
            row.get("ts"), row.get("outcome"), row.get("kind"), row.get("to_kind"), row.get("to"),
            who, body.get("chars"), ",".join(row.get("msg_ids") or []) or "-"))
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--read":
        sys.exit(read(sys.argv[1:]))
    try:
        hook()
    except BaseException:
        pass
    os._exit(0)
