---
id: 107
title: tmux isolation that does not depend on prose (part 1: a hook guard that blocks a bare tmux kill-server)
status: in-progress
blocked-by: []
priority: 107
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-10-11
tui-fixture: n/a  # a PreToolUse hook check + test-harness fixes
approved-by: Matthew (2026-10-11, chose "Hook guard first (Recommended)" in the fleet manager's questions; approvals mdec-1011-cctrl-hook-guard (hook guard, smaller findings, one narrow harness run) + mdec-1011-cctrl-stop-fix-first (harness changes, no runs))
reviews: []
---

<!-- tmux-lint: allow-file (this plan is about the blocked command and quotes its forms; never run them) -->

## Plain-English Summary

On 2026-10-09 a validation sub-agent cleaned up with
`for l in new old; do TMUX_TMPDIR=$D/tt-$l tmux kill-server; done`.
It ran inside a fleet pane, so `$TMUX` pointed at the fleet's tmux server.
tmux prefers `$TMUX` over `TMUX_TMPDIR`. The kill went to the fleet server
and about 25 sessions died. The rule against it was prose in a brief.

Part 1 makes the rule mechanical: the PreToolUse hook that cctrl already
installs for every Bash tool call now refuses a command that would run
`tmux kill-server` unless the same tmux invocation names its server with
`-S <path>` or `-L <name>`.
The same branch closes the open findings on the test-harness tmux isolation
(commits 96fc26e, 3de0d09, 7e4ccee).

## Non-goals

- A security boundary. This is an accident guard: it reads the command text of
  one tool call. See "Known bypasses".
- Blocking `tmux kill-session` without an exact `-t '=NAME'` (the incident
  plan proposed it). Out of this change: it would refuse many everyday
  commands and needs its own design. Follow-up F1.
- Installing the hook. `cctrl hooks install` / `cctrl self-install` wait for
  Matthew's own go (the guard changes behaviour in every session).
- Lifting the test STOP (fleet-kill-osprey). The fleet manager does that.

## Parts

| Part | What | State |
|---|---|---|
| 1 | Hook guard (this document) | in progress on branch `plan-107-hook-guard` |
| 1b | Open findings on the harness fix (Task B below) | same branch |
| 2 | Harness helper `ptmux` / `cctrl dev tmux-sandbox` for validators | later; the suite's PATH shim (3de0d09) covers the suite itself |
| 3 | Brief rules for validators and smoke agents | done as skill text in 96fc26e, 7e4ccee; reworded here (finding 5) |
| 4 | Restore follow-ups (silent exit 1 at high swap, near-empty `latest.json`, lost `--model`, slow `session list --json`) | other work, not planned here |

## Verified facts (2026-10-11, code at 7e4ccee; read, not run, unless marked)

- `cctrl hooks install` writes one PreToolUse entry with matcher `Bash` and
  the command `cctrl hooks run pre-tool-use` into Claude Code's
  `settings.json` and (through `hooks/codex-hook-config.py`) into Codex's
  `hooks.json`.
- `_hooks_run pre-tool-use` was `exec python3 hooks/block-git-commit.py`:
  one python process per Bash call, advisory only (exit 1).
- `install/cctrl-launcher.sh` passes exit 0, 1 and 2 through for `hooks run`
  and turns every other code into exit 0 ("failing open"). Exit 2 is the hook
  protocol's deny; its stderr goes back to the agent (plans 079, 083).
- A hook script that is missing makes `python3` itself exit 2, so a release
  without `hooks/pre-tool-use.py` would block every Bash call. This existed
  before for `block-git-commit.py` (plan 088) and is pinned by
  `test_cctrl_hooks_run_exits_2_when_target_hook_script_missing`.
  `self-install.sh` builds releases from `git archive`, so tracked hook files
  always ship together.
- tmux picks its server in this order: `-S`, then `-L` (under `TMUX_TMPDIR`),
  then `$TMUX`, then the default socket.
- Python unit tests are found by `python3 -m unittest discover -s tests -p
  'test_*.py'` at the end of a full run; a new `tests/test_*.py` needs no
  registration.
- Measured here (one sample each, a plain `ls` payload): old hook 22 ms, new
  entry point 25 ms.

## Design

### Files

- `hooks/tmux_kill_guard.py`: the parser. Pure functions, standard library
  only. `check_command(text)` returns a reason or `None`; `block_message`
  builds the text for the agent. It starts nothing, opens no file and never
  calls tmux.
- `hooks/pre-tool-use.py`: the process `cctrl hooks run pre-tool-use` now
  execs. It reads stdin once, runs the guard, then runs
  `hooks/block-git-commit.py` unchanged in the same process (`runpy`) on the
  same payload. One python process per Bash call, as before.
- `hooks/block-git-commit.py`: not changed.

### Protocol

- Deny = exit 2 with the reason on stderr (the launcher already passes it
  through). No JSON decision output: exit 2 is the one form both Claude Code
  and Codex document for a command hook.
- The guard takes `tool_input.command` as a string, or as an argv list
  (joined with `shlex.join`), whatever `tool_name` says.
- Fail-open: empty or malformed JSON, a payload without a command, a missing
  or broken `tmux_kill_guard.py`, or any exception in the guard lets the call
  go on to the git-commit check. Only a positive match blocks. If the parser
  raises on a command, a small regex check (`_loose`) decides; it blocks only
  when it matches.
- A cheap pre-check (the text, with quotes and backslashes removed, contains
  `kill-ser`) runs before the parser is imported, so an ordinary call pays one
  `re.sub`. The parser is imported with bytecode writing off, so no
  `__pycache__` appears in a release directory.

### How the guard decides

1. No `kill-ser` in the de-quoted text: allow.
2. Split the text into simple commands with a small shell lexer: quotes,
   `$'...'`, backslashes, comments, `;` `&` `&&` `||` `|` newline, `( )`,
   redirections, here-documents and here-strings. Command substitutions
   (`$(...)`, backticks, `<(...)`), also inside double quotes, `${...}` and
   unquoted here-document bodies, are checked as shell text of their own.
3. Per simple command: drop leading assignments (`TMUX= `, `TMUX_TMPDIR=...`),
   shell keywords (`do`, `then`, `!`, `{`, `time`, ...) and known prefix
   commands (`command`, `exec`, `nohup`, `sudo`, `env` with its options, ...).
4. If the command name is a text command (`echo`, `printf`, `grep`, `rg`,
   `git`, `gh`, `cat`, `sed`, `awk`, `for`, `[[`, ...): allow.
5. If any word is `tmux` (by basename: `/opt/homebrew/bin/tmux`, `'tmux'`,
   `$(brew --prefix)/bin/tmux`), read tmux's own options from the words after
   it (`-S`, `-L`, clustered forms such as `-uS path` and `-Lname`). With a
   socket flag that names its own server: allow, whatever follows. Otherwise
   block when any later word holds `kill-ser`, `kill-serv`, `kill-serve` or
   `kill-server` (tmux accepts unique prefixes), also after a `\;`, and also
   inside a string argument (`run-shell`, `send-keys`, `new-session`).
6. A shell (`sh`, `bash`, `zsh`, ...) with `-c <string>`: the string is checked
   as shell text. Without a script argument, its standard input is: the
   here-document, the here-string, or the words of the pipeline stage in front
   (`echo '...' | sh`). `eval`, `trap` and `alias` strings are checked too.
7. Commands that hand a string to a shell (`ssh`, `su`, `watch`, ...): a
   string argument that mentions the kill is parsed as shell text. `ssh host`
   with no remote command: its standard input is a script too.
8. Commands that run code in their own language (`python3`, `perl`, `ruby`,
   `node`, `osascript`, ...): string arguments, here-documents and
   here-strings go through the regex check (a tmux word followed by the kill
   with no `-S`/`-L` between them).
9. A variable as the command name: `"$TMUX_BIN" kill-server` blocks when the
   line mentions tmux; `"$SHELL" -c '...'` is read as a shell; `cmd="..."; $cmd`
   and `eval "$X"` are checked against what the same line assigned to that
   variable.
10. Nothing matched: allow.

Bounds: recursion depth 6, 400 checked texts per command, 200 kB of command
text; beyond a bound the regex check decides. Measured after the review
fixes: 0.16 s for 180 kB of artificial input, under 1 ms for ordinary
commands.

### Decisions the brief asked for

- **`-L default`: blocked.** It names the default server, which in a cctrl
  session is normally the fleet's. (With a private `TMUX_TMPDIR` on the same
  command it would be private; the guard does not try to tell. Use `-S`.)
