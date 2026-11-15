#!/usr/bin/env python3
"""Pure snapshot normalization and ownership-aware restore policy for cctrl."""

from __future__ import annotations

import argparse
import datetime as dt
import functools
import hashlib
import json
import os
import re
import shlex
import sys
from pathlib import Path
from typing import Any


VALID_DISPOSITIONS = {
    "restore",
    "provider-managed",
    "already-live",
    "conflict",
    "unknown",
    "insufficient-evidence",
}
RESUME_KINDS = {"claude-session-id", "codex-thread-id"}
RESUMABLE_STATES = {"active", "inactive", "provisional", "resumable"}
ENDED_STATES = {"closed", "archived", "released"}
# plan 081, P2 impact: how long a provisional record may go with no live tmux
# session before capture() stops offering it as a tmux-resume restore
# candidate. _session_write_metadata writes the launch-*.json receipt before
# `tmux new-session` runs, so a session that is genuinely still starting up
# can briefly have a provisional record with no matching live tmux session;
# 5 minutes comfortably covers that race (and a slow health-check retry)
# without keeping a record that's actually stuck (P2's bug: it never reached
# `closed`) looking like a live in-progress launch indefinitely.
PROVISIONAL_STALE_GRACE_SECONDS = 300
# Codex provider titles are the whole first prompt (pastes included, up to
# hundreds of KB). A snapshot only needs a readable label plus a hash that
# identifies the full text.
LABEL_MAX_CHARS = 200
# Fields restore planning and launch replay actually consume. content_digest
# covers only these, so timestamps and activity never force a new history file.
DIGEST_TASK_FIELDS = (
    "provider", "provider_task_id", "host_id", "origin", "execution_runtime", "control_owner",
    "lifecycle_state", "restore_strategy", "registered_by_cctrl", "launched_by_cctrl", "lineage",
    "tmux_session", "resume_identity_kind", "resume_identity", "cwd", "purpose", "display_label",
    "display_label_sha256", "agent", "launch_flags", "live", "recovery_action", "recovery_reason",
    "shadowed_task_ids",
)


def load(path: str) -> Any:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def dump(value: Any) -> None:
    json.dump(value, sys.stdout, sort_keys=True, indent=2)
    sys.stdout.write("\n")


