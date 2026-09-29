---
id: 084
title: Fix remaining prune-classifier fail-open bugs and provisional-close corner cases (081 re-review)
status: done
blocked-by: []
priority: 84
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

Split from plan 075. These are the findings from the 2026-09-28 eng review
of plan 081 (prune pipefail fix + provisional-close fix) that plan 081
itself didn't fix. Most of these sit on the destructive-prune classifier
or the provisional-close path, so they get top priority among the 075
split-outs.

## Requirements

- [x] `cctrl` `_task_record_close_provisional_file` (~2755-2803), wired into
      `_task_record_transition_file`: the provisional special case drops
      the caller's digest guard (`${10}`) and source/owner arguments that
      the generic path honors. Nothing reaches this today
      (`lib/conflict_resolve.py:228` only reads `task-*.json`), but it
      should refuse when a digest is passed rather than silently ignoring
      it.
- [x] `cctrl` `_session_task_records_for_name`'s `launch-*.json` close path
      (~12432-12434) has no startup grace — the launch receipt is written
      before `tmux new-session` runs, so a `mark-closed` landing in that
      window could close a session's record while it's still starting up.
      Give it the same 300s grace the snapshot/restore layer already uses
      (`PROVISIONAL_STALE_GRACE_SECONDS`).
- [x] `cctrl:13389-13396` (`_session_never_prompted`): a transcript read
      error leaves the captured variable empty, and the Codex branch
      treats `grep`'s exit 2 (real error) the same as "no match" — both
      fail toward "never-prompted" in a classifier that feeds a
      destructive prune. Treat a read/grep error as "not flagged" (fail
      open on the destructive side), not as a positive match.
- [x] `cctrl:13389`: loading the first 500 transcript lines into a shell
      variable can be several MB when transcripts carry base64 image
      content. Prefer a single bounded `awk` pass (`NR>500{exit 1}
      /pattern/{exit 0}`) that avoids both the pipe-under-pipefail hazard
      and the large in-memory buffer.
