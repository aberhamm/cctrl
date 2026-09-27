---
id: 073
title: Dimmed prompt suggestions are not unsent drafts
status: in-progress
blocked-by: []
priority: 73
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-27
tui-fixture: required  # tests replay the exact escaped composer bytes Claude Code draws
approved-by: matthew (chat, 2026-09-27): queued after the plan 070 re-review fixes
reviews:
  - type=eng verdict=changes-requested date=2026-09-27 by=mstack-review
---

## Plain-English Summary

Claude Code draws a predicted next prompt as dimmed "ghost text" in an empty composer, for example `❯ \e[2myeah clean up the scaffolded project\e[0m`. `cctrl session ls` reports that as `unsent-draft`: about 12 sessions on 2026-09-27 whose input boxes were actually empty. Autoheal also treats it as a draft and skips those sessions.

## Cause

- `_session_pane_has_draft` (cctrl) reads a plain `capture-pane -p`, which drops the SGR attributes. With the attributes gone, ghost text looks exactly like typed text: `❯` (followed by U+00A0) and then non-space characters.
- Its hint filter only knows a few fixed placeholder phrases ("Try …", "for shortcuts").

## Requirements

- [x] The draft detector reads the pane with escapes (`capture-pane -e`). It counts composer text as a draft only if at least one non-space character is drawn outside dim (SGR 2). A reverse-video character is the cursor and is ignored.
- [x] U+00A0 after `❯` is treated as a space.
- [x] A real draft is still detected: typed text after the ghost text, or plain text with no dim at all.
- [x] Both callers use the escaped capture: rich state (`session ls` STATE) and the autoheal draft gate.
- [x] Tests use the exact byte sequence `❯ \e[2myeah clean up the scaffolded project\e[0m`, plus a real draft and a draft with a reverse-video cursor.

- [x] Only the last prompt line on screen, the composer, is judged. Found live on 2026-09-27: submitted messages in the transcript above (`❯ yes` on a grey background) made two sessions with empty composers read as drafts.

## Tasks

1. `_session_pane_has_draft` gains an escaped-capture mode that parses SGR state on the composer line. Callers capture with `-e`.
2. Tests in `tests/run-tests.sh` next to the existing draft detector tests.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | issues_open | 6 issues (1 P2, 5 P3), 0 critical gaps |
| Outside voice | Claude subagent | Independent 2nd opinion | 1 | issues_found | 1 new P3 folded in, 1 claim disproved |

Reviewed on 2026-09-27: plan 073 and commit c7c134e (`lib/pane_draft.pl`, `_session_pane_has_draft` / `_strip_sgr` at `cctrl:9484-9503`, callers at `cctrl:9555-9563` and `cctrl:11878-11884`). These pass with `LANG=en_US.UTF-8`: `CCTRL_TEST_ONLY=pane-draft`, `session-stop-exact`, `health-check` and `snapshot-ownership`, plus `python3 -m unittest discover -s tests -p 'test_*.py'` (97 tests).

Checked and correct. Each was run through `lib/pane_draft.pl`, and the tmux behaviour was checked against real tmux 3.7c on a private socket:
- SGR forms: `\e[22m`, `\e[2;38;5;246m`, `\e[m`, `\e[1;2m` then `\e[22m`, and the split form tmux emits (`\e[2m\e[38;5;246m`). The extended-colour skip keeps `38;5;2` and `38;2;2;2;2` from reading as dim.
- A composer inside a box border (`│ ❯ … │`): typed text counts, ghost text doesn't, an empty box doesn't. The reverse-video cursor is handled, and so is a `❯ yes` transcript line above an empty composer.
- SGR state across lines: tmux 3.7c closes each line with `\e[0m` and sets attributes again at the start of the next, so resetting per line (`pane_draft.pl:18`) is correct.
- Non-Claude panes: the draft detector only runs for a Claude idle base (rich state) or a Claude pane (autoheal), and Codex's `›` glyph never matches.

