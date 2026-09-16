---
id: 065
title: Launch app-owned Codex tasks through cctrl
status: pending
blocked-by: [059, 060, 063]
priority: 65
goal: codex-task-ownership-surfaces
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-15
tui-fixture: n/a  # launch tests count tmux processes but never parse terminal panes
reviews:
  - type=eng verdict=approved date=2026-09-16 by=mstack-review
---

## Plain-English Summary

Today cctrl starts Codex inside tmux, which keeps a terminal writer alive and can make the same task unavailable in the app. This plan adds an explicit app-owned launch mode that creates the task through Codex's App Server, records that cctrl initiated it, and leaves no competing terminal process behind.

**What changes in the code:** `cctrl start --agent codex --app-owned` uses the App Server adapter, applies explicit cctrl launch settings, optionally sends the first prompt once, registers the returned task id, and exits. The existing detached tmux path and experimental remote-TUI flag keep their current meanings.

## Requirements

The user must be able to ask an app-owned Codex task to create another task through cctrl without losing immediate app access to the new task. This is different from creating a native app `+` task, which cctrl only observes, and from normal cctrl detached launch, which cctrl owns in tmux.

**Acceptance criteria:**

- [ ] On confirmed success, `cctrl start --agent codex --app-owned [target]` creates exactly one provider task through the plan-060 adapter and zero tmux sessions. `thread/start` is emitted at most once unless provider idempotency is proven; a lost/ambiguous response is never retried and returns `task_creation_outcome:unknown` with a nullable provider task id.
- [ ] After the command exits, no cctrl-launched Codex CLI/TUI process or cctrl-owned writer remains attached to the provider task.
- [ ] The record is written through plan 059 with `origin:cctrl`, `registered_by_cctrl:true`, `launched_by_cctrl:true`, `execution_runtime:app-server`, `control_owner:app`, and provider-managed restore.
- [ ] The provider task id is the identity. A generated display name or cwd match cannot attach the launch record to another task.
- [ ] Explicit model, reasoning effort, cwd, sandbox, and approval settings supported by the App Server are passed from cctrl flags/profile. Omitted settings retain documented provider defaults rather than guessed values.
- [ ] Settings use one allowlisted normalizer with precedence explicit CLI over profile over omitted/provider default. Add `--reasoning-effort` plus the matching profile field; map only model, reasoning effort, canonical cwd, sandbox, and approval. Reject unsupported values, Claude-only `--permission-mode`, raw `-c`, and arbitrary profile/passthrough arguments. Explicit `--yolo` maps only to its documented sandbox/approval pair and is never inferred.
- [ ] Before mutation, plan 060's capability result must prove `thread/start` and, when needed, `turn/start` or empty-thread support. Unknown/unsupported capability fails before task creation.
- [ ] With `-m/--message`, the first turn is emitted at most once. Use provider idempotency only if plan 057/060 proves a supported key; otherwise an ambiguous timeout returns `outcome:unknown`, never automatically retries, and reports the real provider task id. Without a message, cctrl creates an empty task only when the versioned capability result proves support.
- [ ] Human output and `--json` independently report task creation outcome, nullable task id, host id, owner, runtime, turn outcome, registry persistence as `true|false|unknown`, and an app-opening/connected-host hint without claiming concurrent writable access.
- [ ] If a known provider task id was created but registry persistence failed, nonzero output gives an exact idempotent recovery command targeting the creation host: local uses `cctrl session recover-app-owned <provider-task-id>` and remote uses `cctrl --host <alias> session recover-app-owned <provider-task-id>`. It verifies through plan 060 and retries only the plan-059 launch event. For unknown creation outcome with no id, output instructs the user to inspect that host's app/task inventory and never rerun creation automatically.
- [ ] Normal `cctrl start -d --agent codex` remains one cctrl-owned tmux worker. `--remote unix://` remains an app-server-backed TUI transport and is not an alias for `--app-owned`.
- [ ] The compatibility matrix is closed: `--app-owned` rejects `-d/--detach`, `--foreground`, `--no-tmux/--tmux`, `--resume`, `--remote`, `--peer`, health-check controls, `--purpose`, `--name`, and arbitrary passthrough arguments. Only target, `-m/--message`, allowlisted settings/profile fields, JSON output, and host routing are accepted.
- [ ] Generic `cctrl --host <alias> ... --app-owned` creates on the selected connected host and reports that host. Cross-device visibility depends on Codex remote connections and the target host being awake.
- [ ] Remote app-owned launch is noninteractive: `_remote_exec` allocates no TTY, never detach-attaches, and never runs local purpose-prompt injection. It forwards the validated normalized request once.
- [ ] No target means the invocation cwd; explicit directories and `@shortcut` targets are canonicalized before creation and must exist. Target/cwd is never part of provider-task identity or deduplication.

