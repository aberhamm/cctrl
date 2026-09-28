---
id: 079
title: checked-copy install for ~/.local/bin/cctrl + fail-open hook entrypoint
status: pending
blocked-by: []
priority: 79
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-09-27
tui-fixture: n/a
approved-by: matthew (C-14, via cctrl-fleet-manager)
---

## Plain-English Summary

`~/.local/bin/cctrl` is a symlink straight into this working tree
(`~/dev/cctrl/cctrl`). On 2026-09-27 a half-finished edit left the script
syntactically broken for however long the edit was in progress, and every
session's hooks broke at once (`cctrl hooks run ...` is what
`~/.claude/settings.json` shells out to for PreToolUse/Stop/Notification).
See memory `cctrl-live-tree-edits` and
`.mstack/handoffs/2026-09-27-handoff-snapshot-restore-close.md`.

Two independent fixes:

1. **Install, don't symlink.** `~/.local/bin/cctrl` becomes a plain file,
   refreshed only by an explicit install step that gates on `bash -n` +
   the full test suite, and swaps in atomically (write temp, `mv`).
2. **Hooks fail open.** Even with (1) in place, a bad install, a missing
   release, or an unanticipated crash must never turn into Claude Code
   blocking every `Bash` call. `cctrl hooks run <name>` gets wrapped so
   that "cctrl couldn't run" always exits 0 (allow) with a stderr warning,
   while a *deliberate* block (e.g. `block-git-commit.py`'s exit 1) still
   blocks exactly as it does today.

## Investigation notes

**How `cctrl` finds its own directory today** (`cctrl:18`):
```
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0")")" && pwd)"
```
This already follows symlinks to their real target — it's *not* the
symlink itself that's unsafe, it's that the symlink's target is a
directory edited in place. `cctrl` and its Python/Perl helpers reference
roughly a dozen sibling paths off `$SCRIPT_DIR`: `lib/*.sh` (sourced),
`lib/*.py`/`lib/*.pl` (invoked with a full path), `hooks/*`, `profiles/`,
`completions/`, and `data/`. A checked copy has to carry all of these
except `data/` — see below.

**Data must not be duplicated.** Several data paths have *no* env-var
override at all and are always `$SCRIPT_DIR/data/...`:
`SHORTCUTS_FILE` (`cctrl:23`), `CONFIG_FILE` (`cctrl:25`). Others do have
overrides (`CCTRL_DATA_DIR`, `CCTRL_SESSION_METADATA_DIR`,
`CCTRL_HOSTS_FILE`, `CCTRL_CONFIG_LOCAL`, `CCTRL_HOST_ID_FILE`,
`CCTRL_NEEDS_ME_SNAPSHOT`) but nothing sets them for interactive/hook
invocations today, and plan 078 confirms the snapshot timer deliberately
does **not** set `CCTRL_DATA_DIR`. Patching every hardcoded `data` path to
respect an env var is a wide, un-reviewed diff across the live script.
Instead: **the installed release directory gets a `data` entry that is a
symlink back to `~/dev/cctrl/data`** (the one real data directory). Every
existing `$SCRIPT_DIR/data/...` reference — env-overridden or not —
resolves through that symlink unchanged. Zero changes needed to the data
paths in `cctrl`/`lib/`.

**External consumers of the path, inventoried:**
- `~/.claude/settings.json` — PreToolUse/Stop/Notification hooks all call
  the bare command `cctrl hooks run <name>` (resolved via `$PATH`, not an
  absolute path). **No change needed** as long as `~/.local/bin/cctrl`
  keeps existing and stays on `$PATH`.
- `~/Library/LaunchAgents/com.cctrl.session-snapshot.plist` —
  `ProgramArguments = ["/Users/matthew/.local/bin/cctrl", "session",
  "snapshot", "--quiet"]`, `PATH` in its `EnvironmentVariables` is
  `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin` (does **not** include
  `~/.local/bin` — it relies on the absolute path). **No change needed**;
  same literal path.
- Live sessions' baked MCP runtime/peer args (`--cctrl
  /Users/matthew/dev/cctrl/cctrl`, confirmed via `ps auxww` against
  `lib/runtime_mcp.py`/`lib/peer_mcp.py` argv) already point at the dev
  tree directly, **not** at `~/.local/bin/cctrl` — those were baked when
  `SCRIPT_DIR` resolved through the old symlink to its real target. This
  plan doesn't touch `~/dev/cctrl/cctrl` itself, so already-running
  sessions are unaffected either way. New sessions launched through
  `~/.local/bin/cctrl` after this change will bake the new release path
  instead, which is correct and self-consistent.
- No `mcpServers.cctrl_runtime`-style static config found in
  `~/.claude.json` or `~/.claude/settings*.json` — that entry is written
  per-session by `session-wrapper.sh`, not a static file to migrate.

**Test suite.** `tests/run-tests.sh` already isolates
`CCTRL_DATA_DIR`/`CCTRL_SESSION_METADATA_DIR`/`CCTRL_HOST_ID_FILE` to a
temp dir per run, and `test_syntax()` (line 368) already runs `bash -n`
over `cctrl`, `install.sh`, the `hooks/*.sh`, and `py_compile`s five
Python files — but it **misses** `lib/health-check.sh`,
`lib/health-check-patterns.sh`, `lib/pane_draft.pl`, and several
`lib/*.py` files (`agent_model.py`, `cctrl_fleet_collect.py`,
`codex_app_server.py`, `codex_rollout.py`, `codex_websocket.py`,
`conflict_resolve.py`, `launch_event.py`, `shell_literals.py`,
`snapshot_restore.py`, `terminal_identity.py`, `tmux_snapshot.py`). Since
the install gate's whole premise is "full suite green ⇒ safe to ship,"
that gap has to close first or the gate is checking less than what it
copies. `bash -n cctrl` measured at ~10ms — cheap enough to run on every
hook invocation too (see design below).

**Hook exit-code convention** (`hooks/block-git-commit.py`): exit 0 =
allow, exit 1 = deliberate block (`sys.exit(1)` at line 33, with the
reason on stderr). A bash syntax error, independently verified, exits 2
(`bash -n` on a truncated script → `exit code: 2`). This gives a clean
signal to build the fail-open wrapper on: 0 and 1 are "cctrl ran and
decided something," anything else is "cctrl couldn't run."

## Design

### Layout

```
~/.local/bin/cctrl                          <- plain file, tracked launcher (install/cctrl-launcher.sh)
~/.local/lib/cctrl/current                  <- symlink -> releases/<git-sha>-<timestamp>
~/.local/lib/cctrl/releases/<sha>-<ts>/
    cctrl, lib/, hooks/, profiles/, completions/   <- real copies (__pycache__ excluded)
    data -> /Users/matthew/dev/cctrl/data           <- symlink, never copied
```

`~/.local/lib/cctrl` is a new path (distinct from the existing
`install.sh`'s `~/.local/share/cctrl`, which is the public
clone-from-GitHub flow for a machine that doesn't already have this repo
checked out — that flow is untouched and out of scope here; nothing on
either dev machine has a `~/.local/share/cctrl` today, confirmed).

`~/.local/bin/cctrl` (`install/cctrl-launcher.sh`, new tracked file, ~15
lines) is deliberately tiny and its content never needs to change between
installs — only `current`'s target changes. It does two things:

1. For anything other than `hooks run <name>`: `exec` straight through to
   `$CCTRL_HOME/current/cctrl "$@"`. Behavior identical to today.
2. For `hooks run <name>`: wraps the call so a parse/crash failure fails
   open (see below) instead of propagating an ambiguous exit code.

### Fail-open wrapper (in `install/cctrl-launcher.sh`)

```bash
CCTRL_HOME="${CCTRL_HOME:-$HOME/.local/lib/cctrl}"
CCTRL_REAL="$CCTRL_HOME/current/cctrl"

if [[ "${1:-}" == "hooks" && "${2:-}" == "run" ]]; then
    if [[ -x "$CCTRL_REAL" ]] && bash -n "$CCTRL_REAL" 2>/dev/null; then
        "$CCTRL_REAL" "$@"
        rc=$?
        case $rc in
            0|1) exit "$rc" ;;      # 0 = allow, 1 = deliberate hook block
            *)
                echo "cctrl: hooks entrypoint exited $rc unexpectedly — failing open" >&2
                exit 0
                ;;
        esac
    else
        echo "cctrl: hooks entrypoint missing or fails to parse ($CCTRL_REAL) — failing open, allowing the tool call" >&2
        exit 0
    fi
fi

exec "$CCTRL_REAL" "$@"
```

Only `hooks run` gets this treatment — every other subcommand
(`session ls`, `hooks doctor`, ...) still fails loudly, so real breakage
stays visible instead of being silently swallowed everywhere. The `0|1`
allowlist preserves the one deliberate-block convention that exists today
(`block-git-commit.py`); anything else (a bash syntax error → 2, a Python
traceback, a missing file, a segfault) is treated as "couldn't run" and
fails open. If a future hook needs a second deliberate exit code, extend
the allowlist explicitly — don't widen it to "anything nonzero is a
block," since that's exactly the failure mode this plan removes.

### Install step (`install/self-install.sh`, new)

Run from inside this checkout. Never touches `~/.local/bin/cctrl` or
`~/.local/lib/cctrl` until every gate passes:

1. `bash -n` on `cctrl`, `install.sh`, `install/self-install.sh`,
   `install/cctrl-launcher.sh`, every `lib/*.sh`, every `hooks/*.sh`.
2. `python3 -m py_compile` on every `lib/*.py` and `hooks/*.py`.
3. `perl -c` on `lib/pane_draft.pl`.
4. `LANG=en_US.UTF-8 bash tests/run-tests.sh` — full suite, must exit 0.
5. Any failure in 1–4 aborts with a clear message; nothing on disk changes.
6. Build the release in a scratch dir: `~/.local/lib/cctrl/releases/.tmp-$$`,
   `cp -a` of `cctrl`, `lib/`, `hooks/`, `profiles/`, `completions/`
   (excluding `__pycache__`), then `ln -s /Users/matthew/dev/cctrl/data data`
   inside it. Re-run `bash -n` against the *copied* files (protects
   against a corrupting copy, belt-and-suspenders).
7. `mv` the scratch dir to its final name `releases/<git-sha>-<UTC
   timestamp>` (atomic rename, same filesystem).
8. Atomic symlink swap: `ln -s "releases/<new>" current.next && mv -f
   current.next current` (rename of a symlink is atomic; a concurrently
   running `cctrl` invocation sees either the fully-old or fully-new
   release, never a mix).
9. Install the launcher: copy `install/cctrl-launcher.sh` to
   `~/.local/bin/cctrl.new`, `bash -n` it, `chmod +x`, `mv` it onto
   `~/.local/bin/cctrl` (atomic rename, replaces the existing symlink or
   file at that exact path in one syscall).
10. Prune old releases, keeping the 2 most recent plus the one just
    installed (avoid unbounded growth; this is not a rollback mechanism,
    the git history + rollback command below are).
11. Print what changed and the rollback command.

### Rollback

One command restores today's behavior exactly (symlink straight into the
working tree):
```
ln -sf /Users/matthew/dev/cctrl/cctrl /Users/matthew/.local/bin/cctrl
```

## Requirements

- [ ] `install/cctrl-launcher.sh` added, `bash -n` clean, covered by
      `tests/run-tests.sh`.
- [ ] `install/self-install.sh` added: gates on syntax + full suite before
      touching anything installed; atomic release build + `current` swap;
      atomic launcher install; prints rollback command on success.
- [ ] `data/` is never copied — the release's `data` entry is always a
      symlink to this repo's `data/` directory.
- [ ] `tests/run-tests.sh`'s `test_syntax()` extended to cover every
      `lib/*.sh`, `lib/*.py`, `lib/*.pl`, and the two new `install/*.sh`
      files, so the install gate actually checks everything it ships.
- [ ] New tests for the fail-open wrapper: (a) `hooks run pre-tool-use`
      with a syntactically broken `$CCTRL_REAL` exits 0 with a stderr
      warning; (b) a deliberate block (mock exit 1) still exits 1; (c) an
      unexpected exit code (mock exit 137) exits 0 with a warning; (d)
      non-`hooks run` commands are unaffected (still fail loudly).
- [ ] `~/.claude/settings.json` requires **no changes** (hooks already
      call bare `cctrl` via `$PATH`) — verify this stays true, don't
      "fix" it if it doesn't need touching.
- [ ] `com.cctrl.session-snapshot.plist` requires **no changes** (same
      absolute path, `~/.local/bin/cctrl`) — verify, don't touch.
- [ ] Live switch: run `install/self-install.sh` once, for real, on this
      machine, replacing the current symlink.
- [ ] Post-switch verification (see below) all pass before reporting done.

## Verification

- [cmd] `bash -n install/cctrl-launcher.sh && bash -n install/self-install.sh`
- [cmd] `LANG=en_US.UTF-8 bash tests/run-tests.sh` — full suite green
- [cmd] `bash install/self-install.sh` — succeeds, prints new release path
- [assert] `file ~/.local/bin/cctrl` reports a regular file, not a symlink
- [assert] `readlink ~/.local/lib/cctrl/current` points at a `releases/...` dir under `~/.local/lib/cctrl`
- [assert] `readlink ~/.local/lib/cctrl/current/data` == `/Users/matthew/dev/cctrl/data`
- [cmd] `cctrl session ls` — works
- [cmd] `echo '{}' | cctrl hooks run stop` — exits 0
- [cmd] `echo '{"tool_input":{"command":"git commit -m x"}}' | cctrl hooks run pre-tool-use; test $? -eq 1` — deliberate block still blocks
- [cmd] with `$CCTRL_HOME/current/cctrl` temporarily corrupted (test only, via `CCTRL_HOME` env override to a scratch copy — never the real installed one): `echo '{}' | cctrl hooks run pre-tool-use` exits 0 with a stderr warning
- [assert] next `com.cctrl.session-snapshot` timer firing leaves
  `~/.local/log/cctrl-snapshot.stderr.log` empty
- [assert] a live session's Stop/Notification hook still fires normally after the switch

## Out of scope

- The public `curl | bash` install.sh flow (fresh-machine clone from
  GitHub) — untouched.
- Fixing the `tmux -t` prefix-match hazard — filed separately as plan 080,
  plan-only per the fleet manager's instruction not to touch live tmux
  targeting in this change.
- Codex's `~/.codex/hooks.json` (if it bakes an absolute path) — not
  inventoried here; the task scope was Claude Code hooks + the snapshot
  timer + MCP args.
