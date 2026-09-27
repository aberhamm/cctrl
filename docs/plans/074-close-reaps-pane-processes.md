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
reviews:
  - type=eng verdict=changes-requested date=2026-09-27 by=mstack-review
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
- [x] Before killing, `session kill`, `session close` (immediate and delayed) and `session stop-exact` record the pane processes: each pane pid with its process group and start time, plus every descendant.
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
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | issues_open | 14 issues (5 P2, 9 P3), 0 critical gaps |
| Outside voice | Claude subagent | Independent 2nd opinion | 1 | issues_found | 2 new P2s confirmed, 3 new P3s folded in |

Reviewed on 2026-09-27: plan 074 and commit 2ac152b (`lib/session-wrapper.sh:50-69`, `cctrl:12185-12385`, and the wiring at `cctrl:12164/12176`, `12495/12502` and `12741-12790`). These pass with `LANG=en_US.UTF-8`: `CCTRL_TEST_ONLY=pane-draft`, `session-stop-exact` (which includes `test_session_close_reaps_pane_processes`), `health-check` and `snapshot-ownership`, plus the Python unittests (97). No test processes were left behind afterwards.

Checked and correct. Each was reproduced on a private tmux socket or by sourcing cctrl with `CCTRL_NO_MAIN=1`:
- The pid-reuse guard: a live process recorded with the wrong start time is left alone, and with the right start time it is TERMed.
- The Claude wrapper: after hangup it exits 0.25 s after an agent that honours TERM. `kill -0` doesn't stall on a zombie, because bash reaps the child in its SIGCHLD handler.
- The `pipefail` + `set -e` fix in `_reap_alive` (`cur=… || true`, `return 0`).
- Empty arrays under bash 3.2 `set -u`, which are guarded.
- The quoting of the `run-shell` / `nohup sh -c` helper, which the delayed close of the last session exercises end to end.
- The test's EXIT cleanup (`kill-server` plus `pkill -f "$root"`).

