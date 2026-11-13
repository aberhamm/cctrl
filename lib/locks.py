#!/usr/bin/env python3
"""Mailbox-compatible file locks and the migration sentinel (plan 116, A1).

The protocol is macOS shlock's, on the same path the installed release uses:

  * the lock is the file <target>.lock, holding the owner's pid;
  * it is created by writing a temp file next to it and link(2)ing that file to
    the lock path (link fails with EEXIST when someone holds it);
  * a lock is stale only when its pid is dead, or the process with that pid
    started after the lock's mtime (pid reuse). Age never makes a lock stale: a
    live holder may be SIGSTOPped or asleep, and taking its lock would lose
    every write made meanwhile. A long hold is a doctor warning, nothing more;
  * release unlinks only when the file still holds our pid.

Stale steal (review S9). Stealers serialise on <lock>.steal (same link
protocol, 5 s cap). Under it: judge stale, rename the lock aside, stat the aside
file; same inode -> unlink it and link our temp file in (EEXIST: someone
acquired legitimately, go back to waiting); different inode (a lock taken after
our check, which can only happen next to the system shlock's own stale
handling) -> link the aside file back; if that fails with EEXIST a third
process holds the path, so we do NOT acquire, leave the aside file for doctor,
write a lock-steal-collision record, and go back to waiting.

lib/locks.sh does not exist: the bash twin lives in cctrl (_cctrl_lock_*). Both
must keep to this file's protocol. Standard library only.

Library use:
    import locks
    with locks.locked("/path/messages.jsonl", timeout=10):
        ...
    locks.sentinel_wait(state_root, max_wait=5, kind="hook")

Command line:
    locks.py hold FILE SECONDS     acquire, print "held <pid>", sleep, release
    locks.py status FILE           print JSON about the lock (for doctor, tests)
    locks.py sentinel STATE_ROOT   print JSON about <state root>/.migrating
    locks.py sentinel-message STATE_ROOT   the exit-75 text, on stderr
"""

import contextlib
import errno
import json
import os
import re
import socket
import subprocess
import sys
import time

WARN_AGE_SECONDS = 120
GUARD_CAP_SECONDS = 5.0
POLL_SECONDS = 0.1
START_SLACK_SECONDS = 2
EX_TEMPFAIL = 75


class LockTimeout(Exception):
    pass


class Migrating(Exception):
    """The migration sentinel is present and the wait ran out."""

    def __init__(self, message):
        Exception.__init__(self, message)
        self.message = message


def lock_path(target):
    return target + ".lock"


def _test_mode():
    if os.environ.get("CCTRL_TEST_MODE") != "1":
        return False
    try:
        sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
        import paths
        ok, _reason = paths.test_mode(paths.resolve())
        return ok is True
    except Exception:
        return False


def warn_age():
    """The doctor's hold-age warning threshold; shortened only under test mode."""
    raw = os.environ.get("CCTRL_TEST_LOCK_WARN_AGE")
    if raw and raw.isdigit() and _test_mode():
        return int(raw)
    return WARN_AGE_SECONDS


def pid_alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError as e:
        # EPERM: it exists but belongs to someone else.
        return e.errno == errno.EPERM


_ETIME = re.compile(r"^\s*(?:(?:(\d+)-)?(\d+):)?(\d+):(\d+)\s*$")


def pid_start_epoch(pid):
    """Epoch seconds when pid started, from `ps -o etime=`, or None."""
    try:
        out = subprocess.run(
            ["ps", "-o", "etime=", "-p", str(pid)],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5,
        ).stdout.decode("ascii", "replace")
    except (OSError, subprocess.SubprocessError):
        return None
    m = _ETIME.match(out)
    if not m:
        return None
    days, hours, mins, secs = (int(x or 0) for x in m.groups())
    return time.time() - (((days * 24 + hours) * 60 + mins) * 60 + secs)


def read_pid(path):
    """(pid, stat_result) of a lock file, pid None if unparseable; (None, None) if gone."""
    try:
        # fstat the open fd: the inode and mtime of the file actually read, with
        # no second path lookup a swap could slip between (review S3).
        with open(path, "rb") as f:
            raw = f.read(64)
            st = os.fstat(f.fileno())
    except OSError:
        return None, None
    m = re.match(rb"^\s*(\d+)\s*$", raw)
    return (int(m.group(1)) if m else None), st


def judge_stale(path):
    """(stale, reason, pid, st). Stale only for a dead pid, an unparseable pid
    (a corrupt file; the link protocol never publishes a half-written one), or
    pid reuse. Never by age."""
    pid, st = read_pid(path)
    if st is None:
        return False, "gone", None, None
    if pid is None:
        return True, "corrupt", None, st
    if not pid_alive(pid):
        return True, "dead", pid, st
    started = pid_start_epoch(pid)
    if started is not None and started > st.st_mtime + START_SLACK_SECONDS:
        return True, "pid-reuse", pid, st
    return False, "live", pid, st


