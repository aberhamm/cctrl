---
id: 004
title: Add tmux nudge adapter for peer messages
status: pending
blocked-by: [002, 003, 005]
priority: 5
goal: cctrl-agent-peer-messaging
allows-migrations: false
needs-review: none
created: 2026-06-08
---

## Requirements

The orchestrator workflow needs a way to wake an agent in a tmux pane when that
peer has queued mail. This plan adds tmux as the first active delivery adapter.
The adapter is a doorbell, not a transport: message bodies travel only through
the mailbox (`peer recv`, plan 005). The pasted payload is a constant one-line
nudge pointing the agent at its inbox, which keeps the injection surface fixed,
sidesteps body-escaping entirely, and works for unattended sessions.

**Acceptance criteria:**

- [ ] `cctrl peer deliver comet --dry-run` prints the nudge that would be pasted and does not mutate mailbox state
- [ ] `cctrl peer deliver comet` pastes one nudge for `comet` when the peer has queued messages and a resolvable tmux session
- [ ] The nudge is a constant single line containing the queued count and the exact `cctrl peer recv` command; it never contains message bodies
- [ ] One nudge per recipient per pass, regardless of how many messages are queued
- [ ] Nudges are submitted (Enter) by default; `--no-submit` leaves the nudge in the input box
- [ ] Delivery uses `tmux load-buffer` and `tmux paste-buffer` with a scoped buffer name, never shell-interpolated `send-keys` for the nudge text
- [ ] Before pasting, the adapter captures the target pane and defers the nudge when a known modal-prompt marker is visible — messages stay queued; `deferred` is the per-recipient result in command output, never a message status
- [ ] Nudge attempts update `nudge_count`, `last_nudge_at`, and `last_nudge_error` and append history events; message `status` never changes
- [ ] The check-paste-record cycle runs under a single mailbox lock so concurrent deliver invocations produce at most one nudge
- [ ] tmux commands in the delivery cycle run under a short timeout (default 5s); a hung tmux records a failed nudge and releases the mailbox lock instead of blocking send/recv/ack machine-wide
- [ ] `cctrl peer deliver --all` nudges every recipient with queued messages and tmux capability; peers without tmux capability are skipped with a clear status in human and JSON output
- [ ] `--inline <message-id>` pastes a full message body explicitly: paste-only, never auto-submitted, documented as unsafe for unattended sessions; it resolves the recipient through the registry and passes the same readiness guard

## Design

Add a tmux adapter under the `peer deliver` command. The adapter resolves the
recipient peer, verifies `tmux` is available, resolves the pane target from the
peer's `session` at delivery time (plan 002 stores no pane target), checks pane
readiness, pastes the nudge, and records nudge metadata through the plan 003
locking helper — holding the lock across the entire check-paste-record cycle.

The peer's `session` field stores the exact tmux session name (for derived
peers, the full `TMUX--...` slug). cctrl sessions are created single-window,
single-pane, so the session name is passed directly as the `-t` target with no
pane disambiguation.

Testing approach: unit-only.

**Nudge format (constant, one line):**

```text
[cctrl] N new peer message(s) for <peer>. Run: cctrl peer recv --as <peer> --json
```

Submit is the safe default *because* the payload is a fixed short string; the
risk calculus that justifies paste-only for arbitrary bodies does not apply
here. `--no-submit` opts out for supervised use.

**Readiness guard.** Before pasting, run `tmux capture-pane -p` on the last
~15 lines of the target pane and defer when a modal-prompt marker is visible.
Both Claude Code and Codex render approval dialogs that respond to single
keystrokes, so a paste at the wrong moment could answer a pending permission
prompt. Marker lists are per-agent and are the adapter's only agent-specific
knowledge:

- `claude` starter set: a line containing `Do you want`, `Do you trust`, or a
  `❯ 1.` selection list (permission/trust dialogs)
- `codex` starter set: a line containing `Allow command`, `Approve`, or a
  `y/N` choice prompt
- unknown agents: defer unless `--force-busy` is passed

The marker lists are constants in `cctrl`, documented as starter sets to be
verified against real dialogs during implementation and extended as needed.

Deferral is not an error: messages stay queued and the next watch pass retries.

**State handling.** Delivery never transitions message status. `delivered` is
reserved for `peer recv` (plan 005). Failed pastes (missing session, dead pane,
tmux error) record `last_nudge_error` and a typed `event: "nudge", ok: false`
history record (plan 003 schema); the message stays queued. This is what lets plan 007's watch loop re-nudge and back off without a
`failed` state.

Use a buffer name such as `cctrl-nudge-<peer>`, load the nudge through stdin,
paste the named buffer into the target pane, and delete the buffer after the
attempt so nudge text is not left in tmux's global buffer list.

**Files expected to change:**

- `cctrl`: nudge formatting, pane readiness guard, delivery-time target resolution, `peer deliver`
- `tests/run-tests.sh`: extend fake tmux to log `load-buffer`, `paste-buffer`, and `send-keys`, and to return `$TMUX_FAKE_CAPTURE_PANE` fixture content for `capture-pane` (empty default = idle pane; busy-pane tests set it to a modal-prompt screen)
- `README.md`: document nudge delivery, the readiness guard, and `--inline` limitations
- `completions/_cctrl`: add `deliver` options

**Out of scope:** automatic background loops (plan 007), MCP tools (plan 006),
idle-hook doorbells (plan 008), and message polling itself (plan 005).

## Tasks

1. Add a helper that formats the constant nudge line from recipient name and queued count.
2. Add a helper that resolves and validates a peer's pane target from its `session` at delivery time.
3. Add the readiness guard with per-agent modal-prompt marker lists and `--force-busy`.
4. Implement `peer deliver <name|--all> [--dry-run] [--json] [--no-submit] [--inline ID] [--force-busy]`.
5. Record nudge metadata and history through the plan 003 locking helper, holding the lock across check-paste-record.
6. Add fake tmux tests: dry-run no-mutation, nudge paste with submit by default, `--no-submit`, busy-pane deferral, one nudge per recipient, nudge metadata recorded, failed target records `last_nudge_error` and leaves messages queued, named buffer cleanup, `--inline` paste-only, concurrent deliver produces one nudge.
7. Update README and completions.

## Verification

Checks:
- [cmd] `bash -n cctrl && bash -n tests/run-tests.sh && zsh -n completions/_cctrl`
- [cmd] `tests/run-tests.sh`
- [assert] fake tmux log in the test suite contains `load-buffer` and `paste-buffer` followed by a submit `send-keys` for `cctrl peer deliver comet`
- [assert] fake tmux log in the test suite contains no submit `send-keys` when `--no-submit` or `--inline` is used
- [assert] delivery tests prove dry-run mutates nothing, a successful nudge updates nudge metadata without changing message status, a busy pane defers with messages left queued, and a failed target leaves messages queued with `last_nudge_error` set
- [manual] real-tmux smoke: launch a scratch tmux session running a real agent, queue a message, run `cctrl peer deliver`, and confirm the nudge lands in the input box and submits

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | Terminal injection has quoting, safety, and state risk | 1 | CLEAR | 0 issues; Codex hardening: 5s tmux timeout, real-tmux manual smoke check |

- **VERDICT:** ENG CLEARED. Ready to implement.
