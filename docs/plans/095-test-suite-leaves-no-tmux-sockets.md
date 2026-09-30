---
id: 095
title: Test suite leaves no tmux sockets behind
status: done
completed: 2026-09-30
blocked-by: []
priority: 95
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-30
tui-fixture: n/a  # test-infra only, no TUI surface touched
approved-by: matthew (mdec-0930-cctrl item 3, via cctrl-fleet-manager)
reviews:
  - type=eng verdict=approved date=2026-09-30 by=opus-level-subagent
---

## Plain-English Summary

`/private/tmp/tmux-501/` had accumulated 338 stale `cctrl-*` tmux socket
files, all matching the three private-socket test functions in
`tests/run-tests.sh` (`cctrl-exact-stop-*` 134, `cctrl-reap-*` 86,
`cctrl-terminate-*` 98, plus a handful of manual-repro one-offs from past
workers). Each of those three tests already had an `EXIT` trap calling
`tmux -L "$socket" kill-server` — that looked sufficient, but wasn't.

## Root cause

`tmux kill-server` does not unlink its own socket file on this host's tmux.
Confirmed directly:

```
$ S="cctrl-explore-test-$$"; tmux -L "$S" new-session -d -s x 'sleep 5'
$ tmux -L "$S" kill-server; sleep 0.3
$ ls /private/tmp/tmux-501/ | grep "$S"
cctrl-explore-test-87101   # still there
```

So every private-socket test's trap has been faithfully killing its server
and just as faithfully leaving the socket file behind, one per run, for as
long as these tests have existed.

## Fix

- `tests/run-tests.sh`: added `CCTRL_TEST_TMUX_SOCKET_DIR` (tmux's fixed
  socket dir, `${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)` — not `$TMPDIR`, which is
  this suite's own unrelated scratch root) and a `_test_tmux_socket_rm`
  helper, defined once near `fail()`.
- Each of the three cleanup traps (`cleanup_terminate`,
  `cleanup_reap`, `cleanup_exact_stop`) now also calls
  `_test_tmux_socket_rm "$socket"` after `kill-server`, so the socket file
  is removed on every exit path the trap covers (normal completion, `fail`,
  a `set -e` abort).
- New guard test `test_tmux_sockets_left_behind`: after the three
  private-socket tests, globs for any `cctrl-*-$$-*` socket (this run's own
  pid, embedded in each test's socket name — unaffected by subshells) still
  present in the socket dir and fails if one is. Matching on the run's own
  pid rather than a startup snapshot means a concurrent suite run or
  worktree doing the same private-socket tests at the same time is never
  blamed on this run. Wired into both the `session-stop-exact` focused
  group and the main unconditional run (the only two places those three
  tests are called —
  confirmed by grep, no other `CCTRL_TEST_ONLY` branch invokes them).

## Verification

- Confirmed via the reproduction above that `kill-server` alone leaves the
  socket file (this is the bug, not a hypothesis).
- Socket count before the focused run: 338 `cctrl-*` files in
  `/private/tmp/tmux-501/`. Ran
  `LANG=en_US.UTF-8 CCTRL_TEST_ONLY=session-stop-exact bash tests/run-tests.sh`
  (exercises all three private-socket tests plus the new guard): all
  `ok:` lines including `ok: no leftover cctrl-* tmux sockets`. Socket
  count after: still 338 — no new leak.
- Full suite, `/bin/bash` (3.2.57): RC=0, 171 `ok:`, no `FAIL`, plus
  `python3 -m unittest discover` 100 tests OK. Socket count before/after:
  338/338.
- Full suite, `/opt/homebrew/bin/bash` (5.3.20): RC=0, 171 `ok:`, no
  `FAIL`, same 100 python tests OK. Socket count before/after: 338/338.
- Both runs printed `ok: no leftover cctrl-* tmux sockets`.

## Eng review (Opus)

First pass: **changes requested.** The cleanup traps were sound (each
private-socket test is a `(...)` subshell, so its own `trap ... EXIT` covers
normal completion, `fail`'s `exit 1`, and a `set -e` abort alike), but the
guard test's snapshot-diff design had a real flaw: it flagged every
`cctrl-*` name not seen at suite start, so a *concurrent* suite run (another
worktree, or `install/self-install.sh`'s own gate run) doing the same
private-socket tests at the same time would get blamed on this run.

Fix: dropped the startup snapshot entirely. The guard now matches only
`cctrl-*-$$-*` — sockets containing this run's own `$$` (unaffected by
subshells, since the three socket names already embed `$$-$RANDOM`) — so a
concurrent run's sockets are structurally excluded rather than filtered by
timing.

Everything else was approved as-is: deletion safety (cctrl itself never
uses `-L`/`-S`, so nothing live can collide), the `${TMUX_TMPDIR:-/tmp}/tmux-$(id
-u)` path (no existing helper to reuse), and the two call sites (confirmed
independently: exactly two, matching the three socket definitions).

Second pass (Opus, approved, no further required changes): re-reviewed the
`$$`-matching rewrite.

## Follow-ups (not blocking, filed here)

- Move the main-run guard call to the very end of the unconditional test
  list so a future private-socket test added elsewhere is covered without
  remembering to wire it in.
- A SIGKILL (or a SIGTERM bash doesn't turn into an EXIT trap) still leaks a
  socket — acceptable residual as long as the out-of-band sweep (part B)
  stays available.

## Cleanup of pre-existing leftovers (part B)

Separately swept the 338 pre-existing `cctrl-*` sockets under
`/private/tmp/tmux-501/` accumulated by prior workers' test runs (predates
this plan's fix). For each: verified no live server
(`tmux -S <path> list-sessions` fails and `lsof <path>` shows no holder),
then `rm -f -- "<exact path>"` (no globs). Counts: see handoff.
