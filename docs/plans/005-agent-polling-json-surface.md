---
id: 005
title: Add agent polling and JSON command surface
status: in-progress
blocked-by: [002, 003]
priority: 4
goal: cctrl-agent-peer-messaging
allows-migrations: false
needs-review: none
created: 2026-06-08
---

## Requirements

Peer messaging must work when no tmux session exists. This plan hardens the CLI
mailbox commands into a stable machine-readable polling surface so agents can
send, check, and acknowledge messages by calling `cctrl` directly.

**Acceptance criteria:**

- [ ] Every polling command supports `--json` with deterministic fields and no ANSI color
- [ ] `cctrl peer inbox --as comet --json` returns only messages visible to `comet`
- [ ] `cctrl peer check --as comet --json` returns a compact unread-count summary suitable for status polling
- [ ] `cctrl peer recv --as comet --json` returns the next queued/delivered message without changing it to `acked`
- [ ] `cctrl peer ack <message-id> --as comet --json` returns the updated message status
- [ ] Message bodies can be supplied from a file or stdin with `--body-file <path|->` to avoid shell quoting limits
- [ ] Exit codes distinguish no messages, validation errors, unknown peers, and corrupted mailbox data
- [ ] The README includes agent instruction snippets for polling without tmux

## Design

Build on the plan 003 mailbox commands rather than introducing a new storage
path. The goal is a stable contract agents can use safely from shell tools and,
later, from the MCP bridge. Human output may remain friendly, but `--json`
must be color-free and parseable. Message bodies are data: passed through
verbatim (escape sequences included) and never interpolated into terminal
output by cctrl.

Testing approach: unit-only.

**Command contract additions:**

- `cctrl peer check [--as NAME] [--json] [--exit-on-empty]`
- `cctrl peer recv [--as NAME] [--status queued,delivered] [--json] [--exit-on-empty]`
- `cctrl peer send <to> --from <from> --body-file <path|-> [--json]`
  (the positional `-- <body>` form from plan 003 remains supported; `--body-file` is additive)

`recv` is the polling-agent delivery operation. When it returns a queued
message, it must transition that message to `delivered` with `delivered_at` and
history, but it must not transition to `acked`; agents explicitly call `ack`
after handling the message. This is the only transition to `delivered` in the
system; the tmux nudge adapter (plan 004) never sets it. When no queued
messages exist, `recv` returns the oldest delivered-but-unacked message as-is
with no state change (idempotent redelivery for agents that crashed before
acking); `--status queued` restricts to queued only. `check` is read-only
and returns counts only.

**JSON contracts:**

- `check --json`: `{"peer":"comet","queued":1,"delivered_unacked":2,"oldest_queued_age_seconds":240}`
  (`oldest_queued_age_seconds` covers queued messages only and is `null` when none are queued)
- `recv --json`: `{"message":{...},"empty":false}` or `{"message":null,"empty":true}`
- `ack --json`: `{"message":{...},"status":"acked"}`
- JSON errors: `{"ok":false,"error":{"code":"unknown-peer","message":"..."}}`

**Exit code guidance:**

- `0`: command succeeded and returned data or completed the requested mutation
- `2`: no messages available for `check`/`recv` when `--exit-on-empty` is passed
- `64`: invalid command usage
- `65`: mailbox parse/corruption error
- `66`: unknown peer or unresolved identity

Do not add MCP protocol code in this plan. This plan produces the CLI/JSON
contract that MCP will wrap.

**Files expected to change:**

- `cctrl`: add polling-oriented command aliases/options, stdin body handling, JSON error helpers, and stable exit codes
- `tests/run-tests.sh`: add JSON contract and stdin body tests
- `README.md`: add polling examples and agent prompt snippets
- `completions/_cctrl`: add `check`, `recv`, `--body-file`, `--exit-on-empty`, and polling options

**Out of scope:** tmux delivery changes, MCP server implementation, background
watch mode, and cross-machine synchronization.

## Tasks

1. Add shared JSON output helpers that suppress ANSI color in JSON mode.
2. Add `check` and `recv` commands on top of the existing mailbox filters.
3. Add file and stdin body support with `--body-file <path|->` for `peer send`.
4. Normalize exit codes for polling commands, including opt-in `--exit-on-empty`, and document them in README.
5. Add tests for JSON shape, `CCTRL_PEER` identity, `--as`, empty inbox behavior, `--exit-on-empty`, stdin bodies, delivered-state transition on `recv`, and parse errors.
6. Update completions and README with non-tmux polling instructions, including `--exit-on-empty`.

## Verification

Checks:
- [cmd] `bash -n cctrl && bash -n tests/run-tests.sh && zsh -n completions/_cctrl`
- [cmd] `tests/run-tests.sh`
- [assert] `printf 'hello from stdin' | ./cctrl peer send comet --from orchestrator --body-file - --json` in the test suite preserves the exact body
- [assert] `./cctrl peer check --as comet --json` in the test suite returns valid JSON with unread counts
- [assert] `./cctrl peer recv --as comet --json` in the test suite returns a full message body and transitions it to `delivered`, not `acked`
- [assert] `./cctrl peer check --as comet --json --exit-on-empty` in the test suite exits 2 only when no messages are available

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | This command contract becomes the MCP bridge's API boundary | 1 | CLEAR | 0 issues; JSON contracts, idempotent redelivery, and exit codes validated |

- **VERDICT:** ENG CLEARED. Ready to implement.
