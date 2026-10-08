---
id: 104
title: Hygiene batch 1 (delete unreachable functions, plan status drift, TODOS, temp dirs)
status: done
completed: 2026-10-08
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

Plan statuses (verified per plan against git log, CHANGELOG and code):
- Changed: 103 -> done (adfcc8f); 104 -> done; 100 -> done (below).
- 079: SHIPPED (9f92064, 2026-09-28) but left `pending` with a status-note: the
  gate has no `reviews:` record (only a free-text `eng-review:` line); writing
  an `approved` entry would restate someone else's review.
- Left as is, genuinely open: 028, 029 (blocked on 028), 034-038, 041-049, 050
  (blocked, partial), 039/040 (partial). Left as is, accurate: 033, 054, 055
  (`skipped`, documented reasons: 054 shipped in 53994fb, 055 folded into 100),
  075 (`split` into 084-089).

Plan 100: the gate (`_type_cleared`) fails when ANY `type=eng` entry is not
`approved`. The rev2 and rev3 `changes-requested` lines were moved to
`# SUPERSEDED` comments inside the `reviews:` block (the parser stops at the
first non-`- ` line, so they sit after the active entries), the final
as-shipped Opus approval was recorded, and a "Review history" section in the
body names both old verdicts as superseded. Nothing deleted; `assert-completable`
passes; gate, hook and mstack untouched.

TODOS.md: removed the done `_active_session_count` entry (now a 3-line
tmux/awk count), fixed the stale "119 tests", added one entry pointing at the
audit file for the open items.

Temp dirs: only 1 candidate matched the guards (older than 24 h, not in
lsof/ps, no live socket): `/tmp/cctrl-test-tmux.02M0Qg`; deleted. The other 33
`/tmp/cctrl-*` entries are under 24 h old or are not matching patterns
(benchmark, tmux-before snapshots), so were left. Skipped: 0.

## Out of scope / follow-ups

Test-harness plan (per-test filter, auto-registration, timing, PATH-shim
bypass sites, self-install running the suite with PATH bash only).
