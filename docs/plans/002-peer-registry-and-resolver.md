---
id: 002
title: Add peer registry and resolver for addressable agents
status: pending
blocked-by: []
priority: 2
goal: cctrl-agent-peer-messaging
allows-migrations: false
needs-review: none
created: 2026-06-08
---

## Requirements

Users need a stable way to address running or manually registered coding agents
by name, independent of whether those agents live in tmux. This plan adds the
peer address book and resolver that later mailbox, tmux delivery, polling, and
MCP plans build on.

**Acceptance criteria:**

- [ ] `cctrl peer register comet --dir /Users/matthew/_projects/comet-automation --agent codex` saves a peer to `data/peers.json`
- [ ] `cctrl peer ls --json` lists manually registered peers and derived cctrl-managed tmux sessions, including each peer's `purpose` when available
- [ ] `cctrl peer resolve comet --json` returns a single normalized peer object with name, aliases, host, dir, agent, session, purpose, computed tmux target, and capabilities
- [ ] `cctrl peer alias comet comet-agent` adds an alias that resolves to the same peer
- [ ] `cctrl peer unregister comet` removes a manually registered peer without affecting live tmux sessions
- [ ] Registering a peer whose name matches a live cctrl-managed tmux session succeeds, with the derived peer marked as shadowed in `peer ls`
- [ ] Non-tmux peers can be registered with polling capabilities and no tmux target
- [ ] Peer identity can be resolved from `--as <peer>` or `CCTRL_PEER`, with clear errors when ambiguous or missing
- [ ] Peer names and aliases reject whitespace, shell metacharacters, collisions, and the reserved name `user` (plan 003 uses it as the default human sender identity)

## Design

Add a new `peer` command namespace to the main `cctrl` script. Introduce a
`CCTRL_DATA_DIR` override for new peer-messaging runtime files, defaulting to
`$SCRIPT_DIR/data`; tests must point this at `$TMPDIR/data` so they never mutate
the developer's real runtime registry. `PEERS_FILE` resolves as
`${CCTRL_DATA_DIR:-$SCRIPT_DIR/data}/peers.json`; existing data files
(shortcuts, hosts, config) keep their current hardcoded paths — `CCTRL_DATA_DIR`
scopes peer-messaging files only. The test harness preamble must also unset
`CCTRL_PEER` alongside the existing env isolation. The peer registry is a machine-local
runtime file at `${CCTRL_DATA_DIR}/peers.json`. It stores only user-authored
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
    "purpose": "PiKVM automation work",
    "capabilities": ["mailbox", "polling", "tmux"],
    "registered_at": "2026-06-08T00:00:00Z"
  }
}
```

Manual non-tmux peers should omit `session` and include `polling` in
`capabilities`. Derived tmux peers should include `tmux` and `mailbox`; they
should not be written back to `data/peers.json` unless the user explicitly
registers or aliases them. The stored schema has no `tmux_target`: pane targets
go stale across restarts, so the pane is resolved from `session` at read or
delivery time. `peer resolve --json` may include a computed `tmux_target`
field, derived rather than stored.

When a manual peer name collides with a derived tmux session name, the manual
entry wins and the derived peer is shadowed. `peer ls` must flag shadowed
entries with a `"shadows"` field naming the hidden session, and `peer resolve`
must warn on stderr in human mode. Derived peers inherit `purpose` from session
metadata; manual peers set it with `--purpose`.

Peer `agent` is registry metadata, not a launch request. Accept `claude`,
`codex`, or any non-empty `other` label without calling `_normalize_agent`;
only `cctrl start --agent ...` should use launch-agent normalization.

If `tmux` is unavailable, `peer ls` and `peer resolve` must still work for
manual non-tmux peers. In that case derived tmux peers are omitted, with a clear
human warning and a JSON field indicating derived session discovery was skipped.
`peer alias` mutates manual registry entries only; aliasing a derived-only tmux
peer should fail with an actionable "register this peer first" message.

**Files expected to change:**

- `cctrl`: add `CCTRL_DATA_DIR`, `PEERS_FILE`, peer registry helpers, name validation, identity resolution, and `cmd_peer`
- `tests/run-tests.sh`: add fake registry tests and fake tmux-derived peer tests
- `completions/_cctrl`: add `peer` subcommand and basic peer-name completions
- `README.md`: document peer registry concepts and commands

**Command contract:**

- `cctrl peer ls [--json]`
- `cctrl peer resolve <name-or-alias> [--json]`
- `cctrl peer register <name> [--alias NAME] [--host HOST] [--dir DIR] [--agent claude|codex|other] [--session SESSION] [--purpose TEXT] [--capability NAME]`
- `cctrl peer alias <name> <alias>`
- `cctrl peer unregister <name>`
- `cctrl peer whoami [--as NAME] [--json]`

`--as` should be supported inside the peer namespace and should fall back to
`CCTRL_PEER`. Later plans will use the same identity behavior for inbox and ack
commands.

**Out of scope:** message storage, message delivery, MCP server startup, remote
host synchronization, and automatic idle detection.

## Tasks

1. Add `CCTRL_DATA_DIR`, `PEERS_FILE`, and helper functions for initialization, JSON reads/writes, peer name validation, and ISO timestamp generation.
2. Implement manual peer registration, aliasing, unregister, and normalized JSON output.
3. Implement resolver behavior that merges manual peers with derived peers by calling the internal `_session_list --json` helper in-process (never `cctrl session ls` as a subprocess), with its own tmux-availability guard, manual-wins shadowing, and `purpose` passthrough from session metadata.
4. Implement peer identity resolution from `--as`, `CCTRL_PEER`, and peer names.
5. Add tests for manual non-tmux peers, derived tmux peers, alias resolution, manual-over-derived shadowing, purpose passthrough, collision rejection, tmux-missing manual peer resolution, resolving an unknown peer name (clean error + exit code), and `CCTRL_PEER`; all tests must set `CCTRL_DATA_DIR="$TMPDIR/data"`.
6. Update completions, `cmd_help` output, and README with the new registry commands.

## Verification

Checks:
- [cmd] `bash -n cctrl && bash -n tests/run-tests.sh && zsh -n completions/_cctrl`
- [cmd] `tests/run-tests.sh`
- [assert] `PATH="$TMPDIR:$PATH" CCTRL_PEER=comet ./cctrl peer whoami --json` in the test suite returns `"name": "comet"`
- [assert] `./cctrl peer register bad/name` in the test suite fails with an actionable validation error

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | Registry schema and command contract must be stable before dependent plans | 1 | CLEAR | 1 issue (single-file architecture, resolved 1A), 1 test gap added, reserved name `user` added |

- **CODEX:** combined outside-voice pass over plans 002–008; 16 findings triaged, 4 hardening changes applied across the backlog.
- **VERDICT:** ENG CLEARED. Ready to implement.
