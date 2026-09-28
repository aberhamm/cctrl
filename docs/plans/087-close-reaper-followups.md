---
id: 087
title: Close reaper follow-ups (074 re-review)
status: pending
blocked-by: []
priority: 87
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-28
tui-fixture: n/a
approved-by: matthew (C-15, via cctrl-fleet-manager)
---

## Plain-English Summary

Split from plan 075. P3 findings from the 2026-09-27 eng review of plan
074 (close reaps pane processes), plus items from the follow-up
re-review, that weren't fixed when the P2 fixes shipped. Also folds in
one unrelated test-hygiene cleanup in the same test file.

## Requirements

- [ ] Performance: one batched `ps -axo pid=,stat=,lstart=` per tick
      instead of `ps` + `awk` per pid, and a wall-clock deadline instead of
      counting ticks. Measured: 30 processes with a 2s grace took 4.4s.
- [ ] Send SIGCONT after SIGTERM so a stopped process can act on it. Count
      zombies (`Z`) as gone.
- [ ] Exclude the calling cctrl process and its ancestors from the
      snapshot. `close --now` or `kill` run from inside the pane being
      killed must not kill the reaper itself.
- [ ] Delayed close: take the snapshot inside the tmux-server job, right
      before the kill, so children started during the grace are included.
- [ ] Resolve the tmux session id once and use it everywhere in `session
      close`. Today the kill uses a prefix match while the snapshot uses
      the exact `=name`.
- [ ] The wrapper's SIGKILL also kills the agent's descendants (MCP
      servers, tool processes).
- [ ] `lib/session-wrapper.sh`: validate `CCTRL_WRAPPER_TERM_GRACE`
      against `^[0-9]+$` and fall back to 10. Today a value like `5s` exits
      inside the trap before the agent is signalled.
- [ ] Warn when a stop-exact process snapshot fails, as kill and close
      already do.
- [ ] Warn when `reap_cmd` is empty on the delayed-close path.
- [ ] A test running a Codex-agent pane through `session close`.
- [ ] A test of the survivors report, for a process that survives SIGKILL.
- [ ] `tests/run-tests.sh`: the `tree_digest` helper inside the Codex hook
      test is now unused, because its callers use `live_tree_digest`.
      Remove it.

## Rules

Edit a copy of `cctrl` or `lib/*` and syntax-check it (`bash -n` / `perl
-c`), then `mv` it into place. The live tree runs every session's hooks.

Use exact tmux targets (`-t '=NAME'` / `'=NAME:'`) anywhere this plan
touches session-close code or tests. Test with the existing fake-tmux
harness only — never exercise close/kill against live fleet sessions.
