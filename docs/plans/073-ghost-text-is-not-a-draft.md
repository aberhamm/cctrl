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
