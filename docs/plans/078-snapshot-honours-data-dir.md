---
id: 078
title: session snapshot defaults to CCTRL_DATA_DIR
status: done
blocked-by: []
priority: 78
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-27
completed: 2026-09-29
tui-fixture: n/a
approved-by: matthew (C-15, via cctrl-fleet-manager)
reviews:
  - type=eng verdict=approved date=2026-09-29 by=opus-level-subagent notes="1st pass: changes-requested (test's before/after real-store check was masked by the guard's own snapshot exemption; requirement 4's decision wasn't written down). Both fixed."
---

## Plain-English Summary

`cctrl session snapshot` without `--dir` always writes `$SCRIPT_DIR/data/snapshots`, ignoring `CCTRL_DATA_DIR`. So do the restore default (`--from latest`) and the doctor's staleness check. Everything else in cctrl follows `CCTRL_DATA_DIR`, which the test suite sets to a temp directory.

As things stand, a test that forgets `--dir` would write the real `latest.json`. The live-store guards deliberately ignore the timer's file names there (`latest.json`, `<UTC>Z.json`, `.snapshot-*`), so they would not notice. For now a static check, `test_snapshot_calls_pass_dir`, fails any `session snapshot` call in the tests that lacks `--dir`.

## Requirements

- [x] The default snapshot directory is `${CCTRL_DATA_DIR:-$SCRIPT_DIR/data}/snapshots` for `session snapshot`, `session restore --from latest` and the doctor/timer staleness check. Fixed at all three call sites in `cctrl` (`_snap_dir` in the doctor check, `_session_snapshot`'s `snapshot_dir` default, `_session_restore`'s `snapshot_path` default for `--from latest`).
- [x] The launchd timer's behaviour doesn't change: it doesn't set `CCTRL_DATA_DIR`. Confirmed: `contrib/launchd/com.cctrl.session-snapshot.plist.template` only sets `PATH`/`HOME`, so the timer still falls back to the real `data/snapshots` exactly as before — untouched, deliberately.
- [x] Tests: with `CCTRL_DATA_DIR` set and no `--dir`, snapshot and restore use that directory, and the real store is untouched. New test `test_snapshot_restore_default_honors_data_dir`. First pass compared `live_data_digest()` before/after, which the eng review caught as a no-op check — that digest guard already exempts `snapshots/latest.json` and siblings, so it can't see a regression there. Replaced with two deterministic checks: (1) the test's own fake host id must never appear in the real `data/snapshots/latest.json` after the run, and (2) `session restore --from latest` against a fresh, empty `CCTRL_DATA_DIR` must report a "not found" error whose `path` is that directory's `snapshots/latest.json`, never the real one.
- [x] Then narrow or remove the snapshot exclusion in the live-store guards (`live_tree_digest`, `ownership_live_store_digest`), because tests can no longer reach the real store. Decision: the exclusion patterns themselves stay unchanged. They were never there because tests needed them — they exist because the launchd snapshot timer runs independently (every 5 minutes, doesn't set `CCTRL_DATA_DIR`) and legitimately rewrites the real store's `snapshots/latest.json`/siblings during a test run on this shared machine (see plan 090). What this plan removes instead is the now-redundant workaround: `test_snapshot_calls_pass_dir`, the static lint requiring every test to pass `--dir`. It's structurally unnecessary now — `CCTRL_DATA_DIR` is exported globally at the top of `tests/run-tests.sh` and no test unsets it, so a test omitting `--dir` can no longer reach the real store regardless. Updated the guard's explanatory comment to state the remaining (timer-only) reason.
