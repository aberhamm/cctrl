#!/usr/bin/env python3
"""cctrl helpers: plan 106 P1. Read-only census of MCP helper processes.

Reads one `ps -axo pid=,ppid=,rss=,comm=` table, one `ps -o pid=,args= -p ...`
lookup for owner candidates only (codex/claude executables), and, optionally,
tmux pane pids (`tmux list-panes -a`). It only reports. This module has no
code path that acts on a process or writes anything.

Command-line arguments are used to classify an owner (does it say
`app-server`?) and are simply never printed or returned (nothing is redacted:
there is no code path that emits them). Process environments are
never read. Output holds only: pids, a fixed label, tmux session names,
executable basenames, counts and sizes.

Test inputs: CCTRL_HELPERS_FIXTURE_DIR holding ps.txt, args.txt, panes.txt
replaces the live reads.
"""
import argparse
import json
import os
import re
import statistics
import subprocess
import sys

DEFAULT_PER_SET = 18
TIMEOUT = 15
DEFAULT_WARN_SETS = 8
DEFAULT_WARN_GB = 8.0
LABELS = ("codex app-server (remote-control)", "codex app-server (other)", "codex tui", "codex (unclassified)", "claude")
SAFE_NAME = re.compile(r"[^A-Za-z0-9._+@-]")
# A displayed name that looks like a credential is shown as "?". A crafted comm
# ("/x y/<token>") would otherwise surface its tail as the executable name.
SECRET_PREFIX = re.compile(r"^(sk|pk|rk|ghp|gho|ghu|ghs|github_pat|glpat|xox[a-z]|AKIA|ASIA|AIza|eyJ|npm|hf)[-_A-Za-z0-9]", re.I)
SECRET_SHAPE = re.compile(r"^[A-Za-z0-9_+@.-]{20,}$")
FOOTER_NOTE = "cctrl does not reap helpers; see README: MCP helper processes"


class PsError(Exception):
    pass


def _run(argv, timeout=None):
    return subprocess.run(argv, capture_output=True, text=True, errors="replace", timeout=timeout or TIMEOUT)


