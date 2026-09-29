---
id: 085
title: tmux exact-target hardening follow-ups (080 re-review)
status: done
blocked-by: []
priority: 85
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-28
completed: 2026-09-29
tui-fixture: n/a
approved-by: matthew (C-15, via cctrl-fleet-manager)
reviews:
  - type=eng verdict=approved date=2026-09-29 by=opus-level-subagent
---

## Plain-English Summary

Split from plan 075. Findings from the 2026-09-28 eng review of plan 080
(tmux exact-target matching) that plan 080 itself didn't fix. See memory
[[tmux-target-prefix-match]] for the underlying hazard this line of work
is closing off.

## Requirements

- [x] Remote attach (`ssh -t "$ssh_target" "...tmux attach-session -t
      $sess_q"`, `cctrl` around 14716-14726): the target string runs
      inside a remote **zsh login shell**, where a bare `=NAME` triggers
      zsh's own `=command` filename expansion — `printf '%q'` quoting
      doesn't prevent this since the whole string is re-parsed by the
      remote shell. Escape the `=` (e.g. `\=`) in the remote command
      string, not just shell-quote it.
- [x] `cctrl:10824`-ish: `pane_id` read from `baseline.json` isn't
      validated against `^%[0-9]+$` before use in `send-keys -t
      "$pane_id"`. An empty/malformed value would target the current pane
      instead of failing closed. Pre-existing, not introduced by plan 080,
      but worth closing now while the exact-target work is fresh.
- [x] `test_session_kill_exact_target_no_prefix_match` (added by plan 080)
      only covers `session kill`. Extend the same prefix-match-collision
      coverage to `session close`, both the immediate path and the delayed
      path (grace > 0).

## Rules

Edit a copy of `cctrl` or `lib/*` and syntax-check it (`bash -n` / `perl
-c`), then `mv` it into place. The live tree runs every session's hooks.

Use exact tmux targets (`-t '=NAME'` / `'=NAME:'`) in any test fixtures or
harness code this plan touches. Test with the existing fake-tmux/
fake-hostname test harness only — never exercise close/kill against live
fleet sessions.

## Implementation Notes

- **Remote attach**: `_remote_exec`'s detach-and-attach branch now builds
  the second `ssh -t` command with a literal backslash before the `=`
  (`tmux attach-session -t \\=$sess_q`) rather than relying on `printf
  '%q'`, which quotes for the local bash re-parse, not the remote zsh
  login shell that actually re-parses this string. Left a comment at the
  call site noting `test_tmux_exact_target_lint`'s static regex can't
  anchor on this line (the target isn't a literal `-t "$VAR"` clause —
  it's embedded, unquoted, inside a larger double-quoted command string),
  so it needed its own behavioral test:
  `test_remote_detach_attach_escapes_exact_target`. That test drives
  `_remote_exec`'s actual attach call (not just the launch call, which is
  as far as the existing `test_remote_shortcut_injects_purpose` reaches)
  by making a custom fake `ssh` emit the `CCTRL_SESSION=` marker the real
  remote `cctrl` would print, then asserts the logged attach command
  carries the backslash-escaped target.
- **pane_id guard**: added as a new `if` ahead of the existing `elif !
  tmux send-keys ...` in the codex-handoff release-to-app function,
  sharing the same `_codex_handoff_result`/`return 75` error path as its
  sibling checks (`exit-request-failed`, `owner-process-mismatch`,
  `owner-exit-timeout`), with `owner_exit` left `false`. New regression
  test in `test_codex_handoff_state_machine`: attest only verifies
  `pane_id` by plain string equality against whatever tmux reports, not
  by format, so a malformed-but-tmux-echoed value would sail through
  attestation untouched — the test proves this by making the (parameterized)
  fake tmux's `list-panes` echo back the same malformed `pane_id` the
  record carries, confirming the new `^%[0-9]+$` format check, not attest,
  is what actually stops it.
- **Close prefix-match test**: `test_session_close_exact_target_no_prefix_match`
  mirrors plan 080's kill test for both `session close --now` (immediate)
  and `session close --in N` (delayed). The delayed path's scheduled
  `kill-session` is embedded in a `run-shell -b` string constructed at
  runtime, not a literal `-t "$VAR"` clause, so it's also outside the
  static lint's reach; the test asserts the logged run-shell command
  still carries the exact `=NAME` target.

## Engineering review (2026-09-29)

Verdict: approved. Confirmed by direct simulation (feeding varied session
names, including ones with shell-special characters, through the actual
local-bash-then-remote-zsh quoting composition against a fake tmux) that
the backslash-escape survives correctly and that an unescaped `-t =NAME`
genuinely triggers zsh's equals-expansion under `zsh -c`. Traced the
pane_id guard's placement and error-path parity with sibling checks, and
verified empirically (by simulating the attest+reconcile call chain) that
attest's plain-equality pane_id check would not, on its own, have caught
the malformed value used in the regression test — confirming the new
format check is load-bearing, not redundant. Traced the close test against
the real `cmd_session_close`/`run-shell` implementation and confirmed the
delayed-path assertion is a real, non-vacuous check of `printf '%q'`'s
actual escaping behavior for that command string.

One gap flagged, not blocking: the review's own sanity check on
`test_tmux_exact_target_lint` found the remote-attach line produces zero
matches from that lint's regex — not because it's a recognized exact-id
exception, but because the regex can't anchor on an unquoted, embedded
target at all. There was no behavioral test for the remote-attach line at
review time. Closed before commit: added
`test_remote_detach_attach_escapes_exact_target` (see Implementation
Notes) plus a one-line comment at the call site pointing future readers
at that test instead of the lint.
