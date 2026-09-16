---
id: 062
title: Register Codex tasks from lifecycle events without claiming them
status: pending
blocked-by: [059, 061]
priority: 62
goal: codex-task-ownership-surfaces
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-15
tui-fixture: n/a  # no tmux pane parsing; tmux appears only as an ownership value
reviews:
  - type=eng verdict=approved date=2026-09-16 by=mstack-review
---

## Plain-English Summary

Tasks created with the Codex app's plus button currently bypass cctrl completely. This plan lets cctrl notice and register them after Codex supplies a real task id, while leaving their model, permissions, sandbox, and app ownership untouched.

**What changes in the code:** The observer converts supported Codex lifecycle payloads into normalized registry events. Duplicate, delayed, resume, clear, compact, fork, and end events update one durable record without creating a tmux owner or changing task settings.

## Requirements

Hook execution is evidence that a Codex lifecycle event occurred, not proof that the app created the task. Registration must preserve uncertainty until an authoritative source kind or a matching cctrl launch record establishes origin.

**Acceptance criteria:**

- [ ] Supported hook payloads with a provider task id produce normalized `register` or `observe` events through plan 059's reducer.
- [ ] A task positively identified as native app-created is stored with `origin:codex-app`, `registered_by_cctrl:true`, `launched_by_cctrl:false`, `execution_runtime:app-server`, `control_owner:app`, and provider-managed restore.
- [ ] A hook event that could also come from unmanaged CLI is recorded as `origin:unknown` or `external-cli` according to plan 057; it is never guessed to be app-created.
- [ ] A payload without a stable task id exits successfully and creates no synthetic record. A later first-prompt event may create the first record for an empty app task.
- [ ] Startup, resume, clear, compact, fork, fork-of-fork, and SessionEnd sequences follow the documented identity/parent rules. Normalization preserves provider forkedFromId as forked_from_id and provider subagent parentThreadId as parent_thread_id; it computes derived_root_id only by explicit ancestry traversal with a recorded derivation basis.
- [ ] SessionEnd marks observation/lifecycle state but does not delete the record, archive the Codex task, or rewrite immutable origin.
- [ ] Repeated and out-of-order payloads converge to the same result; a late generic observer event cannot overwrite cctrl launch provenance.
- [ ] No handler changes the Codex task's model, reasoning effort, cwd, sandbox, approval policy, title, archive state, or the record's control owner.
- [ ] Handler failures are logged actionably but fail open so they do not prevent Codex from starting or accepting a prompt.
- [ ] The hook passes exactly one allowlisted, size-bounded JSON envelope over stdin to hidden cctrl session ingest-event; it never uses eval, argv interpolation, or shell expansion. The new ingestion helper calls plan 059's registry API, uses stable reason codes, and has a hard timeout.
- [ ] Ignored/unsupported events return zero. Reducer, lock-timeout, PATH, or persistence failures are logged and fail open at the hook boundary without guessing/rolling back ownership; plan 063 reconciliation repairs missed observations, and this plan adds no unbounded spool/retry queue.
- [ ] Tests export temporary `CCTRL_DATA_DIR` and `CCTRL_SESSION_METADATA_DIR`, replay sanitized plan-057 fixtures only against those roots, and prove by before/after digest that the real live store is untouched.

## Design

Keep `normalize_codex_lifecycle_event(payload)` in `hooks/codex-session-observer.py`, one hidden stdin-based ingestion command, and ownership transitions in the central reducer. Use source-kind evidence from plan 057 when available; otherwise preserve `unknown`. Preserve fork ancestry and subagent ancestry in separate normalized fields; derive a root only by traversing recorded fork ancestry and retain the derivation basis. Lineage ids are relations, never deduplication substitutes. Event JSON moves through stdin/files, never `jq --argjson` or shell/argv interpolation.

**Files expected to change:**

- `hooks/codex-session-observer.py` (created by plan 061; modified here): lifecycle normalization and registry-event emission.
- `cctrl`: internal registry event command callable by the hook.
- `tests/run-tests.sh`: lifecycle replay, idempotence, ordering, fail-open, and no-settings-mutation tests.
- `tests/fixtures/codex-lifecycle/`: expected normalized records for each sequence.

Testing approach: E2E

**Out of scope:** installing hooks globally, forcing every empty `+` click to create a record before Codex assigns an id, runtime-owner reconciliation, peer registration, or app setting changes.

## Tasks

1. Map each validated hook event into the plan-059 event envelope with explicit source confidence.
2. Add hidden `cctrl session ingest-event`, `_session_ingest_event(event_file)`, stable result codes, stdin-only framing, a hard timeout, and safe subprocess invocation from the observer.
3. Implement lifecycle, distinct fork/subagent lineage, derived-root traversal, end, and no-id handling without surface-setting mutations.
4. Add fail-open logging with no sensitive payload capture and reconciliation-based recovery for lost events.
5. Replay duplicates, concurrent invocations, reverse/cursorless/cursor-bearing ordering, equal-authority conflicts, SessionEnd-before-start, resume, clear, compact, fork, fork-of-fork, end, command-not-found, reducer-timeout, and write-failure fixtures.
6. Assert app records are registered but never marked cctrl-launched or tmux-restorable.

## Verification

Checks:

- [cmd] `python3 -m py_compile hooks/codex-session-observer.py`
- [cmd] `bash -n cctrl`
- [cmd] `bash tests/run-tests.sh`
- [cmd] `CCTRL_TEST_ONLY=codex-lifecycle bash tests/run-tests.sh`

<!-- mstack:seam
produced:
- kind: schema; name: codex_lifecycle_observation; shape: "provider,provider_task_id,origin,source,confidence,forked_from_id,parent_thread_id,derived_root_id,derived_root_basis,lifecycle_state"; file: hooks/codex-session-observer.py
- kind: symbol; name: _session_ingest_event; shape: "event_file"; file: cctrl
- kind: symbol; name: normalize_codex_lifecycle_event; shape: "payload"; file: hooks/codex-session-observer.py
assumed:
- from: 059; kind: schema; name: task_registry_event; shape: "event_id,event_type,provider,provider_task_id,host_id,source,source_instance_id,source_sequence,source_cursor,expected_record_digest,observed_at,payload"; file: cctrl
- from: 059; kind: symbol; name: _task_registry_apply_event; shape: "record_key,event_file"; file: cctrl
- from: 061; kind: file; name: hooks/codex-session-observer.py; file: hooks/codex-session-observer.py
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
