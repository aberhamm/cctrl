---
id: 088
title: Hook exit-2 honesty follow-ups (083 re-review)
status: done
completed: 2026-09-29
blocked-by: []
priority: 88
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-28
tui-fixture: n/a
approved-by: matthew (C-15, via cctrl-fleet-manager)
reviews:
  - type=eng verdict=approved date=2026-09-29 by=opus-level-subagent
---

## Plain-English Summary

Split from plan 075. Findings from the 2026-09-28 eng review of plan 083
(honest git-commit warning + hook exit-2 passthrough) that plan 083 itself
didn't fix. Wording cleanup plus a test pinning the known accidental-
exit-2-looks-like-a-block risk documented in memory
[[cctrl-checked-install-design]].

## Requirements

- [x] `hooks/block-git-commit.py:3`: the module docstring still says
      "blocks Bash commands that would create git commits" — update it to
      match the honest-advisory wording plan 083 gave the actual stderr
      message. Done: docstring now says "advisory-only warning ... Does not
      block -- the command always still runs."
- [x] `cctrl:14480` (`hooks run` help text): `"pre-tool-use   Block
      disallowed tool calls (stdin passthrough)"` overclaims the same way
      the old `block-git-commit.py` message did — no hook wired through
      `hooks run` today deliberately exits 2, so nothing is actually
      blocked yet. Update the wording, or revisit once a hook is exiting 2
      on purpose. Done: now reads "Advisory checks on tool calls (stdin
      passthrough; none block yet)".
- [x] Add a test pinning the known, currently-undertested accidental-exit-2
      risk plan 083's review surfaced: a release whose target hook script
      is missing (e.g. `hooks/block-git-commit.py` absent) makes `cctrl`'s
      `exec python3 "..."` itself exit 2, which the launcher now passes
      through as if it were a deliberate block. Record this behavior in a
      test rather than only in `docs/plans/079-checked-copy-install-fail-
      open-hooks.md`'s prose, or reconsider having plan 038's hook dispatch
      signal "deliberate block" some way other than the bare process exit
      code (e.g. a distinguishing marker) so an accidental 2 can't be
      confused with an intentional one. Done:
      `test_cctrl_hooks_run_exits_2_when_target_hook_script_missing` in
      `tests/run-tests.sh` copies the real `cctrl` binary into a scratch
      release with no `hooks/` dir, confirms the direct invocation exits 2
      via python3's own file-not-found code, and confirms the launcher
      passes that 2 through unchanged. Didn't add a distinguishing marker
      (out of scope for this plan) — still an open design question for
      whoever wires up a hook that deliberately exits 2.

## Rules

Edit a copy of `cctrl` or `lib/*`/`hooks/*` and syntax-check it (`bash -n`
/ `perl -c` / `python3 -m py_compile`), then `mv` it into place. The live
tree runs every session's hooks.

## Eng review

Opus-level subagent review, 2026-09-29: verdict "changes requested". One
REQUIRED finding, fixed: `README.md`'s "block-git-commit.py — commit
guardrail" section still said the hook "blocks Claude from creating git
commits without explicit user approval" — the same overclaim this plan was
about, just in the most visible doc rather than code. Fixed: heading
renamed "commit warning", body now says it warns and does not block (exits
1, not 2). The docstring and `cctrl` help-text wording were both confirmed
accurate as written, and the new test was confirmed sound (correct
`SCRIPT_DIR`/exit-2 mechanics, doesn't touch the live install, matches
existing launcher-test conventions).

Two OPTIONAL follow-ups addressed as cheap wins: added
`assert_contains "$out" "block-git-commit.py"` to the new test so it proves
the exit 2 actually comes from the missing script (not an unrelated early
exit); marked plan 075's now-duplicate "From the 2026-09-28 eng review of
plan 083" section as done via this plan rather than leaving both open.

Not addressed (genuinely out of scope for this plan, left as open design
questions): a distinguishing marker so a future deliberate hook exit-2 can't
be confused with an accidental one (plan 088's own third requirement already
scoped this as "reconsider... or don't"); `README.md:1122`'s separate
mention of a "blocking hook" is about the unrelated Stop/peer hook and was
correctly left alone by the reviewer.
