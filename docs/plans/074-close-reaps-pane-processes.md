---
id: 074
title: Closing a session makes sure its pane processes exit
status: in-progress
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

- [x] `lib/session-wrapper.sh` `_cleanup` escalates. It sends the agent SIGTERM, waits a bounded grace (`CCTRL_WRAPPER_TERM_GRACE`, default 10 s), then SIGKILL, so the wrapper can never block forever.
- [x] Before killing, `session kill`, `session close` (immediate and delayed) and `session stop-exact` record the pane processes: each pane pid with its process group and start time, plus every descendant.
- [x] After the kill, the pane processes are verified to exit. First SIGTERM to each recorded process group and to any recorded descendant in another group. Wait a grace period (`CCTRL_CLOSE_REAP_GRACE`, default 5 s), then SIGKILL whatever is left.
- [x] A pid is only signalled if its start time still matches what was recorded, so a reused pid is never signalled.
- [x] The command reports how many processes needed SIGKILL, or which ones could not be stopped.
- [x] A delayed close reaps from the tmux-server job that performs the kill, like the end recording (plan 070).
- [x] Tests on a private tmux socket run the real wrapper with a fake agent that ignores SIGTERM. Wrapper and agent must both be gone after `session close`, `close --now`, `session kill` and `stop-exact`, and after a plain `tmux kill-session` once the wrapper fix is in.

## Implementation notes

- **Wrapper.** `_cleanup` waits `CCTRL_WRAPPER_TERM_GRACE` (10 s) after SIGTERM, then sends SIGKILL. This also covers a plain `tmux kill-session` and `respawn-pane -k`.
- **cctrl.** `_session_pane_process_snapshot` records the pane tree (`pid@lstart`) before the kill. `_session_reap_processes` sends SIGTERM, waits `CCTRL_CLOSE_REAP_GRACE` (5 s), then sends SIGKILL, only to processes whose start time still matches.
- **Delayed close and the last session.** Killing the last session ends the tmux server, which takes its run-shell job with it. So the job first starts a detached helper, `nohup sh -c` with TERM and HUP ignored. The helper waits for the session to be gone (a missing server counts as gone), then records the end and reaps. `CCTRL_CLOSE_JOB_LOG` keeps the helper's output for diagnosis.
- **Found while testing: a silent abort under `pipefail` + `set -e`.** The reaper's `ps` lookup failed for an already-exited pid (the agent's transient child), and `pipefail` + `set -e` then made cctrl exit before reaping anything. It is now guarded.
- **Codex.** Codex runs in the foreground, because a background job would lose its stdin. So for Codex panes, cctrl's reaper is the safety net, not the wrapper.
- **Known gap.** `close --now` run from inside the session being closed. The reaper runs in the pane that dies. The wrapper's own escalation still stops the agent.

## Tasks

1. Helpers: `_session_pane_process_snapshot <target>` (pids, pgids, start times) and `_session_reap_processes <snapshot>` (TERM, wait, KILL, verify start times).
2. Wire them into kill, close (immediate and delayed) and stop-exact.
3. Tests, README, CHANGELOG.

## Not in scope

- `tmux respawn-pane -k` issued by hand. It isn't a cctrl command. A later `cctrl session restart` path can reuse the reaper.
