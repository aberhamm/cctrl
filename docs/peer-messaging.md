# Agent messaging: native first, cctrl fallback

Use this operating guide to send messages and recover sender identity. For
wire formats and evidence, see the [protocol overview](findings/native-agent-messaging-protocols.md).
For fleet authority and approvals, follow the [agent contract](../AGENTS.md#peer-messaging)
and the selected [role skill](../skills/README.md).

## Choose the route

| Sender and recipient | Preferred route | Fall back when |
|---|---|---|
| Claude Code → Claude Code | `ListAgents`, then `SendMessage` to the exact discovered session; reply to its native `from` address | The tools or exact route are unavailable, or a send is definitively rejected before submission |
| Codex → Codex in one agent tree | Exposed collaboration tools; use the supported followup/wake operation for an idle target | Recipient is outside the tree or no applicable tool is exposed |
| Codex → another Codex desktop thread | Exposed cross-chat tools addressing the exact thread/host | The tool or exact thread route is unavailable |
| Independently launched Codex CLIs | cctrl mailbox unless the owning runtime exposes an actual native route | Separate processes do not share the internal collaboration mailbox |
| Different providers | cctrl mailbox | Native provider transports are not a cross-provider bridge |
| Explicitly requested durable mailbox record | cctrl mailbox | Keep its receive/handling-ACK lifecycle even if native messages also occur |

You can use native tools directly without registering a cctrl peer. When
starting from a cctrl name, `cctrl peer route <peer> --json` or MCP
`route_message` returns canonical identity, same-provider discovery guidance,
and fallback arguments. It **does not send**, verify native capability, or
invoke model-owned tools. The agent must confirm the exact native target in its
own runtime; a similar title or a guessed `/root/...` path is insufficient.

A native accepted, held, or ambiguous send must not be duplicated through
cctrl. Reconcile its result, wait for a correlated response, or report the
uncertainty. Native acceptance is not a handling ACK; silence is not agreement.

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

## Send and handle fallback mail

```sh
cctrl peer send RECIPIENT --deliver --json -- "Status report"
cctrl peer recv --all --json
cctrl peer reply MESSAGE_ID --json -- "Handled"
# Or, after handling without a reply:
cctrl peer ack MESSAGE_ID --json
```

Mailbox commands automatically resolve the caller identity. `--as` remains
available for your own explicitly registered peer; it is not needed for the
external-session default. `--deliver` includes existing cross-host routing and
notification behavior; a plain send can remain local queue-only.

Every result except `send-failed` means the mail was queued: never resend it.
Deferred/undelivered notifications do not undo that queue entry. The recipient
must receive and ACK handled mail. Replies sent through a native tool do not
ACK a pre-existing cctrl message automatically.

## MCP setup and startup

`cctrl peer mcp` can start without an explicit peer and responds to initialization
without discovery. It binds to the caller's identity on the first
identity-dependent tool call. `--as` / `CCTRL_PEER` still provide fixed explicit
identity where needed. `route_message` guides selection; `send_message` queues
fallback mailbox work. Neither impersonates a native runtime tool.

The MCP process must inherit its session's actual provider ID. A manually
configured shared server with no per-session identity cannot identify separate
chats by process, working directory, or title. Follow the explicit-ID recovery
above instead of attributing all chats to one shared server process.
