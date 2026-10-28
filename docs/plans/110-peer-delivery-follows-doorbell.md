---
id: 110
title: Peer delivery follows the doorbell (reply, MCP send and deliver stop pushing into non-pilot panes)
status: ready
blocked-by: []
priority: 20
allows-migrations: false
review-required: eng
created: 2026-10-28
approval: mdec-1028-cctrl-recommendations-1-7 item (3) (implement, verify, push, install; every push/install after an independent verify)
reviews:
  - type=eng verdict=approved-with-changes date=2026-10-28 by=opus-subagent (orch-cctrl) ref=orch-cctrl-reports/110-eng-review.md (F1-F5 must-fix, applied below)
related: 108, 111
---

## Problem

Plan 108 gated only the `peer send` default by the doorbell. Every other
delivery path still pushes into the recipient's pane regardless of the bell:
`peer reply` (always delivers, no `--no-deliver` flag), the MCP `send_message`
tool (hard-codes `--deliver`, lib/peer_mcp.py:335), explicit `peer send --deliver`,
and `peer deliver`/`peer nudge`/`peer watch`. Delivery tries the Claude Code
messaging-socket adapter first (cctrl:8592-8614 at 765b8fc), which
skips `_peer_pane_ready_for_delivery`; only the tmux fallback runs that check.
The tmux path's `_peer_pane_ready_for_delivery` checks modals only; neither
path checks busy or draft.
Claude Code holds that cross-session input behind a security prompt, so
non-pilot sessions show held "N new peer messages" bodies. Seven such nudges
were traced after the 108 install, and the same mechanism predates 108.
Doctrine is stopgapped in AGENTS.md (send `--no-deliver`); this plan is the code fix.

## Design

1. One gate, `_peer_push_allowed <peer_json> <messages>`, inside
   `_peer_deliver_one_locked`, the single function every push goes through
   (reply, send --deliver, deliver, nudge, watch, the remote side, and MCP
   bridges pinned to old releases). In 110 it checks only the recipient:
   `_peer_doorbell_enabled_for` (factored out of
   `_peer_doorbell_send_defaults_deliver`; jq only, no tmux). It sets
   `PEER_PUSH_REASON`. It runs after the addressee guard and the
   queued==0 / inline-target checks, before dry-run and the app-server branch.
2. A blocked recipient gets deliver status `queued-only`
   (`reason: recipient-not-doorbell-enabled`), rc 0, no mailbox write (no
   history, no nudge_count, so watch backoff is untouched). Send and reply
   report it as outcome `sent-and-queued` with
   `delivery_reason: recipient-not-doorbell-enabled` plus a `warning` (JSON)
   or a stderr notice (text). Never `skipped`: that is classified as nudged.
3. `peer reply` gains `--deliver` / `--no-deliver` (parity with send; both is
   exit 64). MCP keeps `--deliver` (the gate decides; the outcome field stays);
   `peer mcp` passes the `$CCTRL_HOME/current/cctrl` path so bridges follow
   installs and rollbacks.
4. Claude readiness, `_peer_claude_push_ready <target>`, fail-closed, run
   before ANY push to a Claude recipient (socket and tmux fallback). Ready
   means all of: session exists and pane not in copy-mode; the pane's Claude
   pid has `$CLAUDE_SESSIONS_DIR/<pid>.json` with `.status == "idle"`; a
   capture succeeds and is non-empty; no dialog (`_session_pane_has_dialog`
   plus the `CLAUDE_HC_PATTERN` table); no draft (`_session_pane_has_draft`);
   the transcript's last turn is not `assistant-question`. It ignores the
   `CCTRL_STATE_DETECT_*` switches. The socket comes from that pid's session
   file, not a name scan. `--no-submit` skips the socket path. Codex keeps
   `_peer_pane_ready_for_delivery`.
5. Explicit `--deliver` back-compat: **allowed only to doorbell-enabled
   recipients; to anyone else it degrades to queued-only with the notice, and
   there is no override flag** (no `--force-deliver`, no env-based "human"
   override: env is self-reported, plan 111). If an operator needs a one-off
   push, they enable the bell for that peer (auditable, reversible).

   | case | outcome | delivered | rc |
   |---|---|---|---|
   | send failed | send-failed | - | 64/66/1 (unchanged) |
   | not bell-enabled | sent-and-queued (`delivery_reason: recipient-not-doorbell-enabled`) | false | 0 |
   | bell-enabled, pane not ready | sent-but-deferred | false | 0 (was 1) |
   | bell-enabled, ready, pushed | sent-and-nudged | true | 0 |
   | bell-enabled, push failed | sent-but-undelivered | false | 1 |
   | mailbox-only peer | sent-and-queued | false | 0 |

   Deferred for a bell-enabled recipient is rc 0: its Stop bell rings.
   Remote recipients: the remote host's cctrl decides.
