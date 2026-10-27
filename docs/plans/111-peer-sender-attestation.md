---
id: 111
title: Peer sender attestation at delivery time (precondition for widening the doorbell)
status: draft
blocked-by: []
priority: 25
allows-migrations: false
review-required: eng
created: 2026-10-28
approval: pending (Matthew approved the recommendation in mdec-1027-orch-cctrl-mailbox-fix; plan review and rollout still need explicit OK)
reviews: []
related: 108, 110
---

## Problem

Every fleet session runs `--permission-mode bypassPermissions`. A delivered
nudge carries no proof of who sent it, so widening pushed delivery to more
sessions would let an impersonated or stray message reach an agent that acts
without prompts. Current state (investigation of 2026-10-28):

- `audit.caller_tmux_session` comes from `_session_current_name` (cctrl ~16081):
  CCTRL_SESSION_NAME, or tmux plus a process-ancestry check. It is compared with
  `--from`/`--as` by `_peer_sender_binding_mismatch` (~7160), but `--impersonate`
  skips that check and only records `audit.impersonated: true` (~7495/7518).
- All of it is self-reported by a process with the same uid. `_peer_deliver_one_locked`
  never reads `audit`; nothing is verified at delivery time.
- Any same-user process can write to a session's `messagingSocketPath` directly.

## Design

1. **Deliver-time refusal.** Before a push, inspect every queued message that
   would be named in the nudge. If any has `audit.impersonated`, a
   `caller_tmux_session` different from `from`, or `caller_unresolved`, do not
   push: leave all queued, log, and tell the sender (same notice shape as plan 110).
2. **Sender allowlist for delivery.** Per-recipient list (and a role rule, for
   example only the fleet manager and the recipient's own orchestrator) in
   doorbell.json. A sender not on it queues only. Default for an enabled
   recipient: orchestrator and fleet-manager roles.
3. **Verify against cctrl's own records, not self-report.** Resolve the sending
   session from cctrl's session records (registry/session store, pane pid and
   tmux session id) and require the claimed `from` and `caller_tmux_session`
   to match that record. Never trust `audit.caller_tmux_session` alone. Open
   options for stronger proof, decided in eng review: a per-session 0600 secret
   token under data/ checked at delivery, or a small broker reading unix-socket
   peer credentials (LOCAL_PEERPID) mapped to a pane.
4. Claude Code's cross-session hold stays the last line of defence; nothing
   here touches it (the fleet manager's exact-body-match grant relies on it).

## Acceptance criteria

- A message with `audit.impersonated`, mismatched or unresolved caller is never pushed, and the sender is told.
- A sender off the recipient's allowlist is queued only.
- Delivery decisions use the session record; a forged `audit` field in the message file changes nothing.
- No widening of the doorbell beyond the pilot until this ships (stated in the 108 rollout).
- Honest limit documented: same-uid processes can still write the socket directly; this plan narrows cctrl's own paths and does not claim a security boundary.

## Tests

- Fixtures for impersonated, mismatched, unresolved and forged-audit messages; allowlist hit and miss.
- **Real-tool test:** a real private tmux server (`-S` socket) with two scratch sessions; the real ancestry walk (real `ps`/`pgrep`) resolves the sender as the session it runs in and refuses a process outside any cctrl session. Token or peer-credential check against a real scratch unix socket if that option is chosen.

## Out of scope

Stopping pushes to non-enabled recipients (plan 110); a full authn system.

## Tasks

1. Deliver-time audit gate. 2. Allowlist config and `doorbell` CLI. 3. Session-record verification. 4. Decide and build stronger proof. 5. Tests. 6. Docs.
