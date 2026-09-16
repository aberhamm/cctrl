---
id: 058
title: Add provider-neutral task records and legacy compatibility
status: in-progress
blocked-by: [057]
priority: 58
goal: codex-task-ownership-surfaces
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-15
tui-fixture: n/a  # task records store tmux identifiers but never parse terminal pane text
reviews:
  - type=eng verdict=approved date=2026-09-16 by=mstack-review
---

## Plain-English Summary

cctrl currently treats a tmux session name as both identity and ownership, which cannot describe an app-owned Codex task. This plan introduces a record that separately says where a task came from, where it runs, who controls it now, and whether cctrl may restore it.

**What changes in the code:** Session metadata gains a versioned, provider-neutral task identity and ownership model while old JSON records remain readable. A durable per-machine id prevents two hosts or mutable aliases from accidentally referring to different tasks as the same record.

## Requirements

The same Codex provider task can move from a cctrl-owned terminal process to the app without changing its provider id. The record format must preserve that continuity while distinguishing tasks cctrl merely observed from tasks it launched and controls.

**Acceptance criteria:**

- [ ] Schema version 2 stores schema_version as integer 2; immutable provider, nullable string provider_task_id, origin, string host_id, boolean registered_by_cctrl, and boolean launched_by_cctrl; and mutable execution_runtime, control_owner, lifecycle_state, nullable restore_strategy, and RFC 3339 last_observed_at. Missing schema_version means a legacy task record, not snapshot schema v1.
- [ ] Schema v2 carries a lineage object that keeps nullable provider forked_from_id and provider parent_thread_id separate. A nullable derived_root_id is populated only by explicit ancestry traversal and includes derived_root_basis; it is never presented as a provider-exposed root field.
- [ ] Allowed values include explicit `unknown` and `conflict` states; missing evidence is never converted to app ownership or cctrl ownership.
- [ ] Schema v2 includes a bounded ownership-evidence collection whose entries carry source, source instance/cursor, authority class, observed owner/runtime/state, observed timestamp, and reason. A conflict record preserves the competing entries in this field; timestamps do not choose the winner.
- [ ] `origin` distinguishes at least `cctrl`, `codex-app`, `external-cli`, and `unknown`. A later ownership transition never rewrites origin.
- [ ] A nullable `tmux_session` is a capability/location field, not the task identity. The provider task id plus durable host id is the deduplication boundary.
- [ ] registered_by_cctrl and launched_by_cctrl have independent meanings. App-created tasks may be registered without becoming cctrl-launched or cctrl-restorable.
- [ ] A durable machine id is generated once at the configured host-id file under the cctrl data root, with that path exported to a temporary location by the test bootstrap. Creation has exclusive winner/loser semantics, mode `0600`, and rejects symlinks, non-regular files, or malformed ids; concurrent creators re-read one winner and never replace it.
- [ ] Existing records with no `schema_version` are read through a conservative legacy-task adapter without eager bulk rewrite. Legacy `cctrl_managed:true` does not automatically imply app ownership or app restorability.
- [ ] Legacy files remain immutable compatibility inputs. A mutating path first normalizes and lazily promotes only when it has a stable provider task id; lookup then prefers the canonical v2 record while the legacy file stays untouched. List/doctor become read-only and intentionally stop their legacy metadata backfill while retaining output compatibility. Identity-dependent actions such as app release/archive refuse a legacy record without stable provider identity; tmux close and other identity-independent operations continue and report that provider metadata was not updated.
- [ ] New tmux launches write `origin:cctrl`, `execution_runtime:tmux`, `control_owner:cctrl`, and a tmux restore strategy; native app records can represent `execution_runtime:app-server`, `control_owner:app`, and provider-managed restore.
- [ ] Before a provider task id is known, a launch record is explicitly provisional and keyed by a generated launch id. Promotion to a provider-keyed record is atomic and idempotent: the new canonical record is committed before the provisional record is retired, interrupted promotion is recoverable, and duplicate observations collapse without changing origin.
- [ ] If promotion finds a canonical record, it performs a no-clobber merge: provider/host/id and established origin remain canonical; registration/launch provenance may only be strengthened by the authoritative evidence class allowed by plan 057; mutable fields merge only through evidence-authorized transitions; incompatible owner/runtime evidence yields conflict with both observations preserved; timestamps never choose ownership.
- [ ] Canonical record keys are a fixed-format digest over provider, NUL, host id, NUL, and provider task id; paths are containment-checked beneath the metadata directory and never include raw provider ids. Matching tmux names, cwd values, or display titles do not cause filename or lookup collisions.
- [ ] `_session_list --json`, session attestation, snapshot output, app-list output, archive/title helpers, release, restore, close, backfill, and peer-derived discovery read through the normalized boundary where they are touched. Public JSON retains current legacy keys for the entire schema-v2 compatibility period; removal requires a separately reviewed schema version.
- [ ] Claude remains supported: legacy agent:claude normalizes to provider claude, uses conversation_id as provider_task_id when known, and keeps documented output and launch/snapshot behavior; removing list/doctor backfill is an intentional read-only safety change.

