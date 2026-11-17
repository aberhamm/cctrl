#!/usr/bin/env python3
"""Evidence-based resolution plan for stale tmux ownership claims (plan 070 S5).

Pure evaluation: the shell collects one tmux pane inventory, one process
table, the Claude session files, and the Codex ownership evidence; this module
decides, per open task record, whether live evidence proves the record stale
or proves it the running owner. It never writes. Each proposed action carries
the record digest it was decided against, so the caller's write is rejected if
the record changed in between.

Outcomes:
  close  stale-anchor     the record's pane is gone, its tmux name is held by
                          another execution, and nothing runs the task
  close  superseded-by X  the record's pane runs a different conversation X
  own    live-owner       the pane runs exactly this task; restore cctrl/tmux
  skip   <reason>         evidence is missing or ambiguous; leave unchanged

A name with no live tmux session is never closed here: after a reboot every
pane is gone, and those tasks are exactly what restore should bring back.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

PROVISIONAL_GRACE_SECONDS = 300  # matches snapshot_restore.PROVISIONAL_STALE_GRACE_SECONDS
ENDED = {"closed", "archived", "released"}
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def load(path: str) -> Any:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def record_digest(record: dict[str, Any]) -> str:
    # Same canonical form as cctrl's _task_registry_record_digest.
    canonical = json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(canonical).hexdigest()


def norm(value: Any) -> str:
    return " ".join(str(value or "").split())


def agent_of(command: str) -> str:
    tokens = command.split()
    if not tokens:
        return ""
    base = tokens[0].rsplit("/", 1)[-1]
    if base in ("claude", "codex"):
        return base
    # npm installs run Claude Code as `node .../@anthropic-ai/claude-code/cli.js`.
    if base in ("node", "bun") and len(tokens) > 1 and (
            "@anthropic-ai/claude-code" in tokens[1] or tokens[1].rsplit("/", 1)[-1] == "claude"):
        return "claude"
    return ""


def claude_like(command: str) -> bool:
    """True for a process that might be a Claude CLI whatever argv0 is.

    agent_of() only knows `claude` and node running claude-code. A versioned
    binary (.../claude/versions/<v>) or a desktop CLI entrypoint
    (.../ccd-cli/<v>) has neither name. Only the executable part of the
    command is read (up to the first option). Matches: argv0 `claude`, a
    claude/versions/ path, a ccd-cli/ or claude-code/ component. A macOS app
    bundle (*.app/Contents/, i.e. Claude.app and its helpers) is not a CLI
    unless it sits under ccd-cli. Plain names like claude-mem do not match.
    """
    if agent_of(command) == "claude":
        return True
    head = command
    cut = head.find(" -")
    if cut >= 0:
        head = head[:cut]
    parts = [part.strip().lower() for part in head.replace("\\", "/").split("/")]
    if "ccd-cli" in parts:
        return True
    if ".app/contents/" in head.lower().replace("\\", "/"):
        return False
    for k in range(len(parts) - 1):
        if parts[k] == "claude" and parts[k + 1] == "versions":
            return True
    return "claude-code" in parts


class Evidence:
    def __init__(self, panes: dict[str, Any], process: dict[str, Any], claude_sessions: str, codex: dict[str, Any]):
        self.panes_ok = panes.get("status") == "available"
        self.process_ok = process.get("status") == "available" and isinstance(process.get("processes"), list)
        self.panes = [p for p in panes.get("panes") or [] if isinstance(p, dict)]
        self.live_names = {p.get("session_name") for p in self.panes}
        rows = [p for p in process.get("processes") or [] if isinstance(p, dict)]
        self.proc = {int(p["pid"]): p for p in rows if str(p.get("pid", "")).isdigit()}
        self.children: dict[int, list[int]] = {}
        for p in rows:
            if str(p.get("ppid", "")).isdigit() and str(p.get("pid", "")).isdigit():
                self.children.setdefault(int(p["ppid"]), []).append(int(p["pid"]))
        self.claude_dir = Path(claude_sessions) if claude_sessions else None
        self.codex_ok = isinstance(codex.get("records"), list)
        self.codex = {r.get("provider_task_id"): r for r in codex.get("records") or [] if isinstance(r, dict)}
        self.protect: dict[str, str] = {}

    def pane(self, record: dict[str, Any]) -> dict[str, Any] | None:
        pane_id, pane_pid = str(record.get("pane_id") or ""), str(record.get("pane_pid") or "")
        for pane in self.panes:
            if pane.get("pane_id") == pane_id and str(pane.get("pane_pid")) == pane_pid:
                started = norm(self.proc.get(int(pane_pid), {}).get("started")) if pane_pid.isdigit() else ""
                # pid reuse after a reboot: the same pid with a different start
                # time is a different execution.
                if record.get("pane_started") and started and norm(record["pane_started"]) != started:
                    return None
                return pane
        return None

    def descendants(self, pid: int, depth: int = 0) -> list[dict[str, Any]]:
        if depth > 8 or pid not in self.proc:
            return []
        found = [self.proc[pid]]
        for child in self.children.get(pid, []):
            found += self.descendants(child, depth + 1)
        return found

    def running_task(self, pane: dict[str, Any], provider: str) -> str | None:
        """The provider task id the pane's agent is running, when provable."""
        pid = str(pane.get("pane_pid") or "")
        if not pid.isdigit():
            return None
        agents = [p for p in self.descendants(int(pid)) if agent_of(str(p.get("command", ""))) == provider]
        if len(agents) != 1:
            return None
        agent = agents[0]
        if provider == "claude" and self.claude_dir:
            return self.session_file(int(agent["pid"]))
        if provider == "codex":
            ids = set(UUID.findall(str(agent.get("command", ""))))
            return ids.pop() if len(ids) == 1 else None
        return None

    def argv_mentions(self, task_id: str) -> bool:
        return any(task_id in str(p.get("command", "")) for p in self.proc.values())

    def claude_session_ids(self) -> tuple[set[str], int]:
        """(sessionId of every live Claude process, count of Claude processes without a readable session file).

        A conversation resumed with /resume, or relaunched in another pane,
        has no id on its command line; its session file is the only proof it
        is running. Every <pid>.json of a live pid counts, whatever argv0 is
        (a versioned desktop binary is invisible to the argv test); a file
        whose procStart differs from the process start time is a pid reused
        after a reboot and is ignored. A claude-like process without a usable
        file proves nothing either way.
        """
        if not hasattr(self, "_claude_ids"):
            ids: set[str] = set()
            valid: set[int] = set()
            for pid, proc in self.proc.items():
                session = self.session_file(pid)
                if session is not None:
                    ids.add(session)
                    valid.add(pid)
            unreadable = sum(1 for pid, proc in self.proc.items()
                             if pid not in valid and claude_like(str(proc.get("command", ""))))
            self._claude_ids = (ids, unreadable)
        return self._claude_ids

    def session_file(self, pid: int) -> str | None:
        """The sessionId in <claude sessions>/<pid>.json, when the file is usable for this live pid."""
        if not self.claude_dir or pid not in self.proc:
            return None
        try:
            session = json.loads((self.claude_dir / f"{pid}.json").read_text())
        except Exception:
            return None
        value = session.get("sessionId") if isinstance(session, dict) else None
        if not isinstance(value, str) or not value:
            return None
        proc_start = norm(session.get("procStart"))
        if proc_start and proc_start != norm(self.proc[pid].get("started")):
            return None
        return value

    def task_running(self, provider: str, task_id: str) -> bool:
        """True unless no live process can be running the task (fails closed).

        For Claude, an unreadable session file of any live Claude process
        means the task might be running there, so closing is not safe.
        """
        if self.argv_mentions(task_id):
            return True
        if provider == "claude":
            ids, unreadable = self.claude_session_ids()
            return task_id in ids or unreadable > 0
        return False

    def codex_app(self, task_id: str) -> str:
        """App Server evidence for the task: claimed | confirmed-absence | ambiguous | unavailable.

        `claimed` is an explicit live app owner. `confirmed-absence` proves the
        app is not running the task. `ambiguous` means the inventory answered
        but holds no live app-owner fact: enough to hand a live pane back to
        cctrl (reconcile-codex does the same), never enough to close a record.
        """
        if not self.codex_ok:
            return "unavailable"
        row = self.codex.get(task_id)
        sources = row.get("sources") if isinstance(row, dict) and isinstance(row.get("sources"), dict) else {}
        app = sources.get("app_server") if isinstance(sources.get("app_server"), dict) else {}
        status = app.get("status")
        return status if status in ("claimed", "confirmed-absence", "ambiguous") else "unavailable"

