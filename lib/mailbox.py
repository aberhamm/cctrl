#!/usr/bin/env python3
"""Mailbox storage helpers (plan 116, A1): tolerant read, safe rewrite, backups,
repair. The file stays plain JSONL, one JSON object per line, so a previous
release reads it unchanged. Standard library only.

Commands (the shell side in `cctrl` calls these; the caller holds the lock for
rewrite and repair):

  mailbox.py read FILE [--strict] [--no-quarantine]
      Print the good messages as one JSON array. A bad line (unparseable, a NUL
      byte, invalid UTF-8, or not a JSON object) is copied to
      FILE-with-.quarantine.jsonl ("messages.quarantine.jsonl") with its reason and
      source line number, once per distinct line. With --strict, or
      CCTRL_MAILBOX_STRICT=1, any bad line exits 65 and nothing is quarantined.

  mailbox.py rewrite FILE
      Read a JSON array on stdin and replace FILE with it: backup first, then
      a temp file in the SAME directory, fsync, rename, fsync the directory.

  mailbox.py repair FILE [--dry-run]
      Rebuild FILE from itself, its .bak and the quarantine: no duplicate ids,
      the newest status wins by updated_at. Idempotent.

  mailbox.py info FILE
      JSON facts for `peer doctor`: quarantine count, duplicate ids, stray
      temp files, backups.

Backups: FILE.bak is refreshed before each rewrite, plus one dated copy per
day (FILE.bak.YYYYMMDD) kept 7 days, all 0600.
"""

import datetime
import hashlib
import json
import os
import sys

KEEP_DAYS = 7
SCHEMA_V = 1
# Test-mode fault injection (honoured only under the A0 gate): kill -9 ourselves
# at a named point of the rewrite.
FAULT_ENV = "CCTRL_TEST_MAILBOX_FAULT"


def quarantine_path(path):
    d, n = os.path.split(path)
    stem = n[:-len(".jsonl")] if n.endswith(".jsonl") else n
    return os.path.join(d, stem + ".quarantine.jsonl")


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


def _fault(point):
    """kill -9 the writer at a named point: its parent shell too (so the lock
    is left held by a dead pid, as in a real crash), then ourselves."""
    if os.environ.get(FAULT_ENV) == point and _test_mode():
        try:
            os.kill(os.getppid(), 9)
        except OSError:
            pass
        os.kill(os.getpid(), 9)


def _dumps(obj):
    """Compact JSON, UTF-8, like `jq -c`. Raises UnicodeEncodeError on a lone
    surrogate (the line is then not valid UTF-8 text)."""
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def parse_lines(raw):
    """Split bytes into (good, bad). good: [(lineno, obj)], bad: [(lineno, reason, bytes)]."""
    good, bad = [], []
    lines = raw.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    for i, line in enumerate(lines, 1):
        if line.strip() == b"":
            continue
        if b"\0" in line:
            bad.append((i, "nul-byte", line))
            continue
        try:
            text = line.decode("utf-8")
        except UnicodeDecodeError:
            bad.append((i, "invalid-utf8", line))
            continue
        try:
            obj = json.loads(text)
        except ValueError:
            bad.append((i, "unparseable", line))
            continue
        if not isinstance(obj, dict):
            bad.append((i, "wrong-type", line))
            continue
        try:
            _dumps(obj)
        except UnicodeEncodeError:
            bad.append((i, "invalid-utf8", line))
            continue
        good.append((i, obj))
    return good, bad


