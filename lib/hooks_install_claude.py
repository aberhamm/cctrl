#!/usr/bin/env python3
"""`cctrl hooks install` for Claude Code: merge cctrl's hook entries into settings.json.

usage: hooks_install_claude.py SETTINGS_PATH

Never treats an invalid settings.json as {}: it refuses (exit 1), takes a backup
before any change, and replaces the file atomically. Idempotent.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import claude_inbound as ci  # noqa: E402
from claude_settings_edit import edit_settings  # noqa: E402


def _cmds(entry: dict) -> list[str]:
    return [h.get("command", "") for h in entry.get("hooks", [])]


def apply_hooks(cfg: dict) -> None:
    hooks = cfg.setdefault("hooks", {})

    # PreToolUse: replace any cctrl-sourced entry, preserve others
    new_ptu = [e for e in hooks.get("PreToolUse", [])
               if not any("block-git-commit" in c or "cctrl hooks run pre-tool-use" in c for c in _cmds(e))]
    new_ptu.append({"matcher": "Bash",
                    "hooks": [{"type": "command", "command": "cctrl hooks run pre-tool-use"}]})
    hooks["PreToolUse"] = new_ptu

    # Plan 114 (b): the SendMessage log, as its own PreToolUse (intent) and
    # PostToolUse (outcome) entries. Replace cctrl's, keep others.
    for event in ("PreToolUse", "PostToolUse"):
        kept = [e for e in hooks.get(event, [])
                if not any("cctrl hooks run native-send-log" in c for c in _cmds(e))]
        kept.append({"matcher": "SendMessage",
                     "hooks": [{"type": "command", "command": "cctrl hooks run native-send-log"}]})
        hooks[event] = kept

    # Stop: replace cctrl-sourced entry, preserve others (e.g. gstack)
    new_stop = []
    for e in hooks.get("Stop", []):
        if any("notify.sh" in c or "session-log" in c or "cctrl hooks run stop" in c for c in _cmds(e)):
            if not e.get("_gstack_source"):
                continue
        new_stop.append(e)
    new_stop.insert(0, {"hooks": [{"type": "command", "command": "cctrl hooks run stop"}]})
    hooks["Stop"] = new_stop

    # Notification: replace cctrl-sourced entry, preserve others
    new_notif = [e for e in hooks.get("Notification", [])
                 if not any("notify.sh" in c or "cctrl hooks run notify" in c for c in _cmds(e))]
    new_notif.append({"hooks": [{"type": "command", "command": "cctrl hooks run notify"}]})
    hooks["Notification"] = new_notif


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: hooks_install_claude.py SETTINGS_PATH", file=sys.stderr)
        return 64
    try:
        edit_settings(Path(argv[0]), apply_hooks)
    except ci.SettingsError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
