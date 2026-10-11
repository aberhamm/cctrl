# Untargeted tmux calls hit the default server's current session

An untargeted tmux command (no `-t`, no `-L`) run with `TMUX` unset does not
fail and does not pick "no session" — it resolves against the OS-default tmux
server and, for anything that needs a session (`display-message`, `send-keys`
without `-t`, etc.), that server's *current* session: whichever session is
most recently active, by name or by directory, has nothing to do with the
caller. A background job or test harness that unsets `TMUX` and then calls
tmux untargeted is therefore operating on an arbitrary real session, not a
sandboxed nothing.

This is what caused the plan 071 phase 5 incident: `cctrl restart`'s
background kill step ran `tmux display-message -p '#{pane_pid}'` untargeted.
The test harness unsets `TMUX`/`TMUX_PANE` to isolate tests, so the call fell
through to the default server's current session and the resulting pid resolved
to that session's agent, which got SIGTERMed. See plan 080 (exact-target
matching) for the related, narrower hazard of `-t NAME` falling back to a
prefix match.

Rules that follow from this:

- Any `tmux` call reachable from tests or from shared/background code paths
  must be targeted (`-t '=NAME'` / `'=NAME:'`) or derived from verified
  process ancestry (walk `ps` parent pids, don't ask tmux "what's current").
  Never rely on tmux's own notion of "current" to identify *which* session a
  command should act on.
- A test harness that needs a scratch tmux server must point `TMUX_TMPDIR` at
  a private, empty directory before any test runs, so even a stray untargeted
  call lands somewhere harmless instead of the developer's real server.
  **This is a second layer only** (see the 2026-10-09 note below).
- On macOS, keep that private `TMUX_TMPDIR` short: tmux's socket path is
  `$TMUX_TMPDIR/tmux-<uid>/<name>`, and `AF_UNIX` socket paths are capped at
  `sun_path`, 104 bytes. A path built under the real `$TMPDIR` (already long,
  per-process on macOS) overflows that limit; use a short `/tmp/...` dir
  instead (see `tests/run-tests.sh`'s `CCTRL_TEST_TMUX_TMPDIR`).

## 2026-10-09: `TMUX_TMPDIR` is not an isolation while `TMUX` is set

tmux picks its server in this order: `-S <path>`, then `-L <name>` (under
`TMUX_TMPDIR`), then `$TMUX`, then the default socket. So a private
`TMUX_TMPDIR` protects nothing in a shell that still has `TMUX` set, and every
shell inside a tmux pane has it, including a sub-agent's: a sub-agent runs in
its parent's pane and inherits the parent's `TMUX`.

That is how a validation sub-agent killed a whole fleet's tmux server. Its
brief said "private socket, `TMUX_TMPDIR` in your mktemp dir, `env -u TMUX`".
It built its private servers correctly, then cleaned up with one line that
had the `TMUX_TMPDIR` prefix but not the `env -u TMUX`:

<!-- tmux-lint: allow (the incident command, quoted as a warning; never run it) -->
    for l in new old; do TMUX_TMPDIR=$D/tt-$l tmux kill-server; done

`TMUX` won, and the kill went to the fleet server.

Rules that follow:

- Only an explicit socket is an isolation: `tmux -S "$D/sock" ...` (or `-L`
  with a `TMUX_TMPDIR` you set in the same command). Never rely on
  `TMUX_TMPDIR` or on an unset `TMUX` alone.
  <!-- tmux-lint: allow (the next rule forbids the command) -->
- Never run `tmux kill-server` against a server you did not start on your own
  socket. To clean up, kill your own sessions by exact name on your own socket
  (`tmux -S "$D/sock" kill-session -t '=NAME'`); the server exits with its
  last session.
- `tests/run-tests.sh` enforces this by construction: the `tmux` on the suite's
  PATH is a shim that sends every call to a socket under the suite's private
  dir, drops a `TMUX` that points anywhere else, and refuses (exit 97) a socket
  outside that dir. The unset `TMUX` and the private `TMUX_TMPDIR` stay as the
  second layer. `test_private_tmux_shim_contract` checks the shim against a
  stub; `test_no_unsafe_tmux_isolation` is a static lint over `tests/`,
  `docs/`, `skills/` and `AGENTS.md` for a server kill without `-S`/`-L` and
  for `TMUX_TMPDIR` used as the only isolation of a tmux command. A doc that
  quotes the bad pattern as a warning carries `tmux-lint: allow` on that line
  or the line above.
- Agents: see the "sub-agents and tmux" rule in the `cctrl-repo-orchestrator`,
  `cctrl-fleet-manager` and `cctrl-spawn` skills.