def text(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def lineage(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        value = {}
    return {
        "forked_from_id": text(value.get("forked_from_id")),
        "parent_thread_id": text(value.get("parent_thread_id")),
        "derived_root_id": text(value.get("derived_root_id")),
        "derived_root_basis": text(value.get("derived_root_basis")),
    }


def action_for(row: dict[str, Any]) -> tuple[str, str]:
    owner = row.get("control_owner")
    runtime = row.get("execution_runtime")
    state = row.get("lifecycle_state")
    strategy = row.get("restore_strategy")
    if "conflict" in (owner, runtime, state):
        return "conflict", "snapshot contains contradictory ownership evidence"
    # Only an observed live tmux session is already live. A cctrl/tmux/active
    # record whose pane is gone (killed, crashed, rebooted) is exactly what the
    # restore planner must judge, so it must not be labelled live here.
    if row.get("live") is True:
        return "already-live", "task had a live cctrl tmux owner at capture time"
    if owner == "app" or runtime == "app-server" or strategy == "provider-managed" or state == "released":
        return "provider-managed", "provider owns persistence; cctrl must not relaunch it"
    if owner == "unknown" or runtime == "unknown" or state == "unknown":
        return "unknown", "snapshot ownership is unknown"
    return "insufficient-evidence", "snapshot is informational until current ownership evidence is joined"


def _parse_rfc3339_utc(value: Any) -> dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return None


def provisional_is_stale(observed_at: Any, generated_at: Any) -> bool:
    """True when a provisional record has had no live tmux session for longer
    than PROVISIONAL_STALE_GRACE_SECONDS (plan 081, P2 impact).

    Age is unknown -> fail closed (treated as stale), since an unparseable or
    missing timestamp is not evidence that this is a fresh, still-starting
    launch.
    """
    observed = _parse_rfc3339_utc(observed_at)
    generated = _parse_rfc3339_utc(generated_at)
    if observed is None or generated is None:
        return True
    return (generated - observed).total_seconds() > PROVISIONAL_STALE_GRACE_SECONDS


def bounded(value: Any) -> tuple[str | None, str | None]:
    """Return (label capped at LABEL_MAX_CHARS, sha256 of the full text when cut)."""
    value = text(value)
    if value is None or len(value) <= LABEL_MAX_CHARS:
        return value, None
    return value[:LABEL_MAX_CHARS - 1] + "\u2026", hashlib.sha256(value.encode("utf-8", "replace")).hexdigest()


def apply_label_bounds(row: dict[str, Any]) -> None:
    row["purpose"], _ = bounded(row.get("purpose"))
    row["display_label"], digest = bounded(row.get("display_label"))
    if digest:
        row["display_label_sha256"] = digest


def actionable(row: dict[str, Any]) -> bool:
    """False for discovery-only rows the restore planner can never act on.

    The planner returns `unknown` for any row whose owner or runtime is unknown,
    so a catalogue row with no cctrl provenance, no tmux name, and no known
    owner or runtime only costs bytes. Those are counted, not stored.
    """
    if row.get("registered_by_cctrl") is True or row.get("launched_by_cctrl") is True or text(row.get("tmux_session")):
        return True
    return row.get("control_owner") not in (None, "unknown") or row.get("execution_runtime") not in (None, "unknown")


def content_digest(document: dict[str, Any]) -> str:
    tasks = [{field: task.get(field) for field in DIGEST_TASK_FIELDS} for task in document["tasks"]]
    tasks.sort(key=lambda task: json.dumps([task.get("provider"), task.get("provider_task_id"), task.get("tmux_session")], sort_keys=True))
    basis = {
        "schema_version": document["schema_version"],
        "host_id": document["host_id"],
        "capture_status": document["capture_quality"]["status"],
        "omitted": document["omitted_task_references"],
        "tasks": tasks,
    }
    return hashlib.sha256(json.dumps(basis, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def select_tmux_source(candidates: list[dict[str, Any]], session: dict[str, Any]) -> tuple[dict[str, Any], list[str], str | None]:
    """Pick the catalogue row that owns a live tmux session.

    Several registry records can claim one tmux name (a resumed or relaunched
    conversation leaves its predecessor behind). The live session's own
    provider id decides; catalogue order never does. Returns (source,
    shadowed task ids, ambiguity reason or None).
    """
    ids = [text(c.get("provider_task_id")) or "" for c in candidates]
    live_id = text(session.get("provider_task_id")) or text(session.get("session_id"))
    if live_id:
        exact = [c for c in candidates if text(c.get("provider_task_id")) == live_id]
        if len(exact) == 1:
            return exact[0], sorted(i for i in ids if i and i != live_id), None
        if len(exact) > 1:
            return {}, sorted(i for i in ids if i), "ambiguous-tmux-claim: duplicate records for the live task"
        if candidates:
            return {}, sorted(i for i in ids if i), "ambiguous-tmux-claim: no record matches the live task"
        return {}, [], None
    if len(candidates) == 1:
        return candidates[0], [], None
    if len(candidates) > 1:
        return {}, sorted(i for i in ids if i), "ambiguous-tmux-claim: several records and no live task id"
    return {}, [], None


@functools.lru_cache(maxsize=4)
def launch_records(metadata_dir: str) -> dict[str, dict[str, Any]]:
    """tmux name -> full metadata record, first record by sorted path wins (read once per capture)."""
    root = Path(metadata_dir)
    records: dict[str, dict[str, Any]] = {}
    if not root.is_dir():
        return records
    for path in sorted(root.glob("*.json")):
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(value, dict):
            continue
        for name in {value.get("tmux_session"), value.get("name")}:
            if isinstance(name, str) and name and name not in records:
                records[name] = value
    return records


def launch_commands(metadata_dir: str) -> dict[str, str]:
    """tmux name -> launch_command, derived from launch_records."""
    return {name: text(record.get("launch_command")) for name, record in launch_records(metadata_dir).items() if text(record.get("launch_command"))}


def launch_flags_for(metadata_dir: str, tmux_name: str | None) -> dict[str, Any]:
    if not tmux_name:
        return {}
    record = launch_records(metadata_dir).get(tmux_name, {})
    flags: dict[str, Any] = {}
    command = text(record.get("launch_command"))
    if command:
        try:
            argv = shlex.split(command)
        except ValueError:
            argv = []
        names = {
            "--model": "model",
            "--profile": "profile",
            "--permission-mode": "permission_mode",
            "--sandbox": "sandbox",
            "--ask-for-approval": "ask_for_approval",
            "--peer": "peer",
            "--agent": "agent",
        }
        index = 0
        while index < len(argv):
            token = argv[index]
            if token == "--no-bridge":
                flags["no_bridge"] = True
            elif token in names and index + 1 < len(argv):
                flags[names[token]] = argv[index + 1]
                index += 1
            else:
                for option, key in names.items():
                    if token.startswith(option + "="):
                        flags[key] = token.split("=", 1)[1]
                        break
            index += 1
    # Plan 071 phase 6: the metadata record's own `profile` field (session
    # identity, set at launch) is more reliable than re-parsing launch_command
    # -- it is recorded directly rather than reconstructed from argv, and a
    # pre-change record (no such field) still falls back to the argv parse
    # above. The caller is still responsible for handling a profile that has
    # since been renamed or deleted (e.g. the realign path drops it rather
    # than forwarding a name that would now fail closed).
    record_profile = record.get("profile")
    if isinstance(record_profile, str) and record_profile:
        flags["profile"] = record_profile
    # Plan 100: the record's role and orchestrator kind travel with the
    # launch flags so a restore or realign replays them.
    for field in ("role", "orch_kind"):
        value = record.get(field)
        if isinstance(value, str) and value:
            flags[field] = value
    # Plan 106 P3b: a lean MCP mode travels with the flags. Only the two lean
    # values are replayed; a record without the field (or "inherit") adds
    # nothing, so a restore never invents a mode. Only the mode NAME is kept:
    # the Claude <key>.mcp.json is rebuilt at launch, never snapshotted.
    mcp_mode = record.get("mcp_mode")
    if mcp_mode in ("none", "minimal"):
        flags["mcp_mode"] = mcp_mode
    return flags


TIE_MARGIN_DEFAULT = 120
PROCESS_AGENTS = {"claude", "codex", "cctrl"}
RESUME_FLAGS = {"--resume", "-r", "--session-id"}


def _parse_time(value: Any) -> float | None:
    """Epoch seconds for an RFC 3339 UTC string (fractions and a +00:00 suffix allowed), else None."""
    if not isinstance(value, str) or not value:
        return None
    candidate = value.strip()
    if candidate.endswith("Z"):
        candidate = candidate[:-1]
    elif candidate.endswith("+00:00"):
        candidate = candidate[:-6]
    if "." in candidate:
        candidate = candidate.split(".", 1)[0]
    try:
        parsed = dt.datetime.strptime(candidate, "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    return parsed.replace(tzinfo=dt.timezone.utc).timestamp()


def _iso(epoch: float | None) -> str | None:
    if epoch is None:
        return None
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def transcript_stat(task_id: str | None, projects_dirs: list[str]) -> tuple[float, int] | None:
    """(mtime, size) of the newest <projects>/*/<id>.jsonl, or None."""
    if not task_id or "/" in task_id or task_id in (".", ".."):
        return None
    best: tuple[float, int] | None = None
    for directory in projects_dirs:
        root = Path(directory)
        if not root.is_dir():
            continue
        try:
            for path in root.glob("*/" + task_id + ".jsonl"):
                try:
                    info = path.stat()
                except OSError:
                    continue
                if best is None or info.st_mtime > best[0]:
                    best = (info.st_mtime, info.st_size)
        except OSError:
            continue
    return best


def tie_break(claims: list[dict[str, Any]], host_id: str, projects_dirs: list[str], margin: int) -> tuple[dict[str, Any] | None, dict[str, Any] | None, str]:
    """Pick one of several open claims on a tmux name that is not live.

    Returns (chosen, evidence, reason). chosen is None (a refusal, with the
    specific reason) unless exactly one eligible claim has the newest activity
    by at least `margin` seconds and all claims with activity evidence share
    one cwd. Thin evidence refuses; it never guesses.
    """
    candidates = [
        c for c in claims
        if (text(c.get("host_id")) or host_id) == host_id
        and c.get("registered_by_cctrl") is True and c.get("launched_by_cctrl") is True
        and c.get("restore_strategy") in ("tmux", "tmux-resume")
        and text(c.get("provider")) in ("claude", "codex")
    ]
    if not candidates:
        return None, None, "no eligible candidate among the open claims"
    if len({text(c.get("provider")) for c in candidates}) > 1:
        return None, None, "the open claims belong to different providers"
    provider = text(candidates[0].get("provider"))
    detail: list[dict[str, Any]] = []
    timed: list[tuple[float, dict[str, Any]]] = []
    for candidate in candidates:
        task_id = text(candidate.get("provider_task_id"))
        stat = transcript_stat(task_id, projects_dirs) if provider == "claude" else None
        recency = _parse_time(candidate.get("recency"))
        moment = stat[0] if stat else (recency if provider == "codex" else None)
        detail.append({
            "id": task_id,
            "transcript_mtime": _iso(stat[0]) if stat else None,
            "transcript_bytes": stat[1] if stat else None,
            "recency": text(candidate.get("recency")),
            "cwd": text(candidate.get("cwd")),
        })
        if moment is not None:
            timed.append((moment, candidate))
    if not timed:
        return None, None, "no candidate has a transcript"
    if len({text(c.get("cwd")) for _, c in timed}) > 1:
        return None, None, "candidates with activity evidence have different cwds"
    timed.sort(key=lambda item: item[0], reverse=True)
    # An eligible claim with no activity evidence of its own (its transcript
    # may live in a config dir nobody searched) but a newer record than the
    # winner's moment could be the real current conversation: refuse.
    timed_ids = {id(c) for _, c in timed}
    for candidate in candidates:
        if id(candidate) in timed_ids:
            continue
        recency = _parse_time(candidate.get("recency"))
        if recency is not None and recency > timed[0][0]:
            return None, None, "an eligible claim without activity evidence has a newer record than the winner"
    lead = None if len(timed) == 1 else timed[0][0] - timed[1][0]
    if lead is not None and lead < margin:
        return None, None, f"the two newest candidates are within {margin}s of each other"
    chosen = timed[0][1]
    evidence = {
        "basis": "transcript-mtime" if provider == "claude" else "record-recency",
        "chosen": text(chosen.get("provider_task_id")),
        "margin_s": None if lead is None else int(lead),
        "candidates": detail,
    }
    return chosen, evidence, ""


def process_running(process: dict[str, Any], task_ids: list[str]) -> tuple[int, str] | None:
    """(pid, matched id) of a claude/codex/cctrl process that resumes one of the ids.

    Whole-token matching only: the id must follow --resume / -r / --session-id
    (or `resume` for codex) as its own argv token, or sit in --resume=ID. A
    substring match would catch a grep, a peer command or an agent's Bash line.
    """
    wanted = {i for i in task_ids if i}
    if not wanted:
        return None
    for item in process.get("processes") or []:
        if not isinstance(item, dict) or not isinstance(item.get("command"), str):
            continue
        tokens = item["command"].split()
        if not tokens or os.path.basename(tokens[0]) not in PROCESS_AGENTS:
            continue
        agent = os.path.basename(tokens[0])
        for index, token in enumerate(tokens):
            following = tokens[index + 1] if index + 1 < len(tokens) else None
            if token in RESUME_FLAGS and following in wanted:
                return int(item.get("pid") or 0), following
            if agent in ("codex", "cctrl") and token == "resume" and following in wanted:
                return int(item.get("pid") or 0), following
            if token.startswith(("--resume=", "--session-id=")) and token.split("=", 1)[1] in wanted:
                return int(item.get("pid") or 0), token.split("=", 1)[1]
    return None


UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
NODE_RUNNERS = {"node", "nodejs", "bun"}


def is_claude_command(tokens: list[str]) -> bool:
    """A claude CLI: argv0 `claude`, or node/bun running a claude cli.js."""
    if not tokens:
        return False
    first = os.path.basename(tokens[0])
    if first == "claude":
        return True
    if first in NODE_RUNNERS:
        for token in tokens[1:4]:
            if os.path.basename(token) == "cli.js" and "claude" in token.lower():
                return True
    return False


def bare_resume_command(command: str) -> bool:
    """True when this claude resumes a conversation without naming it in argv.

    -c/--continue never takes a value, so it is always bare. --resume/-r is
    bare when it has no value, a flag after it, or a value that is not a
    conversation UUID (a picker search term). --resume=<value> follows the
    same rule. node .../cli.js --resume counts.
    """
    tokens = command.split()
    if not is_claude_command(tokens):
        return False
    for index, token in enumerate(tokens[1:], start=1):
        if token in ("--continue", "-c"):
            return True
        if token in ("--resume", "-r"):
            following = tokens[index + 1] if index + 1 < len(tokens) else None
            if following is None or following.startswith("-") or not UUID_RE.match(following):
                return True
        elif token.startswith("--resume="):
            if not UUID_RE.match(token.split("=", 1)[1]):
                return True
    return False


def _real(path: str | None) -> str | None:
    if not path:
        return None
    try:
        return os.path.realpath(path)
    except OSError:
        return path


def _squash(value: Any) -> str:
    return " ".join(str(value or "").split())


def claude_config_sessions_dirs(explicit: list[str], metadata_dir: str | None) -> list[str]:
    """Directories that may hold <pid>.json for a live claude: the given ones plus
    <claude_config_dir>/sessions for every config dir a launch record names."""
    dirs: list[str] = [d for d in explicit if d]
    if metadata_dir:
        for record in launch_records(metadata_dir).values():
            config = text(record.get("claude_config_dir"))
            if config and os.path.isabs(config):
                dirs.append(os.path.join(config, "sessions"))
    seen: list[str] = []
    for directory in dirs:
        if directory not in seen:
            seen.append(directory)
    return seen


def claude_live_view(process: dict[str, Any], sessions_dirs: list[str]) -> tuple[dict[str, int], list[tuple[int, str | None]]]:
    """The conversations live claudes run, read from session files.

    Every <sessions dir>/<pid>.json whose pid is alive (it is in the process
    table) and whose procStart equals that process's start time (a pid-reuse
    guard; the process table is read with LC_ALL=C TZ=UTC) names the
    conversation in sessionId, whatever argv0 is (a versioned binary, a
    desktop entrypoint). Stale or mismatched files are ignored.

    A claude resumed without naming a conversation (bare --resume, -c, a
    picker search term) whose pid has no valid session file is "unknown":
    (pid, realpath of its cwd or None). Returns ({session id: pid}, [unknown]).
    """
    known: dict[str, int] = {}
    unknown: list[tuple[int, str | None]] = []
    by_pid: dict[int, dict[str, Any]] = {}
    for item in process.get("processes") or []:
        if not isinstance(item, dict) or not isinstance(item.get("command"), str):
            continue
        try:
            by_pid[int(item.get("pid") or 0)] = item
        except (TypeError, ValueError):
            continue
    valid_pids: set[int] = set()
    for directory in sessions_dirs:
        try:
            names = sorted(os.listdir(directory))
        except OSError:
            continue
        for name in names:
            if not name.endswith(".json") or not name[:-5].isdigit():
                continue
            pid = int(name[:-5])
            item = by_pid.get(pid)
            if item is None:
                continue
            try:
                value = json.loads((Path(directory) / name).read_text(encoding="utf-8"))
            except Exception:
                continue
            if not isinstance(value, dict) or not text(value.get("sessionId")) or value.get("pid", pid) != pid:
                continue
            started = _squash(item.get("started"))
            if not started or _squash(value.get("procStart")) != started:
                continue
            known.setdefault(text(value.get("sessionId")) or "", pid)
            valid_pids.add(pid)
    for pid, item in by_pid.items():
        if pid in valid_pids or not bare_resume_command(item["command"]):
            continue
        unknown.append((pid, _real(text(item.get("cwd")))))
    return known, unknown


def capture(args: argparse.Namespace) -> int:
    catalogue = load(args.catalogue)
    sessions = load(args.sessions)
    process = load(args.process)
    if not isinstance(catalogue, dict) or catalogue.get("schema_version") != 2:
        raise ValueError("task catalogue is not schema 2")
    rows = catalogue.get("rows")
    if not isinstance(rows, list) or not isinstance(sessions, list):
        raise ValueError("catalogue rows or session list is malformed")

    by_tmux: dict[str, list[dict[str, Any]]] = {}
    for item in rows:
        if isinstance(item, dict) and text(item.get("tmux_session")):
            by_tmux.setdefault(item["tmux_session"], []).append(item)

    tasks: list[dict[str, Any]] = []
    seen: set[tuple[str, str | None, str | None]] = set()

    # Live tmux compatibility rows carry launch configuration and provider resume ids.
    for session in sessions:
        if not isinstance(session, dict):
            continue
        name = text(session.get("name"))
        source, shadowed, ambiguity = select_tmux_source(by_tmux.get(name or "", []), session)
        agent = text(session.get("agent"))
        provider = text(source.get("provider")) or ("claude" if agent in ("claude", "claude-code") else "codex" if agent in ("codex", "openai") else "unknown")
        task_id = text(source.get("provider_task_id")) or text(session.get("provider_task_id")) or text(session.get("session_id"))
        host_id = text(source.get("host_id")) or args.host_id
        strategy = source.get("restore_strategy")
        if strategy == "tmux":
            strategy = "tmux-resume"
        resume_kind = "claude-session-id" if provider == "claude" else "codex-thread-id" if provider == "codex" else None
        row = {
            "provider": provider,
            "provider_task_id": task_id,
            "host_id": host_id,
            "origin": source.get("origin", session.get("origin", "unknown")),
            "execution_runtime": source.get("execution_runtime", session.get("execution_runtime", "unknown")),
            "control_owner": source.get("control_owner", session.get("control_owner", "unknown")),
            "lifecycle_state": source.get("lifecycle_state", session.get("lifecycle_state", "unknown")),
            "restore_strategy": strategy,
            "registered_by_cctrl": source.get("registered_by_cctrl") is True or session.get("registered_by_cctrl") is True,
            "launched_by_cctrl": source.get("launched_by_cctrl") is True or session.get("launched_by_cctrl") is True,
            "registration_provenance": source.get("registration_provenance") if isinstance(source.get("registration_provenance"), list) else [],
            "launch_provenance": source.get("launch_provenance") if isinstance(source.get("launch_provenance"), list) else [],
            "lineage": lineage(source.get("lineage", session.get("lineage"))),
            "tmux_session": name,
            "resume_identity_kind": resume_kind if task_id else None,
            "resume_identity": task_id,
            "observed_at": text(source.get("recency")) or text(session.get("last_observed_at")) or args.generated_at,
            "ownership_evidence": source.get("ownership_evidence") if isinstance(source.get("ownership_evidence"), list) else [],
            "cwd": text(source.get("cwd")) or text(session.get("dir")),
            "purpose": text(session.get("purpose")),
            "display_label": text(session.get("display_label")),
            "agent": agent,
            "launch_flags": session.get("launch_flags") if isinstance(session.get("launch_flags"), dict) else launch_flags_for(args.metadata_dir, name),
            "transcript_path": text(session.get("transcript")),
            "transcript_bytes": session.get("transcript_bytes"),
            "last_active": text(session.get("last_active")),
            "live": True,
        }
        # Which tmux server held the session (mdec-1110). Written only when
        # cctrl has a primary configured; a row without it means the default
        # server, which is how every older snapshot reads.
        if text(session.get("tmux_server")):
            row["tmux_server"] = text(session.get("tmux_server"))
        apply_label_bounds(row)
        if shadowed:
            row["shadowed_task_ids"] = shadowed
        if ambiguity:
            # Several records claim this tmux name and none is provably the one
            # running in it. Never let session-level fields make it restorable.
            row["control_owner"] = row["execution_runtime"] = row["lifecycle_state"] = "unknown"
            row["recovery_action"], row["recovery_reason"] = "unknown", ambiguity
        else:
            row["recovery_action"], row["recovery_reason"] = action_for(row)
        key = (provider, task_id, name)
        seen.add(key)
        tasks.append(row)

    # Provider-managed and discovery-only tasks do not necessarily have tmux rows.
    # Rows whose tmux name is live were settled above (the live session picked
    # its row). For a name that is not live (the normal state after a reboot)
    # only open records compete for it: an ended record never hides another,
    # and several open claims with nothing to tell them apart are ambiguous
    # rather than decided by catalogue order.
    omitted: dict[str, int] = {}
    live_names = {t.get("tmux_session") for t in tasks if t.get("tmux_session")}
    open_claims: dict[str, list[dict[str, Any]]] = {}
    for source in rows:
        # App-owned records no longer claim a terminal, so they never make a
        # cctrl record on the same dead name ambiguous.
        if isinstance(source, dict) and text(source.get("tmux_session")) and source.get("lifecycle_state") not in ENDED_STATES \
                and source.get("control_owner") != "app" and source.get("execution_runtime") != "app-server" \
                and source["tmux_session"] not in live_names:
            open_claims.setdefault(source["tmux_session"], []).append(source)
    # Several open claims on a dead name: pick by activity evidence or refuse.
    decisions: dict[str, tuple[dict[str, Any] | None, dict[str, Any] | None, str]] = {
        name: tie_break(claims, args.host_id, list(args.claude_projects_dir or []), args.tie_margin)
        for name, claims in open_claims.items() if len(claims) > 1
    }
    for source in rows:
        if not isinstance(source, dict):
            continue
        provider = text(source.get("provider")) or "unknown"
        task_id = text(source.get("provider_task_id"))
        tmux_name = text(source.get("tmux_session"))
        if (provider, task_id, tmux_name) in seen or (tmux_name and tmux_name in live_names):
            continue
        claims = open_claims.get(tmux_name or "", []) if source.get("lifecycle_state") not in ENDED_STATES else []
        decision = decisions.get(tmux_name or "") if len(claims) > 1 else None
        representative = (decision[0] if decision and decision[0] is not None else claims[0]) if len(claims) > 1 else None
        if len(claims) > 1 and source is not representative:
            continue  # represented by one claim's row, the rest listed in its shadowed_task_ids
        strategy = source.get("restore_strategy")
        if strategy == "tmux":
            strategy = "tmux-resume"
        # plan 081, P2 impact: this loop only ever sees rows whose tmux name
        # has no live session right now, so a provisional record here is
        # either a launch that is still (briefly) starting up, or one stuck
        # by the P2 bug (never promoted, never closed). Age is the only
        # signal that tells them apart; a stale one must not be offered as a
        # tmux-resume restore candidate.
        if strategy == "tmux-resume" and source.get("lifecycle_state") == "provisional" \
                and provisional_is_stale(source.get("recency"), args.generated_at):
            strategy = None
        resume_kind = "claude-session-id" if provider == "claude" else "codex-thread-id" if provider == "codex" else None
        row = {
            "provider": provider,
            "provider_task_id": task_id,
            "host_id": text(source.get("host_id")) or args.host_id,
            "origin": source.get("origin", "unknown"),
            "execution_runtime": source.get("execution_runtime", "unknown"),
            "control_owner": source.get("control_owner", "unknown"),
            "lifecycle_state": source.get("lifecycle_state", "unknown"),
            "restore_strategy": strategy,
            "registered_by_cctrl": source.get("registered_by_cctrl") is True,
            "launched_by_cctrl": source.get("launched_by_cctrl") is True,
            "registration_provenance": source.get("registration_provenance") if isinstance(source.get("registration_provenance"), list) else [],
            "launch_provenance": source.get("launch_provenance") if isinstance(source.get("launch_provenance"), list) else [],
            "lineage": lineage(source.get("lineage")),
            "tmux_session": tmux_name,
            "resume_identity_kind": resume_kind if task_id else None,
            "resume_identity": task_id,
            "observed_at": text(source.get("recency")) or args.generated_at,
            "ownership_evidence": source.get("ownership_evidence") if isinstance(source.get("ownership_evidence"), list) else [],
            "cwd": text(source.get("cwd")),
            "purpose": None,
            "display_label": text(source.get("display_title")),
            "agent": provider if provider in ("claude", "codex") else None,
            # Replay flags for rows that are not live too (the fleet after a
            # reboot, or while restore is only partly done), so a capture taken
            # then still carries what restore needs.
            "launch_flags": launch_flags_for(args.metadata_dir, tmux_name),
            "transcript_path": None,
            "transcript_bytes": None,
            "last_active": text(source.get("recency")),
            "live": source.get("action_capabilities", {}).get("tmux_attach", {}).get("supported") is True,
        }
        if not actionable(row):
            key = f"{provider}:{row.get('lifecycle_state') or 'unknown'}"
            omitted[key] = omitted.get(key, 0) + 1
            continue
        apply_label_bounds(row)
        if len(claims) > 1:
            row["shadowed_task_ids"] = sorted(text(c.get("provider_task_id")) or "" for c in claims if c is not source)
            if decision and decision[0] is not None:
                row["tie_break"] = decision[1]
                row["recovery_action"], row["recovery_reason"] = action_for(row)
            else:
                row["control_owner"] = row["execution_runtime"] = row["lifecycle_state"] = "unknown"
                row["recovery_action"] = "unknown"
                row["recovery_reason"] = "ambiguous-tmux-claim: several open records claim a tmux name that is not live" + (f" ({decision[2]})" if decision and decision[2] else "")
        else:
            row["recovery_action"], row["recovery_reason"] = action_for(row)
        tasks.append(row)

    source_status = catalogue.get("source_status") if isinstance(catalogue.get("source_status"), dict) else {}
    errors = list(catalogue.get("source_errors") or [])
    process_status = process.get("status") if isinstance(process, dict) else "unavailable"
    if process_status != "available":
        errors.append({"source": "process", "status": "unavailable", "error": process.get("error", "process-snapshot-failed") if isinstance(process, dict) else "malformed-process-snapshot"})
    mandatory = {"registry": source_status.get("registry"), "tmux": source_status.get("tmux"), "process": process_status}
    if any(task.get("provider") == "codex" for task in tasks):
        mandatory["codex_provider"] = source_status.get("codex_provider")
    required_error_sources = {"registry", "tmux", "process"}
    if "codex_provider" in mandatory:
        required_error_sources.update({"codex-provider", "codex_provider"})
    partial_required = any(
        isinstance(error, dict)
        and error.get("source") in required_error_sources
        and error.get("status") in {"partial", "unavailable"}
        for error in errors
    )
    complete = all(value == "available" for value in mandatory.values()) and not partial_required
    capture_quality = {"status": "complete" if complete else "degraded", "mandatory_sources": mandatory}
    candidates = sum(1 for task in tasks if task.get("restore_strategy") == "tmux-resume" and task.get("registered_by_cctrl") is True and task.get("launched_by_cctrl") is True)
    document = {
        "schema_version": 2,
        "generated_at": args.generated_at,
        "host_id": args.host_id,
        "hostname": args.hostname,
        "resource_metadata": load(args.resources),
        "tasks": tasks,
        "task_reference_count": len(tasks),
        "catalogue_task_count": len(rows),
        "omitted_task_references": {"count": sum(omitted.values()), "by_provider_state": dict(sorted(omitted.items()))},
        "restore_candidate_count": candidates,
        "capture_quality": capture_quality,
        "source_errors": errors,
        # Compatibility counters remain informational; restore never consumes them.
        "session_count": len(tasks),
    }
    document["content_digest"] = content_digest(document)
    dump(document)
    return 0 if complete else 69


def adapt_v1(snapshot: dict[str, Any], host_id: str, hostname: str) -> dict[str, Any]:
    if snapshot.get("schema_version") != 1 or not isinstance(snapshot.get("sessions"), list):
        raise ValueError("not a schema-v1 snapshot")
    generated = text(snapshot.get("generated_at")) or "1970-01-01T00:00:00Z"
    host_match = text(snapshot.get("hostname")) == hostname
    tasks = []
    for session in snapshot["sessions"]:
        if not isinstance(session, dict):
            continue
        agent = text(session.get("agent")) or "unknown"
        provider = "claude" if agent in ("claude", "claude-code") else "codex" if agent in ("codex", "openai") else "unknown"
        resume = text(session.get("conversation_id"))
        cwd = text(session.get("cwd"))
        eligible = provider == "claude" and session.get("managed") is True and resume is not None and cwd is not None and os.path.isabs(cwd) and host_match
        row = {
            "provider": provider,
            "provider_task_id": resume,
            "host_id": host_id if host_match else None,
            "origin": "cctrl" if eligible else "unknown",
            "execution_runtime": "tmux" if eligible else "unknown",
            "control_owner": "cctrl" if eligible else "unknown",
            "lifecycle_state": "resumable" if eligible else "unknown",
            "restore_strategy": "tmux-resume" if eligible else None,
            "registered_by_cctrl": bool(eligible),
            "launched_by_cctrl": bool(eligible),
            "registration_provenance": [{"source": "legacy-schema-v1-adapter"}] if eligible else [],
            "launch_provenance": [{"source": "legacy-schema-v1-adapter"}] if eligible else [],
            "lineage": lineage(None),
            "tmux_session": text(session.get("name")),
            "resume_identity_kind": "claude-session-id" if eligible else None,
            "resume_identity": resume if eligible else None,
            "observed_at": text(session.get("last_active")) or generated,
            "recovery_action": "insufficient-evidence",
            "recovery_reason": "legacy Codex rows are never restorable" if provider == "codex" else "legacy row adapted; current exact-identity evidence is still required" if eligible else "legacy row lacks the closed restore predicate",
            "ownership_evidence": [],
            "cwd": cwd,
            "purpose": text(session.get("purpose")),
            "display_label": text(session.get("display_label")),
            "agent": agent,
            "launch_flags": session.get("launch_flags") if isinstance(session.get("launch_flags"), dict) else {},
            "transcript_path": text(session.get("transcript_path")),
            "transcript_bytes": session.get("transcript_bytes"),
            "last_active": text(session.get("last_active")),
        }
        tasks.append(row)
    return {
        "schema_version": 2,
        "generated_at": generated,
        "host_id": host_id if host_match else None,
        "hostname": text(snapshot.get("hostname")),
        "resource_metadata": {"legacy_resource_line": snapshot.get("resource_line")},
        "tasks": tasks,
        "task_reference_count": len(tasks),
        "restore_candidate_count": sum(1 for task in tasks if task["restore_strategy"] == "tmux-resume"),
        "capture_quality": {"status": "legacy", "mandatory_sources": {}},
        "source_errors": [],
    }


def adapt(args: argparse.Namespace) -> int:
    dump(adapt_v1(load(args.snapshot), args.host_id, args.hostname))
    return 0


def source_available(catalogue: dict[str, Any], provider: str) -> tuple[bool, str]:
    status = catalogue.get("source_status") if isinstance(catalogue.get("source_status"), dict) else {}
    required = ["registry", "tmux"] + (["codex_provider"] if provider == "codex" else [])
    missing = [name for name in required if status.get(name) != "available"]
    aliases = {"codex-provider": "codex_provider"}
    failed = []
    for error in catalogue.get("source_errors") or []:
        if not isinstance(error, dict):
            continue
        source = aliases.get(error.get("source"), error.get("source"))
        if source in required:
            failed.append(source)
    unavailable = sorted(set(missing + failed))
    return (not unavailable, "mandatory source unavailable: " + ", ".join(unavailable) if unavailable else "available")


def reconcile_record(reconcile: dict[str, Any], task_id: str, host_id: str) -> tuple[dict[str, Any] | None, str | None]:
    records = reconcile.get("records") if isinstance(reconcile, dict) else None
    if not isinstance(records, list):
        return None, "Codex App Server evidence unavailable"
    matches = [
        row for row in records
        if isinstance(row, dict)
        and row.get("provider_task_id") == task_id
        and row.get("host_id") == host_id
    ]
    if len(matches) != 1:
        return None, "Codex evidence absent" if not matches else "Codex evidence ambiguous"
    row = matches[0]
    sources = row.get("sources") if isinstance(row.get("sources"), dict) else {}
    allowed_statuses = {
        "registry": {"available"},
        "app_server": {"claimed", "confirmed-absence"},
        "tmux": {"claimed", "confirmed-absence"},
        "process_table": {"corroborated", "confirmed-absence"},
    }
    for name in ("registry", "app_server", "tmux", "process_table"):
        source = sources.get(name) if isinstance(sources.get(name), dict) else {}
        if source.get("status") not in allowed_statuses[name] or source.get("error"):
            return None, f"Codex {name} evidence unavailable"
        if name == "process_table" and not source.get("source_cursor"):
            return None, "Codex process evidence unavailable"
    return row, None


def live_catalogue_names(rows: list[Any], provider: str, task_id: str, host_id: str) -> list[str]:
    """tmux names of current catalogue rows that hold this exact task live."""
    names = []
    for item in rows:
        if (
            isinstance(item, dict)
            and item.get("provider") == provider
            and item.get("provider_task_id") == task_id
            and item.get("host_id") == host_id
            and item.get("action_capabilities", {}).get("tmux_attach", {}).get("supported") is True
        ):
            names.append(text(item.get("tmux_session")) or "")
    return sorted(set(names))


def plan(args: argparse.Namespace) -> int:
    """Classify every snapshot row against current evidence.

    Each row gets its own disposition. Only evidence that no row could be
    judged without (the process table, a mandatory catalogue source) is a
    run-level `global_errors` entry (exit 69). A row that is skipped for a
    reason a human should look at carries `attention`: "conflict" or
    "ambiguous". `--strict` restores the pre-boot-restore exit codes (75 for
    any conflict, 69 for any missing evidence) for external callers.
    """
    snapshot = load(args.snapshot)
    if snapshot.get("schema_version") == 1:
        snapshot = adapt_v1(snapshot, args.host_id, args.hostname)
    if snapshot.get("schema_version") != 2 or not isinstance(snapshot.get("tasks"), list):
        raise ValueError("snapshot schema is not supported")
    catalogue = load(args.catalogue)
    process = load(args.process)
    reconcile = load(args.codex_evidence) if args.codex_evidence else {"records": []}
    rows = catalogue.get("rows") if isinstance(catalogue, dict) else None
    if not isinstance(rows, list):
        raise RuntimeError("live catalogue is unavailable")
    process_ok = (
        isinstance(process, dict)
        and process.get("status") == "available"
        and not process.get("error")
        and bool(text(process.get("source_cursor")))
        and isinstance(process.get("processes"), list)
    )

    sessions_dirs = claude_config_sessions_dirs(getattr(args, "claude_sessions_dir", None) or [], getattr(args, "metadata_dir", None))
    claude_known, claude_unknown = claude_live_view(process, sessions_dirs) if process_ok else ({}, [])

    results = []
    global_errors: list[dict[str, str]] = []

    def add_global(source: str, error: str) -> None:
        entry = {"source": source, "error": error}
        if entry not in global_errors:
            global_errors.append(entry)

    # The pre-boot-restore exit codes, kept for `plan --strict`.
    strict_evidence_missing = False
    strict_conflict = False
    for source in snapshot["tasks"]:
        if not isinstance(source, dict):
            continue
        row = dict(source)
        provider = text(row.get("provider")) or "unknown"
        task_id = text(row.get("provider_task_id"))
        disposition, reason = "insufficient-evidence", "closed restore predicate not satisfied"
        capability = {"supported": False, "reason": reason}
        attention: str | None = None
        snapshot_conflict = "conflict" in (row.get("control_owner"), row.get("execution_runtime"), row.get("lifecycle_state"))
        snapshot_provider_managed = not snapshot_conflict and (
            row.get("control_owner") == "app" or row.get("execution_runtime") == "app-server"
            or row.get("restore_strategy") == "provider-managed" or row.get("lifecycle_state") == "released"
        )
        running = None
        unidentified: tuple[int, str | None] | None = None
        live_names: list[str] = []
        if task_id and not snapshot_provider_managed and row.get("host_id") == args.host_id:
            if process_ok:
                all_ids = [task_id] + [i for i in row.get("shadowed_task_ids") or [] if isinstance(i, str)]
                running = process_running(process, all_ids)
                if not running and provider == "claude":
                    for candidate_id in all_ids:
                        if candidate_id in claude_known:
                            running = (claude_known[candidate_id], candidate_id)
                            break
                    if not running:
                        row_cwd = _real(text(row.get("cwd")))
                        for unknown_pid, unknown_cwd in claude_unknown:
                            if unknown_cwd is None or unknown_cwd == row_cwd:
                                unidentified = (unknown_pid, unknown_cwd)
                                break
            live_names = [n for n in live_catalogue_names(rows, provider, task_id, args.host_id) if n != (text(row.get("tmux_session")) or "")]

        if row.get("host_id") != args.host_id:
            disposition, reason, strict_conflict, attention = "insufficient-evidence", "durable host id mismatch", True, "conflict"
        elif running:
            pid, matched = running
            disposition = "already-live"
            reason = f"conversation already running (pid {pid})" if matched == task_id else f"a sibling record is running (pid {pid})"
        elif live_names:
            disposition, reason = "already-live", "live under " + ", ".join(n or "an unnamed session" for n in live_names)
        elif snapshot_conflict:
            disposition, reason, strict_conflict, attention = "conflict", "snapshot ownership conflict", True, "conflict"
        elif snapshot_provider_managed:
            disposition, reason = "provider-managed", "provider owns persistence; no cctrl spawn"
        elif row.get("control_owner") == "unknown" or row.get("execution_runtime") == "unknown":
            disposition, reason = "unknown", "snapshot owner or runtime is unknown"
            recorded = text(row.get("recovery_reason")) or ""
            if recorded.startswith("ambiguous-tmux-claim"):
                reason, attention = recorded, "ambiguous"
        elif not task_id:
            reason = "provider task id is missing"
        elif not process_ok:
            reason = "mandatory process evidence unavailable"
            strict_evidence_missing = True
            add_global("process", reason)
        else:
            available, source_reason = source_available(catalogue, provider)
            if not available:
                reason, strict_evidence_missing = source_reason, True
                add_global("catalogue", source_reason)
            else:
                matches = [item for item in rows if isinstance(item, dict) and item.get("provider") == provider and item.get("provider_task_id") == task_id and item.get("host_id") == args.host_id]
                if len(matches) != 1:
                    disposition = "conflict" if len(matches) > 1 else "insufficient-evidence"
                    reason = "live identity is ambiguous" if len(matches) > 1 else "live identity is absent"
                    attention = "conflict" if len(matches) > 1 else "ambiguous"
                    strict_conflict = strict_conflict or len(matches) > 1
                    strict_evidence_missing = strict_evidence_missing or len(matches) == 0
                else:
                    current = matches[0]
                    if provider == "codex":
                        reconciled, reconcile_error = reconcile_record(reconcile, task_id, args.host_id)
                        if reconcile_error:
                            reason, strict_evidence_missing, attention = reconcile_error, True, "ambiguous"
                            current_outcome = {}
                        else:
                            current_outcome = reconciled.get("chosen_outcome") if isinstance(reconciled.get("chosen_outcome"), dict) else {}
                            reconcile_sources = reconciled.get("sources") if isinstance(reconciled.get("sources"), dict) else {}
                            codex_absence_proven = (
                                reconcile_sources.get("app_server", {}).get("status") == "confirmed-absence"
                                and reconcile_sources.get("tmux", {}).get("status") == "confirmed-absence"
                            )
                    else:
                        current_outcome = {
                            "control_owner": current.get("control_owner"),
                            "execution_runtime": current.get("execution_runtime"),
                            "lifecycle_state": current.get("lifecycle_state"),
                            "restore_strategy": current.get("restore_strategy"),
                        }
                        reconcile_error = None
                        codex_absence_proven = False
                    if not reconcile_error:
                        owner = current_outcome.get("control_owner")
                        runtime = current_outcome.get("execution_runtime")
                        state = current_outcome.get("lifecycle_state")
                        live = current.get("action_capabilities", {}).get("tmux_attach", {}).get("supported") is True
                        if "conflict" in (owner, runtime, state):
                            disposition, reason, strict_conflict, attention = "conflict", "current ownership evidence conflicts", True, "conflict"
                        elif state in {"archived", "closed"}:
                            disposition, reason = "insufficient-evidence", f"current lifecycle state is {state}"
                        elif owner == "app" or runtime == "app-server" or current_outcome.get("restore_strategy") == "provider-managed" or state == "released":
                            disposition, reason = "provider-managed", "current evidence assigns persistence to the provider"
                        elif live:
                            disposition, reason = "already-live", "exact provider task already has a live cctrl tmux owner"
                        elif owner == "unknown" or runtime == "unknown":
                            if not (provider == "codex" and codex_absence_proven and owner == "unknown" and runtime == "unknown"):
                                disposition, reason, attention = "unknown", "current ownership evidence is unknown or ambiguous", "ambiguous"
                                row["disposition"] = disposition
                                row["reason"] = reason
                                row["attention"] = attention
                                row["action_capabilities"] = {"restore": {"supported": False, "reason": reason}}
                                results.append(row)
                                continue
                        elif owner != "cctrl" or runtime != "tmux":
                            disposition, reason = "unknown", "current evidence does not confirm an eligible inactive cctrl owner"
                        if disposition not in {"conflict", "provider-managed", "already-live", "unknown"} and state not in {"archived", "closed"}:
                            expected_kind = "claude-session-id" if provider == "claude" else "codex-thread-id" if provider == "codex" else None
                            snapshot_agent = text(row.get("agent"))
                            closed = (
                                row.get("restore_strategy") == "tmux-resume"
                                and row.get("registered_by_cctrl") is True
                                and row.get("launched_by_cctrl") is True
                                and row.get("origin") == "cctrl"
                                and row.get("execution_runtime") == "tmux"
                                and row.get("control_owner") == "cctrl"
                                and row.get("lifecycle_state") in RESUMABLE_STATES
                                and expected_kind in RESUME_KINDS
                                and row.get("resume_identity_kind") == expected_kind
                                and text(row.get("resume_identity")) == task_id
                                and snapshot_agent in (None, provider)
                                and text(row.get("cwd")) is not None
                                and os.path.isabs(row["cwd"])
                            )
                            if closed and unidentified:
                                # Only a row that would otherwise get `restore` is held back, and the
                                # reason names the pid so a human can resolve it in one step.
                                where = unidentified[1] or "an unknown directory"
                                disposition, attention = "insufficient-evidence", "ambiguous"
                                reason = f"an unidentified live claude (pid {unidentified[0]}, resumed without a session id) in {where} may be running this conversation"
                                row["blocked_by_pid"] = unidentified[0]
                            elif closed:
                                disposition, reason = "restore", "exact inactive cctrl tmux task satisfies the closed restore predicate"
                                capability = {"supported": True, "reason": "tmux-resume"}
                            else:
                                reason = "snapshot row does not satisfy the closed restore predicate"
        if not capability["supported"]:
            capability = {"supported": False, "reason": reason}
        row["disposition"] = disposition
        row["reason"] = reason
        if attention:
            row["attention"] = attention
        row["action_capabilities"] = {"restore": capability}
        results.append(row)

    document = {
        "schema_version": 1,
        "kind": "restore_plan_v1",
        "snapshot_schema_version": snapshot.get("schema_version"),
        "host_id": args.host_id,
        "rows": results,
        "counts": {name: sum(1 for row in results if row["disposition"] == name) for name in sorted(VALID_DISPOSITIONS)},
        "global_errors": global_errors,
        "source_errors": catalogue.get("source_errors", []) if isinstance(catalogue, dict) else [],
    }
    dump(document)
    if args.strict:
        if strict_conflict:
            return 75
        if strict_evidence_missing:
            return 69
        return 0
    return 69 if global_errors else 0


def launch_flags_cmd(args: argparse.Namespace) -> int:
    # Plan 071 phase 6: shares launch_flags_for with capture() so a bash
    # caller (doctor's realign) gets the same profile/model/peer/no-bridge
    # resolution the restore path does, instead of a second hand-rolled copy.
    print(json.dumps(launch_flags_for(args.metadata_dir, args.name)))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    capture_parser = sub.add_parser("capture")
    capture_parser.add_argument("--catalogue", required=True)
    capture_parser.add_argument("--sessions", required=True)
    capture_parser.add_argument("--process", required=True)
    capture_parser.add_argument("--resources", required=True)
    capture_parser.add_argument("--host-id", required=True)
    capture_parser.add_argument("--hostname", required=True)
    capture_parser.add_argument("--generated-at", required=True)
    capture_parser.add_argument("--metadata-dir", required=True)
    capture_parser.add_argument("--claude-projects-dir", action="append", default=[], help="Claude transcript root (repeatable); evidence for the duplicate-claim tie-break")
    capture_parser.add_argument("--tie-margin", type=int, default=TIE_MARGIN_DEFAULT, help="seconds the newest claim must lead the runner-up")
    capture_parser.set_defaults(func=capture)
    adapt_parser = sub.add_parser("adapt-v1")
    adapt_parser.add_argument("--snapshot", required=True)
    adapt_parser.add_argument("--host-id", required=True)
    adapt_parser.add_argument("--hostname", required=True)
    adapt_parser.set_defaults(func=adapt)
    plan_parser = sub.add_parser("plan")
    plan_parser.add_argument("--snapshot", required=True)
    plan_parser.add_argument("--catalogue", required=True)
    plan_parser.add_argument("--process", required=True)
    plan_parser.add_argument("--codex-evidence")
    plan_parser.add_argument("--host-id", required=True)
    plan_parser.add_argument("--hostname", required=True)
    plan_parser.add_argument("--claude-sessions-dir", action="append", default=[], help="a Claude <config dir>/sessions (repeatable): <pid>.json names the conversation a live claude runs")
    plan_parser.add_argument("--metadata-dir", help="launch records; their claude_config_dir adds more sessions dirs")
    plan_parser.add_argument("--strict", action="store_true", help="exit 75 on any conflict and 69 on any missing evidence (pre-boot-restore behaviour)")
    plan_parser.set_defaults(func=plan)
    flags_parser = sub.add_parser("launch-flags")
    flags_parser.add_argument("--metadata-dir", required=True)
    flags_parser.add_argument("--name", required=True)
    flags_parser.set_defaults(func=launch_flags_cmd)
    args = parser.parse_args()
    try:
        return args.func(args)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, sort_keys=True), file=sys.stderr)
        return 64
    except Exception as exc:  # fail closed at the shell boundary
        print(json.dumps({"ok": False, "error": str(exc)}, sort_keys=True), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
