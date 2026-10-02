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
- On macOS, keep that private `TMUX_TMPDIR` short: tmux's socket path is
  `$TMUX_TMPDIR/tmux-<uid>/<name>`, and `AF_UNIX` socket paths are capped at
  `sun_path`, 104 bytes. A path built under the real `$TMPDIR` (already long,
  per-process on macOS) overflows that limit; use a short `/tmp/...` dir
  instead (see `tests/run-tests.sh`'s `CCTRL_TEST_TMUX_TMPDIR`).
