---
id: 091
title: Peer send sender-binding check fails open when the caller's own tmux session can't be resolved
status: done
completed: 2026-09-29
blocked-by: [077]
priority: 91
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-29
tui-fixture: n/a
approved-by: matthew (C-15, via cctrl-fleet-manager), 2026-09-29
reviews:
  - type=eng verdict=approved date=2026-09-29 by=opus-level-subagent
---

## Plain-English Summary

Plan 077 added a sender-binding guard so a tmux-hosted `cctrl peer send --as
NAME` can only send as its own live session, unless `--impersonate` is
passed. The guard is designed to fail open (allow the send) whenever there
is nothing to verify against — no `$TMUX`, no peer session metadata, etc —
because it's a misroute guard, not a general identity system, and must never
block legitimate fleet traffic it can't evaluate (see 077's own comment at
`cctrl:5237-5245` and the eng-review note at `cctrl:5248-5256`).

Independent validation of 077 found that "nothing to verify against" is
currently indistinguishable from "the caller *is* in a tmux session but its
identity couldn't be resolved" — and the guard silently fails open in the
second case too, which is not what it's supposed to do.

## The bug

`_peer_cmd_send` derives `caller_tmux_session` via:

```
caller_tmux_session="$(_session_current_name 2>/dev/null)" || true
```

(`cctrl:5246-5247`). `_session_current_name` (`cctrl:12870-12886`) fails
closed (returns 1, prints nothing) whenever it can't verify the caller's
identity — e.g. an inherited `CCTRL_SESSION_NAME` env var that doesn't match
the tmux session the process is actually running in
(`_session_process_in_session` check at `cctrl:12877`), or a stale `$TMUX`
in an agent subprocess.

That failure is swallowed by `|| true`, so `caller_tmux_session` ends up
empty — identical to the legitimate "not in tmux at all" case. Then
`_peer_sender_binding_mismatch` (`cctrl:5065-5075`) requires a non-empty
`caller_session` to do any comparison at all (`cctrl:5069`); an empty one
returns 0 (no mismatch), and the send goes through with whatever `--as`
value was given.

**Validator's reproduction:** in a sandbox with a stale/inherited
`CCTRL_SESSION_NAME` left over from session A, `cctrl peer send ... --as B`
from session A's shell succeeded — should have been refused as a
cross-session `--as` without `--impersonate`. After scrubbing the `CCTRL_*`
env vars so `_session_current_name` could resolve honestly, the same send
was correctly refused (`rc 66`, no mailbox line written), and
`audit.caller_tmux_session` (`cctrl:5320,5341`) was recorded as expected.

**Root cause, one level up:** the field cctrl already writes to the audit
record, `audit.caller_tmux_session`, is `null` in both the "not in tmux"
case and the "in tmux but unresolvable" case (`cctrl:5341`) — there's no
way to tell them apart after the fact either.

## Proposed fix

- In `_peer_cmd_send` (or `_peer_sender_binding_mismatch`), distinguish
  "no `$TMUX`" (legitimate non-tmux `user` path — keep failing open, no
  behavior change) from "`$TMUX` is set but `_session_current_name` could
  not resolve it" (an anomalous state the guard currently can't see).
- In the anomalous case, refuse the send (or at minimum warn loudly and
  record `audit.caller_unresolved=true` on the resulting message/receipt) 
  instead of silently treating it as "nothing to verify" — the design
  intent of 077 was to close exactly this kind of stale/reissued-identity
  gap, and an unresolvable caller session is the same shape of problem
  Matthew's original `msg_20260927_175609_8f2f78` incident was.
- Whichever behavior is chosen (hard refuse vs. warn-and-audit), keep the
  `--impersonate` override path untouched, and keep the true "not in tmux
  at all" (`user`/non-tmux) path exactly as it is today — this is not a
  reintroduction of the recipient-reissue refusal 077 explicitly
  descoped (see `docs/plans/075`'s design-question note); it is narrower,
  about the *caller's own* identity resolution, not the recipient's.
- Add a test that reproduces the validator's sandbox scenario: an
  inherited/stale `CCTRL_SESSION_NAME` that doesn't match the real `$TMUX`
  session, asserting the send is refused (or audited as unresolved) rather
  than silently passing through.
- Note for whoever implements: **sandbox tests that exercise this path
  must explicitly scrub `CCTRL_*` env vars before asserting on
  `_session_current_name`'s behavior.** The validator's own sandbox
  initially produced a false pass (`--as B` succeeding) purely because
  ambient `CCTRL_SESSION_NAME`/`CCTRL_SESSION_KIND` leaked in from the
  outer test harness process; only after scrubbing them did the test
  exercise the real failure-closed path in `_session_current_name`.

## Not in scope

- Re-adding the recipient-created-at reissue-refusal check 077 descoped
  (`cctrl:5248-5256`, `docs/plans/075`) — that's a separate, still-open
  design question about the *recipient's* identity, not the caller's.
- Any change to `--impersonate`'s behavior.
- Any change to the non-tmux (`user`) send path.

## Implementation

Distinguished "no `$TMUX` at all" (unaffected — `caller_unresolved` stays
false, exactly the old fail-open path) from "`$TMUX` set but
`_session_current_name` couldn't resolve it" (`caller_unresolved=true`) in
both `_peer_cmd_send` and its cross-machine twin
`_peer_send_and_deliver_remote_checked`. `_peer_sender_binding_mismatch`
takes the new flag and refuses (rc 66, new `sender-unresolved` error code)
when the caller is unresolved AND the `--as`/`--from` identity actually has
a real `tmux_target`/`session` to bind against — chose refuse over
warn-and-audit (the plan's other offered option) because an unresolved
caller is the same shape of gap 077 was built to close, not a softer case.
`--impersonate` and `from=user` remain fully exempt; `audit.caller_unresolved`
records the anomaly on any message that does get written (i.e. only via
`--impersonate`, since the plain refused case writes nothing).

## Eng review

Opus-level subagent review, 2026-09-29: verdict "changes requested". One
REQUIRED finding, fixed: the unresolved-caller refusal in
`_peer_sender_binding_mismatch` fired before checking whether the `from`
peer even had a `bind_target` — so an unresolved caller sending `--as` a
mailbox-only peer (no tmux identity at all, nothing to impersonate) was
wrongly refused, stricter than the already-allowed case of a *resolved*
caller doing the same send. Fixed: the unresolved check now runs only after
confirming `bind_target` is non-empty. Added a test pinning this exact case
(`test_peer_send_refuses_when_caller_tmux_session_unresolved`'s final
block, using a second registered peer with no `--session`).

Two OPTIONAL findings folded in anyway: reworded the "sender-unresolved"
error message to name the sender and point at `cctrl session current`
instead of guessing "stale/inherited" as the cause (tmux being briefly
unreachable produces the identical symptom); added a matching unresolved-
caller sub-case to `test_peer_send_sender_binding_applies_to_remote_recipients`
covering the cross-machine path (was previously only covered by an ad-hoc,
uncommitted repro during review).

Not addressed (explicitly optional, left for a future pass if anyone hits
it): a second test variant that reproduces the *explicit*
`CCTRL_SESSION_KIND=tmux` + stale `CCTRL_SESSION_NAME` branch of
`_session_current_name` (the current test only exercises the generic
pane-ancestry branch — both branches return the same `caller_unresolved`
signal, so this is redundant coverage, not a gap in behavior). The
reviewer's suggestion to empirically verify from inside a live Codex-hosted
fleet session before landing was not run — no live session was touched, per
the standing hard rule against interacting with other sessions; flagging
here as a good manual sanity check for whoever next has reason to touch
this path.
