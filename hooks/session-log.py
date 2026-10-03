#!/usr/bin/env python3
"""
Claude Code Stop hook: logs session token usage with the launching cctrl
profile and auth backend.

Fires after every assistant turn. Reads the hook's own JSON from stdin and
logs only the transcript it names -- a previous version globbed every
~/.claude/projects/*.jsonl modified in the last 120s, which misattributed
usage between concurrent sessions. Uses an upsert strategy: if the last
entry in spending.jsonl is for the same session_id, it replaces that line
with updated totals. This way, only the final snapshot per session persists.
"""
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

CCTRL_DIR = Path(__file__).resolve().parent.parent
SPENDING_LOG = CCTRL_DIR / "costs" / "spending.jsonl"


def sum_session_tokens(session_path):
    """Parse a session JSONL, dedupe streaming assistant lines, sum tokens."""
    totals = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": 0,
    }
    by_model = {}
    prev_type = None
    last_assistant = None
    session_id = None

    with open(session_path) as f:
        for line in f:
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue

            if not session_id:
                session_id = d.get("sessionId")

            msg = d.get("message", {})
            if not isinstance(msg, dict):
                continue

            if msg.get("role") == "assistant" and "usage" in msg:
                last_assistant = d
                prev_type = "assistant"
            elif prev_type == "assistant" and last_assistant is not None:
                _flush(last_assistant, totals, by_model)
                last_assistant = None
                prev_type = d.get("type", "")
            else:
                prev_type = d.get("type", "")

    # Flush final
    if last_assistant is not None:
        _flush(last_assistant, totals, by_model)

    return session_id, totals, by_model


def _flush(assistant_entry, totals, by_model):
    msg = assistant_entry.get("message", {})
    usage = msg.get("usage", {})
    model = msg.get("model", "unknown")

    for key in totals:
        totals[key] += usage.get(key, 0)

    if model not in by_model:
        by_model[model] = {"input_tokens": 0, "output_tokens": 0}
    by_model[model]["input_tokens"] += usage.get("input_tokens", 0)
    by_model[model]["output_tokens"] += usage.get("output_tokens", 0)


def main():
    try:
        hook_input = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        hook_input = {}
    if not isinstance(hook_input, dict):
        hook_input = {}

    transcript_path = hook_input.get("transcript_path")
    if not isinstance(transcript_path, str) or not transcript_path:
        return
    session_path = Path(transcript_path)
    if not session_path.is_file():
        return

    profile = os.environ.get("CCTRL_SESSION_PROFILE") or "unknown"
    auth_backend = os.environ.get("CCTRL_SESSION_AUTH_BACKEND") or "unknown"

    session_id, totals, by_model = sum_session_tokens(session_path)
    hook_session_id = hook_input.get("session_id")
    if isinstance(hook_session_id, str) and hook_session_id:
        session_id = hook_session_id

    if totals["input_tokens"] == 0 and totals["output_tokens"] == 0:
        return

    SPENDING_LOG.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    if SPENDING_LOG.exists():
        with open(SPENDING_LOG) as f:
            lines = f.readlines()

    entry_line = json.dumps({
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "event": "session_update",
        "profile": profile,
        "auth_backend": auth_backend,
        "session_id": session_id,
        "session_file": str(session_path),
        "input_tokens": totals["input_tokens"],
        "output_tokens": totals["output_tokens"],
        "cache_write_tokens": totals["cache_creation_input_tokens"],
        "cache_read_tokens": totals["cache_read_input_tokens"],
        "models": by_model,
    }) + "\n"

    replaced = False
    search_start = max(0, len(lines) - 100)
    for i in range(len(lines) - 1, search_start - 1, -1):
        try:
            existing = json.loads(lines[i])
            if (existing.get("event") in ("session_update", "session_end")
                    and existing.get("session_id") == session_id):
                lines[i] = entry_line
                replaced = True
                break
        except (json.JSONDecodeError, IndexError):
            continue

    if not replaced:
        lines.append(entry_line)

    with open(SPENDING_LOG, "w") as f:
        f.writelines(lines)


if __name__ == "__main__":
    main()
