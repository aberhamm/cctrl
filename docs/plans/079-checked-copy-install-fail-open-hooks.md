---
id: 079
title: checked-copy install for ~/.local/bin/cctrl + fail-open hook entrypoint
status: pending
status-note: 2026-10-08 SHIPPED in 9f92064 (2026-09-28); left pending because the gate has no eng review record (frontmatter eng-review is the old free-text form); close with a reviews entry when someone re-reviews
blocked-by: []
priority: 79
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-09-27
tui-fixture: n/a
approved-by: matthew (C-14, via cctrl-fleet-manager)
eng-review: APPROVE WITH CHANGES (opus, 2026-09-28) — changes folded in below
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
   while a *deliberate* block still passes its exit code through
   unchanged.

## Investigation notes

**How `cctrl` finds its own directory today** (`cctrl:18`):
```
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0")")" && pwd)"
```
This already follows symlinks to their real target — it's *not* the
symlink itself that's unsafe, it's that the symlink's target is a
directory edited in place. Everything `cctrl` builds from `$SCRIPT_DIR`
falls into these groups (cctrl:19-25, :70): `lib/*.sh` (sourced),
`lib/*.py`/`lib/*.pl` (invoked with a full path), `hooks/*`, `profiles/`,
`plugins/`, `costs/`, `completions/`, `data/`, and `.active-profile`. A
checked copy has to carry or symlink **all** of these, not just the
`cctrl`/`lib`/`hooks`/`profiles`/`completions`/`data` set from the
original draft of this plan — the eng review caught two real omissions
(`plugins/`, `.active-profile`) and one path that was wrongly slated for
copying instead of symlinking (`profiles/`, `costs/`) — see "Data and
mutable state must not be duplicated" below.

**Data and mutable state must not be duplicated.** Several paths have
*no* env-var override at all and are always `$SCRIPT_DIR/...`:
`SHORTCUTS_FILE`, `CONFIG_FILE` (`cctrl:23,25`), `costs/spending.jsonl`
(`cctrl:21-22`, written by `hooks/session-log.py:18,106,147` on every
Stop hook — this is live, high-frequency mutable state, not a build
artifact), `profiles/` (gitignored, mode-0600 credential files, mutated
by `cctrl profile add/edit`), and `.active-profile` (`cctrl:70,981,1055,1171`;
read by `hooks/session-log.py:17` and `hooks/statusline.sh:46` on every
hook and every statusline render). Others do have overrides
(`CCTRL_DATA_DIR`, `CCTRL_SESSION_METADATA_DIR`, `CCTRL_HOSTS_FILE`,
`CCTRL_CONFIG_LOCAL`, `CCTRL_HOST_ID_FILE`, `CCTRL_NEEDS_ME_SNAPSHOT`) but
nothing sets them for interactive/hook invocations today, and plan 078
confirms the snapshot timer deliberately does **not** set
`CCTRL_DATA_DIR`.

Patching every hardcoded path to respect an env var is a wide,
un-reviewed diff across the live script. Instead: **every one of
`data/`, `costs/`, `profiles/`, and `.active-profile` in the installed
release is a symlink back to the corresponding path in this repo** —
exactly like `data/` in the original draft, just applied to the full set
instead of only `data/`. `plugins/` is different: it's tracked code
(`cctrl:20, :15785` dispatches `plugins/cctrl-*` like a built-in
subcommand, and `tests/run-tests.sh:377-387` already `py_compile`s it),
so it gets **copied** like `lib/`/`hooks/`, not symlinked. Zero changes
needed to any path-resolution code in `cctrl`/`lib/`.

**External consumers of the path, inventoried:**
- `~/.claude/settings.json` — PreToolUse/Stop/Notification hooks
  (lines 49, 59, 78) are exactly `cctrl hooks run pre-tool-use|stop|notify`
  — bare command, resolved via `$PATH`, not an absolute path. **No
  change needed** as long as `~/.local/bin/cctrl` keeps existing and
  stays on `$PATH`. The statusline hook (settings.json:86) is a separate,
  direct `/Users/matthew/dev/cctrl/hooks/statusline.sh` — out of scope
  (see "Out of scope"), but it stays exposed to live-tree edits either
  way; noting it so it isn't mistaken for something this plan fixes.
