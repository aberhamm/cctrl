---
id: 003
title: Add atomic mailbox and message lifecycle
status: pending
blocked-by: [002]
priority: 3
goal: cctrl-agent-peer-messaging
allows-migrations: false
needs-review: none
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
- [ ] `queued`, `delivered`, and `acked` states are persisted with timestamped history; nudge attempts are history events with `nudge_count`, `last_nudge_at`, and `last_nudge_error` fields, never message states
- [ ] Concurrent send/ack operations use locking or atomic replace semantics and do not corrupt `data/messages.jsonl`
- [ ] A crashed lock holder does not permanently block the mailbox: the lock-directory fallback records the holder PID and stale locks are reclaimed
- [ ] Unknown senders or recipients fail unless explicitly allowed by a documented `--allow-unknown` flag
- [ ] Message records include enough timestamp metadata for later garbage collection by status and age

## Design

Store messages in `${CCTRL_DATA_DIR}/messages.jsonl` because append-friendly
JSON Lines fits the existing shell-first repo and is easy to inspect. Updates
that change state should take an exclusive lock, rewrite through a temporary
file, and then move the file into place atomically. On macOS, prefer `shlock`
if available (it performs PID-staleness checks natively) with a portable
lock-directory fallback. The fallback must write the holder PID into the lock
directory and reclaim the lock when that PID is dead, so a crashed writer can
never block the mailbox permanently. The lock helper must also support wrapping
a caller-supplied multi-step operation (check, external action, record) rather
than only single rewrites — plan 004 holds the lock across its full nudge
cycle. Tests should exercise the chosen helper using
`CCTRL_DATA_DIR="$TMPDIR/data"` so they never touch the real mailbox.

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
  "nudge_count": 0,
  "last_nudge_at": null,
  "last_nudge_error": null,
  "history": [
    {"at": "2026-06-08T07:00:00Z", "status": "queued", "by": "orchestrator"}
  ]
}
```

Message IDs are `msg_<UTC %Y%m%d_%H%M%S>_<6 lowercase hex chars from /dev/urandom>`.
Generation happens under the mailbox lock and regenerates if the ID already
exists, so rapid sends within the same second cannot collide.

The lifecycle is deliberately small: `queued -> delivered -> acked`.
`delivered` means the recipient fetched the message (`peer recv`, plan 005) —
that is the only path to `delivered`. `acked` means the recipient explicitly
handled it. There is no `failed` message state: a failed delivery attempt is
nudge metadata (`nudge_count`, `last_nudge_at`, `last_nudge_error`, plus
history events), never a message status, because the message itself remains
valid and queued. Nudge history records are typed —
`{"at": "...", "event": "nudge", "ok": true|false, "error": null}` — so
consumers can count trailing failures (plan 007's backoff). Do not delete on read. Old-message cleanup will be a separate
garbage-collection command in the orchestrator workflow plan, so this plan must
keep status and timestamp fields consistent enough for retention filters.

**Files expected to change:**

- `cctrl`: add `MESSAGES_FILE`, mailbox locking helpers, message ID generation, send/inbox/outbox/show/ack commands under `cmd_peer`
- `tests/run-tests.sh`: add mailbox fixture tests and concurrent-safe update checks
- `README.md`: document mailbox lifecycle and examples
- `completions/_cctrl`: add mailbox subcommand completions

**Command contract:**

- `cctrl peer send <to> [--from NAME] [--subject TEXT] [--allow-unknown] [--json] -- <body>`
- `cctrl peer inbox [--as NAME] [--status queued,delivered] [--json]`
- `cctrl peer outbox [--as NAME] [--status STATUS] [--json]`
- `cctrl peer show <message-id> [--json]`
- `cctrl peer ack <message-id> [--as NAME]`

`--from` should default to the resolved peer identity from `--as` or
`CCTRL_PEER` when available. If neither is available, it should default to
`user` only for interactive human sends. In `--json` mode, missing sender
identity must fail with the unknown-peer exit code unless `--from` is provided.
`--allow-unknown` applies only to `peer send`; it permits unknown sender or
recipient names and marks the resulting message with `"unknown_peer": true`.

**Out of scope:** tmux paste delivery, MCP server implementation, background
watch loops, garbage collection, and cross-machine mailbox synchronization.

## Tasks

1. Add mailbox file initialization and lock helpers.
2. Add message ID generation that avoids collisions across rapid sends.
3. Implement `send`, `inbox`, `outbox`, `show`, and `ack` using the peer resolver from plan 002.
4. Implement state transition validation so invalid transitions fail clearly: `ack` on a queued message fails with a "receive it first (cctrl peer recv)" error; `ack` on an already-acked message is an idempotent no-op success.
5. Add tests for send/list/show/ack, unknown peer errors, `--allow-unknown`, JSON sender fallback failure, authorization on ack, JSON output, and lock behavior.
6. Add a lock-contention test that runs parallel send/ack operations against `CCTRL_DATA_DIR="$TMPDIR/data"` and verifies `messages.jsonl` remains parseable with no lost records. Background the operations with `&` and collect exit codes via `wait` explicitly — the harness runs under `set -euo pipefail`, which does not propagate background-job failures.
7. Add a stale-lock test that creates a lock directory owned by a dead PID and verifies the next mailbox write reclaims it.
8. Update README and completions for mailbox commands.

## Verification

Checks:
- [cmd] `bash -n cctrl && bash -n tests/run-tests.sh && zsh -n completions/_cctrl`
- [cmd] `tests/run-tests.sh`
- [assert] `./cctrl peer send comet --from orchestrator -- "hello"` in the test suite creates a message with `"status": "queued"`
- [assert] `./cctrl peer ack <id> --as wrong-peer` in the test suite fails without changing message state
- [assert] parallel mailbox operations in the test suite leave `messages.jsonl` valid JSONL with the expected record count
- [assert] a lock directory owned by a dead PID in the test suite is reclaimed by the next mailbox write

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | Message state and locking are shared foundations for every delivery path | 1 | CLEAR | 0 issues; lifecycle, locking, and ID generation validated against codebase idioms |

- **VERDICT:** ENG CLEARED. Ready to implement.
