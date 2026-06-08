---
id: 003
title: Add atomic mailbox and message lifecycle
status: blocked
blocked-by: [002]
priority:
goal: cctrl-agent-peer-messaging
allows-migrations: false
needs-review: eng
created: 2026-06-08
---

## Requirements

Agents need a transport-neutral mailbox before any tmux or MCP delivery layer is
added. This plan adds durable message persistence, explicit message lifecycle
state, and concurrent-safe writes so multiple agent windows can send, inspect,
and acknowledge messages at the same time.

**Acceptance criteria:**

- [ ] `cctrl peer send comet --from orchestrator -- "Please check XYZ"` records a queued message with a stable ID
- [ ] `cctrl peer inbox --as comet --json` returns queued and delivered messages addressed to `comet`
- [ ] `cctrl peer outbox --as orchestrator --json` returns messages sent by `orchestrator`
- [ ] `cctrl peer show <message-id> --json` returns the full message envelope
- [ ] `cctrl peer ack <message-id> --as comet` changes only messages addressed to `comet` to `acked`
- [ ] `queued`, `delivered`, `failed`, and `acked` states are persisted with timestamped history
- [ ] Concurrent send/ack operations use locking or atomic replace semantics and do not corrupt `data/messages.jsonl`
- [ ] Unknown senders or recipients fail unless explicitly allowed by a documented `--allow-unknown` flag

## Design

Store messages in `data/messages.jsonl` because append-friendly JSON Lines fits
the existing shell-first repo and is easy to inspect. Updates that change state
should take an exclusive lock, rewrite through a temporary file, and then move
the file into place atomically. On macOS, prefer `shlock` if available or a
portable lock directory fallback; tests should exercise the chosen helper.

Testing approach: unit-only.

**Message envelope:**

```json
{
  "id": "msg_20260608_070000_abc123",
  "from": "orchestrator",
  "to": "comet",
  "status": "queued",
  "subject": "",
  "body": "Please check XYZ",
  "created_at": "2026-06-08T07:00:00Z",
  "updated_at": "2026-06-08T07:00:00Z",
  "delivered_at": null,
  "acked_at": null,
  "failed_at": null,
  "error": null,
  "history": [
    {"at": "2026-06-08T07:00:00Z", "status": "queued", "by": "orchestrator"}
  ]
}
```

**Files expected to change:**

- `cctrl`: add `MESSAGES_FILE`, mailbox locking helpers, message ID generation, send/inbox/outbox/show/ack commands under `cmd_peer`
- `tests/run-tests.sh`: add mailbox fixture tests and concurrent-safe update checks
- `README.md`: document mailbox lifecycle and examples
- `completions/_cctrl`: add mailbox subcommand completions

**Command contract:**

- `cctrl peer send <to> [--from NAME] [--subject TEXT] [--json] -- <body>`
- `cctrl peer inbox [--as NAME] [--status queued,delivered] [--json]`
- `cctrl peer outbox [--as NAME] [--status STATUS] [--json]`
- `cctrl peer show <message-id> [--json]`
- `cctrl peer ack <message-id> [--as NAME]`

`--from` should default to the resolved peer identity from `--as` or
`CCTRL_PEER` when available. If neither is available, it should default to
`user` only for interactive sends, and JSON mode should report that fallback
explicitly.

**Out of scope:** tmux paste delivery, MCP server implementation, background
watch loops, and cross-machine mailbox synchronization.

## Tasks

1. Add mailbox file initialization and lock helpers.
2. Add message ID generation that avoids collisions across rapid sends.
3. Implement `send`, `inbox`, `outbox`, `show`, and `ack` using the peer resolver from plan 002.
4. Implement state transition validation so invalid transitions fail clearly.
5. Add tests for send/list/show/ack, unknown peer errors, authorization on ack, JSON output, and lock behavior.
6. Update README and completions for mailbox commands.

## Verification

Checks:
- [cmd] `bash -n cctrl completions/_cctrl tests/run-tests.sh`
- [cmd] `tests/run-tests.sh`
- [assert] `./cctrl peer send comet --from orchestrator -- "hello"` in the test suite creates a message with `"status": "queued"`
- [assert] `./cctrl peer ack <id> --as wrong-peer` in the test suite fails without changing message state

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | Message state and locking are shared foundations for every delivery path | 0 | REQUIRED | - |
