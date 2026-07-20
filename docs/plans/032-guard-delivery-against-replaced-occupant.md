---
id: 032
title: Refuse to deliver mail addressed to a previous occupant of a reused session name
status: done
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
      the message is **not delivered** — not by nudge, not by `recv`, and not by
      the other read paths that expose the body (see the disclosure-surface note
      below; `inbox --json` at `cctrl:2724` and `peer show <id>` at `cctrl:2767`
      also render full message objects).
- [ ] `_peer_cmd_recv` applies the guard. A guard on the nudge path alone is
      insufficient and must not be accepted as done. **Plumbing gap:**
      `_mailbox_resolve_identity_for_mode` (`cctrl:2532-2541`) discards the
      resolved peer JSON and keeps only `.name`, so `recv` has no
      `peer.created_at` today — the implementer must resolve the current
      occupant's `created_at` (via `_peer_resolve_json` or
      `_session_metadata_field`) inside the guard.
- [ ] Blocking mail must actually change what a reader selects. `recv` selects
      on status `queued`/`delivered` (`cctrl:2947-2966`); a guard that leaves
      status untouched still lets the body through. Either the selection filter
      excludes guarded messages, or their status is moved to a terminal
      `blocked` value — decide and state which.
- [ ] Blocked mail is marked with an explicit, greppable reason
      (`addressee-replaced`) and surfaced to the **sender** via `outbox`, so the
      sender learns the instruction never landed.
- [ ] The receiving session sees nothing, or sees an explicit notice that mail
      for a prior occupant was withheld. It must never see the body.
- [ ] Messages already queued in `data/messages.jsonl` right now are covered
      retroactively, with no rewrite of stored records and no migration.
- [ ] The guard is **fail-closed on ambiguity, fail-open only on absence**
      (the ambiguity policy; see the design section). Concretely: when the peer
      carries a `created_at` but the comparison cannot be made cleanly (equal
      timestamps, or an unparseable/non-fixed-format message timestamp), the
      message is **blocked** as `addressee-ambiguous`, not delivered. When the
      peer carries **no** `created_at` at all (a manual peer — name was always
      its only identity), the message **delivers**, because blocking gains
      nothing there and would break legitimate manual-peer traffic.
- [ ] Manual peers (`cctrl peer register`, `cctrl:2057`) that carry no
      `created_at` are **not** blocked — this is the absence case above, the one
      place the guard fails open.
- [ ] Mail sent to a not-yet-spawned name via `--allow-unknown` (`cctrl:2649`)
      is **not** blocked. The message already carries a top-level
      `unknown_peer: true` (`cctrl:2686`) — but that flag is **ambiguous**: it
      is set when the *recipient* was unresolved OR a non-user *sender* was
      unresolved (`cctrl:2648-2649`). Exempting on it alone fails open in the
      right direction (never a false block) but under-blocks a genuinely
      recycled name whose original send happened to have an unresolved sender.
      That residual is accepted here and closed exactly by plan 034's per-message
      recipient stamp. See the false-positive analysis below.
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
retroactive criterion above is achievable without touching stored records — with
the granularity and override caveats below.

**Comparison is a string compare, but only under the default format.** Both
timestamps are ISO-8601 UTC, fixed width (`_peer_now_utc` at `cctrl:1841` and
the metadata writer at `cctrl:1193` both emit `%Y-%m-%dT%H:%M:%SZ`), so lexical
ordering equals chronological ordering. Do not parse to epoch;
`_session_created_at_ms` (`cctrl:5744`) exists but drags in `date -u -j -f`,
which is macOS-specific and already a portability seam. **Caveat:**
`_peer_now_utc` honours a `CCTRL_NOW_UTC` override (`cctrl:1836-1841`) that the
metadata writer does not; a message stamped through a non-fixed or non-UTC
override breaks the lexical assumption. A message timestamp that does not match
the fixed `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$` shape is **uncomparable** —
and per the ambiguity policy below, uncomparable-against-a-peer-that-has-a-stamp
means **block**, not deliver.

**Ambiguity policy: fail closed on ambiguity, fail open only on absence.** This
is the load-bearing decision of the plan (operator-settled 2026-07-21, after a
Codex strategic review argued the guard's worst outcome is a false negative that
delivers to the wrong occupant anyway). An earlier draft failed *open* on every
uncertain case; that merely narrows the leak instead of closing it. The settled
rule, applied to a resolved recipient:

| Case | Action | Why |
|---|---|---|
| `unknown_peer: true` on the message | **deliver** | pre-seed / `--allow-unknown`; never had a verified occupant (see below) |
| peer has **no** `created_at` (manual peer) | **deliver** | name was always the only identity; blocking gains nothing, breaks legit traffic |
| message has **no** `created_at` (legacy record) | **deliver** | nothing to compare; matches today's behavior for fieldless old records |
| proven `message.created_at > peer.created_at` | **deliver** | normal case: the occupant predates the message, so it is the addressee |
| proven `message.created_at < peer.created_at` | **block** `addressee-replaced` | occupant born after the message was sent — provably not the addressee |
| peer **has** `created_at`, but timestamps **equal** | **block** `addressee-ambiguous` | seconds-granularity tie could be a same-second recycle; cannot prove same-identity |
| peer **has** `created_at`, but message stamp **unparseable** | **block** `addressee-ambiguous` | e.g. a `CCTRL_NOW_UTC` override; cannot prove same-identity |

