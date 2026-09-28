---
id: 081
title: prune pipefail false-positive, unbounded --yes, and provisional rows that never close
status: done
completed: 2026-09-28
blocked-by: []
priority: 81
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-09-28
tui-fixture: n/a
approved-by: matthew (P1, via cctrl-fleet-manager); implementation approved matthew (C-15, via cctrl-fleet-manager)
reviews:
  - type=eng verdict=approved date=2026-09-28 by=opus-subagent
---

## Plain-English Summary

Filed from a read-only root-cause investigation (not this session's work)
after fm-cctrl issued a safety stop (`prunestop-fm0927`) on `cctrl session
prune --yes`: a dry run proposed 27-29 live sessions, including active
fleet managers and long-running workers. Three separable bugs, all in
`cctrl`'s session-lifecycle machinery:

1. **P1a — false "never-prompted" positives under `pipefail`.** A
   `head | grep -q` pipeline's exit code is swallowed by `set -e
   -o pipefail` in a way that flags almost every long-running session as
   a candidate, regardless of whether it's actually idle.
2. **P1b — `prune --yes`/`--close` has no cap.** Once a session is
   (mis)classified as a candidate, nothing stops the whole batch from
   being closed in one call.
3. **P2 — provisional session records never close.** A lookup that
   drives `mark-closed`, `_session_close`, and `prune` only looks at one
   of the two record-file naming schemes, so sessions that never
   progressed past "provisional" are permanently unclosable through the
   normal path.
4. **P2 impact — stuck provisional rows are restore candidates.**
   Because of (3), closed/stale provisional rows still show up in the
   snapshot as `tmux-resume` restore candidates. A reboot-time restore
   could resurrect sessions that are supposed to be gone.

This plan is **investigation + fix design only**. Per the fleet manager's
explicit instruction, nothing here is implemented, and nothing is tested
against live tmux sessions or the live prune path in this pass.

## Investigation notes (from the RCA)

**P1a — `_session_never_prompted` (`cctrl:13250-13276`).** The Claude
branch, `cctrl:13264`:
```
head -n 500 "$tpath" | grep -qE '"(type|role)":"user"' && return 1
```
Under `set -euo pipefail` (`cctrl:2`), `grep -q` exits as soon as it sees
its first match — often well before `head` has written all 500 lines —
which sends `head` a `SIGPIPE` and gives it exit 141. `pipefail` makes
the *pipeline's* exit status the rightmost non-zero code in that race, so
this reliably (reproduced 5/5 against `obsidian--7`, `content-creation--2`,
`fm-homelab--2`) reports as if the `grep` itself failed to match, and the
function falls through past the `&& return 1` to `return 0` —
"never prompted" — even though the transcript plainly contains a user
turn. Any transcript over roughly 500 lines with an early user message
trips this. The Codex branch (`cctrl:13269`) greps the file directly with
no pipe and is unaffected — this is specific to the piped `head | grep`
construction.

**P1b — `prune --yes`/`--close` (`cctrl:13489-13494`).** Calls
`_session_close` on every candidate returned by the (buggy) classifier
above, with no confirmation prompt and no upper bound on how many
sessions get closed in one invocation. Given P1a's false-positive rate,
the dry run that triggered the safety stop proposed 24-29 of the fleet's
live sessions in one batch.

**P2 — `_session_task_records_for_name` (`cctrl:12309-12345`).** Globs
only `task-*.json` (`cctrl:12327`), never `launch-*.json`. Every consumer
of this lookup — `session mark-closed` (`cctrl:12419-12483`: scoped,
dry-run by default, requires `--apply`, refuses a name that's still
live), `_session_close` → `_session_record_terminated`, and `prune`
itself — inherits the gap, so a session whose record never progressed
past the provisional `launch-*.json` stage can't be marked closed through
any of the normal paths. Confirmed stuck: `TMUX--ms--content-creation`
and `TMUX--ms--tiktok-remotion` (provisional since 2026-09-24/25,
`launch-*.json` only, no matching `task-*.json`), plus four orphaned
`launch-*.json` files for `TMUX--ms--cctrl` whose canonical record is
already closed (harmless on their own, but same root cause).

**P2 impact — restore candidates (verified by fm-cctrl).**
`data/snapshots/latest.json` lists both stuck rows (`content-creation`,
`tiktok-remotion`) with `lifecycle: provisional`, `live: false`,
`restore_strategy: tmux-resume`, inside a snapshot whose
`restore_candidate_count` is 38. Because these rows never transition to
`closed` (root cause: P2), a restore run after a reboot has no signal
telling it these are dead and could re-launch sessions that were meant to
stay gone.

## Requirements (for the plan that implements this — not this plan)

**P1a:**
- [ ] Capture `head`'s output before grepping it (e.g. `hl="$(head -n 500
      "$tpath" 2>/dev/null)"; grep -qE '"(type|role)":"user"' <<<"$hl"`)
      so `pipefail` can't turn "grep matched early" into "pipeline
      failed."
