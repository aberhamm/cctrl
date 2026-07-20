---
id: 034
title: Stamp the resolved recipient's identity at send time so the guard is exact
status: pending
blocked-by: [023, 032]
priority: 34
goal: cctrl-peer-identity-integrity
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-20
---

## Requirements

Plan 032's guard infers replacement from a timestamp inequality. That is sound
for mail already in the queue and needs no migration, but it is an inference: it
cannot distinguish *"this name was recycled"* from *"this mail was sent to a
name before its session existed"* without the `--allow-unknown` exemption
032 carries. This plan makes the check exact by recording, at send time, **which
occupant the sender actually resolved**.

It is deliberately last in the set and blocked on 023, because it edits
`_peer_cmd_send`'s `jq -cn` message construction (`cctrl:2663-2686`) — the same
block plan 023 is rewriting to add its `sender` object. Landing both
concurrently in a shared working tree is a guaranteed conflict; 032 was scoped
read-side precisely so the safety fix did not have to wait for this.

**Acceptance criteria:**

- [ ] A message records the recipient identity resolved at send time, alongside
      the existing `to` name. `_peer_cmd_send` already computes `to_peer_json`
      via `_peer_resolve_json` (`cctrl:2628-2650`) and currently discards
      everything but `.name` — stop discarding it.
- [ ] The stamp carries the recipient's `created_at`, and its `sessionId` where
      one is resolvable (`_session_id`, `cctrl:5504`).
- [ ] 032's guard prefers the stamp when present: replacement is then an exact
      mismatch, not a timestamp inequality.
- [ ] The `--allow-unknown` exemption becomes explicit — an unresolved recipient
      records no stamp, so the guard has positive evidence that no occupant was
      ever verified, rather than inferring it from history.
- [ ] Messages without a stamp (everything queued before this lands) keep
      resolving through 032's heuristic exactly as today. No stored message is
      rewritten.
- [ ] The field is additive and pruned with `with_entries(select(.value != null))`,
      matching the convention in `_peer_derived_json` and plan 023's `sender`.
- [ ] Coordinated with plan 023's author rather than merged blind — both plans
      add keys to one `jq -cn` literal.
- [ ] `data/peers.json` and `data/messages.jsonl` are never edited in place.

## Design

**Shape.** Mirror 023's `sender` object so the envelope reads symmetrically:

```json
"to": "TMUX--ms--obsidian-vault--5",
"recipient": {
  "name": "TMUX--ms--obsidian-vault--5",
  "created_at": "2026-07-20T13:39:20Z",
  "session_id": "…"
}
```

Keep the flat `to` string authoritative for selection and matching. Every reader
(`recv`, `inbox`, `outbox`, the delivery filter) already keys on it, and 032's
guard is a *predicate over* that selection, not a replacement for it. Adding a
second addressing path would create two ways to be wrong.

**Why `created_at` and not `sessionId` alone.** The conversation UUID is the
stronger identity, but it is not available at spawn — Claude mints it after
boot — so a session's `sessionId` may be unresolvable at the moment mail is
sent to it, and codex resolves through a different mechanism entirely
(`_session_codex_rollout_path`). `created_at` is always present for a derived
peer. Record both, prefer `sessionId` when both sides have it, fall back to
`created_at`, and fall back again to 032's inequality. Three tiers, degrading
safely.

**Do not gate delivery on the stamp's presence.** A missing stamp must mean
"fall back", never "block" — otherwise this plan silently strands every message
queued before it landed, which is the failure it exists to prevent.

**Relationship to 029.** This is not a substitute for UUID-keyed identity. It
makes *detection* exact; 029 makes the *address* durable so a replaced peer can
be succeeded rather than merely refused. If 029 lands first, this plan reduces
to reusing 029's stable id as the stamp — smaller, not obsolete.
