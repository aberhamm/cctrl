#!/usr/bin/env python3
"""Normalize bounded Codex lifecycle hooks and ingest them fail-open."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import signal
import subprocess
import sys
from typing import Any


DEADLINE_SECONDS = 2.0
INGEST_TIMEOUT_SECONDS = 1.25
MAX_PAYLOAD_BYTES = 1_048_576
MAX_STRING_BYTES = 4_096
SUPPORTED_EVENTS = {"SessionStart", "SessionEnd", "PreCompact", "PostCompact"}
SUPPORTED_SOURCES = {"startup", "resume", "clear", "compact", "fork", "app-server", "cli", "unknown"}
SUPPORTED_SOURCE_KINDS = {"codex-app", "external-cli", "unknown"}
SUPPORTED_CONFIDENCE = {"authoritative", "corroborating", "diagnostic"}


class ObserverTimeout(Exception):
    pass


def _timeout(_signum: int, _frame: object) -> None:
    raise ObserverTimeout


def _bounded_string(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    value = value.strip()
    if not value or len(value.encode("utf-8")) > MAX_STRING_BYTES:
        return None
    return value


def _first_string(payload: dict[str, Any], *names: str) -> str | None:
    for name in names:
        value = _bounded_string(payload.get(name))
        if value is not None:
            return value
    return None


def normalize_codex_lifecycle_event(payload: dict[str, Any]) -> dict[str, Any] | None:
    """Return the exact allowlisted registry envelope, or None when unsupported."""
    event_name = payload.get("hook_event_name")
    if event_name not in SUPPORTED_EVENTS:
        return None
    task_id = _first_string(payload, "session_id", "thread_id", "threadId")
    if task_id is None:
        return None

    source = _bounded_string(payload.get("source")) or "unknown"
    if source not in SUPPORTED_SOURCES:
        source = "unknown"
    # Hook payloads do not prove their own origin. A trusted launcher or future
    # reconciler may provide separately classified source evidence via env,
    # but that evidence must be bound to this exact provider task.
    evidence_task_id = _bounded_string(os.environ.get("CCTRL_CODEX_SOURCE_TASK_ID"))
    source_kind = _bounded_string(os.environ.get("CCTRL_CODEX_SOURCE_KIND")) or "unknown"
    confidence = _bounded_string(os.environ.get("CCTRL_CODEX_SOURCE_CONFIDENCE")) or "diagnostic"
    if evidence_task_id != task_id or source_kind not in SUPPORTED_SOURCE_KINDS or confidence not in SUPPORTED_CONFIDENCE:
        evidence_task_id = None
        source_kind = "unknown"
        confidence = "diagnostic"

    forked_from_id = _first_string(payload, "forked_from_id", "forkedFromId")
    parent_thread_id = _first_string(payload, "parent_thread_id", "parentThreadId")
    if forked_from_id == task_id:
        forked_from_id = None
    if parent_thread_id == task_id:
        parent_thread_id = None

    observed_at = _bounded_string(payload.get("observed_at"))
    if observed_at is None:
        observed_at = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    source_sequence = payload.get("source_sequence")
    if type(source_sequence) is not int or source_sequence < 0:
        source_sequence = None
    source_cursor = _bounded_string(payload.get("source_cursor"))

    identity = {
        "provider": "codex",
        "provider_task_id": task_id,
        "hook_event_name": event_name,
        "source": source,
        "source_kind": source_kind,
        "source_confidence": confidence,
        "source_evidence_task_id": evidence_task_id,
        "source_sequence": source_sequence,
        "source_cursor": source_cursor,
        "forked_from_id": forked_from_id,
        "parent_thread_id": parent_thread_id,
    }
    event_id = _bounded_string(payload.get("event_id"))
    if event_id is None:
        canonical = json.dumps({**identity, "observed_at": observed_at}, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        event_id = "codex-hook-" + hashlib.sha256(canonical.encode()).hexdigest()
    return {
        "version": 1,
        "event_id": event_id,
        **identity,
        "observed_at": observed_at,
        "lifecycle_state": "closed" if event_name == "SessionEnd" else "active",
    }


def _log_failure(reason_code: str) -> None:
    # Never log payloads, identifiers, cwd, or subprocess output. There is no
    # retry spool; plan 063 reconciliation repairs missed observations.
    print(f"cctrl codex lifecycle observation missed: {reason_code}", file=sys.stderr)


def _ingest(envelope: dict[str, Any]) -> None:
    command = os.environ.get("CCTRL_BIN", "cctrl")
    try:
        completed = subprocess.run(
            [command, "session", "ingest-event"],
            input=json.dumps(envelope, separators=(",", ":")).encode(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=INGEST_TIMEOUT_SECONDS,
            env=os.environ.copy(),
        )
    except FileNotFoundError:
        _log_failure("ingest-command-not-found")
    except subprocess.TimeoutExpired:
        _log_failure("ingest-timeout")
    except OSError:
        _log_failure("ingest-os-error")
    else:
        if completed.returncode != 0:
            _log_failure(f"ingest-exit-{completed.returncode}")


def main() -> int:
    previous = signal.signal(signal.SIGALRM, _timeout)
    signal.setitimer(signal.ITIMER_REAL, DEADLINE_SECONDS)
    try:
        raw = sys.stdin.buffer.read(MAX_PAYLOAD_BYTES + 1)
        if not raw or len(raw) > MAX_PAYLOAD_BYTES:
            return 0
        try:
            payload = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return 0
        if not isinstance(payload, dict):
            return 0
        envelope = normalize_codex_lifecycle_event(payload)
        if envelope is not None:
            _ingest(envelope)
        return 0
    except (ObserverTimeout, OSError):
        return 0
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


if __name__ == "__main__":
    raise SystemExit(main())