- `~/Library/LaunchAgents/com.cctrl.session-snapshot.plist` —
  `ProgramArguments = ["/Users/matthew/.local/bin/cctrl", "session",
  "snapshot", "--quiet"]`, `PATH` in its `EnvironmentVariables` is
  `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin` (does **not** include
  `~/.local/bin` — it relies on the absolute path). **No change needed**;
  same literal path.
- `~/.codex/hooks.json:8,19` — also bare `cctrl hooks run
  pre-tool-use|stop`. **Inventoried, no change needed**: Codex goes
  through the same launcher and gets the same fail-open behavior. Codex's
  own blocking exit-code convention should be confirmed before plan 038
  (see below) lands, but that's plan 038's problem, not this one's.
- Live sessions' baked MCP runtime/peer args (`--cctrl
  /Users/matthew/dev/cctrl/cctrl`, confirmed via `ps auxww` against
  `lib/runtime_mcp.py`/`lib/peer_mcp.py` argv, and the peer MCP
  `--mcp-config` baked at `cctrl:732-733`) already point at the dev tree
  directly, **not** at `~/.local/bin/cctrl` — those were baked when
  `SCRIPT_DIR` resolved through the old symlink to its real target. This
  plan doesn't touch `~/dev/cctrl/cctrl` itself, so already-running
  sessions are unaffected either way, and stay exposed to live-tree edits
  until restarted (unchanged risk, not introduced by this plan).
  **New** sessions launched through `~/.local/bin/cctrl` after this
  change will resolve `SCRIPT_DIR` to the release directory
  (`~/.local/lib/cctrl/releases/<sha>-<ts>`, *not* `current` — `cctrl:18`
  fully resolves symlinks with `readlink -f`) and bake that release path
  into their own MCP config and argv for the life of the session. This
  has a real consequence for release pruning — see "Install step" step 10
  below.
- No `mcpServers.cctrl_runtime`-style static config found in
  `~/.claude.json` or `~/.claude/settings*.json` — that entry is written
  per-session by `session-wrapper.sh`, not a static file to migrate.

**Test suite.** `tests/run-tests.sh` already isolates
`CCTRL_DATA_DIR`/`CCTRL_SESSION_METADATA_DIR`/`CCTRL_HOST_ID_FILE` to a
temp dir per run, and `test_syntax()` (line 368) already runs `bash -n`
over `cctrl`, `install.sh`, the `hooks/*.sh`, and `py_compile`s several
Python files and the `plugins/cctrl-*` entry scripts — but it **misses**
`lib/health-check.sh`, `lib/health-check-patterns.sh`, `lib/pane_draft.pl`,
several `lib/*.py` files (`agent_model.py`, `cctrl_fleet_collect.py`,
`codex_app_server.py`, `codex_rollout.py`, `codex_websocket.py`,
`conflict_resolve.py`, `launch_event.py`, `shell_literals.py`,
`snapshot_restore.py`, `terminal_identity.py`, `tmux_snapshot.py`), and
two hook files (`hooks/codex-hook-config.py`, `hooks/codex-session-observer.py`
— both ship and are checked for existence by `hooks doctor`, `cctrl:14141`,
and the latter is run by `codex-observe`, `cctrl:13924`). Since the
install gate's whole premise is "full suite green ⇒ safe to ship," that
gap has to close first, and it should close by **glob**
(`lib/*.sh`, `lib/*.py`, `lib/*.pl`, `hooks/*.sh`, `hooks/*.py`,
`plugins/cctrl-*`, `install/*.sh`) rather than a hand-kept list, so a
future new file is covered automatically instead of silently exempted.
`bash -n cctrl` measured at ~20ms.

**Hook exit-code convention.** Claude Code's actual convention (not what
the original draft of this plan assumed): **only exit 2 blocks** a hook;
any other non-zero exit is a non-blocking error, logged but not enforced.
`docs/plans/038-...md:458` already flags that `hooks/block-git-commit.py:33`
exits 1, which is **non-blocking today** — the "deliberate block" this
plan set out to preserve isn't actually blocking anything right now, and
that's a pre-existing bug this plan doesn't need to fix. It also explains
the 2026-09-27 incident precisely: a bash syntax error in the live tree
made `cctrl` exit 2, and Claude Code treated *every* `Bash` call as
denied.

Consequence for the fail-open design: **nothing dispatched through
`hooks run` today deliberately exits 2**, so treating "0 or 1 passes
through, anything else fails open" as the allowlist is safe *right now*
— it happens to also be a no-op for blocking purposes until plan 038 (or
something like it) makes a hook deliberately exit 2. When that lands,
the allowlist must be revisited: exit 2 would need to pass through
unchanged too, and at that point telling "cctrl parsed fine and
deliberately denied" apart from "cctrl's shell wrapper hit a real syntax
error and also exits 2" stops being free. Flagging this as a forward
note on plan 038, not a blocker here.

**Update (2026-09-28, plan 083):** issue #1 above (the launcher swallowing
a deliberate exit 2 into "fail open") is now fixed. The passthrough set
in `install/cctrl-launcher.sh` is `0|1|2` (was `0|1`), so a hook that
deliberately exits 2 is no longer downgraded to "allow"; every other
unexpected code (126, 127, signal-derived 128+N, anything not 0/1/2)
still fails open exactly as designed here. Plan 083 also made
`hooks/block-git-commit.py`'s stderr message honest about being
advisory-only (issue #2 below); the hook still exits 1, not 2, so it
still doesn't actually block anything — making it exit 2 to actually
block remains plan 038's separate, not-yet-made call.

This makes the ambiguity flagged above live, and it's broader than just
the release's `current/cctrl` crashing with a bash syntax error (exit 2)
— that specific case is covered (the fail-open test
suite's `test_cctrl_launcher_hooks_run_fails_open_on_broken_release`
fixture was changed to a bad-interpreter shebang, exit 127, instead of a
bash syntax error, exit 2, specifically to keep testing the "unrunnable
release fails open" case without colliding with the new deliberate-block
code — and a release only ships after passing `bash -n`, per
`install/self-install.sh`, so a syntax-error release shouldn't happen in
practice). The wider, still-open risk (2026-09-28 eng review of plan
083) is any *accidental* exit 2 from the real hook dispatch path, which
would now be indistinguishable from a deliberate block rather than
failing open:
- `cctrl`'s `hooks run` dispatch execs the target hook script directly
  (e.g. `exec python3 "$SCRIPT_DIR/hooks/block-git-commit.py"`); if that
  file is missing or unreadable in a given release, the shell's own exec
  failure can itself exit 2.
- `cctrl` runs under `set -euo pipefail`; any command inside the `hooks
  run` codepath that itself happens to exit 2 (a `grep` usage error, an
  argparse usage error from a Python hook, etc.) propagates straight out
  as `cctrl`'s own exit code, with no way to distinguish "the hook
  deliberately denied" from "something in the dispatch path broke."
- The launcher only wraps `hooks run`, but Claude Code's own meaning of
  exit 2 differs by hook type — for `Stop` it means "don't stop", for
  `PermissionRequest` it means "deny" — so an accidental exit 2 doesn't
  just silently allow-through anymore, it actively blocks or denies
  something, which is a real behavior change from before this plan.

No hook dispatched through `cctrl hooks run` deliberately exits 2 today
(`pre-tool-use` → `block-git-commit.py`, `stop` → `notify.sh` +
`session-log.py`, `notify` → `notify.sh`, `codex-observe` →
`codex-session-observer.py` — none of them do), so none of the above
fires yet through the launcher. `hooks/peer-doorbell.sh` *does*
deliberately exit 2 already (README: "Stop/Notification hook: exit 2 on
queued peer mail"), but it's registered as its own direct hook command
(its absolute path, checked by `_peer_doorbell_registered`) — Claude
Code/Codex invoke it directly, not through `cctrl hooks run`, so it never
passes through the launcher and this plan doesn't touch its behavior.
It's useful proof the exit-2 convention already works correctly
end-to-end for a real hook, just not (yet) for one dispatched via `hooks
run`. The fail-open guarantee this whole design exists to provide is now
narrower than "any non-0/1 code from the `hooks run` dispatch path is
safe" — it's "any non-0/1/2 code is safe; a 2 is trusted as deliberate."
Matthew approved this trade-off (C-17) with the awareness that it's a
deliberate narrowing, not a no-op.

## Design

### Layout

```
~/.local/bin/cctrl                          <- plain file, tracked launcher (install/cctrl-launcher.sh)
~/.local/lib/cctrl/current                  <- symlink -> releases/<git-sha>-<timestamp>
~/.local/lib/cctrl/releases/<sha>-<ts>/
    cctrl, lib/, hooks/, completions/, plugins/   <- real copies (__pycache__ excluded)
    data      -> /Users/matthew/dev/cctrl/data           <- symlink, never copied
    costs     -> /Users/matthew/dev/cctrl/costs           <- symlink, never copied
    profiles  -> /Users/matthew/dev/cctrl/profiles        <- symlink, never copied
    .active-profile -> /Users/matthew/dev/cctrl/.active-profile  <- symlink, never copied
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

The launcher must **not** use `set -e`: `"$CCTRL_REAL" "$@"; rc=$?`
depends on running past a nonzero exit to capture `rc`. `set -e` would
abort the script at that line instead, which defeats the entire
fail-open design. Covered by fail-open test (b)/(c) below, which would
catch a `set -e` regression.

### Fail-open wrapper (in `install/cctrl-launcher.sh`)

```bash
CCTRL_HOME="${CCTRL_HOME:-$HOME/.local/lib/cctrl}"
CCTRL_REAL="$CCTRL_HOME/current/cctrl"

if [[ "${1:-}" == "hooks" && "${2:-}" == "run" ]]; then
    if [[ -x "$CCTRL_REAL" ]]; then
        "$CCTRL_REAL" "$@"
        rc=$?
        case $rc in
            0|1|2) exit "$rc" ;;    # 0 = allow. 1 = non-blocking warning,
                                     # passes through unchanged. 2 = Claude
                                     # Code's real "block" code; passed
                                     # through unchanged too (plan 083) so a
                                     # hook that deliberately exits 2 is
                                     # never silently downgraded to
                                     # "allow" — see "Hook exit-code
                                     # convention" above and its plan 083
                                     # update note.
            *)
                echo "cctrl: hooks entrypoint exited $rc unexpectedly — failing open" >&2
                exit 0
                ;;
        esac
    else
        echo "cctrl: hooks entrypoint missing ($CCTRL_REAL) — failing open, allowing the tool call" >&2
        exit 0
    fi
fi

exec "$CCTRL_REAL" "$@"
```

Only `hooks run` gets this treatment — every other subcommand
(`session ls`, `hooks doctor`, ...) still fails loudly, so real breakage
stays visible instead of being silently swallowed everywhere. No `bash -n`
pre-check on every invocation: a parse error in `$CCTRL_REAL` already
exits 2 when run (the whole script is one top-level brace group,
`cctrl:4-12`, with no side effects before the syntax is parsed), and the
`*)` branch already fails that case open — a separate `bash -n` call on
every single hook invocation (which fires on every tool call) would be
pure overhead for a case already handled. The `-x` check stays because it
gives a clear, specific stderr message for the "release missing/not
installed" case rather than a generic "no such file" from the shell.

### Install step (`install/self-install.sh`, new)

Run from inside this checkout. Never touches `~/.local/bin/cctrl` or
`~/.local/lib/cctrl` until every gate passes. Gates run **against the
scratch copy that will actually be shipped**, not against the live
working tree — running gates against the tree and then copying it
separately reopens exactly the 2026-09-27 hazard (a livesync write or
another session's edit landing between "tests passed" and "copy made").
A `trap` removes the scratch dir on any failure or interrupt.

1. `trap 'rm -rf "$SCRATCH"' EXIT` before creating anything.
2. **Superseded design note:** the first four live attempts built the
   release with a hand-kept `cp -a` list (`cctrl`, `lib/`, `hooks/`,
   `completions/`, `plugins/`, `tests/`, ...), and it missed a path on
   three of the four attempts — `install.sh`/`install/`
   (`test_syntax()`'s unconditional `$ROOT/install.sh` check),
   `AGENTS.md`/`CLAUDE.md`/`README.md`/`skills/`
   (`test_peer_contract_docs`, `test_codex_ownership_matrix_contract`),
   and `.githooks/` (`tests/test_secret_hook.py` runs
   `.githooks/pre-commit` directly). Each miss failed the gate loudly
   before touching anything installed — the fail-safe design worked
   exactly as intended every time — but a list that has to be
   hand-extended every time a test references a new top-level path
   isn't a sound long-term shape. Per fleet-manager direction
   (gitarchive-fm0928, 2026-09-28), replaced with:
   **`git archive` from a required-clean `HEAD`.**
3. Refuse to build if the tree is dirty:
   `git -C "$ROOT" status --porcelain --untracked-files=no` — non-empty
   output aborts before creating anything. `--untracked-files=no` is
   deliberate: `data/`, `costs/`, `profiles/`, `.active-profile` are
   gitignored and must not block an install just for existing; only
   *modifications to tracked files* count as dirty, which is exactly
   the 2026-09-27 hazard shape (a half-finished edit to a tracked file).
   This makes "only committed code ships" an explicit property of the
   installer, not an accident of what a `cp -a` list happened to catch.
4. Build the release in a scratch dir first:
   `~/.local/lib/cctrl/releases/.tmp-$$` (created on the same filesystem
   as `releases/` so the later `mv` is a same-fs rename).
   `git -C "$ROOT" archive --format=tar "$SHA" | tar -x -C "$SCRATCH"`
   extracts every tracked file at `HEAD` and nothing else — no hand-kept
   list to fall out of sync with what the bundled test suite references.
   Write `$SHA` (the full commit hash) to `$SCRATCH/VERSION`. `data/config.json`
   is tracked despite `data/` being gitignored (it ships a default config
   for fresh installs), so the archive leaves a real `data/config.json`
   behind — `rm -rf` the archived `data/`, `costs/`, `profiles/`,
   `.active-profile` (only the last three are ever non-empty from the
   archive) before creating the four symlinks back to this repo's real
   copies, same as before.
5. `bash -n` on the **scratch copy's** `cctrl`, `install.sh` (if
   present), `install/self-install.sh`, `install/cctrl-launcher.sh`,
   every `lib/*.sh` and `hooks/*.sh` (glob, not a hand list).
6. `python3 -m py_compile` on the scratch copy's every `lib/*.py`,
   `hooks/*.py`, and `plugins/cctrl-*` (glob).
7. `perl -c` on the scratch copy's `lib/pane_draft.pl`.
8. `LANG=en_US.UTF-8 bash "$SCRATCH/tests/run-tests.sh"` — full suite,
   run from inside the scratch copy so it exercises exactly what's about
   to ship, must exit 0.
9. Any failure in 3–8 aborts with a clear message; the `EXIT` trap cleans
   up the scratch dir; nothing under `~/.local/bin` or `~/.local/lib`
   changes.
10. `mv` the scratch dir to its final name `releases/<short-sha>-<UTC
    timestamp>` (atomic rename, same filesystem, disarm the cleanup trap
    for this path once the mv succeeds).
11. Atomic symlink swap: `ln -s "releases/<new>" current.next && mv -fh
    current.next current`. **`-h`/`-n` is required**: plain `mv -f
    current.next current` on macOS/BSD `mv` follows `current` (a symlink
    to a directory) and moves `current.next` *inside* the old release
    instead of replacing the `current` symlink itself — verified by
    reproduction in a scratch dir during review. `mv -fh` (or `-n`)
    replaces the symlink instead of following it, which is what makes this
    step atomic. Verify immediately after: `[[ "$(readlink current)" ==
    "releases/<new>" ]]` — abort loudly (this is now a real bug, not a
    "couldn't run" case) if it doesn't match.
12. Install the launcher: copy `install/cctrl-launcher.sh` to
    `~/.local/bin/cctrl.new`, `bash -n` it, `chmod +x`, `mv` it onto
    `~/.local/bin/cctrl` (atomic rename, replaces the existing symlink or
    file at that exact path in one syscall — this one has no
    symlink-vs-target ambiguity since `~/.local/bin/cctrl` itself is a
    plain file after the first install, and even on the very first
    install `mv` onto an existing symlink replaces the symlink itself,
    not its target, because the destination has no trailing slash and
    `current`-style directory-following doesn't apply to a file `mv`).
13. **No automatic pruning of old releases.** Sessions started through
    `~/.local/bin/cctrl` resolve `SCRIPT_DIR` to their release directory
    (not `current`) at startup and bake that literal path into their MCP
    runtime/peer config and argv for the session's entire life
    (`cctrl:732-733`, `:7496`, `:8681`; `session autoheal install`,
    `:11758`, is dormant today but would bake it too). Fleet-manager
    sessions live for weeks; a "keep last 2" prune policy would delete a
    release a still-running session depends on after as few as 2-3
    installs. Deferred: a process-aware prune (only remove a release
    directory if no `ps auxww` entry references its path) is real future
    work, tracked as a follow-up, not blocking this plan. A release
    directory is small (a few MB); unbounded growth over months is an
    acceptable trade for not breaking long-lived sessions.
14. Print what changed and the rollback command.

### Rollback

One command restores today's behavior exactly (symlink straight into the
working tree):
```
ln -sf /Users/matthew/dev/cctrl/cctrl /Users/matthew/.local/bin/cctrl
```
`ln -sf` unlinks then re-creates, so there's a sub-millisecond window
where `~/.local/bin/cctrl` doesn't exist; a hook firing in that window
gets `command not found` (exit 127), which Claude Code treats as
non-blocking (only exit 2 blocks — see "Hook exit-code convention"), so
this is acceptable as-is. A strictly atomic alternative if ever needed:
`ln -s /Users/matthew/dev/cctrl/cctrl cctrl.rb && mv -fh cctrl.rb cctrl`
from `~/.local/bin`.

Do **not** delete `~/.local/lib/cctrl` (the `releases/` tree) right after
a rollback — any session started while the installed copy was active
still has that release path baked into its MCP config for its remaining
lifetime (same reasoning as step 11 above). Only remove it once every
session that started after the switch has closed. Because `data/`,
`costs/`, `profiles/`, and `.active-profile` are symlinks back to this
repo (not copies), a rollback loses no state — nothing written during
the window the installed copy was active lives anywhere but the repo
itself.

## Requirements

- [ ] `install/cctrl-launcher.sh` added: no `set -e`; `hooks run` gate
      exactly as designed above; `bash -n` clean; covered by
      `tests/run-tests.sh`.
- [ ] `install/self-install.sh` added: refuses to build from a dirty
      tree (`git status --porcelain --untracked-files=no` non-empty);
      builds the scratch release from `git archive --format=tar HEAD`
      (not a hand-kept file list — see "Superseded design note" above),
      writes the full commit SHA to `VERSION` inside the release, runs
      every gate (syntax + full suite) against the scratch copy, cleans
      up on any failure via `trap`, then does the atomic `releases/`
      rename, the `mv -fh current.next current` swap (with a post-swap
      `readlink` assertion), and the atomic launcher install; does
      **not** auto-prune old releases; prints the rollback command on
      success.
- [ ] `data/`, `costs/`, `profiles/`, `.active-profile` are never
      shipped from the archive — each is always a symlink from the
      release back to this repo (the archive's own `data/config.json`,
      tracked despite `data/` being gitignored, is deleted before the
      symlink is created). `plugins/` **is** shipped as real files via
      the archive (it's code, not mutable state).
- [ ] `tests/run-tests.sh`'s `test_syntax()` extended by **glob**
      (`lib/*.sh`, `lib/*.py`, `lib/*.pl`, `hooks/*.sh`, `hooks/*.py`,
      `plugins/cctrl-*`, `install/*.sh`) so new files are covered
      automatically and the install gate actually checks everything it
      ships.
- [ ] New tests for the fail-open wrapper: (a) `hooks run pre-tool-use`
      with a syntactically broken `$CCTRL_REAL` exits 0 with a stderr
      warning; (b) a mock exit 1 passes through as exit 1 unchanged; (c)
      an unexpected exit code (mock exit 137) exits 0 with a warning; (d)
      non-`hooks run` commands are unaffected (still fail loudly); (e)
      `CCTRL_HOME` pointing at a directory with no `current` (or no
      `current/cctrl`) exits 0 with a warning, not a shell error.
- [ ] New test for the `current` symlink swap itself: build two scratch
      releases, run the swap step twice, assert `readlink current`
      matches the second release each time (regression test for the
      macOS `mv -f` vs `mv -fh` bug found in review).
- [ ] New test for the dirty-tree check: `git status --porcelain
      --untracked-files=no` against a real git fixture reports clean on
      a fresh commit, dirty after modifying a tracked file, and clean
      again with only an untracked file present (proves gitignored
      `data`/`costs`/`profiles`/`.active-profile` never block an
      install). Tests the exact mechanism, not a full
      `install/self-install.sh` run — the latter also runs the entire
      suite internally and would make the test recursive.
- [ ] `~/.claude/settings.json` requires **no changes** (hooks already
      call bare `cctrl` via `$PATH`) — verify this stays true, don't
      "fix" it if it doesn't need touching.
- [ ] `com.cctrl.session-snapshot.plist` requires **no changes** (same
      absolute path, `~/.local/bin/cctrl`) — verify, don't touch.
- [ ] `~/.codex/hooks.json` requires **no changes** (same bare-`cctrl`
      pattern as Claude Code) — verify, don't touch.
- [ ] Live switch: run `install/self-install.sh` once, for real, on this
      machine, replacing the current symlink.
- [ ] Post-switch verification (see below) all pass before reporting done.

## Verification

- [cmd] `bash -n install/cctrl-launcher.sh && bash -n install/self-install.sh`
- [cmd] `LANG=en_US.UTF-8 bash tests/run-tests.sh` — full suite green
- [cmd] `bash install/self-install.sh` — succeeds, prints new release path
- [assert] `file ~/.local/bin/cctrl` reports a regular file, not a symlink
- [assert] `cat ~/.local/lib/cctrl/current/VERSION` equals `git rev-parse HEAD` at install time
- [assert] `readlink ~/.local/lib/cctrl/current` **equals the just-installed
  release path exactly** (not merely "points at some `releases/...` dir" —
  the macOS `mv -f` bug in review left `current` pointing at the *old*
  release while silently creating `releases/<old>/current.next`)
- [assert] `readlink ~/.local/lib/cctrl/current/data` == `/Users/matthew/dev/cctrl/data`
- [assert] same for `costs`, `profiles`, `.active-profile`
- [cmd] `cctrl session ls` — works
- [cmd] `cctrl profile ls` — active profile still shows "personal" (proves
  `.active-profile` symlink resolves correctly, not silently reset)
- [cmd] `cctrl ports --help` (or equivalent plugin subcommand) — proves
  `plugins/` was copied and dispatches correctly
- [cmd] `echo '{}' | cctrl hooks run stop` — exits 0
- [assert] after that Stop hook fires, `costs/spending.jsonl` in *this
  repo* (not inside the release) gained a line, proving the `costs`
  symlink resolves and history isn't forked into the release
- [cmd] `echo '{"tool_input":{"command":"git commit -m x"}}' | cctrl hooks run pre-tool-use; test $? -eq 1` — deliberate-block path passes exit 1 through unchanged (not proof of an actual Claude Code block — see "Hook exit-code convention")
- [cmd] with `$CCTRL_HOME/current/cctrl` temporarily corrupted (test only, via `CCTRL_HOME` env override to a scratch copy — never the real installed one): `echo '{}' | cctrl hooks run pre-tool-use` exits 0 with a stderr warning
- [cmd] `grep -c '"cctrl hooks run' ~/.codex/hooks.json` unchanged before/after
- [cmd] `time (echo '{}' | cctrl hooks run pre-tool-use)` before and after the switch — no meaningful regression
- [assert] next `com.cctrl.session-snapshot` timer firing leaves
  `~/.local/log/cctrl-snapshot.stderr.log` empty
- [assert] a live session (named explicitly at execution time, not "a
  session") has a Stop hook fire after the switch, verified by a new
  `session_update` line appended to `costs/spending.jsonl` for that
  session's id — "still fires normally" isn't verifiable just by
  observing no error

## Out of scope

- The public `curl | bash` install.sh flow (fresh-machine clone from
  GitHub) — untouched.
- Fixing the `tmux -t` prefix-match hazard — filed separately as plan 080,
  plan-only per the fleet manager's instruction not to touch live tmux
  targeting in this change.
- `~/.claude/settings.json`'s statusline hook
  (`/Users/matthew/dev/cctrl/hooks/statusline.sh`, called by absolute
  path, not through `cctrl`) — untouched by this plan, stays exposed to
  live-tree edits the same as before.
- Fixing `hooks/block-git-commit.py`'s exit code (1, non-blocking today)
  to actually block (exit 2) — that's plan 038's concern, noted above as
  a forward dependency on this plan's fail-open allowlist, not fixed
  here.
- Process-aware release pruning — deferred, tracked as a follow-up (see
  Install step, item 11).
