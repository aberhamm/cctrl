---
id: 028
title: Design the stable-peer-identity migration and produce a written proposal
status: blocked
blocked-by: [023]
priority: 28
goal: cctrl-peer-messaging-discoverable-models
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-19
---

## Requirements

This plan produces a **written migration proposal and nothing else**. It writes
no `cctrl` code, touches no registry, and modifies no data. Implementation is
plan 029, which is blocked on this one.

The split exists because the safety gate has to be real. An earlier draft folded
the proposal and the implementation into a single plan whose first task said
"write the proposal and stop." `mstack-run` has no mechanism to pause mid-plan
and wait for a human — the `/goal` driver is explicitly built to keep going
until done or failed — so that gate rested entirely on an autonomous worker
choosing to honour a prose instruction. Splitting into two plans makes the stop
structural: 029 cannot start until 028 is `done` and a human clears its review.

**The problem being designed for.** `_peer_derived_json` (`cctrl:1948`) sets
`name: (.peer // .name)`, so for a session started **without** `--peer` the
mailbox address is literally the tmux session name. Close or rename it and every
stored address referencing it becomes unresolvable; `_peer_cmd_send` fails with
`Unknown recipient` (`cctrl:2628-2631`). That is the reported incident. Scoping
caveat: a session started **with** `--peer NAME` already carries an alias-based
name and is less exposed, though its `tmux_target` still tracks the raw session
name. The proposal must cover both cases rather than overstating a blanket claim
about all derived peers.

**Acceptance criteria:**

- [ ] A written proposal exists at `docs/proposals/stable-peer-identity.md`.
- [ ] It specifies how the ~15 **already-running** sessions acquire a stable id **without restart**, naming the concrete write path. This is the crux: `_session_write_metadata` has exactly **one** call site (`cctrl:1760`, the detached-creation path) and is never re-invoked on foreground start, attach, or resume, so no existing code path can backfill an id. The proposal must name a new one (lazy generate-and-persist on first read, a `session doctor --fix`-style backfill, or an explicit claim command) and state its failure modes.
- [ ] It states what happens to in-flight `queued` messages during the transition.
- [ ] It states whether any backfill of `data/` is required, and argues for **none** if at all possible.
- [ ] It specifies the successor-claiming mechanism explicitly and confirms there is no heuristic fallback: an unclaimed predecessor id must fail cleanly rather than misroute a reply to an unrelated session.
- [ ] It specifies the rollback path, including what becomes unrecoverable.
- [ ] It covers both the unaliased-derived-peer case and the `--peer NAME` case.
- [ ] It states the blast radius: which functions change, and which of the ~16 live sessions are affected during the transition.
- [ ] The proposal is presented to the operator for explicit approval; plan 029 stays blocked until that approval is given.
- [ ] No file under `cctrl`, `lib/`, `hooks/`, or `data/` is modified by this plan.

## Design

The deliverable is a document, not code. Structure it so plan 029 can be
executed directly from it:

```
docs/proposals/stable-peer-identity.md
  1. Identity model        what the id is, where it lives, how it is generated
  2. Adoption path         how running sessions get one WITHOUT restart  <-- the crux
  3. Resolution            id / name / alias union in _peer_resolve_json
  4. Successor claiming    explicit claim only, no heuristics, fail-closed
  5. In-flight messages    what happens to queued mail mid-transition
  6. Backfill              argue for none; if unavoidable, exact scope + reversal
  7. Rollback              how to undo, and what becomes unrecoverable
  8. Blast radius          functions touched, sessions affected
```

**Investigate before writing, but read-only.** Confirm the adoption path against
real source rather than assuming: enumerate every caller of
`_session_write_metadata`, check whether a `_session_metadata_field` read could
safely carry a write side-effect, and confirm the metadata directory persists
after a session ends (it appears to, which is what would let a reply distinguish
"replaced" from "gone" — verify rather than trust).

**Files expected to change:**

- `docs/proposals/stable-peer-identity.md` (new; the only file this plan writes)

**Testing approach: unit-only** — the deliverable is a document; verification is
structural (required sections present, no source file touched).

**Out of scope:** all implementation — resolution changes, metadata writes,
successor claiming, `peer ls` output. Those belong to plan 029. Do not write
code "to validate the proposal"; a read-only investigation is sufficient, and a
scratch experiment risks touching live state.

## Tasks

1. Read-only investigation: enumerate `_session_write_metadata` callers, confirm metadata persistence after session end, and confirm the `--peer` versus unaliased derived-peer distinction.
2. Draft sections 1-4 (identity model, adoption path, resolution, successor claiming).
3. Draft sections 5-8 (in-flight messages, backfill, rollback, blast radius).
4. State explicitly whether any `data/` backfill is required; if yes, justify it against the standing constraint that the live store is never edited in place.
5. Present the proposal to the operator and record the outcome in the document.

## Verification

Checks:

- `[cmd] test -f docs/proposals/stable-peer-identity.md`
- `[assert] bash -c "grep -c '^## ' docs/proposals/stable-peer-identity.md"` contains `8`
- `[assert] bash -c "grep -qi 'without restart' docs/proposals/stable-peer-identity.md && echo yes"` contains `yes`
- `[assert] bash -c "grep -qi 'rollback' docs/proposals/stable-peer-identity.md && echo yes"` contains `yes`
- `[cmd] git diff --quiet -- cctrl lib hooks` — this plan must not modify any source file
- `[manual] Operator has read the proposal and explicitly approved or rejected it before plan 029 is unblocked.`