6. FM: no exemption. FM pane nudges (raw tmux, `session say`) are outside the
   gate. Caller identity is self-reported until 111, which extends
   `_peer_push_allowed`.
7. Codex app-server peers: gated the same way (review F10); the FM is told
   before install.
8. MCP `say_peer` (decision D1, narrowing; own commit): to a tmux recipient
   that is not bell-enabled it returns `error.code
   "recipient-not-doorbell-enabled"` ("use send_message"); its description
   drops "DEFAULT RULE".

## Acceptance criteria

- No path (`reply`, MCP `send_message`, `send --deliver`, `deliver`, `nudge`,
  `watch`) writes to a socket or tmux pane of a recipient that is not
  doorbell-enabled. With doorbell.json absent or malformed, nothing is pushed.
- Every such call to a non-enabled recipient returns exit 0, leaves the message
  queued, and reports `queued-only` / `sent-and-queued` in text and JSON.
- Bell-enabled recipients get a push only into a ready pane (Design 4), by
  socket or tmux; a not-ready pane is deferred, rc 0.
- `peer reply --no-deliver` exists; `--deliver` and `--no-deliver` together is a usage error.
- Running MCP bridges re-pointed or restarted at install (Rollout G3).
- MacBook installed (G4).
- The existing delivery tests are updated (bell fixture), not deleted.
- AGENTS.md keeps "do not use peer say/session say into other sessions",
  describes reply/send as queue-first with delivery as cctrl's decision, and
  drops the "prefer `send --no-deliver`" caveat.

## Tests

- T0: shared fixture helper (doorbell.json for a recipient; a Claude session
  file under `CCTRL_CLAUDE_SESSIONS_DIR`); every delivery test sets
  `CCTRL_CLAUDE_SESSIONS_DIR` and HOME to scratch.
- T1 (stubbed): each path to a NON-enabled recipient: rc 0, queued-only /
  sent-and-queued, zero socket or tmux paste, nudge_count unchanged; an enabled
  idle recipient gets exactly one push; no / malformed doorbell.json: no push.
- T2 (stubbed): readiness on an enabled recipient: busy, modal, draft,
  waiting-input, copy-mode, capture failure, missing session file,
  `CCTRL_STATE_DETECT_*=0` with a modal: deferred, rc 0, zero frames; idle: one.
- T3: JSON shape (outcome, delivered, delivery_reason, warning), text notice
  on stderr, MCP `send_message` ok:true with outcome sent-and-queued.
- T4: `--no-submit` uses no socket; queued-only never reported as
  sent-and-nudged; `reply --deliver --no-deliver` exits 64.
- T5 (real tools, AGENTS.md rule): real tmux on a private `-S` socket, real
  `ps` (`_proc_children`), a real python AF_UNIX listener in `mktemp -d`, a
  pane running `bash -c 'sleep 600 & wait'` with the session file keyed by the
  sleep's pid: (i) not enabled: reply, send --deliver, deliver give zero
  frames and an unchanged capture; (ii) enabled idle: one frame; (iii) enabled
  with a modal line: zero; (iv) real `python3 lib/peer_mcp.py` over stdio:
  `send_message` to a non-enabled recipient gives zero frames.
- Never against the live fleet, live tmux server or ~/.claude.

## Rollout

Each step needs explicit OK and an independent verify before install (grant limits).

- G1. The FM accepts the wake-up change: a non-bell session waiting idle for a
  reply is no longer woken by cctrl; FM ticks use `peer status`/`overview`
  queued counts and nudge by pane.
- G2. Tell the FM about the Codex app consequence (Design 7).
- G3. After install, list bridges (`ps -A -o pid=,command= | grep '[p]eer_mcp.py'`)
  and restart each pinned MCP server or its session (FM, one at a time).
- G4. Install on the MacBook as well; until then a Studio send to a MacBook
  peer runs the MacBook's old `peer send --deliver` and pushes.
- G5. Rollback is as in 108-READY; it re-opens every push path at once and
  loses no mail.
- G6. Verify on the pilot: a send to orch-cctrl while busy is queued and the
  bell rings at Stop; a send to one non-pilot session gives no held prompt
  and no `event:"nudge"` history entry.

## Out of scope

- Sender attestation and a sender allowlist: plan 111 (precondition for widening the bell).
- Changing Claude Code's cross-session input hold.
- CLI `peer say` / `session say` (operator and FM paste tools).

## Tasks

1. `_peer_doorbell_enabled_for` + `_peer_push_allowed`, gate in `_peer_deliver_one_locked`.
2. `queued-only` status and classification. 3. Reply flags.
4. `_peer_claude_push_ready` + pid-bound socket, no socket on --no-submit.
5. MCP description + `current` path; say_peer gate (D1); Codex app (D2).
6. Tests T0-T5. 7. README/CHANGELOG/AGENTS.md.
