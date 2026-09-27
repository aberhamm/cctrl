---
id: 070
title: Harden snapshot size, closed sessions, and restore conflicts
status: done
completed: 2026-09-27
blocked-by: []
priority: 70
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-24
tui-fixture: n/a  # snapshot/restore tests use fixture catalogues, fake tmux, and temp registries
approved-by: matthew (chat, 2026-09-24): implement steps 1-5; live --apply and loading the timer need a separate OK
reviews:
  - type=eng verdict=approved date=2026-09-27 by=mstack-review
---

## Plain-English Summary

The snapshot timer is installed but unloaded. Three problems block turning it on:

1. **Size.** Each snapshot is 40 MB. Retention keeps every file for 7 days, so a 5-minute timer would write about 11.5 GB a day.
2. **Killed sessions come back.** `cctrl session kill` never records that the session ended on purpose, so restore brings back sessions Matthew closed.
3. **Live sessions show as conflicts.** Several live sessions are `[conflict]` because of stale or duplicate ownership records. The snapshot can also record the wrong conversation for a tmux session.

This plan fixes the capture, records intentional ends, stops new conflicts from forming, and adds a digest-guarded command that clears the stale ones. It then turns the timer back on in stages.

## Findings (2026-09-24, live Studio, read-only)

- **What fills the 40 MB.** `display_label` is 36.6 of 40.2 MB. It holds the Codex provider title, which is the whole first prompt, pastes included (`cctrl` task catalogue `merge` of provider rows; `lib/snapshot_restore.py` capture). 817 rows are over 10 KB and the largest is 555 KB.
- **Almost no row is restorable.** 2,863 of 2,905 rows are discovery-only Codex tasks with `unknown` ownership. The planner can never restore those. There are 18 restore candidates.
- **Every run writes a full history copy and a full `latest.json`.** `_snapshot_retention_prune` keeps everything younger than 7 days. `data/` is livesynced, so each run also copies about 80 MB to the other Mac.
- **Row selection per tmux name.** Capture keeps the first catalogue row for each tmux name (`by_tmux.setdefault`) and drops every other row with that name. For `TMUX--ms--homelab` it recorded the stale Claude conversation 12b80645. The pane actually runs e55c2cd9 (`~/.claude/sessions/95008.json`).
- **The `already-live` label.** `action_for` marks a row `already-live` when it is cctrl/tmux/active and has a tmux name, even with `live=false`.
- **Nothing records an intentional end.**
  - `_session_kill` is a raw `tmux kill-session`.
  - `_session_close` archives Codex tasks only.
  - `_session_stop_exact` kills without a lifecycle write.
  - For Claude, `closed` never arrives.

  The records stay `cctrl/tmux/active`, and the planner returns `[restore]` for mcp, mcp--2, portal and obsidian.
- **Conflict source (a), the registry merge.** When an old and a new register disagree on owner or runtime, the merge writes `conflict`. The Codex tasks were handed off to the app on Sep 20. The Sep 23 relaunch registered `cctrl/tmux`, and the merge turned app vs cctrl into `conflict`. That hit 01a0bde7, 01a0bde3, 01a0bde5-10ee and 01a0bde5-95ce.
- **Conflict source (b), the tmux join.** The catalogue marks `explicit-link-ambiguous-or-stale` when an anchor matches no live pane, or several. It marks `contradictory-explicit-link` when two records anchor the same pane.
  - homelab: 12b80645 and e55c2cd9 both anchor `%0`/94950.
  - scraper: 64f5fc95 and c0b252e0 both anchor `%1`/96614.
  - 95ce anchors `%47`/70515, and that pane is gone.
- **`reconcile-codex` can't clear them yet.** It is digest-guarded, but it keeps the conflict while the Codex App Server control socket is missing. It also reports a gone anchored pane as `ambiguous` rather than `confirmed-absence`.

## Requirements

**Acceptance criteria:**

