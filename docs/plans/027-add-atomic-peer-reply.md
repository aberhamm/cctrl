---
id: 027
title: Add an atomic peer reply that sends and delivers
status: pending
blocked-by: [023]
priority: 27
goal: cctrl-peer-messaging-discoverable-models
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-19
reviews:
  - type=eng verdict=approved date=2026-07-19 by=mstack-review
---

## Requirements

`cctrl peer send` only **queues**. `_peer_cmd_send` ends at `cctrl:2694-2698`
printing `Queued message: <id>` and stops; delivery is a separate
`cctrl peer deliver` step, and no `peer watch` daemon runs by default (verified:
no watch process, no launchd peer job on this fleet). So every caller who sends
without delivering produces a message that silently never arrives — the sender
sees a success line and reasonably concludes it worked.

This is not hypothetical. The fleet manager hit it in live use: *"I know this
system and still nearly stopped after send."* Plan 024 patches around it by
printing both commands in the envelope, but every other caller — the MCP
`send_message` tool, humans, scripts — still has the trap.

There is a second, larger win available here. Replying currently requires the
receiver to know and correctly type the sender's address. If a reply can be
addressed by **message id** instead, the receiver never has to resolve an
address at all, which is the single biggest reduction in reply friction
available in this surface.

**Acceptance criteria:**

- [ ] `cctrl peer reply <message-id> [--as NAME] [--subject TEXT] [--body-file PATH|-] [--json] -- <body>` sends a reply addressed to the original message's sender and delivers it, in one command.
- [ ] The recipient is resolved from the referenced message's `sender.name` (plan 023), falling back to its bare `from` for messages that predate the snapshot.
- [ ] `peer reply` refuses with a clear error when the referenced message is not addressed to the replying identity, matching the authorization rule `_peer_cmd_ack` already enforces.
- [ ] `peer reply` refuses with an actionable error when the original sender is `user` (the human operator), since `user` is not an addressable peer (`cctrl:2619`, `cctrl:2628-2631`).
- [ ] `peer reply` refuses with an actionable error when the original sender no longer resolves, naming the peer and stating the message cannot be replied to.
- [ ] `cctrl peer send --deliver` performs the same send-then-deliver sequence for the case where the caller knows the address but has no message to reply to.
- [ ] `peer reply` **acks the original message** after a successful send. `--no-ack` opts out for the reply-but-still-working case. An ack failure must not fail the reply: the reply already went out, so report the ack failure distinctly and keep exit status driven by the send/deliver outcome.
- [ ] Outcomes are **five**: `send-failed`, `sent-but-undelivered`, `sent-but-deferred`, `sent-and-nudged`, `sent-and-queued`. The success state is named `nudged` rather than `delivered` because `deliver` pastes only the nudge line and leaves the body `queued` (`cctrl:3396`, `tests/run-tests.sh:2348`).
- [ ] `sent-but-deferred` (recipient pane busy or showing a modal — `cctrl:3336` returns exit 0 today) exits **non-zero** with a retry hint. Nothing was pasted and nothing retries on its own.
- [ ] `sent-and-queued` exits **zero**. `_peer_deliver_one_locked` returns 0 with status `skipped` for a `no-tmux-capability` peer (`cctrl:3331`); reporting that as failure would make every reply to a polling or MCP-only peer exit non-zero.
- [ ] Every non-zero outcome except `send-failed` returns the message id and its error text says to retry **delivery only**, never the reply — re-running the reply duplicates the message.
- [ ] `peer reply` refuses when the referenced message is still `queued` — you cannot answer mail you never received. `_peer_cmd_ack` already rejects queued messages (`cctrl:2840`); reply must fail the same way with a hint to run `recv` first, rather than sending and then silently failing to ack.
- [ ] `--allow-unknown` combined with `--deliver` is **rejected** with an actionable error. An unresolvable recipient cannot be delivered to, so the combination would durably queue a message to nowhere while reporting a delivery attempt.
- [ ] The MCP `send_message` contract exposes the **same five states** as the CLI, not a reduced set, so MCP and CLI callers reason about one model.
- [ ] `send_message`'s tool description is updated **in this plan** to say it sends and attempts delivery. It currently reads "Queue a message from this server's identity to another peer" (`lib/peer_mcp.py:31`), which becomes wrong the moment this plan lands. Do not defer it to plan 025.
- [ ] The command's user-facing output and docs note the known limitation: reply-by-message-id still fails once the sender's session is gone, because addresses remain tmux-session-derived until plans 028/029 land.
- [ ] The whole command performs **one** identity/peer resolution. Read, send, deliver, and ack all operate on that single `_peer_all_json` result rather than re-resolving per step.
- [ ] Delivery failure after a successful send does **not** discard the message: the message stays queued, the command reports the delivery failure distinctly from a send failure, and exits non-zero.
- [ ] `--json` output distinguishes all five outcomes by name, and always carries the message id whenever one was queued.
- [ ] `peer send` with no `--deliver` flag behaves **exactly** as today, byte-identical output. Existing callers and the ~375 peer assertions are unaffected.
- [ ] The MCP `send_message` tool delivers after sending, so MCP agents stop producing silently-undelivered messages.
- [ ] MCP `send_message` reports every state where the message was durably queued as **success** (`ok: true`) with an explicit `outcome` field, not as an error. Only `send-failed` is `ok: false`. A peer with no live tmux session is a normal case — the message is legitimately queued and the send succeeded.
- [ ] `test_peer_mcp_bridge_stdio` (`tests/run-tests.sh:2261-2316`) still passes unmodified. Its fixture registers `comet` via `setup_mailbox_peers` (`tests/run-tests.sh:1992-1998`) **without `--session`**, so `comet` has no live tmux target and delivery will fail there by design; the assertion at line 2288 expects `ok == true`.

