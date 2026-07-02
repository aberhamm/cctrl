---
id: 015
title: Surface each session's recap (goal + next action) in session ls --recap
status: in-progress
blocked-by: [013]
priority: 15
goal: cctrl-fleet-staleness
allows-migrations: false
needs-review: none
created: 2026-06-30
---

## Requirements

The single best one-line answer to "what is this session" is its `※ recap:`
(goal + next action). Today the user reconstructs it by attaching to each pane.
This plan adds `cctrl session ls --recap` that prints, per session, a one-line
recap derived from its transcript (resolved via the plan-013 helpers).

The recap source is **not** a clean transcript entry type — a survey of a live
transcript found `recap` only as incidental message text, not a dedicated
`type`. So this plan includes a bounded investigation step to pin down where
Claude Code records the recap/summary (e.g. a `summary`/`isCompactSummary`
entry, the latest assistant text, or a pane-rendered element) and extracts the
most reliable available signal, degrading gracefully when none exists. The eng
review must confirm the chosen source before implementation hardens it.

**Acceptance criteria:**

- [ ] `cctrl session ls --recap` prints one recap line per session (truncated to
      a sane width), or a clear placeholder (`-`) when no recap is derivable.
- [ ] The recap is read from the session's transcript (via
      `_session_transcript_path` from plan 013), not by scraping the live pane.
- [ ] Without `--recap`, `session ls` output is unchanged.
- [ ] `cctrl session ls --recap --json` includes a `recap` field (string or
      null) per session.
- [ ] Sessions with no transcript or no derivable recap render `-` / null and
      never error.

## Design

Step 1 is investigation (document findings in the plan's implementation notes):
enumerate transcript entry types and locate the recap/summary signal. Candidate
sources in priority order: a dedicated `summary`/compact-summary entry (or an
`isCompactSummary`-flagged entry); otherwise `-`. Do **not** fall back to the
last assistant `text` line — for the flagship "what is this" column an honest
blank beats a misleading preamble line (e.g. "Let me check that"). Pick the most
reliable dedicated source that exists and implement a `_session_recap <sess>` helper that
reads the transcript tail (bounded — do not load the whole file; read a capped
number of trailing lines) and extracts the chosen field.

**Guaranteed-executable default:** even if the investigation finds no dedicated
recap/summary entry, the worker is NOT blocked — it ships the honest-blank
policy (render `-`). The investigation only upgrades the source when a reliable
dedicated one exists; it never substitutes the last assistant line. This keeps
the plan autonomously executable while keeping the column trustworthy.

`--recap` is opt-in because it costs a transcript read per session; default
`ls` stays cheap.

**Files expected to change:**

- `cctrl`: add `--recap` flag parsing to `_session_list`; add `_session_recap`
  helper; render the recap column / `--json` field only when requested.
- `tests/run-tests.sh`: cases with a fixture transcript containing the chosen
  recap signal, asserting extraction; plus a no-recap fixture asserting `-`.

**Testing approach:** unit-only.

**Out of scope:** pane scraping, generating recaps where none exist, and the
STATE column. Bound the transcript read (no full-file loads).

## Tasks

1. Investigate and document the recap/summary source in transcripts; choose the
   extraction strategy.
2. Implement `_session_recap <sess>` reading a capped transcript tail.
3. Add `--recap` flag to `_session_list`; render column + `--json` field only
   when set.
4. Add tests for the chosen signal and the no-recap fallback.

## Verification

- [cmd] `bash -n cctrl`
- [cmd] `tests/run-tests.sh < /dev/null`
- [assert] a new test with a recap-bearing fixture transcript asserts
  `session ls --recap --json` contains the expected recap text
- [assert] a new test asserts a transcript-less session yields `recap` null /
  `-` under `--recap`
