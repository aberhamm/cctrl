---
id: 004
title: Add tmux delivery adapter for peer messages
status: blocked
blocked-by: [002, 003]
priority:
goal: cctrl-agent-peer-messaging
allows-migrations: false
needs-review: eng
created: 2026-06-08
---

## Requirements

The orchestrator workflow needs a way to inject a queued mailbox message into an
agent's terminal session when that peer has a tmux target. This plan adds tmux
as the first active delivery adapter while keeping the mailbox and peer registry
usable without tmux.

**Acceptance criteria:**

- [ ] `cctrl peer deliver comet --dry-run` prints the message envelope that would be pasted and does not mutate message state
- [ ] `cctrl peer deliver comet` delivers queued messages for `comet` when the peer has a valid `tmux_target`
- [ ] Delivery uses `tmux load-buffer` and `tmux paste-buffer`, not raw shell-interpolated `send-keys` for message bodies
- [ ] Delivered messages transition from `queued` to `delivered` with `delivered_at` and history entries
- [ ] Delivery failures transition to `failed` with a useful error message unless `--no-mark-failed` is used
- [ ] `cctrl peer deliver --all` attempts delivery for every queued message whose recipient has `tmux` capability
- [ ] Peers without tmux capability are skipped with a clear status in human and JSON output
- [ ] Delivery never sends an implicit Enter unless the user passes a documented `--submit` flag

## Design

Add a tmux adapter under the `peer deliver` command. The adapter resolves the
recipient peer, verifies `tmux` is available, verifies the target exists, formats
a structured envelope, loads that envelope into a tmux buffer, pastes it into the
target pane, and updates mailbox state.

Testing approach: unit-only.

**Pasted envelope:**

```text
Message from cctrl peer
ID: msg_20260608_070000_abc123
From: orchestrator
To: comet

Please check XYZ.

Reply by sending or acknowledging this message through cctrl peer.
```

`--submit` may add `tmux send-keys -t <target> Enter` after paste, but the safe
default is paste-only. This avoids accidentally submitting into an agent that is
mid-edit or not ready.

**Files expected to change:**

- `cctrl`: add tmux delivery helper functions and `peer deliver`
- `tests/run-tests.sh`: extend fake tmux to capture `load-buffer`, `paste-buffer`, and optional `send-keys`
- `README.md`: document tmux delivery workflow and safety limitations
- `completions/_cctrl`: add `deliver` options

**Out of scope:** idle/readiness detection, automatic background loops, MCP
tools, and message polling by non-tmux agents.

## Tasks

1. Add helper to format a mailbox message into a deterministic delivery envelope.
2. Add helper to resolve and validate a peer's tmux target.
3. Implement `peer deliver <name|--all> [--dry-run] [--json] [--submit] [--no-mark-failed]`.
4. Use safe tmux buffer commands for body delivery and quote tmux target names correctly.
5. Update mailbox state for delivered and failed messages through the locking helper from plan 003.
6. Add fake tmux tests for dry-run, successful paste, skipped non-tmux peer, failed target, and optional submit.
7. Update README and completions.

## Verification

Checks:
- [cmd] `bash -n cctrl completions/_cctrl tests/run-tests.sh`
- [cmd] `tests/run-tests.sh`
- [assert] fake tmux log in the test suite contains `load-buffer` and `paste-buffer` for `cctrl peer deliver comet`
- [assert] fake tmux log in the test suite does not contain `send-keys Enter` unless `--submit` is passed

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | Terminal injection has quoting, safety, and state-transition risk | 0 | REQUIRED | - |
