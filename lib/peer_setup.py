#!/usr/bin/env python3
"""`cctrl peer setup`: opt in to Claude Code cross-session inbound admission.

Writes `crossSessionInbound` into the Claude user settings file (--scope user),
into the cctrl config key messaging.claude.crossSessionInbound that the spawn
overlay reads (--scope spawned), or both. Exit codes: 0 done or unchanged, 1 refused or failed, 2 Claude Code
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
Usage: cctrl peer setup [--scope user|spawned|both] [--value accept|hold|refuse|unset]
                        [--dir PATH] [--dry-run] [--yes] [--override-user] [--json]

  Opt in to Claude Code cross-session messages. cctrl starts every Claude in
  bypass mode, and Claude holds a message between sessions of different
  permission classes until a person approves it. Desktop, VS Code and
  `claude -p` cannot show that dialog, so held messages expire. Setting
  crossSessionInbound to accept in your Claude user settings lets them through.

  --scope user    ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json (default; covers every
                  session you run, Desktop and VS Code included)
  --scope spawned the cctrl config key messaging.claude.crossSessionInbound: cctrl
                  adds it to the --settings overlay of the Claude sessions it starts
                  (applies to new launches; see the note below); your own sessions
                  are not changed. It reads the merged cctrl config like a spawn does
  --scope both    both of the above
  --override-user spawned/both: the overlay may override a user-set hold or refuse.
                  Without it the overlay leaves such a value alone and cctrl warns
  --value V       accept (default), hold, refuse, or unset (removes the key)
  --dir PATH      repo whose project and local settings are checked (default: here)
  --dry-run       show what would change; write nothing
  --yes           skip the confirmation (needed when stdin is not a terminal)
  --json          machine-readable result; the trade-off text is in the
                  "trade_off" field (it is printed as text on every other path)

  Spawned scope applies to NEW launches only. A running session keeps the overlay
  it started with. `cctrl restart` re-reads the value only for a session that
  already has an overlay file (a profile session, or one that started with this
  key set). A profile-none session without one picks it up when you close it and
  start a new one; a restart does not add --settings to it.

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


OVERRIDE_KEY = "overrideUser"

SPAWNED_NOTE = """\
Spawned scope: only the Claude sessions cctrl starts get the value (in their
  --settings overlay). It applies to new launches. A running session keeps what
  it started with; a restart refreshes the value only for a session that already
  has an overlay (a profile session). A profile-none session without one needs
  a new launch. Your own sessions are not changed, so they still hold messages
  from bypass workers."""


def config_path() -> Path:
    """The cctrl user config file (same resolution as cctrl itself)."""
    given = os.environ.get("CCTRL_SETUP_CONFIG_FILE")
    if given:
        return Path(given)
    xdg = os.environ.get("XDG_CONFIG_HOME", "")
    base = Path(xdg) if xdg.startswith("/") else Path(os.environ.get("HOME") or os.path.expanduser("~")) / ".config"
    return base / "cctrl" / "config.json"


def _env_files(name: str) -> list[Path]:
    return [Path(x) for x in os.environ.get(name, "").split("\n") if x]


def _rank(v) -> int:
    return {"accept": 0, "hold": 1, "refuse": 2}.get(v, -1)


def _merge(a, b):
    if isinstance(a, dict) and isinstance(b, dict):
        out = dict(a)
        for k, v in b.items():
            out[k] = _merge(out[k], v) if k in out else v
        return out
    return b


def merged_config(user: Path) -> tuple[dict, dict]:
    """The merged cctrl config a spawn sees (default, legacy, user, local), and per-key winning files.

    Returns (merged messaging.claude block, {key: winning file}). Unreadable files are skipped."""
    order = _env_files("CCTRL_SETUP_CONFIG_LOWER") + [user] + _env_files("CCTRL_SETUP_CONFIG_HIGHER")
    merged: dict = {}
    won: dict = {}
    for f in order:
        r = ci.read_settings(ci.real_target(f))
        if r.status != "ok":
            continue
        merged = _merge(merged, r.data)
        blk = _claude_block(r.data)
        for k in (ci.KEY, OVERRIDE_KEY):
            if k in blk:
                won[k] = f
    return _claude_block(merged), won


def _higher_or_lower_blockers(user: Path, target) -> list[tuple[str, Path]]:
    """Files other than the user config that stop the user-config write from taking effect."""
    out: list[tuple[str, Path]] = []
    for f in _env_files("CCTRL_SETUP_CONFIG_HIGHER"):
        r = ci.read_settings(ci.real_target(f))
        blk = _claude_block(r.data) if r.status == "ok" else {}
        for k in (ci.KEY, OVERRIDE_KEY):
            if k in blk:
                out.append((k, f))
    if target is None:
        for f in _env_files("CCTRL_SETUP_CONFIG_LOWER"):
            r = ci.read_settings(ci.real_target(f))
            blk = _claude_block(r.data) if r.status == "ok" else {}
            if ci.KEY in blk:
                out.append((ci.KEY, f))
    return out


def _claude_block(cfg: dict) -> dict:
    m = cfg.get("messaging")
    c = m.get("claude") if isinstance(m, dict) else None
    return c if isinstance(c, dict) else {}


def _apply_config(cfg: dict, target: str | None, override: bool) -> None:
    """Set or remove messaging.claude.{crossSessionInbound,overrideUser}; prune empty parents."""
    m = cfg.get("messaging")
    if m is None:
        m = {}
    if not isinstance(m, dict) or not isinstance(m.get("claude", {}), dict):
        raise ci.SettingsError("refusing to change the cctrl config: 'messaging' or 'messaging.claude' is not an object; fix it by hand first")
    c = m.get("claude", {})
    if target is None:
        c.pop(ci.KEY, None)
    else:
        c[ci.KEY] = target
    if override:
        c[OVERRIDE_KEY] = True
    else:
        c.pop(OVERRIDE_KEY, None)
    if c:
        m["claude"] = c
    else:
        m.pop("claude", None)
    if m:
        cfg["messaging"] = m
    else:
        cfg.pop("messaging", None)


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
    p.add_argument("--override-user", action="store_true")
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
    if args.scope not in ("user", "spawned", "both"):
        print(f"cctrl peer setup: --scope must be user, spawned or both (got {args.scope!r})\n", file=sys.stderr)
        print(USAGE, file=sys.stderr)
        return 64
    if args.override_user and args.scope == "user":
        print("cctrl peer setup: --override-user only applies to --scope spawned or both\n", file=sys.stderr)
        print(USAGE, file=sys.stderr)
        return 64
    if args.value != "unset" and args.value not in ci.VALUES:
        print(f"cctrl peer setup: --value must be accept, hold, refuse or unset (got {args.value!r})", file=sys.stderr)
        return 64
    target = None if args.value == "unset" else args.value
    do_user = args.scope in ("user", "both")
    do_spawn = args.scope in ("spawned", "both")
    override = bool(args.override_user) and target is not None
    project_dir = args.dir or os.getcwd()
    user_real = ci.real_target(ci.user_settings_path())
    cfg_real = ci.real_target(config_path()) if do_spawn else None
    base = {"scope": args.scope, "file": str(user_real if do_user else cfg_real), "value": args.value,
            "dry_run": args.dry_run, "changed": False, "backup": None, "warnings": [], "notes": []}
    if do_spawn:
        base["config_file"] = str(cfg_real)
        base["override_user"] = override

    pf = ci.preflight(target, project_dir=project_dir, yes=args.yes,
                      overlay=target if do_spawn else None)
    base["warnings"], base["notes"] = pf.warnings, pf.notes
    base["claude_version"] = ".".join(map(str, pf.version)) if pf.version else None
    if pf.blocked:
        lines = [f"warning: {w}" for w in pf.warnings] + [f"not changed: {user_real if do_user else cfg_real}"]
        return _out(args, base, lines, pf.exit_code)

    current = ci.read_settings(user_real)
    if do_user and current.status == "invalid":
        lines = [f"refusing to change {user_real}: {current.error}; fix it by hand first"]
        base["error"] = lines[0]
        return _out(args, base, lines, 1)
    cfg_cur = ci.read_settings(cfg_real) if do_spawn else None
    if do_spawn and cfg_cur.status == "invalid":
        lines = [f"refusing to change {cfg_real}: {cfg_cur.error}; fix it by hand first"]
        base["error"] = lines[0]
        return _out(args, base, lines, 1)
    merged_claude: dict = {}
    if do_spawn:
        merged_claude, won = merged_config(config_path())
        base["config_source"] = {k: str(v) for k, v in won.items()}
        blockers = _higher_or_lower_blockers(config_path(), target)
        if blockers:
            key, f = blockers[0]
            lines = [f"refusing to change {cfg_real}: {f} sets messaging.claude.{key} and wins over "
                     f"(or cannot be removed from) this file for spawned sessions; edit {f} by hand "
                     f"(or remove that key), then run this again"]
            base["error"] = lines[0]
            return _out(args, base, lines, 1)

    have = current.data.get(ci.KEY) if current.status == "ok" else None
    user_change = do_user and ((ci.KEY in current.data) if target is None and current.status == "ok" else (
        target is not None and (current.status != "ok" or have != target)))
    cfg_change = False
    if do_spawn:
        cur_claude = _claude_block(cfg_cur.data)
        cfg_change = (cur_claude.get(ci.KEY) != target) or ((cur_claude.get(OVERRIDE_KEY) is True) != override)

    # Would the value actually apply? Simulate the user file after the write.
    managed = ci.read_managed()
    pp, lp = ci.project_settings_paths(project_dir)
    sim = dict(current.data if current.status == "ok" else {})
    if do_user:
        if target is None:
            sim.pop(ci.KEY, None)
        else:
            sim[ci.KEY] = target
    mg = managed.data if managed.source else None
    proj, loc = ci.read_settings(pp).data or None, ci.read_settings(lp).data or None
    after = ci.resolve(managed=mg, user=sim, project=proj, local=loc)
    base["effective_after"] = {"value": after.value, "source": after.source}
    if do_user and target is not None and after.value != target:
        pf.warnings.append(f"this write will not take effect in {project_dir}: "
                           f"{after.value} from {after.source} applies instead")
    spawn_after = None
    if do_spawn:
        user_val = sim.get(ci.KEY)
        blocked_by_user = (target is not None and not override and user_val in ("hold", "refuse")
                           and _rank(user_val) > _rank(target))
        spawn_after = ci.resolve(managed=mg, overlay=None if (target is None or blocked_by_user) else target,
                                 user=sim, project=proj, local=loc)
        base["spawn_effective_after"] = {"value": spawn_after.value, "source": spawn_after.source}
        if blocked_by_user:
            pf.warnings.append(
                f"user settings set {ci.KEY} to {user_val}: cctrl's spawn overlay will omit the key and "
                f"that value stays in force for spawned sessions; add --override-user to apply {target}")
        elif target is not None and spawn_after.value != target:
            pf.warnings.append(f"this write will not take effect for spawned sessions in {project_dir}: "
                               f"{spawn_after.value} from {spawn_after.source} applies instead")
    base["warnings"] = pf.warnings

    lines = [f"warning: {w}" for w in pf.warnings] + [f"note: {n}" for n in pf.notes]
    if do_user:
        lines.append(f"file: {user_real}")
        lines.append(f"effective after: {after.value or 'per-class default'} (source: {after.source})")
    if do_spawn:
        lines.append(f"cctrl config: {cfg_real} (messaging.claude.{ci.KEY})")
        src = base["config_source"].get(ci.KEY)
        lines.append(f"cctrl config in force now: {merged_claude.get(ci.KEY) or 'unset'}"
                     + (f" (from {src})" if src else ""))
        lines.append(f"spawned sessions after: {spawn_after.value or 'per-class default'} "
                     f"(source: {spawn_after.source})")

    where = {"user": str(user_real), "spawned": str(cfg_real), "both": f"{user_real} and {cfg_real}"}[args.scope]
    if not user_change and not cfg_change:
        lines.append(f"unchanged: {ci.KEY} is already {'absent' if target is None else target}")
        return _out(args, base, lines, 0)

    if target == "accept":
        base["trade_off"] = TRADE_OFF
        if not args.json:
            lines.append(TRADE_OFF)
            if do_spawn and not do_user:
                lines.append(SPAWNED_NOTE)
    base["changed"] = True
    verb = "remove" if target is None else f"set to {target}"
    if args.dry_run:
        lines.append(f"dry run: would {verb} {ci.KEY} in {where} (backup first if the file exists); nothing written")
        return _out(args, base, lines, 0)

    if not args.yes:
        if pf.needs_yes:
            if pf.claude_on_path:
                lines.append("not confirmed: the Claude Code version could not be checked; "
                             "pass --yes to write anyway")
            else:
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
        print(f"\nAbout to {verb} {ci.KEY} in {where}")
        try:
            answer = input("Proceed? [y/N] ").strip().lower()
        except EOFError:
            answer = ""
        if answer not in ("y", "yes"):
            print("not confirmed; nothing written")
            return 65

    backups: list[str] = []
    changed_any = False
    try:
        if do_user:
            changed, backup = edit_settings(user_real, lambda cfg: (cfg.pop(ci.KEY, None) if target is None
                                                                    else cfg.__setitem__(ci.KEY, target)))
            changed_any |= changed
            if backup:
                backups.append(str(backup))
            if changed:
                lines.append(f"done: {verb} {ci.KEY} in {user_real}")
        if do_spawn:
            changed, backup = edit_settings(cfg_real, lambda cfg: _apply_config(cfg, target, override))
            changed_any |= changed
            if backup:
                backups.append(str(backup))
            if changed:
                lines.append(f"done: {verb} messaging.claude.{ci.KEY} in {cfg_real}")
    except ci.SettingsError as exc:
        base["changed"] = changed_any
        base["error"] = str(exc)
        return _out(args, base, lines + [str(exc)], 1)
    base["changed"] = changed_any
    base["backup"] = backups[0] if backups else None
    if len(backups) > 1:
        base["backups"] = backups
    if not changed_any:
        lines.append("unchanged: the file already had that value")
    else:
        for b in backups:
            lines.append(f"backup: {b}")
        if do_user:
            lines.append("running Claude sessions pick it up on restart; new sessions use it now")
        if do_spawn:
            lines.append("applies to new cctrl launches; a running profile-none session without an overlay "
                         "needs a new launch (a restart only refreshes an existing overlay)")
    return _out(args, base, lines, 0)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
