---
id: 022
title: "What needs me" digest — sessions newly waiting, errored, or finished
status: done
blocked-by: [014, 016]
priority: 22
goal: cctrl-fleet-staleness
allows-migrations: false
needs-review: none
created: 2026-06-30
completed: 2026-07-02
reviewed: false
qa: automated
---

## Requirements

Across ~20 sessions, the thing the user actually wants at a glance (especially
from the phone) is: *which sessions newly need me since I last looked* — ones
that just went waiting-on-input, errored, or finished. This plan adds a
`cctrl needs-me` digest that diffs current session states (using the rich STATE
from plan 016) against a stored snapshot from the previous run and reports only
what changed into an attention-worthy state.

**Acceptance criteria:**

- [ ] `cctrl needs-me` reports sessions currently in an attention state
      (`waiting-input`, `blocked-dialog`, errored, finished/`idle-done`), grouped
      by what newly changed since the last run.
- [ ] State is snapshotted to disk each run; the next run diffs against it so
      "newly" is accurate (a session already waiting last time is not re-flagged
      as new).
- [ ] First-ever run (no prior snapshot) reports all current attention-state
      sessions as new, without error.
- [ ] `--json` returns the changed sessions with `name`, `from_state`,
      `to_state`, and `last_active`.
- [ ] The digest is read-only: it never closes, repairs, or mutates sessions.
- [ ] Output is compact enough to be useful as a phone glance / notification
      body.

## Design

Add a `needs-me` command (top-level or under `cmd_session`). Compute each
session's rich state via plan 016; load the prior snapshot from the cctrl data
dir (e.g. `data/needs-me-snapshot.json`), diff per session
(`from_state → to_state`), select transitions *into* an attention state, render
grouped output, then write the new snapshot. Define the attention-state set
explicitly. Local-host scope (composes naturally with plan 020's fleet later but
not required here).

**Files expected to change:**

- `cctrl`: add `needs-me` dispatch + help; implement `_session_needs_me`
  (state collection via 016, snapshot load/diff/save, grouped render, `--json`).
- `tests/run-tests.sh`: cases driving two successive runs over changing fixture
  states, asserting only newly-attention sessions are flagged the second run;
  assert first-run-no-snapshot behavior; assert snapshot is written.

**Testing approach:** unit-only.

**Out of scope:** push notifications / Telegram delivery (out of band; this
produces the digest text only) and cross-host aggregation. Strictly read-only.

## Tasks

1. Define the attention-state set and the snapshot schema/location
   (test-overridable path).
2. Implement state collection (reuse plan 016) + snapshot load/diff/save.
3. Select transitions into attention states; render grouped output + `--json`.
4. Add `needs-me` dispatch + help.
5. Add tests: two-run diff flags only new transitions; first-run behavior;
   snapshot written.

## Verification

- [cmd] `bash -n cctrl`
- [cmd] `tests/run-tests.sh < /dev/null`
- [assert] a two-run test asserts a session that was already `waiting-input` in
  the prior snapshot is NOT reported as new on the second run
- [assert] a test asserts a session that transitioned idle→waiting-input IS
  reported, with `from_state`/`to_state` in `--json`

## Implementation Notes

Added top-level `cctrl needs-me`: computes each live session's rich STATE (via
`_session_rich_state` through `session ls --json`), diffs against the prior
snapshot, and reports only sessions that NEWLY transitioned INTO an attention
state (`waiting-input`, `blocked-dialog`, `idle-done`; rich-state has no distinct
errored signal, documented in-code). An already-attention session is not
re-flagged; a missing/corrupt snapshot is an empty baseline (first-run flags all
current attention sessions with `from_state` `-`). Snapshot at
`data/needs-me-snapshot.json` (override `CCTRL_NEEDS_ME_SNAPSHOT`), written
atomically after render. Strictly read-only. `--json` carries
name/from_state/to_state/last_active.

**Files changed:**

- `cctrl` (modified)
- `tests/run-tests.sh` (modified)

**Commit:** `3c642b0` — `feat(session): add needs-me digest of newly-attention sessions`
