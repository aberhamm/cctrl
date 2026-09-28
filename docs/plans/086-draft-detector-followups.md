---
id: 086
title: Draft detector follow-ups (073 re-review)
status: pending
blocked-by: []
priority: 86
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-28
tui-fixture: n/a
approved-by: matthew (C-15, via cctrl-fleet-manager)
---

## Plain-English Summary

Split from plan 075. P3 findings from the 2026-09-27 eng review of plan
073 (draft detector), plus one item from the follow-up re-review, that
weren't fixed when the P2 fixes shipped.

## Requirements

- [ ] Wrapped and multi-line drafts. Judge every composer line up to the
      bottom border or hint line, so a draft whose first composer line is
      empty is still found. Keep a draft that consists only of `>` or `|`
      as well.
- [ ] Separate exit code for "no composer found": a bash-mode `!` prompt,
      a pager, or a shell left after a crash. Autoheal treats it as
      unverifiable; rich state keeps the base state.
- [ ] Check against a live capture whether Claude draws the `[Pasted text
      …]` placeholder dim. If it does, treat it as a draft.
- [ ] One shared escape regex for `lib/pane_draft.pl` and `_strip_sgr`.
- [ ] A typed draft that *starts* with placeholder text (`❯ Try "foo…"`,
      `❯ esc to cancel…`) still reads as empty. Apply the hint check only
      to composer lines with no SGR at all.

## Rules

Edit a copy of `cctrl` or `lib/*` and syntax-check it (`bash -n` / `perl
-c`), then `mv` it into place. The live tree runs every session's hooks.
