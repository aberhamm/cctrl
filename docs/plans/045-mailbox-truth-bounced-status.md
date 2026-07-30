---
id: 045
title: Mailbox truth — guard-aware check and an explicit bounced status
status: blocked
blocked-by: []
priority: 17
goal: revised-cctrl-audit-backlog
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-30
reviews:
  - type=eng verdict=changes-requested date=2026-07-30 by=mstack-review
---

## Requirements

Two honesty defects make the mailbox lie to its users. (1) **Phantom mail:**
`peer check` counts every `status=="queued"` row for a name, while `recv` and
`inbox` filter through the plan-032 addressee guard (`deliverable($peer)`) —
so a session is told "N new messages", runs `recv`, and gets `{empty:true}`,
looping until some deliver pass terminally marks the rows `blocked`.
`peer overview` has the same defect: it reuses `peer check`'s mailbox shape
but counts raw `.status=="queued"` rows, and the MCP `peer_overview` tool
passes that phantom count straight through. The doorbell hook (plan 044)
would inherit this false signal. (2) **Invisible orphans:** queued mail
addressed to sessions that no longer exist is skipped as `unknown-peer` —
in **both** skip sites: the `--all` loop in the deliver command and
`_peer_orchestrate_recipients_locked` — and appears in **no per-peer row**;
verified live: `peer status` header said 6 queued / 15 delivered-unacked while
the rows summed to 2 / 5; the remainder was orphaned mail nobody can see.
Targeted (non-`--all`) deliver is worse still: it returns `unknown-peer`
without producing a delivery result or rewriting rows at all. Senders never
learn their message went nowhere.

**Acceptance criteria:**

- [ ] `peer check` **and** `peer overview` count through the same `deliverable($peer)` filter as `recv`/`inbox`; a guard-blocked row is never counted as "new". The MCP passthroughs (`check_messages`, `peer_overview`) inherit the fix (shared jq), and the doorbell (which shells out to `check`) therefore stops false-ringing.
- [ ] New terminal status `bounced` — defined as **addressee unresolvable at deliver time** (the store cannot prove the addressee ever existed; only `--allow-unknown` sends record `unknown_peer:true`): when a deliver pass finds a queued message whose addressee no longer resolves to any live or manual peer, the row transitions `queued → bounced` with a history event carrying the reason (`unknown-peer`) and timestamp. All three `unknown-peer` sites bounce: the `--all` loop in the deliver command, `_peer_orchestrate_recipients_locked`, and targeted (non-`--all`) deliver — which today returns `unknown-peer` without producing a delivery result or rewriting rows and needs its own bounce handling — otherwise check/status disagree depending on entrypoint. Distinct from `blocked` (addressee replaced — plan 032), which keeps its meaning.
- [ ] Re-registration semantics: a bounced row STAYS bounced even if the name is later re-held by a new peer — no un-bounce; `gc` archives it like any other terminal row.
- [ ] Nothing is auto-deleted (reviewer finding: no silent expiry). No new gc flag needed: `peer gc` already accepts arbitrary `--status` values, so `peer gc --status bounced --older-than …` archives bounced rows explicitly; document that path (optionally validate the status enum); default gc behavior unchanged.
- [ ] Sender visibility: `peer outbox` shows `bounced` with the reason; `peer status` gains an `orphaned/bounced` line so the header totals exactly equal the sum of visible rows (assert this identity in a test).
- [ ] Automation contract: `peer status --json` carries a top-level bounced/orphaned count as a documented field, so the doorbell/fleet-manager can alarm on bounces without parsing rows.
- [ ] Status-model agreement: `check`, `recv`, `inbox`, `outbox`, `status`, `gc`, the MCP bridge surfaces that actually exist (`send_message`, `check_messages`, `recv_message`, `show_message`, `ack_message`, `peer_overview` — the bridge has no outbox/status/gc tools), and the doorbell all agree on the full lifecycle `queued → delivered → acked | blocked | bounced`; the lifecycle is documented in one place in the script's peer section header comment.
- [ ] `peer send` to a currently-unknown peer without `--allow-unknown` still refuses upfront (unchanged); `bounced` only applies to mail that was validly queued and whose addressee later vanished.
- [ ] Full suite passes; the ~375 existing peer assertions are untouched except where they enumerate statuses.

