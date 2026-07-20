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
      via `_peer_resolve_json` (`cctrl:2628-2650`) and currently reduces it to
      `.name` (`cctrl:2630`) — stop discarding the rest.
- [ ] The stamp carries the recipient's `created_at`. It carries `sessionId`
      **only** where actually resolvable — and note the gap: `to_peer_json` comes
      from `_peer_derived_json`, which does **not** emit `session_id`
      (`cctrl:1948-1958`); only `_session_list --json` carries it
      (`cctrl:4853-4885`). So stamping `sessionId` requires either resolving it
      separately at send (`_session_id`, defined at `cctrl:4525`) or teaching
      `_peer_derived_json` to carry it. Pick one and state it; do not assume the
      field is already on the peer object.
- [ ] 032's guard prefers the stamp when present: replacement is then an exact
      mismatch, not a timestamp inequality. Because 032 ships with the ambiguous
      `unknown_peer` exemption, this plan must **replace** that logic where a
      stamp exists, not merely layer on top of it — a stamped message is judged
      by the stamp alone.
- [ ] The `--allow-unknown` exemption becomes precise — an unresolved *recipient*
      records no recipient stamp (positive evidence no occupant was verified),
      which disambiguates the recipient-vs-sender conflation that 032's
      top-level `unknown_peer` flag (`cctrl:2686`) cannot distinguish.
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
sent. On the codex side there is **no equivalent stable id at all**:
`_session_codex_rollout_path` (`cctrl:5750-5765`) returns a rollout *file path*
correlated by cwd, not a durable session identity, so do not treat it as a
codex `sessionId` — for codex peers the stamp is `created_at`-only until 029
provides a real stable id. `created_at` is always present for a derived peer.
Record `sessionId` when resolvable, else `created_at`, and fall back again to
032's inequality. Tiers degrade safely; do not claim a codex UUID that does not
exist.

**Do not gate delivery on the stamp's presence.** A missing stamp must mean
"fall back", never "block" — otherwise this plan silently strands every message
queued before it landed, which is the failure it exists to prevent.

**Relationship to 029.** This is not a substitute for UUID-keyed identity. It
makes *detection* exact; 029 makes the *address* durable so a replaced peer can
be succeeded rather than merely refused. If 029 lands first, this plan reduces
to reusing 029's stable id as the stamp — smaller, not obsolete.
