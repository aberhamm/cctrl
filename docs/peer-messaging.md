# Agent messaging across Claude Code and Codex

Use `cctrl bridge` for native cross-provider messages and Codex-to-Codex input.
Claude-to-Claude messages use actual Claude `ListAgents`/`SendMessage`. For wire formats and evidence, see the
[protocol overview](findings/native-agent-messaging-protocols.md). Fleet authority
and approvals follow the [agent contract](../AGENTS.md#peer-messaging) and
[selected role skill](../skills/README.md).

## Enable, discover, and send

The current bridge is local and POSIX-only: it does not expose a network
messaging service, and Windows fails closed when OS peer verification is
unavailable. Run enable inside each actual participating provider session:

```sh
cctrl bridge enable
cctrl bridge list
# From Codex to Claude:
cctrl bridge send claude:ACTUAL_SESSION_ID -- "Please review the result"
# From Claude or Codex to Codex:
cctrl bridge send codex:ACTUAL_THREAD_ID -- "Please review the result"
```

Use the exact provider-qualified address returned by discovery. Session titles,
working directories, and relative subagent paths are not bridge addresses.
Enabling outside cctrl does not require launching another agent session or
borrowing an orchestrator's identity. If current-session identity is unavailable
or conflicting, diagnose it instead of fabricating an ID.

A Codex endpoint owns a persistent Claude-compatible socket and registry entry
for that exact Codex thread. Claude can discover this endpoint with native
`ListAgents` and use `SendMessage`; its native reply address routes back through
the same bridge daemon. The entry represents a **cctrl bridge to Codex**, not a
Claude agent. `bridge list` also discovers live native Claude sessions.

Claude-to-Claude bridge sends are rejected before submission. Use the actual
Claude native tools so sender/recipient permission admission retains its true
provider context. Raw native ingress addressed to a Claude actor's bridge proxy
is refused; the proxy is not a substitute Claude recipient.

For Codex-to-Claude sends, the bridge conservatively declares **prompting**
provenance. A Claude recipient in bypass mode may hold that input for its own
admission decision. The bridge never spoofs bypass provenance or overrides the
recipient's admission policy. Held is not failed and must not be replayed.

Codex input is submitted through the connected server's `thread/queue/add` API.
The native shared queue store can wake an independent owner's idle queue when
that provider build supports it. Queue acceptance does not establish consumption
by every CLI or extension. The bridge never resumes a running CLI thread or
replaces its history writer. Existing same-tree collaboration and exposed desktop tools remain
usable for targets they actually support; independently launched CLI sessions
do not share an internal collaboration tree.

## Delivery, inbox, history, and handling

These are three different things; keep them apart.

- **Delivery** is the native provider surface. A Codex message accepted by the
  server's queue (`queued`) and a Claude message that Claude admitted
  (`released`, or an immediate accept recorded as `submitted`) reaches the model
  as ordinary native input. `held` is NOT delivered: Claude admission is waiting
  for the receiver's approval, so the text has not reached the model, is not
  authorized work, and must never be handled from the ledger. Native delivery
  owns every message it accepted.
- **Inbox** is the handling surface and must never show the same work a second
  time. The default view (`actionable`) lists only messages native delivery did
  not accept (`failed`). Anything `queued`, `submitted`, `held` or `released`
  is not actionable in the inbox, and neither is refused input, a receipt, or
  anything already handled. Act on the native input itself, quoting its
  `message=` ID.
- **History** is inspection only. `inbox --view stranded` lists unhandled
  items native delivery did not cleanly take (`held`, `refused`, `denied`,
  `expired`, `dropped`, `ambiguous`, `submitting`, never dispatched); each
  row has `actionable: false` and is not authorized work. `inbox --view history`
  lists everything this session sent or received, receipts included, and
  `bridge status ID` shows one message with its events, `handled`,
  `late_native_delivery` and envelope.

When handling finishes (`bridge reply ID` or `bridge ack ID`) cctrl also retires
the recipient's still-pending native Codex queue item, so it cannot surface
again as a fresh user turn after the model has answered. It uses the supported
`thread/queue/delete` request, only for the exact item this bridge submitted:
`thread/queue/list` must show one entry whose `clientUserMessageId` is the
message ID AND whose queue ID equals the persisted `queued_submission_id`. Body
text is never consulted and no other queue entry is touched. The result carries
`native_retirement.outcome` (`original.native_retirement` on a reply):

| outcome | meaning |
|---|---|
| `retired` | the item was pending and the server deleted it |
| `absent` | not in the queue; it may already have been consumed (final, never replay) |
| `already_consumed` | delete found nothing and a re-list shows it gone: the owner consumed it in the window |
| `race` | delete reported nothing but the item is still queued; untouched, repeat the ACK to retry |
| `identity_mismatch` | the queue holds this client ID under another queue ID or several entries; nothing deleted |
| `unknown` / `unknown_identity` | transport failure or no persisted queue ID (run `status --reconcile`); retryable |
| `not_applicable` | no native queue item was ever accepted (for example `failed`) |
| `unsupported` | Claude recipient (see limit below) |

**Admission gate.** `bridge ack` and `bridge reply` refuse (exit 1, error says
the message is not admitted) while the status is `held`, `refused`, `denied`,
`expired` or `dropped`, and for a Claude recipient while it is only `submitted`
with no release recorded. A refusal sends no receipt and no reply and does not
mark the message handled. `inbox --view stranded` rows for those statuses carry
`admitted: false` and the body is replaced by `[NOT ADMITTED: body withheld ...]`;
`history` and `status` still show the stored text for inspection only. Consequence:
a Claude recipient can ACK or reply only after a release is recorded; a plain
immediate accept has no positive receipt and stays unACKable through the bridge
until that gap is closed.

`retired`, `absent`, `already_consumed`, `not_applicable` and `unsupported`
are final and recorded once as a `native-retire` event.

Limit: native Claude input cannot be retracted once written to its socket, and
held input is released by Claude's own admission decision. cctrl therefore
records the handling and, if a release (`delivered`) is reported for an item that
was already handled (only possible for items handled before the admission gate),
adds a
`late-native-delivery-after-handled` event, shown as `late_native_delivery:
true` by `bridge status`. This marks the late arrival as already handled in the
ledger; it cannot remove text a Claude session already received. Do not act on
it again: check `bridge status ID`.

## Daemon protocol and controlled upgrade

Each endpoint daemon answers a `capabilities` request with `protocol: 2`
(features `native_retirement`, `sender_envelope`, `admission_gate`). Daemons from
before this change reject the request, which reads as protocol 1. The CLI (and
therefore the MCP tools, which run the CLI) checks this before every `send`,
`reply` and `ack` and fails closed:

```
bridge daemon for ACTOR (pid N) speaks protocol 1; this cctrl requires protocol 2
(native queue retirement, sender envelopes, admission gate). Refusing to ack through it.
That daemon still owns this session's held and ambiguous items, so it is NOT restarted
automatically. Controlled migration: see 'Daemon upgrade' in docs/peer-messaging.md.
```

An unreachable daemon also refuses (`... is unreachable ...; not sending anything`).
`bridge enable` still returns the endpoint row, plus `protocol`, `protocol_required`,
`compatible` and, when stale, a `warning`. `inbox`, `status` and `list` are
read-only ledger reads and keep working.

### Daemon upgrade

cctrl never restarts a daemon by itself. A stale daemon is the owner of this
session's pending held and ambiguous items (provider callbacks bind its PID), so
replacing it blindly can orphan them. Migrate deliberately, per session:

1. `cctrl bridge inbox --view stranded --json` and `--view history`: note every
   `held`, `ambiguous`, `submitting` or `persisted` item. Resolve or record them;
   do not resend an ambiguous one.
2. Install the new cctrl (a separate, approved step), then in that session run
   `cctrl bridge stop --json` and wait until it reports `stopped`. If it reports
   pending cleanup, stop and investigate; do not kill the PID.
3. Run `cctrl bridge enable --json` and confirm `compatible: true`.
4. Re-check `bridge status ID` for each noted item. Held items whose provider
   callbacks died with the old process stay `held`; handle them natively, never
   by ACK from the ledger.

## Receipts are control facts

A receipt (`[cctrl-bridge receipt ... control=true]`) tells the original sender
that the recipient explicitly handled a message. It is not work: it is stored
as `kind: receipt`, born handled, never dispatched, never listed by the default
or `stranded` inbox views (only `history`), and cannot be ACKed, replied to, or
sent as a message (those return an error). Receipt submission is idempotent and
an ambiguous receipt is never replayed, so there are no receipt/ACK loops.

## Sender envelope

Codex sessions started outside cctrl need no setup for a name: the sender's CLI/MCP
call reads the thread title and origin with a read-only `thread/read` (no turns, no
resume, no history writer); if that fails or the thread is untitled they stay
`unknown`. To label a session explicitly, pass `--name`/`--harness` on `bridge
send|reply` (MCP `native_send`/`native_reply` `name`, `harness`) or export
`CCTRL_SESSION_NAME` / `CCTRL_HARNESS` once in the agent's startup; they are
recorded as claims and a provider-reported title wins over them.

Every bridge message carries one sender snapshot, taken once where the session is
owned (the sending CLI/MCP call, or the daemon for native ingress) and persisted
with the message. A retry keeps the first snapshot. The wire text shows it on a
`Sender:` line (always present: `Sender: unknown (no envelope recorded)` when none
was recorded; every claimed or reported value is JSON-quoted, so it cannot forge a
basis or another field); `status` and `inbox` return it as `envelope`:

| field | meaning |
|---|---|
| `provider`, `session_id` | routing identity from the actual session, never from the request |
| `identity_basis` | how the session was established (`environment-claimed`, `ancestor-registry`, `verified-native-socket`) |
| `display_name` | `{value, basis}`: the provider's own title for the exact session (Claude registry `provider-registry`; Codex read-only `thread/read` name, `provider-reported:thread/read`), else a caller claim (`--name`, then `CCTRL_SESSION_NAME`, basis `claimed:...`), else `unknown` |
| `harness` | `{value, basis}`: only a caller claim (`--harness`, then `CCTRL_HARNESS`; `claimed:...`); otherwise `unknown` |
| `reported_source` | `{value, basis}`: the provider's origin (for example Codex `thread/read` `source`: `vscode`, `cli`); never treated as the harness |
| `host` | `{value, basis}`: the local host name, observed |

Nothing is inferred from cwd, title or labels, the environment is never copied
(only the named variables are read), and the envelope grants no approval. The
mailbox `sender` object (name, label, agent, `external_identity`, host) is the
same snapshot idea for mailbox mail; it does not carry `harness` or
`reported_source`, which are native-bridge fields.

## Receive, reply, and inspect receipts

```sh
cctrl bridge inbox --limit 20
# If next_cursor is non-null, fetch the next page:
cctrl bridge inbox --after NEXT_CURSOR --limit 20
# Inspection views (never handling surfaces):
cctrl bridge inbox --view stranded
cctrl bridge inbox --view history
cctrl bridge reply MESSAGE_ID -- "Reviewed; here is the result"
# After handling without a reply:
cctrl bridge ack MESSAGE_ID
cctrl bridge status MESSAGE_ID
# Read-only reconciliation for a Codex target:
cctrl bridge status MESSAGE_ID --reconcile
# When this session no longer needs its endpoint:
cctrl bridge stop
```

Inbox pages default to 20 messages (`--limit` accepts 1..100). Start at
`--after 0` and follow each non-null integer `next_cursor`; listing does not ACK
mail. `status --reconcile` checks the native Codex queue without submitting input.
A missing queue entry may already have been consumed and never permits replay.

The bridge keeps a durable ledger. Use the message ID from its output or inbox
with `bridge reply` to correlate a response with the original message. Claude
can also reply with native `SendMessage` to the received `from` address, but a
raw native reply is recorded as a **new message**; it does not automatically
mark the original replied or handled. Native status receipts use their original
message ID for correlation.

Receipt stages have different meanings:

| Stage | What it establishes |
|---|---|
| Submitted | Socket write completed; not a native admission ACK or proof the model processed it |
| Queued | The connected Codex server accepted queued input; not proof of owner consumption or a handling ACK |
| Held | Claude admission retained the message pending its policy/approval |
| Released (`released` in bridge status) | Native Claude `delivered` reports release of previously held mail; ordinary immediate accepts emit no positive delivery receipt |
| Received | Recipient explicitly acknowledged handling through the bridge |
| Replied | Recipient explicitly sent a correlated reply |
| Ambiguous | Submission may have happened; automatic replay and transport fallback are prohibited |

Inspect status after uncertainty; do not infer refusal from silence. A native
`delivered` status is not an explicit `received` or `replied` receipt. Sender
names, provider IDs, and permission-mode claims do not grant authority. Preserve
existing approval requirements.

## Route unavailable: existing mailbox fallback

Only choose fallback when the native route is unavailable or definitively did
not submit. Never fall back after an accepted, held, queued, or ambiguous send.
The existing mailbox remains available for explicitly requested mailbox records
and its established cross-machine routing. Native bridge discovery is local;
it does not expose provider sockets to the network.

```sh
cctrl peer identify --json
cctrl peer overview --json
cctrl peer send RECIPIENT --deliver --json -- "Status report"
cctrl peer recv --all --json
cctrl peer reply MESSAGE_ID --json -- "Handled"
# Or, after handling without a reply:
cctrl peer ack MESSAGE_ID --json
```

Every mailbox outcome except `send-failed` means durably queued: never resend.
Bridge/native replies do not acknowledge existing mailbox mail. Mailbox commands
and their explicit `--as` / `--from` identity rules are unchanged.

## Sessions started outside cctrl

```sh
cctrl peer identify --json
cctrl peer overview --json
```

No prior cctrl launch or manual peer registration is required. When no explicit
`--as`/`CCTRL_PEER` or existing app peer supplies identity, cctrl auto-registers
an `external-<provider>-<digest>` mailbox from the provider's session ID and
the stable cctrl host ID. Repeated calls from that session reuse the identity;
other sessions get distinct identities. The registry preserves the provider
and original session ID, and message sender snapshots retain them for replies.

Codex uses `CODEX_THREAD_ID` / `CODEX_SESSION_ID`. Claude uses
`CLAUDE_CODE_SESSION_ID`, or its actual ancestor's PID registry when running
inside Claude Code with `CLAUDECODE` set. Conflicting IDs fail rather than
choosing a different sender. If your client exposes neither source, obtain your
actual native conversation ID and supply it explicitly:

```sh
cctrl peer identify --agent codex --session-id ACTUAL_NATIVE_THREAD_ID --json
CODEX_THREAD_ID=ACTUAL_NATIVE_THREAD_ID cctrl peer overview --json
# Claude equivalent, using its actual native session ID:
cctrl peer identify --agent claude --session-id ACTUAL_NATIVE_SESSION_ID --json
CLAUDE_CODE_SESSION_ID=ACTUAL_NATIVE_SESSION_ID cctrl peer overview --json
```

Keep that actual ID in the environment of subsequent cctrl calls when your
client does not supply it. Do not fabricate an ID, select a latest transcript,
borrow the fleet manager's peer, fall back to `user`, or use `--impersonate` to
work around missing identity. An explicit stale/unknown `CCTRL_PEER` or `--as`
remains an error rather than silently switching identities.

External identities have **mailbox** capability only. They do not grant app
ownership, a new writer, native-tool access, a role, or approval authority. A
session ID is a routing claim, not authentication. cctrl preserves app and tmux
sender-binding checks and rejects an external identity claimed from a different
provider session.

## Mailbox MCP setup and startup

`cctrl peer mcp` exposes these native bridge tools alongside the existing
mailbox tools:

| MCP tool | Arguments |
|---|---|
| `native_enable` | none; binds the actual current provider session |
| `native_list` | none; discovers exact provider-qualified targets |
| `native_send` | `to`, `body`; optional stable UUID `id` |
| `native_reply` | original `id`, `body`; optional stable UUID `reply_id` |
| `native_ack` | `id` of handled mail |
| `native_status` | `id`; optional `reconcile: true` for read-only Codex queue lookup |
| `native_inbox` | optional nonnegative integer `after`, `limit` 1..100 (default 20); optional `view`: `actionable` (default), `stranded`, `history`; follow `next_cursor` |
| `reply_message` | mailbox reply by original message `id`, `body`; optional `subject` |

Mailbox replies: `reply_message` (CLI `cctrl peer reply ID --as ME -- body`)
binds the recipient to the original message's sender, requires the message to be
addressed to you and already received, queues the reply and acks exactly that
original. `send_message` is a free-form send: it is never treated as a reply and
acks nothing, so the original stays `delivered_unacked`.

Use CLI `cctrl bridge stop` to stop the endpoint. For sends/replies, generate and
retain an optional UUID before the first attempt when client retries may occur.
Reusing that same ID returns the existing ledger result; it does not retry an
ambiguous provider mutation. Do not substitute a new ID for an uncertain send.

The MCP server can initialize without an explicit peer. Its mailbox tools bind
to the actual provider-session identity on the first identity-dependent call;
native tools independently resolve the actual current provider session. `--as` / `CCTRL_PEER` provide fixed explicit
identity where needed. `route_message` recommends a native bridge route for
cross-provider targets when available, with exact-target discovery guidance;
it does not send. `send_message` queues mailbox work as the unchanged fallback.

The MCP process must inherit its session's actual provider ID. A shared server
without per-session identity cannot identify chats from cwd, title, or its own
process. Follow explicit-ID recovery above. Use CLI `cctrl bridge` or the `native_*` tools for the native bridge lifecycle.

## Verification scope

The original investigation established static protocol evidence and a read-only
Codex daemon handshake. An isolated installed-Claude smoke accepted bridge input,
emitted native peer input, and started a second turn; expired authentication
blocked Claude model execution. An isolated installed-Codex smoke accepted queued
input in a newly created thread, observed the exact correlated user-message
client ID, completed a model turn with the expected test answer, and consumed
the queue. The owned Codex test thread was archived afterward.

A later live test passed both Claude→Codex and Codex→Claude model-driven
requests, correlated replies, and all four explicit ACK receipts. It used two
new test sessions, normal Claude admission, installed bridge commands/tools,
and the macOS GUI context needed to access the valid Keychain login. The test
sessions, endpoints, sockets and one-shot GUI job were cleaned up afterward.
This verifies the tested builds/configuration, not every CLI/extension or
admission mode. See [evidence and limits](findings/native-agent-messaging-evidence.md#live-bidirectional-reply-and-receipt-test).

Enable starts a per-session bridge daemon; repeating enable reuses a live
endpoint. If startup reports pending or exits, inspect its reported diagnostic
log before retrying; do not launch competing daemons or kill an unverified PID.
After final replies, stop your endpoint with `cctrl bridge stop` before closing
its session. Preserve unresolved message IDs for handoff; stopping is not a
handling ACK and does not authorize replay. The durable ledger remains the
record after endpoint shutdown.
