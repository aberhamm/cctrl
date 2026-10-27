---
id: 108
title: Wire the peer doorbell into sessions' Stop hook
status: ready
blocked-by: []
priority: 10
allows-migrations: false
review-required: eng
created: 2026-10-20
approval: mdec-1020-cctrl-mailbox-push (plan); mdec-1027-orch-cctrl-mailbox-fix (scope incl. drain fix)
reviews:
  - type=eng verdict=approved-with-changes date=2026-10-27 by=opus-subagent (orch-cctrl)
supersedes-in-part: 044
base: main a8200c3 + cherry-pick b6970ce
---

## Problem

`peer send` stores mail fast again (fix 846d159), but nothing tells the
recipient. Mail stays `queued` until the recipient runs `peer recv` on its
own. On 2026-10-20 `orch-homelab--2` had 23 queued and the fleet manager
had 115.

`hooks/peer-doorbell.sh` exists for this but is registered nowhere. A global Stop hook,
`cctrl hooks run stop`, IS already registered for every Claude session and resolves the
installed release on every call. So the doorbell belongs inside that dispatcher, and an
install alone would enable it fleet-wide. It must ship behind a runtime enable file.
`peer send --deliver` (nudge idle, defer busy, no retry) and `peer watch` (resident
renudger) already exist. The bell is the missing retry for "deferred while busy".
Queued backlog on 10-27: 735 messages (330 to fleet-claude--2).

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
5. **Nested Claude misidentification.** CCTRL_SESSION_NAME/TMUX/TMUX_PANE/CCTRL_PEER are
   inherited by any `claude -p` started in a pane; a name-only rule would ring (and let
   recv flip) the parent's mail. Identity must bind to the pane's own Claude pid.
6. **`peer check` ignores the addressee guard** (recv applies it), so a recycled name
   could ring for undeliverable mail.
7. **Drain contract.** recv is one-per-call and re-returns delivered mail forever once
   the queue is empty; ack is single-id and refuses queued. The bell's instruction is
   not drainable without recv --all / ack --all.
8. **notify.sh `say` is synchronous** in the same dispatcher; doorbell must run first and
   its feedback must not include notify/session-log stderr.

## Design (normative; see eng review 108-eng-review.md §5 for detail)

- Doorbell logic lives in cctrl (`_peer_doorbell_eval`, `peer doorbell` subcommand);
  `hooks/peer-doorbell.sh` becomes a thin wrapper (codex mode kept).
- `hooks run stop`: run the doorbell first, then notify.sh and session-log.py with stderr
  discarded; exit 2 with the bell text only when the bell rings, else 0.
- Gates, cheapest first, all fail-open/silent:
  1. env (CCTRL_SESSION_KIND=tmux, CCTRL_SESSION_NAME, TMUX, TMUX_PANE=%N);
  2. $PEER_DATA_DIR/doorbell.json enabled;
  3. stdin stop_hook_active read as a flag, not a skip (verify fix SF2): a forced
     continuation's Stop rings only for mail that arrived during that turn, at most
     3 rings in a row (DOORBELL_MAX_CHAIN); held mail rings at the next ordinary Stop;
  4. live session name via `tmux display-message -p -t "$TMUX_PANE"` (exact), managed check;
  5. candidate names = live name, CCTRL_PEER (unless peers.json binds it to another
     session, verify fix SF1), metadata.peer, manual peers whose session or aliases match;
  6. peer/role allowlist;
  7. jq prefilter of messages.jsonl for post-baseline, un-rung, queued mail;
  8. the FIRST Claude process above the hook, found by process name (verify fix MF2: a
     nested `claude -p` may write no sessions file), is the pane's Claude; and when the
     Stop stdin carries session_id it equals that Claude's sessionId. Unknown = no ring;
  9. authoritative guarded `peer check`;
  10. record rung ids, print the instruction, exit 2.
- Bell keys on QUEUED mail only; delivered_unacked never rings.
- Instruction: `cctrl peer recv --all --as <peer> --json`, then `cctrl peer ack --all --as <peer>`.
- Ring-once state: $PEER_DATA_DIR/doorbell/state/<session>.json {occupant_created, chain, rung{}}.
- baseline_at: now on first enable and on enable from disabled, unless --keep-baseline
  (verify fix SF5); widening a running bell keeps it.
- Debug: `touch data/doorbell/debug` or CCTRL_DOORBELL_DEBUG=1 → one reason line per
  Stop in data/doorbell/debug.log, also from inside `hooks run stop` (verify fix SF4).
- Cost note (verify SF8): the gate order means every cctrl session with post-baseline
  queued mail pays the metadata/role lookup at each Stop while the bell is enabled,
  not only enabled sessions (a few ms).
- Drain fix: `recv --all|--limit N`; plain recv no longer re-returns delivered unless
  --status delivered; `ack <id>...` and `ack --all`; MCP recv/ack equivalents.
