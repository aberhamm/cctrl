---
id: 092
title: Plan 082 follow-ups — shared launch-code safety review + launch-to-app test teardown race
status: done
blocked-by: []
priority: 92
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-29
completed: 2026-09-29
tui-fixture: n/a
approved-by: matthew (C-15, via cctrl-fleet-manager)
reviews:
  - type=eng verdict=approved date=2026-09-29 by=opus-level-subagent
---

## Plain-English Summary

Plan 082 (`launch-to-app`) touched several functions that every `cctrl start
-d`/detached launch goes through, not just the new compound workflow: an
independent validation flagged these as "non-additive" and asked whether
they're safe for plain `cctrl start`, and whether they leak/accumulate
receipt files. Separately, `test_codex_launch_to_app_workflow`
(`tests/run-tests.sh` ~12512) intermittently leaves the top-level test
`$TMPDIR` non-empty at exit, making the full suite's `trap 'rm -rf
"$TMPDIR"' EXIT` fail with "Directory not empty" even when every assertion
passed (see the 078 handoff's flake evidence). This plan records the safety
review and fixes the teardown race.

## Part (a): safety review of plan 082's shared-code edits

Read against `git show 79d073e -- cctrl` (the mechanical cherry-pick that
landed plan 082 on main).

1. **`_launch_detached` now generates `CCTRL_PENDING_LAUNCH_ID` and exports
   it as `CCTRL_SESSION_LAUNCH_ID` for every detached launch** (when
   `resume_id` is empty), not just for `launch-to-app`.
   **Safe.** Purely additive: one more env var baked into the launched
   tmux session's shell command. Nothing reads it except the new
   promotion branch (item 4) and `launch-to-app`'s own fixtures.
2. **`_session_write_metadata`'s `launch_id` now defaults to
   `CCTRL_PENDING_LAUNCH_ID` (falling back to a fresh UUID only when
   unset).**
   **Safe, and necessary.** Before 082 the metadata record's
   `provisional_launch_id` and the (nonexistent) session-inherited token
   were generated independently and could never be compared. Now both
   `_launch_detached` (item 1) and `_session_write_metadata` compute the
   *same* value for the *same* launch, which is what makes item 4's
   binding check meaningful. Plain `cctrl start -d` behaves identically —
   same record shape, same field — just with a value threaded through
   instead of generated twice.
3. **The recovery-receipt validator (`_task_record_promote_legacy_locked`'s
   embedded `PYRECEIPT`) gained a second `evidence_kind` branch
   (`codex-lifecycle-hook-launch-binding`).**
   **Safe, mostly additive, with one minor, harmless loosening noted by
   eng review.** The original `live-native-codex-writable-root-rollout`
   branch's checks (numeric `pane_pid`/`wrapper_pid`, `%N`-shaped
   `pane_id`) are unchanged and still run under
   `if proof.get("evidence_kind") == "live-native-...":`. The new `else`
   branch requires its own independent fields (`lifecycle_event_id`,
   `provisional_launch_id` matching the record, and `tmux_session`
   matching the record's name) — it does not relax the original branch's
   *requirements*. It does, incidentally, relax the earlier per-field loop
   (now skipping `None` values instead of rejecting non-strings outright),
   which means the `live-native` branch now accepts `pane_started: null`
   where it previously rejected it; that branch never reads
   `pane_started` itself, so this has no observed effect, but the wording
   is corrected here rather than a stronger "not loosened" claim. Filed as
   a follow-up (not blocking): tighten the per-field loop to keep
   `pane_started` a required string for the `live-native` evidence kind.
4. **Task-registry promotion (~cctrl:7976-8031) now branches on
   `CCTRL_SESSION_LAUNCH_ID`.** Because of item 1, this env var is present
   for *every* codex tmux launch now, so this new branch fires for
   ordinary `cctrl start -d --agent codex` sessions too, not only
   `launch-to-app` ones — this is the crux of "non-additive."
   **Safe, and a net hardening, not a behavior change that breaks plain
   `start`.** The lifecycle-hook proof's receipt (`control_surface`,
   `tmux_session`, `pane_id`, `pane_pid`, `wrapper_pid`, `pane_started`) is
   built by reading those exact fields back out of the same provisional
   record it's validated against (cctrl:8007), so it isn't independent
   forensic evidence the way the root-rollout proof is — its only real
   job is binding the promotion to the launch token captured at spawn time
   (`CCTRL_SESSION_LAUNCH_ID`, matched against the record's
   `provisional_launch_id` at cctrl:7987-7990), so a delayed lifecycle
   hook from a reused tmux session name can't promote a stale/different
   generation's provisional record — exactly the anti-staleness property
   plan 082's design notes call out. Sessions launched by an older cctrl
   (no `CCTRL_SESSION_LAUNCH_ID` in their pane environment) fall through
   to the unchanged `_task_record_promote_legacy` 2-arg legacy path
   (cctrl:7993-8000). No regression path exists for plain `start`; the
   change gives every codex tmux launch's promotion the same identity
   binding launch-to-app relies on, rather than special-casing it.