- **Other socket flags that are not an isolation: blocked.** `-S` with an
  empty literal path, `-S` built from `$TMUX` or from `#{socket_path}`, a
  `-S` path that ends in `/tmp/tmux-<uid>/default` (also `${TMUX_TMPDIR:-/tmp}`
  and `/private/tmp`), and `-S "$var"` on a line that names `/tmp/tmux-`
  (the "clean up every socket" loop).
- **`tmux kill-session` without `-t '=NAME'`: not in this change** (F1).
- **Malformed hook input: fail-open** (see Protocol).
- **Escape hatch: none built. Proposal: keep it that way.**
  - The hook only sees an agent's tool calls. A human who wants to kill the
    default server types the command in their own terminal, where no hook
    runs.
  - An environment variable in the session's own environment (for example
    `CCTRL_ALLOW_TMUX_KILL_SERVER=1`, read by the hook process, so an inline
    `VAR=1 tmux ...` could not set it) would be inherited by every sub-agent
    and every session spawned from that shell. That is the incident's path.
  - If Matthew wants one anyway, that variable is the design I would build,
    plus a line in `cctrl hooks doctor` that warns while it is set.
  - Separate question, also not built: a switch to turn the guard off if it
    misfires badly. Today the way out is `cctrl self rollback` or removing the
    PreToolUse entry by hand.