## Design

`bounced` is assigned only under the mailbox lock during a deliver pass —
the same place `unknown-peer` skips happen today — so no new scan job is
needed. **TOCTOU guard:** the peers doc is not under the mailbox lock, so the
addressee MUST be re-resolved inside the mailbox lock immediately before the
`queued → bounced` write — a peer registering between resolution and write
must not get its mail bounced. `peer status` computes orphans as: rows whose
`to` matches no current peer row, grouped under one labeled section.

Coordinate with pending plan 024 (inline envelope): 024 touches inline
delivery status transitions; this plan touches queued-side transitions. No
shared code expected, but land whichever goes second with a rebase check on
the status enumeration. Do not block either on the other.

Coordinate with pending plan 034 (stamp recipient identity at send): 034
modifies the same plan-032 deliverability guard (`_peer_guard_defs`) this
plan routes `check`/`overview` through. No ordering constraint, but land
whichever goes second with a rebase check on the guard. Do not block either
on the other.

**Files expected to change:**

- `cctrl`: `_peer_cmd_check` + `_peer_cmd_overview` (route through the existing `_peer_guard_defs` `deliverable($p)` filter), all three `unknown-peer` sites (deliver `--all` loop, `_peer_orchestrate_recipients_locked`, targeted deliver) → bounce transition, `peer status` orphan section + `--json` bounced/orphaned field, `peer outbox` rendering, `peer gc` docs (`--status bounced` path, optional enum validation), peer section header comment
- `lib/peer_mcp.py`: only if `check_messages`/`peer_overview` duplicate the jq rather than shelling through `cctrl peer check`/`peer overview` (verify; keep one implementation)
- `tests/run-tests.sh`: phantom-mail regression (check==overview==recv-visible), bounce lifecycle across all three deliver entrypoints, no-un-bounce-on-re-register, totals-equal-rows identity, `status --json` bounced field, `gc --status bounced`

**Testing approach: E2E** — isolated `CCTRL_DATA_DIR`; never the live
`data/messages.jsonl`.

**Out of scope:** expiry/TTL policies, sender-side notification pushes,
stable identity (plans 028/029 — bounces from name recycling shrink when
those land, but this plan is correct with or without them).

## Tasks

1. Route `_peer_cmd_check` and `_peer_cmd_overview` through the existing `_peer_guard_defs` `deliverable($p)` filter (plan 032) — `recv`/`inbox`/delivery already use it; do NOT re-extract (regression test: check/overview/recv-visible counts agree).
2. Add the `bounced` transition at all three `unknown-peer` sites (deliver `--all` loop, `_peer_orchestrate_recipients_locked`, targeted deliver — the last needs its own bounce handling since it currently rewrites nothing), each under the mailbox lock with a re-resolve of the addressee immediately before the write (TOCTOU), with history event + reason. Test that a bounced row stays bounced after the name is re-registered.
3. Add the `peer status` orphaned/bounced section and the documented top-level bounced/orphaned count in `peer status --json`; make header totals = sum of rows an invariant test.
4. Update `outbox` rendering; document the `peer gc --status bounced` archival path (gc already accepts arbitrary `--status` values — no new flag; optionally validate the status enum).
5. Confirm MCP `check_messages` and `peer_overview` flow through the shared implementation.
6. Document the lifecycle in the peer section header comment; run the full suite.

## Verification

Checks:

- `[cmd] bash tests/run-tests.sh`
- `[assert] ./cctrl peer help 2>&1` contains `bounced`
- `[cmd] bash -c 'h1=$(shasum data/messages.jsonl 2>/dev/null || echo absent); bash tests/run-tests.sh >/dev/null 2>&1; h2=$(shasum data/messages.jsonl 2>/dev/null || echo absent); [ "$h1" = "$h2" ]'`

<!-- mstack:seam
produced:
- kind: schema; name: bounced; file: cctrl
assumed:
-->
