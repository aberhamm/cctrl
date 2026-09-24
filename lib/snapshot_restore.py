#!/usr/bin/env python3
"""Pure snapshot normalization and ownership-aware restore policy for cctrl."""

from __future__ import annotations

import argparse
import json
import os
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


def launch_flags_for(metadata_dir: str, tmux_name: str | None) -> dict[str, Any]:
    if not tmux_name:
        return {}
    root = Path(metadata_dir)
    if not root.is_dir():
        return {}
    command = None
    for path in sorted(root.glob("*.json")):
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if isinstance(value, dict) and (value.get("tmux_session") == tmux_name or value.get("name") == tmux_name):
            command = text(value.get("launch_command"))
            if command:
                break
    if not command:
        return {}
    try:
        argv = shlex.split(command)
    except ValueError:
        return {}
    flags: dict[str, Any] = {}
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
    return flags


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
    for source in rows:
        if not isinstance(source, dict):
            continue
        provider = text(source.get("provider")) or "unknown"
        task_id = text(source.get("provider_task_id"))
        tmux_name = text(source.get("tmux_session"))
        if (provider, task_id, tmux_name) in seen or (tmux_name and any(t.get("tmux_session") == tmux_name for t in tasks)):
            continue
        strategy = source.get("restore_strategy")
        if strategy == "tmux":
            strategy = "tmux-resume"
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
            "launch_flags": {},
            "transcript_path": None,
            "transcript_bytes": None,
            "last_active": text(source.get("recency")),
            "live": source.get("action_capabilities", {}).get("tmux_attach", {}).get("supported") is True,
        }
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
        "restore_candidate_count": candidates,
        "capture_quality": capture_quality,
        "source_errors": errors,
        # Compatibility counters remain informational; restore never consumes them.
        "session_count": len(tasks),
    }
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


def plan(args: argparse.Namespace) -> int:
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

    results = []
    evidence_missing = False
    conflict = False
    for source in snapshot["tasks"]:
        if not isinstance(source, dict):
            continue
        row = dict(source)
        provider = text(row.get("provider")) or "unknown"
        task_id = text(row.get("provider_task_id"))
        disposition, reason = "insufficient-evidence", "closed restore predicate not satisfied"
        capability = {"supported": False, "reason": reason}

        if row.get("host_id") != args.host_id:
            disposition, reason, conflict = "insufficient-evidence", "durable host id mismatch", True
        elif "conflict" in (row.get("control_owner"), row.get("execution_runtime"), row.get("lifecycle_state")):
            disposition, reason, conflict = "conflict", "snapshot ownership conflict", True
        elif row.get("control_owner") == "app" or row.get("execution_runtime") == "app-server" or row.get("restore_strategy") == "provider-managed" or row.get("lifecycle_state") == "released":
            disposition, reason = "provider-managed", "provider owns persistence; no cctrl spawn"
        elif row.get("control_owner") == "unknown" or row.get("execution_runtime") == "unknown":
            disposition, reason = "unknown", "snapshot owner or runtime is unknown"
        elif not task_id:
            reason = "provider task id is missing"
        elif (
            process.get("status") != "available"
            or process.get("error")
            or not text(process.get("source_cursor"))
            or not isinstance(process.get("processes"), list)
        ):
            reason, evidence_missing = "mandatory process evidence unavailable", True
        else:
            available, source_reason = source_available(catalogue, provider)
            if not available:
                reason, evidence_missing = source_reason, True
            else:
                matches = [item for item in rows if isinstance(item, dict) and item.get("provider") == provider and item.get("provider_task_id") == task_id and item.get("host_id") == args.host_id]
                if len(matches) != 1:
                    disposition = "conflict" if len(matches) > 1 else "insufficient-evidence"
                    reason = "live identity is ambiguous" if len(matches) > 1 else "live identity is absent"
                    conflict = conflict or len(matches) > 1
                    evidence_missing = evidence_missing or len(matches) == 0
                else:
                    current = matches[0]
                    if provider == "codex":
                        reconciled, reconcile_error = reconcile_record(reconcile, task_id, args.host_id)
                        if reconcile_error:
                            reason, evidence_missing = reconcile_error, True
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
                            disposition, reason, conflict = "conflict", "current ownership evidence conflicts", True
                        elif state in {"archived", "closed"}:
                            disposition, reason = "insufficient-evidence", f"current lifecycle state is {state}"
                        elif owner == "app" or runtime == "app-server" or current_outcome.get("restore_strategy") == "provider-managed" or state == "released":
                            disposition, reason = "provider-managed", "current evidence assigns persistence to the provider"
                        elif live:
                            disposition, reason = "already-live", "exact provider task already has a live cctrl tmux owner"
                        elif owner == "unknown" or runtime == "unknown":
                            if not (provider == "codex" and codex_absence_proven and owner == "unknown" and runtime == "unknown"):
                                disposition, reason = "unknown", "current ownership evidence is unknown or ambiguous"
                                row["disposition"] = disposition
                                row["reason"] = reason
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
                            if closed:
                                disposition, reason = "restore", "exact inactive cctrl tmux task satisfies the closed restore predicate"
                                capability = {"supported": True, "reason": "tmux-resume"}
                            else:
                                reason = "snapshot row does not satisfy the closed restore predicate"
        if not capability["supported"]:
            capability = {"supported": False, "reason": reason}
        row["disposition"] = disposition
        row["reason"] = reason
        row["action_capabilities"] = {"restore": capability}
        results.append(row)

    document = {
        "schema_version": 1,
        "kind": "restore_plan_v1",
        "snapshot_schema_version": snapshot.get("schema_version"),
        "host_id": args.host_id,
        "rows": results,
        "counts": {name: sum(1 for row in results if row["disposition"] == name) for name in sorted(VALID_DISPOSITIONS)},
        "source_errors": catalogue.get("source_errors", []) if isinstance(catalogue, dict) else [],
    }
    dump(document)
    if conflict:
        return 75
    if evidence_missing:
        return 69
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
    plan_parser.set_defaults(func=plan)
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