### Uncertain cases that block (by design)

- A `-S`/`-L` held in a variable (`tmux $SOCK_ARGS kill-server`): no literal
  flag is visible.
- A variable as the command name with a kill word after it, when the line
  mentions tmux anywhere (`"$TMUX_BIN" kill-server`, `T=tmux; $T kill-server`).
- A variable in tmux's command position on a line that mentions the kill
  (`for c in kill-server; do tmux $c; done`, `tmux "$@"; echo kill-server`).
- `tmux` and the kill as separate words after an unknown command
  (`mywrapper tmux kill-server`, and unquoted prose such as
  `cctrl session say X tmux kill-server is bad`). Quote the text as one
  argument and it passes.
- A bare tmux whose string argument holds the kill word as a word of its own
  (`tmux send-keys -t X 'echo kill-server' Enter`).
- Text piped into a shell (`echo "tmux kill-server" | sh`, also `| bash -n`)
  and code given to `python3`, `perl`, `osascript` and the like that mentions
  it, even when it would only print it
  (`python3 -c "print('tmux kill-server')"`, `python3 - <<'EOF'`).
- Unescaped backticks or `$(...)` around it inside double quotes or an
  unquoted here-document: bash does run those.

### Known bypasses (not blocked)

- A script written to a file and run later; `source`; a `tmux -f` config or
  `source-file`.
- A shell function or alias defined in an earlier tool call; a variable set in
  the session's environment (`$T kill-server` with no "tmux" on the line).
- A program not on the list that runs its string argument (for example
  `awk 'BEGIN{system("...")}'`, a custom wrapper taking a quoted command).
- Text assembled at run time (`printf` into `sh` through a variable,
  `$'\x6b'`-style escapes inside the kill word, base64).
- A safe-looking socket that is not private: `-S "$SOCK"` where the variable
  holds the fleet socket and was set in an earlier call (set on the same
  line from `$TMUX`, `#{socket_path}` or the default socket path, it
  blocks); `-L <name>` of a server someone else runs.
- `-S "$UNSET"`: believed harmless (tmux fails to connect to an empty path
  and does not fall back to `$TMUX`), but not verified: no tmux may run under
  the STOP. Worth one check of `tmux.c` or a run outside the fleet.
- A bare tmux inside a string argument of a tmux call that has a safe socket
  is allowed: in that pane `$TMUX` is the private server. (Not when the
  string clears `TMUX` itself.)
- A command whose kill word only exists at run time (`tmux kill-$c`), a
  script passed as `sh <(...)`, `xargs -I{} tmux {}`.
- tmux commands other than `kill-server`, and `pkill tmux` / `killall tmux`
  (F1).
- Sessions without the cctrl hook installed or, for Codex, not trusted.

## Tasks

### A. Hook guard

- [x] `hooks/tmux_kill_guard.py`, `hooks/pre-tool-use.py`.
- [x] `cctrl`: `_hooks_run pre-tool-use` execs the new entry point; `cctrl
      hooks run --help` no longer says "none block yet"; `hooks doctor` checks
      the two new files.
