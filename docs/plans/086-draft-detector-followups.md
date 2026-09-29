---
id: 086
title: Draft detector follow-ups (073 re-review)
status: done
blocked-by: []
priority: 86
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-28
completed: 2026-09-29
tui-fixture: n/a
approved-by: matthew (C-15, via cctrl-fleet-manager)
reviews:
  - type=eng verdict=approved date=2026-09-29 by=opus-level-subagent
---

## Plain-English Summary

Split from plan 075. P3 findings from the 2026-09-27 eng review of plan
073 (draft detector), plus one item from the follow-up re-review, that
weren't fixed when the P2 fixes shipped.

## Requirements

- [x] Wrapped and multi-line drafts. Judge every composer line up to the
      bottom border or hint line, so a draft whose first composer line is
      empty is still found. Keep a draft that consists only of `>` or `|`
      as well.
- [x] Separate exit code for "no composer found": a bash-mode `!` prompt,
      a pager, or a shell left after a crash. Autoheal treats it as
      unverifiable; rich state keeps the base state.
- [x] Check against a live capture whether Claude draws the `[Pasted text
      …]` placeholder dim. If it does, treat it as a draft.
- [x] One shared escape regex for `lib/pane_draft.pl` and `_strip_sgr`.
- [x] A typed draft that *starts* with placeholder text (`❯ Try "foo…"`,
      `❯ esc to cancel…`) still reads as empty. Apply the hint check only
      to composer lines with no SGR at all.

## Rules

Edit a copy of `cctrl` or `lib/*` and syntax-check it (`bash -n` / `perl
-c`), then `mv` it into place. The live tree runs every session's hooks.

## Implementation notes (2026-09-29)

`lib/pane_draft.pl` now scopes "the composer" to the text between the last
two border-only lines in the capture (a box or a plain dash divider), not
just "whichever line last matched the prompt glyph" — this is what makes
requirement 2 correct: a stale, non-dim, non-reverse `❯ some old message`
line higher up in scrollback no longer gets mistaken for a live, glyph-less
composer (bash-mode `!`, a pager, a crashed shell) lower down. Verified
live against a real Claude Code v2.1.281 pane (`tests/fixtures/pane-
bashmode-with-history.txt`, `pane-draft-multiline.txt`,
`pane-draft-wrapped.txt`, `pane-pasted-text.txt` are harvested captures,
not hand-crafted).

Two things the eng review caught and this fix addresses, worth knowing if
touching this file again:
- With fewer than 2 border lines (the capture window cut one off), the
  fallback checks BOTH candidate sides for a glyph line and prefers
  whichever has one, rather than assuming the composer is always "after"
  the visible border — a real draft was lost otherwise when only the
  bottom border was in view (`pane-draft-wrapped-truncated-top.txt`).
- With ZERO border lines and ZERO glyph lines (a bare test string, or any
  capture with no structural evidence either way), the detector returns
  "no draft" (exit 1), matching the pre-086 contract, not "no composer
  found" (exit 2) — several pre-existing autoheal tests rely on a plain,
  border-less "confirmed empty" fixture reading as safe-to-heal, and a
  genuine "no composer found" needs at least a border line as evidence a
  composer box was ever there to look inside.
- `lib/ansi_escape.pl`/`lib/strip_ansi.pl`'s shared-regex `do(...)` call
  dies loudly (not silently) if the file can't be loaded — the earlier
  attempt let `$ANSI_ESCAPE_RE` come back `undef`, which turned into an
  infinite loop in `pane_draft.pl`'s SGR walk and a silent pass-through
  (unstripped escapes) in `strip_ansi.pl`.