def protected_reason(ev: Evidence, task_id: str) -> str | None:
    return ev.protect.get(task_id)


def guard_protected(outcome: tuple[str, str, str | None], ev: Evidence, task_id: Any) -> tuple[str, str, str | None]:
    """A close of a record live in the newest pre-boot or newest snapshot becomes a skip (restore needs it)."""
    if outcome[0] == "close" and isinstance(task_id, str) and protected_reason(ev, task_id):
        return "skip", protected_reason(ev, task_id) or "protected", outcome[2]
    return outcome


def evaluate(record: dict[str, Any], ev: Evidence) -> tuple[str, str, str | None]:
    return guard_protected(_evaluate(record, ev), ev, record.get("provider_task_id"))


def _evaluate(record: dict[str, Any], ev: Evidence) -> tuple[str, str, str | None]:
    provider = record.get("provider")
    task_id = record.get("provider_task_id")
    name = record.get("tmux_session") or record.get("name")
    if provider not in ("claude", "codex") or not task_id or not name:
        return "skip", "record lacks provider identity or tmux name", None
    if not ev.panes_ok or not ev.process_ok:
        return "skip", "tmux or process evidence unavailable", None
    if not record.get("pane_id") or not record.get("pane_pid"):
        return "skip", "record has no pane anchor", None
    if name not in ev.live_names:
        return "skip", "tmux name is not live; restore territory, not a conflict", None
    if record.get("control_owner") == "app" or record.get("execution_runtime") == "app-server":
        # Handed off to the app: the provider owns persistence. A leftover
        # tmux name on such a record is not a terminal claim to settle here.
        return "skip", "owned by the app; provider-managed", None
    # Closing needs proof the app is not running the task; handing a live
    # pane back to cctrl only needs the app not to be a live owner.
    app = ev.codex_app(task_id) if provider == "codex" else "confirmed-absence"
    pane = ev.pane(record)
    if pane is None:
        if ev.task_running(provider, task_id):
            return "skip", "the task may be running in another process", None
        if app != "confirmed-absence":
            return "skip", f"Codex App Server evidence {app}; closing needs confirmed-absence", None
        return "close", "stale-anchor", None
    running = ev.running_task(pane, provider)
    if running is None:
        return "skip", "cannot prove which task the pane runs", None
    if running != task_id:
        if ev.task_running(provider, task_id):
            return "skip", f"pane runs {running}, but the task may be running elsewhere", running
        if app != "confirmed-absence":
            return "skip", f"Codex App Server evidence {app}; closing needs confirmed-absence", running
        return "close", f"superseded-by {running}", running
    if app not in ("confirmed-absence", "ambiguous"):
        return "skip", f"Codex App Server evidence {app}", running
    owner = (record.get("control_owner"), record.get("execution_runtime"), record.get("lifecycle_state"))
    if owner == ("cctrl", "tmux", "active"):
        return "none", "already the live cctrl tmux owner", running
    return "own", "live-owner", running