## Design

Two entry points, one shared helper. `peer reply` is the ergonomic path
(address inferred from a message id); `peer send --deliver` is the explicit path
(caller supplies the address). Both call one internal send-then-deliver routine
so the failure semantics live in exactly one place.

```
peer reply <id>  ──┐
                   ├──> _peer_send_and_deliver(to, body, as)
peer send --deliver┘         │
                             ├── _peer_cmd_send  (existing, unchanged)
                             └── _peer_cmd_deliver <to>   (nudge)
```

Deliver by **peer**, not `--inline`. `deliver <peer>` nudges the recipient to
run `recv`, which is the fleet's established async flow. Inline delivery would
paste the body directly but requires threading the new message id through, and
an inline-delivered reply would itself acquire an envelope from plan 024 —
avoidable recursion for no gain.

**Failure semantics are the whole design.** Send and deliver are two operations
and the second can fail independently (recipient pane busy, session gone, tmux
timeout). A reply that reports total failure after a successful send would
invite the caller to resend, duplicating the message. So: on delivery failure,
keep the queued message, report `sent-but-undelivered` with the message id, and
exit non-zero. The caller can retry delivery alone. Never roll back the send.

**Five outcomes. Name each for what actually happened:**

```
send-failed          nothing queued                        exit != 0
sent-but-undelivered queued, paste failed, retryable       exit != 0
sent-but-deferred    queued, pane busy/modal, not pasted   exit != 0
sent-and-nudged      queued, nudge pasted into a live pane exit 0
sent-and-queued      queued, peer is mailbox-only          exit 0
```

**`nudged`, not `delivered`.** `deliver <peer>` does not push the message body
into the recipient's terminal — it pastes the short nudge line and leaves the
message `queued` (`cctrl:3396`, asserted at `tests/run-tests.sh:2348`). The body
arrives only when the recipient runs `recv`. Calling this `delivered` would tell
every caller, and every MCP consumer, something stronger than what occurred.

**`deferred` is its own state.** `_peer_deliver_one_locked` returns status
`deferred` with **exit 0** when the recipient's pane has a modal or prompt open
(`cctrl:3336`). Nothing is pasted and nothing retries. Folding that into a
success would reintroduce the exact silent non-arrival this plan exists to
eliminate — so it exits non-zero and carries a retry hint. It is kept distinct
from `sent-but-undelivered` because the two want different retry timing: a busy
pane clears on its own, a failed paste usually does not.

