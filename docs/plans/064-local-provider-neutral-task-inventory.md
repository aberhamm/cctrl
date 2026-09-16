---
id: 064
title: Add a local provider-neutral task inventory
status: in-progress
blocked-by: [058, 063]
priority: 64
goal: codex-task-ownership-surfaces
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-15
tui-fixture: n/a  # inventory consumes structured tmux metadata and never parses pane text
reviews:
  - type=eng verdict=approved date=2026-09-16 by=mstack-review
---

## Plain-English Summary

The current session list shows tmux workers, while app tasks live in a separate Codex-only command. This plan provides one local catalogue that shows both without pretending they have the same controls or merging unrelated tasks that happen to use the same project folder.

**What changes in the code:** A normalized local task-list function joins cctrl records, live tmux sessions, and discoverable Codex provider tasks by stable identity. Existing tmux commands remain compatible, while app-ls becomes a filtered view of the shared catalogue.

## Requirements

Users need to see whether a task is cctrl-owned, app-owned, merely observed, inactive, or conflicted before choosing attach, open, handoff, or restore actions. A single state label such as `locked` is insufficient and can be actively misleading.

**Acceptance criteria:**

- [ ] `cctrl task ls [--json]` returns local tmux sessions and Codex app/provider tasks through one normalized schema.
- [ ] JSON output is a versioned top-level envelope with schema version 2, capabilities, rows, and source errors; every row follows the task-list schema below.
- [ ] Each row includes provider task id, durable host id, origin, execution runtime, control owner, lifecycle state, restore strategy, registration/launch provenance, distinct lineage, bounded ownership evidence, diagnostic evidence, recency, cwd, display title, and nullable tmux session.
- [ ] Capability fields state whether the row can be tmux-attached, opened in the app, handed off, or restored by cctrl; unsupported actions are not inferred from state labels.
- [ ] Deduplication uses provider task id plus host identity and explicit tmux/provider linkage only. Same cwd, title, prompt, recency, or tmux-like name never merges tasks.
- [ ] Row identity follows an explicit table: provider-known rows use provider plus durable host id plus provider task id; provisional launches use plan 058's launch id; tmux-only rows use durable host id plus tmux `#{session_id}` as an observation key; discovery-only rows use provider identity. A tmux display name is never an identity, and provisional rows promote only through plan 058.
- [ ] Discovery-only Codex rows remain visible and are labeled unregistered/unknown rather than silently claimed by cctrl.
- [ ] Writer-lock presence from `cctrl::_codex_app_threads_json` is exposed only as diagnostic evidence and never rendered as the control owner.
- [ ] `cctrl session app-ls` remains a Codex filtered view: default rows satisfy provider codex plus registered_by_cctrl; `--all` also includes discovery-only and archived provider rows, without filtering solely on app ownership.
- [ ] `cctrl::_session_list` JSON and mutating tmux commands retain their documented tmux-target behavior during the compatibility window.
- [ ] Archived, inactive, conflict, unknown, app-owned, and cctrl-owned fixtures render distinctly in human and JSON modes.
- [ ] Listing never mutates task records or provider state. The sole allowed first-use side effect is plan 058's atomic durable host-id creation before rows are built; it is reported as `host_id_initialized:true`. No archive, release, repair, reconciliation, or metadata backfill occurs.
- [ ] The new read-only tmux collector does not call `_session_list` backfill paths. Inventory tests prove byte identity of metadata, registry, and provider DB before/after listing and isolate/verify the one-time host-id file creation separately.
- [ ] Top-level capabilities describe source/command support. Each row has an action-capability map, with every action shaped `{supported:boolean, reason:string}`. Attach requires a live explicitly linked cctrl tmux owner. App-open requires a nonarchived provider task, available provider surface, no conflict, and owner app or inactive/provider-managed state; cctrl-owned yields false/`owned-by-cctrl`, archived false/`archived`, provider-unavailable false/`provider-unavailable`, and unknown/conflict false with matching reason. Handoff/restore stay false/`not-implemented` until plans 067/068 enable their exact predicates.
- [ ] Source errors are represented per source with partial rows preserved. Total inability to read every source is nonzero; one failed source does not become an empty-success inventory or erase rows from healthy sources.
- [ ] Fusion precedence is deterministic: explicit stable linkage, registry provenance, and plan-063 evidence are compared; contradictory explicit links produce conflict rather than last-source-wins.

