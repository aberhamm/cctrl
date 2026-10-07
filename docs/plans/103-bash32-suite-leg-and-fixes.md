---
id: 103
title: Make the bash 3.2 suite leg real (cctrl under the harness bash) and fix the 3.2 breaks it exposes
status: in-progress
blocked-by: []
priority: 103
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-10-07
tui-fixture: n/a  # test harness + one launch-path helper
approved-by: Matthew ("Go with what you feel is right and is the best long-term decision.", 2026-10-07 via fm-cctrl; hygiene audit finding #1, orchestrator pick)
reviews:
  - type=eng verdict=approved date=2026-10-07 by=opus-subagent
---

## Plain-English Summary

cctrl must run under macOS `/bin/bash` 3.2 (the MacBook has only that) and
Homebrew bash 5. `/bin/bash tests/run-tests.sh` only ran the *harness* under
3.2: every `"$ROOT/cctrl"` call goes through `#!/usr/bin/env bash` and
`cctrl_source_eval` used `bash -c`, both of which resolved to Homebrew bash 5
on the Studio. So cctrl itself was not exercised under 3.2 since 2026-09-29,
and `_profile_settings_gc` (called on launch paths) had a bash-4-only
`local -A`.

## Changes

1. Suite: a `bash` symlink to the harness's own `$BASH` in
   `$TMPDIR/bash-shim`, first on the suite's PATH (suite-only; no shebang is
   edited, the installed cctrl still picks its interpreter as before).
   `cctrl_source_eval` uses `"$BASH"`. The suite prints the harness bash and
   the cctrl-under-test bash once at start.
2. Guard test `test_bash_leg_is_honest` (focused group `bash-leg`): fails if
   shebang lookup, `bash -c`, or `cctrl_source_eval` run a different bash than
   the harness, or the shim is not first.
3. `_profile_settings_gc`: newline-delimited membership instead of an
   associative array; behaviour unchanged. New test
   `test_profile_settings_gc_portable_membership`.
4. Run the full suite under `/bin/bash`, fix real 3.2 breaks (see Findings).
5. README requirements/testing note and CHANGELOG.

Review follow-up (applied): ten tests reset PATH to `/usr/bin:/bin`; they now
prefix `$TMPDIR/bash-shim` so the bash 5 leg also covers them.

## Findings

Static grep of `cctrl`, `lib/*.sh`, `hooks/*.sh` for `declare/local -A|-n`,
`${v,,}`/`${v^^}`, `mapfile`/`readarray`, `&>>`, `|&`, negative indices,
`printf %(..)T`, `wait -n`, `coproc`, `${v@X}`, `[[ -v`, `;;&`: only the
`_profile_settings_gc` site. The full suite under `/bin/bash` 3.2.57 with the honest leg (cctrl-under-test
reported as 3.2.57) passes: EXIT=0, no other runtime 3.2 break. The old
`_profile_settings_gc` fails there (`local: -A: invalid option`), confirming
the guard.

## Out of scope / follow-ups

Unguarded `"${arr[@]}"` under `set -u` are only fixed where the suite reaches
them as a 3.2 failure.
