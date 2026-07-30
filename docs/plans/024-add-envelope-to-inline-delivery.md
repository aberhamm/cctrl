---
id: 024
title: Add a sender envelope to inline peer delivery
status: done
completed: 2026-07-22
blocked-by: [023, 027]
priority: 24
goal: cctrl-peer-messaging-discoverable-models
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-19
reviews:
  - type=eng verdict=approved date=2026-07-19 by=mstack-review
---

## Requirements

`cctrl peer deliver --inline <id>` pastes the raw message body straight into the
recipient's tmux pane. `_peer_deliver_one_locked` sets
`payload="$message_body"` (`cctrl:3290-3295`) with **no envelope whatsoever**:
no sender, no subject, no message id, no ack instruction. The receiving model
sees a wall of text appear in its input that is indistinguishable from the human
operator typing. It cannot tell who sent it, and it cannot reply.

It also cannot acknowledge. `_peer_record_inline_json` (`cctrl:3191`) records
history but never changes `status`, so an inline-delivered message stays
`queued` — and `_peer_cmd_ack` explicitly **rejects** queued messages with
`Message '<id>' is still queued; receive it first`. Inline delivery is a
dead-end path today: the body arrives, and the lifecycle cannot be completed.

This plan gives inline delivery a sender envelope and closes the ack dead-end,
without touching the nudge path that the fleet's ~16 live sessions depend on.

**Acceptance criteria:**

- [ ] `cctrl peer deliver --inline <id>` prefixes the pasted payload with an envelope header carrying sender label + canonical name, the message id, and the subject when non-empty.
- [ ] The envelope tells the receiver how to reply (`cctrl peer reply <message-id> ...`, from plan 027) and how to acknowledge (`cctrl peer ack <id> ...`), using the concrete message id, not placeholders.
- [ ] When the sender is the human operator (`from == "user"`), the envelope does **not** emit a `cctrl peer send user ...` reply line — that command fails recipient resolution. It states the message came from the human operator and that the reply belongs in the conversation. The ack line is still emitted.
- [ ] The reply line emits the single atomic form `cctrl peer reply <message-id> --as <recipient> --json -- "<body>"` from plan 027, which sends **and** delivers. It must never emit a bare `cctrl peer send`: send alone only queues (`cctrl:2694-2698`) and no watcher runs by default, so a send-only reply line is a silent failure — the receiver sees `Queued message: <id>` and believes it replied.
- [ ] The envelope annotates sender reachability **at delivery time**, not send time, using the three-way classification `_peer_tmux_target_for_delivery` (`cctrl:3068`) already implements:
  - live tmux session → emit the full send-and-deliver reply line
  - dead/missing tmux session, **or** the peer no longer resolves at all → emit an explicit `SENDER IS NO LONGER LIVE — do not reply to this peer` line and **no** reply command
  - `no-tmux-capability` (polling/MCP-only peer) → emit the normal `peer reply` line; these peers are reachable by mailbox and must **never** be marked unreachable

**Interaction with plan 028 (stable identity).** This plan deliberately does
**not** depend on 028. The `unresolvable peer → unreachable` branch is written
against name-based resolution as it exists today. When 028 lands, successor
claiming will make some currently-unresolvable senders resolvable by stable id,
and 028 owns updating this classifier accordingly — it already modifies
`_peer_resolve_json`. Blocking this plan behind a migration-gated one would
delay the user-visible fix for no benefit.
- [ ] The ack line is emitted in every reachability branch, including when the sender is gone.
- [ ] The envelope is built from the message's `sender` object (plan 023) and falls back to the bare `from` string for messages that predate it.
- [ ] The message body is delivered unaltered after the envelope; no truncation, no re-wrapping, and trailing newlines are preserved.
- [ ] Inline delivery sets `status: "delivered"` **and** `delivered_at`, so `cctrl peer ack <id>` succeeds against an inline-delivered message.
- [ ] `_peer_delivered_stale_json` (`cctrl:3735`) correctly ages inline-delivered messages, so they appear in the delivered-but-unacked stale sweep like any other delivered message.
- [ ] `_peer_nudge_line` output is **byte-identical** to today, asserted by the existing test at `tests/run-tests.sh:2331`.
- [ ] `hooks/peer-doorbell.sh` is unchanged, asserted by a regression test that pins its emitted string.
- [ ] A message already in `delivered` status that is re-delivered inline does not regress its status or clobber its original `delivered_at`.

