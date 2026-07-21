---
id: 030
title: Fix the unsent-draft detector so its safety gates actually work
status: blocked
blocked-by: []
priority: 30
goal: cctrl-peer-messaging-discoverable-models
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-19
---

## Requirements

`_session_pane_has_draft` (`cctrl:4660-4673`) is supposed to return true when a
session's input line holds typed, unsubmitted text. It anchors on an ASCII `>`:

```
grep -E '^[[:space:]│|]*>[[:space:]]+[^[:space:]]'
```

Claude Code's input line begins with `❯` (U+276F), not `>`. **The detector never
fires on a real pane.** Verified against the live `TMUX--ms--agent-hub` session,
whose input box visibly held `❯ commit the plans`:

```
_session_pane_has_draft(<real captured pane>)   -> false
_session_pane_has_draft("> commit the plans")   -> true
```

The regex is sound; the glyph is wrong. The codebase already uses the correct
character elsewhere — the Claude modal detector greps `❯ 1\.` at `cctrl:3115`
and `cctrl:4656` — so this is one missed case in one function, not a systemic
encoding problem.

**Two live consumers are silently ineffective as a result:**

1. `_session_autoheal` (`cctrl:5261`) gates its repair on the detector, with this comment: *"skip unsent-draft — a non-empty input line means typed-but-unsent text that C-u would erase (reuses plan 016's draft detector)"*. That gate has never fired. A scheduled job that presses `C-u` has been running with a guard that does nothing, and a comment that confidently describes protection it does not provide.
2. `_session_rich_state` (`cctrl:4727`) layers an `unsent-draft` state onto the fleet view. Confirmed: `cctrl fleet` reports **zero** sessions in that state, ever — while seven sessions were simultaneously holding unsubmitted text. Operators have had no visibility into pending input across the fleet.

This is a small, verified, self-contained fix to a function whose failure is
invisible by construction: a detector that never fires looks exactly like a
fleet where nothing ever needs detecting.

**Acceptance criteria:**

- [ ] `_session_pane_has_draft` returns true for an input line beginning with `❯` (U+276F), and continues to return true for the ASCII `>` form.
- [ ] It still returns **false** for an empty input box, including when placeholder or hint text is present (`Try "…"`, `for shortcuts`, `for commands`, `for newline`, `esc to interrupt`, `/ for`). The existing exclusion filter keeps working against both glyphs.
- [ ] Tests use fixtures **captured from real panes**, not hand-written strings, so a glyph change cannot silently reintroduce the blindness. Include at least one real-pane fixture with a draft and one without.
- [ ] `_session_rich_state` reports `unsent-draft` for a session holding typed input, so `cctrl fleet` surfaces it.
- [ ] `_session_autoheal`'s safety gate demonstrably skips a session with a draft — add a test that proves the gate fires, since it never has.
- [ ] No change to peer delivery behavior in this plan. Wiring the detector into `_peer_pane_ready_for_delivery` is deliberately **not** included here (see Out of scope).
- [ ] `_peer_nudge_line` and `hooks/peer-doorbell.sh` are untouched.

## Design

Widen the anchor to accept both glyphs, keep everything else identical:

```
before:  ^[[:space:]│|]*>[[:space:]]+[^[:space:]]
after:   ^[[:space:]│|]*[>❯][[:space:]]+[^[:space:]]
```

Keep the exclusion filter as-is — it is glyph-independent and already correct.

**Test with real fixtures, not synthetic strings.** This bug survived because
the only thing that ever exercised the detector was a hand-written test string
using the wrong character. Capture two real panes (`tmux capture-pane -p`), commit
them as fixtures, and assert against those. A synthetic test would have passed
against the broken regex and will pass against any future wrong guess too.

**The detector is intentionally sensitive, not precise.** Its documented
"fragile pane detector" status (`cctrl:4667`) is fine: a false positive merely
defers an autoheal or shows an extra fleet state, while a false negative erases
a human's typing. Prefer over-detection. Do not tighten it.

**Files expected to change:**

- `cctrl`: `_session_pane_has_draft` (glyph)
- `tests/run-tests.sh`: real-pane fixtures, detector tests, a rich-state test, and an autoheal-gate test
- `tests/fixtures/` (new, if no fixture convention exists): two captured panes

**Testing approach: unit-only** — the detector is a pure function over captured
text; the rich-state and autoheal tests exercise it through their existing
harnesses.

**Out of scope, deliberately:** wiring this into peer delivery
(`_peer_pane_ready_for_delivery`). That was the original motivation for this
plan, based on a reported class of bug where an incoming peer message destroyed
typed input. **That claim did not survive scrutiny** — see the investigation note
below — so this plan is reduced to the defect that is independently verified.
Adding a delivery guard should wait until the delivery question is actually
settled, and is cheap to add later once the detector works.

## Investigation note (not part of this plan's scope)

One unexplained report remains: `comet-automation--2` reported that an operator's
typed `yes`, approving a live-HID action, never reached it. That is a session's
own report of non-receipt and is independent of the pane observations that were
later retracted. It is one data point suggesting delivery may be able to fail
silently. It is **not** evidence of a buffer-clobbering mechanism, and no
reproduction exists.

Two competing explanations were offered for the surrounding observations and both
were contradicted by evidence: a deterministic clobber (refuted — buffers
survived deliveries in `homelab-mcp-servers` and `agent-hub`), and a rendering
artifact where the box appears empty while the agent works (refuted — `agent-hub`,
`finance-hub--3`, `homelab--2`, `homelab-mcp-servers`, and `obsidian-vault--4`
were all observed rendering their draft text *while working*).

One concrete behavior worth starting from, directly observed: after a doorbell
delivery, the nudge text was present **both** as a submitted turn and as unsubmitted
residue in the receiving session's input box. Injection appears able to leave a
copy behind. Whether that can displace pre-existing text is unknown.

Anyone picking this up should start by reproducing, not by assuming a mechanism.

## Tasks

1. Widen the `_session_pane_has_draft` anchor to accept `❯` as well as `>`.
2. Capture two real panes as fixtures: one holding an unsubmitted draft, one with an empty input box showing hint text.
3. Add detector tests against those fixtures, covering both glyphs and the empty/hint case.
4. Add a `_session_rich_state` test asserting `unsent-draft` is reported for a drafting session.
5. Add an `_session_autoheal` test proving the safety gate now skips a session holding a draft.
6. Run the full suite; confirm no peer assertion changed and the nudge/doorbell strings are untouched.

## Verification

Checks:

- `[cmd] bash tests/run-tests.sh`
- `[assert] bash -c "awk '/_session_pane_has_draft\(\) \{/,/^}/' ~/dev/cctrl/cctrl | grep -q '❯' && echo yes"` contains `yes`
- `[cmd] bash -c 'cap=$(printf "❯ some typed text\n"); awk "/_session_pane_has_draft\(\) \{/,/^}/" ~/dev/cctrl/cctrl > /tmp/d.sh; . /tmp/d.sh; _session_pane_has_draft "$cap"'`
- `[cmd] bash -c 'awk "/_session_pane_has_draft\(\) \{/,/^}/" ~/dev/cctrl/cctrl > /tmp/d.sh; . /tmp/d.sh; ! _session_pane_has_draft "❯ Try \"write a test\""'`
- `[cmd] git -C ~/dev/cctrl diff --quiet -- hooks/peer-doorbell.sh`
- `[manual] With a real session holding typed input, confirm `cctrl fleet` now shows it as unsent-draft.`