def _new_tmp(lock):
    """A temp file next to the lock holding our pid, 0600. Returns its path."""
    base = "%s.%d.%s.tmp" % (lock, os.getpid(), os.urandom(4).hex())
    fd = os.open(base, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, ("%10d\n" % os.getpid()).encode("ascii"))
    finally:
        os.close(fd)
    return base


def _try_link(tmp, lock):
    try:
        os.link(tmp, lock)
        return True
    except OSError as e:
        if e.errno in (errno.EEXIST, errno.ENOENT):
            return False
        raise


def _hook(name, lock, extra=()):
    """Test-mode fault hook: CCTRL_TEST_STEAL_HOOK is run as HOOK LOCK STAGE
    [ASIDE] at stage after-judge (stale judged, before the rename) and
    after-aside (renamed away, before the inode check)."""
    cmd = os.environ.get("CCTRL_TEST_STEAL_HOOK")
    if cmd and _test_mode():
        subprocess.call([cmd, lock, name] + list(extra))


def _record_collision(lock, aside, note):
    rec = {
        "kind": "lock-steal-collision", "lock": lock, "aside": aside,
        "pid": os.getpid(), "host": socket.gethostname(), "note": note,
        "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    try:
        fd = os.open(lock + ".collisions", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, (json.dumps(rec) + "\n").encode("utf-8"))
        finally:
            os.close(fd)
    except OSError:
        pass


def _simple_acquire(lock, cap):
    """The steal guard: link protocol, dead-pid takeover, `cap` seconds."""
    tmp = _new_tmp(lock)
    deadline = time.monotonic() + cap
    try:
        while True:
            if _try_link(tmp, lock):
                return True
            stale, _r, _p, _st = judge_stale(lock)
            if stale:
                with contextlib.suppress(OSError):
                    os.unlink(lock)
                continue
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.02)
    finally:
        with contextlib.suppress(OSError):
            os.unlink(tmp)


def _release_path(lock, pid):
    p, _st = read_pid(lock)
    if p != pid:
        return False
    with contextlib.suppress(OSError):
        os.unlink(lock)
    return True


def _steal(lock, tmp):
    """One steal attempt. True when we now hold the lock."""
    guard = lock + ".steal"
    if not _simple_acquire(guard, GUARD_CAP_SECONDS):
        return False
    try:
        stale, _reason, _pid, st = judge_stale(lock)
        if not stale:
            return False
        _hook("after-judge", lock)
        aside = "%s.aside.%d.%s" % (lock, os.getpid(), os.urandom(4).hex())
        try:
            os.rename(lock, aside)
        except OSError:
            return False
        _hook("after-aside", lock, [aside])
        try:
            ast = os.stat(aside)
        except OSError:
            return False
        if ast.st_ino == st.st_ino:
            with contextlib.suppress(OSError):
                os.unlink(aside)
            return _try_link(tmp, lock)
        # Found live: put it back.
        try:
            os.link(aside, lock)
        except OSError as e:
            if e.errno == errno.EEXIST:
                _record_collision(lock, aside, "third process holds the lock path")
            return False
        with contextlib.suppress(OSError):
            os.unlink(aside)
        return False
    finally:
        _release_path(guard, os.getpid())


def acquire(target, timeout=10.0, pid=None):
    """Take <target>.lock. Returns the lock path. Raises LockTimeout."""
    lock = lock_path(target)
    me = pid if pid is not None else os.getpid()
    if me != os.getpid():
        raise ValueError("acquire on behalf of another pid is not supported")
    deadline = time.monotonic() + timeout
    tmp = _new_tmp(lock)
    try:
        while True:
            if os.path.isdir(lock) and not os.path.islink(lock):
                _legacy_dir_lock(lock)
            if _try_link(tmp, lock):
                return lock
            stale, _r, _p, _st = judge_stale(lock)
            if stale and _steal(lock, tmp):
                return lock
            if time.monotonic() >= deadline:
                raise LockTimeout("timed out waiting for %s" % lock)
            time.sleep(POLL_SECONDS)
    finally:
        with contextlib.suppress(OSError):
            os.unlink(tmp)


def _legacy_dir_lock(lock):
    """A lock directory left by the old CCTRL_MAILBOX_LOCK_KIND=dir fallback:
    remove it when its pid is dead (or there is none), else leave it."""
    try:
        with open(os.path.join(lock, "pid"), "rb") as f:
            pid = int(f.read(32).strip() or 0)
    except (OSError, ValueError):
        pid = 0
    if not pid_alive(pid):
        import shutil
        shutil.rmtree(lock, ignore_errors=True)


