---
id: 077
title: Bind the peer-send sender to the caller's tmux session
status: done
completed: 2026-09-28
blocked-by: []
priority: 77
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-27
tui-fixture: n/a
approved-by: matthew (C-15, via cctrl-fleet-manager)
reviews:
  - type=eng verdict=approved date=2026-09-28 by=opus-subagent
---

## Implementation note (2026-09-28)

Shipped with one deliberate descope from the Requirements below, found by the
Opus eng review: the "refuse a reissued recipient name" check (3rd
Requirements bullet) was implemented exactly as specified, then dropped
before commit. As written, "the peer's created_at is newer than the caller's
session start" is also true of every normal session spawned *after* the
caller — a fleet manager messaging a freshly spawned worker, a reply to that
worker, a restore-order-dependent send. The literal implementation refused
ordinary fleet traffic far more often than it caught an actual reissue (the
review's test case was itself just "a session created after the caller").
Shipped instead:
- The sender-binding check (1st bullet) exactly as specified, using
  `_session_current_name` (not the bare `_session_tmux_display_current_name`)
  since `$TMUX` alone can be stale in an agent subprocess.
- `audit.recipient_created_at` is still recorded on every message (audit
  only, not enforced), plus `audit.impersonated` when `--impersonate` was
  used.
- The `--force` flag was removed (nothing left to override).
- The eng review also found the sender-binding check never ran for a
  cross-machine recipient (`_peer_send_and_deliver`'s SSH hop bypassed the
  local check entirely) — fixed via `_peer_send_and_deliver_remote_checked`,
  which re-runs the same check from the caller's local vantage point (the
  only place `$TMUX`/pane ancestry are meaningful) before ever dispatching
  over SSH.

A real, non-false-positive-prone reissued-name check is filed as an open
design question in docs/plans/075-close-and-draft-review-followups.md, along
with the review's other minor/follow-up findings (documentation not updated,
`peer reply`'s audit.requested_from losing the literal `--as`, test-coverage
gaps, and the `peer recv --as <other>` read-side gap).

## Plain-English Summary

On 2026-09-27, message msg_20260927_175609_8f2f78 was misrouted. TMUX--ms--homelab ran `peer send TMUX--ms--cctrl --as TMUX--ms--homelab--3`, and both names were stale: the `--3` name had been reused on 2026-09-24, and the fleet manager's name in the brief was outdated.

Recipient resolution is exact-match (cctrl ~3948-3974). The sender identity (`_mailbox_resolve_identity_for_mode`, ~4908; send at ~5030-5051) is never checked against the caller's tmux session.

This is from the fleet manager's read-only analysis.

## Requirements

- [x] `_peer_cmd_send`, `peer reply` and `_peer_send_and_deliver` (incl. the cross-machine SSH hop): when the caller is inside a live tmux session and `--as`/`--from`/`CCTRL_PEER` resolves to a tmux session other than the caller's own, exit 66 with "sender X is not your session Y". An explicit `--impersonate` overrides this.
- [x] Record audit fields on each message: requested_to, requested_from, caller_tmux_session, recipient_created_at, and impersonated (when used).
- [x] ~~Refuse a reissued name (the peer's created_at is newer than the caller's session start) unless `--force` is given.~~ Descoped — see the 2026-09-28 implementation note above and the design question filed in plan 075. `recipient_created_at` is recorded but not enforced; `--force` was removed.
- [x] Doctrine in `skills/cctrl-spawn` and `skills/cctrl-fleet-manager`: use `--as "$(tmux display -p '#S')"` or role aliases, never a literal session name.
- [x] Tests:
  - `send B --as B` from A exits 66 and writes no messages.jsonl line (`test_peer_send_sender_binding_refuses_mismatch`).
  - `send --as A` records the audit fields (same test).
  - The cross-machine SSH hop also enforces sender binding (`test_peer_send_sender_binding_applies_to_remote_recipients`).
  - ~~A reused name is refused~~ — descoped; `test_peer_send_recipient_created_at_is_audit_only` instead pins that recency is recorded but never enforced.

## Side note

`data/sessions/TMUX--ms--homelab.json` is a stale legacy record (2026-09-06, conversation 12b80645) that doesn't match the live occupant. Plan 070's resolver closed the canonical 12b80645 record, but the legacy name-keyed file remains.