- [x] Pipefail audit follow-up (plan 081 missed two sites with the same
      SIGPIPE-under-`set -o pipefail` shape): `cctrl:8692` (`tmux
      list-panes | awk '{...; exit}'`) and `cctrl:13004` (`ps -ax | awk
      '...; exit}'` inside the restart background subshell, where errexit
      could skip the kill it's meant to guard).
- [x] `test_snapshot_excludes_stale_provisional_restore_candidates` (plan
      081) only compares a 0s-old row against a 1h-old one; add a
      near-boundary case (e.g. ~60s vs ~301s against the 300s grace) to
      actually pin the threshold. Also add coverage of the real-world
      anchored close path (`_session_close` → `_session_record_terminated`)
      for a provisional-only record — today only `mark-closed --apply` is
      tested directly.
- [x] `_task_record_find_by_session`'s fallback when the index file is
      missing: closing a provisional record rewrites the launch file, so
      it can become the newest record for a reused session name. Look at
      this alongside the digest-guard fix above. **Reviewed, no code
      change**: see Implementation Notes.

## Needs a decision (not a code change — do not implement without explicit sign-off)

Plan 081's prune cap (`max(K=5, ceil(25% × live sessions))`) is a flat 5
for any fleet of 20 or fewer live sessions, so `--yes` can still close up
to 5 sessions — potentially all of a small fleet — in one call with no
override. This is very likely the intended behavior (5 is a deliberately
small floor), but it's Matthew's call to make explicitly rather than an
implicit side effect of the K/N choice. Surface this to Matthew; do not
change the cap logic as part of this plan unless he says otherwise.

## Rules

Edit a copy of `cctrl` or `lib/*` and syntax-check it (`bash -n` / `perl
-c`), then `mv` it into place. The live tree runs every session's hooks.

Test with the existing fake-tmux/fake-hostname test harness
(`tests/run-tests.sh`) only — do not test any of this against live tmux
sessions, and do not run `prune --yes`/`--close` or `session
reconcile-names` for real.

## Implementation Notes

- **Digest guard**: `_task_record_close_provisional_file` gained a 4th
  positional `decided_digest`; when non-empty it compares against
  `_task_registry_record_digest "$file"` and refuses (75) on mismatch,
  mirroring the generic path's own check. `_task_record_transition_file`'s
  provisional-close branch now forwards its own `$decided_digest` through.
  Source/owner (`$7`/`$8`) were deliberately left hardcoded to
  `cctrl-terminate`/`unknown`/`unknown` — a provisional close always means
  "the launch never resolved and is being retired," which is exactly the
  shape `_task_record_close_provisional_file`'s design comment already
  documents (mirrors a canonical record's `cctrl-terminate` reconcile), so
  threading arbitrary caller-supplied owner/runtime through would let a
  caller assert an owner/runtime a provisional record can never actually
  have. New direct unit test:
  `test_task_record_close_provisional_honors_digest_guard`.
- **Startup grace**: `_session_task_records_for_name`'s Python now takes a
  5th arg (`now`, RFC3339 UTC) and, **only for the name-only `cctrl-tmux`
  selector** (mark-closed's own gate, and prune's unanchored fallback),
  excludes any `launch-*.json` entry whose `created_at` is within
  `PROVISIONAL_STALE_GRACE_SECONDS` (300s) of `now`, or whose
  `created_at`/`now` fails to parse (fail closed — excluded, not offered).
  This mirrors `lib/snapshot_restore.py`'s
  `PROVISIONAL_STALE_GRACE_SECONDS`/`provisional_is_stale` for the
  identical race, but inverted: snapshot capture fails an unparseable age
  *toward* stale (eligible for restore-candidate demotion), while this
  fails it *toward* not-offered (excluded from closeable) — the difference
  is deliberate, matching each function's own destructive-vs-informational
  direction.

  **First-pass eng review caught a real bug here (fixed, not just a
  suggestion):** the grace was originally applied unconditionally, ahead of
  the selector branch, so it also gated the pane-anchored selector that
  `_session_record_terminated` uses for `kill`/`close`/`stop-exact`. That
  path's provisional records carry an exact `pane_id`+`pane_pid` anchor
  cctrl captured itself before tearing the pane down — authoritative
  identity evidence with no "still starting up" ambiguity — so gating it
  on age meant a session the user explicitly closed within its first 5
  minutes stayed stuck at `lifecycle_state=provisional` (and so still
  looked like a live `tmux-resume` restore candidate to a snapshot taken
  in that window). Moved the age check inside the `selector == "cctrl-tmux"`
  branch only; the anchored branch is unaffected by record age, exactly as
  before this plan.

  Updated `test_session_mark_closed_provisional_launch_record` and
  `test_session_task_records_for_name_launch_liveness_gate` to backdate
  their "genuinely gone" (`cctrl-tmux` selector) fixtures past the grace
  window (they previously asserted immediate closeability of a 0s-old
  record, which the grace now correctly withholds for that selector), and
  added a fresh-and-gone case to each proving the grace itself. Added a new
  `test_session_record_terminated_closes_fresh_anchored_provisional`
  proving the anchored selector closes a fresh (0s-old), pane-anchored
  provisional record immediately, with no grace — this is the requirement-6
  anchored-close-path coverage the plan asked for, and it is also the
  regression test for the bug the first eng review pass caught.
- **`_session_never_prompted`**: both branches now inspect the exact exit
  code instead of a boolean `&&`/piped grep. Claude branch: a single `awk`
  pass over the file (no pipe, no shell variable) returns 0 (user turn
  found, within 500 lines) / 1 (scanned to EOF or line 500, no match) / 2+
  (macOS awk's "can't open file" or other read failure) — only 1 means
  never-prompted; anything else, including a read error, does not. Codex
  branch: same three-way `grep` exit-code split (0/1/2+), no `awk`
  rewrite needed since it already read the file directly with no pipe or
  shell-variable buffering.
- **Pipefail audit**: both flagged sites (`_session_attest`'s
  `tmux list-panes | awk '...; exit}'` pane-anchor check, and `cctrl
  restart`'s backgrounded `ps -ax | awk '...; exit}'` agent-pid lookup) now
  end their assignment with `|| true`, the same fix `_session_agent_cmd`
  already established for this exact SIGPIPE-under-`awk`'s-early-`exit`
  shape (plan 081, P1a).
- **Boundary test**: added 60s (inside grace) and 310s (past grace) rows to
  `test_snapshot_excludes_stale_provisional_restore_candidates` alongside
  the original 0s/1h pair, and a matching real-`mark-closed`-path regression
  (`s-starting-prov` in `test_session_mark_closed_provisional_launch_record`)
  proving `mark-closed --apply` — not just direct construction — withholds
  a fresh provisional record. The anchored-close path (the other half of
  requirement 6) is covered by
  `test_session_record_terminated_closes_fresh_anchored_provisional`, added
  above.
- **`_task_record_find_by_session`'s index-missing fallback (item 7,
  reviewed, no code change)**: traced the full lifecycle. A provisional
  close (`_task_record_close_provisional_file`) rewrites the *same*
  `launch-<id>.json` path in place — it never creates a new file or
  changes which path the per-name index (`_session_record_index_update`)
  points at, so a present, valid index is unaffected by a close. The
  fallback loop (picking the mtime-newest matching file across
  `task-*.json`+`launch-*.json`) only runs when that index is absent or
  its referenced file fails validation — and `_session_write_metadata`
  writes the index immediately after every new record, while
  `_task_record_promote_legacy_locked` both repoints the index at the new
  canonical file *and* deletes the old provisional source (cctrl:~2610,
  ~2612) on promotion. So a stale-but-still-on-disk provisional record
  from a prior use of a reused tmux name can only mtime-shadow a fresh
  one in the fallback path if the index file is itself missing/corrupt at
  exactly that moment — an operational-integrity edge case, not something
  either this plan's digest-guard fix or the startup-grace fix changes the
  likelihood of. No safe, narrowly-scoped fix presents itself without
  either duplicating the index's own job in the fallback (extra
  complexity for a path that's supposed to be a rare-case backstop) or
  guessing at intent Matthew hasn't confirmed; flagging as a follow-up
  worth a dedicated look rather than folding a speculative fix into this
  plan.

## Engineering review (2026-09-29)

Verdict: changes-requested, then approved after fix. First pass found one
required bug: the 300s startup grace was applied unconditionally in
`_session_task_records_for_name`, so it also silently blocked the
pane-anchored close path (`kill`/`close`/`stop-exact` via
`_session_record_terminated`) from closing a fresh provisional record,
even though that path has exact pane-anchor identity evidence and no
"still starting up" ambiguity to guard against — a session closed by the
user within 5 minutes of launch would stay stuck `provisional` and look
like a live restore candidate. Fixed by scoping the grace to the
`cctrl-tmux` (name-only) selector only; see the Implementation Notes above
and the new `test_session_record_terminated_closes_fresh_anchored_provisional`
regression test. Second pass confirmed the digest guard, `_session_never_
prompted` exit-code handling (verified against this machine's actual awk/
grep exit codes), both `|| true` pipefail fixes, test registration in both
list locations, the prune-cap non-change, and item 7's rationale all hold.

**Follow-ups filed, not blocking:**
- `_session_never_prompted`'s `[[ -e "$tpath" ]]`/`[[ -e "$rollout" ]]`
  existence checks accept a directory, which then makes both `awk` and
  `grep` exit 1 ("no match") — flagging a directory path as never-prompted.
  Tighten to `-f`.
- Have `_session_never_prompted` capture `awk`/`grep`'s exit code via
  `rc=0; ... || rc=$?` explicitly rather than relying on the surrounding
  `&&`-context call site to keep `set -e` from firing, so it stays correct
  if ever called in a bare/unconditional context.
- `parse_rfc3339_utc`'s strict `%Y-%m-%dT%H:%M:%SZ` format would leave a
  `created_at` with fractional seconds or a non-`Z` UTC offset permanently
  excluded from the "genuinely gone" cctrl-tmux path (fail-closed by
  design, but no current writer produces that shape — worth a more lenient
  parser if one ever does).
- `lib/snapshot_restore.py` and `cctrl` now each define their own
  `PROVISIONAL_STALE_GRACE_SECONDS = 300`. Consider a single shared source
  for the constant.
- The digest-guard test only asserts `lifecycle_state`; comparing the
  whole-file digest before/after would be a stronger regression guard.

## Needs a decision — carried forward, not resolved by this plan

Per the plan's own instruction, the prune-cap question above (`--yes`
closing up to `max(5, ceil(25%))`, a flat 5 for any fleet of ≤20 live
sessions) was **not** touched. Surfacing again here for Matthew: is a flat
floor of 5 the intended behavior for a small fleet, or should the cap
scale down further for fleets well under 20?
