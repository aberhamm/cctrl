# Claude Code and Codex messaging protocols

Investigated 2026-11-16. These are version-pinned findings for cctrl bridge
design, not a declaration that undocumented provider interfaces are stable.
For current native bridge operation and external-session identity, follow the
[operating guide](../peer-messaging.md). The adapter inventory below records
the investigation baseline; the native bridge described in the operating guide
is a later implementation and does not change that historical evidence.

Claude Code exposes a local protocol for independently launched sessions.
Codex's native subagent mailbox belongs to a runtime's agent tree; external
clients use App Server or desktop host tools. Its native queue API is distinct
from the inter-agent mailbox. cctrl already has a durable
mailbox and notification adapters for both providers. Completing native
request/reply needs more than writing a prompt to either transport.

## Read only what you need

Baseline: Claude Code `2.1.325`, Codex `0.167.0`, and cctrl commit `6d4adc3`.
Protocol implementation findings are static/source-derived. The original phase
verified only the existing Codex daemon handshake live.
A subsequent isolated installed-Claude smoke verified native ingress/turn wakeup;
expired authentication blocked model-driven outbound messages and replies.
See [verification scope](native-agent-messaging-evidence.md#evidence-and-verification-scope) before relying on a
runtime or compatibility claim.

| Your question | Read next | Enough for this task |
|---|---|---|
| How do I send or ACK ordinary peer mail? | [Agent peer contract](../../AGENTS.md#peer-messaging), [peer commands](../../README.md#peers) | Use the existing mailbox contract; no wire-format reading is needed |
| Which provider surface can reach another session? | [Protocol map](#protocol-map) | Compare scope and transport |
| What does cctrl already do, and what is missing? | [Adapters and bridge gaps](#existing-cctrl-behavior-and-bridge-gaps) | Distinguish current behavior from proposed integration |
| How would a Claude native adapter send and receive? | [Claude protocol](native-agent-messaging-claude.md) | Discovery, framing, authority, and reverse receipts |
| How would a Codex adapter address a thread? | [Codex protocols](native-agent-messaging-codex.md) | Internal collaboration versus external input and desktop tools |
| How was a claim established or how can I refresh it? | [Verification scope](native-agent-messaging-evidence.md#evidence-and-verification-scope), [refresh procedure](native-agent-messaging-evidence.md#refreshing-the-findings), [sources](native-agent-messaging-evidence.md#source-and-evidence-references) | Version identities, limits, source offsets, and Evidence IDs |

For the wider documentation map, return to the [task index](../README.md).

## Protocol map

| Surface | Transport and addressing | Boundary |
|---|---|---|
| Claude independent sessions | UTF-8 JSONL; Unix socket on macOS/Linux, named pipe on Windows; registry-selected endpoint | Local cross-session input, status notifications, and replies |
| Claude teammates | Locked JSON-array inbox files, or a storage-provider path | Team mailbox; separate from the independent-session socket |
| Codex collaboration | Rust calls, operation queues, and an in-memory mailbox; runtime registry IDs/agent paths | Root agent and its subagents, not an external process mailbox |
| Codex App Server | JSON-RPC-style requests over supported stdio/Unix/WebSocket transports; thread IDs | External thread/turn input through the owning server |
| Codex desktop app tools | Length-prefixed JSON-RPC 2.0 over a local pipe; dynamic host tool calls | Desktop cross-chat tools, separate from App Server |
| cctrl peers | Durable JSONL mailbox and per-peer stdio MCP; canonical peer names | Common receive/reply/handling-ACK contract across runtimes |

## Existing cctrl behavior and bridge gaps

The implementation anchors below describe the investigated cctrl commit:

| Owner | Existing behavior | Remaining gap |
|---|---|---|
| `cctrl` peer mailbox | Durable `messages.jsonl`, canonical peer identity, receive/reply/ACK lifecycle | Keep this as the common record; native transport acceptance is not handling |
| `cctrl` Claude socket delivery | Finds `.messagingSocketPath`; sends a simple `type:user` frame; prompting-mode gate and tmux fallback | Does not provide the full native envelope, a reply endpoint, or native receipt correlation |
| `hooks/native-send-log.py` | Records native `SendMessage` metadata and keyed body fingerprints | Intentionally excludes bodies; cannot ingest or reconstruct native replies |
| `lib/codex_app_server.py` and `lib/codex_websocket.py` | Existing daemon via `codex app-server proxy`, HTTP Upgrade, RFC 6455 framing, initialize/initialized | External thread-input channel, not native collaboration membership |
| `lib/codex_peer_delivery.py` | Checks exact thread/cwd, ownership, version, archive/busy state; persists attempt receipts before `turn/start` | Sends mailbox notifications; busy tasks defer and app inline delivery is unsupported |
| `lib/peer_mcp.py` | Per-peer stdio MCP interface to the common mailbox | Common tools remain the receive/handling-ACK boundary across providers |

At the investigated baseline, the Claude socket frame is:

```json
{"type":"user","message":{"role":"user","content":"<mailbox notification>"}}
```

Its missing permission class explains why the adapter avoids bypass/unknown
recipients. Restoring a class field would not by itself establish delivery or
sender authority.

Codex notifications carry a `[cctrl-delivery:<attempt-id>]` marker. Persisted
receipts and user-message history reconcile ambiguous submissions; a lost
response must not cause blind replay. The server has no atomic start-only-if-idle
operation, so a preflight idle check can race with new app input. Existing
observed busy state defers; strict ordering is not guaranteed.

The bridge direction supported by this evidence is:

1. Keep canonical cctrl message IDs, sender identity, and queued/delivered/ACK
   states authoritative.
2. Resolve the runtime endpoint with fresh session/process or thread/owner
   evidence.
3. Deliver an ID-bearing notification through the relevant adapter.
4. For Claude native replies, own a vetted persistent callback endpoint and
   translate reply/status correlation into cctrl records without treating
   claimed native identity as authority.
5. Have the recipient use cctrl MCP/CLI to receive, reply, and ACK handled work.
   Preserve held, refused, deferred, and ambiguous outcomes separately.

These are the original bridge design implications at `6d4adc3`, not the current
feature inventory. The later [native bridge](../peer-messaging.md) owns a durable
ledger and a persistent Claude-compatible endpoint for each enabled Codex
thread. It translates native replies/status and submits Codex input through the
connected server's native shared queue API; it does not join the internal collaboration tree or
resume another writer. Existing peer mailbox commands remain a separate fallback
with their original receive/ACK lifecycle.

Native submitted/queued states do not establish model handling. Ordinary Claude
immediate admission sends no positive delivery receipt; its native delivered
status reports held-message release. Bridge received/replied stages require an
explicit recipient action. Ambiguous native submissions must not be replayed or
sent through fallback. Current implementation and live verification evidence
must be checked separately; the original read-only investigation and later ingress smoke did not establish
a complete real-provider bridge round trip.

The bridge supports Claude→Codex, Codex→Claude and Codex→Codex. Claude→Claude
uses actual native tools to preserve provider admission context; bridge sends
reject it before submission, and Claude actor proxies refuse raw native ingress.
Codex→Claude messages declare conservative prompting provenance, so a bypass
recipient may hold them. No spoofed mode or admission override is used.
