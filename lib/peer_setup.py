#!/usr/bin/env python3
"""`cctrl peer setup`: opt in to Claude Code cross-session inbound admission.

Writes `crossSessionInbound` into the Claude user settings file. User scope only
in this phase. Exit codes: 0 done or unchanged, 1 refused or failed, 2 Claude Code
too old, 3 a managed value overrides, 64 usage, 65 not confirmed.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import claude_inbound as ci  # noqa: E402
from claude_settings_edit import edit_settings  # noqa: E402

USAGE = """\
Usage: cctrl peer setup [--scope user] [--value accept|hold|refuse|unset]
                        [--dir PATH] [--dry-run] [--yes] [--json]

  Opt in to Claude Code cross-session messages. cctrl starts every Claude in
  bypass mode, and Claude holds a message between sessions of different
  permission classes until a person approves it. Desktop, VS Code and
  `claude -p` cannot show that dialog, so held messages expire. Setting
  crossSessionInbound to accept in your Claude user settings lets them through.

  --scope user    ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json (the only scope for now)
  --value V       accept (default), hold, refuse, or unset (removes the key)
  --dir PATH      repo whose project and local settings are checked (default: here)
  --dry-run       show what would change; write nothing
  --yes           skip the confirmation (needed when stdin is not a terminal)
  --json          machine-readable result; the trade-off text is in the
                  "trade_off" field (it is printed as text on every other path)

  The file is backed up (settings.json.cctrl-backup-<UTC>) before a change and
  replaced atomically. Invalid JSON is refused. A second run changes nothing.
  Only this Mac is changed; for another Mac run: cctrl --host ALIAS peer setup --yes
  Exit: 0 done/unchanged, 1 refused, 2 Claude Code too old, 3 managed override,
        64 usage, 65 not confirmed."""

TRADE_OFF = """\
What accept means:
  - Any of your other sessions on this Mac can start a turn in your sessions,
    including a bypass worker. So can any process running as you that writes
    the session socket. Permission prompts still fire in a receiving session
    that is not in bypass mode; a message can never approve one.
  - Bigger escalation: user scope also applies to every bypass-mode session
    cctrl spawns. A guarded session, or a Codex sender through the bridge, can
    then trigger no-prompt actions in a bypass worker.
  - Provider guards stay on: rate limits, loop throttling, and the rule that
    messages cannot change configuration. Setup never touches permissions.
  - Not set by setup: isolatePeerMachines. dialogExpiry is left alone."""


def _out(args, payload: dict, lines: list[str], code: int) -> int:
    payload["exit_code"] = code
    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        for line in lines:
            print(line)
    return code


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="cctrl peer setup", add_help=False)
    p.add_argument("--scope", default="user")
    p.add_argument("--value", default="accept")
    p.add_argument("--dir", default=None)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--yes", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("-h", "--help", action="store_true")
    try:
        args = p.parse_args(argv)
    except SystemExit:
        print(USAGE, file=sys.stderr)
        return 64
    if args.help:
        print(USAGE)
        return 0
    if args.scope != "user":
        print(f"cctrl peer setup: scope {args.scope!r} is not available yet; only --scope user\n", file=sys.stderr)
        print(USAGE, file=sys.stderr)
        return 64
    if args.value != "unset" and args.value not in ci.VALUES:
        print(f"cctrl peer setup: --value must be accept, hold, refuse or unset (got {args.value!r})", file=sys.stderr)
        return 64
    target = None if args.value == "unset" else args.value
    path = ci.user_settings_path()
    real = ci.real_target(path)
    base = {"file": str(real), "value": args.value, "dry_run": args.dry_run, "changed": False,
            "backup": None, "warnings": [], "notes": []}

    pf = ci.preflight(target, project_dir=args.dir or os.getcwd(), yes=args.yes)
    base["warnings"], base["notes"] = pf.warnings, pf.notes
    base["claude_version"] = ".".join(map(str, pf.version)) if pf.version else None
    if pf.blocked:
        lines = [f"warning: {w}" for w in pf.warnings] + [f"not changed: {real}"]
        return _out(args, base, lines, pf.exit_code)

    current = ci.read_settings(real)
    if current.status == "invalid":
        lines = [f"refusing to change {real}: {current.error}; fix it by hand first"]
        base["error"] = lines[0]
        return _out(args, base, lines, 1)
    have = current.data.get(ci.KEY) if current.status == "ok" else None
    would_change = (ci.KEY in current.data) if target is None and current.status == "ok" else (
        target is not None and (current.status != "ok" or have != target))

    # Would the value actually apply? Simulate the user file after the write.
    managed = ci.read_managed()
    pp, lp = ci.project_settings_paths(args.dir or os.getcwd())
    sim = dict(current.data if current.status == "ok" else {})
    if target is None:
        sim.pop(ci.KEY, None)
    else:
        sim[ci.KEY] = target
    after = ci.resolve(managed=managed.data if managed.source else None, user=sim,
                       project=ci.read_settings(pp).data or None, local=ci.read_settings(lp).data or None)
    base["effective_after"] = {"value": after.value, "source": after.source}
    if target is not None and after.value != target:
        pf.warnings.append(f"this write will not take effect in {args.dir or os.getcwd()}: "
                           f"{after.value} from {after.source} applies instead")
    base["warnings"] = pf.warnings

    lines = [f"warning: {w}" for w in pf.warnings] + [f"note: {n}" for n in pf.notes]
    lines.append(f"file: {real}")
    lines.append(f"effective after: {after.value or 'per-class default'} (source: {after.source})")

    if not would_change:
        lines.append(f"unchanged: {ci.KEY} is already {'absent' if target is None else target}")
        return _out(args, base, lines, 0)

    if target == "accept":
        base["trade_off"] = TRADE_OFF
        if not args.json:
            lines.append(TRADE_OFF)
    base["changed"] = True
    verb = "remove" if target is None else f"set to {target}"
    if args.dry_run:
        lines.append(f"dry run: would {verb} {ci.KEY} in {real} (backup first if the file exists); nothing written")
        return _out(args, base, lines, 0)

    if not args.yes:
        if pf.needs_yes:
            lines.append("not confirmed: claude was not found on PATH, so its version cannot be checked; "
                         "pass --yes to write anyway")
            base["changed"] = False
            return _out(args, base, lines, 65)
        if not sys.stdin.isatty() or args.json:
            lines.append("not confirmed: pass --yes to write (no terminal to ask on)")
            base["changed"] = False
            return _out(args, base, lines, 65)
        for line in lines:  # warnings, notes and the trade-off come before the prompt
            print(line)
        lines = []
        print(f"\nAbout to {verb} {ci.KEY} in {real}")
        try:
            answer = input("Proceed? [y/N] ").strip().lower()
        except EOFError:
            answer = ""
        if answer not in ("y", "yes"):
            print("not confirmed; nothing written")
            return 65

    try:
        changed, backup = edit_settings(real, lambda cfg: (cfg.pop(ci.KEY, None) if target is None
                                                           else cfg.__setitem__(ci.KEY, target)))
    except ci.SettingsError as exc:
        base["changed"] = False
        base["error"] = str(exc)
        return _out(args, base, [str(exc)], 1)
    base["changed"], base["backup"] = changed, str(backup) if backup else None
    if not changed:
        lines.append("unchanged: the file already had that value")
    else:
        lines.append(f"done: {verb} {ci.KEY} in {real}")
        if backup:
            lines.append(f"backup: {backup}")
        lines.append("running Claude sessions pick it up on restart; new sessions use it now")
    return _out(args, base, lines, 0)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