The distinction is **absence vs ambiguity**. Absence (no stamp on either side)
means name was never anything but the address, so the guard has no better
signal than today and delivers. Ambiguity (a peer that *does* carry a stamp, but
the comparison ties or won't parse) means the name has demonstrably churned and
we simply cannot prove the current occupant is the addressee — there, misroute
is worse than a bounced message, so block and notify the sender. This costs a
false block on the vanishingly rare legitimate same-second send, but that fails
*loud* (the sender is told `addressee-ambiguous`) and is recoverable, whereas a
false deliver is silent and is exactly the defect. Plan 034's exact stamp
removes the tie entirely; until then the fleet is protected, not merely warned.

**The false-positive that matters: `--allow-unknown`.** A message may be queued
for a name *before* that session exists (`cctrl:2641` permits sending to an
unresolved recipient). When the session then spawns, its `created_at` is
correctly **later** than the message — the exact signature of a recycle. A naive
guard would block legitimate pre-seeded mail.

Resolve it by distinguishing *never resolved* from *resolved then replaced*.
The message **already carries** `unknown_peer: true` at the top level when sent
via `--allow-unknown` (`cctrl:2686`) — an earlier draft wrongly claimed this was
an unrecorded local and proposed writing it into `history`; that was both
unnecessary and self-contradictory, since `history` is built inside the same
`jq -cn` block (`cctrl:2663-2686`) the plan forbids editing. **Read** the
existing `unknown_peer` field; do not write anything new. Exempt any message
with `unknown_peer: true` from the guard.

The known imprecision (the flag also fires for an unresolved *sender*) is
accepted per the acceptance criteria above: it can only cause under-blocking
(fail-open), never a false block, and plan 034's recipient-specific stamp
removes it. This plan must be correct — never misroute — without 034; it simply
tolerates the occasional missed block until 034 lands.

**Where to enforce.** One shared predicate, applied at every surface that can
disclose a body — Codex's review flagged that `recv` is not the only one:

1. `_peer_cmd_recv` (`cctrl:2947-2966`) — the primary read-out. Also the
   plumbing gap: it must gain access to `peer.created_at`, which
   `_mailbox_resolve_identity_for_mode` (`cctrl:2532-2541`) currently discards.
2. `_peer_cmd_inbox` (`cctrl:2724-2728`) and `_peer_cmd_show` (`cctrl:2767-2791`)
   — both render full message objects including the body. A guard that covers
   only `recv` still leaks here. Either filter guarded messages out of these, or
   redact their body, and state which.
3. `_peer_deliver_one_locked` / delivery nudge (`cctrl:3068`, `cctrl:3295-3330`)
   — so a recycled name is not nudged and the sender's queued count excludes
   blocked mail. Note `_peer_record_nudge_json` (`cctrl:3173-3188`) only records
   nudge metadata and leaves status `queued`; blocking at the nudge does **not**
   stop `recv` on its own, which is why the status/selection change in the
   acceptance criteria is load-bearing.

Implement the predicate once (e.g. `_peer_message_addressee_current`) and call
it from every surface above, so they cannot drift — one surface disagreeing is
how a partial fix leaks.

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

## Implementation Notes (done 2026-07-21)

- Canonical predicate `_peer_guard_defs` emits jq `def`s (`fixed_ts`,
  `deliverable($p)`, `block_reason($p)`) as a single string, concatenated
  single-quoted ahead of each program (`jq ... "$guard"'<prog>'`) so bash never
  re-expands the `$p` and all sites share ONE copy. Unit-verified against all
  seven policy rows (normal/replaced/equal/absence×2/unknown_peer/unparseable).
- `_mailbox_resolve_identity_for_mode` now also stashes
  `MAILBOX_RESOLVED_PEER_CREATED` (the occupant's `created_at`, "" for a manual
  peer with none) so read paths guard without re-resolving.
- Enforcement surfaces: `_peer_cmd_recv` selection (primary body handover),
  `_peer_cmd_inbox` listing (so a withheld message's id never leaks to a
  receiver), and `_peer_deliver_one_locked` — which terminally transitions a
  stale-addressed queued message to `status:"blocked"` + `blocked_reason` +
  history, under the caller's existing lock, dropping it from the queued count so
  no nudge fires. The inline branch refuses a just-blocked message too.
- `peer show <id>` is deliberately NOT guarded: it is unscoped (operator/sender
  tool), and a receiver only learns a message id through recv/inbox, both now
  guarded — so the id never reaches a receiver to `show`.
- Ambiguity policy is fail-closed (block) on equal/unparseable-stamp when the
  occupant carries a `created_at`, fail-open (deliver) on absence — the
  operator-settled decision recorded in the Design section.
- Manual peers (no `created_at`) and pre-existing queued mail are unaffected:
  the 28 prior peer tests pass unchanged. New test
  `test_peer_deliver_addressee_guard_replaced_occupant` proves block + non-
  interference + no body leak end-to-end.
