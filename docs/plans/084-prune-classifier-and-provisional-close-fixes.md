---
id: 084
title: Fix remaining prune-classifier fail-open bugs and provisional-close corner cases (081 re-review)
status: pending
blocked-by: []
priority: 84
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-28
tui-fixture: n/a
approved-by: matthew (C-15, via cctrl-fleet-manager)
---

## Plain-English Summary

Split from plan 075. These are the findings from the 2026-09-28 eng review
of plan 081 (prune pipefail fix + provisional-close fix) that plan 081
itself didn't fix. Most of these sit on the destructive-prune classifier
or the provisional-close path, so they get top priority among the 075
split-outs.

## Requirements

- [ ] `cctrl` `_task_record_record_close_provisional_file` (~2746-2789),
      wired into `_task_record_transition_file`: the provisional special
      case drops the caller's digest guard (`${10}`) and source/owner
      arguments that the generic path honors. Nothing reaches this today
      (`lib/conflict_resolve.py:228` only reads `task-*.json`), but it
      should refuse when a digest is passed rather than silently ignoring
      it.
- [ ] `cctrl` `_session_task_records_for_name`'s `launch-*.json` close path
      (~12432-12434) has no startup grace — the launch receipt is written
      before `tmux new-session` runs, so a `mark-closed` landing in that
      window could close a session's record while it's still starting up.
      Give it the same 300s grace the snapshot/restore layer already uses
      (`PROVISIONAL_STALE_GRACE_SECONDS`).
- [ ] `cctrl:13389-13396` (`_session_never_prompted`): a transcript read
      error leaves the captured variable empty, and the Codex branch
      treats `grep`'s exit 2 (real error) the same as "no match" — both
      fail toward "never-prompted" in a classifier that feeds a
      destructive prune. Treat a read/grep error as "not flagged" (fail
      open on the destructive side), not as a positive match.
- [ ] `cctrl:13389`: loading the first 500 transcript lines into a shell
      variable can be several MB when transcripts carry base64 image
      content. Prefer a single bounded `awk` pass (`NR>500{exit 1}
      /pattern/{exit 0}`) that avoids both the pipe-under-pipefail hazard
      and the large in-memory buffer.
- [ ] Pipefail audit follow-up (plan 081 missed two sites with the same
      SIGPIPE-under-`set -o pipefail` shape): `cctrl:8692` (`tmux
      list-panes | awk '{...; exit}'`) and `cctrl:13004` (`ps -ax | awk
      '...; exit}'` inside the restart background subshell, where errexit
      could skip the kill it's meant to guard).
- [ ] `test_snapshot_excludes_stale_provisional_restore_candidates` (plan
      081) only compares a 0s-old row against a 1h-old one; add a
      near-boundary case (e.g. ~60s vs ~301s against the 300s grace) to
      actually pin the threshold. Also add coverage of the real-world
      anchored close path (`_session_close` → `_session_record_terminated`)
      for a provisional-only record — today only `mark-closed --apply` is
      tested directly.
- [ ] `_task_record_find_by_session`'s fallback when the index file is
      missing: closing a provisional record rewrites the launch file, so
      it can become the newest record for a reused session name. Look at
      this alongside the digest-guard fix above.

## Needs a decision (not a code change — do not implement without explicit sign-off)

Plan 081's prune cap (`max(K=5, ceil(25% × live sessions))`) is a flat 5
for any fleet of 20 or fewer live sessions, so `--yes` can still close up
to 5 sessions — potentially all of a small fleet — in one call with no
override. This is very likely the intended behavior (5 is a deliberately
small floor), but it's Matthew's call to make explicitly rather than an
implicit side effect of the K/N choice. Surface this to Matthew; do not
change the cap logic as part of this plan unless he says otherwise.

## Rules

Edit a copy of `cctrl` or `lib/*` and syntax-check it (`bash -n` / `perl
-c`), then `mv` it into place. The live tree runs every session's hooks.

Test with the existing fake-tmux/fake-hostname test harness
(`tests/run-tests.sh`) only — do not test any of this against live tmux
sessions, and do not run `prune --yes`/`--close` or `session
reconcile-names` for real.
