---
id: 074
title: Closing a session makes sure its pane processes exit
status: done
completed: 2026-09-27
blocked-by: []
priority: 74
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-27
tui-fixture: n/a  # tests run real tmux on a private socket and check process liveness
approved-by: matthew (chat, 2026-09-27): queued after the plan 070 re-review fixes
reviews:
  - type=eng verdict=approved date=2026-09-27 by=mstack-review
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

- [x] (Claude panes only; Codex runs in the foreground, see follow-up plan 076) `lib/session-wrapper.sh` `_cleanup` escalates. It sends the agent SIGTERM, waits a bounded grace (`CCTRL_WRAPPER_TERM_GRACE`, default 10 s), then SIGKILL, so the wrapper can never block forever.
- [x] Before killing, `session kill`, `session close` (immediate and delayed) and `session stop-exact` record the pane processes: each pane pid and every descendant, with its start time (`pid@lstart`).
- [x] After the kill, the pane processes are verified to exit. SIGTERM goes to each recorded pid; individual pids, not process groups, which is safer. Wait a grace period (`CCTRL_CLOSE_REAP_GRACE`, default 12 s, longer than the wrapper's 10 s), then SIGKILL whatever is left.
- [x] A pid is only signalled if its start time still matches what was recorded, so a reused pid is never signalled.
- [x] The command reports how many processes needed SIGKILL, or which ones could not be stopped.
- [x] A delayed close reaps from the tmux-server job that performs the kill, like the end recording (plan 070).
- [x] Tests on a private tmux socket run the real wrapper with a fake agent that ignores SIGTERM. Wrapper and agent must both be gone after `session close`, `close --now`, `session kill` and `stop-exact`, and after a plain `tmux kill-session` once the wrapper fix is in.

## Implementation notes

- **Wrapper, Claude panes only.** `_cleanup` waits `CCTRL_WRAPPER_TERM_GRACE` (10 s) after SIGTERM, then sends SIGKILL. For Claude this also covers a plain `tmux kill-session` and `respawn-pane -k`. Codex runs in the foreground, so its trap never fires; the Sep 23 Codex orphans stay open until follow-up plan 076.
- **cctrl.** `_session_pane_process_snapshot` records the pane tree (`pid@lstart`, with `LC_ALL=C TZ=UTC0`) before the kill; if that fails, the kill proceeds with a warning. `_session_reap_processes` sends SIGTERM, waits `CCTRL_CLOSE_REAP_GRACE` (12 s), then sends SIGKILL, only to processes whose start time still matches. Survivors are reported as a warning, not an error.
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

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 2 | clean | Run 2: all required P2s fixed; 1 new P3, 0 critical gaps |

Re-review on 2026-09-27 of fix commit 4eb5707 against the run-1 findings (commit 2ac152b), scoped by the fleet manager's call scope-fm0927. These pass with `LANG=en_US.UTF-8`: `CCTRL_TEST_ONLY=session-stop-exact` (which includes `test_session_close_reaps_pane_processes`, 30 s), `pane-draft` and `health-check`, plus the Python unittests (97). No test processes were left behind.

Required items:
- **[P2] Best-effort snapshot at all 3 kill sites: fixed.** stop-exact at `cctrl:12173` (`|| stop_procs=""`; silent, which keeps the `--json` stdout contract), kill at `cctrl:12508-12511` and close at `cctrl:12757-12760` (a warning, then `procs=""`). The failing `python3` shim test is at `tests/run-tests.sh:4498-4507`: the kill proceeds, the warning is printed and the wrapper still escalates.
- **[P2] "Claude panes only" wording: fixed.** In the plan (Requirements line 1, Implementation notes "Wrapper, Claude panes only"), CHANGELOG ("stops a Claude agent … Codex … isn't covered by the wrapper (follow-up plan 076)") and README:478-483. Codex is filed as 076.
- **[P2] pid-reuse safety test: added.** `tests/run-tests.sh:4485-4497`: a live process with a wrong start time survives `_session_reap_processes`, and with the right start time it is stopped.
- **[P2] Survivors non-fatal (prune --yes abort): fixed.** Kill `cctrl:12518`, and close `cctrl:12794` and `:12809`, now use `|| true`, matching stop-exact at `:12185`. `session prune --yes` no longer stops at the first stubborn session. There is no dedicated test of the survivors report; that was not required.
- **[P2] Shutdown window: fixed.** `CCTRL_CLOSE_REAP_GRACE` defaults to 12 s (`cctrl:12237-12239`), above the wrapper's 10 s. The delayed helper forwards the variable (`cctrl:12392`), and the README and CHANGELOG say 12.
- **[P3] `LC_ALL=C TZ=UTC0` for lstart: fixed** at both the snapshot (`cctrl:12209`) and the liveness check (`cctrl:12248`), so the delayed tmux-server job matches regardless of its environment.
- Plan text: the "process group" wording is corrected in Requirements 2 and 3 (pids with start times, `pid@lstart`), to match the code.

`set -e` / `pipefail` audit of the new bash:
- The three `snapshot || {…}` sites disable errexit for the pipeline, so a `ps` or `python3` failure is caught.
- `$(LC_ALL=C TZ=UTC0 ps … | awk … || true)` in `_reap_alive` is still guarded.
- The `|| true` on the reaper calls cannot abort.
- No new unguarded command substitution.

Deferred items are filed: 075 (tick performance and wall-clock deadline, SIGCONT and zombies, self-exclusion, snapshot inside the delayed job, one session id, wrapper killing descendants, validating the wrapper grace) and 076 (Codex foreground wrapper). These run-1 items are not in 075 and should be added there:
- the warning when `reap_cmd` is empty on the delayed path (`cctrl:12778`);
- a Codex-agent pane through `session close`;
- a survivors-report test.

New finding (P3, not blocking):
- **[P3] (6/10) `cctrl:12173`: a failed stop-exact snapshot prints no warning,** unlike kill and close. A stderr warning would not break the `--json` stdout contract. **Fix:** add the same warning, sent to stderr.

Performance note: with the 12 s default, a stubborn pane holds a synchronous `close` or `kill` for about 12 s plus the per-tick `ps` overhead (075's batching item). That is acceptable for a rare stubborn agent.

VERDICT: ENG CLEARED. All five required P2s and the scoped lstart P3 are verified, with no regressions in the new bash. The remaining work is filed in 075 and 076.

NO UNRESOLVED DECISIONS