**`sent-and-queued` is not a failure.** `_peer_deliver_one_locked` returns 0
with status `skipped` for a `no-tmux-capability` peer (`cctrl:3331`); polling
and MCP-only peers collect their own mail and were never going to receive a
paste. Reporting that as failure would make every reply to such a peer exit
non-zero.

**Retry safety.** Every non-zero outcome except `send-failed` has already
durably queued the message and returns its id. The contract is explicit: on a
non-zero exit **retry delivery only** (`cctrl peer deliver <peer>`), never
re-run the reply, or the message duplicates. State this in the error text
itself, not only in docs — a naive `reply || reply` is exactly what a script or
model will otherwise write.

**This plan OWNS the shared reachability classifier.** Plan 024 needs the same
live / mailbox-only / unreachable distinction for its envelope, and 024 is
blocked by this plan, so extraction belongs here — the reverse would be a
dependency cycle. Extract a **pure** classifier (no `PEER_DELIVER_*` writes; see
024's Design for why that matters) taking a peer JSON object and returning
`live` / `mailbox-only` / `unreachable`, have `_peer_tmux_target_for_delivery`
use it, and consume it here for outcome classification. 024 then consumes the
same function rather than writing a second answer to the same question.

**Ack the original.** Replying is the strongest evidence a message was handled,
so `peer reply` acks it by default. Without this, every answered message stays
in `delivered_unacked` forever — `peer check` keeps counting it and the stale
sweep keeps surfacing it, so the unacked pile stops meaning anything. `--no-ack`
covers replying while still working. Ack failure is reported but never fails the
reply, since the reply has already been sent and re-running the command would
duplicate it.

**One resolution for the whole command — via a cached resolver, not discipline.**
Reply performs four logical steps, and implementing each as a separate `cctrl`
invocation costs a full `_peer_all_json` → `_session_list` walk apiece —
measured at ~1.43s each, so ~5.6s for one reply on a 15-session fleet. This is
the hot path: the exact command plan 024's envelope tells every receiving model
to run.

An acceptance criterion alone will not achieve this. Every existing helper hides
its own walk behind `_peer_resolve_json` or an identity helper
(`_mailbox_resolve_identity_for_mode` at `cctrl:2511`, `_peer_cmd_send` at
`cctrl:2628`, `_peer_cmd_deliver` at `cctrl:3500`), so any implementation that
reuses them re-enumerates no matter what the plan says. Introduce an explicit
**cached resolver**: resolve `_peer_all_json` once into a variable and pass it
down, or memoize it behind a guard so repeated calls within one command reuse
the first result. Name that API in the implementation and have the internal
steps take the resolved document as a parameter rather than re-resolving.

**Do not change `peer send`'s default behavior.** The `--deliver` flag is opt-in.
`peer send` alone must remain byte-identical, because ~375 existing assertions
and an unknown number of fleet scripts depend on its current output.

**The MCP layer must not turn a delivery failure into a send failure.**
`Bridge.cli` (`lib/peer_mcp.py:99-118`) raises `McpError` on **any** non-zero
`cctrl` exit, and this plan's CLI contract exits non-zero on
`sent-but-undelivered` and `sent-but-deferred`. Wiring `send_message` through
`--deliver` naively
would therefore convert a perfectly good queued message into `ok: false`.
Concretely, `test_peer_mcp_bridge_stdio` registers `comet` with no `--session`
(`tests/run-tests.sh:1992-1998`), so delivery to it fails by construction, and
the existing assertion at line 2288 expects `ok == true` — the naive wiring
breaks a passing test. Surface the **same five states** at the bridge — MCP and
CLI must not ship two contracts for one operation. Only `send-failed` maps to
`ok: false`; every other state queued the message durably and is `ok: true` with
an explicit `outcome` field naming which one. The
message id must be present in all `ok: true` cases so the caller can retry
delivery alone. Add `Bridge.cli` (or a delivery-aware variant of it) to the
files-to-change list.

**Files expected to change:**

- `cctrl`: new `_peer_cmd_reply`, new `_peer_send_and_deliver` helper, the extracted pure reachability classifier (consumed by plan 024), `_peer_tmux_target_for_delivery` refactored onto it, `--deliver` flag in `_peer_cmd_send`, dispatcher cases, `peer help` lines
- `lib/peer_mcp.py`: `send_message` delivers after sending, plus the `Bridge.cli` error-handling path so a delivery failure surfaces as `ok: true, delivered: false` rather than `McpError`
- `tests/run-tests.sh`: new reply/deliver coverage

**Testing approach: E2E** — exercised against a real `cctrl` binary and the
fake-tmux harness in an isolated `CCTRL_DATA_DIR`.

**Out of scope:** changing `peer send`'s default (no auto-deliver without the
flag), the inline envelope (plan 024), and any change to nudge or doorbell
strings.