- [x] **S1.** When several catalogue rows claim one tmux name, capture picks the one whose `provider_task_id` equals that session's live `session_id` from `session ls --json`. If there is no live id and exactly one row, it takes that row. If several rows remain and none matches, the snapshot row is marked `unknown`, reason `ambiguous-tmux-claim`, and is never restorable.
- [x] **S1.** The rows it doesn't pick are listed on the chosen row as `shadowed_task_ids`, so the evidence isn't silently dropped.
- [x] **S1.** `action_for` returns `already-live` only when `live` is true.
- [x] **S2 (slim).** `display_label` and `purpose` are capped at 200 characters. When a label is cut, a `display_label_sha256` of the full text is added.
- [x] **S2 (slim).** Rows the planner can never act on are summarised in `omitted_task_references`, as a count per provider/state. These are rows not registered or launched by cctrl, with no tmux name, and with unknown owner and runtime.
- [x] **S2 (slim).** The empty-catalogue guard counts the full catalogue (`catalogue_task_count`), not only the rows kept.
- [x] **S2 (history on change).** Each snapshot carries `content_digest`, a sha256 over only the fields restore uses. Timestamps, activity, byte counts and resource data are left out. `latest.json` is always rewritten. A history file is written only when the digest differs from the newest history file.
- [x] **S2 (retention).** On top of the age rules, history is capped by count (`CCTRL_SNAPSHOT_HISTORY_MAX`, default 200) and by bytes (`CCTRL_SNAPSHOT_HISTORY_MAX_BYTES`, default 100 MB). The newest history file and `latest.json` are never removed.
- [x] **S2 (size guard).** A capture larger than `CCTRL_SNAPSHOT_MAX_BYTES` (default 5 MB) is refused with exit 69, and the existing latest and history files are kept.
- [x] **S3.** `session kill`, `session close` and `session stop-exact` write a digest-guarded `closed` transition (source `cctrl-terminate`, authoritative). It goes to every registry record anchored to the killed pane, and is written only after the kill succeeds.
- [x] **S3.** `kill --keep-restorable` skips that write.
- [x] **S3.** The planner already treats `closed` as not restorable.
- [x] **S3.** A new `cctrl session mark-closed <tmux-name> [--apply] [--json]`, dry-run by default, closes records for a name that has no live tmux session. It exists to backfill sessions killed before this change. It refuses when a live session holds the name or the tmux inventory is incomplete.
- [x] **S4.** A cctrl relaunch of a task whose record is owned by the app no longer merges into `conflict`. The relaunch registers as a digest-guarded ownership change back to `cctrl/tmux`, recorded as `reclaim-from-app` evidence. A real simultaneous writer is still caught, as `conflict`, by the existing reconcile rule (app live and tmux live).
- [ ] ~~**S4.** When a pane's conversation changes, the anchor is removed from the other records that claim the same pane.~~ **Struck 2026-09-27 (Matthew, D5).** Two things cover it instead:
  - The leak that created shared anchors is fixed: an anchor receipt never promotes a legacy record.
  - `task resolve-conflicts` settles leftover duplicates with live evidence (`superseded-by`).

  Releasing anchors in the registry reducer would mean cross-record writes with no live evidence.
- [x] **S5.** `cctrl task resolve-conflicts [--apply] [--json]`, dry-run by default, gathers one complete tmux inventory, the process table, the Claude session files and the Codex App Server evidence, each with a cursor. For each record in conflict, or with a contradictory or stale tmux link:
  - The anchored pane is missing from a complete inventory, no process or session file claims the task, and (for Codex) the app is confirmed not live → `closed`, reason `stale-anchor`, and the tmux claim is released.
  - The pane exists but its agent runs a different conversation → `closed`, reason `superseded-by <id>`.
  - The pane runs exactly this task, and (for Codex) the app is confirmed not live → `cctrl/tmux/active`.
  - Anything else → unchanged, with the reason printed.
