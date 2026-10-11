#!/usr/bin/env python3
"""
PreToolUse (Bash) entry point of `cctrl hooks run pre-tool-use`. One process,
two checks on the same stdin payload:

  1. tmux guard (docs/plans/107): BLOCKS (exit 2, reason on stderr) a command
     that would run `tmux kill-server` without -S/-L on that tmux invocation.
     The parser is hooks/tmux_kill_guard.py.
  2. hooks/block-git-commit.py: the advisory git-commit warning (exit 1),
     unchanged.

Fail-open: malformed input, a missing or broken guard module, or any error in
the guard lets the command run. Only a positive match blocks.

JSON structure received (Claude Code and Codex hook protocol):
  {"tool_name": "Bash", "tool_input": {"command": "..."}, ...}
"""
import io
import json
import os
import re
import runpy
import shlex
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _command(data):
    tool_input = data.get("tool_input") if isinstance(data, dict) else None
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if isinstance(command, str):
        return command
    if isinstance(command, list) and all(isinstance(part, str) for part in command):
        return shlex.join(command)  # an argv list: ["bash", "-lc", "..."]
    return None


def _tmux_guard(raw):
    """Exit status 2 after printing the reason, or None to let the call go on."""
    try:
        command = _command(json.loads(raw))
        # Cheap pre-check so the common call never imports the parser.
        if not command or "kill-ser" not in re.sub(r"[\\'\"]", "", command.replace("\\\n", "")):
            return None
        sys.dont_write_bytecode = True  # never write __pycache__ into a release
        sys.path.insert(0, HERE)
        import tmux_kill_guard
        reason = tmux_kill_guard.check_command(command)
        if reason:
            sys.stderr.write(tmux_kill_guard.block_message(reason))
            return 2
    except Exception:
        pass
    return None


def main():
    raw = sys.stdin.read()
    blocked = _tmux_guard(raw)
    if blocked is not None:
        return blocked
    sys.stdin = io.StringIO(raw)
    try:
        runpy.run_path(os.path.join(HERE, "block-git-commit.py"), run_name="__main__")
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 0
    except Exception:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
