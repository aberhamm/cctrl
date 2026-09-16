---
id: 057
title: Establish the Codex lifecycle and ownership signal contract
status: in-progress
blocked-by: []
priority: 57
goal: codex-task-ownership-surfaces
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-15
tui-fixture: n/a  # this plan inventories tmux metadata/process evidence but never parses pane text
reviews:
  - type=eng verdict=approved date=2026-09-16 by=mstack-review
---

## Plain-English Summary

Before cctrl can label a Codex task as app-owned or terminal-owned, it must know which signals Codex actually exposes and which are only hints. This plan records that evidence and defines conservative rules so later work never mistakes a lock file, working directory, or hook event for proof of ownership.

**What changes in the code:** A versioned lifecycle contract and reproducible fixtures are added for the Codex App Server, hook payloads, local state database, rollout files, processes, and writer locks. The contract explicitly covers native app creation, cctrl terminal creation, cctrl app-owned creation, resume, fork, restart, handoff, and ambiguous states.

## Requirements

The user currently experiences a task as inaccessible when another Codex process owns its writer. cctrl needs an evidence hierarchy that distinguishes three intended paths without promising simultaneous writable access or inferring ownership from weak signals.

**Acceptance criteria:**

- [ ] `docs/findings/codex-task-lifecycle-contract.md` contains a matrix for native app `+`, native app first prompt, cctrl tmux launch, `--remote unix://`, direct CLI resume, cctrl app-owned launch, app restart, host reboot, clear, compact, fork, fork-of-fork, and `release-to-app`.
- [ ] The matrix identifies the stable provider task id and parent/root relationship fields available from App Server methods, hooks, SQLite, rollout files, and cctrl metadata.
- [ ] Lineage records preserve provider meaning: forkedFromId is fork ancestry, parentThreadId is subagent ancestry, and any root id is labeled as derived by traversal rather than provider-exposed.
- [ ] Every signal is classified as authoritative, corroborating, or diagnostic-only. Writer-lock presence, cwd, title, and process argv are never authoritative by themselves.
- [ ] The contract defines `unknown` and `conflict` outcomes when evidence cannot prove one owner; it never resolves ambiguity by cwd, title, recency, or name similarity.
- [ ] Empty app `+` behavior is recorded separately from first-prompt behavior. If no task id exists yet, cctrl records nothing rather than minting a fake identity.
- [ ] Hook behavior is documented for startup, resume, clear, compact, fork, app-server, and CLI sources, including GUI PATH/trust constraints and the possibility that user-level hooks run for more than one surface.
- [ ] The single-writer limitation is explicit: cctrl can transfer or report ownership, but it cannot make one Codex task concurrently writable from tmux and the app.
- [ ] Cross-device behavior is scoped correctly: cctrl records the connected host that owns the task; Codex remote connections determine whether another device can open that host while it is awake.
- [ ] Reproducible, sanitized lifecycle fixtures are added under the fixture directory declared in Design; no account identifiers, tokens, or private paths are committed.
- [ ] Every fixture has one manifest entry containing Codex CLI/app version, source, capture method, observation time, lifecycle scenario, field status (`observed`, `derived`, or `unsupported`), sanitization placeholders, and refresh/invalidation rules.
- [ ] Disposable probes set temporary `CCTRL_DATA_DIR` and `CCTRL_SESSION_METADATA_DIR`, record a before/after digest of the real live store, declare any expected Codex-owned state delta, and include cleanup instructions. An executable allowlist-based privacy scan rejects tokens, account identifiers, home-directory paths, and unapproved absolute paths.

## Design

Use official App Server schemas/documentation plus read-only inspection of current local Codex state. Any disposable live probe must use a clearly named test task and record its cleanup requirements; it must not alter an existing user task. The contract is the source of truth for later attribution policy, not a narrative appendix.

Use one canonical matrix schema and one fixture-manifest schema. Anchor the investigation in `_launch_exec_agent`, `_session_write_metadata`, `_session_codex_rollout_path`, `_codex_rollout_thread_id`, `_codex_app_threads_json`, `_codex_thread_writer_lock_path`, `_codex_writer_lock_is_stale`, and `_session_release_to_app`. Fixture validation reads JSON from files or stdin (`jq -e FILE`, `--slurpfile`, or Python), never by passing whole documents through `jq --argjson`.

**Files expected to change:**

- docs/findings/codex-task-lifecycle-contract.md
- tests/fixtures/codex-lifecycle
- tests/run-tests.sh

## Testing Strategy

Testing approach: unit-only

**Out of scope:** implementing a registry, changing global hooks, creating production app-owned tasks, changing peer identity, or attempting concurrent multi-writer access.

## Tasks

1. Inventory the current Codex CLI/app versions and generate or inspect the official App Server method schemas, distinguishing `forkedFromId`, subagent `parentThreadId`, and derived root lineage.
2. Create the canonical matrix and fixture-manifest schemas; capture sanitized examples for each available lifecycle source and explicitly record unavailable or version-dependent fields.
3. Exercise or conservatively document the native app empty-task versus first-prompt boundary, resume, fork, restart, and terminal-owner cases.
4. Run disposable probes only with temporary cctrl data/metadata paths, before/after live-store digests, declared Codex deltas, and cleanup instructions.
5. Write the evidence precedence and ambiguity truth table, including cross-host and cross-device boundaries.
6. Add completeness, provenance, lineage, and privacy validation tests and document how a future Codex version change invalidates or refreshes the contract.

## Verification

Checks:

- [cmd] `test -f docs/findings/codex-task-lifecycle-contract.md`
- [cmd] `test -d tests/fixtures/codex-lifecycle`
- [assert] `rg -q "authoritative" docs/findings/codex-task-lifecycle-contract.md`
- [assert] `rg -q "corroborating" docs/findings/codex-task-lifecycle-contract.md`
- [assert] `rg -q "diagnostic-only" docs/findings/codex-task-lifecycle-contract.md`
- [assert] `rg -q "unknown" docs/findings/codex-task-lifecycle-contract.md`
- [assert] `rg -q "conflict" docs/findings/codex-task-lifecycle-contract.md`
- [assert] `rg -q "forkedFromId" docs/findings/codex-task-lifecycle-contract.md`
- [assert] `rg -q "parentThreadId" docs/findings/codex-task-lifecycle-contract.md`
- [assert] `rg -q "native app.*first prompt" docs/findings/codex-task-lifecycle-contract.md`
- [assert] `rg -q "host reboot" docs/findings/codex-task-lifecycle-contract.md`
- [assert] `rg -q "release-to-app" docs/findings/codex-task-lifecycle-contract.md`
- [assert] `rg -q "CCTRL_DATA_DIR" docs/findings/codex-task-lifecycle-contract.md`
- [assert] `rg -q "CCTRL_SESSION_METADATA_DIR" docs/findings/codex-task-lifecycle-contract.md`
- [cmd] `bash tests/run-tests.sh`

<!-- mstack:seam
produced:
- kind: file; name: docs/findings/codex-task-lifecycle-contract.md; file: docs/findings/codex-task-lifecycle-contract.md
- kind: schema; name: codex_lifecycle_fixture_manifest; shape: "cli_version,app_version,source,capture_method,observed_at,scenario,field_status,sanitization,refresh_rule"; file: tests/fixtures/codex-lifecycle/manifest.json
assumed:
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
