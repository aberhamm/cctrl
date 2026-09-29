---
id: 093
title: Draft detector hotfix — titled divider misread as scrollback (086 regression)
status: done
completed: 2026-09-29
blocked-by: []
priority: 93
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-29
tui-fixture: n/a
approved-by: matthew (C-15, via cctrl-fleet-manager, hotfix086-fm0929)
reviews:
  - type=eng verdict=approved date=2026-09-29 by=opus-level-subagent
---

## Plain-English Summary

Plan 086 (installed release 5adc34c) regressed `lib/pane_draft.pl`: empty
composers started reading as unsent drafts. `cctrl session ls` showed 3 idle
fleet sessions as `unsent-draft` when their pane held nothing but `❯` and a
non-breaking space, or a dimmed ghost suggestion. This caused false
unsent-draft states in the fleet view and made autoheal skip those sessions
(fail-safe, so not itself dangerous, but wrong).

## Cause

086's border-pair scoping only recognizes a divider line that is ENTIRELY
box/divider-drawing characters. Some real Claude Code panes draw a titled
top divider — tmux's own pane-border-status line, using the same dash
character but with a title embedded in the middle (e.g. `── portal: resume
from handoff portal-auth-architecture (TMUX--ms--portal) ──`). That line
doesn't match the all-border-chars pattern, so only the composer's bottom
divider is recognized, leaving exactly one border in the capture.

The single-border fallback (added in 086 for a capture whose OTHER border
scrolled out of view) then scoped the composer to the WHOLE side of that one
border — from the raw buffer boundary (index 0 for "before") through the
border — and searched that whole range for the FIRST glyph-starting (`❯`/`>`)
line. In a capture with a lot of earlier conversation scrollback above the
composer, that first glyph line can be an unrelated, already-submitted `❯
...` line from earlier in the transcript. Everything from there down to the
border was then judged for real (non-dim) content, which real conversation
text supplies in abundance — a false positive.

## Fix

`lib/pane_draft.pl`'s `@border_idx == 1` branch now scopes to the LAST
glyph line found within the chosen side (matching the zero-border fallback,
which already did this correctly), not the side's raw boundary. This bounds
the judged range to just the actual composer's own prompt line (and any
wrapped continuation after it), the same way the two-border and zero-border
paths already do.

## Requirements

- [x] Fix the single-border fallback to use the last glyph line, not the
      side boundary, as the scope's start.
- [x] Add the real reported capture as a regression fixture
      (`tests/fixtures/pane-draft-titled-divider-empty.txt`) — must read as
      no-draft (rc=1).
- [x] Add a second fixture with a dimmed ghost suggestion instead of an
      empty composer under the same titled-divider shape
      (`tests/fixtures/pane-draft-titled-divider-ghost.txt`) — must also
      read as no-draft (rc=1).
- [x] A test (`test_pane_draft_plan086_hotfix_titled_divider`) pinning both
      fixtures, registered in both the `pane-draft` CCTRL_TEST_ONLY group
      and the full-suite list.
- [x] Confirm no regression across the existing `pane-draft*`,
      `pane-bashmode*`, `pane-pasted-text.txt`, `pane-ghost-suggestion.txt`
      and `pane-empty-hint.txt` fixtures.

## Rules

Edit a copy of `lib/pane_draft.pl` and syntax-check it (`perl -c`), then
`mv` it into place. The live tree runs every session's draft detection.

## Eng review

Opus-level subagent review, 2026-09-29: CLEAR, no required fixes. The
`@border_idx == 1` branch's `$start` now comes from the last glyph index
within the chosen side (`$aft_glyph_idx[-1]` / `$bef_glyph_idx[-1]`)
instead of the side's raw boundary, mirroring the zero-border fallback.
Verified against every existing `pane-draft*`/`pane-bashmode*`/
`pane-pasted-text.txt`/`pane-ghost-suggestion.txt`/`pane-empty-hint.txt`
fixture with no regressions, and confirmed both new fixtures fail on the
pre-fix code and pass on the fix.

Two optional follow-ups flagged, neither blocking, not filed as plans yet:
- The "after" side of the single-border fallback still scopes to EOF
  (including the footer). If a composer's BOTTOM divider ever carries a
  title (mirror image of this bug's TOP-divider case), the same false
  positive could recur from the other side. Not yet observed in the wild.
- A multi-line draft whose LAST line is a bare `>` (e.g. an empty markdown
  quote continuation) would, on the single-border "before" fallback, have
  that bare `>` line picked as the new last-glyph `$start`, skipping the
  real earlier draft content and reading as empty (rc=1) — a false
  negative, unsafe direction for the autoheal gate. Very narrow: any text
  after the `>` still reads correctly.

The reviewer's suggested general fix (recognize a titled divider, dash-run
+ text + dash-run, as a border too, so this capture shape lands in the
normal two-border branch instead of the single-border fallback) would
close both gaps. Left as a future follow-up rather than expanding this
hotfix's scope.