def release(lock, pid=None):
    """Unlink the lock only if it still holds our pid. True if released."""
    return _release_path(lock, pid if pid is not None else os.getpid())


@contextlib.contextmanager
def locked(target, timeout=10.0):
    lock = acquire(target, timeout)
    try:
        yield lock
    finally:
        release(lock)


def status(target):
    """JSON-able facts for doctor and tests."""
    lock = lock_path(target)
    out = {"lock": lock, "held": False, "pid": None, "alive": None,
           "age_seconds": None, "stale": False, "warn": False,
           "collisions": 0, "asides": 0}
    d = os.path.dirname(lock) or "."
    try:
        names = os.listdir(d)
    except OSError:
        names = []
    base = os.path.basename(lock)
    out["asides"] = sum(1 for n in names if n.startswith(base + ".aside."))
    try:
        with open(lock + ".collisions", "rb") as f:
            out["collisions"] = sum(1 for _ in f)
    except OSError:
        pass
    if os.path.isdir(lock):
        out["held"] = True
        out["legacy_dir"] = True
        return out
    stale, reason, pid, st = judge_stale(lock)
    if st is None:
        return out
    out["held"] = True
    out["pid"] = pid
    out["alive"] = bool(pid and pid_alive(pid))
    out["age_seconds"] = max(0, int(time.time() - st.st_mtime))
    out["stale"] = bool(stale)
    out["stale_reason"] = reason
    out["warn"] = bool(not stale and out["age_seconds"] > warn_age())
    if pid and out["alive"]:
        with contextlib.suppress(Exception):
            out["command"] = subprocess.run(
                ["ps", "-o", "command=", "-p", str(pid)],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5,
            ).stdout.decode("utf-8", "replace").strip()[:200]
    return out


# --- migration sentinel (plan 116 A1, MUST-FIX 2, R3-S5, R3-S8) -------------

def sentinel_path(state_root):
    return os.path.join(state_root, ".migrating")


def sentinel_info(state_root):
    """None when absent, else a dict: pid, pid_start, host, step, created_at
    (as recorded), age_seconds, owner_alive."""
    path = sentinel_path(state_root)
    try:
        st = os.lstat(path)
    except OSError:
        return None
    info = {"path": path, "pid": None, "pid_start": None, "host": None,
            "step": None, "created_at": None}
    try:
        with open(path, "rb") as f:
            doc = json.loads(f.read(4096).decode("utf-8", "replace") or "{}")
        if isinstance(doc, dict):
            for k in ("pid", "pid_start", "host", "step", "created_at"):
                info[k] = doc.get(k)
    except (OSError, ValueError):
        pass
    info["age_seconds"] = max(0, int(time.time() - st.st_mtime))
    pid = info["pid"]
    same_host = info["host"] in (None, socket.gethostname())
    info["owner_alive"] = bool(isinstance(pid, int) and same_host and pid_alive(pid))
    return info


def sentinel_message(info):
    owner = "alive" if info["owner_alive"] else "not running"
    return (
        "state-migrating: %s exists (pid %s %s, step %s, age %ss). "
        "Wait for the migration to finish, or resume it with `cctrl state migrate --apply`, "
        "or undo it with `cctrl state migrate --rollback`."
        % (info["path"], info["pid"], owner, info["step"], info["age_seconds"])
    )


def sentinel_wait(state_root, max_wait=120.0, kind="cli"):
    """Block while the sentinel exists. Returns True when clear. On timeout a
    CLI writer gets Migrating (exit 75); a hook (kind="hook") gets False and
    should skip its write."""
    deadline = time.monotonic() + max_wait
    while True:
        info = sentinel_info(state_root)
        if info is None:
            return True
        if time.monotonic() >= deadline:
            if kind == "hook":
                return False
            raise Migrating(sentinel_message(info))
        time.sleep(0.2)


def _main(argv):
    if len(argv) >= 3 and argv[1] == "hold":
        lock = acquire(argv[2], 30)
        print("held %d" % os.getpid(), flush=True)
        time.sleep(float(argv[3]) if len(argv) > 3 else 1)
        release(lock)
        return 0
    if len(argv) == 3 and argv[1] == "status":
        print(json.dumps(status(argv[2])))
        return 0
    if len(argv) == 3 and argv[1] == "sentinel":
        print(json.dumps(sentinel_info(argv[2])))
        return 0
    if len(argv) == 3 and argv[1] == "sentinel-message":
        info = sentinel_info(argv[2])
        if info is None:
            return 1
        sys.stderr.write(sentinel_message(info) + "\n")
        return 0
    sys.stderr.write(__doc__)
    return 64


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
