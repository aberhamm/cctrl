---
id: 108
title: Wire the peer doorbell into sessions' Stop hook
status: draft
blocked-by: []
priority: 10
allows-migrations: false
review-required: eng
created: 2026-10-20
approval: mdec-1020-cctrl-mailbox-push (plan only; no hook change)
supersedes-in-part: 044
---

## Problem

`peer send` stores mail fast again (fix 846d159), but nothing tells the
recipient. Mail stays `queued` until the recipient runs `peer recv` on its
own. On 2026-10-20 `orch-homelab--2` had 23 queued and the fleet manager
had 115.

`hooks/peer-doorbell.sh` exists for this. As a Claude Stop hook it exits 2
when mail is queued, so the agent keeps going and is told to run
`peer recv`. It is registered nowhere. Plan 044 (pending since 07-30)
would add `peer doctor --fix` to register it.

## Gaps found beyond plan 044

1. **The doorbell is a no-op for every live session today.** It returns
   early when `CCTRL_PEER` is unset. All 21 live peers are `derived`
   (no `--peer` at spawn), so `CCTRL_PEER` is not set. Wiring the hook
   alone changes nothing.
2. **No loop guard.** Claude passes `stop_hook_active: true` on the
   stop that follows a hook-forced continuation. The script ignores it.
   If the agent does not drain the mail, every stop forces another turn.
3. **Stop only fires at the end of a turn.** An idle session never ends a
   turn, so it never hears the bell. Idle recipients still need
   `peer send --deliver` (a nudge) or a resident watcher.
4. **Cost per stop.** Each stop runs `peer check`. That costs about 1 s
   now, down from about 6 s or more before 846d159. Measure on the
   installed build before rollout.

## Proposed design

- Name fallback: when `CCTRL_PEER` is unset, the hook uses the tmux
  session name (`tmux display -p '#S'`, only inside a cctrl-managed
  session), the same name `peer ls` derives.
- Loop guard: read the Stop hook's JSON on stdin. When
  `stop_hook_active` is true, exit 0. The agent then gets at most one
  forced continuation per natural stop.
- Rate limit: ring at most once per new message id. Keep a small state
  file per peer under `data/`, so old queued mail is not repeated every
  stop.
- Registration: a per-session `--settings` overlay at spawn (cctrl
  already writes overlays), or global `~/.claude/settings.json` through
  plan 044's `peer doctor --fix`. See decision D1.
- Tests: an isolated settings fixture (`CCTRL_CLAUDE_SETTINGS`), an
  isolated tmux socket (`unset TMUX TMUX_PANE`, `tmux -S`), never
  kill-server. Cover the derived-name path, the loop guard,
  ring-once-per-message and the no-peer no-op.

## Decisions for Matthew

- **D1. Scope of registration.**
  - (a) Global, via 044's `peer doctor --fix`: every Claude session on
    the machine, including non-cctrl ones, which stay a no-op.
  - (b) Per-session overlay, only for cctrl spawns. Existing sessions get
    it only after a restart.
  - Recommendation: (a), because live sessions pick it up without a
    restart.
- **D2. Who gets the bell.**
  - (a) Every cctrl session.
  - (b) Only orchestrators and the fleet manager (role ≠ worker), so
    workers mid-task are not pulled off course.
  - Recommendation: (b) first.
- **D3. Blocking or advisory.**
  - Exit 2 forces the agent to act on the mail now.
  - The alternative is exit 0 with a printed notice the agent may
    ignore.
  - Recommendation: exit 2, with the D2 scope and the loop guard.
- **D4. Idle recipients.**
  - (a) Senders to orchestrators default to `--deliver`.
  - (b) Leave idle sessions to the fleet manager's tick.
  - (c) A later `peer watch` daemon (out of scope in 044).
  - Recommendation: (a) for the fleet manager → orchestrator path only.
- **D5. Existing backlog.** On first ring, 100+ old messages would flood
  the fleet manager.
  - (a) Mark mail older than the rollout as seen, so only new mail
    rings.
  - (b) Ring for all of it.
  - Recommendation: (a).

## Rollout

Implement and test this in a worktree, review it, install it, and enable
it on one orchestrator first. Watch one day of Stop behaviour there, then
roll out to the rest. Rollback: remove the hook entry (044 makes a backup)
or reinstall the previous release.

## Unrelated bug seen while planning

On the live install (257d5a5), `peer ls` prints a literal `\033[0;32mlive`
in the STATUS column, and the DIR/PURPOSE columns run together.
