---
id: 074
title: Closing a session makes sure its pane processes exit
status: pending
blocked-by: []
priority: 74
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-27
tui-fixture: n/a  # tests run real tmux on a private socket and check process liveness
approved-by: matthew (chat, 2026-09-27): queued after the plan 070 re-review fixes
---

## Plain-English Summary

After `cctrl session close`, including `close --now`, the tmux session was gone but the pane's wrapper and agent kept running. On 2026-09-27 this happened five times with Claude sessions (torstra-e-225, where wrapper 60229 and claude 60278 survived; comet--2; scraper; obsidian--2; tiktok-remotion--3). Each needed a manual `kill -TERM`. The same thing happened on 2026-09-23 to Codex panes after `tmux respawn-pane -k`.

## Cause (reproduced 2026-09-27 on a private tmux socket)

- **The wrapper is the pane leader.** For a cctrl session, tmux runs `$SHELL -c 'cctrl … --foreground'`, zsh execs cctrl, and cctrl execs `lib/session-wrapper.sh`. The wrapper is therefore the pane's session leader, and the agent runs as its background child in the same process group.
- **The wrapper waits for the agent with no limit.** `tmux kill-session` closes the pty, and SIGHUP reaches the wrapper. Its trap `_cleanup` sends the agent SIGTERM, then `wait`s with no timeout.
- **The agent never exits.** Claude Code shuts down gracefully on SIGTERM, and with its tty gone that shutdown doesn't always finish. So the wrapper blocks forever and both processes are orphaned and keep running.
- **Repro:** the real `lib/session-wrapper.sh` with a fake agent that ignores SIGTERM. Three seconds after `kill-session`, wrapper 34867 (now owned by pid 1) and the agent were both still alive.
- **respawn-pane -k:** `tmux respawn-pane -k` delivers the same hangup, which explains the Codex panes on 2026-09-23.
- **Not the cause:** the session-leader shell dropping the signal. A pane whose leader exits on SIGHUP took its foreground child with it in a separate repro.

## Requirements

- [ ] `lib/session-wrapper.sh` `_cleanup` escalates. It sends the agent SIGTERM, waits a bounded grace (`CCTRL_WRAPPER_TERM_GRACE`, default 10 s), then SIGKILL, so the wrapper can never block forever.
- [ ] Before killing, `session kill`, `session close` (immediate and delayed) and `session stop-exact` record the pane processes: each pane pid with its process group and start time, plus every descendant.
- [ ] After the kill, the pane processes are verified to exit. First SIGTERM to each recorded process group and to any recorded descendant in another group. Wait a grace period (`CCTRL_CLOSE_REAP_GRACE`, default 5 s), then SIGKILL whatever is left.
- [ ] A pid is only signalled if its start time still matches what was recorded, so a reused pid is never signalled.
- [ ] The command reports how many processes needed SIGKILL, or which ones could not be stopped.
- [ ] A delayed close reaps from the tmux-server job that performs the kill, like the end recording (plan 070).
- [ ] Tests on a private tmux socket run the real wrapper with a fake agent that ignores SIGTERM. Wrapper and agent must both be gone after `session close`, `close --now`, `session kill` and `stop-exact`, and after a plain `tmux kill-session` once the wrapper fix is in.

## Tasks

1. Helpers: `_session_pane_process_snapshot <target>` (pids, pgids, start times) and `_session_reap_processes <snapshot>` (TERM, wait, KILL, verify start times).
2. Wire them into kill, close (immediate and delayed) and stop-exact.
3. Tests, README, CHANGELOG.

## Not in scope

- `tmux respawn-pane -k` issued by hand. It isn't a cctrl command. A later `cctrl session restart` path can reuse the reaper.
