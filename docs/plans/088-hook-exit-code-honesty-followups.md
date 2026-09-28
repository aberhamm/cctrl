---
id: 088
title: Hook exit-2 honesty follow-ups (083 re-review)
status: pending
blocked-by: []
priority: 88
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-28
tui-fixture: n/a
approved-by: matthew (C-15, via cctrl-fleet-manager)
---

## Plain-English Summary

Split from plan 075. Findings from the 2026-09-28 eng review of plan 083
(honest git-commit warning + hook exit-2 passthrough) that plan 083 itself
didn't fix. Wording cleanup plus a test pinning the known accidental-
exit-2-looks-like-a-block risk documented in memory
[[cctrl-checked-install-design]].

## Requirements

- [ ] `hooks/block-git-commit.py:3`: the module docstring still says
      "blocks Bash commands that would create git commits" — update it to
      match the honest-advisory wording plan 083 gave the actual stderr
      message.
- [ ] `cctrl:14067` (`hooks run` help text): `"pre-tool-use   Block
      disallowed tool calls (stdin passthrough)"` overclaims the same way
      the old `block-git-commit.py` message did — no hook wired through
      `hooks run` today deliberately exits 2, so nothing is actually
      blocked yet. Update the wording, or revisit once a hook is exiting 2
      on purpose.
- [ ] Add a test pinning the known, currently-undertested accidental-exit-2
      risk plan 083's review surfaced: a release whose target hook script
      is missing (e.g. `hooks/block-git-commit.py` absent) makes `cctrl`'s
      `exec python3 "..."` itself exit 2, which the launcher now passes
      through as if it were a deliberate block. Record this behavior in a
      test rather than only in `docs/plans/079-checked-copy-install-fail-
      open-hooks.md`'s prose, or reconsider having plan 038's hook dispatch
      signal "deliberate block" some way other than the bare process exit
      code (e.g. a distinguishing marker) so an accidental 2 can't be
      confused with an intentional one.

## Rules

Edit a copy of `cctrl` or `lib/*`/`hooks/*` and syntax-check it (`bash -n`
/ `perl -c` / `python3 -m py_compile`), then `mv` it into place. The live
tree runs every session's hooks.
