---
id: 008
title: Add idle-hook doorbell for peer messages
status: in-progress
blocked-by: [004, 005]
priority: 8
goal: cctrl-agent-peer-messaging
allows-migrations: false
needs-review: none
created: 2026-06-11
---

## Requirements

The tmux nudge adapter (plan 004) is best-effort and external. Both supported
agents can instead check their own mailbox at natural pause points: Claude Code
via `Stop`/`Notification` hooks, Codex via its `notify` configuration. This
plan wires that doorbell so a session learns about new mail the moment it goes
idle, without any watch loop running.

**Acceptance criteria:**

- [ ] A Claude Code hook script in `hooks/` runs `cctrl peer check --as "$CCTRL_PEER" --json --exit-on-empty` and, when messages exist, emits the plan 004 nudge text as blocking hook feedback (exit 2) so the agent immediately runs `peer recv`
- [ ] The hook is a fast no-op (exit 0) when `CCTRL_PEER` is unset or the inbox is empty
- [ ] The hook exits 2 only when queued messages exist; delivered-but-unacked messages never re-trigger it, so the recv-then-stop cycle cannot loop
- [ ] A Codex `notify` integration is provided and documented as notification-only (Codex has no blocking-feedback hook semantics)
- [ ] `cctrl start --peer NAME` launches a session with `CCTRL_PEER` exported and records the peer name in session metadata
- [ ] Sessions launched with `--peer` resolve their identity for `peer recv`, `peer ack`, and the MCP bridge without manual flags
- [ ] README documents the doorbell as the preferred delivery path, with the tmux nudge adapter as fallback for sessions launched without hooks

## Design

Keep the hook thin and fail-open: any error or missing dependency must exit 0
so peer-messaging problems can never block an agent's normal stop flow. The
hook reuses plan 004's nudge format so agents see one consistent instruction
regardless of delivery path. Identity comes only from `CCTRL_PEER`; the hook
never guesses.

The hook keys on the `queued` count only: `recv` transitions messages out of
`queued`, so after the agent fetches its mail the next Stop event finds
`queued == 0` and exits 0 — delivered-but-unacked messages cannot re-trigger
the hook, which is what prevents a stop-loop. The nudge text tells the agent
to `recv` and then `ack` each handled message.

`cctrl start --peer NAME` is the wiring that makes identity ambient: it exports
`CCTRL_PEER` into the session environment and stores `peer` in the session
metadata JSON, which also lets the plan 002 resolver link derived peers to
registered identities. That resolver linkage ships in this plan, not in 002:
008 extends the resolver so derived peers whose session metadata carries
`peer` resolve under that registered identity. Concretely: `--peer` is parsed in both `cmd_start` and
`_launch_detached`, exported through the same `base_env_q` mechanism as
`CCTRL_AGENT`, and must be verified to survive into the agent process spawned
by `_launch_exec_agent`. `_session_write_metadata` gains a `peer` parameter
(one call site to update).

Once this lands, the tmux nudger demotes from primary mechanism to fallback for
sessions launched without hooks; plan 004 should not grow readiness heuristics
beyond what it already has.

Testing approach: unit-only (hook script exercised directly with fixture JSON
on stdin and a fake `cctrl` in PATH).

**Files expected to change:**

- `hooks/peer-doorbell.sh`: Claude Code Stop/Notification hook
- `cctrl`: `start --peer NAME` env export and session metadata field
- `tests/run-tests.sh`: hook behavior tests (empty inbox, pending mail, unset identity, fail-open on error)
- `README.md`: doorbell setup for both agents, hook registration snippets
- `completions/_cctrl`: add `--peer`

**Out of scope:** changes to mailbox semantics, MCP bridge changes, automatic
hook installation into user settings, and cross-host doorbells.

## Tasks

1. Implement `hooks/peer-doorbell.sh` with fail-open behavior and the shared nudge format.
2. Add `--peer NAME` to `cctrl start`: export `CCTRL_PEER`, persist `peer` to session metadata.
3. Document Claude Code hook registration (settings hooks block) and the Codex `notify` equivalent in README.
4. Add tests for hook outputs and `start --peer` metadata.
5. Extend `peer doctor` (plan 007) with doorbell checks: hook script present, executable, and registered in the agent's hook configuration — fail-open hooks are otherwise invisible when broken.
6. Update completions for `--peer`.

## Verification

Checks:
- [cmd] `bash -n cctrl && bash -n hooks/peer-doorbell.sh && bash -n tests/run-tests.sh`
- [cmd] `tests/run-tests.sh`
- [assert] the hook in the test suite exits 2 with nudge text when the fake inbox has queued mail, exits 0 when empty, and exits 0 when `CCTRL_PEER` is unset
- [assert] `cctrl start -d --peer comet` in the test suite writes `"peer": "comet"` into session metadata

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | Hook blocking semantics must never break normal agent stop flow | 1 | CLEAR | 0 issues; resolver linkage clarified, doctor doorbell checks added |

- **VERDICT:** ENG CLEARED. Ready to implement.