Findings:
- **[P2] (9/10) `cctrl:12495`, `12741`, `12164`: a failed snapshot silently cancels the kill.** Verified. `procs="$(_session_pane_process_snapshot "$session_id")"` is a plain assignment under `set -euo pipefail`. If `ps` or `python3` fails, cctrl exits 1 with no message before `tmux kill-session`. With a `python3` shim that exits 1, `session kill victim` returned 1 silently and the session stayed alive. `stop-exact` also loses its `--json` stdout contract. **Fix:** make the snapshot best-effort, e.g. `procs="$(…)" || { echo "⚠ could not record pane processes; killing without reaping" >&2; procs=""; }` at all three sites. Add a test with a failing `python3` shim: the kill still happens and a warning is printed.
- **[P2] (9/10) `lib/session-wrapper.sh:81,91,94`, and this plan's note "This also covers a plain tmux kill-session and respawn-pane -k": this is not true for Codex.** Verified. Codex runs in the foreground, so bash holds the trap until `codex` exits, and `_child_pid` is never set. A fake codex that ignores HUP/TERM, with its wrapper, was still alive 3 s after a plain `tmux kill-session`. So the 2026-09-23 Codex orphans after `respawn-pane -k`, which the plan cites as explained, are not fixed. Only cctrl's reaper covers Codex. The CHANGELOG and README line claiming the wrapper escalation is just as broad. **Fix (D2):** say "Claude panes only" in the plan note, the CHANGELOG and the README, and file a follow-up plan to run Codex as a waited background child with the tty as stdin (`codex … <&0 & _child_pid=$!; wait`), tested on a live Codex pane.
- **[P2] (8/10) `tests/run-tests.sh` `test_session_close_reaps_pane_processes`: the safety requirements are untested.** Nothing tests that a pid with a different start time is never signalled, even though it is this plan's main safety property. There is no Codex-agent pane through `session close`, no test of a failed snapshot, and no test of the survivors report. **Fix:** add a unit test with `CCTRL_NO_MAIN=1`. Start a process that traps TERM and writes to a file, call `_session_reap_processes "$pid@Mon_Jan_1_00:00:00_2001"`, then assert it is still alive and never got TERM. Add a `codex` variant of `launch` (the wrapper with the `codex` agent and `--cctrl-initial`) for `session close`.
- **[P3] (9/10) `cctrl:12198,12235`: `lstart` depends on locale and TZ.** Verified: under `de_DE` it prints `So. 27 Sep. …`. The delayed reap runs in the tmux server's environment and forwards only `PATH` and `CCTRL_CLOSE_REAP_GRACE`. If the locale or TZ differs, nothing matches and nothing is reaped, with no message. **Fix:** use `LC_ALL=C TZ=UTC0 ps …` in both places.
- **[P3] (9/10) `cctrl:12228-12248`: the grace counts ticks, not seconds.** Each 100 ms tick forks one `ps` and one `awk` per pid. Live pane trees on the Studio have 24-41 processes (counted read-only). With 30 pids that ignore TERM and a 2 s grace, the reap took 4.4 s (measured), so the default 5 s is about 11 s per close. **Fix:** one `ps -o pid=,lstart= -p <csv>` per tick, and a wall-clock deadline (`SECONDS`).
- **[P3] (8/10) `cctrl:12191-12216`: run from inside the pane being killed, the snapshot includes the calling cctrl and its ancestors.** So the reaper TERMs itself. This is the plan's known gap, and it also applies to `session kill <self>`. **Fix:** remove `$$` and its parent chain from the snapshot, and state the known gap for `kill` as well.
- **[P3] (7/10) `cctrl:12741` vs `12766`: a delayed close takes its snapshot N seconds before the kill.** Children started in that window are not reaped. **Fix:** take the snapshot in the `run-shell` job just before `kill-session`, or document it.
- **[P3] (9/10) `lib/session-wrapper.sh:59`: a malformed grace value kills the wrapper.** Verified: a non-numeric `CCTRL_WRAPPER_TERM_GRACE` (`5s`) is an arithmetic expansion error, and the wrapper exits inside its trap before it signals the agent. **Fix:** check it against `^[0-9]+$` and fall back to 10, as the reaper does.
- **[P3] (8/10) The plan text says something different from the code.** The Requirements say each pane pid is recorded "with its process group" and that SIGTERM goes "to each recorded process group". The code records `pid@lstart` and signals single pids. The code's choice is safer, because a group can't be checked by start time. **Fix:** update the Requirements text.
- **[P3] (7/10) The reaper's grace is shorter than the wrapper's.** `CCTRL_CLOSE_REAP_GRACE` (5 s) is less than `CCTRL_WRAPPER_TERM_GRACE` (10 s), so through cctrl, Claude gets 5 s to shut down, not 10. **Fix:** document this, or align the two.
- **[P2] (outside voice, confirmed 8/10) `cctrl:13474`: one stubborn session stops `session prune --yes`.** `_session_close "${cand_names[i]}"` runs under `set -e`, and close now returns 1 when a process survives the reap (`_session_reap_processes "$close_procs" "$target" || return 1`). So the first such session aborts prune, and the rest are never closed. **Fix:** in close and kill, report survivors as a warning (return 0, as stop-exact does with `|| true`), or have the prune loop count failures (`|| failed=$((failed+1))`).
- **[P2] (outside voice, 6/10, medium confidence: check whether this is real) `cctrl:12222`: Claude's shutdown is cut off at 5 s.** The reaper TERMs Claude right away and KILLs it at `CCTRL_CLOSE_REAP_GRACE` (5 s). Before, shutdown had no limit, and the wrapper now allows 10 s. SessionEnd hooks and the transcript flush can be cut off. This supersedes the grace P3 above. **Fix:** first wait, without signalling, for the snapshot to exit for at least the wrapper's grace plus 2 s. Then TERM, then KILL.
- **[P3] (outside voice, 5/10) `cctrl:12741` vs `12786`: close uses two kinds of target.** The snapshot, anchors and session id use the exact target `=$target`, but `has-session` / `kill-session -t "$target"` use a prefix match. Also, a dropped `reap_cmd` on the delayed path prints no warning. **Fix:** resolve the session id once and use it for every tmux call, and warn when `reap_cmd` is empty.
- **[P3] (outside voice, 5/10) `cctrl:12228-12240`: stopped processes and zombies.** A stopped process (ctrl-z) waits out the whole grace. A zombie counts as alive and inflates the "ignored SIGTERM" count. **Fix:** send `kill -CONT` after TERM, and read `stat=`, treating `Z` as gone.
- **[P3] (outside voice, 5/10) `lib/session-wrapper.sh:63`: the wrapper's SIGKILL leaves the agent's children behind.** It KILLs only the agent. Its MCP and tool children are orphaned when cctrl's reaper doesn't run (a plain `kill-session`, `kill-server`). **Fix:** KILL the agent's descendants too (`pgrep -P`, recursively).

Performance: see the tick finding above. Otherwise it adds one `ps -axo` and one `python3` per kill, which is fine.

VERDICT: ENG NOT CLEARED: changes requested (3 P2). Required before approval: best-effort snapshots, the Codex scope made accurate (D2) with a follow-up plan, the pid-reuse and Codex tests, survivors reported as a warning so prune continues, and either a shutdown window no shorter than the wrapper grace or a documented reason for 5 s (D3). eng review required

NO UNRESOLVED DECISIONS