Findings:
- **[P2] (confidence 8/10) `lib/pane_draft.pl:14,50`: the hint filter drops real drafts.** Verified. `if ($visible =~ $hint) { $found = 0; next }` matches anywhere in the line. So a typed draft such as `❯ check lib/ for the retry bug` (it contains `/ for`), or one containing `for commands` or `Try "`, reads as no draft. Autoheal then runs `_session_repair_bridge`, which sends `C-u` (`cctrl:10986`) and erases the draft. This behaviour predates the plan (the old `grep -Eiv` did the same), but it breaks this plan's requirement that "plain text with no dim at all" is still a draft. Now that the capture has escapes, the fix is small. **Fix:** check the hint only at the start of the typed text, e.g. `$typed =~ /^[\s\x{00A0}]*(?:Try "|\? for shortcuts|esc to (?:interrupt|cancel))/`. The dim placeholders are already excluded by their attribute, and a placeholder in a plain capture is still caught. Add tests where `❯ check lib/ for the retry bug` and `❯ list the for commands flags` are drafts and `❯ Try "…"` (plain) is not.
- **[P3] (7/10) `cctrl:9497`: a perl failure reads as "no draft".** `printf '%s\n' "$capture" | perl "$SCRIPT_DIR/lib/pane_draft.pl"` exits 2 when the script is missing or fails to compile, and callers treat any non-zero as "empty composer". That fails open on autoheal's safety gate. Perl's warnings (for example on invalid UTF-8) also reach `session ls` stderr. **Fix:** capture rc. In autoheal, rc > 1 gives `skipped / unverifiable-input`. In rich state, rc > 1 keeps the base state. Send perl's stderr to `/dev/null`.
- **[P3] (9/10) `lib/pane_draft.pl:22,39` and `cctrl:9502`: two escape forms that real tmux 3.7c emits are not parsed.** Verified: tmux writes `\e[4:3m` (curly underline) and `\e[5:3m` (overline) with colons, and OSC 8 links end in ST (`\e]8;;url\e\\`), not BEL. `[0-9;]*` and `\][^\a]*\a` miss both, so `\e.` removes only two bytes and the rest (`4:3m`, the URL) becomes visible text. A ghost drawn as `\e[2;4:3m` reads as a draft (verified, exit 0). **Fix:** accept `[0-9;:]*` and use the first `:` sub-field of each `;` parameter. Match OSC as `\e\].*?(?:\a|\e\\)`. Keep one escape regex that `pane_draft.pl` and `_strip_sgr` both use (DRY).
- **[P3] (8/10) `lib/pane_draft.pl:49-52`: only the glyph line is judged.** Verified: a multi-line draft whose first composer line is empty (the text is on a continuation line) reads as no draft, and so does a draft that is only `>` or `|`. This predates the plan. **Fix:** after the last prompt line, also count non-dim text on the following lines up to the composer's bottom border (`─`), and stop removing a leading `>`/`|` from `$typed`, which never contains the glyph.
- **[P3] (5/10, medium confidence: check whether this is real) the pasted-text placeholder.** If Claude Code draws `[Pasted text #1 +N lines]` dim, a draft made only of pasted text would now read as empty. **Fix:** check against a live escaped capture, and if needed add it to the fixture as a draft.
- **[P3] (outside voice, 6/10) `lib/pane_draft.pl:54`: exit 1 has two meanings.** `exit($found ? 0 : 1)` returns 1 both for "empty composer seen" and for "no composer line at all". The second covers bash mode `!`, memory mode `#`, a shell prompt left by a crashed Claude, a pager, or the transcript view. Autoheal treats 1 as eligible and sends `C-u` and `/rc`. **Fix:** return a third code (e.g. 3) for "no composer in the last ~8 lines", which autoheal maps to `unverifiable-input`. Accept `!` and `#` as composer glyphs.
- Outside voice, disproved: it said SGR state carries across lines in `capture-pane -e`. On tmux 3.7c it does not (see above).

Performance: one `perl` per Claude session per `session ls`, plus one more for `_strip_sgr` when dialog detection is on. That is comparable to the two `grep`s it replaces, so no concern.

VERDICT: ENG NOT CLEARED: changes requested (1 P2). Required before approval: the P2 hint fix and its tests. The P3s can follow separately. eng review required

NO UNRESOLVED DECISIONS
