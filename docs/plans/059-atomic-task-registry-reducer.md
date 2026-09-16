---
id: 059
title: Make task registry updates atomic and order-independent
status: in-progress
blocked-by: [057, 058]
priority: 59
goal: codex-task-ownership-surfaces
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-15
reviews:
  - type=eng verdict=approved date=2026-09-16 by=mstack-review
---

## Plain-English Summary

Codex lifecycle events and cctrl commands can update the same task at nearly the same time. This plan prevents one update from erasing another and ensures delayed or duplicate events cannot move a task backward to an older ownership state.

**What changes in the code:** All task-record mutations go through a per-record lock and a single event reducer. Writes remain atomic, immutable provenance fields are protected, and concurrent or repeated events converge on the same record.

## Requirements

The existing single-field helper uses atomic rename but performs an unlocked read-modify-write, so two valid writers can lose each other's changes. Native app observation adds more writers and makes this race a correctness issue.

**Acceptance criteria:**

- [ ] Every schema-v2 mutation uses one registry API; direct ad-hoc JSON rewrites of task records are rejected by tests or removed from the relevant paths.
- [ ] Per-task locking works on macOS without assuming GNU `flock`; acquisition, stale-owner handling, timeout behavior, and release are documented and tested.
- [ ] The lock protects the entire read-reduce-write cycle, and the final file is replaced atomically from a same-directory temporary file.
- [ ] Every transition is intrinsically idempotent and canonical for duplicate lifecycle events and deterministic for out-of-order events. The bounded event-id cache is only an optimization: cursor-bearing mutations below the stored high-water mark are rejected, while cursorless inputs and cache-evicted replays reduce through set/canonical-fingerprint semantics that preserve the same result.
- [ ] The versioned event envelope contains event_id, event_type, provider, provider_task_id, host_id, source, source_instance_id, optional monotonic source_sequence/source_cursor, optional expected_record_digest, observed_at, and payload. Per-source trusted cursor high-water marks prevent regression; wall-clock and arrival order never prove ownership; a cursorless source may add only immutable-identical facts or union a canonical observation/conflict fingerprint and cannot supersede an authoritative owner.
- [ ] Under the per-record lock, any event that can change owner/runtime compares expected_record_digest with the SHA-256 digest of the canonical record bytes read for reduction. A matching digest admits the requested transition. A mismatch never applies the requested owner/runtime directly: an unrelated stale event returns a stable stale result, while a contradictory same-authority event whose basis digest matches a preserved ownership observation is reduced to canonical conflict evidence and `control_owner:conflict`. Creation requires the explicit absent-record sentinel.
- [ ] Immutable provider, provider_task_id, origin, host_id, and launched_by_cctrl cannot be downgraded or silently changed by an observer event.
- [ ] Mutable owner/runtime changes require an event type authorized by plan 057's precedence table. Weak diagnostic evidence can update observations but not claim ownership.
- [ ] Every accepted owner-changing event preserves a bounded canonical ownership observation containing its basis record digest, authority class, source identity/cursor, event fingerprint, and proposed owner/runtime/state. A later contradictory event with the same basis digest unions both sorted fingerprints and sets the conflict state without applying the later requested owner; reversing arrival order or replaying after event-cache eviction produces byte-identical conflict evidence and state. Explicit conflicts require reconciliation; last-write-wins is not used for ownership.
- [ ] Malformed records remain untouched and produce an actionable error. Missing records are created only by explicit register/create events.
- [ ] A deterministic concurrency test proves that different-field writers lose no updates and that only one reducer holds the critical section at a time.
- [ ] Same-authority contradictory events produce one canonical conflict independent of replay order. Event-id cache and canonical conflict observations are explicitly bounded; source cursors retain one high-water mark per bounded, allowlisted source instance so a long-lived record cannot grow without limit.
- [ ] All tests use temporary metadata/data roots and never mutate cctrl's live gitignored mailbox or session records.

## Design

