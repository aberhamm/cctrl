---
id: 077
title: Bind the peer-send sender to the caller's tmux session
status: pending
blocked-by: []
priority: 77
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-27
tui-fixture: n/a
approved-by: none  # queued by the fleet manager (scope-fm0927); plan only
---

## Plain-English Summary

On 2026-09-27, message msg_20260927_175609_8f2f78 was misrouted. TMUX--ms--homelab ran `peer send TMUX--ms--cctrl --as TMUX--ms--homelab--3`, and both names were stale: the `--3` name had been reused on 2026-09-24, and the fleet manager's name in the brief was outdated.

Recipient resolution is exact-match (cctrl ~3948-3974). The sender identity (`_mailbox_resolve_identity_for_mode`, ~4908; send at ~5030-5051) is never checked against the caller's tmux session.

This is from the fleet manager's read-only analysis.

## Requirements

- [ ] `_peer_cmd_send`, `peer reply` and `_peer_send_and_deliver`: when `$TMUX` is set and `--as`, `--from` or `CCTRL_PEER` resolves to a tmux session other than `tmux display -p '#S'`, exit 66 with "sender X is not your session Y". An explicit `--impersonate` overrides this.
- [ ] Record audit fields on each message: requested_to, requested_from, caller_tmux_session, and the recipient's created_at.
- [ ] Refuse a reissued name (the peer's created_at is newer than the caller's session start) unless `--force` is given.
- [ ] Doctrine in `skills/cctrl-spawn` and `skills/cctrl-fleet-manager`: use `--as "$(tmux display -p '#S')"` or role aliases, never a literal session name.
- [ ] Tests:
  - `send B --as B` from A exits 66 and writes no messages.jsonl line.
  - `send --as A` records the audit fields.
  - A reused name is refused.

## Side note

`data/sessions/TMUX--ms--homelab.json` is a stale legacy record (2026-09-06, conversation 12b80645) that doesn't match the live occupant. Plan 070's resolver closed the canonical 12b80645 record, but the legacy name-keyed file remains.