## Design

Only the `inline_id` branch of `_peer_deliver_one_locked` changes. The `else`
branch — which builds the nudge via `_peer_nudge_line` — must not be touched.

**Envelope format.** Keep it compact; it is prepended to every inline body and
consumes the receiver's context. Target shape:

```text
[cctrl peer message] from: @homelab (TMUX--ms--homelab) · id: msg_20260719_...
Reply:  cctrl peer reply msg_20260719_... --as <recipient> --json -- "<your reply>"
Ack:    cctrl peer ack msg_20260719_... --as <recipient> --json
---
<original body verbatim>
```

**Use `peer reply` (plan 027), not a send-and-deliver chain.** 027 adds an
atomic `cctrl peer reply <message-id>` that resolves the recipient from the
message's own sender and both sends and delivers. That collapses the reply to
one command and — critically — means the receiving model never has to know or
type the sender's address at all. It also removes the failure mode where a model
runs the `send` half of a chained command and drops the `deliver`. This plan is
blocked by 027 precisely so the envelope can emit the single-command form.

**Every emitted command must carry `--as <recipient>`.** `_peer_cmd_send`
requires an identity from `--from`, `--as`, or `CCTRL_PEER` and errors without
one (`cctrl:2602-2615`); `ack` has the same requirement via
`_mailbox_resolve_identity_for_mode`. A non-interactive agent shell may not have
`CCTRL_PEER` exported, so a bare command fails. The existing nudge line already
includes `--as` (`cctrl:3001`) — match it. Substitute the delivering peer's
canonical name, not a placeholder.

When the sender is no longer reachable:

```text
[cctrl peer message] from: @homelab (TMUX--ms--homelab) · id: msg_20260719_...
SENDER IS NO LONGER LIVE — do not reply to this peer.
Ack:    cctrl peer ack msg_20260719_... --json
---
<original body verbatim>
```

**Reachability is resolved at delivery time, not send time.** The `sender`
snapshot from plan 023 records who the sender *was*; by the time a model reads
the pane, that peer may be gone. Since peer names for derived peers are tmux
session names (`cctrl:1948`), a stale address makes `cctrl peer send` fail with
`Unknown recipient` (`cctrl:2628-2631`) — which is the original incident this
whole initiative exists to fix. Inline delivery already resolves the
*recipient's* tmux target at this exact moment, so resolving the *sender's*
reachability in the same breath costs one extra call and is the closest point in
time to when the model actually reads the message.

Reuse the three-way *logic* of `_peer_tmux_target_for_delivery` — which already
separates `no-tmux-capability` (`skipped`, `cctrl:3071-3074`) from a genuinely
dead session (`failed`) — because a naive `tmux has-session` collapses those two
and would stamp `SENDER IS NO LONGER LIVE` on a polling-only peer whose mailbox
works perfectly, suppressing valid replies silently.

**But do NOT call `_peer_tmux_target_for_delivery` directly.** It is not a pure
function: it writes `PEER_DELIVER_STATUS` (`cctrl:3072-3093`) and
`PEER_DELIVER_TARGET` (`cctrl:3095`), and `_peer_deliver_one_locked` reads
`PEER_DELIVER_TARGET` at `cctrl:3334` as the **recipient's** paste target while
`_peer_delivery_result_json` reads it at `cctrl:3213`. Calling it for the sender
mid-delivery clobbers the in-flight recipient delivery.

**Consume the pure classifier that plan 027 extracts.** 027 owns extraction
(this plan is blocked by it, so the reverse would be a dependency cycle) and
provides a side-effect-free function taking a peer JSON object and returning
`live` / `mailbox-only` / `unreachable`. Call that. Do not write a second
implementation, and do not fall back to a save/restore of the `PEER_DELIVER_*`
globals — that leaves a trap for the next editor. If 027's classifier is missing
when this plan runs, stop and report rather than reimplementing it.

**The reply line must chain `deliver`.** `_peer_cmd_send` ends at
`cctrl:2694-2698` printing `Queued message: <id>` and stops; delivery is a
separate step and no `peer watch` daemon runs by default. A send-only reply line
therefore produces a confident-looking success that never reaches the sender.

Build the sender fragment from `.sender.label` and `.sender.name`, falling back
to `.from` alone when `sender` is absent. Include the subject line only when
`.subject` is non-empty.

