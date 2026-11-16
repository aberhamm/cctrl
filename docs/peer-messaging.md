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

## Receive, reply, and inspect receipts

```sh
cctrl bridge inbox --limit 20
# If next_cursor is non-null, fetch the next page:
cctrl bridge inbox --after NEXT_CURSOR --limit 20
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
| `native_inbox` | optional nonnegative integer `after`, `limit` 1..100 (default 20); follow `next_cursor` |

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

These verify Claude ingress/wakeup and Codex queue-to-model execution in the
tested configurations. A full real Claude↔Codex model-driven reply/ACK round
trip remains blocked by Claude login. Isolated module/subprocess tests and a
simulated two-direction integration verify plumbing, not every provider
configuration. See [evidence and limits](findings/native-agent-messaging-evidence.md).

Enable starts a per-session bridge daemon; repeating enable reuses a live
endpoint. If startup reports pending or exits, inspect its reported diagnostic
log before retrying; do not launch competing daemons or kill an unverified PID.
After final replies, stop your endpoint with `cctrl bridge stop` before closing
its session. Preserve unresolved message IDs for handoff; stopping is not a
handling ACK and does not authorize replay. The durable ledger remains the
record after endpoint shutdown.
