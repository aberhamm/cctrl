---
id: 006
title: Add MCP stdio bridge for peer messaging
status: blocked
blocked-by: [005]
priority: 6
goal: cctrl-agent-peer-messaging
allows-migrations: false
needs-review: eng
created: 2026-06-08
---

## Requirements

Tool-calling agents should be able to use peer messaging without shelling out
manually. This plan adds an MCP stdio bridge that wraps the stable CLI/JSON
surface from plan 005 and exposes peer messaging as explicit tools.

**Acceptance criteria:**

- [ ] `cctrl peer mcp` starts a stdio MCP server process
- [ ] The MCP server exposes `list_peers`, `resolve_peer`, `send_message`, `check_messages`, `recv_message`, `show_message`, and `ack_message`
- [ ] Tool calls use the same mailbox files and state transitions as the CLI commands
- [ ] Tool responses are structured JSON-compatible objects with clear errors
- [ ] The server can run from a Codex MCP config entry or another stdio MCP client
- [ ] README documents how to register the MCP server globally in `~/.codex/config.toml`
- [ ] The bridge does not duplicate registry or mailbox business logic; it shells out to `cctrl peer ... --json` or imports only a narrowly scoped helper if one exists

## Design

Implement the bridge as a small script invoked by `cctrl peer mcp`. A Python
stdio MCP server is preferable to implementing JSON-RPC in bash. Keep it thin:
validate tool inputs, call the existing CLI JSON commands, parse results, and
return MCP tool responses. This minimizes the chance that CLI behavior and MCP
behavior drift.

Testing approach: unit-only.

Because this repo has no Python package manager and no existing MCP Python
dependency, implement a narrow dependency-free stdlib bridge in
`lib/peer_mcp.py`. Use newline-delimited JSON-RPC 2.0 over stdio for the MCP
transport and support only the client lifecycle needed by Codex-style stdio MCP
clients: `initialize`, `notifications/initialized`, `tools/list`, and
`tools/call`. Return JSON-RPC method-not-found or invalid-params errors for
unsupported methods and malformed tool arguments.
Keep stdout protocol-clean: JSON-RPC responses only on stdout, with all logs and
subprocess stderr routed to stderr.

Tool responses should use a consistent shape: `{"ok":true,"data":...}` for
successful calls and `{"ok":false,"error":{"code":"...","message":"..."}}` for
validation, unknown peer, and mailbox errors. `check_messages` wraps the
read-only count summary from plan 005; `recv_message` returns full message
bodies and applies the same delivered-state semantics as `cctrl peer recv`.

**Files expected to change:**

- `cctrl`: add `peer mcp` dispatch that execs the bridge script
- `lib/peer_mcp.py`: stdio MCP bridge implementation
- `tests/run-tests.sh`: add bridge smoke tests and command-contract tests
- `README.md`: add MCP registration example and tool list
- `completions/_cctrl`: add `peer mcp`

**Tool contract:**

- `list_peers({})`
- `resolve_peer({"name": "comet"})`
- `send_message({"to": "comet", "from": "orchestrator", "body": "..."})`
- `check_messages({"as": "comet", "limit": 10})`
- `recv_message({"as": "comet", "status": "queued,delivered"})`
- `show_message({"id": "msg_..."})`
- `ack_message({"id": "msg_...", "as": "comet"})`

If MCP dependencies are not already available, prefer a dependency-light
implementation using the standard library over adding a package manager or
vendored dependency.

**Out of scope:** hosted HTTP MCP, remote machine federation, tmux delivery
changes, and orchestrator watch loops.

## Tasks

1. Choose the smallest viable stdio MCP implementation strategy for this repo.
2. Add `cctrl peer mcp` dispatch and the bridge script.
3. Implement the seven MCP tools by wrapping existing `cctrl peer ... --json` commands.
4. Normalize MCP error responses for validation failures, unknown peers, and mailbox errors.
5. Add smoke tests that start the bridge enough to verify tool advertisement, JSON-RPC initialization, and one real send/receive tool call.
6. Update README with Codex MCP registration instructions and examples.
7. Update completions.

## Verification

Checks:
- [cmd] `bash -n cctrl completions/_cctrl tests/run-tests.sh`
- [cmd] `test ! -f lib/peer_mcp.py || python3 -m py_compile lib/peer_mcp.py`
- [cmd] `tests/run-tests.sh`
- [assert] MCP bridge smoke test in `tests/run-tests.sh` shows the peer messaging tools are advertised
- [assert] MCP bridge smoke test calls `send_message` and `recv_message` through stdio against `CCTRL_DATA_DIR="$TMPDIR/data"` and observes the expected mailbox side effects

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | MCP protocol boundary and dependency strategy need review before implementation | 0 | REQUIRED | - |
