#!/usr/bin/env python3
"""
PreToolUse hook: blocks Bash commands that would create git commits.
Reads tool input JSON from stdin (Claude Code hook protocol).

JSON structure received from Claude Code:
  {"tool_name": "Bash", "tool_input": {"command": "..."}, ...}
"""
import sys
import json
import re

PATTERNS = [
    r"\bgit\b.*\bcommit\b",
    r"\bgit-commit\b",
    r"\bgit\b.*\brevert\b",
    r"\bgit\b.*\bcherry-pick\b",
    r"\bgit\b.*\bam\b",
    r"\b(?:bash|sh|zsh)\b.*-c\b.*\bgit\b.*\bcommit\b",
    r"\beval\b.*\bgit\b.*\bcommit\b",
]

try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)

cmd = data.get("tool_input", {}).get("command", "")

for pattern in PATTERNS:
    if re.search(pattern, cmd, re.DOTALL):
        print("Warning: this command looks like a git commit action (commit/revert/cherry-pick/am). This is advisory only -- the command is NOT blocked and will still run. Ask the user first if that wasn't intended.", file=sys.stderr)
        sys.exit(1)
