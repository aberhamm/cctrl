---
id: 040
title: Verify paste delivery and uniquify tmux buffer names
status: pending
blocked-by: [039]
priority: 12
goal: revised-cctrl-audit-backlog
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-30
reviews:
  - type=eng verdict=approved date=2026-07-30 by=mstack-review
---

## Requirements

`session say` and the peer nudge paste report success when the tmux commands
exit 0 — nothing confirms the text actually landed in the composer or was
submitted. Combined with the silent-loss modes the substrate plan (039)
closes, callers today cannot distinguish "delivered" from "vanished".
Separately, paste buffers are named `cctrl-say-<sess>-$(date +%s)`,
`cctrl-nudge-<peer>-$(date +%s)`, and `cctrl-inline-<peer>-$(date +%s)`
(the `--inline` branch of `_peer_deliver_one_locked`): two concurrent senders
within the same second overwrite each other's buffer (A pastes B's content,
then A's `delete-buffer` breaks B's paste).

**Acceptance criteria:**

- [ ] Buffer names include `$$-$RANDOM` so concurrent invocations never collide — all three sites: say (`cctrl-say-`), nudge (`cctrl-nudge-`), and inline (`cctrl-inline-` in `_peer_deliver_one_locked`'s `--inline` branch).
- [ ] After pasting without submit, `_session_say` captures the pinned pane's input region and verifies the pasted text is present; after submit (Enter), it verifies the composer emptied OR the text appears as an echoed prompt line. Verification failure exits non-zero with a distinct `paste-unverified` status.
- [ ] `paste-unverified` is distinct from `failed`: the paste may in fact have landed, so callers MUST NOT auto-resend (duplicate-submission risk). For `peer deliver` the message stays queued/actionable with the `paste-unverified` outcome recorded as the delivery status/reason (existing `PEER_DELIVER_STATUS`/`PEER_DELIVER_REASON` vocabulary); no automatic retry anywhere — the caller decides.
- [ ] The `--inline` delivery path gains the same post-paste verification and `verified` reporting — it pastes full message bodies through the same emitter, so it verifies like say bodies (normalized prefix), not like the fixed-line nudge.
- [ ] `--json` output for `session say` and `peer deliver` gains a `verified: true|false` field; on verification failure the mismatch snippet (what the pane actually showed) is emitted as the reason, for diagnosability.
- [ ] Multi-line and unicode bodies verify correctly (match on a normalized prefix, not exact pane bytes — tmux wraps long lines).
- [ ] Claude Code collapses multi-line pastes in the composer to a `[Pasted text #N +M lines]` placeholder instead of the body — verification accepts that placeholder as verified (or uses capture-diff) for multi-line sends.
- [ ] A fake-tmux test simulates a swallowed paste (capture returns unchanged pane) and asserts the non-zero `paste-unverified` outcome.
- [ ] The fake tmux capture is made stateful — `capture-pane` reflects the last `load-buffer` payload — building on plan 039's harness task. Today it returns a static `TMUX_FAKE_CAPTURE_PANE` for every capture, so post-paste verification would fail every currently-green success test; affected say/deliver tests are updated accordingly.

## Design

Verification is a bounded post-condition check, not a retry loop: capture once
after paste (and once after Enter when submitting), compare against the first
~120 chars of the body with whitespace normalized (pane wrapping mangles longer
matches). Keep the window small — one extra `capture-pane` per say.

The `peer deliver` nudge is a single fixed line, so its verification is an
exact-substring check for the nudge prefix. The `--inline` branch pastes full
message bodies, so it verifies like say bodies (normalized prefix / placeholder
acceptance), not like the nudge.

`paste-unverified` semantics: it means "tmux commands succeeded but the
post-condition check could not confirm the text" — NOT "delivery failed". The
paste may have landed (capture raced the redraw), so auto-resend risks a
duplicate submission; the outcome is recorded and the message left
queued/actionable, and any retry is a human/caller decision.

Call-site cost: `_session_say_json` is positional (5 args) and called ~15
times — adding `verified` means touching every call site in one sweep, not
just the success path.

**Files expected to change:**

- `cctrl`: `_session_say` (verify + buffer name), nudge and `--inline` paste in `_peer_deliver_one_locked` (verify + buffer names), `_session_say_json` and the `peer deliver` `--json` emitters (all call sites)
- `tests/run-tests.sh`: stateful fake capture (capture-pane echoes last load-buffer), swallowed-paste fixture, collision test (two says in the same second), multiline verification test, updates to existing say/deliver success tests

**Testing approach: E2E** — fake-tmux harness, isolated `CCTRL_DATA_DIR`.

**Out of scope:** readiness semantics (041), automatic retry on verification
failure, any change to nudge wording.

## Tasks

1. Make the fake tmux capture stateful in `tests/run-tests.sh` (capture-pane reflects the last load-buffer payload; extends plan 039's harness task), and update existing say/deliver success tests that rely on the static `TMUX_FAKE_CAPTURE_PANE`.
2. Add `$$-$RANDOM` to all three buffer-name sites (say, nudge, inline).
3. Implement the post-paste capture/compare in `_session_say` (no-submit and submit variants, `[Pasted text #N +M lines]` placeholder acceptance for multi-line).
4. Implement verification in the deliver path — nudge (exact-substring) and `--inline` (body prefix) — mapping failure to `paste-unverified` in the existing delivery vocabulary, message left queued, no auto-resend.
5. Emit `verified` in both `--json` payloads (sweep all ~15 `_session_say_json` call sites) plus the mismatch-snippet reason on failure.
6. Add tests: swallowed paste (`test_session_say_swallowed_paste_unverified`), same-second collision, multiline/unicode verify.
7. Run the full suite.

## Verification

Checks:

- `[cmd] bash tests/run-tests.sh`
- `[assert] grep -n 'cctrl-say-' cctrl` contains `RANDOM`
- `[assert] grep -c '^test_session_say_swallowed_paste_unverified' tests/run-tests.sh` contains `2` (function defined AND invoked by name — the runner has no filter, so both lines must exist for the swallowed-paste test to run)
- `[cmd] bash -c 'h1=$(shasum data/messages.jsonl 2>/dev/null || echo absent); bash tests/run-tests.sh >/dev/null 2>&1; h2=$(shasum data/messages.jsonl 2>/dev/null || echo absent); [ "$h1" = "$h2" ]'`
- `[assert] ./cctrl session say --help 2>&1 || true` contains `say`

<!-- mstack:seam
produced:
- kind: schema; name: verified; file: cctrl
assumed:
- from: 039; kind: symbol; name: _tmux_pin_pane; file: cctrl
-->
