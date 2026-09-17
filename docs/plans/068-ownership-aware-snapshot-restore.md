---
id: 068
title: Make snapshot and restore ownership-aware
status: in-progress
blocked-by: [064, 067]
priority: 68
goal: codex-task-ownership-surfaces
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-15
tui-fixture: n/a  # snapshot tests inspect records/process state and never parse terminal panes
reviews:
  - type=eng verdict=approved date=2026-09-16 by=mstack-review
---

## Plain-English Summary

A host restart destroys tmux processes but does not mean every Codex task should be relaunched in tmux. This plan records all known tasks for situational awareness while restoring only tasks whose ownership record explicitly authorizes a cctrl terminal resume.

**What changes in the code:** Snapshots gain the provider-neutral ownership fields and a per-row recovery action. Restore reads both old and new snapshots, skips provider-managed app tasks with a clear reason, and never converts an observed or handed-off task back into a tmux worker.

## Requirements

The existing snapshot is built from the tmux-only session list and restore selects managed rows for `_launch_detached`. Once app tasks enter the catalogue, that selection must become an explicit restore-strategy decision rather than a broad `managed` boolean.

**Acceptance criteria:**

- [ ] Snapshot schema v2 captures each local task's provider id, host id, origin, runtime, owner, lifecycle state, restore strategy, launch/registration provenance, and calculated recovery action.
- [ ] Each persisted schema-v2 snapshot task row contains provider, provider task id, host id, origin, runtime, owner, lifecycle state, restore strategy, registration/launch provenance, distinct lineage, nullable tmux session, nullable provider-specific resume-identity kind/value, observation time, informational recovery action/reason, and ownership evidence. The envelope contains schema version, generated time, durable host id, resource metadata, task rows/counts, capture quality, and source errors.
- [ ] App-created, discovery-only, app-owned cctrl-launched, and released-to-app tasks appear as provider-managed/non-restorable references; snapshotting them never starts, resumes, archives, or opens them.
- [ ] The closed restore predicate requires schema 2, tmux-resume strategy, both cctrl registration/launch provenance, cctrl origin, tmux runtime/cctrl owner, a resumable/inactive lifecycle state, provider-supported nonempty resume id, matching durable host id, and no stronger ownership conflict. Missing/unknown fields yield insufficient evidence.
- [ ] Restore never uses `cctrl_managed:true`, a tmux-like name, cwd, title, or missing schema-v2 fields alone to authorize a spawn.
- [ ] Schema-v1 snapshots remain readable through the new v1 adapter. Every legacy Codex row is insufficient-evidence; only a legacy Claude row with managed true, nonempty conversation id, valid cwd, and matching host may adapt to tmux-resume. Name/cwd/title never strengthen eligibility.
- [ ] Dry-run and JSON output show `restore`, `provider-managed`, `already-live`, `conflict`, `unknown`, and `insufficient-evidence` dispositions per task.
- [ ] Stored recovery action is informational. At restore time the new restore planner rejoins live ownership evidence by provider plus host identity; authoritative app ownership overrides a stale pre-handoff snapshot, and contradictions become conflict/no-spawn.
- [ ] Restore requires one unique identity-matching live catalogue row and successful mandatory source reads. Codex requires registry, App Server/provider inventory, and tmux/process snapshots; Claude requires registry plus tmux/process snapshots. Source error, absent match, or duplicate/ambiguous match yields insufficient-evidence or conflict and no spawn—snapshot data alone never authorizes restore.
- [ ] A released-to-app task keeps the same provider id in the snapshot and is never duplicated by restore after reboot.
- [ ] For native app tasks cctrl emits provider-managed/non-restorable and never relaunches them or claims that tmux changes provider persistence.
- [ ] A capture-quality gate preserves byte-identical latest/history snapshots and returns degraded/nonzero if any source required to enumerate restorable rows fails; `--allow-empty` cannot override source failure. Task-reference count and restore-candidate count are separate.
- [ ] Snapshot automation preserves `cctrl::_session_snapshot` and `_snapshot_retention_prune` atomic-write/retention guarantees.
- [ ] Disposition precedence is conflict, live, provider-managed, insufficient-evidence/unknown, then restore. Filters/limits apply only after eligibility and never upgrade a row. `--force-host` may bypass an envelope hostname for inspection but never makes a row with mismatched durable host id restorable.
- [ ] The single restore-plan policy function enables per-row `action_capabilities.restore`: only an exact eligible row becomes supported/`tmux-resume`; provider-managed, source-error, absent/ambiguous, conflict, unknown, archived, or host-mismatch rows remain false with the matching reason.
- [ ] Exit codes are exact: 0 for a complete plan/execution (including honest provider-managed skips), 64 for invalid input/schema, 69 when mandatory restore-time evidence is unavailable/absent, 75 for ownership conflict/stale evidence, and 1 for internal/parse/execution failure. JSON always carries the per-row disposition/reason.
- [ ] Tests cover v1/v2, mixed Claude/Codex fleets, app restart, host reboot, handoff before reboot, conflict, missing id, and dry-run/no-spawn behavior.

