---
id: 067
title: Make Codex terminal-to-app handoff an explicit safe transition
status: pending
blocked-by: [063, 064, 065]
priority: 67
goal: codex-task-ownership-surfaces
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-15
tui-fixture: n/a  # no pane-text parsing; tmux is inspected only as process/ownership evidence
reviews:
  - type=eng verdict=approved date=2026-09-16 by=mstack-review
---

## Plain-English Summary

Opening a cctrl-owned tmux task in the app is not simultaneous access; the terminal writer has to stop first. This plan makes that handoff a verified state transition, preserves the same provider task, and reports incomplete or conflicted handoffs instead of claiming success too early.

**What changes in the code:** `release-to-app` validates that cctrl owns the exact task, asks the terminal process to exit, waits for authoritative exit evidence, and then commits one registry transition. Native app tasks and app-owned cctrl launches are recognized as already app-owned rather than being duplicated or forcibly changed.

## Requirements

The existing release workflow can send EOF and quarantine a stale writer lock, but metadata and process state must move together. An interrupted command or blocking approval must not leave the registry saying app-owned while a cctrl writer still lives.

**Acceptance criteria:**

- [ ] `cctrl session release-to-app <target>` resolves one cctrl-launched Codex tmux task by stable provider identity before sending any input.
- [ ] It rejects native observed app tasks and unmanaged CLI tasks as non-transferable. An app-owned cctrl task returns an idempotent no-op.
- [ ] Before EOF, targeted reconciliation plus plan-060 App Server evidence proves that the same provider task exists and is app-openable/provider-restorable. After owner exit, a fresh evidence snapshot must prove the same postcondition before app ownership is committed.
- [ ] The terminal owner receives one graceful EOF/exit request and cctrl waits for the matching process/tmux owner to end; no new provider task is created.
- [ ] Only after authoritative owner exit does one `handoff` event set `execution_runtime:app-server`, `control_owner:app`, and provider-managed restore while preserving `origin:cctrl` and provider task id.
- [ ] Resolve captures provider task id, host id, baseline canonical-record SHA-256 digest, tmux session id, pane/child pid, and process-start identity. The baseline guards revalidation after confirmation and before EOF. After exact owner exit and provider postflight, cctrl re-reads the record: only same-task, non-owner-changing SessionEnd/observation updates from this shutdown are admissible, then a fresh digest guards the handoff event. Ownership/provenance changes become conflict.
- [ ] Timeout, blocking approval, process mismatch, or simultaneous credible app/CLI ownership produces an actionable incomplete/conflict result and does not falsely commit app ownership.
- [ ] Writer-lock quarantine remains a separate, evidence-gated repair after owner exit; lock presence alone is never proof that handoff failed or succeeded.
- [ ] Interrupting the command between exit request and registry commit is recoverable by `reconcile-codex` without creating a duplicate or changing origin.
- [ ] `--json` reports previous state, requested transition, verified owner exit, resulting state, and any required user action.
- [ ] Opening an app-owned task never reports that cctrl/tmux still owns it. Attach consults normalized task records before its early no-active-tmux return; a released task produces an app-opening hint rather than recreating tmux automatically.
- [ ] The interactive/`--yes` confirmation remains. Output shows the resolved provider identity before confirmation and revalidates it afterward. Without pane parsing, a blocking approval is reported conservatively as `owner-exit-timeout` with instructions to reopen the terminal and resolve it.
- [ ] Tests cover success, app-owned idempotent no-op, wrong origin, confirmation decline, provider missing/archived/unavailable, blocked approval timeout, tmux-name/PID reuse, concurrent hook/reconcile, reducer failure after exit, interruption/reconcile, conflict, stale lock, retry idempotence, and exact-task/no-duplicate guarantees.
- [ ] Tests export temporary cctrl data, session-metadata, host-id, and Codex-home paths, then prove the real live-store digest is unchanged.

## Design

Treat handoff as a two-checkpoint compare-and-set state machine: resolve/baseline digest -> `reconcile-codex --dry-run` and exact provider+host selection -> provider preflight -> confirm/baseline revalidation -> one exit -> exact owner gone -> provider postflight -> classify admissible SessionEnd-only record changes -> fresh digest -> reduce handoff -> report. Preflight reconciliation never writes. Keep quarantine behind confirmation/doctor safety rules and never use cwd/name matching.

**Files expected to change:**

- `cctrl`: `_session_release_to_app`, stable task resolution, handoff event, state-machine output, attach guard, and help.
- `tests/run-tests.sh`: lifecycle state-machine, interruption, conflict, and no-duplicate tests.
- `README.md`: one-way writer handoff semantics and recovery instructions.

Testing approach: E2E

**Out of scope:** app-to-tmux automatic takeover, concurrent writable owners, force-killing unknown processes, native app task settings, or peer delivery.

## Tasks

1. Resolve through stable provider linkage, capture the baseline digest/owner fingerprint, run dry-run reconciliation and select the exact provider+host result, then run App Server preflight and validate the transferable class.
2. Preserve confirmation, revalidate the fingerprint, then implement one exit request and exact tmux/process-owner verification with bounded timeout.
3. Run provider postflight, re-read/classify only admissible same-task shutdown observations, capture a fresh digest, and commit the registry handoff; make the app-owned case and retry attempt idempotent.
4. Add conflict/incomplete JSON output and reconciliation recovery for interrupted transitions.
5. Guard attach before the no-active-tmux early return from silently recreating a released terminal owner.
6. Add exhaustive isolated fake App Server/tmux/process/lock lifecycle and race tests, live-store digest checks, and handoff documentation.

## Verification

Checks:

- [cmd] `bash -n cctrl`
- [cmd] `bash tests/run-tests.sh`
- [cmd] `./cctrl session release-to-app --help | rg -q "app"`
- [cmd] `CCTRL_TEST_ONLY=codex-handoff bash tests/run-tests.sh`

<!-- mstack:seam
produced:
- kind: schema; name: codex_handoff_result_v1; shape: "attempt_id,provider_task_id,previous_state,requested_transition,owner_exit,provider_postcondition,resulting_state,required_action,error"; file: cctrl
- kind: symbol; name: _session_release_to_app; file: cctrl
assumed:
- from: 059; kind: schema; name: task_registry_event; shape: "event_id,event_type,provider,provider_task_id,host_id,source,source_instance_id,source_sequence,source_cursor,expected_record_digest,observed_at,payload"; file: cctrl
- from: 059; kind: symbol; name: _task_registry_apply_event; shape: "record_key,event_file"; file: cctrl
- from: 060; kind: symbol; name: AppServerClient; file: lib/codex_app_server.py
- from: 063; kind: schema; name: codex_reconcile_result_v1; shape: "pass_id,observed_at,expected_record_digest,sources,outcome,reason,errors"; file: cctrl
- from: 063; kind: symbol; name: _session_reconcile_codex; file: cctrl
- from: 064; kind: symbol; name: _task_list_json; file: cctrl
- from: 065; kind: schema; name: app_owned_launch_result_v1; shape: "partial,task_creation_outcome,provider_task_id,host_id,owner,runtime,turn_outcome,registry_persisted,open_hint,error"; file: cctrl
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
