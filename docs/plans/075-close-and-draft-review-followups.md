---
id: 075
title: Deferred review items from plans 073 and 074
status: pending
blocked-by: []
priority: 75
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-27
tui-fixture: n/a
approved-by: none  # filed by the fleet manager's scope call (scope-fm0927); implement on approval
---

## Plain-English Summary

These are the P3 findings from the 2026-09-27 eng reviews of plans 073 (draft detector) and 074 (close reaps pane processes). They were deferred so the P2 fixes could ship first.

## Requirements

### Draft detector (073)
- [ ] Wrapped and multi-line drafts. Judge every composer line up to the bottom border or hint line, so a draft whose first composer line is empty is still found. Keep a draft that consists only of `>` or `|` as well.
- [ ] Separate exit code for "no composer found": a bash-mode `!` prompt, a pager, or a shell left after a crash. Autoheal treats it as unverifiable; rich state keeps the base state.
- [ ] Check against a live capture whether Claude draws the `[Pasted text …]` placeholder dim. If it does, treat it as a draft.
- [ ] One shared escape regex for `lib/pane_draft.pl` and `_strip_sgr`.

### Close reaper (074)
- [ ] Performance: one batched `ps -axo pid=,stat=,lstart=` per tick instead of `ps` + `awk` per pid, and a wall-clock deadline instead of counting ticks. Measured: 30 processes with a 2 s grace took 4.4 s.
- [ ] Send SIGCONT after SIGTERM so a stopped process can act on it. Count zombies (`Z`) as gone.
- [ ] Exclude the calling cctrl process and its ancestors from the snapshot. `close --now` or `kill` run from inside the pane being killed must not kill the reaper itself.
- [ ] Delayed close: take the snapshot inside the tmux-server job, right before the kill, so children started during the grace are included.
- [ ] Resolve the tmux session id once and use it everywhere in `session close`. Today the kill uses a prefix match while the snapshot uses the exact `=name`.
- [ ] The wrapper's SIGKILL also kills the agent's descendants (MCP servers, tool processes).
- [ ] `lib/session-wrapper.sh`: validate `CCTRL_WRAPPER_TERM_GRACE` against `^[0-9]+$` and fall back to 10. Today a value like `5s` exits inside the trap before the agent is signalled.

## Rules

Edit a copy of `cctrl` or `lib/*` and syntax-check it (`bash -n` / `perl -c`), then `mv` it into place. The live tree runs every session's hooks.
