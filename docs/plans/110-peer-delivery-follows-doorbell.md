---
id: 110
title: Peer delivery follows the doorbell (reply, MCP send and deliver stop pushing into non-pilot panes)
status: draft
blocked-by: []
priority: 20
allows-migrations: false
review-required: eng
created: 2026-10-28
approval: pending (Matthew approved the recommendation in mdec-1028-cctrl-recommendations-1-7; plan review and rollout still need explicit OK)
reviews: []
related: 108, 111
---

## Problem

Plan 108 gated only the `peer send` default by the doorbell. Every other
delivery path still pushes into the recipient's pane regardless of the bell:
`peer reply` (always delivers, no `--no-deliver` flag), the MCP `send_message`
tool (hard-codes `--deliver`, lib/peer_mcp.py ~335), explicit `peer send --deliver`,
and `peer deliver`/`peer nudge`. Delivery tries the Claude Code
messaging-socket adapter first (cctrl ~8593-8613 in release fac2ea2), which
skips `_peer_pane_ready_for_delivery`; only the tmux fallback runs that check.
Claude Code holds that cross-session input behind a security prompt, so
non-pilot sessions show held "N new peer messages" bodies. Seven such nudges
were traced after the 108 install, and the same mechanism predates 108.
Doctrine is stopgapped in AGENTS.md (send `--no-deliver`); this plan is the code fix.

## Design

1. One predicate decides whether a recipient may be pushed to: the existing
   doorbell enabled-for-recipient check (peers/roles allowlist), reused from
   `_peer_doorbell_send_defaults_deliver`. Factor it into a shared helper.
2. `peer reply`, MCP `send_message` and `peer deliver`/`nudge` call it. Bell-enabled
   recipient: deliver as today. Otherwise: queue only, exit 0, and tell the sender.
   Text notice on stderr plus a `delivery: "queued-only"` and `reason: "recipient-not-doorbell-enabled"`
   field in `--json` output (the MCP result carries the same field).
3. `peer reply` gains `--deliver` / `--no-deliver` (parity with send). MCP drops the
   hard-coded `--deliver` and inherits the send policy.
4. The socket adapter path gets the same pane-readiness check the tmux path has
   (idle Claude pane: not working, no modal, no draft); a blocked delivery is
   queued with a warning, as the 108 default already does.
5. Explicit `--deliver` back-compat. Decision, recommended: **explicit `--deliver`
   is allowed only to doorbell-enabled recipients; to anyone else it degrades to
   queued-only with the notice, and there is no override flag.** Reason: the
   problem is the push itself, so a `--force-deliver` would recreate it with one
   more flag, and agents under bypass permissions use any flag a brief mentions.
   If an operator needs a one-off push, they enable the bell for that peer
   (auditable, reversible). Alternative if rejected: `--force-deliver`, human-only,
   refused when `CCTRL_SESSION_NAME` is set. Scripts that relied on `--deliver`
   keep exit 0; only the delivery outcome changes, and it is reported.

## Acceptance criteria

- No path (`reply`, MCP `send_message`, `send --deliver`, `deliver`, `nudge`) writes to
  a socket or tmux pane of a recipient that is not doorbell-enabled.
- Every such call to a non-enabled recipient returns exit 0, leaves the message
  queued, and reports `queued-only` in text and JSON.
- Bell-enabled recipients behave exactly as after 108 (idle pane only).
- The socket path refuses a busy, modal or drafting pane and queues with a warning.
- `peer reply --no-deliver` exists; `--deliver` and `--no-deliver` together is a usage error.
- AGENTS.md reverts to describing reply/send as queue-first, with the doorbell
  doing pickup; the "prefer `send --no-deliver`" caveat is removed.

## Tests

- Unit/suite: for each path, a non-enabled recipient gets queued-only and zero
  socket/tmux writes (stubbed adapters assert no call); an enabled recipient gets one.
- Socket-path readiness: busy, modal, draft and idle fixtures.
- JSON/text notice shape for sender; MCP result field.
- **Real-tool tests (AGENTS.md rule on stubbed tools):** (a) a real private tmux
  server on a `-S` socket with a scratch pane running a long `sleep` as the "Claude"
  process: `peer reply` to a non-enabled recipient sends no keys (capture-pane
  unchanged); (b) a real unix-domain socket listener in a scratch dir standing in for
  `messagingSocketPath`: assert zero frames for a non-enabled recipient and one for
  an enabled idle one; (c) real `pgrep`/`ps` readiness probe against scratch processes.
- Run through the repo's isolated harness only; never against the live fleet.

## Out of scope

- Sender attestation and a sender allowlist: plan 111 (precondition for widening the bell).
- Changing Claude Code's cross-session input hold.

## Tasks

1. Shared enabled-for-recipient helper. 2. Gate reply/MCP/deliver. 3. Reply flags.
4. Socket readiness check. 5. Tests incl. real-tool ones. 6. README/CHANGELOG/AGENTS.md.
