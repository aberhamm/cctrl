---
id: 060
title: Encapsulate the Codex App Server transport
status: done
blocked-by: [057]
priority: 60
goal: codex-task-ownership-surfaces
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-15
completed: 2026-09-16
reviewed: false
qa: automated
reviews:
  - type=eng verdict=approved date=2026-09-16 by=mstack-review
  - type=code verdict=pass date=2026-09-16 by=mstack-code-review
---

## Plain-English Summary

cctrl needs a supported way to create and inspect app-owned Codex tasks without starting a terminal UI that competes for the writer lock. This plan adds a small, testable App Server client and a capability check, but does not expose task creation to users yet.

**What changes in the code:** App Server initialization, request/notification handling, timeouts, version checks, and task methods are moved behind one adapter. cctrl can report whether the installed Codex runtime supports the exact operations later plans need.

## Requirements

The existing `--remote unix://` path still starts a Codex TUI and therefore is not equivalent to an app-owned task. A dedicated protocol adapter is required before cctrl can safely call `thread/start` and related methods.

**Acceptance criteria:**

- [ ] A dedicated helper implements newline-delimited JSON-RPC framing, `initialize` then `initialized`, integer/string request-id correlation, and the exact `thread/start`, `thread/read`, `thread/list`, and `turn/start` wrappers without parsing terminal UI output.
- [ ] Server-initiated requests are distinguished from notifications. Supported approval/permission/tool/elicitation/user-input requests use an explicit caller callback; an unsupported request receives a deterministic JSON-RPC error and aborts that operation instead of hanging.
- [ ] Interleaved notifications and server requests, structured errors, EOF, malformed JSON, mismatched ids, and separate connect/handshake/request/inactivity timeouts are handled without hanging cctrl.
- [ ] A read-only `cctrl codex capabilities --json` command reports CLI/app-server version, transport choice, normalized runtime facts, and each required method as `supported`, `unsupported`, or `unknown` with its evidence source and actionable failure reason.
- [ ] Capability discovery never invokes a mutating method. Generated schema may establish support only when its producing binary version matches the connected server userAgent; otherwise method support is unknown, not guessed from local wrapper availability.
- [ ] Runtime discovery uses configured override, then PATH lookup, then a validated platform-installation lookup. It works from an interactive shell and a GUI hook environment with a minimal PATH, reports the selected executable/transport, and does not hardcode a user-specific app bundle path.
- [ ] The adapter uses the transport validated in plan 057 and does not assume that spawning a new standalone server is the same as connecting to the desktop app daemon.
- [ ] Process-boundary tests use a fake App Server and cover success, notifications and server requests before responses, unsupported methods, evidence/version mismatch, every timeout phase, crash, protocol-version mismatch, and orphan-free termination/reaping.
- [ ] No command in this plan creates, archives, resumes, or mutates a real user task by default.
- [ ] The adapter returns runtime facts (userAgent, codexHome, platform, and transport endpoint); plan 058's task-record layer alone stamps the durable host_id.
- [ ] Capability output has a versioned JSON schema and documented stable exit-code table. Adapter invocation from `cctrl` is guarded under `set -euo pipefail` so failures still produce the normalized error contract.

## Design

Prefer a small Python helper in `lib/` for streaming JSON-RPC rather than implementing asynchronous framing in Bash. Its narrow public surface is initialize/capabilities plus the four named method wrappers and an inbound-request callback; it is not a general JSON-RPC framework. Keep the public cctrl command read-only. On timeout, EOF, or caller exit, terminate and reap a spawned child with a bounded escalation sequence. The adapter returns normalized JSON and stable exit codes so the launcher and reconciler do not duplicate protocol logic.

**Files expected to change:**

- `lib/codex_app_server.py`: protocol adapter, method wrappers, timeouts, and normalized errors.
- `cctrl`: `cctrl codex capabilities` dispatch and adapter invocation.
- `tests/run-tests.sh`: fake-server transport and capability tests.
- `README.md`: diagnostic command and supported-version boundary.

Testing approach: E2E

**Out of scope:** user-facing app-owned launch, hook installation, fleet merging, task ownership mutation, or presenting `--remote unix://` as simultaneous app access.

## Tasks

1. Convert plan 057's validated transport and exact methods into the narrow adapter interface, versioned capability schema, evidence states, and exit-code table.
2. Implement handshake, streaming response correlation, notifications, server-request callback/error handling, phased timeouts, child cleanup, and stable errors.
3. Add method wrappers for start/read/list and initial-turn support without exposing them as cctrl launch commands.
4. Add the non-mutating capability command, evidence/version comparison, deterministic runtime discovery, and guarded Bash invocation.
5. Build a deterministic fake App Server and exercise protocol success/failure, interleaved inbound requests, minimal PATH, read-only request traces, and orphan-free teardown.
6. Document the supported-version and transport diagnostics.

## Verification

Checks:

- [cmd] `python3 -m py_compile lib/codex_app_server.py`
- [cmd] `bash -n cctrl`
- [cmd] `bash tests/run-tests.sh`
- [cmd] `./cctrl codex capabilities --help | rg -q "capabilities"`

<!-- mstack:seam
produced:
- kind: file; name: lib/codex_app_server.py; file: lib/codex_app_server.py
- kind: schema; name: codex_capabilities_v1; shape: "schema_version,cli_version,server_version,transport,runtime_facts,methods,errors"; file: lib/codex_app_server.py
- kind: symbol; name: AppServerClient; file: lib/codex_app_server.py
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

## Implementation Notes

Implemented a narrow Codex desktop App Server adapter with newline-delimited JSON-RPC framing, typed request correlation, inbound request callbacks, phase-specific deadlines, bounded child termination, safe runtime discovery, exact schema evidence matching, guarded cctrl dispatch, and versioned read-only capability reporting. Added deterministic fake-server process tests covering success, interleaving, errors, crashes, timeouts, protocol mismatch, typed IDs, minimal-PATH discovery, non-mutating traces, and SIGKILL escalation. Health scored 10.0, all four verification checks passed, and the post-review full suite ended in `ok`; no real Codex task was mutated.

**Files changed:**

- `README.md` (modified)
- `cctrl` (modified)
- `docs/plans/060-codex-app-server-adapter.md` (modified)
- `lib/codex_app_server.py` (created)
- `tests/run-tests.sh` (modified)

**Commit:** `97fd169` — `feat(codex): add App Server transport adapter`