- [ ] Audit every other `| grep -q` (and `| grep -c`, `| head`, `| tail`)
      pipeline in `cctrl`/`lib/*.sh` for the same SIGPIPE-under-`pipefail`
      shape — this bug class isn't unique to `_session_never_prompted`.
- [ ] Test: a transcript file over 500 lines with a user turn in the
      first few lines is **not** flagged never-prompted (this is exactly
      the shape that was silently wrong today, and the existing test
      suite didn't catch it).

**P1b:**
- [ ] `prune --yes` (and `--close`) refuses to act when the candidate
      count exceeds `max(K, N% of live sessions)` (concrete K/N to be
      chosen during implementation planning) unless a new explicit
      override flag is passed. `--force` already means something
      different ("include attached sessions") and must not be
      overloaded to also mean "skip the cap."
- [ ] Test: `--yes` with candidates above the cap refuses and explains
      why, without closing anything; with the override flag, it proceeds.

**P2:**
- [ ] `_session_task_records_for_name` also considers `launch-*.json`
      whose tmux session name matches exactly (see plan 080 — exact-match
      tmux targeting, not prefix, is the relevant convention here too)
      and whose tmux session no longer exists.
- [ ] `mark-closed --apply` on a name that only has a provisional
      `launch-*.json` record (no `task-*.json`) actually marks it closed.
- [ ] Test: a provisional-only record for a name whose tmux session is
      gone closes via `mark-closed --apply`; a provisional-only record
      for a name whose tmux session is still live is refused, same as
      today's live-name protection.

**P2 impact (restore candidates):**
- [ ] Once P2's close path works, verify closed/stale provisional rows
      are excluded from `restore_strategy: tmux-resume` candidates in a
      fresh snapshot — i.e. the fix must be checked at the snapshot/restore
      layer, not just at the close layer, since the RCA shows these rows
      currently survive into `latest.json` as restore candidates *because*
      they never transition to closed.
- [ ] Test: build a snapshot containing a stale/closed provisional row
      and assert it does not appear in the restore-candidate list; a
      companion test with a genuinely live provisional row confirms it
      still does appear (i.e. the fix filters on staleness/closed state,
      not on "provisional" itself, which is a normal transient lifecycle
      stage for a session that's still starting up).
- [ ] Use the existing fake-tmux/fake-hostname test harness
      (`tests/run-tests.sh`) for all of the above — **do not** test any
      of this against live tmux sessions or run `prune --yes`/`--close`
      for real during this investigation or its eventual implementation
      review.

## Out of scope for this filing

Implementation. This plan is filed per the fleet manager's explicit
instruction to plan only, based on a read-only root-cause investigation
already done in another session — no code changes, no live prune runs,
no `cctrl session reconcile-names`, no tmux session closes/restarts in
the course of writing this plan.
