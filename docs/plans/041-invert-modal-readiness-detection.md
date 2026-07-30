---
id: 041
title: Invert modal readiness — require a positively identified idle composer
status: pending
blocked-by: [040]
priority: 13
goal: revised-cctrl-audit-backlog
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-30
reviews:
  - type=eng verdict=approved date=2026-07-30 by=mstack-review
---

## Requirements

Readiness for pasting (`_peer_pane_ready_for_delivery`, reused by
`_session_say`) is an **allowlist of known modal signatures**. Its Claude
branch matches ONLY the anchor `❯ 1\.` — the "Do you want to
(proceed|create|make)" / "Do you trust the files" signatures live in
`_session_pane_has_dialog` (the rich-state detector), a separate function
that this readiness path does not consult. The Codex branch already defers
on `Allow Codex to ` / `approve network access` / `tell Codex what to do
differently`, so Codex APPROVAL modals are already covered. Any
differently-phrased dialog — MCP tool approval, plan-mode confirm, update
prompts, the session-resume modal — is invisible, so `say` pastes text +
Enter and **Enter activates the highlighted dialog button**: an invisible
permission grant or denial. The inversion's new win is precisely those
unknown/unlisted dialogs and the resume modal. Live evidence this week: two
fleet sessions sat on the resume modal misclassified as ready/unsent-draft.
The safe polarity is the opposite: *cannot positively identify an idle
composer ⇒ not ready.*

There is also a dead-end in the current default branch: peers whose metadata
lacks a recognized `agent` return "unknown agent readiness" and are
**permanently deferred** — deliver reports rc 0, nothing escalates, the peer
never gets nudged. Composer-shape detection removes the dependency on agent
type and fixes that.

**Acceptance criteria:**

- [ ] Readiness = the pinned pane's bottom input region positively matches a known idle-composer shape (Claude `❯ ` prompt line / Codex composer), AND no dialog marker is present. Everything else is not-ready.
- [ ] `session say` against an unrecognized dialog (e.g. the resume modal: "Resuming the full session will consume … Enter to confirm") refuses instead of pasting; `--force-busy` still overrides, and its help text states the Enter-presses-a-button risk.
- [ ] `peer deliver` classifies not-ready as `deferred` (existing vocabulary) — but a peer with an unrecognized `agent` whose pane shows a detectable idle composer is now **nudgeable**, eliminating the permanent silent deferral.
- [ ] The readiness decision and the paste happen against the same single capture wherever feasible. Immediately before the Enter keypress, a **narrower pre-Enter predicate** is re-checked against a fresh capture: dialog-markers-absent (no known dialog/selector signature in the bottom region) — NOT the full idle-composer predicate, which cannot be used at this point because the pane now contains our own pasted text and would always classify not-ready. Optionally, the pasted-prefix match from 040's verification capture doubles as confirmation the composer holds our text. This shrinks (not fully closes — noted limitation) the check-then-paste TOCTOU window. `--force-busy` remains a blind-Enter path; its help text must state that risk.
- [ ] Rollback guard: `CCTRL_READINESS_POSITIVE=0` restores the old allowlist polarity (per-detector env-guard convention, like `CCTRL_STATE_DETECT_*`). Default is the new positive-identification polarity.
- [ ] Operator visibility: deferred deliveries are distinguishable by age — `peer status` gains one minimal field per peer (oldest-deferral age, or deferral count), so a week-old deferral doesn't look fresh. One field only; not a status redesign.
- [ ] Autoheal's and doctor's busy-gating keep their current fail-safe behavior (they may only get MORE conservative, never less).
- [ ] Fixtures: resume modal, MCP-approval-style dialog, plain idle Claude composer, Codex composer, unknown-agent-with-idle-composer. Full suite passes.

## Design

