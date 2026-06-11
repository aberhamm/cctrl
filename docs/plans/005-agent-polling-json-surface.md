---
id: 005
title: Add agent polling and JSON command surface
status: blocked
blocked-by: [002, 003]
priority: 5
goal: cctrl-agent-peer-messaging
allows-migrations: false
needs-review: eng
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
- [ ] Message bodies can be supplied from stdin with `--body-file -` to avoid shell quoting limits
- [ ] Exit codes distinguish no messages, validation errors, unknown peers, and corrupted mailbox data
- [ ] The README includes agent instruction snippets for polling without tmux

## Design

Build on the plan 003 mailbox commands rather than introducing a new storage
path. The goal is a stable contract agents can use safely from shell tools and,
later, from the MCP bridge. Human output may remain friendly, but `--json`
must be color-free and parseable.

Testing approach: unit-only.

**Command contract additions:**

- `cctrl peer check [--as NAME] [--json] [--exit-on-empty]`
- `cctrl peer recv [--as NAME] [--status queued,delivered] [--json] [--exit-on-empty]`
- `cctrl peer send <to> --from <from> --body-file - [--json]`

`recv` is the polling-agent delivery operation. When it returns a queued
message, it must transition that message to `delivered` with `delivered_at` and
history, but it must not transition to `acked`; agents explicitly call `ack`
after handling the message. `check` is read-only and returns counts only.

**JSON contracts:**

- `check --json`: `{"peer":"comet","queued":1,"delivered":2,"failed":0}`
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
3. Add stdin body support with `--body-file -` for `peer send`.
4. Normalize exit codes for polling commands, including opt-in `--exit-on-empty`, and document them in README.
5. Add tests for JSON shape, `CCTRL_PEER` identity, `--as`, empty inbox behavior, `--exit-on-empty`, stdin bodies, delivered-state transition on `recv`, and parse errors.
6. Update completions and README with non-tmux polling instructions, including `--exit-on-empty`.

## Verification

Checks:
- [cmd] `bash -n cctrl completions/_cctrl tests/run-tests.sh`
- [cmd] `tests/run-tests.sh`
- [assert] `printf 'hello from stdin' | ./cctrl peer send comet --from orchestrator --body-file - --json` in the test suite preserves the exact body
- [assert] `./cctrl peer check --as comet --json` in the test suite returns valid JSON with unread counts
- [assert] `./cctrl peer recv --as comet --json` in the test suite returns a full message body and transitions it to `delivered`, not `acked`
- [assert] `./cctrl peer check --as comet --json --exit-on-empty` in the test suite exits 2 only when no messages are available

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | This command contract becomes the MCP bridge's API boundary | 0 | REQUIRED | - |
