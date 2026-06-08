---
id: 002
title: Add peer registry and resolver for addressable agents
status: blocked
blocked-by: []
priority:
goal: cctrl-agent-peer-messaging
allows-migrations: false
needs-review: eng
created: 2026-06-08
---

## Requirements

Users need a stable way to address running or manually registered coding agents
by name, independent of whether those agents live in tmux. This plan adds the
peer address book and resolver that later mailbox, tmux delivery, polling, and
MCP plans build on.

**Acceptance criteria:**

- [ ] `cctrl peer register comet --dir /Users/matthew/_projects/comet-automation --agent codex` saves a peer to `data/peers.json`
- [ ] `cctrl peer ls --json` lists manually registered peers and derived cctrl-managed tmux sessions
- [ ] `cctrl peer resolve comet --json` returns a single normalized peer object with name, aliases, host, dir, agent, session, tmux target, and capabilities
- [ ] `cctrl peer alias comet comet-agent` adds an alias that resolves to the same peer
- [ ] `cctrl peer unregister comet` removes a manually registered peer without affecting live tmux sessions
- [ ] Non-tmux peers can be registered with polling capabilities and no tmux target
- [ ] Peer identity can be resolved from `--as <peer>` or `CCTRL_PEER`, with clear errors when ambiguous or missing
- [ ] Peer names and aliases reject whitespace, shell metacharacters, and collisions

## Design

Add a new `peer` command namespace to the main `cctrl` script. The registry is a
machine-local runtime file at `data/peers.json`. It stores only user-authored
peer metadata; live tmux-backed peers are derived from `cctrl session ls --json`
at read time and merged with the manual registry.

Testing approach: unit-only.

**Peer schema:**

```json
{
  "comet": {
    "name": "comet",
    "aliases": ["comet-agent"],
    "host": "local",
    "dir": "/Users/matthew/_projects/comet-automation",
    "agent": "codex",
    "session": "comet",
    "tmux_target": "comet:0.0",
    "capabilities": ["mailbox", "polling", "tmux"],
    "registered_at": "2026-06-08T00:00:00Z"
  }
}
```

Manual non-tmux peers should omit `session` and `tmux_target` and include
`polling` in `capabilities`. Derived tmux peers should include `tmux` and
`mailbox`; they should not be written back to `data/peers.json` unless the user
explicitly registers or aliases them.

**Files expected to change:**

- `cctrl`: add `PEERS_FILE`, peer registry helpers, name validation, identity resolution, and `cmd_peer`
- `tests/run-tests.sh`: add fake registry tests and fake tmux-derived peer tests
- `completions/_cctrl`: add `peer` subcommand and basic peer-name completions
- `README.md`: document peer registry concepts and commands

**Command contract:**

- `cctrl peer ls [--json]`
- `cctrl peer resolve <name-or-alias> [--json]`
- `cctrl peer register <name> [--alias NAME] [--host HOST] [--dir DIR] [--agent claude|codex|other] [--session SESSION] [--tmux-target TARGET] [--capability NAME]`
- `cctrl peer alias <name> <alias>`
- `cctrl peer unregister <name>`
- `cctrl peer whoami [--as NAME] [--json]`

`--as` should be supported inside the peer namespace and should fall back to
`CCTRL_PEER`. Later plans will use the same identity behavior for inbox and ack
commands.

**Out of scope:** message storage, message delivery, MCP server startup, remote
host synchronization, and automatic idle detection.

## Tasks

1. Add `PEERS_FILE` and helper functions for initialization, JSON reads/writes, peer name validation, and ISO timestamp generation.
2. Implement manual peer registration, aliasing, unregister, and normalized JSON output.
3. Implement resolver behavior that merges manual peers with derived peers from `_session_list --json` or equivalent internal helpers.
4. Implement peer identity resolution from `--as`, `CCTRL_PEER`, and peer names.
5. Add tests for manual non-tmux peers, derived tmux peers, alias resolution, collision rejection, and `CCTRL_PEER`.
6. Update completions and README with the new registry commands.

## Verification

Checks:
- [cmd] `bash -n cctrl completions/_cctrl tests/run-tests.sh`
- [cmd] `tests/run-tests.sh`
- [assert] `PATH="$TMPDIR:$PATH" CCTRL_PEER=comet ./cctrl peer whoami --json` in the test suite returns `"name": "comet"`
- [assert] `./cctrl peer register bad/name` in the test suite fails with an actionable validation error

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | Registry schema and command contract must be stable before dependent plans | 0 | REQUIRED | - |