## Design

Build snapshots from plan 064's normalized local task catalogue into one tempfile/stdin stream and one-pass transform; never grow shell JSON with `jq --argjson`. Use pure `_snapshot_v1_to_v2` and `_restore_plan_json` as the single policy path for dry-run, JSON/human rendering, and execution. Re-evaluate current evidence at restore time and apply the closed predicate/precedence above.

**Files expected to change:**

- `cctrl`: snapshot schema v2, v1 reader adapter, restore disposition logic, reports, and structural safety guards.
- `tests/run-tests.sh`: mixed ownership, legacy, reboot, handoff, and no-spawn restore tests.
- `README.md`: what tmux, Codex, snapshot, and provider persistence each survive.

Testing approach: E2E

**Out of scope:** backing up Codex provider data, waking a powered-off host, automatically reopening app tasks on another device, replaying initial prompts, or changing provider archive state.

## Tasks

1. Define exact snapshot envelope and `snapshot_task_v2` fields, disposition/reason and exit-code table, capture-quality gate, and the closed restore predicate.
2. Stream provider-neutral enumeration through one tempfile/one-pass transform without side effects or O(n²) shell JSON accumulation.
3. Add `_snapshot_v1_to_v2` with exact legacy rules and `_restore_plan_json` as the only candidate/capability selector, requiring the provider-specific mandatory current sources and one unique matching row.
4. Update dry-run, JSON, and human reports with per-task skip/restore reasons.
5. Add structural guards ensuring app/provider-managed rows never reach `_launch_detached`.
6. Under temporary snapshot/data/metadata/host-id/provider roots, test fixture-mode reboot/handoff, stale pre-handoff snapshot versus live app state, source failure/absent/duplicate matches, restore-capability enablement, partial-source latest preservation, host mismatch despite `--force-host`, mixed fleets, old snapshots, and atomic crash behavior; prove real stores are byte-identical before/after.
7. Document the distinct persistence guarantees of tmux, cctrl snapshot, and Codex tasks.

## Verification

Checks:

- [cmd] `bash -n cctrl`
- [cmd] `bash tests/run-tests.sh`
- [assert] `rg -q "provider-managed" cctrl`
- [assert] `rg -q "restore_strategy" cctrl`
- [cmd] `CCTRL_TEST_ONLY=snapshot-ownership bash tests/run-tests.sh`

<!-- mstack:seam
produced:
- kind: schema; name: snapshot_task_v2; shape: "provider,provider_task_id,host_id,origin,execution_runtime,control_owner,lifecycle_state,restore_strategy,registered_by_cctrl,launched_by_cctrl,lineage,tmux_session,resume_identity_kind,resume_identity,observed_at,recovery_action,recovery_reason,ownership_evidence"; file: cctrl
- kind: schema; name: snapshot_v2; shape: "schema_version,generated_at,host_id,resource_metadata,tasks,task_reference_count,restore_candidate_count,capture_quality,source_errors"; file: cctrl
- kind: symbol; name: _restore_plan_json; file: cctrl
- kind: symbol; name: _snapshot_v1_to_v2; file: cctrl
assumed:
- from: 064; kind: schema; name: task_list_v2; file: cctrl
- from: 064; kind: schema; name: task_list_row_v2; file: cctrl
- from: 067; kind: schema; name: codex_handoff_result_v1; file: cctrl
-->


## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | Not required for this implementation plan |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | SKIPPED | Running under Codex; nested pass suppressed |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 0 open issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | No visual UI scope |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | Not required |

**VERDICT:** ENG CLEARED — ready to implement.

NO UNRESOLVED DECISIONS
