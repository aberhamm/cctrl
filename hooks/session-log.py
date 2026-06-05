#!/usr/bin/env python3
"""
Claude Code Stop hook: logs session token usage with the active cctrl profile.

Fires after every assistant turn. Uses an upsert strategy: if the last entry
in spending.jsonl is for the same session_id, it replaces that line with
updated totals. This way, only the final snapshot per session persists.
"""
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

CCTRL_DIR = Path(__file__).resolve().parent.parent
ACTIVE_FILE = CCTRL_DIR / ".active-profile"
SPENDING_LOG = CCTRL_DIR / "costs" / "spending.jsonl"
CLAUDE_PROJECTS = Path.home() / ".claude" / "projects"


def get_active_profile():
    if ACTIVE_FILE.exists():
        return ACTIVE_FILE.read_text().strip()
    return "unknown"


def find_recent_sessions(max_age_seconds=120):
    """Find all session JSONL files modified within the last max_age_seconds."""
    now = time.time()
    candidates = []
    for p in CLAUDE_PROJECTS.rglob("*.jsonl"):
        try:
            if now - p.stat().st_mtime <= max_age_seconds:
                candidates.append(p)
        except OSError:
            continue
    return candidates


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
    recent = find_recent_sessions()
    if not recent:
        return

    profile = get_active_profile()

    SPENDING_LOG.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    if SPENDING_LOG.exists():
        with open(SPENDING_LOG) as f:
            lines = f.readlines()

    for session_path in recent:
        session_id, totals, by_model = sum_session_tokens(session_path)

        if totals["input_tokens"] == 0 and totals["output_tokens"] == 0:
            continue

        entry_line = json.dumps({
            "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "event": "session_update",
            "profile": profile,
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
