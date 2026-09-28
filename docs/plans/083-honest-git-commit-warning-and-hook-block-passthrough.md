---
id: 083
title: honest block-git-commit.py warning + launcher passes hook exit 2 through
status: done
completed: 2026-09-28
blocked-by: []
priority: 83
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-09-28
tui-fixture: n/a
approved-by: matthew (C-17, via cctrl-fleet-manager)
reviews:
  - type=eng verdict=approved date=2026-09-28 by=opus-subagent
---

## Plain-English Summary

Two known issues flagged by plan 079's independent validation and
deliberately left unfixed pending Matthew's call (see memory
`cctrl-checked-install-design`), now approved for a fix:

1. `hooks/block-git-commit.py` prints `"Blocked: ..."` and exits 1 on a
   matched `git commit`/`revert`/`cherry-pick`/`am` command. Claude Code
   only treats a hook's exit **2** as an actual block; exit 1 is a
   non-blocking warning. So this hook has **never actually blocked** a
   commit — it has always been advisory, while its own message claims
   otherwise. This plan makes the message match the real behavior; it does
   **not** make the hook start blocking.
2. `install/cctrl-launcher.sh` (the tiny tracked launcher at
   `~/.local/bin/cctrl`, see plan 079) only passes exit 0 and 1 through
   unchanged from `hooks run`; any other code (including a deliberate
   future exit 2) is swallowed into "fail open" (exit 0). Nothing
   dispatched via `hooks run` today deliberately exits 2, so this is
   currently a no-op in practice, but it means a future hook that *does*
   want to actually block (by exiting 2, Claude Code's real block code)
   would be silently defanged by the launcher. This plan adds exit 2 to
   the explicit passthrough set, alongside 0 and 1, while every other
   unexpected code (126/127/signals, a missing or unrunnable release)
   still fails open exactly as today.

Filed and approved as C-17 via cctrl-fleet-manager, to run after plan 081
and before plan 077 in the fleet manager's execution order.

## Requirements

### `hooks/block-git-commit.py`
- [ ] Keep matching the same command patterns and keep exiting 0 (no
      match / parse error) or 1 (match) — do not change to exit 2 or
      otherwise start actually blocking. That is a separate, not-yet-made
      decision.
- [ ] Change the stderr message so it does not claim to have blocked
      anything (currently `"Blocked: automatic git commits are not
      allowed. Ask the user first."`). Make it an honest warning that
      states what actually happens: the command still runs, this is
      advisory only.
- [ ] Add tests: a matched command exits 1 with the new (non-"Blocked")
      wording; a non-matching command exits 0; invalid stdin JSON exits 0
      (existing fail-open behavior, unchanged).

### `install/cctrl-launcher.sh`
- [ ] Add exit 2 to the passthrough set alongside 0 and 1 (`case $rc in
      0|1|2) exit "$rc" ;; *) ... fail open ... ;; esac` or equivalent) so
      a hook that deliberately exits 2 (Claude Code's real block code) is
      never silently downgraded to "allow".
- [ ] Every other unexpected code — 126, 127, a signal-derived code
      (128+N), or any value that isn't 0/1/2 — still fails open (exit 0
      from the launcher) exactly as today. Do not widen the passthrough
      set beyond 0/1/2.
- [ ] A missing or unrunnable release (`current/cctrl` absent or not
      executable) still fails open exactly as today — unaffected by this
      change, but keep the existing test coverage green.
- [ ] New tests in the launcher sandbox group (`tests/run-tests.sh`,
      alongside `test_cctrl_launcher_hooks_run_*`, using the same
      `CCTRL_HOME="$TMPDIR/..."` scratch-directory pattern — never the real
      `~/.local/lib/cctrl`):
      - a fake release that `exit 2`s: launcher passes 2 through unchanged.
      - a fake release that `exit 42`s: launcher fails open (exit 0),
        same as today's "unexpected exit" case.
      - a missing release: launcher still fails open (exit 0) — regression
        check that this change didn't touch that path.

### Docs/memory updates
- [ ] `docs/plans/079-checked-copy-install-fail-open-hooks.md`:
      update its description of the launcher's exit-code handling to
      describe the new 0/1/2 passthrough, and note that issue #1 from its
      "two known issues" section (the exit-2 swallowing) is resolved by
      this plan.
- [ ] Memory `cctrl-checked-install-design`: update the "Two known
      issues" section — issue 1 (exit-2 passthrough) is now fixed by this
      plan; issue 2 (block-git-commit.py's message vs. its real exit code)
      is resolved by the honest-warning wording change above, though the
      hook still does not block (that remains a separate future decision
      if Matthew wants actual blocking, e.g. by having it exit 2).

## Out of scope

- Making `block-git-commit.py` actually block commits (exit 2). That is
  a distinct decision Matthew has not made; this plan only makes its
  current advisory behavior honest.
- Any other hook's exit-code semantics.
- Anything in plans 071, 075, 077, 078.

## Rules

Edit a copy of `cctrl`/`hooks/*`/`install/*` and syntax-check it (`bash
-n` / `python3 -c "import ast; ast.parse(...)"`), then `mv` it into
place — other live sessions on this machine may run the working-tree
files directly. Do not run the real installed launcher against the real
`~/.local/lib/cctrl`; test only against `CCTRL_HOME`-scoped scratch
directories, per the existing launcher test pattern.
