---
id: 033
title: Stop handing a freed session index to the next spawn
status: pending
blocked-by: []
priority: 33
goal: cctrl-peer-identity-integrity
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-20
---

## Requirements

Plan 032 detects a reused address. This plan removes the reuse.

`_pick_safe_session_index` (`cctrl:1258-1283`) treats an index as taken **only**
when `tmux has-session` reports it live. Its comment states the intent
plainly — *"A stale metadata record for a DEAD session does not reserve the
index, so freed indices are reused (no `--N` sprawl)"* — an anti-sprawl choice
made before the session name became a mailbox address.

Reproduced deterministically: with `base`, `base--2`, `base--3` live, the next
pick is `base--4`; kill `base--2` and the next pick is immediately `base--2`.

**Acceptance criteria:**

- [ ] A session name that has been used and released is **not** reissued to a
      later spawn while its record is retained.
- [ ] The reproduction above inverts: after killing `base--2`, the next pick is
      `base--4`, not `base--2`.
- [ ] Retention is bounded and explicitly documented — names become reusable
      again only through a stated, operator-visible policy, never silently.
- [ ] `cctrl session prune` / the existing prune path is the sanctioned way to
      release retained names, and releasing a name is reported, not silent.
- [ ] The picker still refuses rather than colliding when no free slot exists,
      preserving today's `cctrl:1279-1282` behavior and its error message.
- [ ] A live session is never overwritten. This property is load-bearing and
      must not regress — it is the reason the picker exists.
- [ ] Behavior is verified against a real multi-session fleet, not only the
      throwaway-tmux reproduction.

## Design

**The retention set is already on disk.** `_session_close` (`cctrl:5610-5721`)
kills tmux and does nothing else — no metadata removal, no deregistration. So
`data/sessions/<name>.json` **persists after close**. The minimal change is for
the picker to treat *"a metadata file exists"* as taken, in addition to *"tmux
reports it live"*. No new state file, no counter to keep consistent, and the
retention set survives a cctrl restart for free.

**The cost, stated honestly.** Metadata files accumulate for the life of the
machine, so indices climb (`--47`) and never come back on their own. The sprawl
the original comment was avoiding is real; it is also *cosmetic*, whereas the
behavior it enables is a misrouting hazard. Accepting bounded ugliness to remove
a safety failure is the right trade, but it must come with a release valve or
the fleet degrades into unreadable names over months.

**Release valve.** Wire retention release into the existing prune path
(`_session_prune`, `cctrl:5852+`) rather than inventing a second lifecycle:
pruning a long-dead session is exactly the moment its name becomes safe to
reissue. Note the ordering dependency — `_session_prune` currently classifies
sessions using the same defective `*codex*`-first test that plan **031** fixes
(`cctrl:5864-5876`), so land 031 first or the release valve inherits the
misclassification and prunes against the wrong log source.

**Do not tie release to a short timer.** A name is safe to reissue only when no
queued mail still references it. A time-based rule that expires a name while
`data/messages.jsonl` still holds messages addressed to it walks straight back
into the 032 hazard. Either check the mailbox before releasing, or make release
explicit and operator-driven. Prefer the mailbox check — an operator will not
reliably remember.

**Interaction with 032.** These are complementary, not redundant. 033 prevents
the collision for *new* spawns; 032 stays necessary because mail can be queued
against a name whose session dies at any moment, and because a fleet running a
mixed-version cctrl (or a name released through the valve) can still present a
replaced occupant. Do not let 033 landing become an argument for dropping 032's
fail-closed guard.

**Out of scope.** Making `--resume` reclaim its original name. That requires
persisting the conversation UUID→name mapping, which is plan 029's territory;
once identity is UUID-keyed, reclaiming is nearly free and this plan's retention
set becomes the lookup table for it.
