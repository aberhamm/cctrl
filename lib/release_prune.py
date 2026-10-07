#!/usr/bin/env python3
"""cctrl release prune: plan 089.

Dry run by default. Keeps the newest N complete releases plus `current`, the
launcher's target, and anything still referenced. Reference discovery is
read-only and fail-closed: if any scan cannot complete, every release is
treated as referenced and nothing is deleted.

Never prints environment values: process scans use `ps -axo pid=,command=`
(argv only) and `lsof -d cwd` (paths only); file scans only test whether a
release path occurs and report the *file name*, never its contents.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys

NAME_RE = re.compile(r"^[0-9a-f]{12}-(\d{8}T\d{6}Z)$")
MAX_FILE_BYTES = 8 * 1024 * 1024


def run(argv, timeout=30):
    return subprocess.run(argv, capture_output=True, text=True, errors="replace", timeout=timeout)


def classify(releases_dir):
    """Return (complete, incomplete, unrecognized) release name lists."""
    complete, incomplete, unrecognized = [], [], []
    for name in sorted(os.listdir(releases_dir)):
        path = os.path.join(releases_dir, name)
        if os.path.islink(path) or not os.path.isdir(path):
            unrecognized.append((name, "not a plain directory"))
            continue
        if not NAME_RE.match(name):
            (incomplete if name.startswith(".tmp-") else unrecognized).append(
                (name, "scratch/partial build directory" if name.startswith(".tmp-") else "unrecognized name"))
            continue
        if not (os.path.isfile(os.path.join(path, "cctrl")) and os.path.isfile(os.path.join(path, "VERSION"))):
            incomplete.append((name, "missing cctrl or VERSION"))
            continue
        complete.append(name)
    return complete, incomplete, unrecognized


def build_time(name):
    return NAME_RE.match(name).group(1)


class Scan:
    """Collects (source label, text-or-path-list) evidence; fails closed."""

    def __init__(self):
        self.blobs = []      # (label, text)
        self.errors = []

    def add_blob(self, label, text):
        self.blobs.append((label, text))

    def fail(self, why):
        self.errors.append(why)

    def users_of(self, name):
        needles = ("releases/" + name, "releases\\/" + name)
        return sorted({label for label, text in self.blobs if any(n in text for n in needles)})


def scan_processes(scan):
    try:
        r = run(["ps", "-ww", "-axo", "pid=,command="])
    except Exception as e:  # noqa: BLE001
        scan.fail("process scan failed: %s" % type(e).__name__)
        return
    if r.returncode != 0 or not r.stdout.strip():
        scan.fail("process scan failed (ps exit %d)" % r.returncode)
        return
    for line in r.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) < 2 or ("releases/" not in parts[1] and "releases\\/" not in parts[1]):
            continue
        exe = os.path.basename(parts[1].split(None, 1)[0])
        scan.add_blob("process %s (%s)" % (parts[0], exe), parts[1])
    # cwds and open files (paths only): a long-lived cctrl started via
    # `current/cctrl` before an install resolves to the old release dir and
    # keeps its script open, which ps argv alone does not show.
    try:
        r = run(["lsof", "-nP", "-u", str(os.getuid()), "-Fpn"], timeout=120)
    except FileNotFoundError:
        scan.fail("open-file scan unavailable (lsof not found)")
        return
    except Exception as e:  # noqa: BLE001
        scan.fail("open-file scan failed: %s" % type(e).__name__)
        return
    if r.returncode not in (0, 1) or not r.stdout.strip():
        scan.fail("open-file scan failed (lsof exit %d)" % r.returncode)
        return
    pid = "?"
    for line in r.stdout.splitlines():
        if line.startswith("p"):
            pid = line[1:]
        elif line.startswith("n") and "releases/" in line:
            scan.add_blob("process %s open file/cwd" % pid, line[1:])


def read_file(path):
    try:
        if os.path.getsize(path) > MAX_FILE_BYTES:
            return None
        with open(path, "r", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def scan_dir_files(scan, label, directory):
    """Every plain file in a short-lived overlay directory."""
    if not os.path.isdir(directory):
        return
    try:
        entries = sorted(os.listdir(directory))
    except OSError as e:
        scan.fail("%s unreadable (%s)" % (label, type(e).__name__))
        return
    for entry in entries:
        path = os.path.join(directory, entry)
        if os.path.islink(path):
            scan.fail("%s/%s is a symlink" % (label, entry))
            continue
        if not os.path.isfile(path):
            continue
        text = read_file(path)
        if text is None:
            scan.fail("%s/%s unreadable or too large" % (label, entry))
            continue
        scan.add_blob("%s %s" % (label, entry), text)


def scan_session_records(scan, directory, live):
    """Session registry records (TMUX--*.json, task-*.json, launch-*.json):
    a record pins the releases it mentions when its `name` is a live tmux
    session. Unparseable records fail closed."""
    if not os.path.isdir(directory):
        return
    try:
        entries = sorted(os.listdir(directory))
    except OSError as e:
        scan.fail("session registry unreadable (%s)" % type(e).__name__)
        return
    for entry in entries:
        if not entry.endswith(".json"):
            continue
        path = os.path.join(directory, entry)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        text = read_file(path)
        if text is None:
            scan.fail("session registry %s unreadable or too large" % entry)
            continue
        try:
            doc = json.loads(text)
        except ValueError:
            scan.fail("session registry %s is not valid JSON" % entry)
            continue
        name = doc.get("name") if isinstance(doc, dict) else None
        if name is None and entry.endswith(".json") and not entry.startswith(("task-", "launch-")):
            name = entry[:-5]
        state = doc.get("lifecycle_state") if isinstance(doc, dict) else None
        if name in live and state != "closed":
            scan.add_blob("session record %s (%s)" % (entry, name), text)


def live_tmux_sessions(scan):
    try:
        r = run(["tmux", "list-sessions", "-F", "#{session_name}"])
    except FileNotFoundError:
        scan.fail("session scan unavailable (tmux not found)")
        return None
    except Exception as e:  # noqa: BLE001
        scan.fail("session scan failed: %s" % type(e).__name__)
        return None
    if r.returncode != 0:
        if any(m in r.stderr for m in ("no server running", "No such file or directory", "Connection refused")):
            return set()
        scan.fail("session scan failed (tmux exit %d)" % r.returncode)
        return None
    return set(r.stdout.split())


def scan_bin_dir(scan, bin_path):
    """Symlinks and small launchers next to the cctrl launcher."""
    bin_dir = os.path.dirname(bin_path) or "."
    if not os.path.isdir(bin_dir):
        return
    try:
        entries = sorted(os.listdir(bin_dir))
    except OSError as e:
        scan.fail("bin dir unreadable (%s)" % type(e).__name__)
        return
    for entry in entries:
        path = os.path.join(bin_dir, entry)
        label = "bin/%s" % entry
        if os.path.islink(path):
            scan.add_blob(label + " (symlink)", os.readlink(path) + "\n" + os.path.realpath(path))
        elif os.path.isfile(path):
            text = read_file(path) if os.path.getsize(path) <= 65536 else ""
            if text is None:
                scan.fail("%s unreadable" % label)
            else:
                scan.add_blob(label, text)


def scan_user_configs(scan):
    """Existence-only checks of user MCP/settings files: only the release
    names are searched for; contents are never kept or printed."""
    home = os.path.expanduser("~")
    for rel in (".claude.json", ".claude/settings.json", ".codex/config.toml"):
        path = os.path.join(home, rel)
        if not os.path.isfile(path):
            continue
        text = read_file(path)
        if text is None:
            scan.fail("%s unreadable or too large" % rel)
            continue
        # Reduce to just the release-path fragments so nothing else is retained.
        frags = re.findall(r"releases/[0-9a-f]{12}-\d{8}T\d{6}Z", text)
        scan.add_blob("~/%s" % rel, "\n".join(frags))


def link_target_name(path, releases_real):
    """Release name a symlink resolves into, or None."""
    if not os.path.islink(path):
        return None
    real = os.path.realpath(path)
    prefix = releases_real + os.sep
    if real.startswith(prefix):
        return real[len(prefix):].split(os.sep, 1)[0]
    return None


def safe_to_delete(releases_dir, releases_real, name, current_real):
    if not NAME_RE.match(name):
        return False, "name does not match the release pattern"
    path = os.path.join(releases_dir, name)
    if os.path.islink(path):
        return False, "is a symlink"
    real = os.path.realpath(path)
    if os.path.dirname(real) != releases_real or os.path.basename(real) != name:
        return False, "does not resolve to a direct child of the releases dir"
    if current_real and real == current_real:
        return False, "is current's target"
    if not os.path.isdir(real) or not os.listdir(real):
        return False, "empty or not a directory"
    return True, ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--home", required=True)
    ap.add_argument("--bin", required=True)
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--runtime-settings-dir", required=True)
    ap.add_argument("--keep", type=int, default=5)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    releases_dir = os.path.join(a.home, "releases")
    current_link = os.path.join(a.home, "current")
    result = {"schema_version": 1, "mode": "apply" if a.apply else "dry-run", "keep": a.keep,
              "releases_dir": releases_dir, "scan_complete": True, "scan_errors": [],
              "kept": [], "would_delete": [], "deleted": [], "incomplete": [],
              "unrecognized": [], "refused": []}

    if not os.path.isdir(releases_dir) or os.path.islink(releases_dir):
        result["scan_complete"] = False
        result["scan_errors"].append("releases dir missing or a symlink")
        return finish(a, result, 69)

    releases_real = os.path.realpath(releases_dir)
    complete, incomplete, unrecognized = classify(releases_dir)
    result["incomplete"] = [{"name": n, "reason": why} for n, why in incomplete]
    result["unrecognized"] = [{"name": n, "reason": why} for n, why in unrecognized]

    scan = Scan()
    current_real = os.path.realpath(current_link) if os.path.lexists(current_link) else None
    if current_real is None:
        scan.fail("current link missing")
    scan_processes(scan)
    scan_bin_dir(scan, a.bin)
    # Metadata only for sessions that are live in tmux; settings overlays are
    # short-lived and always scanned.
    live = live_tmux_sessions(scan)
    if live is not None:
        scan_session_records(scan, a.data_dir, live)
    scan_dir_files(scan, "settings overlay", a.runtime_settings_dir)
    scan_user_configs(scan)

    keep_reason = {}
    newest = sorted(complete, key=build_time, reverse=True)
    for n in newest[: max(a.keep, 0)]:
        keep_reason[n] = ["newest %d" % a.keep]
    if current_real and os.path.dirname(current_real) == releases_real:
        keep_reason.setdefault(os.path.basename(current_real), []).append("current")
    launcher_name = link_target_name(a.bin, releases_real)
    if launcher_name:
        keep_reason.setdefault(launcher_name, []).append("launcher target")

    if scan.errors:
        result["scan_complete"] = False
        result["scan_errors"] = scan.errors

    for name in newest:
        reasons = list(keep_reason.get(name, []))
        users = scan.users_of(name)
        if users:
            shown = ", ".join(users[:3]) + (" and %d more" % (len(users) - 3) if len(users) > 3 else "")
            reasons.append("in use by " + shown)
        if scan.errors:
            reasons.append("reference scan incomplete (fail closed)")
        if reasons:
            result["kept"].append({"name": name, "reasons": reasons})
        else:
            result["would_delete"].append(name)

    rc = 69 if scan.errors else 0
    if a.apply and not scan.errors:
        for name in list(result["would_delete"]):
            # Re-resolve current and the launcher right before each delete so a
            # rollback during the scan window cannot be raced.
            cur = os.path.realpath(current_link) if os.path.lexists(current_link) else None
            launcher_now = link_target_name(a.bin, releases_real)
            if cur is None:
                result["refused"].append({"name": name, "reason": "current link vanished"})
                rc = 69
                break
            if launcher_now == name:
                result["would_delete"].remove(name)
                result["refused"].append({"name": name, "reason": "launcher now points here"})
                continue
            ok, why = safe_to_delete(releases_dir, releases_real, name, cur)
            if not ok:
                result["refused"].append({"name": name, "reason": why})
                result["would_delete"].remove(name)
                continue
            try:
                shutil.rmtree(os.path.join(releases_real, name))
            except Exception as e:  # noqa: BLE001
                result["failed"] = {"name": name, "error": type(e).__name__}
                rc = 70
                break
            result["would_delete"].remove(name)
            result["deleted"].append(name)
    return finish(a, result, rc)


def finish(a, result, rc):
    if a.json:
        print(json.dumps(result, indent=2))
        return rc
    print("release prune (%s), keep newest %d" % (result["mode"], result["keep"]))
    if not result["scan_complete"]:
        print("REFERENCE SCAN INCOMPLETE - treating every release as referenced; nothing will be deleted:")
        for e in result["scan_errors"]:
            print("  - " + e)
    for k in result["kept"]:
        print("kept    %s (%s)" % (k["name"], "; ".join(k["reasons"])))
    for n in result["would_delete"]:
        print("would delete %s" % n)
    for n in result["deleted"]:
        print("deleted %s" % n)
    if "failed" in result:
        print("FAILED deleting %s (%s); stopped, remaining releases untouched" % (result["failed"]["name"], result["failed"]["error"]))
    for x in result["refused"]:
        print("REFUSED %s: %s" % (x["name"], x["reason"]))
    for x in result["incomplete"]:
        print("incomplete (not touched) %s: %s" % (x["name"], x["reason"]))
    for x in result["unrecognized"]:
        print("unrecognized (not touched) %s: %s" % (x["name"], x["reason"]))
    if result["mode"] == "dry-run" and result["would_delete"]:
        print("dry run: nothing deleted; re-run with --apply to delete the %d release(s) above" % len(result["would_delete"]))
    return rc


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        # Nothing is deleted before the scan finishes; a crash after deletion
        # started is handled inside main(). Fail closed, no traceback noise.
        print("release prune: internal error (%s); nothing further was deleted" % type(exc).__name__, file=sys.stderr)
        sys.exit(70)
