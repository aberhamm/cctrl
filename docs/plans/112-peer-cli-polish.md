---
id: 112
title: Peer CLI polish (ls escape, consistent --as, housekeeping)
status: draft
blocked-by: []
priority: 40
allows-migrations: false
review-required: none
created: 2026-10-28
approval: pending
reviews: []
related: 108
---

## Problem

Small defects found during plan 108 that were kept out of it.

## Tasks

1. `peer ls` prints a literal `\033[0;32mlive` (cctrl ~6347-6349): the colour escape
   is emitted through a path that does not interpret it. Fix with the same echo/printf
   form the rest of the file uses; add a test that no literal `\033` appears in output.
2. Make `--as` accepted on every peer subcommand. Keep `--from` as an alias on
   `send` and `reply` (existing scripts). Add `--as` to `peer show`, which has none.
   Passing both with different values is a usage error. Update help text and README.
3. **Housekeeping, needs approval (an action for the orchestrator, not code):** delete
   the local branch `fix/mailbox-delivery` (b6970ce, plan file only, superseded by 108)
   after 108's pgrep fix lands. Do not delete before then.

## Acceptance criteria

- `cctrl peer ls` output has no literal backslash-zero-three-three sequence, with and without a tty.
- `--as X` works on send, reply, show, recv, check, ack, ls, overview, deliver; `--from` still works on send and reply.
- The branch deletion is performed only on Matthew's explicit OK, and logged.

## Tests

Suite cases for the ls output and for `--as`/`--from` parsing on each subcommand. No stubbed system tool is involved; if one is introduced, pair it with a real-tool test.