## Tasks

0. Extract the **pure** reachability classifier (peer JSON → `live` / `mailbox-only` / `unreachable`, no `PEER_DELIVER_*` writes) and refactor `_peer_tmux_target_for_delivery` to use it. Plan 024 consumes this same function.
1. Extract `_peer_send_and_deliver`: send, capture the id, deliver to the recipient peer, and classify the outcome into the four states above using that classifier.
2. Add `_peer_cmd_reply`: resolve the referenced message, authorize the replying identity against `.to`, derive the recipient from `sender.name` with `from` fallback, then call the shared helper.
3. Add the `user`-sender and unresolvable-sender refusals with actionable messages.
4. Add `--deliver` to `_peer_cmd_send`, routing through the same helper; leave the default path untouched.
5. Wire dispatcher cases and `peer help` lines for both.
6. Update the MCP `send_message` handler to deliver after sending, surfacing all five outcomes in its JSON, and rewrite its tool description so it no longer claims to only "Queue a message" (`lib/peer_mcp.py:31`).
7. Add tests: happy-path reply; reply to a legacy message with no `sender`; unauthorized reply; `user`-sender refusal; dead-sender refusal; delivery-failure keeps the message queued and exits non-zero; `peer send` without `--deliver` is byte-identical to today.
7a. Add outcome tests, one per state: live tmux peer → `sent-and-nudged` (exit 0); mailbox-only peer → `sent-and-queued` (exit 0); busy/modal pane → `sent-but-deferred` (non-zero, retry hint); paste failure → `sent-but-undelivered` with the message still queued; send failure → `send-failed` with nothing queued.
7b. Add ack tests: reply acks the original by default; `--no-ack` leaves it `delivered`; an ack failure is reported but does **not** fail the reply or change its exit status.
7c. Add refusal tests: replying to a still-`queued` original is rejected with a `recv` hint; `--allow-unknown` with `--deliver` is rejected.
7d. Assert a single session enumeration by counting **session-enumeration calls specifically** via the fake-tmux harness — not total tmux invocations. Delivery legitimately calls tmux for `has-session`, `capture-pane`, and the paste itself (`cctrl:3319`), so a raw count would encode nonsense.
7e. Assert the MCP surface reports all five states and that `send_message`'s description no longer says "Queue a message".
8. Run the full suite and confirm no existing peer assertion regressed.

## Verification

Checks:

- `[cmd] bash tests/run-tests.sh`
- `[assert] ./cctrl peer help 2>&1` contains `peer reply`
- `[assert] ./cctrl peer reply 2>&1 || true` contains `Usage`
- `[cmd] bash -c 'h1=$(shasum data/messages.jsonl 2>/dev/null || echo absent); bash tests/run-tests.sh >/dev/null 2>&1; h2=$(shasum data/messages.jsonl 2>/dev/null || echo absent); [ "$h1" = "$h2" ]'`
- `[manual] Send a reply between two scratch sessions and confirm the recipient is nudged without any second command.`


## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | issues_found | 10 findings, 9 folded, 1 corrected an approved decision |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 13 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

**CODEX:** caught that `sent-and-delivered` was a misnomer — `deliver` pastes only a nudge and leaves the body queued — and found a missed `deferred` state where a busy pane reports success while nothing is pasted and nothing retries. Both folded, expanding the outcome model from four states to five.

**CROSS-MODEL:** one tension, on what "delivered" means. Resolved in the outside voice’s favour: the state is now `sent-and-nudged`, named for what actually happens.

**VERDICT:** ENG CLEARED — ready to implement. This plan owns the shared reachability classifier that plan 024 consumes; extraction here avoids a dependency cycle.

NO UNRESOLVED DECISIONS