- [x] **S5.** Every write carries the `expected_record_digest` read with the evidence. `--apply` then collects the evidence again and writes only the actions the fresh pass decides identically for the same record digest. This replaced checking the source cursors again: the process-table cursor changes on every process start, so no write could ever pass.
- [x] **S5 (D6, Matthew 2026-09-27).** Closing a Codex record needs App Server `confirmed-absence`. `ambiguous` (the inventory answered with no live app-owner fact) is enough to hand a live pane back to cctrl, the same rule as reconcile-codex, but never enough to close.
- [x] **S5.** A record is never closed while its conversation runs anywhere. That covers any command line mentioning it and any live Claude session file with its id.
- [x] Every step has focused regression tests and passes the relevant groups before its commit. Each step is its own commit on main, with a CHANGELOG entry. Nothing is pushed.

## Tasks

1. **S1: capture row selection and the `already-live` label.** Touches `lib/snapshot_restore.py` (`capture`, `action_for`) and `tests/run-tests.sh` (snapshot group).
2. **S2: snapshot size.** Slim rows, history only on change, retention caps, size guard. Touches `lib/snapshot_restore.py`, `cctrl` (`_session_snapshot`, `_snapshot_retention_prune`), tests and README.
3. **S3: record intentional ends.** `closed` on kill, close and stop-exact, plus `session mark-closed`. Touches `cctrl`, tests, README and help text.
4. **S4: stop new conflicts.** Reclaim-from-app rule in the registry merge. Anchor receipts never promote legacy records. Anchor release was struck (D5). Touches the `cctrl` registry reducer and merge, and tests.
5. **S5: `task resolve-conflicts`.** Evidence gathering, rules, digest-guarded apply. Touches `cctrl`, a new lib helper if needed, tests and README.
6. **Operational steps.** Not code; each needs Matthew's OK in chat.
   - Backfill with `session mark-closed` for mcp, mcp--2, portal and obsidian: dry run first, then apply.
   - Start the Codex App Server, then run `resolve-conflicts` as a dry run, then apply.
   - Check that `restore --dry-run` exits 0, shows no `[restore]` for killed sessions and no `[conflict]` for live ones, and that homelab's row is e55c2cd9.
   - Load the snapshot timer at 900 s, watch it for a day (disk use, history count, stderr log, livesync), then move it to 300 s.

## Verification

- Focused groups `snapshot-ownership`, `session-stop-exact`, `task-records`, `task-record-list` and `codex-reconcile`, plus the new ones, must pass. Also the python unittests `tests/test_restore_revalidation.py` and `tests/test_tmux_snapshot.py`.
- Run the full `tests/run-tests.sh` with `LANG=en_US.UTF-8`.
- Size check on the live Studio (read-only capture into a scratch `--dir`): under 1 MB, and two runs with nothing changed produce one history file.

## NOT in scope

- Moving `data/` state to `$XDG_STATE_HOME` (see plan 071 follow-ups).
- A Claude SessionEnd hook that records `/exit`. It would be useful later, but it must filter by exit reason so a reboot's SIGTERM never counts as an intentional end.
- Keeping `data/snapshots/` out of livesync. That is an operational choice for Matthew.

## Implementation Notes

Commits on main (not pushed):
- `27fb1db`: test harness ignores the statusline rate-limit files in the live-store guards
- `4fd3ac7`: S1
- `c9216ea`: S2
- `cccb5e8`: S3
- `1a0f922`: S4
- `015cfc3`: S5

The full suite passes at `015cfc3`: 145 shell checks and 93 Python tests.

Operational steps, 2026-09-25 (Matthew approved in chat):
- **Backfill:** `session mark-closed --apply` closed mcp (6bbb07ed), mcp--2 (c8133901), and portal (83eff643). obsidian was live again (56474c30), so it was refused as expected.
- **Resolve:** `task resolve-conflicts --apply` closed homelab 12b80645 (superseded by e55c2cd9), scraper 64f5fc95 (superseded by c0b252e0), and obsidian 5e25447b (stale anchor). All three were digest-guarded and all applied.
- **Restore dry run:**
  - 0 `[restore]` rows.
  - Killed sessions are no longer offered.
  - homelab and scraper are `[already-live]`.
  - 3 `[conflict]` rows remain, all live Codex tasks: cctrl, homelab--2, rentkompass.
- **Timer:** loaded at StartInterval 900, then moved to 300 on 2026-09-25 at Matthew's request. By 2026-09-27 it had run 626 times, the last exit was 0, and each capture was about 120–160 KB.

