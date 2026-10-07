---
id: 097
title: Register (or delete) the dead restore/snapshot tests and guard against recurrence
status: done
completed: 2026-10-07
blocked-by: []
priority: 97
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-10-07
tui-fixture: n/a  # fake tmux + injected evidence fixtures only
approved-by: Matthew ("yes we should continue with cctrl", 2026-10-07; mdec-1007-cctrl-continue item 3)
reviews:
  - type=eng verdict=approved date=2026-10-07 by=opus-subagent
---

## Plain-English Summary

`tests/run-tests.sh` defined 32 `test_*` functions that nothing ever called,
so the suite's "ok" lines said nothing about them. 31 were restore/snapshot
tests dropped from the call list by dbe923e (ownership-aware restore,
plan 068) when the engine and fixtures changed; 1 is a deliberately skipped
peer test. This plan registers every one that still describes live behaviour
(porting fixtures to the current evidence model), deletes the three whose
behaviour is gone, and adds a guard test so a defined-but-uncalled test fails
the suite.

## The dead-test list

Found by script: defined at column 0, no other line consisting of its name.

The handoff estimated ~17; the real count was **32** (18 restore, 13 snapshot,
1 peer).

| Test | Disposition |
|---|---|
| test_peer_mailbox_concurrency_and_stale_lock | KEPT SKIPPED, allowlisted: hangs on macOS bash 3.2 (flock), call already commented out with that reason |
| test_snapshot_header_and_session_shape | registered (ported to v2 fields) |
| test_snapshot_initial_prompt_absent | registered (ported) |
| test_snapshot_empty_fleet_guard_preserves | registered (passed as-is) |
| test_snapshot_allow_empty_overrides | registered (as-is) |
| test_snapshot_history_and_latest_agree | registered (ported) |
| test_snapshot_retention_pruning | registered (ported) |
| test_snapshot_no_tmux_mutation | registered (as-is) |
| test_snapshot_tmux_absent_preserves | registered (ported: now exit 69, latest byte-identical, no history file) |
| test_snapshot_first_run_empty_writes | registered (as-is) |
| test_snapshot_transcript_bytes_null_when_missing | DELETED: nothing computes `transcript_bytes` any more, the test asserted a constant null |
| test_snapshot_managed_matches_session_ls | registered (ported: compares registration/launch flags, which replaced `managed`) |
| test_snapshot_launch_flags_round_trip | registered (ported: reads `.tasks[0]`) |
| test_snapshot_conversation_id_from_session_id | registered (ported: checks `resume_identity`) |
| test_restore_ordering_by_last_active | DELETED: restore no longer sorts by last-active; the planner keeps snapshot order and the README never documented the ordering. See Follow-ups |
| test_restore_only_filter | registered (ported: filtered rows are `insufficient-evidence`, "filtered by --only") |
| test_restore_cap_on_total | registered; needed a product fix (below) |
| test_restore_null_conversation_id_skipped | registered (ported) |
| test_restore_dry_run_spawns_nothing | registered |
| test_restore_gate_stops_below_threshold | registered (memory gate now exits 1) |
| test_restore_limit_caps_spawns | registered |
| test_restore_no_tty_no_yes_exits_2 | registered, renamed `test_restore_no_tty_no_yes_refused` (exit 64) |
| test_restore_unknown_schema_refused | registered (exit 64, `--json`) |
| test_restore_stale_snapshot_refused | registered (exit 64, plus `--stale-ok` override check) |
| test_restore_host_mismatch_refused | registered (exit 64) |
| test_restore_cap_fails_closed | registered (no tmux on PATH: exit 69, nothing spawned) |
| test_restore_picker_expected_routing | DELETED: dbe923e removed the resume-picker feature and its README section |
| test_restore_wave_pacing | registered |
| test_restore_already_live_skipped | registered (live-ness now read from the catalogue) |
| test_restore_launch_config_replay | registered |
| test_restore_already_live_record_join | registered (matched by exact id under a different tmux name) |
| test_restore_exit_codes | registered (0 and 64) |

Totals: 28 registered, 3 deleted, 1 allowlisted skip.

## What changed

- `tests/run-tests.sh`: `_restore_fixture` rewritten to build a v2 snapshot
  plus injected catalogue/process/Codex evidence/host id; `_restore_run`
  passes every setting per command (the old fixture `export`ed
  `CCTRL_RESTORE_LAUNCH_LOG`, which would have leaked into later tests once
  registered). New snapshot helpers `_snapshot_v2_evidence`, `_snapshot_run`,
  `_snapshot_ls_json`. Focused group `snapshot-restore-legacy` lists the 28.
  Assertions were kept or tightened (exact counts, baseline "fixture is
  restorable" runs, empty launch-log checks); none weakened.
- Product fix in `cctrl` (`_session_restore`): `CCTRL_RESTORE_MAX_ACTIVE`
  (default 8, documented in the README) no longer did anything after dbe923e.
  Rows are now demoted to `insufficient-evidence` ("deferred by
  CCTRL_RESTORE_MAX_ACTIVE") once live tasks (catalogue rows owned by cctrl
  under tmux) plus planned restores reach the cap. Confirmed the test fails
  without the fix.
- Guard: `test_every_defined_test_is_registered` fails when a `test_*`
  function is defined but no other line consists solely of its name.
  Allowlist (with reason) is the heredoc inside the guard. Known limit: a test
  referenced only from a focused group counts as registered.

## Review

Opus eng review: changes-requested, one required fix (cap test assertions
too loose; now exact 2/2/2), applied. Optional nits: README cap wording
(applied); cap-count-unparseable fail-closed branch has no test; 
`test_restore_cap_fails_closed` actually covers evidence-unavailable;
memory-gate env not pinned in `_restore_run`; guard misses dead-code calls and
duplicate definitions.

## NOT in scope
- Plans 089, 033, 055, 035, 100 implementation.

## Follow-ups
- Restore ordering: `--limit` and the active cap now defer rows in snapshot
  order, not most-recently-active first. Decide whether to restore a
  last-active sort (the deleted test documents the old intent).
- README says each wave re-checks memory/swap and interactive mode releases
  per wave; code checks memory once before the first spawn and asks once.
  Align docs or code.
- Guard cannot see a test registered only in a focused group.
- `test_app_owned_launch` failed once in a full Homebrew-bash suite run
  (`suite-hb.log`, scratchpad of the plan-097 worker session; exact line:
  `FAIL: ambiguous creation result is wrong: {... "reason": "required App
  Server capability is not proven: thread/start" ...}`, tests/run-tests.sh
  ~line 14360). The full re-run passed (EXIT=0) and so did 30+ isolated and
  looped runs of the `app-owned-launch` group (including 12 in parallel with
  the HEAD test file). Not reproduced; the test and the Codex app-server code
  are untouched by plan 097. Suspected timing/load sensitivity: the test
  drives a fake python app-server with `CCTRL_CODEX_REQUEST_TIMEOUT=.05`
  (50 ms; lines ~14355 and ~14366), so a slow fake-server start could report
  a capability failure instead of the intended timeout outcome. The failing
  full run did not overlap another suite run (the bash 3.2 suite had finished;
  the Opus review subagent had completed). Not changed here; filed for a
  follow-up (raise/bound the timeout or retry the handshake in the test).