This plan INTRODUCES and owns a shared helper, `_pane_bottom_region`
(extract the last non-empty block / tail-N rows of a capture); plan 046
adopts it (046 is now blocked-by [041]). Match structure in the **bottom
region** of the capture (last ~12 lines), not anywhere in 40 lines of
scrollback. An idle composer is: a prompt line (`❯ ` for Claude; for Codex
there is NO existing composer signature anywhere in cctrl — the existing
Codex anchors are modal text only, so Task 1 must capture/discover the Codex
composer signature from a real pane) with nothing after it but hint/blank
lines, and no `Enter to confirm` / `Esc to cancel` / numbered selector block
above it.

Behavior change risk: sessions previously (wrongly) considered ready become
deferred. That is the intended direction — silent deferral is visible in
`peer status` while a mispressed dialog button is invisible and irreversible.
Call this out in CHANGELOG.

**Fixture sourcing fallback:** if a live resume modal cannot be reproduced on
demand, capture the fixture from a fleet session exhibiting it (two sessions sat
on this exact modal during the 2026-07 audit) — never fabricate fixture text.

**Codex contingency:** if Task 1 finds no stable Codex composer signature (Codex
renders selection as reverse-video with no reliable glyph — see the existing
readiness comments), fall back per-agent: codex peers KEEP the current
allowlist polarity (modal-anchor deferral) while claude panes get positive
detection. Inversion must never permanently defer all codex peers;
`CCTRL_READINESS_POSITIVE=0` remains the fleet-wide rollback.

**Files expected to change:**

- `cctrl`: new `_pane_bottom_region` helper; `_peer_pane_ready_for_delivery` rewritten around positive composer identification (with `CCTRL_READINESS_POSITIVE=0` polarity rollback guard); `_session_say` refusal message; help text for `--force-busy`; one deferral-age/count field in `peer status`
- `tests/run-tests.sh`: new modal/composer fixtures (add real captured panes to `tests/fixtures/` alongside the existing `pane-draft.txt` pair)

**Testing approach: E2E** — fake-tmux harness with pane fixtures.

**Out of scope:** the `session key` verb that acts on modals (plan 042), draft
detection (plan 046), changing autoheal.

## Tasks

1. Capture real pane fixtures: resume modal, permission dialog, idle Claude composer, idle Codex composer — this is where the Codex composer signature is discovered (none exists in cctrl today).
2. Add `_pane_bottom_region` (last non-empty block / tail-N rows of a capture) as the shared helper this plan owns; plan 046 will adopt it.
3. Rewrite `_peer_pane_ready_for_delivery`: bottom-region positive composer match; dialog markers force not-ready; drop the agent-type dead-end default. Guard the new polarity behind `CCTRL_READINESS_POSITIVE` (default on; `=0` restores the old allowlist polarity, per the `CCTRL_STATE_DETECT_*` env-guard convention).
4. Update `_session_say` refusal text and `--force-busy` help (state the blind-Enter risk).
5. Wire single-capture readiness into the paste path; immediately before Enter, re-check the narrower dialog-markers-absent predicate against a fresh capture (the full idle-composer predicate would always fail here — the pane now contains the pasted text).
6. Add the one deferral-age (or deferral-count) field to `peer status`.
7. Add fixture-driven tests incl. unknown-agent-nudgeable case and the `CCTRL_READINESS_POSITIVE=0` rollback path.
8. Run the full suite; update CHANGELOG noting the polarity change.

## Verification

Checks:

- `[cmd] bash tests/run-tests.sh`
- `[assert] ./cctrl session say --help 2>&1 || ./cctrl help 2>&1` contains `force-busy`
- `[cmd] bash -c 'grep -q "Resuming the full session" tests/fixtures/*.txt'`

<!-- mstack:seam
produced:
- kind: flag; name: CCTRL_READINESS_POSITIVE; file: cctrl
- kind: symbol; name: _pane_bottom_region; file: cctrl
- kind: symbol; name: _peer_pane_ready_for_delivery; file: cctrl
assumed:
- from: 039; kind: symbol; name: _tmux_pin_pane; file: cctrl
-->
