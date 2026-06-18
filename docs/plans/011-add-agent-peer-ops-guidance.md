---
id: 011
title: Add agent-facing peer operations guidance
status: pending
blocked-by: [010]
priority: 11
goal: tmux-peer-direct-chat
allows-migrations: false
needs-review: none
created: 2026-06-14
---

## Requirements

Humans can learn `peer say` from README examples, but agents need a compact
operating contract that tells them when to direct-chat a live peer and when to
use the async mailbox. Add an agent-facing help surface and update the MCP
bridge so agent tooling can discover the same direct-chat path.

**Acceptance criteria:**

- [ ] `cctrl peer help-agent` prints concise agent instructions that distinguish `peer say`, `peer send`, `peer recv`, and `peer ack`.
- [ ] `cctrl peer help-agent --as comet` validates and canonicalizes the peer identity, then prints instructions phrased for that peer.
- [ ] Bare `cctrl peer help-agent` prints generic guidance when neither `--as` nor `CCTRL_PEER` is set; it does not fail for missing identity.
- [ ] `CCTRL_PEER=comet cctrl peer help-agent` prints the same peer-specific guidance as `--as comet`.
- [ ] `cctrl peer help-agent --json` returns a structured version of the same contract for prompt builders and tests.
- [ ] `cctrl peer mcp` advertises a direct peer chat tool, `say_peer`, after plan 010 exists.
- [ ] The MCP `say_peer` tool sends direct chat through `cctrl peer say` and does not create mailbox messages.
- [ ] The MCP `say_peer` tool preserves multi-line and trailing-newline bodies by passing the body through `cctrl peer say --body-file -`.
- [ ] MCP tool descriptions and README examples teach the default rule: use `peer say` for live tmux agents, use `peer send` for durable async/offline work.
- [ ] `cctrl start --peer` does not automatically inject extra prompt text in this plan; automatic startup injection remains explicitly out of scope unless a future plan opts in.
- [ ] Help, completions, and docs make the no-injection decision clear so agents only receive this contract when a user prompt, MCP tool surface, or explicit `peer help-agent` call provides it.

## Design

Add a small command-oriented contract rather than another hidden behavior layer.
The contract should be short enough for an orchestrator or startup prompt to
include verbatim:

```text
You are running as peer: comet.
Use `cctrl peer say <peer> -- "<message>"` to talk to a live tmux peer.
Use `cctrl peer send <peer> --from comet -- "<message>"` for durable async work.
Use `cctrl peer recv --json` and `cctrl peer ack <id> --json` to handle mailbox work.
```

The automatic injection decision is resolved here: do not inject this text into
all `start --peer` launches. Injection changes model behavior and prompt size
for every peer session, so it should remain a separate opt-in feature if it is
ever needed. This plan only exposes guidance through explicit commands, docs,
and MCP tool metadata.

Identity behavior is explicit: a bare `peer help-agent` prints generic
instructions; `--as NAME` and `CCTRL_PEER` canonicalize the identity and print
peer-specific examples using that name.

Update `lib/peer_mcp.py` so MCP-backed agents see the direct path too. Add a
`say_peer` tool that accepts `to`, `body`, and optional `submit`/`force_busy`
arguments. The bridge must pass `body` through stdin to `cctrl peer say
<to> --json --body-file -` so newlines are preserved. `submit` defaults to
`true`; `submit:false` maps to `--no-submit`. `force_busy:true` maps to
`--force-busy`. Non-boolean `submit` or `force_busy` values are validation
errors in the same style as the existing MCP tools. Keep existing mailbox
tools unchanged.

Testing approach: unit-only.

**Files expected to change:**

- `cctrl`: add `peer help-agent`, structured output, help text, and completions
- `lib/peer_mcp.py`: add `say_peer` tool and direct-chat tool descriptions
- `tests/run-tests.sh`: add help-agent and MCP `say_peer` smoke tests
- `README.md`: document the agent-facing contract and the no automatic injection decision
- `completions/_cctrl`: complete `peer help-agent`

**Out of scope:** automatic prompt injection in `start --peer`, renaming mailbox commands, adding `peer ask`, changing hook behavior, and making the mailbox session-addressable.

## Tasks

1. Implement `cctrl peer help-agent [--as NAME] [--json]` using the existing peer identity resolver where applicable.
2. Add human and JSON tests for generic no-identity guidance, explicit `--as`, ambient `CCTRL_PEER`, and invalid peers.
3. Add `say_peer` to `lib/peer_mcp.py` by delegating to `cctrl peer say` and preserving the MCP bridge's existing validation/error style.
4. Extend the MCP smoke test to confirm `say_peer` is advertised, maps `submit:false` and `force_busy:true` to the expected CLI flags, preserves trailing newlines, and calls the direct tmux path without creating a mailbox message.
5. Update README and command help with the direct-vs-async agent contract.
6. Update completions for `peer help-agent`.

## Verification

Checks:
- [cmd] `bash -n cctrl && bash -n tests/run-tests.sh && python3 -m py_compile lib/peer_mcp.py && zsh -n completions/_cctrl`
- [cmd] `tests/run-tests.sh`
- [assert] the test suite shows `cctrl peer help-agent --as comet` prints the canonical peer and includes `peer say`, `peer send`, `peer recv`, and `peer ack`
- [assert] the test suite shows bare `cctrl peer help-agent` succeeds with generic guidance
- [assert] the test suite shows `cctrl peer help-agent --json` returns valid structured JSON with direct and async command examples
- [assert] the MCP smoke test advertises `say_peer`
- [assert] the MCP `say_peer` test sends through the fake tmux path, preserves a trailing newline, and leaves `messages.jsonl` unchanged

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | Architecture, edge cases, tests, and agent-surface contracts | 1 | CLEAR | 5 issues found; all addressed in plan text |
| Codex Review | `codex exec` | Independent plan-structure and edge-case check | 1 | CLEAR | Host metadata, help-agent identity, MCP flag mapping, busy status, and TTY behavior were clarified |

- **UNRESOLVED:** 0
- **VERDICT:** ENG CLEARED — ready to implement after dependencies 009 and 010 are done.