def _read_bytes(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return b""


def _quarantined_digests(qpath):
    seen = set()
    raw = _read_bytes(qpath)
    for line in raw.split(b"\n"):
        if not line.strip():
            continue
        try:
            d = json.loads(line.decode("utf-8", "replace")).get("sha256")
        except ValueError:
            continue
        if d:
            seen.add(d)
    return seen


def quarantine(path, bad):
    """Append bad lines to the quarantine file (0600), once per distinct line."""
    qpath = quarantine_path(path)
    seen = _quarantined_digests(qpath)
    out = []
    now = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    for lineno, reason, line in bad:
        digest = hashlib.sha256(line).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        rec = {
            "reason": reason, "line": lineno, "source": os.path.basename(path),
            "quarantined_at": now, "sha256": digest,
            "raw": line.decode("utf-8", "backslashreplace"),
        }
        out.append(json.dumps(rec, ensure_ascii=True, separators=(",", ":")).encode("ascii") + b"\n")
    if not out:
        return 0
    fd = os.open(qpath, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, b"".join(out))
    finally:
        os.close(fd)
    return len(out)


def cmd_read(path, strict, no_quarantine):
    good, bad = parse_lines(_read_bytes(path))
    if bad:
        if strict:
            sys.stderr.write("mailbox has %d bad line(s), first at line %d (%s)\n" % (len(bad), bad[0][0], bad[0][1]))
            return 65
        if not no_quarantine:
            try:
                quarantine(path, bad)
            except OSError as e:
                sys.stderr.write("could not write the quarantine: %s\n" % e)
    sys.stdout.buffer.write(_dumps([o for _n, o in good]) + b"\n")
    return 0


def _fsync_dir(d):
    fd = os.open(d, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _write_file_atomic(path, data, mode=0o600, fault=False):
    """Temp file in the same directory, fsync, rename, fsync the directory."""
    d = os.path.dirname(path) or "."
    tmp = os.path.join(d, ".%s.tmp.%d.%s" % (os.path.basename(path), os.getpid(), os.urandom(3).hex()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        view = memoryview(data)
        while view:
            n = os.write(fd, view)
            view = view[n:]
        os.fchmod(fd, mode)
        os.fsync(fd)
    except BaseException:
        os.close(fd)
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.close(fd)
    if fault:
        _fault("after-tmp")
    os.rename(tmp, path)
    if fault:
        _fault("after-rename")
    _fsync_dir(d)


def refresh_backups(path):
    """FILE.bak = the current content; one dated copy per day; prune to 7 days."""
    cur = _read_bytes(path)
    if not cur:
        return
    _write_file_atomic(path + ".bak", cur)
    today = datetime.date.today()
    dated = "%s.bak.%s" % (path, today.strftime("%Y%m%d"))
    if not os.path.exists(dated):
        _write_file_atomic(dated, cur)
    d = os.path.dirname(path) or "."
    prefix = os.path.basename(path) + ".bak."
    for name in os.listdir(d):
        if not name.startswith(prefix):
            continue
        stamp = name[len(prefix):]
        try:
            day = datetime.datetime.strptime(stamp, "%Y%m%d").date()
        except ValueError:
            continue
        if (today - day).days >= KEEP_DAYS:
            try:
                os.unlink(os.path.join(d, name))
            except OSError:
                pass


def rewrite(path, messages):
    lines = []
    for m in messages:
        if not isinstance(m, dict):
            raise ValueError("a mailbox record must be a JSON object")
        lines.append(_dumps(m) + b"\n")
    sweep_stray_temp(path)
    refresh_backups(path)
    _write_file_atomic(path, b"".join(lines), fault=True)


def sweep_stray_temp(path):
    """Remove temp files a crashed writer left behind (their pid is dead)."""
    d = os.path.dirname(path) or "."
    prefix = ".%s.tmp." % os.path.basename(path)
    for name in os.listdir(d):
        if not name.startswith(prefix):
            continue
        parts = name[len(prefix):].split(".")
        try:
            pid = int(parts[0])
            os.kill(pid, 0)
            continue  # its writer is alive
        except ProcessLookupError:
            pass
        except (ValueError, OSError):
            continue
        try:
            os.unlink(os.path.join(d, name))
        except OSError:
            pass


def cmd_rewrite(path):
    try:
        doc = json.loads(sys.stdin.buffer.read().decode("utf-8"))
    except ValueError as e:
        sys.stderr.write("rewrite: stdin is not a JSON array: %s\n" % e)
        return 65
    if not isinstance(doc, list):
        sys.stderr.write("rewrite: stdin is not a JSON array\n")
        return 65
    try:
        rewrite(path, doc)
    except (ValueError, UnicodeEncodeError, OSError) as e:
        sys.stderr.write("rewrite: %s\n" % e)
        return 1
    return 0


_STATUS_RANK = {"queued": 0, "delivered": 1, "acked": 2}


def _sort_key(obj):
    return (str(obj.get("updated_at") or obj.get("acked_at") or obj.get("delivered_at") or obj.get("created_at") or ""),
            _STATUS_RANK.get(obj.get("status"), -1))


def merge(sources):
    """sources: list of lists of dicts, highest-priority first (ties go to the
    earlier source). Keeps first-seen order; per id the newest wins."""
    order, best = [], {}
    anon = []
    for objs in sources:
        for obj in objs:
            mid = obj.get("id")
            if not isinstance(mid, str) or not mid:
                anon.append(obj)
                continue
            if mid not in best:
                order.append(mid)
                best[mid] = obj
            elif _sort_key(obj) > _sort_key(best[mid]):
                best[mid] = obj
    return [best[i] for i in order] + anon


def _recover_from_quarantine(path):
    out = []
    for line in _read_bytes(quarantine_path(path)).split(b"\n"):
        if not line.strip():
            continue
        try:
            rec = json.loads(line.decode("utf-8", "replace"))
            raw = rec.get("raw", "")
            obj = json.loads(raw)
        except (ValueError, AttributeError):
            continue
        if isinstance(obj, dict) and isinstance(obj.get("id"), str):
            out.append(obj)
    return out


def repair_plan(path):
    cur_good, cur_bad = parse_lines(_read_bytes(path))
    bak_good, _ = parse_lines(_read_bytes(path + ".bak"))
    q = _recover_from_quarantine(path)
    cur = [o for _n, o in cur_good]
    bak = [o for _n, o in bak_good]
    merged = merge([cur, bak, q])
    cur_ids = {o.get("id") for o in cur}
    return {
        "merged": merged,
        "current": len(cur),
        "from_backup": sum(1 for o in merged if o.get("id") not in cur_ids and o in bak),
        "from_quarantine": sum(1 for o in merged if o.get("id") not in cur_ids and o in q and o not in bak),
        "bad_lines": len(cur_bad),
        "result": len(merged),
    }


def cmd_repair(path, dry_run):
    plan = repair_plan(path)
    if not dry_run:
        # A quarantine pass first, so nothing in a bad line is lost by the rewrite.
        _good, bad = parse_lines(_read_bytes(path))
        if bad:
            quarantine(path, bad)
        rewrite(path, plan["merged"])
    summary = {k: v for k, v in plan.items() if k != "merged"}
    summary["dry_run"] = dry_run
    sys.stdout.write(json.dumps(summary) + "\n")
    return 0


def cmd_info(path):
    good, bad = parse_lines(_read_bytes(path))
    ids = {}
    for _n, o in good:
        mid = o.get("id")
        if isinstance(mid, str):
            ids[mid] = ids.get(mid, 0) + 1
    qcount = 0
    for line in _read_bytes(quarantine_path(path)).split(b"\n"):
        if line.strip():
            qcount += 1
    d = os.path.dirname(path) or "."
    base = os.path.basename(path)
    names = os.listdir(d) if os.path.isdir(d) else []
    out = {
        "messages": len(good),
        "bad_lines": len(bad),
        "quarantined": qcount,
        "duplicate_ids": sum(1 for c in ids.values() if c > 1),
        "stray_temp_files": sorted(n for n in names if n.startswith("." + base + ".tmp.")),
        "backups": sorted(n for n in names if n == base + ".bak" or n.startswith(base + ".bak.")),
    }
    sys.stdout.write(json.dumps(out) + "\n")
    return 0


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 64
    cmd, path, rest = argv[1], argv[2], argv[3:]
    if cmd == "read":
        strict = "--strict" in rest or os.environ.get("CCTRL_MAILBOX_STRICT") == "1"
        return cmd_read(path, strict, "--no-quarantine" in rest)
    if cmd == "rewrite":
        return cmd_rewrite(path)
    if cmd == "repair":
        return cmd_repair(path, "--dry-run" in rest)
    if cmd == "info":
        return cmd_info(path)
    sys.stderr.write(__doc__)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
