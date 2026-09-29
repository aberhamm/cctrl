---
id: 076
title: Codex panes stop cleanly on tmux hangup
status: done
completed: 2026-09-29
blocked-by: []
priority: 76
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-27
tui-fixture: verified 2026-09-29 — live throwaway Codex session (TMUX--ms--076-codex-test), input/resize/--cctrl-initial confirmed, tmux kill-session reaped both wrapper and codex within 200ms
approved-by: matthew (C-15, via cctrl-fleet-manager)
reviews:
  - type=eng verdict=approved date=2026-09-29 by=opus-level-subagent
---

## Plain-English Summary

`lib/session-wrapper.sh` runs Codex in the foreground. The wrapper's SIGHUP trap therefore only runs after Codex exits, so plan 074's SIGTERM→SIGKILL escalation never applies to Codex. A bare `tmux kill-session` or `tmux respawn-pane -k` can leave Codex and the wrapper orphaned. That happened on 2026-09-23, and the 2026-09-27 review reproduced it.

cctrl's own kill paths (`kill`, `close`, `stop-exact`) already reap Codex panes through plan 074's reaper. This plan covers everything else.

## Requirements

- [x] Run Codex as a waited background child with the tty explicitly as stdin (`codex … <&0 &` followed by `wait`), so the trap can escalate as it does for Claude. Without job control, bash would otherwise give a background child `/dev/null` as stdin.
- [x] A live test that the Codex TUI still takes input, handles resize and still follows `--cctrl-initial` / resume.
- [x] Private-socket tests: a fake Codex that ignores HUP and TERM is gone after a bare `kill-session` and after `respawn-pane -k`.

## Eng review (2026-09-29, approved, no required fixes)

Optional follow-ups noted, none blocking:
1. A backgrounded child in a shell without job control starts with SIGINT/SIGQUIT ignored; Codex subprocesses may inherit that. Codex itself is unaffected (Ctrl-C arrives as a keystroke), and Claude already runs this way — worth a one-line comment, not a behavior change.
2. The two `codex resume` paths (restart-with-resume-flag and initial-resume) have no automated private-socket test, only the live TUI check. A resume-path case with the fake Codex would be cheap to add later.
3. `tui-fixture` here is free text where other plans use `n/a  # reason`; harmless since the fixture linter only acts on plans reading pane text, but worth conforming later for consistency.
