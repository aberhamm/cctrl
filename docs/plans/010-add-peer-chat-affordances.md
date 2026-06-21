---
id: 010
title: Add peer chat affordances over tmux sessions
status: pending
blocked-by: [009]
priority: 10
goal: tmux-peer-direct-chat
allows-migrations: false
needs-review: none
created: 2026-06-14
---

## Requirements

Peers should feel like human role names for live tmux agents, not like a
separate transport layer. Add peer commands that make the backing tmux session
visible and let users send direct chat messages to a peer's live session while
leaving the durable mailbox path intact for async work.

**Acceptance criteria:**

- [ ] `cctrl peer session <peer>` prints the resolved backing tmux session for a live tmux-capable peer.
- [ ] `cctrl peer session <peer> --json` returns the canonical peer name, requested label, session or tmux target, live status, and a clear error for peers without a live tmux session.
- [ ] `cctrl peer attach <peer>` resolves the peer to its backing tmux session and attaches to that session.
- [ ] `cctrl peer say <peer> -- "message"` resolves the peer or alias to a live tmux session and sends a direct chat message through `session say`.
- [ ] `cctrl peer say` supports the same message-input and safety flags as `session say`: `--body-file PATH|-`, `--no-submit`, `--json`, and `--force-busy`.
- [ ] `peer say` never writes to `data/messages.jsonl`, never changes mailbox status, and never records nudge metadata.
- [ ] `peer session`, `peer attach`, and `peer say` reject non-local peer host metadata with an actionable hint to run `cctrl --host <host> peer ...`; they do not auto-SSH based on registry metadata.
- [ ] `cctrl --host <host> peer attach <peer>` is treated as an interactive remote command and requests a TTY, matching `session attach`.
- [ ] Human `cctrl peer ls` shows the backing `SESSION` and live/offline status by default so peer-to-session mapping is visible without `--json`.
- [ ] README explains the split: `peer say` for live tmux chat; `peer send` for durable async mailbox delivery.

## Design

Build on plan 009's direct session command. Add peer-level affordances that
resolve a peer to `.tmux_target // .session` and then either print it, attach
to it, or delegate to the session say path. Keep `peer say` intentionally
separate from `peer send`: direct chat is immediate terminal input, while
mailbox send remains queued/delivered/acked async work.

`peer session` should use the existing peer resolver, including aliases and
metadata-derived peers. It should fail clearly for polling-only/MCP-only peers,
unknown peers, and stale sessions. Human output should be concise, for example
`comet -> TMUX--ctrl--3`; JSON output should include enough fields for scripts
to choose whether a peer is live.

Resolution must go through the existing peer JSON resolver instead of directly
reading `peers.json`, so canonical alias handling and the
live-derived-over-stale-manual behavior from earlier peer work remain intact.

Peer host metadata is descriptive, not an implicit transport. If the resolved
peer has `.host` set to anything other than the current host label (`local` or
`${CCTRL_HOST_PREFIX}`), local direct-chat commands must fail with a hint such
as `Run: cctrl --host studio peer say comet -- ...`. The top-level `--host`
forwarding layer remains the only cross-host execution path.

`peer ls` currently exposes session information through JSON but hides it in
human output. Add visible columns rather than replacing `peer status`; mailbox
queue counts can remain in `peer status` to avoid making `peer ls` a second
status dashboard.

Testing approach: unit-only.

**Files expected to change:**

- `cctrl`: add `peer session`, `peer attach`, `peer say`, and richer human `peer ls`
- `tests/run-tests.sh`: add fake peer/tmux tests for session resolution, attach, direct say, aliases, offline errors, and no mailbox mutation
- `README.md`: document peer/session mental model and direct-vs-async examples
- `completions/_cctrl`: complete new peer commands and shared say flags

`peer attach` is intentionally interactive and has no JSON mode. Remote command
forwarding must recognize `peer attach` as TTY-requiring, the same way it
already recognizes `session attach`.

**Out of scope:** changing mailbox semantics, adding `peer ask`, changing `peer nudge`/`peer watch`, adding session-addressed mailbox recipients, implicit SSH forwarding from peer host metadata, and automatic startup prompt injection.

## Tasks

1. Add a helper that resolves a peer JSON object to a live tmux target with consistent human and JSON errors.
2. Implement `cctrl peer session <peer> [--json]`.
3. Implement `cctrl peer attach <peer>` by resolving the peer and delegating to the existing session attach path.
4. Implement `cctrl peer say <peer> ...` by resolving the peer and delegating to the plan 009 session say behavior.
5. Add local-vs-remote host checks for direct peer commands, with tests for non-local manual peer metadata.
6. Update remote forwarding so `cctrl --host <host> peer attach <peer>` uses a TTY.
7. Update `peer ls` human output to include `SESSION` and live/offline status without removing existing JSON fields.
8. Update help text, completions, and README examples.
9. Add tests proving aliases resolve, offline peers fail clearly, remote-host metadata fails with a `--host` hint, direct say does not touch mailbox files, and attach/say target the resolved tmux session.

## Verification

Checks:
- [cmd] `bash -n cctrl && bash -n tests/run-tests.sh && zsh -n completions/_cctrl`
- [cmd] `tests/run-tests.sh`
- [cmd] `grep -Eq 'peer session' tests/run-tests.sh && grep -Eq 'tmux_target' tests/run-tests.sh`
- [cmd] `grep -Eq 'peer say' tests/run-tests.sh && grep -Eq 'messages\\.jsonl|message.*unchanged|mailbox' tests/run-tests.sh`
- [cmd] `grep -Eq 'peer attach' tests/run-tests.sh && grep -Eq 'attach-session -t|attach-session.*resolved' tests/run-tests.sh`
- [cmd] `grep -Eq 'non-local|remote-host|--host <host>|--host.*peer say' tests/run-tests.sh`
- [cmd] `grep -Eq -- '--host[[:space:]]+studio.*peer attach|peer attach.*ssh.*-t|ssh.*-t.*peer attach' tests/run-tests.sh`
- [cmd] `grep -Eq 'peer ls' tests/run-tests.sh && grep -Eq 'SESSION|live|offline|status column' tests/run-tests.sh`
