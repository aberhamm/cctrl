---
id: 032
title: Refuse to deliver mail addressed to a previous occupant of a reused session name
status: pending
blocked-by: []
priority: 32
goal: cctrl-peer-identity-integrity
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-20
---

## Requirements

This is the **safety plan** of the set. It does not fix identity — it makes the
dangerous failure mode loud instead of silent, and it is deliberately scoped so
it can ship immediately, with no message-format change and no contention with
the in-flight plans 023–030.

**The defect.** A tmux session name doubles as a mailbox address
(`_peer_derived_json`, `cctrl:1948`: `name: (.peer // .name)`), and
`_pick_safe_session_index` (`cctrl:1258`) deliberately recycles freed indices —
its own comment says *"A stale metadata record for a DEAD session does not
reserve the index, so freed indices are reused (no `--N` sprawl)."* That choice
predates the name being an address.

`-r/--resume` never reaches the naming logic (`cctrl:510`,
`LAUNCH_FLAGS+=("--resume" …)`), so a resumed session takes whatever slot is
lowest-free and **frees its old one**. Observed twice in one hour: `--5` resumed
as the unsuffixed name, and a brand-new unrelated session claimed `--5`.

**Why it is dangerous rather than merely wrong.** Delivery is late-bound and
name-keyed at every hop, and the failure is asymmetric:

- `_peer_tmux_target_for_delivery` (`cctrl:3068-3095`) fails **only** when the
  name has no live session. If the name was *recycled*, `has-session` succeeds
  and delivery proceeds normally.
- `_peer_cmd_recv` selects mail with `select(.to == $who …)` on a bare name
  string, with no occupant check. **This is the actual content-handover path** —
  the nudge is only a count; `recv` is where the body is read out.

So an addressee that is **gone** fails loudly, while an addressee that has been
**replaced** is silently misdelivered. Peer traffic carries hard-holds,
approvals and retractions; delivering one to a session that cannot know it was
not the intended recipient is a safety issue.

**Acceptance criteria:**

- [ ] Mail addressed to a name whose current occupant demonstrably post-dates
      the message is **not delivered** — not by nudge, and not by `recv`.
- [ ] `_peer_cmd_recv` applies the guard. A guard on the nudge path alone is
      insufficient and must not be accepted as done.
- [ ] Blocked mail is marked with an explicit, greppable reason
      (`addressee-replaced`) and surfaced to the **sender** via `outbox`, so the
      sender learns the instruction never landed.
- [ ] The receiving session sees nothing, or sees an explicit notice that mail
      for a prior occupant was withheld. It must never see the body.
- [ ] Messages already queued in `data/messages.jsonl` right now are covered
      retroactively, with no rewrite of stored records and no migration.
- [ ] Manual peers (`cctrl peer register`, `cctrl:2057`) that carry no
      `created_at` are **not** blocked — the guard fails open when it cannot
      prove replacement.
- [ ] Mail legitimately sent to a not-yet-spawned name via `--allow-unknown`
      (`cctrl:2641`) is **not** blocked. See the false-positive analysis below;
      this case inverts the comparison and is the main correctness risk.
- [ ] No change to the message JSON schema, and no edit to `_peer_cmd_send`'s
      `jq -cn` construction at `cctrl:2663-2686` — plan 023 is rewriting that
      block. Send-side stamping is plan **034**.
- [ ] `data/peers.json` and `data/messages.jsonl` are never edited in place;
      status changes go through the existing locked-rewrite path.

## Design

**The detector needs no new data.** `created_at` is already carried into every
derived peer record (`cctrl:1958`, sourced from session metadata) and is
confirmed present in live `cctrl peer ls --json` output. Because
`_session_write_metadata` has exactly one call site (`cctrl:1760`, detached
creation), a live session's `created_at` is stable for its whole life, and a
**recycled name gets a fresh one**. Therefore:

> If `message.created_at < peer.created_at`, the current occupant of that name
> was born after the message was sent, and is not the addressee.

This is sound for every message sitting in the queue today, which is why the
retroactive criterion above is achievable without touching stored records.

**Comparison is a string compare.** Both timestamps are ISO-8601 UTC with fixed
width (`_peer_now_utc` and the metadata writer both emit `%Y-%m-%dT%H:%M:%SZ`),
so lexical ordering equals chronological ordering. Do not parse to epoch;
`_session_created_at_ms` (`cctrl:5745`) exists but drags in `date -u -j -f`,
which is macOS-specific and already a portability seam elsewhere in the file.

**Fail open, deliberately.** Block only on a *proven* inequality. Missing
`peer.created_at`, missing `message.created_at`, or equal values all deliver as
today. Equality means the session was created in the same second the message
was sent — that is a session receiving its own seed mail, not a recycle.

**The false-positive that matters: `--allow-unknown`.** A message may be queued
for a name *before* that session exists (`cctrl:2641` permits sending to an
unresolved recipient). When the session then spawns, its `created_at` is
correctly **later** than the message — the exact signature of a recycle. A naive
guard would block legitimate pre-seeded mail.

Resolve it by distinguishing *never resolved* from *resolved then replaced*.
At minimum: exempt messages whose history shows they were accepted while
unresolved. `_peer_cmd_send`'s `unknown_peer` flag (`cctrl:2628-2650`) already
computes this; if it is not currently recorded, record it in the message
`history` array — an **append**, which does not touch the 023 construction block
— rather than adding a top-level field. Plan 034's send-time stamp removes the
ambiguity entirely; this plan must be correct without it.

**Where to enforce.** Two call sites, one shared predicate:

1. `_peer_cmd_recv` — extend the `select(.to == $who …)` filter. This is the
   content gate and the one that actually prevents disclosure.
2. `_peer_deliver_one_locked` / `_peer_tmux_target_for_delivery`
   (`cctrl:3068`, `cctrl:3295-3330`) — so a recycled name does not even get
   nudged, and the queued count reported to the sender excludes blocked mail.

Implement the predicate once (e.g. `_peer_message_addressee_current`) and call
it from both, so the two paths cannot drift — the nudge and the read-out
disagreeing is how a partial fix would present.

**Do not auto-reroute.** When the guard fires, the correct action is to withhold
and report, never to guess a successor. Misrouting is worse than failing: a
delivered-to-the-wrong-session instruction gives work to someone with no
context while the real recipient never learns. Plan 029 states this principle
for replies; it applies identically to forward delivery, and 029 does not
currently cover the replaced-occupant case.

**Relationship to the rest of the set.** 033 removes the collision source, 034
makes the detection exact, and 029 makes the address durable. This plan is the
net that stays useful even after all three land, because it is the only one that
fails closed on an identity it cannot verify.
