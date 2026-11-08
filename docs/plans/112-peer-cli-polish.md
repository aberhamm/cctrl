---
id: 112
title: Peer CLI polish (ls escape, consistent --as, housekeeping)
status: in-progress
status-note: "2026-11-08 tasks 1-2 built on feat/peer-cli-polish (on top of plan 111 phases 1-2), not pushed or installed; task 3 is an orchestrator action: fix/mailbox-delivery is already absent locally and on the remote, nothing to delete"
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

## Implementation notes (2026-11-08, rebased onto plan 111 phases 1-2)

- Task 1: the status colour reached a `%-8s` slot (a single-quoted
  `'\033[...'` string is only interpreted by `%b`); the `shadows=` suffix had
  the same bug. Also fixed while testing: `@tsv` + `IFS=$'\t' read` merged an
  empty SESSION field into the next column (a tab is IFS whitespace), so rows
  for peers without a session shifted left; rows now split on the unit
  separator. Capabilities and purpose are separated by a space.
- Task 2: `--as` added to `show`, `ls` and `deliver` (send, reply, recv,
  check, ack, inbox, outbox and overview already had it); `--from` added to
  `reply` as an alias; `send` keeps its own `--from` path (it accepts `user`
  and skips the app-thread check, so it is not folded into `--as`). Both with
  different values: exit 64, nothing written. `show --as` scopes to mail NAME
  sent or received; `ls --as` validates and echoes NAME; `deliver --as NAME`
  stands in for the target (different target or `--all`: 64).
- Plan 111 kept as is: attest, seal and warn-mode verification are untouched;
  `show --as` runs the same read-time `verification` annotation. `peer say`
  still refuses `--as`/`--from` (direct chat has no sender identity). Other
  subcommands with no identity (register, alias, doctor, gc, ...) take no `--as`.