def _fixture(name):
    d = os.environ.get("CCTRL_HELPERS_FIXTURE_DIR")
    if not d:
        return None
    try:
        with open(os.path.join(d, name), encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def exe_name(comm):
    """Executable basename of a ps comm field, reduced to a safe display token.

    comm is a path that may hold spaces, so the name is the text after the last
    "/" and then its first whitespace-delimited token. A token with any
    character outside a small safe set (so KEY=value, user:pw@host), anything
    credential-shaped and anything past 40 characters is shown as "?", not
    partly masked."""
    base = comm.rstrip("/").rsplit("/", 1)[-1].strip("()")
    base = (base.split() or [""])[0]
    digits = sum(ch.isdigit() for ch in base)
    if (SAFE_NAME.search(base) or SECRET_PREFIX.match(base) or len(base) > 40
            or (SECRET_SHAPE.match(base) and digits >= 3) or (len(base) >= 12 and digits >= 3)):
        base = "?"
    return base or "?"


def parse_ps(text):
    """Parse ps rows into {pid: (ppid, rss_kb, comm)}. Malformed rows are skipped."""
    procs = {}
    for line in text.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid, ppid, rss = int(parts[0]), int(parts[1]), int(parts[2])
        except ValueError:
            continue
        if pid <= 0 or rss < 0:
            continue
        procs[pid] = (ppid, rss, parts[3])
    return procs


def read_ps():
    fx = _fixture("ps.txt")
    if fx is not None:
        text = fx
    else:
        try:
            r = _run(["ps", "-axo", "pid=,ppid=,rss=,comm="])
        except (OSError, subprocess.SubprocessError) as exc:
            raise PsError("ps failed: %s" % type(exc).__name__)
        if r.returncode != 0:
            raise PsError("ps exited %d" % r.returncode)
        text = r.stdout
    procs = parse_ps(text)
    if not procs:
        raise PsError("ps returned no usable rows")
    return procs


def read_args(pids):
    """{pid: args text} for the given owner pids. Used only to classify."""
    out = {}
    if not pids:
        return out
    fx = _fixture("args.txt")
    if fx is not None:
        text = fx
    else:
        try:
            r = _run(["ps", "-o", "pid=,args=", "-p", ",".join(str(p) for p in sorted(pids))])
            text = r.stdout if r.returncode in (0, 1) else ""
        except (OSError, subprocess.SubprocessError):
            text = ""
    for line in text.splitlines():
        parts = line.strip().split(None, 1)
        if parts and parts[0].isdigit():
            out[int(parts[0])] = parts[1] if len(parts) > 1 else ""
    return out


def read_panes():
    """{pid: tmux session name} from tmux list-panes (read-only); {} on any failure."""
    fx = _fixture("panes.txt")
    if fx is not None:
        text = fx
    else:
        try:
            r = _run(["tmux", "list-panes", "-a", "-F", "#{pane_pid} #{session_name}"], timeout=min(5, TIMEOUT))
            text = r.stdout if r.returncode == 0 else ""
        except (OSError, subprocess.SubprocessError):
            text = ""
    out = {}
    for line in text.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit():
            out[int(parts[0])] = SAFE_NAME.sub("?", parts[1])[:80]
    return out


def classify(kind, args):
    """Fixed label from the executable kind and its (never printed) args."""
    if kind == "claude":
        return "claude"
    if args is None:
        return "codex (unclassified)"
    if re.search(r"(^|\s)app-server(\s|$)", args):
        if re.search(r"--remote-control(\s|=|$)", args):
            return "codex app-server (remote-control)"
        return "codex app-server (other)"
    return "codex tui"


def codex_stdio_count(codex_dir):
    """Number of [mcp_servers.<name>] tables that declare `command` (names never kept)."""
    fx = _fixture("codex-config.toml")
    if fx is not None:
        text = fx
    else:
        try:
            with open(os.path.join(codex_dir, "config.toml"), encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            return 0
    count, in_server = 0, False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("["):
            m = re.match(r"^\[mcp_servers\.[A-Za-z0-9_-]+\]\s*(#.*)?$", s)
            in_server = bool(m)
        elif in_server and re.match(r"^command\s*=", s):
            count += 1
            in_server = False
    return count


def session_of(pid, procs, panes):
    """tmux session of the pane whose process is this pid or its nearest ancestor."""
    seen = set()
    while pid in procs and pid not in seen and pid > 1:
        if pid in panes:
            return panes[pid]
        seen.add(pid)
        pid = procs[pid][0]
    return "-"


def census(procs, args_of, panes, codex_dir, warn_sets=DEFAULT_WARN_SETS, warn_gb=DEFAULT_WARN_GB):
    kids = {}
    for pid, (ppid, _rss, _comm) in procs.items():
        if ppid != pid:
            kids.setdefault(ppid, []).append(pid)
    owners = {}
    for pid, (_ppid, _rss, comm) in procs.items():
        name = exe_name(comm)
        if name in ("codex", "claude"):
            owners[pid] = name
    raw_args = args_of(set(owners))
    rows = []
    for pid, kind in sorted(owners.items()):
        direct = [c for c in kids.get(pid, []) if c not in owners]
        seen, stack = set(), list(direct)
        while stack:
            p = stack.pop()
            if p in seen or p == pid or p in owners:
                continue   # a nested owner is its own row; do not count it twice
            seen.add(p)
            stack.extend(kids.get(p, []))
        counts = {}
        for c in direct:
            n = exe_name(procs[c][2])
            counts[n] = counts.get(n, 0) + 1
        top = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
        rows.append({
            "pid": pid,
            "label": classify(kind, raw_args.get(pid)),
            "session": session_of(pid, procs, panes),
            "direct_children": len(direct),
            "descendants": len(seen),
            "helper_rss_kb": sum(procs[d][1] for d in seen if d in procs),
            "own_rss_kb": procs[pid][1],
            "top_children": [{"name": n, "count": c} for n, c in top],
        })
    solo = [r["direct_children"] for r in rows
            if r["label"] in ("codex tui", "claude") and r["direct_children"] > 0]
    median_solo = int(statistics.median(solo)) if solo else 0
    stdio = codex_stdio_count(codex_dir)
    for r in rows:
        if r["label"].startswith("codex app-server") or r["label"] == "codex tui":
            per_set = stdio or median_solo or DEFAULT_PER_SET
        else:
            per_set = median_solo or DEFAULT_PER_SET
        r["per_set"] = per_set
        r["est_sets"] = int(round(r["direct_children"] / float(per_set)))
        r["extra_sets_est"] = max(0, r["est_sets"] - 1) if r["label"].startswith("codex app-server") else 0
        limit_kb = warn_gb * 1024 * 1024
        reasons = []
        if r["est_sets"] > warn_sets:
            reasons.append("est_sets %d > %d" % (r["est_sets"], warn_sets))
        if r["helper_rss_kb"] > limit_kb:
            reasons.append("helper RSS %.1f GB > %g GB" % (r["helper_rss_kb"] / 1048576.0, warn_gb))
        r["flagged"] = bool(reasons)
        r["flag_reason"] = "; ".join(reasons)
    rows.sort(key=lambda r: (-r["helper_rss_kb"], r["pid"]))
    return rows


def summary(rows):
    return {
        "owners": len(rows),
        "total_helpers": sum(r["direct_children"] for r in rows),
        "total_descendants": sum(r["descendants"] for r in rows),
        "helper_rss_kb": sum(r["helper_rss_kb"] for r in rows),
        "extra_sets_est": sum(r["extra_sets_est"] for r in rows),
        "flagged": sum(1 for r in rows if r["flagged"]),
    }


def gb(kb):
    return "%.1f" % (kb / 1048576.0)


def render_text(rows):
    lines = []
    if not rows:
        lines.append("No codex or claude processes found.")
        return "\n".join(lines)
    lines.append("%-6s %-34s %-24s %6s %6s %9s %8s %5s" % (
        "PID", "OWNER", "SESSION", "KIDS", "DESC", "HELPERGB", "OWNGB", "SETS"))
    for r in rows:
        lines.append("%-6d %-34s %-24s %6d %6d %9s %8s %5d" % (
            r["pid"], r["label"], r["session"][:24], r["direct_children"], r["descendants"],
            gb(r["helper_rss_kb"]), gb(r["own_rss_kb"]), r["est_sets"]))
        if r["top_children"]:
            lines.append("       top: " + ", ".join("%s x%d" % (c["name"], c["count"]) for c in r["top_children"]))
    s = summary(rows)
    lines.append("total: %d helpers (%d descendants), %s GB helper RSS, ~%d extra app-server sets (estimate)" % (
        s["total_helpers"], s["total_descendants"], gb(s["helper_rss_kb"]), s["extra_sets_est"]))
    for r in rows:
        if r["flagged"]:
            lines.append("FLAGGED pid %d %s: %s" % (r["pid"], r["label"], r["flag_reason"]))
    if s["flagged"]:
        lines.append(FOOTER_NOTE)
    return "\n".join(lines)


def footer_line(rows):
    flagged = [r for r in rows if r["flagged"]]
    if not flagged:
        return ""
    worst = flagged[0]
    return "MCP helpers: %d owner(s) flagged (pid %d %s: %s). Run: cctrl helpers" % (
        len(flagged), worst["pid"], worst["label"], worst["flag_reason"])


def main(argv=None):
    ap = argparse.ArgumentParser(prog="cctrl helpers", add_help=True,
                                 description="Read-only census of MCP helper processes per codex/claude owner.")
    ap.add_argument("--json", action="store_true", help="machine-readable report")
    ap.add_argument("--check", action="store_true", help="exit 1 when an owner is flagged")
    ap.add_argument("--footer", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--warn-sets", type=int, default=DEFAULT_WARN_SETS, metavar="N")
    ap.add_argument("--warn-gb", type=float, default=DEFAULT_WARN_GB, metavar="G")
    ap.add_argument("--codex-dir", default=os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"))
    try:
        ns = ap.parse_args(argv)
    except SystemExit as exc:
        return 0 if exc.code in (0, None) else 64
    if ns.warn_sets < 0 or ns.warn_gb < 0:
        print("cctrl helpers: thresholds must be >= 0", file=sys.stderr)
        return 64
    global TIMEOUT
    if ns.footer:
        TIMEOUT = 2   # best effort inside `task ls`: never hold it up
    try:
        procs = read_ps()
        rows = census(procs, read_args, read_panes(), ns.codex_dir, ns.warn_sets, ns.warn_gb)
    except PsError as exc:
        print("cctrl helpers: cannot read the process table (%s)" % exc, file=sys.stderr)
        return 69
    except Exception as exc:  # fail soft: a message and rc, never a traceback
        print("cctrl helpers: unexpected process table (%s)" % type(exc).__name__, file=sys.stderr)
        return 69
    if ns.footer:
        line = footer_line(rows)
        if line:
            print(line)
        return 0
    if ns.json:
        print(json.dumps({"schema_version": 1, "summary": summary(rows), "owners": rows},
                         sort_keys=True, indent=2))
    else:
        print(render_text(rows))
    return 1 if ns.check and any(r["flagged"] for r in rows) else 0


if __name__ == "__main__":
    sys.exit(main())
