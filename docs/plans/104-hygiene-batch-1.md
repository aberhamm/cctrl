---
id: 104
title: Hygiene batch 1 (delete unreachable functions, plan status drift, TODOS, temp dirs)
status: in-progress
blocked-by: []
priority: 104
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-10-08
tui-fixture: n/a  # dead-code deletion + docs
approved-by: Matthew ("Okay, just go with what you think the best decisions are and keep going.", 2026-10-08 15:49Z via the cctrl orchestrator; approval mdec-1008-cctrl-next-work, choice 3a; hygiene audit item #3 and #10)
reviews:
  - type=eng verdict=approved date=2026-10-08 by=opus-subagent  # first pass: one REQUIRED doc fix (findings doc), applied before commit
---

## Plain-English Summary

The hygiene audit (`~/.local/state/fleet/fm-cctrl-artifacts/hygiene/2026-10-07-cctrl-hygiene-audit.md`,
section 2.3) listed 9 functions in `cctrl` that nothing calls. This plan
re-verifies each one, deletes the ones that are provably dead, adds a guard
test so new dead functions are caught, and (second commit, docs only) fixes
plan-status drift, TODOS.md and leftover test temp dirs.

## Commit A: dead code (behaviour-preserving)

Re-verification: whole-name search (`grep -w`) across cctrl, lib, hooks,
install, completions, skills, plugins, tests, docs (non-archived); no
dispatch by constructed name (`declare -F`, `type -t`, `"_${x}"`) exists in
`cctrl`; no `cctrl_source_eval` use of any name but `_snapshot_v1_to_v2`.

Deleted (8, 240 lines):
`_codex_app_threads_json`, `_codex_rollout_matches_prompt`,
`_mailbox_resolve_identity`, `_task_registry_reduce`,
`_codex_writer_lock_is_stale`, `_codex_remote_control_enabled`,
`_default_agent`, `_peer_derived_identity_exists`.
Only mentions left were findings docs (`docs/findings/codex-task-lifecycle-contract.md`,
historical) and one test line.

Kept:
- `_snapshot_v1_to_v2`: the audit missed that a test (`cctrl_source_eval`-style
  `bash -c 'source ...; _snapshot_v1_to_v2'` in the snapshot ownership test)
  really calls it and asserts its output. Not dead for the suite; kept.

Test edit: `test_task_registry_structural_boundary` asserted only that
`^_task_registry_reduce()` is *defined* (an `rg -q` existence check, not a
call). That single line was removed with the function; the reducer's live
core `_task_registry_reduce_files` and `_task_registry_apply_event` checks
remain.

Guard: `test_no_unreferenced_functions` fails when a top-level `cctrl`
function name appears only once (its definition) across cctrl, lib, hooks,
completions and tests. Verified to flag exactly the 8 names on the pre-change
tree and to pass on the new one. Allowlist is empty. It found no further
dead functions.

## Commit B: bookkeeping (docs only)

Filled in after commit A (plan statuses changed/left, plan 100 closure,
TODOS.md decision, temp-dir cleanup counts).

## Out of scope / follow-ups

Test-harness plan (per-test filter, auto-registration, timing, PATH-shim
bypass sites, self-install running the suite with PATH bash only).