5. **`_session_release_to_app_one` gained a fifth `expected_guard`
   parameter, defaulted to `""`.** **Safe.** Every existing call site omits
   the fifth argument, so `expected_guard` is empty and the new guard block
   (cctrl:10995-11002) is skipped entirely — identical behavior to before
   082 for every caller except `launch-to-app`'s own.

**Do receipts accumulate?** No, for either receipt mechanism plan 082
touches:
- `CCTRL_LAUNCH_RECEIPT_FILE` (cctrl:3662-3673) is only written when that
  env var is set, and only `lib/codex-launch-to-app.sh:150` sets it —
  scoped to a per-invocation `mktemp -d` scratch dir
  (`lib/codex-launch-to-app.sh:148`) that every exit path (success and
  every failure branch, lines 172-304) `rm -rf`s. Plain `cctrl start -d`
  never sets this var, so it never writes this file at all.
- The pre-existing `app-owned-launch-receipts` directory
  (`_task_app_owned_receipt_dir`, cctrl:1265-1281) is unrelated to plan
  082 — it predates it (the `--app-owned` path) and plan 082's diff does
  not touch it.

**Conclusion:** no code change required for part (a); this section is the
recorded decision. Independent validation's "non-additive" framing was
correct about *scope* (item 4 now applies beyond launch-to-app) but the
broadened scope is deliberate hardening with no observed regression path
for plain `cctrl start`.

## Part (b): fix the teardown race in `test_codex_launch_to_app_workflow`