**The `user` sender is a real case, not an edge case.** `peer send --from user`
is the path a human takes, and inline delivery is exactly how a human-originated
message reaches a pane. But `"user"` is never a registered or derived peer:
`_peer_cmd_send` validates the recipient with `allow_user=false` (`cctrl:2619`)
and resolves it without `--allow-unknown` (`cctrl:2628-2631`), so
`cctrl peer send user` fails with `Unknown recipient: user`. Emitting that as
the reply line would hand the receiving agent a command guaranteed to error.
Branch the envelope: for `from == "user"`, print a line identifying the human
operator as the sender and directing the reply into the conversation instead of
the mailbox. Keep the ack line in both branches — acking a human-sent message
works normally. Use the same body-extraction path as today
(`_peer_message_body_from_json`, `cctrl:3207`) — it uses `jq -j` plus a sentinel
specifically to preserve trailing newlines, so prepend to `PEER_MESSAGE_BODY`
rather than re-extracting the body a different way.

**Closing the ack dead-end.** `_peer_record_inline_json` must transition the
message the way `_peer_cmd_recv` does (`cctrl:2960-2969`): set
`status = "delivered"`, `delivered_at = $now`, `updated_at = $now`, and append a
`{status: "delivered"}` history entry alongside the existing `inline` event
entry. Only transition when the current status is `queued`; a message already
`delivered` or `acked` keeps its status and its original `delivered_at`.

Setting `delivered_at` is not optional bookkeeping. `_peer_delivered_stale_json`
(`cctrl:3735`) reads it to compute age for the delivered-but-unacked stale
sweep that `peer watch` drives. Flipping `status` without setting
`delivered_at` would silently break the age calculation for this new class of
message. Folding inline deliveries into that sweep is desirable — the sweep is
currently blind to them.

Only transition on **successful** paste. The failure branches
(`cctrl:3378-3389`) must continue to record the failure without marking the
message delivered.

**Protecting the common path.** The nudge line is duplicated in two places:
`_peer_nudge_line` (`cctrl:2999`) and `hooks/peer-doorbell.sh:35`. Both must
stay byte-identical. **Both sides are already pinned**: `tests/run-tests.sh:2331`
covers the cctrl side, and `test_peer_doorbell_hook`
(`tests/run-tests.sh:2703-2764`, assertion at line 2748) already asserts the
doorbell's exact emitted string. Do not write a new redundant test — confirm
both existing assertions still pass unmodified, and only extend them if this
plan's changes expose a gap. Do **not** refactor the duplication away in this
plan — deduplicating would itself be a behavior change to a path the live fleet
depends on.

**Files expected to change:**

- `cctrl`: `_peer_deliver_one_locked` (inline branch: build and prepend envelope), `_peer_record_inline_json` (queued → delivered transition with `delivered_at`)
- `tests/run-tests.sh`: extend `test_peer_deliver_busy_no_submit_and_inline`; add a doorbell-string regression test

**Testing approach: E2E** — the existing inline tests drive real tmux panes via
`cctrl peer deliver` against an isolated `CCTRL_DATA_DIR`.

**Out of scope:** the nudge line, `hooks/peer-doorbell.sh` behavior, and
deduplicating the shared nudge string. Do not add sender names to the nudge
path — that changes the string every idle session sees and is deliberately
deferred. Do not touch the MCP bridge (plan 025) or documentation (plan 026).

## Tasks

