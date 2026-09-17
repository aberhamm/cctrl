---
id: 066
title: Federate provider-neutral tasks across cctrl hosts
status: in-progress
blocked-by: [064]
priority: 66
goal: codex-task-ownership-surfaces
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-15
tui-fixture: n/a  # fleet reads structured task/session JSON and never parses terminal panes
reviews:
  - type=eng verdict=approved date=2026-09-16 by=mstack-review
---

## Plain-English Summary

Once local task ownership is correct, the fleet view should show the same distinctions across the Mac Studio, MacBook, and any registered host. This plan upgrades cross-host aggregation without letting an older remote cctrl corrupt or masquerade as the new ownership model.

**What changes in the code:** Fleet queries the provider-neutral task list when the remote supports it and safely adapts legacy tmux-only responses otherwise. Rows carry durable host identity and explicit capability/version information, so an offline or older host remains visible without false ownership claims.

## Requirements

Cross-host aggregation adds network failures and mixed cctrl versions to an already nuanced identity join. It must build on a correct local inventory rather than mixing remote compatibility into the local ownership implementation.

**Acceptance criteria:**

- [ ] `cctrl fleet` includes local and remote tmux sessions, app-owned tasks, cctrl-launched app tasks, native observed tasks, and discovery-only Codex rows when available.
- [ ] Public `cctrl fleet --json` remains the legacy top-level array with additive fields. New `--json-v2` returns the versioned fleet envelope; human rendering uses the same v2 rows internally. The per-host transport envelope has the seam-declared fleet-host-result-v2 schema.
- [ ] Remote hosts are queried for a versioned provider-neutral JSON surface; older hosts fall back to legacy `session ls --json` rows labeled `schema_version:1` with unknown app capabilities.
- [ ] Each remote call captures stdout, stderr, and status separately. `cctrl task ls --json` success must parse as plan 064's versioned envelope. Legacy fallback requires exit 1 and, after stripping ANSI, the first logical stdout line exactly `Unknown command: task`; following help text is ignored and stderr is expected empty. SSH/auth/timeout, exit-zero malformed JSON, provider partial failure, and every other result never trigger fallback.
- [ ] Every host registration has an immutable local federation host id plus a nullable remote host id. New registrations create the surrogate atomically. Legacy registrations remain visible as `identity-uninitialized` until explicit `cctrl host refresh-identity <alias>` adds the surrogate and maps any authoritative remote id; fleet never mutates host identity. Alias changes retain the registration ids.
- [ ] Host aliases remain display/routing labels and may change without changing task identity.
- [ ] Offline, timeout, malformed JSON, unsupported command, and partial provider-discovery failures yield inline host/capability markers without failing healthy hosts.
- [ ] Cross-host sorting tolerates null or differently formatted legacy recency fields and never uses recency to deduplicate.
- [ ] Large fleet JSON is streamed or file-fed into merge tooling; it does not pass arbitrarily large documents through `jq --argjson` command arguments.
- [ ] Human output exposes owner/runtime/origin and a concise action hint; JSON retains the full plan-064 normalized row plus remote schema/capability metadata.
- [ ] Fleet v2 JSON retains name, host, managed, agent, claude, model, dir, state, attached, remote_control, bridge, session_id, transcript, last_active, purpose, created_at, peer, display_label, and optional recap through the entire v2 compatibility period; removal requires a separately reviewed schema version.
- [ ] Tests cover new-to-new, new-to-old, offline, corrupt, duplicate-id/different-host, and alias-change cases with fake SSH.
- [ ] Host collection uses a small Python subprocess helper with at most four workers, a 10-second whole-process deadline per SSH command (not only connect timeout), process-group termination/reaping on expiry, and a whole-command budget of `ceil(remote_hosts/4) * 10 + 2` seconds. Timed-out workers emit structured timeout envelopes; Bash guards the helper under `set -euo pipefail`.
- [ ] Every host writes stdout/stderr/status to isolated temporary files, merged through stdin/`--slurpfile` with cleanup traps; no full fleet document is held in argv or passed via `jq --argjson`.
- [ ] Fake-SSH tests isolate all cctrl data/metadata/host-id roots and prove the real live store digest is unchanged.

## Design

Split remote capability detection from row merging. Use one per-host result envelope `{status,schema_version,capabilities,rows,error}` and the exact negotiation table above. Normalize locally before final sort, using one v1/v2 adapter and one renderer rather than parallel pipelines. Reuse `_fleet_remote_sessions`, `_fleet_tag`, `cmd_fleet`, and the fake-SSH `fleet_rootcopy`/`make_fleet_ssh` seams where appropriate.

**Files expected to change:**

- `cctrl`: remote task query, host-identity refresh, capability/version handling, fleet normalization, rendering, and compatibility fields.
- `lib/cctrl_fleet_collect.py` (new): bounded four-worker SSH subprocess collection, timeout, termination, and result files.
- `tests/run-tests.sh`: mixed-version fake-SSH matrices and large-output regression coverage.
- `README.md`: cross-host ownership and offline/legacy meanings.

Testing approach: E2E

**Out of scope:** waking sleeping connected hosts, synchronizing Codex provider databases between machines, remote process control, or creating tasks as part of fleet listing.

## Tasks

1. Add `fleet_host_result_v2`, preserve array `--json`, add envelope `--json-v2`, and implement the exact stdout/stderr/status negotiation table.
2. Add atomic federation ids for new registrations plus explicit `host refresh-identity` migration/mapping for legacy hosts; never mutate identity during fleet listing.
3. Merge and sort without identity inference from aliases, cwd, names, or recency.
4. Render owner/runtime/origin and remote failure/capability markers.
5. Preserve the enumerated legacy JSON fields and document the schema-version removal boundary.
6. Add the Python bounded four-worker collector with numeric deadlines, process-group cancellation/reaping, guarded Bash invocation, per-host tempfiles, total latency budget, and cleanup traps.
7. Add isolated fake-SSH tests for mixed versions, exact fallback/error classification, failures, collisions, alias migration, large fleets, and live-store digest invariance.

## Verification

Checks:

- [cmd] `bash -n cctrl`
- [cmd] `bash tests/run-tests.sh`
- [cmd] `./cctrl fleet --help | rg -q "task"`
- [cmd] `CCTRL_TEST_ONLY=fleet-v2 bash tests/run-tests.sh`

<!-- mstack:seam
produced:
- kind: schema; name: fleet_v2; shape: "status,schema_version,capabilities,rows,error"; file: cctrl
- kind: schema; name: fleet_host_result_v2; shape: "status,schema_version,capabilities,rows,error"; file: cctrl
- kind: symbol; name: _fleet_task_rows_json; file: cctrl
assumed:
- from: 064; kind: schema; name: task_list_v2; file: cctrl
- from: 064; kind: schema; name: task_list_row_v2; file: cctrl
- from: 064; kind: symbol; name: _task_list_json; file: cctrl
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
