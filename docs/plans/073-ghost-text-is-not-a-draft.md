---
id: 073
title: Dimmed prompt suggestions are not unsent drafts
status: done
completed: 2026-09-27
blocked-by: []
priority: 73
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-27
tui-fixture: required  # tests replay the exact escaped composer bytes Claude Code draws
approved-by: matthew (chat, 2026-09-27): queued after the plan 070 re-review fixes
reviews:
  - type=eng verdict=approved date=2026-09-27 by=mstack-review
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
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 2 | clean | Run 2: required items fixed; 2 new P3s, 0 critical gaps |

Re-review on 2026-09-27 of fix commit e1c2451 against the run-1 findings (commit c7c134e), scoped by the fleet manager's call scope-fm0927. These pass with `LANG=en_US.UTF-8`: `CCTRL_TEST_ONLY=pane-draft`, `session-stop-exact` and `health-check`, plus `python3 -m unittest discover -s tests -p 'test_*.py'` (97 tests). `perl -c lib/pane_draft.pl`, `bash -n cctrl` and `bash -n tests/run-tests.sh` are clean.

Required items:
- **[P2] Hint anchoring: fixed.** `lib/pane_draft.pl:16` anchors the placeholder to the start of the composer text (`^…[>❯]…(?:Try "|\? for shortcuts|esc to …)`), and `:53` applies it per line. Probed: `❯ check lib/ for the retry bug` gives 0 (draft), `│ ❯ Try "fix the parser" │` gives 1, and the fixtures `pane-empty-hint.txt` / `pane-ghost-suggestion.txt` still read as empty. The footer hints (`/ for commands`, `for newline`) are on non-glyph lines, so dropping them from the pattern is safe. Tests are at `tests/run-tests.sh:2335-2338`.
- **[P3] rc > 1 means unverifiable, and autoheal fails closed: fixed.** `cctrl:9499` sends perl's stderr to `/dev/null` and documents 0/1/other. `cctrl:11885-11895` maps rc ∉ {0,1} to `skipped / unverifiable-input`. Rich state (`cctrl:9565`) falls through to the base and transcript states on rc > 1, which is the intended "keep the base". Tests: `tests/run-tests.sh:2345-2347` (missing script gives rc > 1) and the broken-`perl` autoheal case in `test_session_autoheal_skips_glyph_draft` (no repair sent).
- **[P3] Colon SGR and OSC ended by ST: fixed in the detector.** `pane_draft.pl:24,28` accepts `[0-9;:]*` and keeps the first `:` sub-field. `:42` matches CSI with intermediates and OSC `…(?:\a|\e\\)`. Probed: `\e[2;4:3m` ghost gives 1, `\e[4:3m` and `\e[38:2::2:2:2m` typed text give 0, OSC 8 links (ST, BEL, unterminated) followed by an empty composer give 1. `_strip_sgr` (`cctrl:9502-9505`, dialog detector only) is unchanged. That is filed as 075's shared-escape-regex item.

`set -e` / `pipefail` audit of the new bash: `draft_rc=0; _session_pane_has_draft … || draft_rc=$?` and the `(( ))` tests inside `if`/`elif` cannot abort. The `printf | perl 2>/dev/null` pipeline is only called in `||` / `&&` / `if` context. No new abort path.

Deferred items are filed accurately in 075: multi-line drafts, exit code 3 for "no composer", the pasted-text placeholder, and one shared escape regex.

New findings (P3, not blocking; not yet in 075):
- **[P3] (7/10) `lib/pane_draft.pl:16,53`: a typed draft that starts with placeholder text is still read as empty.** Probed: `❯ Try "foo" as the new name`, `❯ ? for shortcuts, what does ctrl-r do` and `❯ esc to cancel the job please` all give 1. This predates the plan and is now much narrower (start of text only). Both production callers now pass an escaped capture, in which a real placeholder is dim and already excluded. **Fix:** apply `$hint` only when the line carries no SGR at all, i.e. a plain capture.
- **[P3] (9/10) `tests/run-tests.sh`: e1c2451 dropped the executable bit (100755 → 100644).** `./tests/run-tests.sh` now fails with "permission denied". Every documented invocation uses `bash tests/run-tests.sh`, so nothing breaks today. **Fix:** `git update-index --chmod=+x tests/run-tests.sh`.

VERDICT: ENG CLEARED. The P2 and the scoped P3s are verified with tests, with no regressions in the gate. The remaining P3s are in 075, and the two new ones above can join it.

NO UNRESOLVED DECISIONS
