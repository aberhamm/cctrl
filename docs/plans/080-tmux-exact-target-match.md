---
id: 080
title: tmux -t targets must use exact-match (=NAME), not prefix fallback
status: pending
blocked-by: []
priority: 80
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-09-27
tui-fixture: n/a
approved-by: matthew (C-14, via cctrl-fleet-manager) — PLAN ONLY, not implemented
---

## Plain-English Summary

tmux's `-t NAME` target resolution falls back to prefix matching when no
session named exactly `NAME` exists. Filed after the fleet manager hit it
directly: after `TMUX--ms--cctrl` was closed, `tmux has-session -t
TMUX--ms--cctrl` matched the still-live `TMUX--ms--cctrl--2` (a `--2`
suffixed session is exactly the kind of name cctrl creates routinely for
duplicate labels). See memory `tmux-target-prefix-match`.

The fix tmux itself provides: prefix the target with `=` for an exact,
non-prefix match (`-t "=$name"`, and `-t "=$name:"` for a pane/window
target that includes a session-name component). No behavior changes
otherwise.

**Concrete risk:** `cctrl session close X` run a second time after X is
already gone (e.g. a retry, a stale script, a race between two fleet
agents) can silently kill `X--2` instead of no-oping. `kill-session` at
`cctrl:11033`, `cctrl:12512`, and `cctrl:12788` are the sharpest edges —
each is one prefix-match away from killing the wrong live session.

## Investigation notes

`grep -n 'tmux[^|&]*-t "\$' cctrl lib/*.sh` finds 78 call sites (session
name and pane/window forms mixed together). Full list, `cctrl` unless
noted:

**`has-session` (session existence checks — a false positive here can
cascade into wrong branches elsewhere):**
2998, 3004 (`${base_name}--${n}` — this one's a `--N` name check, exact
match still correct to want here), 3797, 4220, 4282, 5612, 7447, 8608,
12004, 12290 (loop condition), 12412 (loop condition), 12499, 12556,
12720, 12911, `lib/health-check.sh:115`.

**`kill-session` (destructive — highest priority):**
11033, 12512, 12788, 12803.

**`attach-session`:**
3670, 11986, 11998, 12005, 12020, 12032.

**`send-keys` / `paste-buffer` (session-name targets; pane-id targets like
`-t "$pane_id"` are unaffected since pane ids aren't prefix-matched the
same way — verify per call before changing):**
5779, 5786, 8697, 8704, 10824, 10987, 10988, 10989, 10990,
`lib/health-check.sh:68`, `:72`.

**`capture-pane`:**
5701, 7450, 9560, 11881, `lib/health-check.sh:65`, `:120`, `:201`.

**`display-message` / `display` (read-only, lower risk but should still be
exact — a stale metadata read is a correctness bug, not just a safety
one):**
9556, 9686, 10741, 10812, 10828, 11101, 11877, 12143, 13431.

**`list-panes`:**
8341, 8445, 8613, 9685, 9876, 9877, 12205, 12306, 12535, 13070.

**`set-option` / `show-option`:**
3558, 3559, 9727, 9734, 12596, 12727, 12921, 12942, 12987, 13017.

**`if-shell`:**
12175.

Not all 78 are session-name targets — some (`send-keys -t "$pane_id"`,
`list-panes -t "$sess"` where `$sess` is already a resolved pane/session
id from an earlier exact lookup) may already be operating on values that
can't collide with prefix-matching the same way a bare session *name*
can. The eng review for the follow-up plan needs to classify each site
(session-name string vs. already-resolved id) before mechanically
appending `=` — a blanket sed would break window/pane target forms like
`"$name:0.0"` (those need `=$name:0.0`, not `=$name:0.0` misapplied to an
id).

## Requirements (for the plan that implements this — not this plan)

- [ ] Every `tmux ... -t "$X"` call where `$X` is a session *name* (not a
      pane id, not a `session_id` like `$5`) uses `-t "=$X"`.
- [ ] Every call where `$X` includes a window/pane suffix
      (`"$name:$window"`) uses `-t "=$name:$window"`.
- [ ] A single shared helper (or documented convention) so future call
      sites don't reintroduce the bare form — e.g. a lint/test that greps
      for `tmux .* -t "\$[a-zA-Z_]` without a preceding `=` and fails.
- [ ] Regression test: two sessions named `X` and `X--2`; close/kill `X`;
      assert `X--2` is untouched and still attachable.
- [ ] **Do not test this against live tmux sessions** — use the existing
      fake-tmux test harness (`tests/run-tests.sh` already stubs
      `tmux`/`hostname` for isolation).

## Out of scope for this filing

Implementation. This plan is filed per the fleet manager's explicit
instruction to plan only and not touch live tmux targeting in the same
change as the install-copy work (plan 079).