- `peer check` applies the addressee guard (read-only).
- Idle path:
  - sends default to --deliver (with --no-deliver) only when doorbell.json is enabled,
    the bell is enabled FOR the recipient (its names in peers, or its role in roles),
    its role is in deliver_default_roles, and its Claude pane is idle (not working,
    no modal, no draft) (verify fixes MF1, SF3). A pilot `enable --peer ONE` changes
    sends to ONE only. A busy recipient gets a plain send; its Stop bell catches it.
  - a default (not requested) delivery that is deferred or fails exits 0 with a
    warning: the message is queued and a retry would duplicate it. Explicit
    --deliver keeps its exit codes;
  - `peer watch --since` (default baseline_at) is the safety net.
  - Starting a resident watcher is a separate approval.
- Registration: none needed. `peer doctor` checks Stop has an active `cctrl hooks run stop`
  entry (structural, CCTRL_CLAUDE_SETTINGS-overridable); the remedy is `cctrl hooks install`.
- Cost budget:
  - non-cctrl ≤5 ms, no forks;
  - disabled ≤15 ms;
  - enabled with no new mail p95 ≤100 ms;
  - ring ≤2 s once per batch.
  - Enforced in the suite by tmux-call counts; measured by tests/bench-doorbell.sh on a copy
    of data/ and a private `tmux -S` socket.

## Decisions for Matthew

- **D1. Scope of registration.**
  - (a) Global, via 044's `peer doctor --fix`: every Claude session on
    the machine, including non-cctrl ones, which stay a no-op.
  - (b) Per-session overlay, only for cctrl spawns. Existing sessions get
    it only after a restart.
  - Recommendation: neither. Fold into the already-registered global `cctrl hooks run
    stop`, gated by $PEER_DATA_DIR/doorbell.json. No settings edit; live sessions see it
    at their next Stop once enabled; install alone is inert. Matthew approves the
    exact enable command.
- **D2. Who gets the bell.**
  - (a) Every cctrl session.
  - (b) Only orchestrators and the fleet manager (role ≠ worker), so
    workers mid-task are not pulled off course.
  - Recommendation: (b), via doorbell.json roles/peers; unknown role = off; pilot = one
    orchestrator by name.
- **D3. Blocking or advisory.**
  - Exit 2 forces the agent to act on the mail now.
  - The alternative is exit 0 with a printed notice the agent may
    ignore.
  - Recommendation: exit 2, with the D2 scope and the loop guard.
- **D4. Idle recipients.**
  - (a) Senders to orchestrators default to `--deliver`.
  - (b) Leave idle sessions to the fleet manager's tick.
  - (c) A later `peer watch` daemon (out of scope in 044).
  - Recommendation: (a) default --deliver to live, idle orchestrator/FM recipients the
    bell is enabled for (a busy one gets a plain send, caught by the Stop bell) + (c) existing `peer watch` with a --since
    baseline floor as safety net. Starting it resident = separate Matthew approval.
- **D5. Existing backlog.** On first ring, 100+ old messages would flood
  the fleet manager.
  - (a) Mark mail older than the rollout as seen, so only new mail
    rings.
  - (b) Ring for all of it.
  - Recommendation: (a) baseline_at written once by `peer doorbell enable`; bell and
    watch ignore older mail; backlog untouched; `peer doorbell status --backlog`
    reports it for later triage.

## Rollout (each step separately approved by Matthew)

1. Merge after the full suite and review pass. Install the release; it is inert (no doorbell.json).
2. `cctrl peer doorbell enable --peer <one orchestrator> --dry-run`, then run it for real.
3. Watch one day: ring count, forced-continuation count, Stop latency (bench numbers recorded here).
4. `cctrl peer doorbell enable --role orchestrator --role fleet-manager`.
5. Optional, separate approval: a resident `peer watch --interval 60`.

Rollback:
- `cctrl peer doorbell disable`, or `rm data/doorbell.json`. Takes effect at the next Stop.
- Code: disable the bell first (`cctrl peer doorbell disable`), then repoint
  ~/.local/lib/cctrl/current at the previous release (there is no `cctrl rollback`
  command; see the impl report's rollback text).
- No settings.json change at any step.

## Tests

The 27 tests of eng review §5.13 (in `tests/run-tests.sh`):
doorbell no-op outside cctrl / when disabled; derived name rings; prefix-match safe;
nested Claude no-op; stop_hook_active guard; ring once per message; baseline skips
backlog; recycled name; alias candidates; role gate; rename uses live name;
`hooks run stop` ordering; fail open; fast-path call budget; `peer check` applies the
guard; `recv --all/--limit`; recv no re-return; `ack` multi/--all; MCP recv all / ack
ids; send default deliver (gated); `watch --since` floor; `peer doorbell
enable/disable/status`; registration check is structural; real settings untouched;
existing doorbell hook test kept (codex + no-peer); `peer ls` escape (out of scope here).

## Out of scope

- the `peer ls` `\033` bug (separate commit);
- `asyncRewake` idle wake (needs a scratch-session spike);
- backlog cleanup (separate gc approval);
- `peer show --as`;
- the launchd unit.

## Unrelated bug seen while planning

`peer ls` prints a literal `\033[0;32mlive`: the status is bound to a `%-8s` slot instead
of `%b`, and the last two `%s%s` fields have no separator (`cctrl:6347-6349`). Separate fix.