- [x] `tests/test_tmux_kill_guard.py`: block and allow tables, entry-point
      exit codes, fail-open inputs. Strings only; no tmux.
- [x] `tests/run-tests.sh`: the missing-hook-script test names the new file.
- [x] Docs: README hooks section, CHANGELOG, the findings doc.
- [x] Independent review (one Opus sub-agent, reading only; 77 candidate
      strings against the parser): APPROVED WITH REQUIRED FIXES. R1-R5 applied,
      see "Review".
- [ ] Install: waits for Matthew.

### B. Open findings on the harness fix

All done as code; none of it has run (test STOP).

1. [x] Python tests run directly cannot reach a real tmux by name
       (`tests/no_real_tmux.py`).
2. [x] The guard test no longer passes silently when no shim was installed.
3. [x] Teardown does not follow symlinks.
4. [x] The lint accepts only a socket flag in front of the kill word, with a
       value that is not `default` and not built from `$TMUX`. A file about
       the pattern itself opts out with a file marker.
5. [x] Skill and AGENTS text define `$D`.
6. [x] The shim contract test runs first (RUN_FIRST), before any real tmux.
7. [x] `_test_path` puts the shim in front of a system-dir tmux
       (`test_bash_leg_is_honest` expects the same).

## Review

Independent Opus sub-agent, 2026-10-11, reading only (no tmux, no test); it
called `check_command` on 77 strings. Report:
`~/.local/state/fleet/fm-cctrl-artifacts/plan-107/review-hook-guard.md`.
Verdict: APPROVED WITH REQUIRED FIXES. The fixes were not re-reviewed.

- R1 an apostrophe inside `"${var:-...}"` hid the rest of the line: fixed.
- R2 `"$SHELL" -c '...'`: fixed.
- R3 `bash -s -- arg <<EOF`: fixed.
- R4 `python3 - <<EOF` and other interpreters on a here-document: fixed
  (regex check; a here-document that only prints the words now blocks).
- R5 `_test_path` against the exact assert in `test_bash_leg_is_honest`: fixed.
- Recommended, applied: here-documents inside `$(...)` (the standard commit
  and PR form no longer blocks on `1)` or `:)`), `xargs grep` / `find -exec
  grep` / `ssh host "grep ..."` no longer block, text piped to
  `ssh host 'cat > file'` no longer blocks, `[[ a && b ]]`, the default
  socket through `${TMUX_TMPDIR:-/tmp}` and the socket-cleanup loop block,
  a variable holding the whole command, `sudo -u`, `timeout N`, `(( 1 << 4 ))`,
  time bounds, a guarded stdin read.
- Confirmation review (second Opus pass on 9b960ac/1e9d86f, 183 strings):
  SAFE TO INSTALL AFTER REQUIRED FIXES. Its one required item is applied:
  `ssh host 'bash -s' <<EOF` (a quoted remote command of two or more words
  with the script on stdin) blocks again. Also applied: `"$BASH" <<EOF` and
  `... | "$SHELL"`, a `-S` variable that the same line set from `$TMUX`,
  `#{socket_path}` or the default socket path, `-L` built from `$TMUX`. Its
  other recommended items (C4-C15 there) are open.
- Recommended, not applied: `sh <(...)`, `xargs -I{} tmux {}` (listed under
  known bypasses); the lint still takes a `-S`/`-L` of another program on the
  same line (`ssh -L ...`) as a socket flag.

## Verification

- `python3 tests/test_tmux_kill_guard.py` (pure string tests; allowed under
  the STOP).
- `bash -n` under `/bin/bash` and brew bash for `cctrl` and
  `tests/run-tests.sh`; `python3 -m py_compile` for the new files.
- Not run under the STOP: `tests/run-tests.sh` in any form, so the harness
  edits of Task B and the changed assert in
  `test_cctrl_hooks_run_exits_2_when_target_hook_script_missing` are read, not
  proven. One narrow run of two tests is prepared in the worker's report; the
  orchestrator starts it.

## Follow-ups

- F1: `tmux kill-session` / `kill-window` / `kill-pane` without an exact
  target, and `send-keys` into a session the caller does not own.
- F2: the hook reaches Codex only where the Codex hook is installed and
  trusted; a live check of exit 2 in a Codex session is owed.
- F3: a `ptmux` helper for validators (part 2).