## Design

Branch into app-owned launch before `_launch_detached`, foreground tmux setup, and interactive `_remote_exec` routing. Use one canonical argument/settings normalizer shared by local and remote paths. Execute the fixed sequence capability preflight -> at-most-once task creation -> optional at-most-once first-turn emission -> plan-059 launch event, with independent tri-state outcomes for every failure boundary. Do not hold the provider's long-lived writer in the cctrl process.

**Files expected to change:**

- `cctrl`: `--app-owned` parsing, validation, launch flow, output, remote-host compatibility, help, and completions plumbing.
- `lib/codex_app_server.py`: start/turn request fields proven necessary by plan 057.
- `completions/_cctrl`: new flag and incompatible-option descriptions.
- `tests/run-tests.sh`: fake-server creation, first-turn at-most-once/ambiguous outcome, zero-tmux, partial success/recovery, incompatible flags, and legacy-path regression tests.
- `README.md`: explicit three-path launch examples.

Testing approach: E2E

**Out of scope:** intercepting the Codex app's plus button before task creation, simultaneous app/tmux writers, changing an app-created task's settings, or automatic peer registration.

## Tasks

1. Add and validate `--app-owned` as a Codex-only execution-surface choice using the complete compatibility matrix and target rules.
2. Add `--reasoning-effort` and normalize only allowlisted CLI/profile settings with explicit precedence into plan-060 requests.
3. Implement capability preflight, at-most-once provider creation, optional at-most-once initial prompt, plan-059 launch event, independent outcome reporting, and idempotent known-id recovery.
4. Ensure the code path returns before all tmux/CLI-owner setup and rejects contradictory flags.
5. Preserve generic remote-host routing while making host ownership explicit and proving no SSH TTY, attach, or purpose prompt is used.
6. Add fake App Server/tmux/SSH tests for settings mapping/omission, capability preflight before mutation, ambiguous thread-start timeout emitted once with no retry/unknown outcome/null id, ambiguous turn timeout without retry, host-preserving local/remote recovery commands, partial recovery, same-cwd identity, one provider task, and zero CLI/tmux/writer/orphan owners.
7. Export temporary `CCTRL_DATA_DIR`, `CCTRL_SESSION_METADATA_DIR`, and `CCTRL_HOST_ID_FILE`; prove the live store digest is unchanged.
8. Update completions and user documentation.

## Verification

Checks:

- [cmd] `bash -n cctrl`
- [cmd] `python3 -m py_compile lib/codex_app_server.py`
- [cmd] `bash tests/run-tests.sh`
- [cmd] `./cctrl start --help | rg -q -- "--app-owned"`
- [assert] `rg -q -- "--app-owned" completions/_cctrl`
- [cmd] `CCTRL_TEST_ONLY=app-owned-launch bash tests/run-tests.sh`

<!-- mstack:seam
produced:
- kind: flag; name: --app-owned; file: cctrl
- kind: flag; name: --reasoning-effort; file: cctrl
- kind: schema; name: app_owned_launch_result_v1; shape: "partial,task_creation_outcome,provider_task_id,host_id,owner,runtime,turn_outcome,registry_persisted,open_hint,error"; file: cctrl
- kind: symbol; name: _launch_app_owned_codex; file: cctrl
assumed:
- from: 059; kind: symbol; name: _task_registry_apply_event; shape: "record_key,event_file"; file: cctrl
- from: 060; kind: symbol; name: AppServerClient; file: lib/codex_app_server.py
- from: 063; kind: symbol; name: _session_reconcile_codex; file: cctrl
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