Still open:
- The 3 live Codex conflicts, plus 95ce and the other Codex rows, need the Codex App Server: its control socket is missing. Open the Codex desktop app, then run `cctrl task resolve-conflicts` (dry run) and `--apply`.
- Watch the timer for a day, then move it to 300 s.
- The focused `CCTRL_TEST_ONLY=codex-ownership-matrix` group already failed at 4f353cb. The full suite runs the same contract and passes.

## Review Follow-up (2026-09-27)

Fixes for the 2026-09-25 eng review (`changes-requested`), each a separate commit on main:

| Finding | Commit | What changed |
|---|---|---|
| Follow-up [P2, critical gap], D7 | `08fd052` | A capture with no live session never replaces a `latest.json` that had live sessions (post-reboot guard); `--allow-empty` overrides. |
| D6 | `cb67013` | Closing a Codex record needs App Server `confirmed-absence`. |
| P1 | `d639f46` | For a tmux name that is not live, an ended record never hides the open one, and several open claims are `ambiguous-tmux-claim`. |
| P2 (S3 kill result) | `76a132b` | kill and close record `closed` only after the kill succeeds. A delayed close records via a detached waiter once the exact session id is gone. |
| P3 (unanchored sessions) | `76a132b` | Unanchored leftovers get a `mark-closed` hint. |
| P2 (S5 session files) | `fd836eb` | No close while a command line or a live Claude session file shows the task. |
| P3 (retention) | `dfe3450` | Age retention never prunes the newest history file. |
| P2 (S4 anchor release) | — | Struck with a reason (D5). |
| P3 (cursor re-check) | — | The requirement text now describes the re-decide-and-compare-digest apply. |

## Decision: restore does not trust an `ambiguous` App Server answer (Matthew, 2026-09-27)

**What.** The restore planner (`lib/snapshot_restore.py`, `reconcile_record`) accepts only `claimed` or `confirmed-absence` from the Codex App Server. `ambiguous` means the inventory answered but holds no live app-owner fact. For restore that counts as missing evidence: the row is `insufficient-evidence`, not `restore`, and the dry run exits 69.

**Why.** Restore *starts* a terminal writer. If the app might still be writing the thread, a second writer could corrupt the conversation. Only `confirmed-absence` proves the app isn't running it. Other paths deliberately accept `ambiguous`, but only for a pane that is already live:
- `reconcile-codex` accepts it.
- `task resolve-conflicts`' `live-owner` rule accepts it (D6).

In both cases the terminal is already the writer, so nothing new is spawned.

**Known cost.** Live cctrl Codex tasks for which the App Server answers `ambiguous` are not restored automatically after a reboot. On 2026-09-27 that was cctrl, rentkompass and homelab--2. Restore lists them as `insufficient-evidence`; bring them back by hand with `cctrl start -d <dir> --agent codex -r <thread-id>`.

**Revisit** if the App Server gains an explicit "not loaded or owned" answer, or if Matthew accepts the risk.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 2 | CLEAR | Re-review: 9 prior findings closed, 0 critical gaps, 4 new P3 follow-ups |
| Outside voice | Claude subagent (Codex out of credits) | Independent 2nd opinion | 1 | issues_found | 2026-09-25 run; its confirmed findings are in the table below |

Re-reviewed on 2026-09-27 at afa62bd. Checked the fix commits 08fd052, cb67013, d639f46, 76a132b, fd836eb, dfe3450 and afa62bd with `git show` and the current code. D5, D6 and D7 are Matthew's decisions and were not reopened. These focused groups pass with `LANG=en_US.UTF-8`: `snapshot-ownership`, `session-stop-exact`, `task-records` and `health-check`. So does `python3 -m unittest tests.test_conflict_resolve tests.test_restore_revalidation tests.test_tmux_snapshot` (18 tests). `bash -n cctrl` is clean, and shellcheck reports 19 warnings both at 4232663 and now, so the fixes add none. The full suite is run separately. `codex-ownership-matrix` already failed on its own at 4f353cb, before these fixes.

