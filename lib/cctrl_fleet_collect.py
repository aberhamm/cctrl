#!/usr/bin/env python3
"""Bounded, fail-closed collection and normalization for ``cctrl fleet``.

The shell entrypoint intentionally passes only file names.  Remote JSON is
captured in isolated files and is never copied into argv, which keeps large
fleets below the platform command-line limit and leaves an auditable transport
record for every registered host until the caller removes its scratch tree.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import math
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
LEGACY_FIELDS = (
    "name", "host", "managed", "agent", "claude", "model", "dir",
    "state", "attached", "remote_control", "bridge", "session_id",
    "transcript", "last_active", "purpose", "created_at", "peer",
    "display_label",
)


def _write(path: Path, data: bytes | str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, bytes):
        path.write_bytes(data)
    else:
        path.write_text(data, encoding="utf-8")


def _run(command: list[str], cwd: Path, prefix: str, deadline: float) -> dict[str, Any]:
    """Run one complete SSH process under the remaining per-host deadline."""
    stdout_path = cwd / f"{prefix}.stdout"
    stderr_path = cwd / f"{prefix}.stderr"
    status_path = cwd / f"{prefix}.status"
    remaining = max(0.01, deadline - time.monotonic())
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=remaining)
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            stdout, stderr = process.communicate(timeout=0.5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = process.communicate()
    status = 124 if timed_out else int(process.returncode or 0)
    _write(stdout_path, stdout)
    _write(stderr_path, stderr)
    _write(status_path, f"{status}\n")
    return {
        "status": status,
        "timed_out": timed_out,
        "stdout": stdout.decode("utf-8", errors="replace"),
        "stderr": stderr.decode("utf-8", errors="replace"),
    }


def _target(registration: dict[str, Any]) -> str:
    hostname = str(registration.get("hostname") or "")
    user = str(registration.get("user") or "")
    return f"{user}@{hostname}" if user else hostname


def _envelope(status: str, schema_version: int | None, capabilities: dict[str, Any],
              rows: list[dict[str, Any]], error: dict[str, Any] | None) -> dict[str, Any]:
    # Keep this shape synchronized with the fleet_host_result_v2 seam.
    return {
        "status": status,
        "schema_version": schema_version,
        "capabilities": capabilities,
        "rows": rows,
        "error": error,
    }


def _unsupported(stdout: str, stderr: str, status: int) -> bool:
    if status != 1 or stderr != "":
        return False
    stripped = ANSI_RE.sub("", stdout)
    lines = stripped.splitlines()
    return bool(lines) and lines[0] == "Unknown command: task"


def _valid_task_row(row: Any) -> bool:
    if not isinstance(row, dict):
        return False
    string_fields = ("task_key", "provider", "host_id", "origin", "execution_runtime", "control_owner", "lifecycle_state")
    if any(not isinstance(row.get(field), str) or not row[field] for field in string_fields):
        return False
    if row.get("provider_task_id") is not None and not isinstance(row.get("provider_task_id"), str):
        return False
    if row.get("cwd") is not None and not isinstance(row.get("cwd"), str):
        return False
    if type(row.get("registered_by_cctrl")) is not bool or type(row.get("launched_by_cctrl")) is not bool:
        return False
    if row["origin"] not in {"cctrl", "codex-app", "external-cli", "unknown"}:
        return False
    if row["execution_runtime"] not in {"tmux", "app-server", "external-cli", "unknown", "conflict"}:
        return False
    if row["control_owner"] not in {"cctrl", "app", "external", "unknown", "conflict"}:
        return False
    if row["lifecycle_state"] not in {"provisional", "active", "released", "archived", "closed", "unknown", "conflict"}:
        return False
    actions = row.get("action_capabilities")
    if not isinstance(actions, dict):
        return False
    for name in ("tmux_attach", "app_open", "handoff", "cctrl_restore"):
        action = actions.get(name)
        if not isinstance(action, dict) or type(action.get("supported")) is not bool or not isinstance(action.get("reason"), str):
            return False
    return True


def _valid_task_document(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and value.get("schema_version") == 2
        and isinstance(value.get("host_id"), str)
        and bool(value.get("host_id"))
        and isinstance(value.get("capabilities"), dict)
        and isinstance(value.get("rows"), list)
        and all(_valid_task_row(row) for row in value["rows"])
        and all(row["host_id"] == value["host_id"] for row in value["rows"])
        and isinstance(value.get("source_errors"), list)
        and isinstance(value.get("source_status"), dict)
    )


def _host_caps(registration: dict[str, Any], alias: str, **extra: Any) -> dict[str, Any]:
    value: dict[str, Any] = {
        "alias": alias,
        "federation_host_id": registration.get("federation_host_id"),
        "registered_remote_host_id": registration.get("remote_host_id"),
        "identity_state": (
            "initialized" if registration.get("federation_host_id") else "identity-uninitialized"
        ),
    }
    value.update(extra)
    return value


def _collect_one(index: int, alias: str, registration: dict[str, Any], args: argparse.Namespace) -> str:
    host_dir = Path(args.output_dir) / f"host-{index:05d}"
    host_dir.mkdir(parents=True, exist_ok=True)
    _write(host_dir / "registration.json", json.dumps({"alias": alias, **registration}, sort_keys=True) + "\n")
    deadline = time.monotonic() + args.timeout
    target = _target(registration)
    base = [args.ssh_bin, "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", target]
    task_command = "source ~/.zprofile 2>/dev/null; cctrl task ls --json"
    try:
        task = _run(base + [task_command], host_dir, "task", deadline)
        if task["timed_out"]:
            result = _envelope(
                "timeout", None, _host_caps(registration, alias, task_list={"supported": False, "reason": "timeout"}),
                [], {"code": "timeout", "message": "remote task inventory exceeded its deadline"},
            )
        elif task["status"] == 0:
            try:
                document = json.loads(task["stdout"])
            except Exception as exc:
                result = _envelope(
                    "malformed", None, _host_caps(registration, alias, task_list={"supported": False, "reason": "malformed-json"}),
                    [], {"code": "malformed-json", "message": str(exc)},
                )
            else:
                if not _valid_task_document(document):
                    result = _envelope(
                        "malformed", None, _host_caps(registration, alias, task_list={"supported": False, "reason": "invalid-task-list-v2"}),
                        [], {"code": "invalid-task-list-v2", "message": "exit-zero response did not match task_list_v2"},
                    )
                else:
                    observed = document["host_id"]
                    registered = registration.get("remote_host_id")
                    identity_match = registered is None or registered == observed
                    source_partial = bool(document["source_errors"]) or any(
                        value != "available" for value in document["source_status"].values()
                    )
                    status = "ok" if identity_match and not source_partial else "partial"
                    error = None
                    if not identity_match:
                        error = {"code": "remote-host-id-mismatch", "message": "authoritative remote id differs from registration"}
                    elif source_partial:
                        error = {"code": "provider-partial", "message": "one or more remote inventory sources are partial"}
                    caps = _host_caps(
                        registration,
                        alias,
                        task_list={"supported": True, "reason": "available"},
                        remote=document["capabilities"],
                        observed_remote_host_id=observed,
                        remote_host_id_match=identity_match,
                        source_status=document["source_status"],
                        source_errors=document["source_errors"],
                    )
                    result = _envelope(
                        "identity-conflict" if not identity_match else status,
                        2,
                        caps,
                        [] if not identity_match else document["rows"],
                        error,
                    )
        elif _unsupported(task["stdout"], task["stderr"], task["status"]):
            legacy_command = "source ~/.zprofile 2>/dev/null; cctrl session ls --json"
            legacy = _run(base + [legacy_command], host_dir, "legacy", deadline)
            if legacy["timed_out"]:
                result = _envelope(
                    "timeout", 1, _host_caps(registration, alias, task_list={"supported": False, "reason": "legacy-timeout"}),
                    [], {"code": "legacy-timeout", "message": "legacy inventory exceeded its deadline"},
                )
            elif legacy["status"] != 0:
                result = _envelope(
                    "unavailable", 1, _host_caps(registration, alias, task_list={"supported": False, "reason": "legacy-command-failed"}),
                    [], {"code": "legacy-command-failed", "message": f"legacy command exited {legacy['status']}"},
                )
            else:
                try:
                    rows = json.loads(legacy["stdout"])
                except Exception as exc:
                    rows = None
                    legacy_error = str(exc)
                if not isinstance(rows, list):
                    result = _envelope(
                        "malformed", 1, _host_caps(registration, alias, task_list={"supported": False, "reason": "legacy-malformed-json"}),
                        [], {"code": "legacy-malformed-json", "message": locals().get("legacy_error", "legacy result was not an array")},
                    )
                else:
                    result = _envelope(
                        "legacy", 1,
                        _host_caps(
                            registration, alias,
                            task_list={"supported": False, "reason": "legacy-host"},
                            app_ownership={"supported": False, "reason": "unknown"},
                        ),
                        [row for row in rows if isinstance(row, dict)], None,
                    )
        else:
            result = _envelope(
                "unavailable", None,
                _host_caps(registration, alias, task_list={"supported": False, "reason": "remote-command-failed"}),
                [], {"code": "remote-command-failed", "message": f"task command exited {task['status']}"},
            )
    except Exception as exc:
        # Even local spawn failures retain the same per-call evidence contract
        # as completed processes; callers never have to infer missing files.
        for prefix in ("task", "legacy"):
            stdout_path = host_dir / f"{prefix}.stdout"
            stderr_path = host_dir / f"{prefix}.stderr"
            status_path = host_dir / f"{prefix}.status"
            if not stdout_path.exists():
                _write(stdout_path, b"")
            if not stderr_path.exists():
                _write(stderr_path, str(exc))
            if not status_path.exists():
                _write(status_path, "70\n")
        result = _envelope(
            "unavailable", None,
            _host_caps(registration, alias, task_list={"supported": False, "reason": "collector-error"}),
            [], {"code": "collector-error", "message": str(exc)},
        )
    result_path = host_dir / "result.json"
    _write(result_path, json.dumps(result, sort_keys=True) + "\n")
    return str(result_path)


def collect(args: argparse.Namespace) -> int:
    try:
        registrations = json.loads(Path(args.hosts_file).read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"invalid hosts file: {exc}", file=sys.stderr)
        return 65
    if not isinstance(registrations, dict):
        print("invalid hosts file: top level must be an object", file=sys.stderr)
        return 65
    items = [(alias, value) for alias, value in registrations.items() if isinstance(value, dict)]
    start = time.monotonic()
    budget = math.ceil(len(items) / max(1, min(4, args.workers))) * args.timeout + 2
    paths: list[str] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(4, max(1, args.workers))) as executor:
        futures = [
            executor.submit(_collect_one, index, alias, value, args)
            for index, (alias, value) in enumerate(items)
        ]
        try:
            for future in concurrent.futures.as_completed(futures, timeout=budget):
                paths.append(future.result())
        except concurrent.futures.TimeoutError:
            print("collector exceeded whole-command budget", file=sys.stderr)
            return 124
    if time.monotonic() - start > budget:
        print("collector exceeded whole-command budget", file=sys.stderr)
        return 124
    for path in sorted(paths):
        print(path)
    return 0


def _legacy_defaults(row: dict[str, Any], alias: str) -> dict[str, Any]:
    result = dict(row)
    defaults = {
        "name": row.get("name") or row.get("display_title") or row.get("provider_task_id") or row.get("task_key"),
        "host": alias,
        "managed": bool(row.get("registered_by_cctrl", row.get("managed", False))),
        "agent": row.get("provider") or row.get("agent") or "unknown",
        "claude": row.get("claude"),
        "model": row.get("model"),
        "dir": row.get("cwd") or row.get("dir"),
        "state": row.get("lifecycle_state") or row.get("state") or "unknown",
        "attached": row.get("attached", False),
        "remote_control": row.get("remote_control"),
        "bridge": row.get("bridge"),
        "session_id": row.get("provider_task_id") or row.get("session_id") or row.get("task_key"),
        "transcript": row.get("transcript"),
        "last_active": row.get("recency") or row.get("last_active"),
        "purpose": row.get("purpose") or row.get("title"),
        "created_at": row.get("created_at"),
        "peer": row.get("peer"),
        "display_label": row.get("display_label") or row.get("display_title") or row.get("title"),
    }
    for field in LEGACY_FIELDS:
        result.setdefault(field, defaults[field])
    return result


def _action_hint(row: dict[str, Any]) -> str:
    actions = row.get("action_capabilities")
    if isinstance(actions, dict):
        tmux = actions.get("tmux_attach")
        app = actions.get("app_open")
        if isinstance(tmux, dict) and tmux.get("supported") is True:
            return "tmux-attach"
        if isinstance(app, dict) and app.get("supported") is True:
            return "app-open"
    return "none"


def _normalize_rows(result: dict[str, Any], local: bool = False) -> list[dict[str, Any]]:
    caps = result.get("capabilities") if isinstance(result.get("capabilities"), dict) else {}
    alias = "local" if local else str(caps.get("alias") or "unknown")
    federation_id = caps.get("federation_host_id")
    observed_remote_id = caps.get("observed_remote_host_id")
    if local:
        federation_id = observed_remote_id = caps.get("observed_remote_host_id")
    output: list[dict[str, Any]] = []
    for original in result.get("rows", []):
        if not isinstance(original, dict):
            continue
        row = _legacy_defaults(original, alias)
        source_host_id = original.get("host_id")
        row.update({
            "host": alias,
            "host_id": federation_id,
            "federation_host_id": federation_id,
            "remote_host_id": observed_remote_id,
            "source_host_id": source_host_id,
            "host_identity_state": caps.get("identity_state", "initialized" if local else "identity-uninitialized"),
            "remote_schema_version": result.get("schema_version"),
            "remote_capabilities": caps,
            "remote_status": result.get("status"),
        })
        if result.get("schema_version") == 1:
            row["schema_version"] = 1
            if "state" not in original:
                row["state"] = None
            if "last_active" not in original:
                row["last_active"] = None
            row.setdefault("origin", "unknown")
            row.setdefault("execution_runtime", "tmux")
            row.setdefault("control_owner", "unknown")
            row.setdefault("lifecycle_state", row.get("state") or "unknown")
            row.setdefault("action_capabilities", {
                "tmux_attach": {"supported": False, "reason": "legacy-host-unknown"},
                "app_open": {"supported": False, "reason": "legacy-host-unknown"},
                "handoff": {"supported": False, "reason": "legacy-host-unknown"},
                "cctrl_restore": {"supported": False, "reason": "legacy-host-unknown"},
            })
        if caps.get("remote_host_id_match") is False:
            row["source_claims"] = {
                "origin": row.get("origin"),
                "execution_runtime": row.get("execution_runtime"),
                "control_owner": row.get("control_owner"),
                "lifecycle_state": row.get("lifecycle_state"),
                "action_capabilities": row.get("action_capabilities"),
            }
            row["origin"] = "unknown"
            row["execution_runtime"] = "conflict"
            row["control_owner"] = "conflict"
            row["lifecycle_state"] = "conflict"
            row["action_capabilities"] = {
                name: {"supported": False, "reason": "remote-host-id-mismatch"}
                for name in ("tmux_attach", "app_open", "handoff", "cctrl_restore")
            }
            evidence = row.get("diagnostic_evidence")
            if not isinstance(evidence, list):
                evidence = []
            row["diagnostic_evidence"] = [
                *evidence,
                {"source": "federation", "reason": "remote-host-id-mismatch"},
            ]
        row["action_hint"] = _action_hint(row)
        output.append(row)
    if not output and result.get("status") not in ("ok", "legacy"):
        output.append(_legacy_defaults({
            "host": alias,
            "offline": result.get("status") in ("unavailable", "timeout"),
            "host_marker": True,
            "host_id": federation_id,
            "federation_host_id": federation_id,
            "remote_host_id": observed_remote_id,
            "host_identity_state": caps.get("identity_state", "identity-uninitialized"),
            "remote_schema_version": result.get("schema_version"),
            "remote_capabilities": caps,
            "remote_status": result.get("status"),
            "remote_error": result.get("error"),
            "origin": "unknown",
            "execution_runtime": "unknown",
            "control_owner": "unknown",
            "lifecycle_state": result.get("status") or "unavailable",
            "action_hint": "none",
        }, alias))
    return output


def _recency(value: Any) -> tuple[int, float | str]:
    if isinstance(value, (int, float)):
        return (2, float(value))
    if isinstance(value, str) and value:
        try:
            return (2, float(value))
        except ValueError:
            return (1, value)
    return (0, "")


def merge(args: argparse.Namespace) -> int:
    host_results: list[dict[str, Any]] = []
    for raw_path in sys.stdin:
        path = raw_path.strip()
        if not path:
            continue
        try:
            value = json.loads(Path(path).read_text(encoding="utf-8"))
        except Exception as exc:
            value = _envelope("malformed", None, {"alias": "unknown", "identity_state": "identity-uninitialized"}, [], {"code": "result-read-failed", "message": str(exc)})
        host_results.append(value)

    try:
        local_doc = json.loads(Path(args.local_file).read_text(encoding="utf-8"))
    except Exception as exc:
        local_result = _envelope("malformed", 2, {"alias": "local", "identity_state": "initialized"}, [], {"code": "local-malformed", "message": str(exc)})
    else:
        if _valid_task_document(local_doc):
            partial = bool(local_doc["source_errors"]) or any(v != "available" for v in local_doc["source_status"].values())
            local_result = _envelope(
                "partial" if partial else "ok", 2,
                {
                    "alias": "local", "identity_state": "initialized",
                    "federation_host_id": local_doc["host_id"],
                    "registered_remote_host_id": local_doc["host_id"],
                    "observed_remote_host_id": local_doc["host_id"],
                    "remote_host_id_match": True,
                    "task_list": {"supported": True, "reason": "available"},
                    "remote": local_doc["capabilities"],
                    "source_status": local_doc["source_status"],
                    "source_errors": local_doc["source_errors"],
                },
                local_doc["rows"],
                {"code": "provider-partial", "message": "one or more local inventory sources are partial"} if partial else None,
            )
        else:
            local_result = _envelope("malformed", 2, {"alias": "local", "identity_state": "initialized"}, [], {"code": "invalid-local-task-list-v2", "message": "local task inventory did not match task_list_v2"})

    all_results = [local_result, *host_results]
    rows: list[dict[str, Any]] = []
    for index, result in enumerate(all_results):
        rows.extend(_normalize_rows(result, local=index == 0))
    rows.sort(key=lambda row: (_recency(row.get("last_active")), str(row.get("host_id") or ""), str(row.get("task_key") or row.get("session_id") or "")), reverse=True)
    failures = [
        {"host": result.get("capabilities", {}).get("alias", "unknown"), "status": result.get("status"), "error": result.get("error")}
        for result in all_results if result.get("status") not in ("ok", "legacy")
    ]
    status = "ok" if not failures else "partial"
    # Keep this top-level shape synchronized with the fleet_v2 seam.
    fleet = _envelope(
        status,
        2,
        {
            "fleet": {"supported": True, "reason": "available"},
            "legacy_json_array": {"supported": True, "reason": "compatibility-v1"},
            "hosts": [
                {
                    "status": result.get("status"),
                    "schema_version": result.get("schema_version"),
                    "capabilities": result.get("capabilities"),
                    "error": result.get("error"),
                }
                for result in all_results
            ],
        },
        rows,
        {"code": "host-partial", "hosts": failures} if failures else None,
    )
    print(json.dumps(fleet, sort_keys=True, indent=2))
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    sub = result.add_subparsers(dest="command", required=True)
    collect_parser = sub.add_parser("collect")
    collect_parser.add_argument("--hosts-file", required=True)
    collect_parser.add_argument("--output-dir", required=True)
    collect_parser.add_argument("--ssh-bin", default="ssh")
    collect_parser.add_argument("--workers", type=int, default=4)
    collect_parser.add_argument("--timeout", type=float, default=10.0)
    merge_parser = sub.add_parser("merge")
    merge_parser.add_argument("--local-file", required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    if args.command == "collect":
        return collect(args)
    return merge(args)


if __name__ == "__main__":
    raise SystemExit(main())
