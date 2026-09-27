---
id: 078
title: session snapshot defaults to CCTRL_DATA_DIR
status: pending
blocked-by: []
priority: 78
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-27
tui-fixture: n/a
approved-by: none  # filed at the fleet manager's request (guardok-fm0927)
---

## Plain-English Summary

`cctrl session snapshot` without `--dir` always writes `$SCRIPT_DIR/data/snapshots`, ignoring `CCTRL_DATA_DIR`. So do the restore default (`--from latest`) and the doctor's staleness check. Everything else in cctrl follows `CCTRL_DATA_DIR`, which the test suite sets to a temp directory.

As things stand, a test that forgets `--dir` would write the real `latest.json`. The live-store guards deliberately ignore the timer's file names there (`latest.json`, `<UTC>Z.json`, `.snapshot-*`), so they would not notice. For now a static check, `test_snapshot_calls_pass_dir`, fails any `session snapshot` call in the tests that lacks `--dir`.

## Requirements

- [ ] The default snapshot directory is `${CCTRL_DATA_DIR:-$SCRIPT_DIR/data}/snapshots` for `session snapshot`, `session restore --from latest` and the doctor/timer staleness check.
- [ ] The launchd timer's behaviour doesn't change: it doesn't set `CCTRL_DATA_DIR`.
- [ ] Tests: with `CCTRL_DATA_DIR` set and no `--dir`, snapshot and restore use that directory, and the real store is untouched.
- [ ] Then narrow or remove the snapshot exclusion in the live-store guards (`live_tree_digest`, `ownership_live_store_digest`), because tests can no longer reach the real store.
