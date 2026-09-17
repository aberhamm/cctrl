---
id: 069
title: Verify and document the three Codex ownership paths
status: in-progress
blocked-by: [066, 068]
priority: 69
goal: codex-task-ownership-surfaces
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-15
tui-fixture: n/a  # lifecycle tests use fake tmux/process events and never parse terminal panes
reviews:
  - type=eng verdict=approved date=2026-09-16 by=mstack-review
---

## Plain-English Summary

The final user experience should make the three creation paths unmistakable: a cctrl tmux worker, a cctrl-launched app-owned task, and a native app task that cctrl only observes. This plan runs the complete lifecycle matrix, aligns help and operator skills, and removes wording that suggests tmux and the app can write the same task at once.

**What changes in the code:** Cross-feature regression fixtures exercise creation, observation, listing, handoff, restart, and recovery as one flow. README, command help, completions, and cctrl's bundled operating skills are updated to choose the correct launch path and explain the ownership limits.

## Requirements

Even correct internals will be unsafe if cctrl-spawn or help text continues to route every Codex task through tmux. The finished feature needs one consistent operational contract across commands and agent-facing guidance.

**Acceptance criteria:**

- [ ] The end-to-end matrix proves native app creation produces one app/provider task and zero tmux sessions, with cctrl recorded only as observer/registrar.
- [ ] The matrix proves `cctrl start --agent codex --app-owned` produces one app/provider task and zero tmux sessions, with cctrl launch provenance and app control.
- [ ] The matrix proves normal detached Codex start produces one tmux owner and reports cctrl control until explicit release.
- [ ] The matrix proves `release-to-app` preserves one provider id, removes the terminal owner, updates capabilities, and does not duplicate the task.
- [ ] Fleet identity joins exclude cwd/title, and mixed-version remote rows expose unknown capabilities rather than synthesized ownership.
- [ ] Snapshot/restore never spawns app-created, app-owned, discovery-only, conflict, or handed-off tasks as tmux workers.
- [ ] README and help explain that tmux survives terminal/SSH disconnects but not host reboot; Codex tasks are provider-resumable; cctrl snapshot restores only authorized terminal workers.
- [ ] `skills/cctrl-spawn/SKILL.md` tells agents when to use normal detached launch versus `--app-owned`, and never presents `--remote unix://` as simultaneous app access.
- [ ] `skills/cctrl-session-end/SKILL.md` documents release-to-app as a verified ownership handoff, while `skills/cctrl-fleet-manager/SKILL.md` uses provider-neutral task/fleet status before dispatch.
- [ ] Documentation states that app `+` tasks are observed after Codex assigns an id, not intercepted before creation, and that cctrl does not override app-selected model or permissions.
- [ ] Peer messaging for app tasks remains explicitly deferred to plans 028/029 or a successor after stable identity; this backlog does not create an unsafe shared-MCP identity shortcut.
- [ ] One semantic three-path decision table is canonical across README, CLI help, completions, and skills. It states creation command, origin, runtime owner, control surface, disconnect behavior, reboot behavior, safe transition, and unsupported actions.
- [ ] The matrix exercises the original contention case for the same provider id while tmux owns the writer and proves honest conflict/no duplicate/no owner theft plus an actionable `release-to-app` path.
- [ ] The deterministic matrix replays plan-057's versioned authoritative fixtures and claims compatibility only for that declared boundary; it does not overclaim arbitrary future Codex behavior.
- [ ] Matrix tests force all cctrl data, session-metadata, host-id, Codex-home, fake home, and snapshot roots beneath test temp space, then compare real live-store digests before/after. Git status is not a safety check.

## Design

Add one named fixture-driven integration matrix on top of the per-plan tests; do not substitute a fragile live-user-task test for deterministic coverage. Use the canonical decision table as the semantic source and test each other surface against its command/ownership invariants. If the matrix exposes prerequisite logic, make only the narrowest regression-tested correction in that owning surface; do not redesign ownership semantics here. Update canonical skill sources, not thin docs pointers.

**Files expected to change:**

- `tests/run-tests.sh`: complete three-path lifecycle matrix and negative recovery assertions.
- `README.md`: ownership model, command decision guide, cross-device/reboot semantics, and troubleshooting.
- `cctrl`: final help consistency only; no new ownership logic.
- `completions/_cctrl`: final option/help consistency.
- `skills/cctrl-spawn/SKILL.md`: launch-surface decision rules.
- `skills/cctrl-session-end/SKILL.md`: handoff and close behavior.
- `skills/cctrl-fleet-manager/SKILL.md`: provider-neutral inventory guidance.
- `CHANGELOG.md`: shipped behavior and compatibility notes.

Testing approach: E2E

**Out of scope:** new peer identity design, changing the Codex desktop UI, concurrent multi-writer access, or supporting a Codex version outside plan 060's declared compatibility boundary.

## Tasks

1. Build the named deterministic end-to-end three-path fixture matrix from plan-057 versioned fixtures under fully isolated roots.
2. Verify exact task count, provider id, origin/provenance, owner, runtime, capabilities, tmux process count, contested-writer behavior, handoff, cross-host display, and restore dispositions.
3. Rewrite README and command help around the three explicit paths and their persistence limits.
4. Update the three canonical cctrl skills so agents choose app-owned versus tmux-owned creation intentionally.
5. Align completions and changelog, and remove stale wording about released tasks or `--remote unix://`.
6. Run the focused matrix and complete suite, compare live-store digests, and verify no generated live task, hook, mailbox, or snapshot data was touched.

## Verification

Checks:

- [cmd] `bash -n cctrl`
- [cmd] `bash tests/run-tests.sh`
- [assert] `rg -q -- "--app-owned" README.md skills/cctrl-spawn/SKILL.md completions/_cctrl`
- [assert] `rg -q "three ownership paths" README.md`
- [assert] `rg -q "release-to-app" skills/cctrl-session-end/SKILL.md`
- [assert] `rg -q "task ls" skills/cctrl-fleet-manager/SKILL.md`
- [assert] `rg -q "provider-neutral" README.md`
- [cmd] `CCTRL_TEST_ONLY=codex-ownership-matrix bash tests/run-tests.sh`

<!-- mstack:seam
produced:
- kind: schema; name: codex_three_path_matrix; shape: "path,command,origin,runtime,owner,control_surface,disconnect,reboot,transition,unsupported"; file: tests/run-tests.sh
assumed:
- from: 066; kind: schema; name: fleet_v2; shape: "status,schema_version,capabilities,rows,error"; file: cctrl
- from: 068; kind: schema; name: snapshot_v2; shape: "schema_version,generated_at,host_id,resource_metadata,tasks,task_reference_count,restore_candidate_count,capture_quality,source_errors"; file: cctrl
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