Status of the 2026-09-25 findings:
- **[P1] S1, tmux names that are not live: fixed** (d639f46, `lib/snapshot_restore.py:283-344`). Ended records (`closed`/`archived`/`released`) no longer claim a name. When several open records claim a name, the row is `unknown` with the reason `ambiguous-tmux-claim` and lists `shadowed_task_ids`. Catalogue order no longer decides anything. Every row with a tmux name is actionable, so the omitted-rows path can't drop the evidence. Tested in `test_snapshot_tmux_row_selection`.
- **[P2] S3, kill result: fixed** (76a132b). kill and close return 1 and write nothing when `tmux kill-session` fails. stop-exact already gated its write on the guarded kill. A delayed close records from a detached `nohup` waiter only once the exact `$N` session id is gone, giving up after grace plus 30 s. Tested with a failing kill and a 2 s delayed close.
- **[P2] S4, anchor release: struck** with a reason (D5, afa62bd).
- **[P2] S5, session files: fixed** (fd836eb). Both close paths (`stale-anchor` and `superseded-by`) skip a task when a command line or a live Claude session file shows it. Tested with the `/resume` fixture.
- **[P2] S5 / 291c3ea, `ambiguous` App Server evidence: fixed per D6** (cb67013). Closing needs `confirmed-absence`. `ambiguous` is still enough for `own`. The unittest covers `confirmed-absence`, `ambiguous` and `unavailable`.
- **[P2, critical gap] reboot capture replacing `latest.json`: fixed per D7** (08fd052, `cctrl:11523-11540`). A capture with no live session goes to history only, and `--allow-empty` overrides. If jq fails, the count reads as 0, so the guard errs toward keeping the old `latest.json`.
- **[P3] age retention: fixed** (dfe3450).
- **[P3] unanchored sessions: fixed** (76a132b). A kill or close that finds no anchored record now prints a `mark-closed` hint.
- **[P3] cursor re-check wording: fixed** (afa62bd).

Tests: every fix commit adds a focused regression test and a CHANGELOG entry. Performance: nothing to worry about. The fixes add one `jq` count over a `latest.json` of about 110 KB per capture, one cached read of each live Claude session file per resolve pass, and one 1 Hz waiter that only runs during a delayed close.

Follow-ups (P3, not blocking; none of them is a regression that closes or loses a live conversation):
- **Delayed-close waiter while a Claude pane closes itself** (`cctrl:12249-12256`). The waiter is `nohup` plus `&` from the caller's process group. When `session close <self> --in N` runs from a Claude Code Bash tool, the harness may kill that group when the pane dies, and the only test closes from outside the pane. If the waiter dies, the record stays active: restore offers the session again, and `mark-closed` fixes it. To make it robust, append the record step to the `tmux run-shell -b` command so it runs on the tmux server. Also, if `close_session_id` is empty (`cctrl:12610`), nothing is recorded and no warning is printed.
- **Session-file check fails open** (`lib/conflict_resolve.py:118-138`). A live `claude` process whose `sessions/<pid>.json` can't be read, or a Claude run through `node`, which `agent_of` misses, counts as not running the task. A stricter version would skip Claude closes whenever a live Claude process has no readable session file.
- **Next to D7, not reopening it** (`lib/snapshot_restore.py:327`). If one session is live before restore runs (for example the new fleet manager), a timer capture can still replace `latest.json`. Its non-live rows then carry `launch_flags:{}`. The history file keeps the good capture. Filling non-live rows with `launch_flags_for(metadata_dir, name)` would remove the cause.
- **Conservative ambiguity** (`lib/snapshot_restore.py:285-288`). An app-owned open record that still holds a dead tmux name makes a cctrl record with the same name ambiguous, so restore won't offer it. This errs toward safety.

VERDICT: ENG CLEARED. All P1 and P2 findings are fixed or resolved by Matthew's decisions (D5, D6, D7). Plan 070 is done. The operational follow-ups under Implementation Notes (the Codex App Server conflicts, and moving the timer to 300 s) still need Matthew's OK in chat.

NO UNRESOLVED DECISIONS
