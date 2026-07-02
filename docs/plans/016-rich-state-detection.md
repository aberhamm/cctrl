---
id: 016
title: Rich STATE detection — waiting-input, blocked-dialog, unsent-draft, idle-done
status: pending
blocked-by: [014]
priority: 16
goal: cctrl-fleet-staleness
allows-migrations: false
needs-review: none
created: 2026-06-30
---

## Requirements

The base STATE column (plan 014) distinguishes working/idle/shell but cannot
tell a session *waiting for the user to answer a question* from one that
*finished and is genuinely idle*, nor surface a session *frozen on a dialog* or
one with a *reply typed but never sent*. In the diagnosing session, these blind
spots hid ~9 sessions frozen on the fullscreen-renderer prompt and several
unsent drafts. This plan layers richer states onto the base column:

- `waiting-input` — agent asked something / is awaiting a user turn
- `blocked-dialog` — a modal/dialog (e.g. permission, fullscreen prompt) is
  blocking progress
- `unsent-draft` — text is present in the input but not submitted
- `idle-done` — idle with the last turn being an assistant message (finished,
  nothing pending)

These rely on transcript-tail inspection and bounded pane inspection. The
handoff flagged these heuristics as fragile, so each detector must fail safe:
when uncertain, fall back to the base state (014) rather than mislabel.

**Acceptance criteria:**

- [ ] `session ls` STATE shows `waiting-input` when the transcript tail / pane
      indicates the agent is awaiting a user response.
- [ ] STATE shows `blocked-dialog` when a blocking dialog/prompt is detected in
      the pane.
- [ ] STATE shows `unsent-draft` when the input line holds unsubmitted text.
- [ ] STATE distinguishes `idle-done` (idle + last turn assistant) from a bare
      `idle`.
- [ ] Every detector falls back to the base state (014) when its signal is
      ambiguous or unavailable — no false positives that override a confident
      base state incorrectly.
- [ ] `--json` `state` carries the refined value; a test documents the precedence
      order between detectors.
- [ ] Detection adds no full-file transcript reads and a bounded number of
      `tmux capture-pane` calls per session.

## Design

Extend the state resolver from 014 into a layered `_session_rich_state <sess>`:
start from base state, then apply detectors in a documented precedence
(e.g. blocked-dialog > unsent-draft > waiting-input > idle-done > base):

- **waiting-input / idle-done:** inspect the transcript tail (capped lines) for
  the last message role and shape — last entry user vs assistant, presence of a
  pending question.
- **blocked-dialog / unsent-draft:** `tmux capture-pane -p` (bounded) and match
  known dialog signatures / a non-empty input line. Must `#{pane_in_mode}`-guard
  and never inject keystrokes (read-only), per the copy-mode learning in
  plan 012.

Make detectors individually disableable internally so a flaky one can be turned
off without removing the column.

**Files expected to change:**

- `cctrl`: add `_session_rich_state` (and per-detector helpers); switch
  `_session_list` STATE to use it.
- `tests/run-tests.sh`: fixture transcripts + a stub `tmux capture-pane` (the
  harness already stubs `tmux`) to drive each detector, including ambiguous
  cases that must fall back to base state.

**Testing approach:** unit-only.

**Out of scope:** taking any action on the detected state (no auto-dismiss, no
keystroke injection) — read-only classification only. The "what needs me"
digest that consumes these states is plan 022.

## Tasks

1. Define the state precedence and document it in the function header.
2. Implement transcript-tail detectors (`waiting-input`, `idle-done`).
3. Implement bounded pane detectors (`blocked-dialog`, `unsent-draft`) with
   `#{pane_in_mode}` guarding and no keystroke injection. Match on **stable,
   specific signatures** (e.g. the fullscreen-renderer prompt string; a
   non-empty input line), never loose heuristics — an unmatched pane yields the
   base state, never a guess. Ship with **realistic captured-pane fixtures**
   (real `tmux capture-pane` output for a dialog-blocked pane and an
   unsent-draft pane), not just empty stubs, so the signatures are proven.
4. Compose into `_session_rich_state` with safe fallback to base state.
5. Wire into `_session_list`; add tests for each detector + ambiguous-fallback
   cases.

## Verification

- [cmd] `bash -n cctrl`
- [cmd] `tests/run-tests.sh < /dev/null`
- [assert] a test driving a "last turn = user question" fixture asserts
  `state` == `waiting-input`
- [assert] a test driving an ambiguous fixture asserts `state` falls back to the
  base value (no misclassification)
