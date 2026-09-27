---
id: 076
title: Codex panes stop cleanly on tmux hangup
status: pending
blocked-by: []
priority: 76
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-27
tui-fixture: required  # needs a live Codex TUI check that input still works
approved-by: none  # filed by the fleet manager's scope call (scope-fm0927)
---

## Plain-English Summary

`lib/session-wrapper.sh` runs Codex in the foreground. The wrapper's SIGHUP trap therefore only runs after Codex exits, so plan 074's SIGTERM→SIGKILL escalation never applies to Codex. A bare `tmux kill-session` or `tmux respawn-pane -k` can leave Codex and the wrapper orphaned. That happened on 2026-09-23, and the 2026-09-27 review reproduced it.

cctrl's own kill paths (`kill`, `close`, `stop-exact`) already reap Codex panes through plan 074's reaper. This plan covers everything else.

## Requirements

- [ ] Run Codex as a waited background child with the tty explicitly as stdin (`codex … <&0 &` followed by `wait`), so the trap can escalate as it does for Claude. Without job control, bash would otherwise give a background child `/dev/null` as stdin.
- [ ] A live test that the Codex TUI still takes input, handles resize and still follows `--cctrl-initial` / resume.
- [ ] Private-socket tests: a fake Codex that ignores HUP and TERM is gone after a bare `kill-session` and after `respawn-pane -k`.
