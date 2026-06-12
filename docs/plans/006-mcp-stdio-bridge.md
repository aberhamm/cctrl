---
id: 006
title: Add MCP stdio bridge for peer messaging
status: pending
blocked-by: [005]
priority: 6
goal: cctrl-agent-peer-messaging
allows-migrations: false
needs-review: none
created: 2026-06-08
---

## Requirements

Tool-calling agents should be able to use peer messaging without shelling out
manually. This plan adds an MCP stdio bridge that wraps the stable CLI/JSON
surface from plan 005 and exposes peer messaging as explicit tools.

**Acceptance criteria:**

- [ ] `cctrl peer mcp --as comet` starts a stdio MCP server bound to one peer identity, falling back to `CCTRL_PEER`; startup fails with a clear error when no identity is resolvable
- [ ] The MCP server exposes `whoami`, `list_peers`, `resolve_peer`, `send_message`, `check_messages`, `recv_message`, `show_message`, and `ack_message`; no tool accepts `as` or `from` arguments — identity comes from server startup
- [ ] Tool calls use the same mailbox files and state transitions as the CLI commands
- [ ] Tool responses are structured JSON-compatible objects with clear errors
- [ ] The server can run from a Codex MCP config entry or another stdio MCP client
- [ ] README documents registration for both agents: Codex via `~/.codex/config.toml`, and Claude Code via project `.mcp.json` or `claude mcp add -s user` (env vars added to the entry in `~/.claude.json`), with each agent's entry setting its own identity
- [ ] The bridge does not duplicate registry or mailbox business logic; it shells out to `cctrl peer ... --json` or imports only a narrowly scoped helper if one exists

## Design

Implement the bridge as a small script invoked by `cctrl peer mcp`. A Python
stdio MCP server is preferable to implementing JSON-RPC in bash. Keep it thin:
validate tool inputs, call the existing CLI JSON commands, parse results, and
return MCP tool responses. This minimizes the chance that CLI behavior and MCP
behavior drift.

Identity is configuration, not a tool argument. The bridge resolves its peer
identity once at startup (`--as`, falling back to `CCTRL_PEER`), validates it
with the plan 002 resolver, and passes it to every underlying CLI call. This
keeps tool schemas small, prevents an agent from acking or sending as another
peer, and means each agent's MCP config entry pins who it is.

Testing approach: unit-only.

Because this repo has no Python package manager and no existing MCP Python
dependency, implement a narrow dependency-free stdlib bridge in
`lib/peer_mcp.py`. Use newline-delimited JSON-RPC 2.0 over stdio — this is the framing the MCP
spec defines for stdio transports (one message per line, no Content-Length
headers); both Claude Code and Codex stdio clients speak it. Support only the
client lifecycle needed: `initialize`, `notifications/initialized`,
`tools/list`, and `tools/call`. Return JSON-RPC method-not-found or invalid-params errors for
unsupported methods and malformed tool arguments.
Keep stdout protocol-clean: JSON-RPC responses only on stdout, with all logs and
subprocess stderr routed to stderr.

Tool responses should use a consistent shape: `{"ok":true,"data":...}` for
successful calls and `{"ok":false,"error":{"code":"...","message":"..."}}` for
validation, unknown peer, and mailbox errors. `check_messages` wraps the
read-only count summary from plan 005; `recv_message` returns full message
bodies and applies the same delivered-state semantics as `cctrl peer recv`.
`send_message` passes the body to `cctrl peer send ... --body-file -` over
stdin to avoid shell-quoting limits.

**Files expected to change:**

- `cctrl`: add an `mcp` case to `cmd_peer` that runs `exec python3 "$SCRIPT_DIR/lib/peer_mcp.py" --as "<resolved identity>"` (same invocation pattern as `lib/usage_costs.py`)
- `lib/peer_mcp.py`: stdio MCP bridge implementation
- `tests/run-tests.sh`: add bridge smoke tests and command-contract tests
- `README.md`: add MCP registration example and tool list
- `completions/_cctrl`: add `peer mcp`

**Tool contract:**

- `whoami({})`
- `list_peers({})`
- `resolve_peer({"name": "comet"})`
- `send_message({"to": "comet", "subject": "...", "body": "..."})`
- `check_messages({})`
- `recv_message({"status": "queued,delivered"})`
- `show_message({"id": "msg_..."})`
- `ack_message({"id": "msg_..."})`

If MCP dependencies are not already available, prefer a dependency-light
implementation using the standard library over adding a package manager or
vendored dependency.

**Out of scope:** hosted HTTP MCP, remote machine federation, tmux delivery
changes, and orchestrator watch loops.

## Tasks

1. Scaffold `lib/peer_mcp.py` — stdlib-only, `#!/usr/bin/env python3` + `from __future__ import annotations` (match `lib/usage_costs.py` style) — with the newline-delimited JSON-RPC read/dispatch/respond loop.
2. Add `cctrl peer mcp` dispatch and the bridge script.
3. Implement the eight MCP tools by wrapping existing `cctrl peer ... --json` commands, injecting the startup identity into every underlying call.
4. Normalize MCP error responses for validation failures, unknown peers, and mailbox errors.
5. Add smoke tests that drive the bridge by piping `printf`-built JSON-RPC lines (initialize, tools/list, one tools/call) into its stdin and reading responses with a timeout — no coproc or fifo plumbing needed.
6. Update README with registration instructions and examples for both Codex and Claude Code.
7. Update completions.

## Verification

Checks:
- [cmd] `bash -n cctrl && bash -n tests/run-tests.sh && zsh -n completions/_cctrl`
- [cmd] `test ! -f lib/peer_mcp.py || python3 -m py_compile lib/peer_mcp.py`
- [cmd] `tests/run-tests.sh`
- [assert] MCP bridge smoke test in `tests/run-tests.sh` shows the peer messaging tools are advertised
- [assert] MCP bridge smoke test calls `send_message` and `recv_message` through stdio against `CCTRL_DATA_DIR="$TMPDIR/data"` and observes the expected mailbox side effects
- [assert] MCP bridge smoke test shows startup fails with a clear error when neither `--as` nor `CCTRL_PEER` provides an identity
- [manual] real-client smoke: register the bridge with an actual client (`claude mcp add` and a Codex `config.toml` entry), confirm the tools list renders and one `send_message` round-trips into the mailbox

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | MCP protocol boundary and dependency strategy need review before implementation | 1 | CLEAR | 0 issues; Codex hardening: real-client manual smoke check (claude + codex registration) |

- **VERDICT:** ENG CLEARED. Ready to implement.
