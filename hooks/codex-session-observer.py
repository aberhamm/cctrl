#!/usr/bin/env python3
"""Validate a bounded Codex lifecycle payload without mutating cctrl state."""

from __future__ import annotations

import json
import signal
import sys


DEADLINE_SECONDS = 2.0
MAX_PAYLOAD_BYTES = 1_048_576
SUPPORTED_EVENTS = {"SessionStart", "SessionEnd", "PreCompact", "PostCompact"}


class ObserverTimeout(Exception):
    pass


def _timeout(_signum: int, _frame: object) -> None:
    raise ObserverTimeout


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
        if payload.get("hook_event_name") not in SUPPORTED_EVENTS:
            return 0
        session_id = payload.get("session_id")
        if not isinstance(session_id, str) or not session_id.strip():
            return 0
        # Plan 061 is deliberately validation-only. Event interpretation and
        # registry writes belong to the later lifecycle-registration plan.
        return 0
    except (ObserverTimeout, OSError):
        return 0
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


if __name__ == "__main__":
    raise SystemExit(main())