## Design

Define `_task_record_normalize_json`, `_task_record_key`, `_task_record_file`, `_task_record_promote_legacy`, and `_cctrl_host_id` as the canonical boundaries. `_task_record_normalize_json` validates types and refuses unsupported future schema versions. Persist provider-known tasks by the canonical digest key; retain tmux-named legacy files as immutable compatibility inputs and resolve canonical records before legacy records. Backfill that discovers a stable provider id invokes lazy promotion; a mutation with no stable id fails closed. Fresh launches use a generated provisional launch id and the promotion/no-clobber merge protocol above. Collection-sized JSON is composed through files/stdin or `--slurpfile`, never `jq --argjson`; this plan stays per-record and leaves aggregation to plan 064.

**Files expected to change:**

- `cctrl`: schema constants, durable host-id helper, v1 adapter, normalized task record writer/reader, and tmux launch metadata.
- `tests/run-tests.sh`: v1 compatibility, schema-v2 shape, host-id stability, collision, and unknown-state tests.
- `README.md`: machine identity and record-field compatibility notes.

Testing approach: unit-only

**Out of scope:** concurrency control for record updates, Codex hook ingestion, App Server RPC, fleet rendering, peer identities, and rewriting existing live records in bulk.

## Tasks

1. Define the exact schema-v2 types, enum/nullability rules, distinct fork/subagent/derived-root lineage fields, missing-version legacy mapping, and proposed normalization/key/file helper boundaries from plan 057's evidence rules.
2. Add `CCTRL_HOST_ID_FILE` and a validated, no-clobber host-id creator with winner/loser concurrency semantics and restrictive permissions.
3. Add the legacy-to-normalized adapter, canonical-first lookup, insufficient-identity failure, lazy legacy promotion, and provisional-to-canonical no-clobber/conflict merge without rewriting legacy files.
4. Route the named metadata consumers through the normalization boundary; separate identity-dependent refusal from identity-independent tmux actions, and remove list/doctor write-back while preserving output compatibility.
5. Update new Claude and Codex tmux metadata writes to emit typed ownership fields while preserving legacy public output fields.
6. Add isolated tests for malformed/wrong-type/future-version legacy records, read-only no-backfill, identity-dependent refusal, identity-independent tmux close, lazy promotion with/without stable id, typed ownership-evidence persistence, pre-existing canonical merge/conflict, Claude and Codex records, concurrent host-id creation, permissions, provisional promotion interruption, ambiguous evidence, host aliases, and same-cwd/same-title tasks.
7. Document the compatibility period and explicit non-meanings of `cctrl_managed` and `control_surface`.

## Verification

Checks:

- [cmd] `bash -n cctrl`
- [cmd] `bash tests/run-tests.sh`
- [assert] `rg -q "provider_task_id" cctrl`
- [assert] `rg -q "restore_strategy" cctrl`

<!-- mstack:seam
produced:
- kind: schema; name: task_record_v2; shape: "schema_version,provider,provider_task_id,origin,host_id,registered_by_cctrl,launched_by_cctrl,execution_runtime,control_owner,lifecycle_state,restore_strategy,last_observed_at,tmux_session,lineage,ownership_evidence"; file: cctrl
- kind: symbol; name: _cctrl_host_id; file: cctrl
- kind: symbol; name: _task_record_file; file: cctrl
- kind: symbol; name: _task_record_key; file: cctrl
- kind: symbol; name: _task_record_normalize_json; file: cctrl
- kind: symbol; name: _task_record_promote_legacy; file: cctrl
assumed:
- from: 057; kind: file; name: docs/findings/codex-task-lifecycle-contract.md; file: docs/findings/codex-task-lifecycle-contract.md
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
