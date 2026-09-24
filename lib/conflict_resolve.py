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
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

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
    first = command.split(None, 1)[0] if command.strip() else ""
    base = first.rsplit("/", 1)[-1]
    return base if base in ("claude", "codex") else ""


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
            path = self.claude_dir / f"{agent['pid']}.json"
            try:
                session = json.loads(path.read_text())
            except Exception:
                return None
            value = session.get("sessionId") if isinstance(session, dict) else None
            return value if isinstance(value, str) and value else None
        if provider == "codex":
            ids = set(UUID.findall(str(agent.get("command", ""))))
            return ids.pop() if len(ids) == 1 else None
        return None

    def argv_mentions(self, task_id: str) -> bool:
        return any(task_id in str(p.get("command", "")) for p in self.proc.values())

    def codex_app(self, task_id: str) -> str:
        """claimed | confirmed-absence | unavailable for the App Server source."""
        if not self.codex_ok:
            return "unavailable"
        row = self.codex.get(task_id)
        sources = row.get("sources") if isinstance(row, dict) and isinstance(row.get("sources"), dict) else {}
        app = sources.get("app_server") if isinstance(sources.get("app_server"), dict) else {}
        status = app.get("status")
        return status if status in ("claimed", "confirmed-absence") else "unavailable"


def evaluate(record: dict[str, Any], ev: Evidence) -> tuple[str, str, str | None]:
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
    app = ev.codex_app(task_id) if provider == "codex" else "confirmed-absence"
    pane = ev.pane(record)
    if pane is None:
        if ev.argv_mentions(task_id):
            return "skip", "a process still references the task", None
        if app != "confirmed-absence":
            return "skip", f"Codex App Server evidence {app}", None
        return "close", "stale-anchor", None
    running = ev.running_task(pane, provider)
    if running is None:
        return "skip", "cannot prove which task the pane runs", None
    if app != "confirmed-absence":
        return "skip", f"Codex App Server evidence {app}", running
    if running != task_id:
        return "close", f"superseded-by {running}", running
    owner = (record.get("control_owner"), record.get("execution_runtime"), record.get("lifecycle_state"))
    if owner == ("cctrl", "tmux", "active"):
        return "none", "already the live cctrl tmux owner", running
    return "own", "live-owner", running


def plan(args: argparse.Namespace) -> int:
    ev = Evidence(load(args.panes), load(args.process), args.claude_sessions or "", load(args.codex) if args.codex else {})
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
    p.set_defaults(func=plan)
    args = parser.parse_args()
    try:
        return args.func(args)
    except Exception as exc:  # fail closed at the shell boundary
        print(json.dumps({"ok": False, "error": str(exc)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