def plan(args: argparse.Namespace) -> int:
    ev = Evidence(load(args.panes), load(args.process), args.claude_sessions or "", load(args.codex) if args.codex else {})
    ev.protect = load_protect(getattr(args, "protect", None))
    rows = []
    for path in sorted(Path(args.records_dir).glob("task-*.json")):
        if path.is_symlink():
            continue
        try:
            record = json.loads(path.read_text())
        except Exception:
            continue
        if record.get("schema_version") != 2 or record.get("host_id") != args.host_id:
            continue
        if record.get("lifecycle_state") in ENDED or not (record.get("tmux_session") or record.get("name")):
            continue
        action, reason, running = evaluate(record, ev)
        rows.append({
            "record": path.name,
            "record_digest": record_digest(record),
            "provider": record.get("provider"),
            "provider_task_id": record.get("provider_task_id"),
            "tmux_session": record.get("tmux_session") or record.get("name"),
            "current": {k: record.get(k) for k in ("control_owner", "execution_runtime", "lifecycle_state")},
            "action": action,
            "reason": reason,
            "running_task_id": running,
        })
    document = {
        "schema_version": 1,
        "kind": "conflict_resolution_plan_v1",
        "sources": {"tmux": "available" if ev.panes_ok else "unavailable",
                    "process": "available" if ev.process_ok else "unavailable",
                    "codex": "available" if ev.codex_ok else "unavailable"},
        "rows": rows,
        "counts": {name: sum(1 for row in rows if row["action"] == name) for name in ("close", "own", "none", "skip")},
    }
    json.dump(document, sys.stdout, sort_keys=True, indent=2)
    sys.stdout.write("\n")
    return 0


def load_protect(path: str | None) -> dict[str, str]:
    """{task id: "protected: live in <snapshot> at <generated_at>"} from the shell-built protect list."""
    if not path:
        return {}
    out: dict[str, str] = {}
    for item in load(path):
        if isinstance(item, dict) and isinstance(item.get("id"), str) and item["id"]:
            out[item["id"]] = f"protected: live in {item.get('snapshot') or 'a snapshot'} at {item.get('generated_at') or 'an unknown time'}"
    return out


def parse_utc(value: Any) -> dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ"):
        try:
            return dt.datetime.strptime(value, fmt)
        except ValueError:
            continue
    return None