## Design

Create provider-neutral `_task_list_json` plus non-mutating `_task_tmux_rows_json_readonly`, and keep legacy `_session_list` for tmux-targeted operations. Apply the explicit row-identity, fusion, capability, and source-error tables above. Join normalized sources through stdin/files rather than oversized `jq --argjson` values. Keep provider discovery tolerant of SQLite column/version drift, while surfacing failure instead of silently substituting an empty source.

**Files expected to change:**

- `cctrl`: task list command, normalized join, app-ls filter, capability computation, help, and rendering.
- `tests/run-tests.sh`: identity joins, non-merges, discovery-only rows, state/capability rendering, and legacy session-ls compatibility.
- `README.md`: task versus tmux-session terminology and examples.

Testing approach: E2E

**Out of scope:** cross-host federation, app-owned task creation, changing provider state while listing, peer visibility, or removing `session ls`.

## Tasks

1. Define the local task-list envelope, task-list row schema, row identity, top-level versus per-row capability/reason, source-error, and fusion-precedence contracts from plans 058 and 063.
2. Initialize/read the durable host id once, add a no-backfill tmux collector, then normalize live tmux rows, registry records, and Codex provider-discovery rows without task/provider writes.
3. Join only on stable identity; emit conflict on contradictory linkage; compute explicit action capabilities with future actions disabled.
4. Add `cctrl task ls` plus human/JSON rendering and implement app-ls as a filter.
5. Preserve legacy session-ls consumers and test schema/version drift in Codex SQLite fixtures.
6. Add null-provider-id, provisional promotion, recycled tmux name, contradictory link, source-failure, ambiguity, conflict, archive, inactive, same-cwd non-merge, future-capability-disabled, and before/after byte-identity tests.
7. Export temporary `CCTRL_DATA_DIR`, `CCTRL_SESSION_METADATA_DIR`, and `CCTRL_HOST_ID_FILE` for tests and prove the real live stores are unchanged.

## Verification

Checks:

- [cmd] `bash -n cctrl`
- [cmd] `bash tests/run-tests.sh`
- [cmd] `./cctrl task ls --help | rg -q -- "--json"`
- [cmd] `./cctrl session app-ls --help | rg -q -- "--all"`
- [cmd] `CCTRL_TEST_ONLY=task-inventory bash tests/run-tests.sh`

<!-- mstack:seam
produced:
- kind: schema; name: task_list_v2; shape: "schema_version,capabilities,rows,source_errors"; file: cctrl
- kind: schema; name: task_list_row_v2; shape: "provider,provider_task_id,host_id,origin,execution_runtime,control_owner,lifecycle_state,restore_strategy,registered_by_cctrl,launched_by_cctrl,lineage,ownership_evidence,diagnostic_evidence,recency,cwd,title,tmux_session,action_capabilities"; file: cctrl
- kind: symbol; name: _task_list_json; file: cctrl
- kind: symbol; name: _task_tmux_rows_json_readonly; file: cctrl
assumed:
- from: 058; kind: schema; name: task_record_v2; shape: "schema_version,provider,provider_task_id,origin,host_id,registered_by_cctrl,launched_by_cctrl,execution_runtime,control_owner,lifecycle_state,restore_strategy,last_observed_at,tmux_session,lineage,ownership_evidence"; file: cctrl
- from: 063; kind: schema; name: codex_reconcile_result_v1; shape: "pass_id,observed_at,expected_record_digest,sources,outcome,reason,errors"; file: cctrl
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
