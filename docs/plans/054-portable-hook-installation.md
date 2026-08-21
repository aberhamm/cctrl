---
id: 054
title: Portable hook installation — resolve hooks via PATH, not absolute paths
status: pending
blocked-by: []
priority:
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-08-21
---

## Requirements

cctrl hooks (block-git-commit, session-log, notify) are referenced by
absolute paths in Claude Code (`~/.claude/settings.json`) and Codex
(`~/.codex/hooks.json`). Moving cctrl, cloning to a different location, or
migrating from `~/_projects/` to `~/dev/` silently breaks every tool call.
This already happened on the MacBook Pro — Codex was non-functional until the
paths were manually fixed.

The fix follows the standard pattern (pre-commit, Husky, Lefthook): hook
configs invoke `cctrl hooks run <name>`, and cctrl resolves its own
`$SCRIPT_DIR` at runtime. Moving cctrl only requires updating `$PATH`.

**Acceptance criteria:**

- [ ] `cctrl hooks run pre-tool-use` executes `hooks/block-git-commit.py` via `$SCRIPT_DIR`, piping stdin through
- [ ] `cctrl hooks run stop` executes both `hooks/notify.sh stop` and `hooks/session-log.py`
- [ ] `cctrl hooks run notify` executes `hooks/notify.sh notification`
- [ ] `cctrl hooks install` writes the correct hook configs for Claude Code and Codex on the current machine
- [ ] `cctrl hooks install` is idempotent — running twice produces the same result
- [ ] `cctrl hooks doctor` validates that hook configs point to working commands
- [ ] After install, hooks work with cctrl at any filesystem path without editing configs

## Design

Three subcommands under `cctrl hooks`:

**`cctrl hooks run <name>`** — the portable entry point. Hook configs call
this instead of absolute paths to Python/shell scripts. `<name>` maps to:

| name | runs |
|------|------|
| `pre-tool-use` | `python3 $SCRIPT_DIR/hooks/block-git-commit.py` (stdin passthrough) |
| `stop` | `$SCRIPT_DIR/hooks/notify.sh stop` then `python3 $SCRIPT_DIR/hooks/session-log.py` |
| `notify` | `$SCRIPT_DIR/hooks/notify.sh notification` |

**`cctrl hooks install`** — writes hook configs for both runtimes:

- Claude Code: merges into `~/.claude/settings.json` (PreToolUse, Stop, Notification hooks)
- Codex: writes `~/.codex/hooks.json` (PreToolUse, Stop hooks)

The hook commands use `cctrl hooks run <name>` — no absolute paths. Requires
`cctrl` to be on `$PATH`; the install command checks and warns if not.

**`cctrl hooks doctor`** — reads both config files, checks that each hook
command resolves and the referenced scripts exist. Reports mismatches,
stale absolute paths, and missing configs.

**Files expected to change:**

- `cctrl`: add `cmd_hooks` with `run`, `install`, `doctor` subcommands
- No changes to the hook scripts themselves — they stay in `hooks/`

**Out of scope:** git hooks (pre-commit, pre-push) — those are mstack's
domain. This is only about Claude Code / Codex agent hooks.

## Tasks

1. Add `cmd_hooks` function to `cctrl` with subcommand dispatch (`run`, `install`, `doctor`, `--help`)
2. Implement `hooks run <name>` — route to the correct hook script(s) via `$SCRIPT_DIR`, passthrough stdin/args
3. Implement `hooks install` — detect Claude Code and Codex configs, write/merge hook entries using `cctrl hooks run` commands
4. Implement `hooks doctor` — read configs, validate commands resolve, report issues
5. Add `hooks` to main dispatch in `_dispatch()`
6. Test: run `cctrl hooks install` then verify hooks fire correctly in both runtimes
7. Fix existing hook configs on both machines (Studio + MacBook Pro) via `cctrl hooks install`

## Verification

- [cmd] `cctrl hooks run --help` exits 0
- [cmd] `echo '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' | cctrl hooks run pre-tool-use` exits 0
- [cmd] `echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m test"}}' | cctrl hooks run pre-tool-use 2>&1; test $? -eq 1` (blocked commit exits 1)
- [assert] `cctrl hooks doctor 2>&1` contains "OK" or reports actionable findings