1. Add a helper that renders the envelope header from a message JSON object, using `sender.label`/`sender.name` with fallback to bare `from`, and omitting the subject line when empty. It takes a reachability verdict (live / unreachable / mailbox-only) and emits the matching reply line.
1a. Call the pure reachability classifier extracted by plan 027 to resolve sender reachability at delivery time. Do not reimplement it; if it is absent, stop and report.
1b. Emit `--as <recipient>` on every command the envelope prints (send, deliver, ack), using the delivering peer's canonical name.
2. In the `inline_id` branch of `_peer_deliver_one_locked`, prepend the envelope to `PEER_MESSAGE_BODY` before assigning `payload`, preserving the trailing-newline-safe extraction.
3. Update `_peer_record_inline_json` to transition `queued` → `delivered` with `delivered_at` and a `delivered` history entry, leaving already-`delivered`/`acked` messages untouched.
4. Confirm the transition happens only on successful paste; leave the failure branches recording failure without marking delivered.
5. Confirm the two existing nudge/doorbell pins (`tests/run-tests.sh:2331` and `test_peer_doorbell_hook` at 2748) still pass unmodified; do not add a duplicate test.
6. Extend the inline delivery test: envelope contains sender label, canonical name, and id; body arrives verbatim; `cctrl peer ack <id>` now succeeds; a legacy message without `sender` still produces a usable envelope from `from`; a `--from user` message produces the no-reply-line variant and never emits `cctrl peer send user`.
7. Add a test asserting an inline-delivered message appears in the delivered-stale sweep with a sane age.
8. Add reachability tests, one per branch: live tmux sender → reply line emits `cctrl peer reply <id>`; dead tmux session → `SENDER IS NO LONGER LIVE` and no reply command; `no-tmux-capability` peer → reply line still emitted (mailbox peers are reachable) and **not** marked unreachable; unresolvable peer → treated as unreachable. Assert the ack line appears in all four, and assert no branch ever emits a bare `cctrl peer send`.
9. Add a **critical** test: when `_peer_tmux_paste` fails, the message status stays `queued` and `delivered_at` remains null. A regression here silently drops fleet messages — the sender believes it landed and nothing retries.
10. Add idempotency tests: re-delivering an already-`delivered` message preserves its original `delivered_at`; an already-`acked` message is left unchanged.
10a. Add a test asserting the pure classifier leaves `PEER_DELIVER_STATUS` / `PEER_DELIVER_TARGET` untouched, and that an inline delivery to peer A whose sender is peer B still pastes into **A's** pane (guards the global-clobber regression).
10b. Body-preservation test must capture **raw bytes**. The current fake-tmux harness logs `BUFFER %s\n`, which cannot prove trailing-newline fidelity — write the load-buffer payload to a file and byte-compare against the original body.
11. Run the full suite and confirm the nudge assertion at `tests/run-tests.sh:2331` and `test_peer_doorbell_hook` (2748) both still pass untouched.

## Verification

Checks:

- `[cmd] bash tests/run-tests.sh`
- `[assert] bash -c "grep -q 'new peer message(s) for' ~/dev/cctrl/hooks/peer-doorbell.sh && echo yes"` contains `yes` — existence form, not `grep -c … contains N` (a line count substring-matched is fragile)
- `[assert] grep -n 'new peer message(s) for %s. Run: cctrl peer recv --as %s --json' ~/dev/cctrl/cctrl` contains `printf`
- `[cmd] git -C ~/dev/cctrl diff --quiet -- hooks/peer-doorbell.sh` — exits 0 only when the doorbell hook is unmodified
- `[cmd] bash -c 'h1=$(shasum data/messages.jsonl 2>/dev/null || echo absent); bash tests/run-tests.sh >/dev/null 2>&1; h2=$(shasum data/messages.jsonl 2>/dev/null || echo absent); [ "$h1" = "$h2" ]'` — the live store must be byte-identical before and after the suite. **Do not** use `git status --porcelain data/...`: `data/` is gitignored (`.gitignore:39`), so that form always returns empty and verifies nothing.
(The `--from user` guard is verified behaviorally by the Task 6 test, not by
grepping source. A static `grep` for `from == "user"` cannot work: the codebase
idiom is `[[ "$from" == "user" ]]`, so the pattern matches nothing in a correct
implementation, `grep -c` prints `0` and exits 1, and `|| true` swallows the
failure — the check would pass whether or not the bug exists.)
- `[manual] Deliver a real message inline into a scratch tmux pane and confirm the receiving agent can identify the sender and successfully run the ack command shown in the envelope.`

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | issues_found | 11 findings, 9 folded, 1 tension resolved, 1 promoted to plan 028 |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 15 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

**CODEX:** found 11 defects the review missed, including two that would have shipped broken — jq `//` not falling through empty strings (blank labels) and `_peer_tmux_target_for_delivery` mutating the in-flight delivery target. Both reproduced and folded.

**CROSS-MODEL:** one tension (reply via nudge vs `deliver --inline`); resolved in favour of the atomic `peer reply` introduced by plan 027, which supersedes both. Everything else was additive, not contradictory.

**VERDICT:** ENG CLEARED — ready to implement. Batch expanded 4 → 6 plans; 027 and 028 were promoted from deferred TODOs on review evidence.

NO UNRESOLVED DECISIONS
