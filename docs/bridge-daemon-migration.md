# Migrating a running bridge daemon after a cctrl upgrade

A bridge daemon outlives the `cctrl` that started it. After upgrading cctrl, an
endpoint that was enabled earlier keeps running the **old** daemon code until
you stop it. cctrl never restarts a running daemon for you: the daemon owns
pending work, and replacing it blindly can lose track of that work.

## How cctrl detects an old daemon

Each daemon writes a protocol record (`protocol` and `capabilities`) next to its
endpoint row, in the same transaction. Current daemons advertise protocol 2 with
`native_retirement`, `reply_acks_original`, `sender_envelope` and `admission_gate`. A daemon
started by an older cctrl wrote no record and counts as protocol 1.

`cctrl bridge list` shows `protocol` and `capabilities` per endpoint. The daemon
also answers a `hello` request with the same values.

Rule: **an outdated daemon allows only `stop`, `list`, `status` and `inbox`.**

| Command | Old daemon (protocol < 2) |
|---|---|
| `bridge send`, `bridge ack`, `bridge reply` (and the MCP `native_send`, `native_ack`, `native_reply`, which run the same CLI) | **Refused**, exit 1, error code `daemon-outdated`. Nothing is sent, acknowledged or retired. An old daemon cannot retire the Codex queue copy (an ACK would report success while the message surfaces again later) and drops the sender envelope (no `Sender:` line). The mailbox tools `ack_message` / `reply_message` are not affected. |
| `bridge enable` | Returns the row with `daemon_outdated: true` and a `warning`. |
| `bridge list` | Shows `protocol`, `capabilities` and `daemon_outdated` per endpoint. |
| `bridge stop`, `status`, `inbox` | Work normally. `stop` is how you migrate. |

The ledger row is the authority for this check. The daemon's `hello` request
(returns protocol, capabilities, pid) exists only as a diagnostic; cctrl does not
call it.

**Rollout note.** Right after this release is installed, every running endpoint
is outdated, including daemons started by the release just before it: they wrote
no protocol record. Each session must migrate (below) before it can send, ack or
reply again.

Do not retry a refused `send`, `ack` or `reply`; migrate first. Do not just stop and enable: drain held items first.

## Why a drain comes first

Messages belong to the daemon's actor (`messages.dispatcher`), and the ledger
survives a restart. Callbacks do not survive it. Native Claude reports
`held`, `released`, `denied`, `expired` and `refused` to the **PID and callback
socket that sent the message**, and the daemon only accepts a callback from the
PID/socket it expects. A new daemon has a new PID and socket, so:

- an outbound message that is `held` (waiting for the receiver's admission) will
  never have its release reported to the new daemon; the ledger would show
  `held` forever even though Claude later accepted it;
- `submitting` and `ambiguous` items are never replayed by any daemon. They keep
  their ledger status, and only `status --reconcile` (Codex) can learn more.

Items still `persisted` (never submitted) are safe: the new daemon for the same
actor dispatches them.

## Procedure

Run these as the session that owns the endpoint, with the **new** cctrl.

1. Check what is pending:
   ```sh
   cctrl bridge list --json
   cctrl bridge inbox --view history --json
   ```
   Look for rows this session sent with status `held`, `submitting` or
   `ambiguous`, and for received rows you have not finished.
2. Drain:
   - `held`: wait until the receiver admits or refuses it (status becomes
     `released`, `denied`, `expired` or `refused`). Do not resend.
   - `ambiguous` or `submitting` to a Codex thread: `cctrl bridge status ID --reconcile`.
     Never replay.
   - Finish handling of anything you received, but note `ack`/`reply` are refused
     on the old daemon; leave those for step 5.
3. If an item cannot drain, write down its ID and stop anyway: stopping is not a
   handling ACK and does not authorize replay. After the migration, the ledger
   row stays as it was, no callback will update it, and you must confirm the
   outcome with the receiver (or `status --reconcile` for Codex).
4. Make sure nothing old can bring the old daemon back. Restart peer MCP servers
   (and any other long-running process) that were started before the upgrade, and
   check `command -v cctrl` is the new release. A process still running an older
   cctrl starts an old daemon on its next send or enable after the stop.
   Stop the old daemon and start a current one:
   ```sh
   cctrl bridge stop
   cctrl bridge list --json      # your endpoint is gone
   cctrl bridge enable --json    # no daemon_outdated; protocol 2
   ```
   Use `bridge stop`, never `kill`: it lets the daemon remove its own sockets
   and ownership record. If cleanup stays pending, inspect it; do not kill an
   unverified PID.
5. Retire stale Codex queue copies. Messages the old daemon already marked
   handled were never retired from your Codex queue. Find them (read-only; only a successful or final retirement excludes a message, so `unknown`, `race` and `identity_mismatch` outcomes, which are meant to be retried, are listed too; the
   ledger is `$CCTRL_NATIVE_BRIDGE_DIR/ledger.sqlite3`, default
   `~/.local/state/cctrl/native-bridge/ledger.sqlite3`):
   ```sh
   sqlite3 -readonly LEDGER "SELECT id FROM messages m
     WHERE recipient='codex:YOUR_THREAD_ID' AND kind='message' AND received IS NOT NULL
       AND status IN ('queued','ambiguous')
       AND NOT EXISTS (SELECT 1 FROM events e WHERE e.id=m.id AND e.kind='native-retire'
         AND json_extract(e.detail,'\$.outcome') IN ('retired','absent','already_consumed','unsupported','not_applicable'))"
   ```
   Repeat the ACK for each with the new daemon; it is idempotent and only deletes
   the exact queue item this bridge submitted:
   ```sh
   cctrl bridge ack MESSAGE_ID
   ```
   Check `native_retirement.outcome` (see
   [peer-messaging.md](peer-messaging.md)).

A repeated ACK does not resend a receipt that was already sent; a receipt that earlier failed is retried, which is intended. A receipt owed to a Claude sender is never submitted natively (recorded as `suppressed`, see peer-messaging.md), so it has nothing to retry.

## Not done on purpose

- No automatic restart or kill of a running daemon, and no in-place upgrade.
- No `--force` that bypasses the check: a refused `ack`/`reply` is the safe
  outcome.
