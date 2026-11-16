# Codex messaging wire reference

For bridge implementation or diagnosis. Start with the
[messaging overview](native-agent-messaging-protocols.md) to choose the right
surface and distinguish implemented cctrl behavior from bridge proposals.
Baseline: installed CLI/daemon `0.167.0` and version-matched public release
source, whose identity with the installed local build is unproven. Only daemon
initialization was verified live. [Evidence and limitations](native-agent-messaging-evidence.md).


## Internal collaboration

The version-matched release implements `send_message({target,message})` as
`QueueOnly` and `followup_task({target,message})` as `TriggerTurn`. Both require
known caller and recipient entries in the local runtime registry; a followup
cannot target the root. Addresses can be UUID thread IDs or relative/canonical
agent paths such as `/root/worker`.

`LocalAgentRuntime` shares an in-memory
`Mutex<Option<HashMap<ThreadId, Mailbox>>>` and Tokio watch notifications with
its agent tree. Messages also enter loaded-session operation queues. There is
no external mailbox file or global socket in this implementation for an
independently launched process to join.

The internal `InterAgentCommunication` envelope includes `author`, `recipient`,
`other_recipients`, `content`, and `trigger_turn`, with optional ID, encrypted
content, and internal metadata. Context rendering produces `Message Type`,
`Task name`, `Sender`, and `Payload` text. Copying that text into a user prompt
does not reproduce native identity, routing, or delivery.

## External App Server

The installed binary generated an experimental `ClientRequest` schema with 180
methods. It includes `turn/start` and `turn/steer`, but no request that joins
an external process to the internal inter-agent mailbox. The native `thread/queue/add`
input path is separate from that mailbox. The current cctrl bridge uses queued
input through the connected server's native shared queue and never resumes a thread to acquire its writer.

The bridge submits exactly once with a persisted correlation ID:

```json
{"id":2,"method":"thread/queue/add","params":{"threadId":"THREAD","clientUserMessageId":"BRIDGE_MESSAGE_ID","input":[{"type":"text","text":"Message"}]}}
```

The response's `queuedSubmission` supplies its native `id`, matching
`clientUserMessageId`, and input. `thread/queue/list` supports read-only
reconciliation. Queue absence does not prove that a submission failed: the
owner may already have consumed it. `clientUserMessageId` is correlation data,
not an established provider idempotency key. Neither operation resumes a thread
or acquires its history writer. Shared-store queue consumption by an independent
owner depends on provider support and liveness; successful insertion alone does
not establish that a particular CLI/extension consumed it. See
`lib/bridge_codex.py` for the current adapter.

The historical notification adapter used this external input sequence:

```json
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"cctrl","version":"1"},"capabilities":{}}}
{"method":"initialized","params":{}}
{"id":2,"method":"thread/read","params":{"threadId":"THREAD","includeTurns":false}}
{"id":3,"method":"turn/start","params":{"threadId":"THREAD","input":[{"type":"text","text":"Message"}]}}
```

That historical adapter resumes an eligible unloaded app-owned thread through
`thread/resume` before submitting input. This is **not** the native bridge path:
never resume a separately running CLI thread to deliver bridge mail. Steering
an active turn requires **`expectedTurnId`**, not `turnId`:

```json
{"id":4,"method":"turn/steer","params":{"threadId":"THREAD","expectedTurnId":"TURN","input":[{"type":"text","text":"Follow-up"}]}}
```

Both input methods expose optional `clientUserMessageId`; its presence alone
does not establish idempotency semantics. cctrl's existing adapter emits the
RPC envelopes above without a `jsonrpc` property.

CLI help advertises stdio, Unix-socket, and WebSocket listener modes.
WebSocket authentication supports capability-token and signed-bearer-token
modes. A newly started standalone server is not automatically the owner of a
thread already running in another CLI process. Use the existing owning server
and preserve writer-lock/ownership checks; never open a second writer just to
deliver input. See the [task lifecycle contract](codex-task-lifecycle-contract.md).

## Desktop app-tools pipe

The shipped app-tools bridge gets its endpoint from
`CODEX_APP_TOOLS_PIPE_PATH`. Each frame is a four-byte unsigned little-endian
payload length followed by that many bytes of UTF-8 JSON-RPC 2.0. The bridge
caps payloads at 8 MiB.

It requests dynamic definitions with `tools/list` and forwards calls through
`tools/call`; cancellation uses `tools/cancel`. Forwarded metadata includes
namespace, caller source, caller thread/turn/call IDs, and host identity where
applicable. `send_message_to_thread` appears in the delegation tool set, but
the host supplies its definition and handler. That name in the bundle does not
establish availability in every session. This investigation did not inspect
the host handler's delivery or ownership semantics.

This pipe is separate from both the App Server API and the internal agent-tree
mailbox. Their framing and initialization are not interchangeable.