Implement registry-specific `_task_registry_lock_*` helpers using the reviewed mechanics from plan 049, without depending on or copying its mailbox/watch functions as callable artifacts: `shlock` when available and an atomic-link fallback with a unique owner token in a mode-`0700` lock directory. Only the matching token may release; dead-owner reclamation requires a grace period and recheck; live or unverifiable ownership fails closed; acquisition has a configurable hard timeout. Represent updates as named events (`register`, `observe`, `launch`, `handoff`, `reconcile`, `end`) using the exact envelope, high-water mark, and intrinsic-idempotency rules above. Treat digest comparison as an admission guard for the requested mutation, not as permission to discard competing evidence: each accepted ownership mutation stores its basis digest and canonical fingerprint, and a same-basis contradiction converges to the same sorted conflict set in either arrival order. Feed arbitrary record/event JSON through files, stdin, or `--slurpfile`, never `jq --argjson`.

The canonical boundaries are pure `_task_registry_reduce(record_json,event_json)`, `_task_registry_apply_event(record_key,event_file)`, and `_task_registry_lock_acquire`/`_task_registry_lock_release`. The concurrent test harness must be safe under `set -euo pipefail`: do not use an unguarded `xargs -P`; collect every child status explicitly behind deterministic barriers.

**Files expected to change:**

- `cctrl`: registry lock helpers, normalized event reducer, atomic record writer, and replacement for `_session_update_metadata_field` on schema-v2 paths.
- `tests/run-tests.sh`: duplicate, out-of-order, malformed-record, stale-lock, and deterministic concurrency tests.
- `tests/fixtures/codex-lifecycle/`: event sequences and expected reduced records.

Testing approach: E2E

**Out of scope:** changing mailbox locking, installing hooks, discovering runtime ownership, or modifying live user records during installation.

## Tasks

1. Define the exact versioned event envelope, canonical-record digest/absent sentinel, locked CAS outcome, authority/sequence transition table, intrinsic-idempotency rules, canonical conflict fingerprints, bounded event cache, and bounded-source cursor high-water marks using plans 057 and 058.
2. Implement registry-specific per-record lock helpers with plan-049-reviewed mechanics, token-checked release, stale detection/recheck, bounded timeout, and cleanup.
3. Implement locked read-reduce-atomic-write with immutable-field and malformed-record safeguards.
4. Route schema-v2 metadata mutations through the registry API while preserving v1 compatibility.
5. Add deterministic concurrent writers and replay-permutation tests in isolated directories, including stale/live locks, timeouts, immutable-field attacks, weak evidence, conflicts, malformed/missing records, and termination after temp creation but before rename.
6. Add structural checks preventing new direct schema-v2 rewrites outside the registry boundary.
7. Hash the real live store before and after the suite and prove it is unchanged.

## Verification

Checks:

- [cmd] `bash -n cctrl`
- [cmd] `bash tests/run-tests.sh`
- [assert] `rg -q "_task_registry_apply_event" cctrl`
- [assert] `rg -q "_task_registry_reduce" cctrl`

<!-- mstack:seam
produced:
- kind: schema; name: task_registry_event; shape: "event_id,event_type,provider,provider_task_id,host_id,source,source_instance_id,source_sequence,source_cursor,expected_record_digest,observed_at,payload"; file: cctrl
- kind: symbol; name: _task_registry_apply_event; shape: "record_key,event_file"; file: cctrl
- kind: symbol; name: _task_registry_lock_acquire; file: cctrl
- kind: symbol; name: _task_registry_lock_release; file: cctrl
- kind: symbol; name: _task_registry_reduce; shape: "record_json,event_json"; file: cctrl
assumed:
- from: 057; kind: file; name: docs/findings/codex-task-lifecycle-contract.md; file: docs/findings/codex-task-lifecycle-contract.md
- from: 058; kind: schema; name: task_record_v2; shape: "schema_version,provider,provider_task_id,origin,host_id,registered_by_cctrl,launched_by_cctrl,execution_runtime,control_owner,lifecycle_state,restore_strategy,last_observed_at,tmux_session,lineage,ownership_evidence"; file: cctrl
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
