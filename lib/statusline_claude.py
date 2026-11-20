#!/usr/bin/env python3
"""Set statusLine in a Claude Code settings.json through the safe writer.

usage: statusline_claude.py SETTINGS_PATH COMMAND
Invalid JSON is refused (exit 1), the file is left byte-identical.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import claude_inbound as ci  # noqa: E402
from claude_settings_edit import edit_settings  # noqa: E402


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: statusline_claude.py SETTINGS_PATH COMMAND", file=sys.stderr)
        return 64
    cmd = argv[1]
    try:
        edit_settings(Path(argv[0]), lambda cfg: cfg.__setitem__("statusLine", {"type": "command", "command": cmd}))
    except ci.SettingsError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
