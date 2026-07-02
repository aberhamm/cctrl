---
id: 014
title: Add a base STATE column to session ls from the per-pid status field
status: pending
blocked-by: [013]
priority: 14
goal: cctrl-fleet-staleness
allows-migrations: false
needs-review: none
created: 2026-06-30
---

## Requirements

`cctrl session ls` collapses every session's activity into `attached` /
`detached`, which says nothing about whether the agent is currently working,
sitting idle, or dropped to a shell. When triaging ~20 sessions the user needs
a one-glance state. The Claude per-pid file (`~/.claude/sessions/<pid>.json`,
already read via the helpers from plan 013) carries an authoritative `status`
field with values `busy`, `idle`, and `shell`. This plan surfaces a base STATE
column derived from it — cheap and reliable. Richer states
(waiting-input / blocked-dialog / unsent-draft) are deliberately deferred to
plan 016.

**Acceptance criteria:**

- [ ] `cctrl session ls` shows a `state` column with base values:
      `working` (per-pid `status=busy`), `idle` (`status=idle`),
      `shell` (`status=shell`), and `-` when the status is unavailable
      (non-Claude sessions or missing per-pid file).
- [ ] The attached/detached fact is preserved (e.g. an attached marker or
      retaining it as a separate column/flag), so no information is lost
      relative to the current output.
- [ ] `cctrl session ls --json` exposes a `state` field carrying the base value
      (and continues to expose `attached`).
- [ ] Sessions without a resolvable per-pid status render `-`, never error.

## Design

Reuse `_session_claude_field <sess> status` from plan 013. Map `busy→working`,
`idle→idle`, `shell→shell`, else `-`. The current `state` variable in
`_session_list` holds `attached|detached`; decide the cleanest presentation:
keep `attached` as a distinct marker/column and let the new `state` carry the
working/idle/shell semantics. Update the `printf` width string and the `--json`
object accordingly.

**Files expected to change:**

- `cctrl`: `_session_list` — derive base state, render column, add to `--json`.
- `tests/run-tests.sh`: cases asserting `busy→working`, `idle→idle`,
  `shell→shell`, and `-` for an unresolvable session, using injected per-pid
  fixtures.

**Testing approach:** unit-only.

**Out of scope:** rich state detection (waiting-input/blocked-dialog/
unsent-draft/idle-done) — that is plan 016. Do not read transcripts or scrape
panes here; base state comes solely from the per-pid `status` field.

## Tasks

1. Add a `_session_base_state <sess>` helper mapping per-pid `status` to
   `working|idle|shell|-`.
2. Wire it into `_session_list` human output; reconcile with the existing
   attached/detached display so attachment info is retained.
3. Add `state` to the `--json` object.
4. Add tests covering each status mapping plus the unresolvable `-` case.

## Verification

- [cmd] `bash -n cctrl`
- [cmd] `tests/run-tests.sh < /dev/null`
- [assert] `tests/run-tests.sh < /dev/null` output contains `working`
- [assert] a new test asserting an `idle` per-pid fixture yields `state` ==
  `idle` in `session ls --json`
