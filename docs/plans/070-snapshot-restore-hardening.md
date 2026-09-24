---
id: 070
title: Harden snapshot size, closed sessions, and restore conflicts
status: in-progress
blocked-by: []
priority: 70
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-24
tui-fixture: n/a  # snapshot/restore tests use fixture catalogues, fake tmux, and temp registries
approved-by: matthew (chat, 2026-09-24): implement steps 1-5; live --apply and loading the timer need a separate OK
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

- [ ] **S1.** When several catalogue rows claim one tmux name, capture picks the one whose `provider_task_id` equals that session's live `session_id` from `session ls --json`. If there is no live id and exactly one row, it takes that row. If several rows remain and none matches, the snapshot row is marked `unknown`, reason `ambiguous-tmux-claim`, and is never restorable.
- [ ] **S1.** The rows it doesn't pick are listed on the chosen row as `shadowed_task_ids`, so the evidence isn't silently dropped.
- [ ] **S1.** `action_for` returns `already-live` only when `live` is true.
- [ ] **S2 (slim).** `display_label` and `purpose` are capped at 200 characters. When a label is cut, a `display_label_sha256` of the full text is added.
- [ ] **S2 (slim).** Rows the planner can never act on are summarised in `omitted_task_references`, as a count per provider/state. These are rows not registered or launched by cctrl, with no tmux name, and with unknown owner and runtime.
- [ ] **S2 (slim).** The empty-catalogue guard counts the full catalogue (`catalogue_task_count`), not only the rows kept.
- [ ] **S2 (history on change).** Each snapshot carries `content_digest`, a sha256 over only the fields restore uses. Timestamps, activity, byte counts and resource data are left out. `latest.json` is always rewritten. A history file is written only when the digest differs from the newest history file.
- [ ] **S2 (retention).** On top of the age rules, history is capped by count (`CCTRL_SNAPSHOT_HISTORY_MAX`, default 200) and by bytes (`CCTRL_SNAPSHOT_HISTORY_MAX_BYTES`, default 100 MB). The newest history file and `latest.json` are never removed.
- [ ] **S2 (size guard).** A capture larger than `CCTRL_SNAPSHOT_MAX_BYTES` (default 5 MB) is refused with exit 69, and the existing latest and history files are kept.
- [ ] **S3.** `session kill`, `session close` and `session stop-exact` write a digest-guarded `closed` transition (source `cctrl-terminate`, authoritative). It goes to every registry record anchored to the killed pane, and is written only after the kill succeeds.
- [ ] **S3.** `kill --keep-restorable` skips that write.
- [ ] **S3.** The planner already treats `closed` as not restorable.
- [ ] **S3.** A new `cctrl session mark-closed <tmux-name> [--apply] [--json]`, dry-run by default, closes records for a name that has no live tmux session. It exists to backfill sessions killed before this change. It refuses when a live session holds the name or the tmux inventory is incomplete.
- [ ] **S4.** A cctrl relaunch of a task whose record is owned by the app no longer merges into `conflict`. The relaunch registers as a digest-guarded ownership change back to `cctrl/tmux`, recorded as `reclaim-from-app` evidence. A real simultaneous writer is still caught, as `conflict`, by the existing reconcile rule (app live and tmux live).
- [ ] **S4.** When a pane's conversation changes, the anchor is removed from the other records that claim the same pane. A pane changes conversation when it is resumed or relaunched with a different id.
- [ ] **S5.** `cctrl task resolve-conflicts [--apply] [--json]`, dry-run by default, gathers one complete tmux inventory, the process table, the Claude session files and the Codex App Server evidence, each with a cursor. For each record in conflict, or with a contradictory or stale tmux link:
  - The anchored pane is missing from a complete inventory, no process or session file claims the task, and (for Codex) the app is confirmed not live → `closed`, reason `stale-anchor`, and the tmux claim is released.
  - The pane exists but its agent runs a different conversation → `closed`, reason `superseded-by <id>`.
  - The pane runs exactly this task, and (for Codex) the app is confirmed not live → `cctrl/tmux/active`.
  - Anything else → unchanged, with the reason printed.
- [ ] **S5.** Every write carries the `expected_record_digest` read with the evidence. Before writing, the command checks the source cursors again and rejects the change if they moved.
- [ ] Every step has focused regression tests and passes the relevant groups before its commit. Each step is its own commit on main, with a CHANGELOG entry. Nothing is pushed.

## Tasks

1. **S1: capture row selection and the `already-live` label.** Touches `lib/snapshot_restore.py` (`capture`, `action_for`) and `tests/run-tests.sh` (snapshot group).
2. **S2: snapshot size.** Slim rows, history only on change, retention caps, size guard. Touches `lib/snapshot_restore.py`, `cctrl` (`_session_snapshot`, `_snapshot_retention_prune`), tests and README.
3. **S3: record intentional ends.** `closed` on kill, close and stop-exact, plus `session mark-closed`. Touches `cctrl`, tests, README and help text.
4. **S4: stop new conflicts.** Reclaim-from-app rule in the registry merge, anchor release on conversation change. Touches the `cctrl` registry reducer and merge, and tests.
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
