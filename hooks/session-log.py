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


def find_latest_session():
    """Find the most recently modified session JSONL (non-subagent)."""
    candidates = []
    for p in CLAUDE_PROJECTS.rglob("*.jsonl"):
        if "subagents" in str(p):
            continue
        candidates.append(p)
    if not candidates:
        return None
    return max(candidates, key=lambda p: p.stat().st_mtime)


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


def upsert_entry(entry):
    """Write entry to spending log. If the last line is the same session, replace it."""
    SPENDING_LOG.parent.mkdir(parents=True, exist_ok=True)

    lines = []
    if SPENDING_LOG.exists():
        with open(SPENDING_LOG) as f:
            lines = f.readlines()

    # Check if the last line is a session_update for the same session
    replaced = False
    if lines:
        try:
            last = json.loads(lines[-1])
            if (last.get("event") in ("session_update", "session_end")
                    and last.get("session_id") == entry["session_id"]):
                lines[-1] = json.dumps(entry) + "\n"
                replaced = True
        except (json.JSONDecodeError, IndexError):
            pass

    if not replaced:
        lines.append(json.dumps(entry) + "\n")

    with open(SPENDING_LOG, "w") as f:
        f.writelines(lines)


def main():
    session_path = find_latest_session()
    if not session_path:
        return

    profile = get_active_profile()
    session_id, totals, by_model = sum_session_tokens(session_path)

    if totals["input_tokens"] == 0 and totals["output_tokens"] == 0:
        return

    entry = {
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
    }

    upsert_entry(entry)


if __name__ == "__main__":
    main()
