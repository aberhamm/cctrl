---
id: 087
title: Close reaper follow-ups (074 re-review)
status: done
completed: 2026-09-29
blocked-by: []
priority: 87
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-28
tui-fixture: n/a
approved-by: matthew (C-15, via cctrl-fleet-manager)
reviews:
  - type=eng verdict=approved date=2026-09-29 by=opus-level-subagent
---

## Plain-English Summary

Split from plan 075. P3 findings from the 2026-09-27 eng review of plan
074 (close reaps pane processes), plus items from the follow-up
re-review, that weren't fixed when the P2 fixes shipped. Also folds in
one unrelated test-hygiene cleanup in the same test file.

## Requirements

- [x] Performance: one batched `ps -axo pid=,stat=,lstart=` per tick
      instead of `ps` + `awk` per pid, and a wall-clock deadline instead of
      counting ticks. Measured: 30 processes with a 2s grace took 4.4s.
- [x] Send SIGCONT after SIGTERM so a stopped process can act on it. Count
      zombies (`Z`) as gone.
- [x] Exclude the calling cctrl process and its ancestors from the
      snapshot. `close --now` or `kill` run from inside the pane being
      killed must not kill the reaper itself.
- [x] Delayed close: take the snapshot inside the tmux-server job, right
      before the kill, so children started during the grace are included.
- [x] Resolve the tmux session id once and use it everywhere in `session
      close`. Today the kill uses a prefix match while the snapshot uses
      the exact `=name`.
- [x] The wrapper's SIGKILL also kills the agent's descendants (MCP
      servers, tool processes).
- [x] `lib/session-wrapper.sh`: validate `CCTRL_WRAPPER_TERM_GRACE`
      against `^[0-9]+$` and fall back to 10. Today a value like `5s` exits
      inside the trap before the agent is signalled.
- [x] Warn when a stop-exact process snapshot fails, as kill and close
      already do.
- [x] Warn when `reap_cmd` is empty on the delayed-close path.
- [x] A test running a Codex-agent pane through `session close`.
- [x] A test of the survivors report, for a process that survives SIGKILL.
- [x] `tests/run-tests.sh`: the `tree_digest` helper inside the Codex hook
      test is now unused, because its callers use `live_tree_digest`.
      Remove it.

## Rules

Edit a copy of `cctrl` or `lib/*` and syntax-check it (`bash -n` / `perl
-c`), then `mv` it into place. The live tree runs every session's hooks.

Use exact tmux targets (`-t '=NAME'` / `'=NAME:'`) anywhere this plan
touches session-close code or tests. Test with the existing fake-tmux
harness only — never exercise close/kill against live fleet sessions.

## Eng review

Opus-level subagent review, 2026-09-29: verdict "needs one small fix, then
clear to ship" — the three bugs I'd already found and fixed via my own
manual real-tmux testing (missing `PATH` forwarding to the new `session
pane-snapshot` subcommand; an `IFS` leak inside `_reap_scan` that silently
broke `read -a`'s space-splitting; unguarded `"${alive[@]}"`/`"${stopped[@]}"`
expansions crashing on this host's bash 3.2 for a zero-element array) were
confirmed correct and complete, not re-flagged. One REQUIRED finding, fixed:
`_session_close` resolved `close_session_id` but still took `close_anchors`
and the up-front `close_procs` snapshot against the bare `"=$target"` name
instead of the resolved `close_kill_target` — a same-name replacement
session created between resolving the id and taking the snapshot could have
had its anchors/processes captured under the old target's identity. Fixed:
resolve `close_kill_target` first, then pass it to both
`_session_pane_anchors` and `_session_pane_process_snapshot`.

Two OPTIONAL findings addressed as cheap wins while in the area (not
required, folded in anyway):
- `CCTRL_WRAPPER_TERM_GRACE=08` (or any leading-zero grace) passed the
  `^[0-9]+$` regex but isn't valid octal, so `$(( _grace * 10 ))` still blew
  up — same failure class the requirement was fixing. Fixed in both
  `session-wrapper.sh`'s `_cleanup` and `cctrl`'s `_session_reap_processes`
  with `_grace=$((10#$_grace))` after the regex check.
- The delayed-close live snapshot (`cctrl session pane-snapshot`, run inside
  the tmux-server job right before the kill) had no fallback if it failed —
  `__cctrl_procs` would end up empty and the reap would silently do nothing,
  regressing below the pre-087 guarantee. Fixed: `_session_reap_shell_template`
  now unions the live snapshot with the up-front `close_procs` snapshot
  (`--snapshot "$1,<up-front tokens>"`); a stale/dead token from either side
  is harmless since matching is by pid AND start time.

Remaining OPTIONAL findings, not filed as their own plans:
- The wall-clock reap deadline has ~1s granularity (`grace-1` to `grace`
  seconds effective), not exactly `grace`. Never observed to matter in
  practice (default grace of 12s vs. the wrapper's own 10s window).
- The pane snapshot still records the caller's own short-lived `ps`/
  `python3` helper processes (only the ancestor *chain* is excluded, not a
  "stop descending into the caller's own pid" rule) — harmless since they've
  already exited by reap time, but not maximally precise.
- No dedicated unit tests yet for: caller/ancestor exclusion, SIGCONT/zombie
  handling in isolation, or a malformed `CCTRL_WRAPPER_TERM_GRACE`. Covered
  indirectly today (manual testing during implementation, and the existing
  reap/close integration tests), but not pinned as regression tests.
- `lib/session-wrapper.sh` has a PRE-EXISTING (not introduced by this plan)
  latent bug: several `${_flags[*]}`/`"${_flags[@]}"` usages will crash under
  `set -u` on this host's bash 3.2 if `_flags` is ever empty (e.g. an agent
  launched with zero extra CLI flags, or a Claude pane restarted in place
  after `--resume <id>` was its only original flag). Not triggered in normal
  cctrl usage today (cctrl always passes at least one flag), and out of
  scope for this plan's checklist — noted here rather than fixed, and my new
  Codex-agent-pane test deliberately passes a non-empty flag set to avoid
  tripping it. Worth a dedicated plan if it's ever hit in practice.
- The wrapper's new descendant-kill-on-SIGKILL (checklist item 6) only
  takes effect for Claude panes: Codex still runs in the wrapper's
  foreground (plan 076, not yet done), so `_child_pid` is never set for a
  Codex pane and `_cleanup` is a no-op for it. Codex panes are still fully
  covered by cctrl's own outside-in snapshot reap — the new Codex-agent test
  exercises exactly that path — but the wrapper-level descendant kill itself
  will only start applying to Codex once plan 076 lands.
