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

### From the 073/074 re-review (2026-09-27)
- [ ] A typed draft that *starts* with placeholder text (`❯ Try "foo…"`, `❯ esc to cancel…`) still reads as empty. Apply the hint check only to composer lines with no SGR at all.
- [ ] Warn when a stop-exact process snapshot fails, as kill and close already do.
- [ ] Warn when `reap_cmd` is empty on the delayed-close path.
- [ ] A test running a Codex-agent pane through `session close`.
- [ ] A test of the survivors report, for a process that survives SIGKILL.

### Test hygiene
- [ ] `tests/run-tests.sh`: the `tree_digest` helper inside the Codex hook test is now unused, because its callers use `live_tree_digest`. Remove it.

### From the 2026-09-28 eng review of plan 080 (tmux exact targets)
- [ ] Remote attach (`ssh -t "$ssh_target" "...tmux attach-session -t $sess_q"`, `cctrl` around 14716-14726): the target string runs inside a remote **zsh login shell**, where a bare `=NAME` triggers zsh's own `=command` filename expansion — `printf '%q'` quoting doesn't prevent this since the whole string is re-parsed by the remote shell. The `=` needs escaping (e.g. `\=`) in the remote command string, not just shell-quoted.
- [ ] `cctrl:10824`-ish: `pane_id` read from `baseline.json` isn't validated against `^%[0-9]+$` before use in `send-keys -t "$pane_id"`. An empty/malformed value would target the current pane instead of failing closed. Pre-existing, not introduced by plan 080.
- [ ] `test_session_kill_exact_target_no_prefix_match` (added by plan 080) only covers `session kill`. Extend the same prefix-match-collision coverage to `session close`, both the immediate path and the delayed path (grace > 0).

## Rules

Edit a copy of `cctrl` or `lib/*` and syntax-check it (`bash -n` / `perl -c`), then `mv` it into place. The live tree runs every session's hooks.
