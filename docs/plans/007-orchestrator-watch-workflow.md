---
id: 007
title: Add orchestrator watch workflow for peer messaging
status: pending
blocked-by: [004, 006]
priority:
goal: cctrl-agent-peer-messaging
allows-migrations: false
needs-review: none
created: 2026-06-08
---

## Requirements

After peers, mailbox, tmux delivery, polling, and MCP exist, users need a
coherent operating workflow for an overseeing agent. This plan adds watch,
status, retry, docs, completions, and scenario tests so the feature is usable
end-to-end instead of a collection of primitives.

**Acceptance criteria:**

- [ ] `cctrl peer status --json` summarizes peers, queued messages, delivered messages waiting for ack, failed messages, and available transports
- [ ] `cctrl peer retry <message-id>` resets a failed message to queued with history
- [ ] `cctrl peer retry --all` safely retries failed messages without duplicating acked messages
- [ ] `cctrl peer watch --once` performs one orchestrator pass over queued messages and reports what happened
- [ ] `cctrl peer watch --interval 5` repeatedly checks queued messages and invokes tmux delivery for tmux-capable peers
- [ ] Watch mode leaves polling/MCP-capable non-tmux peers in queued state for agent-side pickup
- [ ] README includes the recommended orchestrator prompt and examples for "send a message to the Comet agent"
- [ ] zsh completions cover all new `peer` subcommands and common flags
- [ ] Scenario tests cover tmux delivery, polling-only delivery, retry, and status summaries

## Design

Add orchestration commands on top of the completed primitives. `watch` should not
invent new delivery semantics; it should call the tmux adapter for tmux peers and
leave polling/MCP peers in the mailbox. The user-facing model should be clear:
`cctrl` is the registry and delivery layer, while the overseeing agent makes
reasoning/routing decisions.

Testing approach: unit-only.

**Files expected to change:**

- `cctrl`: add `peer status`, `peer retry`, and `peer watch`
- `tests/run-tests.sh`: add end-to-end fake mailbox/fake tmux scenarios
- `README.md`: add full peer messaging workflow, examples, and limitations
- `completions/_cctrl`: complete the peer command tree

**Watch behavior:**

- `--once`: one pass, exits zero when work was checked successfully
- `--interval N`: loop until interrupted
- `--json`: emit machine-readable pass summaries
- `--dry-run`: report actions without mutating message state

The implementation must avoid marking non-tmux messages failed simply because
there is no active delivery adapter; polling and MCP peers consume messages
themselves.

**Out of scope:** automatic agent idle detection, real-time push delivery
without polling, cross-host mailbox replication, and UI dashboards.

## Tasks

1. Implement `peer status` summary using the registry and mailbox.
2. Implement `peer retry` for one failed message and `--all`.
3. Implement `peer watch --once`, `--interval`, `--dry-run`, and `--json`.
4. Add scenario tests for orchestrator pass behavior across tmux and polling peers.
5. Complete zsh completions for all peer commands.
6. Update README with architecture, examples, orchestrator prompt guidance, and known limitations.

## Verification

Checks:
- [cmd] `bash -n cctrl completions/_cctrl tests/run-tests.sh`
- [cmd] `tests/run-tests.sh`
- [assert] `cctrl peer watch --once --dry-run --json` in the test suite reports tmux delivery candidates without changing message state
- [assert] `cctrl peer retry --all --json` in the test suite resets failed messages and leaves acked messages unchanged