def predecessor_candidate(record: dict[str, Any], ev: Evidence, args: argparse.Namespace, live_pane: dict[str, Any],
                          now: dt.datetime | None) -> tuple[str, str]:
    """(action, reason) for one open record that claims the launch's tmux name."""
    if record.get("control_owner") == "app" or record.get("execution_runtime") == "app-server":
        return "skip", "owned by the app; provider-managed"
    task_id = record.get("provider_task_id")
    if isinstance(task_id, str) and task_id in ev.protect:
        return "skip", ev.protect[task_id]
    superseded = f"superseded-by {args.expect_task}"
    if not task_id:
        if record.get("name") != args.name:
            return "skip", "receipt name differs"
        if record.get("pane_id") and record.get("pane_id") == live_pane.get("pane_id") \
                and str(record.get("pane_pid") or "") == str(live_pane.get("pane_pid") or ""):
            return "skip", "shares the live pane"
        observed = [t for t in (parse_utc(record.get("created_at")), parse_utc(record.get("last_observed_at"))) if t]
        if not observed or now is None:
            return "skip", "receipt age unknown"
        if (now - max(observed)).total_seconds() <= PROVISIONAL_GRACE_SECONDS:
            return "skip", "provisional receipt still within the start-up grace"
        return "close", superseded
    provider = record.get("provider")
    if provider not in ("claude", "codex"):
        return "skip", "record lacks provider identity"
    if ev.task_running(provider, task_id):
        return "skip", "the task may be running in another process"
    if provider == "codex":
        app = ev.codex_app(task_id)
        if app != "confirmed-absence":
            return "skip", f"Codex App Server evidence {app}; closing needs confirmed-absence"
    return "close", superseded


def plan_predecessors(args: argparse.Namespace) -> int:
    ev = Evidence(load(args.panes), load(args.process), args.claude_sessions or "", load(args.codex) if args.codex else {})
    ev.protect = load_protect(args.protect)
    now = parse_utc(args.now) if args.now else dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
    document: dict[str, Any] = {
        "schema_version": 1, "kind": "predecessor_plan_v1", "name": args.name, "expect_task": args.expect_task,
        "proved": False, "global_skip": None, "rows": [],
    }

    def finish() -> int:
        json.dump(document, sys.stdout, sort_keys=True, indent=2)
        sys.stdout.write("\n")
        return 0

    if not ev.panes_ok or not ev.process_ok:
        document["global_skip"] = "skip: evidence unavailable"
        return finish()
    live = [p for p in ev.panes if p.get("session_name") == args.name]
    running = ev.running_task(live[0], args.provider) if len(live) == 1 else None
    if running != args.expect_task:
        document["global_skip"] = f"skip: cannot prove {args.name} runs {args.expect_task} (running: {running or 'none'})"
        return finish()
    document["proved"] = True
    exclude = Path(args.exclude_record).name if args.exclude_record else None
    paths = sorted(Path(args.records_dir).glob("task-*.json")) + sorted(Path(args.records_dir).glob("launch-*.json"))
    for path in paths:
        if path.is_symlink() or path.name == exclude:
            continue
        try:
            record = json.loads(path.read_text())
        except Exception:
            continue
        if not isinstance(record, dict) or record.get("schema_version") != 2 or record.get("host_id") != args.host_id:
            continue
        if record.get("lifecycle_state") in ENDED or args.name not in (record.get("tmux_session"), record.get("name")):
            continue
        if record.get("provider_task_id") == args.expect_task:
            continue
        action, reason = predecessor_candidate(record, ev, args, live[0], now)
        document["rows"].append({
            "record": path.name,
            "record_digest": record_digest(record),
            "provider": record.get("provider"),
            "provider_task_id": record.get("provider_task_id"),
            "provisional": not record.get("provider_task_id"),
            "current": {"owner": record.get("control_owner"), "runtime": record.get("execution_runtime"),
                        "state": record.get("lifecycle_state"), "restore_strategy": record.get("restore_strategy")},
            "action": action,
            "reason": reason,
        })
    return finish()


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--records-dir", required=True)
    p.add_argument("--panes", required=True)
    p.add_argument("--process", required=True)
    p.add_argument("--claude-sessions")
    p.add_argument("--codex")
    p.add_argument("--host-id", required=True)
    p.add_argument("--protect")
    p.set_defaults(func=plan)
    q = sub.add_parser("plan-predecessors")
    for flag in ("--records-dir", "--panes", "--process", "--host-id", "--name", "--expect-task", "--provider"):
        q.add_argument(flag, required=True)
    for flag in ("--claude-sessions", "--codex", "--exclude-record", "--protect", "--now"):
        q.add_argument(flag)
    q.set_defaults(func=plan_predecessors)
    args = parser.parse_args()
    try:
        return args.func(args)
    except Exception as exc:  # fail closed at the shell boundary
        print(json.dumps({"ok": False, "error": str(exc)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
