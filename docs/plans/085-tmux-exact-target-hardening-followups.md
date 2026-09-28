---
id: 085
title: tmux exact-target hardening follow-ups (080 re-review)
status: pending
blocked-by: []
priority: 85
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-28
tui-fixture: n/a
approved-by: matthew (C-15, via cctrl-fleet-manager)
---

## Plain-English Summary

Split from plan 075. Findings from the 2026-09-28 eng review of plan 080
(tmux exact-target matching) that plan 080 itself didn't fix. See memory
[[tmux-target-prefix-match]] for the underlying hazard this line of work
is closing off.

## Requirements

- [ ] Remote attach (`ssh -t "$ssh_target" "...tmux attach-session -t
      $sess_q"`, `cctrl` around 14716-14726): the target string runs
      inside a remote **zsh login shell**, where a bare `=NAME` triggers
      zsh's own `=command` filename expansion — `printf '%q'` quoting
      doesn't prevent this since the whole string is re-parsed by the
      remote shell. Escape the `=` (e.g. `\=`) in the remote command
      string, not just shell-quote it.
- [ ] `cctrl:10824`-ish: `pane_id` read from `baseline.json` isn't
      validated against `^%[0-9]+$` before use in `send-keys -t
      "$pane_id"`. An empty/malformed value would target the current pane
      instead of failing closed. Pre-existing, not introduced by plan 080,
      but worth closing now while the exact-target work is fresh.
- [ ] `test_session_kill_exact_target_no_prefix_match` (added by plan 080)
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
