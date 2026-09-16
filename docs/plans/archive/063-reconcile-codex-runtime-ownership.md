---
id: 063
title: Reconcile Codex runtime ownership from authoritative evidence
status: done
blocked-by: [059, 060, 062]
priority: 63
goal: codex-task-ownership-surfaces
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-15
completed: 2026-09-17
reviewed: false
qa: automated
tui-fixture: n/a  # reconciliation reads structured tmux metadata and never parses pane output
reviews:
  - type=eng verdict=approved date=2026-09-16 by=mstack-review
  - type=code verdict=pass date=2026-09-17 by=mstack-code-review
---

## Plain-English Summary

A task can outlive the process that first registered it and later move between the app and a CLI resume. This plan refreshes current ownership from live evidence while preserving where the task originally came from and surfacing conflicts instead of guessing.

**What changes in the code:** cctrl gains a non-destructive evidence pass that compares registry records with App Server state, tmux metadata, live owner processes, and diagnostic lock files. The default command updates only cctrl registry state after a complete evidence snapshot; `--dry-run` previews byte-for-byte without registry writes. No provider state or process is mutated.

## Requirements

Hooks provide lifecycle observations but cannot by themselves prove the current writer after a crash, restart, handoff, or resume elsewhere. Fleet and recovery need a current-owner view based on the evidence hierarchy from plan 057.

**Acceptance criteria:**

- [ ] `cctrl session reconcile-codex [--json] [--dry-run]` evaluates registered Codex tasks using plan 057's precedence rules.
- [ ] A live cctrl tmux owner with matching provider task id resolves to `execution_runtime:tmux` and `control_owner:cctrl`.
- [ ] Authoritative App Server runtime state with no competing cctrl owner resolves to `execution_runtime:app-server` and `control_owner:app`.
- [ ] Simultaneous credible owners produce `control_owner:conflict`. Confirmed authoritative absence may produce `unknown` or inactive; ambiguous but available evidence produces `unknown`; an unavailable/timed-out authoritative source preserves the last confirmed owner and records a stale/error observation rather than treating failure as absence.
- [ ] Writer-lock presence, cwd, title, recency, and argv substring matches can corroborate or diagnose but never claim ownership alone.
- [ ] Reconciliation preserves immutable origin and launch provenance, including app-to-CLI resume and cctrl-to-app handoff cases.
- [ ] Reconciliation preserves the record's distinct fork ancestry, subagent ancestry, and derived-root lineage; runtime evidence cannot rewrite or conflate those relations.
- [ ] App restart, terminal crash, host reboot, direct CLI resume, fork, and stale-lock fixtures produce the documented state without deleting locks or tasks.
- [ ] The default command performs no registry mutation until the complete evidence document has been built; it then applies only cctrl registry events. `--dry-run` never writes and produces the same proposed result document.
- [ ] Reconciliation never sends EOF, kills a process, quarantines a writer lock, archives a task, or changes provider settings.
- [ ] Partial App Server failure yields per-task stale/error details, preserves the last confirmed owner for affected tasks, and does not fail unrelated tasks.
- [ ] Every evidence document and `reconcile` event carries pass id, observation timestamp/source cursor, expected SHA-256 digest of the canonical record bytes (or absent sentinel), per-source status/confidence/error, chosen outcome, and reason. Plan 059 compares the digest under lock and rejects a stale pass without owner mutation so it cannot overwrite a newer hook/handoff event.
- [ ] One pass snapshots App Server, tmux, the process table, and the writer-lock directory once each and indexes them by provider task id; per-task rescans are forbidden.
- [ ] The `cctrl session reconcile` alias remains the legacy doctor-oriented flow and is explicitly labeled/deprecated in help; reconcile-codex is the non-destructive ownership-evidence command and never inherits doctor fix behavior.

## Design

Build one evidence document per provider task from one indexed snapshot per source, retaining the canonical record's byte digest, then pass a named, digest-guarded `reconcile` event to plan 059's reducer. Apply the explicit three-way truth table (confirmed absence, ambiguous available evidence, unavailable source). Keep destructive orphan-lock repair in `session doctor --fix`, outside reconciliation, and preserve the legacy `session reconcile` alias only with unambiguous deprecation/help text.

**Files expected to change:**

- `cctrl`: reconciliation command, evidence collection, reducer calls, dispatch, and help.
- `lib/codex_app_server.py`: any batch/list support required to avoid per-task connections.
- `tests/run-tests.sh`: app restart, CLI resume, conflict, stale lock, partial failure, and dry-run tests.
- `README.md`: ownership refresh and diagnostic meanings.

Testing approach: E2E

**Out of scope:** process termination, lock quarantine, automatic periodic daemons, peer delivery, or changing immutable origin after reconciliation.

## Tasks

1. Implement one indexed snapshot each from registry, App Server, tmux, processes, and diagnostic locks; prohibit per-task source rescans.
2. Define the evidence/result schema, canonical-record digest CAS guard, and three-way source truth table, then encode plan 057's precedence into explicit outcomes.
3. Add dry-run and JSON output before enabling reducer writes.
4. Route confirmed/unknown/conflict outcomes through plan 059 without changing provenance.
5. Add source-failure preservation, stale-pass rejection, partial-failure isolation, dry-run byte-identity, and lifecycle transition fixtures under temporary cctrl data/metadata roots.
6. Document `reconcile-codex` versus the legacy `session reconcile` alias, doctor, and release-to-app; include stable exit codes.
7. Hash the real live store before and after tests and prove reconciliation fixtures do not touch it.

## Verification

Checks:

- [cmd] `bash -n cctrl`
- [cmd] `python3 -m py_compile lib/codex_app_server.py`
- [cmd] `bash tests/run-tests.sh`
- [cmd] `./cctrl session reconcile-codex --help | rg -q -- "--dry-run"`
- [cmd] `CCTRL_TEST_ONLY=codex-reconcile bash tests/run-tests.sh`

<!-- mstack:seam
produced:
- kind: schema; name: codex_reconcile_result_v1; shape: "pass_id,observed_at,expected_record_digest,sources,outcome,reason,errors"; file: cctrl
- kind: symbol; name: _session_reconcile_codex; file: cctrl
assumed:
- from: 059; kind: symbol; name: _task_registry_apply_event; file: cctrl
- from: 060; kind: symbol; name: AppServerClient; file: lib/codex_app_server.py
- from: 062; kind: schema; name: codex_lifecycle_observation; file: hooks/codex-session-observer.py
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

## Implementation Notes

Implemented snapshot-first, exact-id Codex ownership reconciliation across canonical local registry records, paginated App Server inventory, tmux metadata, process evidence, and diagnostic locks. Added conservative unavailable-versus-absent handling, conflict/unknown outcomes, last-owner preservation, digest-guarded registry events, byte-identical dry-run proposals, partial-failure isolation, stable help/exits, and documentation. Local unified review fixed three high-confidence issues: malformed available sources could imply false absence, reused tmux names lacked a current receipt anchor, and registry input lacked strict local-host/canonical-key filtering; the external reviewer was unavailable and the fallback is recorded in the review artifact. Health scored 10.0, all five verification checks passed, the final full suite passed 202 milestones, and the actual live `data/` digest remained unchanged.

**Files changed:**

- `README.md` (modified)
- `cctrl` (modified)
- `docs/plans/063-reconcile-codex-runtime-ownership.md` (modified)
- `lib/codex_app_server.py` (modified)
- `tests/run-tests.sh` (modified)

**Commit:** `b6cdbdc` — `feat(codex): reconcile runtime ownership safely`
