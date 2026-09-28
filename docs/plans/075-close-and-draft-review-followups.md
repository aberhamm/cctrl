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

### From the 2026-09-28 eng review of plan 081 (prune pipefail + provisional close)
- [ ] `cctrl` `_task_record_close_provisional_file` (~2746-2789), wired into `_task_record_transition_file`: the provisional special case drops the caller's digest guard (`${10}`) and source/owner arguments that the generic path honors. Nothing reaches this today (`lib/conflict_resolve.py:228` only reads `task-*.json`), but it should refuse when a digest is passed rather than silently ignoring it.
- [ ] `cctrl` `_session_task_records_for_name`'s new `launch-*.json` close path (~12432-12434) has no startup grace — the launch receipt is written before `tmux new-session` runs, so a `mark-closed` landing in that window could close a session's record while it's still starting up. The snapshot/restore layer already got a 300s grace (`PROVISIONAL_STALE_GRACE_SECONDS`); this path should get an equivalent one.
- [ ] `cctrl:13389-13396` (`_session_never_prompted`): a transcript read error leaves the captured variable empty, and the Codex branch treats `grep`'s exit 2 (real error) the same as "no match" — both fail toward "never-prompted" in a classifier that feeds a destructive prune. Treat a read/grep error as "not flagged" (fail open on the destructive side), not as a positive match.
- [ ] `cctrl:13389`: loading the first 500 transcript lines into a shell variable can be several MB when transcripts carry base64 image content. Prefer a single bounded `awk` pass (`NR>500{exit 1} /pattern/{exit 0}`) that avoids both the pipe-under-pipefail hazard and the large in-memory buffer.
- [ ] Pipefail audit (plan 081) missed two sites with the same SIGPIPE-under-`set -o pipefail` shape: `cctrl:8692` (`tmux list-panes | awk '{...; exit}'`) and `cctrl:13004` (`ps -ax | awk '...; exit}'` inside the restart background subshell, where errexit could skip the kill it's meant to guard).
- [ ] Plan 081's prune cap (`max(K=5, ceil(25% × live sessions))`) is a flat 5 for any fleet of 20 or fewer live sessions, so `--yes` can still close up to 5 sessions — potentially all of a small fleet — in one call with no override. This is very likely the intended behavior (5 is a deliberately small floor), but Matthew should make the call explicitly rather than it being an implicit side effect of the K/N choice.
- [ ] `test_snapshot_excludes_stale_provisional_restore_candidates` (plan 081) only compares a 0s-old row against a 1h-old one; add a near-boundary case (e.g. ~60s vs ~301s against the 300s grace) to actually pin the threshold. Also add coverage of the real-world anchored close path (`_session_close` → `_session_record_terminated`) for a provisional-only record — today only `mark-closed --apply` is tested directly.
- [ ] `_task_record_find_by_session`'s fallback when the index file is missing: closing a provisional record rewrites the launch file, so it can become the newest record for a reused session name. Minor, but worth a look alongside the above.

## Rules

Edit a copy of `cctrl` or `lib/*` and syntax-check it (`bash -n` / `perl -c`), then `mv` it into place. The live tree runs every session's hooks.
