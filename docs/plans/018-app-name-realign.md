---
id: 018
title: Realign existing tmux/app-name MISMATCH rows in session doctor
status: pending
blocked-by: [013]
priority: 18
goal: cctrl-fleet-staleness
allows-migrations: false
needs-review: none
created: 2026-06-30
---

## Requirements

`cctrl session doctor` reports `MISMATCH` rows where a session's tmux name and
its Claude app session name (the `--remote-control-session-name-prefix`) have
diverged — the residue of earlier `--name` forcing and inconsistent launch
paths. Plan 012 fixes this going forward at *launch time*; this plan adds the
*repair* side for already-running mismatched sessions.

**Critical constraint (verified against source):** the app session name is the
`--remote-control-session-name-prefix`, which is baked into the process launch
argv. There is **no in-session command to rename a running Claude session** —
`_session_repair_bridge` re-injects `/rc` to re-establish a bridge but cannot
change the prefix (see the "relaunch to fix" comment at `cctrl:~4427`). So
realigning an existing session is a **guided relaunch**, not an in-place rename:
kill + recreate the session with the correct `--name`/prefix, using the
plan-013 `sessionId` to `--resume` the same conversation so nothing is lost.

**Acceptance criteria:**

- [ ] `cctrl session doctor` clearly reports each tmux/app-name MISMATCH row
      (tmux name + current app-name prefix + expected). (Detection already
      exists; keep/clarify it.)
- [ ] `cctrl session doctor --fix` offers, **per mismatched session with an
      explicit confirm**, to relaunch it with the correct `--name`/prefix,
      `--resume`-ing its plan-013 `sessionId` so the conversation is preserved.
- [ ] Realign **skips busy sessions** (`status=busy`) and **copy-mode** panes,
      exactly as the existing bridge repair does — never relaunch mid-work.
- [ ] After a realign, the session's app-name prefix matches its tmux name
      (`aligned=ok`); the action is reported.
- [ ] `--fix` is idempotent: a second run on an aligned fleet relaunches nothing
      and reports no changes.
- [ ] `doctor --json` includes the mismatch/realign status + action per session.
- [ ] Without `--fix`, doctor only reports (with a copy-pasteable relaunch hint)
      and never mutates or relaunches sessions.

## Design

Build on the existing `_session_doctor` (~line 4351), which already detects the
mismatch (`aligned`/`MISMATCH`, `n_misnamed`) and reports it. This plan adds the
`--fix` realign as a guided relaunch:

1. For a `MISMATCH` session (not busy, not copy-mode), resolve its `sessionId`
   via the plan-013 helper and its canonical name (per plan 012).
2. Prompt per session (respect `--yes`); on confirm, relaunch it detached with
   the correct `--name`/prefix and `--resume <sessionId>`, reusing the existing
   detached-launch path (which now goes through plan 017's safe index picker).
3. Verify the relaunched session reports `aligned=ok`; report the action.

Report-only mode adds a copy-pasteable relaunch hint per MISMATCH row. No
keystroke injection is involved (relaunch, not in-session rename), so the
copy-mode concern applies only to the skip check, not to a repair keystroke.

**Files expected to change:**

- `cctrl`: extend `_session_doctor` `--fix` with the guided-relaunch realign
  (skip busy/copy-mode, confirm per session, `--resume <sessionId>`); add the
  report-only relaunch hint; extend `--json` with the action.
- `tests/run-tests.sh`: cases asserting a fabricated mismatch is reported with a
  relaunch hint; that `--fix --yes` (with stubbed tmux + relaunch path) emits
  the correct relaunch command carrying `--resume <sessionId>` and the corrected
  `--name`; that a busy MISMATCH session is skipped; that a second `--fix` on an
  aligned fleet is a no-op.

**Testing approach:** unit-only (the relaunch path is stubbed; no real sessions
are killed in tests).

**Out of scope:** launch-time naming reconciliation (plan 012), the live-index
clobber guard (plan 017 — but the realign relaunch MUST route through 017's safe
picker), and any attempt to rename a session in place (impossible — see
constraint above). Do not change bridge-collision detection.

## Tasks

1. In `_session_doctor --fix`, for each `MISMATCH` session, gate on
   not-busy + not-copy-mode; resolve `sessionId` (plan 013) and canonical name
   (plan 012).
2. Add the guided relaunch: confirm per session (respect `--yes`), then relaunch
   detached with the corrected `--name`/prefix and `--resume <sessionId>` via the
   existing detached-launch path (through plan 017's picker).
3. Verify the relaunched session reports `aligned=ok`; report the action; make
   `--fix` idempotent (aligned fleet → no relaunch).
4. Add the report-only relaunch hint per MISMATCH row; extend `--json`.
5. Add tests: mismatch reported with hint; `--fix --yes` emits correct
   `--resume`+`--name` relaunch; busy session skipped; second `--fix` no-op.

## Verification

- [cmd] `bash -n cctrl`
- [cmd] `tests/run-tests.sh < /dev/null`
- [assert] a fabricated-mismatch test asserts `doctor --json` contains the
  mismatch flag and a relaunch hint
- [assert] a `--fix --yes` test asserts the emitted relaunch command carries
  `--resume <sessionId>` and the corrected `--name`
- [assert] a busy-session test asserts the MISMATCH session is skipped
- [assert] an idempotency test asserts a second `--fix` reports no changes
