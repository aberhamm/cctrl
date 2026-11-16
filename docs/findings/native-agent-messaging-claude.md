# Claude Code messaging wire reference

For bridge implementation or diagnosis. Start with the
[messaging overview](native-agent-messaging-protocols.md) to choose the right
surface and distinguish implemented cctrl behavior from bridge proposals.
This reference describes installed Claude Code `2.1.325`; findings are static,
with later live verification of native sends, correlated cross-provider replies,
and explicit ACK receipts in the tested macOS configuration.
[Evidence and limitations](native-agent-messaging-evidence.md#live-bidirectional-reply-and-receipt-test).


## Discovery and framing

Use `messagingSocketPath` from the selected process's session registry,
ordinarily `~/.claude/sessions/<pid>.json`. The registry advertises
`peerProtocol: 1` and features including `notify_idle`,
`reply_across_default_dirs`, and `artifact_yield`.

The normal socket location is
`(XDG_RUNTIME_DIR || Claude temporary directory)/cc-socks/<pid>.sock`, with a
long-path fallback under `/tmp/cc-socks-<uid>/`. These are descriptive defaults:
custom paths, moved-aside sockets, and process reuse mean PID-derived paths are
not sufficient endpoint identity.

Each native frame is UTF-8 JSON followed by a newline. A normal send has this
shape; placeholders are illustrative, not usable credentials or endpoints:

```json
{"type":"auth","token":"<recipient peer token>"}
{"msgV":1,"msg_id":"<uuid>","type":"user","message":{"role":"user","content":"<cross-session-message from=\"uds:/sender.sock\" from-name=\"bridge\" from-mode=\"prompting\">\nHello\n</cross-session-message>"},"priority":"next","from":"uds:/sender.sock"}
```

- `message.content` is a nonempty string, not a content-block array.
- `msgV: 1` and `msg_id` provide native envelope version and correlation.
- `from` is the reverse address. Native sender addresses use `uds:` plus the
  encoded socket path.
- Normal sends use `priority: "next"`; the receiver also handles `"now"`.
- Optional `session_id` must match the receiving conversation when supplied.
- Optional `uuid` is preserved only through explicit
  `--messaging-socket-path`; otherwise the receiver generates its transcript ID.
- The XML envelope also supports `from-session`, `hop-chain`, and `from-plugin`.
  File attachments follow a separate materialization path not covered here.

## Authentication, identity, and admission

The first frame can authenticate with the recipient's peer token. Authentication
is optional by default on macOS/Linux and required by default on Windows in
this build. Peer token metadata is published in a mode-`0600` file:

```text
~/.claude/sessions/<pid>.<sha256(canonical_socket_address)>.key
```

The metadata includes `peerToken` and may include process-start and PID-domain
information. The separately minted child token is inherited through
`CLAUDE_CODE_MESSAGING_TOKEN`; it is not interchangeable with the peer token.
No actual token values were collected in the findings.

Native endpoint checks include process identity where available, peer ownership,
and rejection of symlink reply targets. The receiver records verified process
identity separately from the claimed `from`. Sender labels and permission-mode
assertions must not be treated as authenticated authority.

For a normal user frame, the receiver obtains the sender's permission class
from **`from-mode` inside the XML content**, not a top-level `from_mode` JSON
property. Some control frames use the top-level property instead.

| Claimed sender class | Prompting recipient | Bypass recipient |
|---|---|---|
| `prompting` | Accept by default | Hold by default |
| `bypass` | Hold by default | Accept by default |
| Missing | Accept by default | Hold by default |

Explicit `crossSessionInbound: "accept" | "hold" | "refuse"` settings can
override this default; repository settings may tighten broader settings. Unknown
recipient mode holds messages, and feature gates can refuse reception. Other
admission controls include rate, duplicate, loop, and capacity checks. The held
queue is bounded at 100 entries in this build.

A bridge must represent its real provenance and authority. Adding a bypass
assertion merely to avoid a hold would not establish bypass authority.

## Receipts, replies, and idle notifications

The native sender does not consume a synchronous delivery ACK on the sending
connection. Successful write completion establishes neither model delivery nor
handling. Status messages return over a **new connection to the vetted `from`
address**, correlated by `orig_msg_id`:

```json
{"type":"control","action":"peer_message_status","status":"delivered","orig_msg_id":"<original uuid>","from":"uds:/recipient.sock","msgV":1,"msg_id":"<receipt uuid>"}
```

Observed status vocabulary is `held`, `denied`, `expired`, `delivered`,
`refused`, and `dropped`. Refusal can also be encoded as `status: "expired"`
with `status_detail: "refused"`. Dropped receipts may include `drop_reason`
and `dropped_msg_ids`. Ordinary immediate admission does **not** emit a positive
delivery receipt; native `delivered` reports release of a previously held
message. It still is not a cctrl handling ACK. A bridge must obtain explicit
received/replied acknowledgement instead of waiting for a positive receipt on
every accepted send.

Claude can reply with `SendMessage` to the sender address. A complete bridge
therefore needs a persistent inbound endpoint, verified routing ownership, and
mapping to the actual cctrl recipient. Arbitrary callback paths are not
automatically accepted: socket namespace and cross-default-directory reply
checks apply.

Idle subscription is a separate control operation:

```json
{"type":"control","action":"notify_when_idle","from":"uds:/sender.sock","msg_id":"<uuid>","from_mode":"prompting","msgV":1}
```

The reverse response uses `action: "peer_idle_notice"`, `orig_msg_id`,
`state`, and optional `finished_at`/`detail`. It is not a chat reply or a
handling acknowledgement.

## Teammates and tool routing

The disk teammate inbox is
`~/.claude/teams/<sanitized-team>/inboxes/<sanitized-agent>.json`. It contains
a JSON **array**, not JSONL. Entries require `from`, `text`, and `timestamp`;
optional fields include `type`, `read`, `color`, `summary`, `from_plugin`, and
native identity/signature metadata. Writers lock, append, and atomically
rewrite; current code also supports storage providers.

An in-memory provenance ledger, optional Ed25519 lead-entry signatures, and
replay/unverifiable-message handling mean direct inbox editing is not equivalent
to native delivery. The independent-session socket is the relevant cctrl bridge
boundary.

`SendMessage` multiplexes main/subagent, teammate, independent-session, and
remote routes. This build's general tool input uses `to`, `message`, optional
`summary`, and optional `notify_when_idle`; historical `type/recipient/content`
examples should not establish its current schema. Cross-machine Remote Control
and cloud routes are distinct from the local socket and were not investigated
at their wire boundary.