**Root cause.** `tests/run-tests.sh:12519-12522` calls the real (unmocked)
`"$ROOT/cctrl" start -d --agent codex "$seam_project"` to exercise the real
detached-launch seam. That launch has no `--resume`, so `_launch_detached`
spawns its best-effort background conversation-id poll subshell
(cctrl:3698-3723): a `sleep 2`-interval loop for up to
`CCTRL_RESUME_POLL_TIMEOUT` (default 20s) that reads session metadata
under `$seam_meta`/touches `$seam_data` (e.g. `_cctrl_host_id`'s
`CCTRL_HOST_ID_FILE=$seam_data/host-id`). **The launch also uses
`--agent codex`, so `_launch_detached` additionally calls
`_session_codex_schedule_display_name_sync` (cctrl:3725-3730), which
starts a second, independently `disown`ed background subshell
(cctrl:13549) polling for up to `CCTRL_CODEX_TITLE_POLL_TIMEOUT` (default
30s) — longer-lived than the resume poll, and it goes through
`_session_metadata_field`/`_cctrl_host_id` too, so it can recreate
`$seam_data` just as easily.** Both subshells outlive the parent `cctrl`
invocation and nothing in the test waits for either. When the full
suite's total remaining runtime after this test is shorter than either
poll's timeout, that background process is still alive — and still
writing under `$TMPDIR/launch-to-app/seam-data/` — when the top-level
`trap 'rm -rf "$TMPDIR"' EXIT` (`tests/run-tests.sh:18`) fires, racing
`rm -rf`'s directory traversal against the poll's writes and producing
"Directory not empty" even though every real assertion already passed.
This is the same hazard `test_launch_stdout_closes_promptly`
(`tests/run-tests.sh:9355`) exists to catch for the resume poll, and the
same fix other real-launch tests already use for it
(`tests/run-tests.sh:9352,9394,9410,9427`: `CCTRL_RESUME_POLL_TIMEOUT=0`)
— but those are all `claude`-agent launches, so the title poll never
applied to them and no existing test demonstrates silencing it. This
call site is the first real `--agent codex` detached launch in the suite
and needs both timeouts zeroed, not just the resume one.
`lib/codex-launch-to-app.sh:147` already treats both pollers as hazards
to suppress (asserted by this same test's `never|0|0` `env_log` check),
so this fix brings the seam's own real launch in line with what the
workflow it's testing already requires of itself.

## Requirements

- [x] Record the part (a) safety decision above (this plan doc is the
      record; no code change).
- [x] Add `CCTRL_RESUME_POLL_TIMEOUT=0` to the real-launch env in
      `test_codex_launch_to_app_workflow` (`tests/run-tests.sh:12519`),
      matching the existing convention, so the background poll subshell
      exits immediately instead of surviving past the test.
- [x] Re-run the full suite enough times to gain confidence the
      "Directory not empty" teardown failure no longer reproduces (it was
      intermittent, so a single green run is not sufficient evidence).
      Ran twice back to back: 100 tests, OK, exit 0, both times.

## Files expected to change

- `tests/run-tests.sh`: one line in `test_codex_launch_to_app_workflow`'s
  real-launch invocation.
- `docs/plans/092-plan-082-shared-launch-follow-ups.md`: this plan doc
  (the part (a) record).

## Verification

- [cmd] `bash -n tests/run-tests.sh`
- [cmd] `LANG=en_US.UTF-8 bash tests/run-tests.sh` (run at least twice back
  to back to gain confidence against the intermittent teardown race)
- [assert] no "Directory not empty" trap failure; suite exits 0 with all
  "Ran N tests ... OK"

## Engineering review (2026-09-29)

Verdict: changes-requested, then approved after fix. The reviewer found the
teardown fix as originally written was incomplete: the test's real launch
uses `--agent codex`, which also triggers `_launch_detached`'s codex
display-name-sync background poll (`_session_codex_schedule_display_name_sync`,
default 30s timeout) in addition to the resume poll (default 20s) — both
`disown`ed, both capable of touching `$seam_data`. Fixed by also setting
`CCTRL_CODEX_TITLE_POLL_TIMEOUT=0` at the same call site
(`tests/run-tests.sh:12522`); root-cause section above updated accordingly.
The review also corrected part (a) item 3's wording (see above) and
confirmed items 1, 2, 4, and 5 and the "no accumulation" conclusion as
written.

**Follow-ups filed, not blocking this plan:**
- Tighten the recovery-receipt validator's per-field loop so
  `live-native-codex-writable-root-rollout` proofs still require
  `pane_started` to be a non-empty string (currently accepts `null`
  incidentally, with no observed effect since that branch never reads the
  field).
- ~15 other real `--agent codex` detached launches elsewhere in
  `tests/run-tests.sh` (e.g. ~1085-1372, ~1586-1670) set neither poller
  timeout; they run early enough that the pollers likely finish before the
  suite exits, but setting both timeouts across the suite would remove the
  whole class of flake rather than relying on run order.
- The new lifecycle-binding promotion path for plain codex `start -d`
  computes `launch_digest` outside the registry lock before passing it as
  `expected`; a pane-anchor write landing in that window makes
  `_task_record_promote_legacy_locked` return 75 (hook returns 74 for that
  event). Likely self-heals on the next lifecycle event since the
  provisional record survives, but it's a new, narrow failure mode worth
  a dedicated look.
- `_launch_detached` returns 74 with no stderr message if both `uuidgen`
  and `openssl` are unavailable (cctrl:3621); before plan 082 this
  condition only produced a metadata-write warning. Worth an explicit
  error message.
