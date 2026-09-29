---
id: 090
title: Live-store guard flakes — make them diagnosable, then narrow the exclusion list
status: done
completed: 2026-09-29
blocked-by: []
priority: 90
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-28
tui-fixture: n/a
approved-by: matthew (via cctrl-fleet-manager), 2026-09-29
reviews:
  - type=eng verdict=approved date=2026-09-29 by=opus-level-subagent
---

## Plain-English Summary

`tests/run-tests.sh`'s "tests did not touch the real live store" guards
(`live_tree_digest`/`live_data_digest`, and `ownership_live_store_digest`)
hash the whole `data/` directory (plus a handful of dotfiles) before and
after a test group and fail if the digest moved. This is the second
live-store guard flake in two days on this shared, actively-used dev
machine — each one costs a ~40 minute full-suite re-run to confirm it wasn't
a real leak. Filed by the fleet manager after `test_fleet_v2_provider_neutral_federation`
failed with `FAIL: fleet v2 tests changed the real cctrl live store` during
plan 077's verification run (2026-09-28), then passed cleanly on an isolated
re-run of the exact same test seconds later — the digest moved because of
concurrent activity from other live fleet sessions on this machine, not
because of anything the test itself wrote.

## Evidence from the failing run

The run's log (`live_tree_digest`/`before`/`after` around
`tests/run-tests.sh:8167-8173`) only prints the pass/fail line — it does not
say which file changed, so there is no way to tell a flake from a real leak
after the fact. A `find data -newer <failing-run's log file>` immediately
after the failure showed several `data/sessions/*.json` records,
`data/sessions/.session-index-*.ref`, and `data/snapshots/*.json` files with
mtimes at or after the failure, alongside `data/rate-limits.json` — i.e.
exactly the kind of routine live-session writes (heartbeats, task-record
transitions, the snapshot timer) that a shared multi-session dev machine
produces continuously, landing inside the ~40 minute window the full suite
runs in.

Both guard helpers (`tests/run-tests.sh:59-65` `live_tree_digest`, and
`tests/run-tests.sh:68-109` `ownership_live_store_digest`) already special-case
three families of live-fleet writes and exclude them from the digest:
`rate-limits*.json(l)`, `messages.jsonl`, and `snapshots/latest.json` /
`snapshots/<UTC>Z.json` / `snapshots/.snapshot-*`. **`data/sessions/*.json`
(the session/task registry that every live session's heartbeats, spawns, and
closes write to) and `data/needs-me-snapshot.json` are not on that list** —
this is the most likely source of the flake, and directly evidenced by the
`find -newer` output above.

## Requirements

- [x] **(a) Diagnosability.** When `live_tree_digest`/`live_data_digest` (or
      `ownership_live_store_digest`) detects a mismatch, print which path(s)
      changed and how (added/removed/modified), not just "before != after".
      The simplest version: instead of (or in addition to) a single rolled-up
      hash, keep a per-file `path\tsha256` listing for the `before` and
      `after` snapshots and diff them; print the diff on failure. This must
      not change what counts as a failure today — it only makes an existing
      failure explain itself.
- [x] **(b) Narrow the exclusion, don't broaden it into a blind spot.**
      Extend the existing per-name/per-path exclusion approach (`tests/run-tests.sh:59-65`,
      `68-109`) to also recognize live-fleet writers under `data/sessions/`
      the same way `messages.jsonl` is already handled: exclude a record
      only when it carries a name/id that's a live *test fixture* would never
      use for something the guard should actually catch — i.e. flag
      `data/sessions/*.json` writes whose *filename* doesn't correspond to
      any session/task name the test group under scrutiny itself created.
      Do **not** exclude the whole `data/sessions/` directory wholesale —
      that would blind the guard to a test that actually leaks a spawn/close
      into the live registry, which is exactly the hazard the guard exists
      to catch (see `fleet-prune-safety` and `cctrl-multi-machine-git`
      memories). Also evaluate `data/needs-me-snapshot.json`, which the
      `find -newer` evidence above also flagged.
- [x] **(c) Consider scoping the guard to the suspicious group, not the whole
      run.** Investigate taking the "before" snapshot immediately before each
      test group that asserts store-isolation (e.g. right before
      `test_fleet_v2_provider_neutral_federation`), rather than once at
      process start covering the full ~40 minute run — this shrinks the
      window in which unrelated concurrent fleet activity can land a false
      positive, without weakening what the guard actually checks. Only do
      this if it doesn't require duplicating the exclusion logic per call
      site; prefer a single parameterized snapshot/diff pair over N copies.
- [x] Add a test (or extend an existing one) that pins the new exclusion
      behavior: a live-looking `data/sessions/some-other-session.json` write
      that occurs *during* a test group is correctly ignored, while a write
      to a session/task name the test group itself is responsible for is
      still caught.

## Out of scope for this filing

Fixing `test_fleet_v2_provider_neutral_federation` itself — it isn't broken;
re-running it in isolation immediately after the failure passed cleanly.
This plan is about the guard's diagnosability and precision, not that test.

## Rules

Edit a copy of `tests/run-tests.sh` and `bash -n` it before moving it into
place, per repo convention. Do not weaken what counts as a live-store leak
in the process of reducing false positives — when in doubt, keep the
exclusion narrower and file a further follow-up rather than broadening it
speculatively.

## Outcome (2026-09-29)

- **(a)** One Python helper (`$TMPDIR/live_store_guard.py`) builds a
  per-file manifest (`kind<TAB>path`, sha256 per file, rows for dirs and
  links) and diffs two manifests. Every guard site now calls
  `assert_live_store_unchanged BEFORE AFTER MESSAGE [owned-name...]`, which
  on failure lists each `added:`/`removed:`/`modified:` path.
- **Found while doing (a):** the install gate runs the suite from a release
  whose `data/` is a symlink to the live store, and `find DIR` without `-H`
  does not follow a symlinked root. The old guard hashed nothing there and
  always passed. The ownership digest only recorded the link target. The
  manifest now follows a symlinked root.
- **(b)** Registry entries directly under `data/sessions/` that were added
  or modified are tolerated as live-fleet churn only when the file stem is
  not an owned name and the content mentions neither this run's `$TMPDIR`
  nor an owned name. Removed records always fail. Registry lock files and
  mktemp'd `.task-event.*` files are tolerated. Tolerated churn is printed
  as a `note:` line. `needs-me-snapshot.json` is excluded by name, and
  `cctrl`'s `NEEDS_ME_SNAPSHOT` now follows `CCTRL_DATA_DIR`, so the suite
  cannot write the real file without an explicit override. It was the one
  data-dir state file that ignored `CCTRL_DATA_DIR`.
- **(c)** No change. Every guard already snapshots immediately around its
  own test. The fleet-v2 guard that flaked wraps a single `cctrl fleet`
  call. Only the ownership-matrix group guard is wide, and it now shares the
  same helper.
- Test: `test_live_store_guard_diagnostics_and_churn` covers the symlinked
  root, tolerated churn, an owned-name write, a `$TMPDIR`-bearing write, a
  removed record, and the failure message.

Follow-ups (not done): `.session-index-*.ref` holds only a task filename,
so it can't be matched by content. The ownership-matrix outer guard passes
no owned names and relies on `$TMPDIR` matching. The manifest splits on the
first tab, so a link target containing a tab would mis-parse.
