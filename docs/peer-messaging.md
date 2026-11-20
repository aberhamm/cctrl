# Agent messaging across Claude Code and Codex

Use `cctrl bridge` for native cross-provider messages and Codex-to-Codex input.
Claude-to-Claude messages use actual Claude `ListAgents`/`SendMessage`. For wire formats and evidence, see the
[protocol overview](findings/native-agent-messaging-protocols.md). Fleet authority
and approvals follow the [agent contract](../AGENTS.md#peer-messaging) and
[selected role skill](../skills/README.md).

## Cross-session messaging setup

Claude Code decides whether to admit a message from another session by
comparing permission-mode classes (bypass versus prompting). cctrl starts every
Claude in bypass mode, and a Codex-to-Claude bridge send always claims the
prompting class. So a cctrl worker and a normal-mode session, or a Codex sender
and any cctrl-spawned Claude, are in different classes, and Claude holds the
message until a person approves it. Desktop, VS Code and `claude -p` cannot show
the dialog, so a held message there is dropped after `dialogExpiry` (5 minutes by
default). Held is not failed; the bridge reports `held_for_approval`.

The fix is Claude's `crossSessionInbound` setting (`accept`, `hold` or
`refuse`). `cctrl peer setup` sets it for you after a version check and a
trade-off prompt. `cctrl peer doctor` reports whether it took effect.

### `cctrl peer setup`

```sh
cctrl peer setup [--scope user|spawned|both] [--value accept|hold|refuse|unset]
                 [--dir PATH] [--dry-run] [--yes] [--override-user] [--json]
```

| Scope | Writes | Covers |
|---|---|---|
| `user` (default) | `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json` | every session you run, Desktop and VS Code included, and the sessions cctrl spawns (user settings still apply to them) |
| `spawned` | cctrl config key `messaging.claude.crossSessionInbound` | the Claude sessions cctrl starts, through their `--settings` overlay; your own sessions are unchanged |
| `both` | both of the above | both |

Behaviour that applies to every scope:

- **Safe write.** The file is parsed as JSON and only the one key changes, so other keys
  and their order are kept. The write is atomic (same-directory temp file, fsync,
  `os.replace`), under a lock, and a symlinked file is written through to its
  target. Before a change, an exact copy is saved as
  `settings.json.cctrl-backup-<UTC>`.
- **Invalid JSON is refused**, never read as `{}`. The file is left byte-identical
  and setup exits 1. `cctrl hooks install` and `cctrl statusline claude install`
  follow the same rule.
- **Idempotent.** A second run with the same value prints `unchanged`, exits 0,
  and makes no backup and no write. `--value unset` removes the key, so
  Claude's per-class default applies again.
- **Warnings come before the question.** Version, managed, project, local and
  invalid-value findings and the trade-off text print first; then the
  confirmation (`--yes` skips it, and is required when stdin is not a terminal).
  `--dry-run` prints the same and writes nothing. `--json` carries the trade-off
  text in a `trade_off` field.
- **Exit codes.** 0 done or unchanged, 1 refused, 2 Claude Code too old, 3 managed
  override, 64 usage, 65 not confirmed.

### Precedence, and why stricter wins

Claude resolves `crossSessionInbound` in this order (settings reference):

1. **Managed settings** (macOS managed preferences, else the managed-settings
   file and `managed-settings.d/*.json`) win over everything. An invalid managed
   value counts as `refuse` (v2.1.248 and later). Server-managed settings cannot
   be read locally; setup and doctor report them as `unknown`, never as clear.
2. The **`--settings` overlay**, then **user settings**: the first value found.
3. A **project or local** value (`<repo>/.claude/settings.json`,
   `settings.local.json`) applies only when it is stricter than the above
   (`refuse` over `hold` over `accept`). With no trusted value at all, a project
   or local `hold` or `refuse` replaces the per-class default.
4. An **unrecognised value** in a user, project, local or overlay file forces
   `hold`, even when a higher source says `accept`.

Setup therefore checks before it writes. A managed value that overrides yours
makes setup stop with exit 3 and write nothing. A stricter project or local value
is reported as applying in that repo only (`--dir`, default the current
directory) and does not block a user write. An invalid value anywhere is named by
file.

Setup also reports two effective values with their sources: one for "a cctrl
spawn in DIR" (overlay plus user) and one for "a session you start yourself in
DIR".

### Managed settings

Setup and doctor read, read-only:

- macOS: `/Library/Managed Preferences/<user>/com.anthropic.claudecode.plist`,
  then `/Library/Managed Preferences/com.anthropic.claudecode.plist`, converted
  with `plutil -convert json -o -`; then
  `/Library/Application Support/ClaudeCode/managed-settings.json` and
  `managed-settings.d/*.json`.
- Linux: `/etc/claude-code/managed-settings.json` and `managed-settings.d/*.json`.

`managedSourcesBehavior: merge` in the plist merges it with the file. Tests point
the readers at fixtures with `CCTRL_CLAUDE_MANAGED_DIR` and
`CCTRL_CLAUDE_MANAGED_PLIST_JSON`. cctrl never writes a managed source.

### Version gate

| Claude Code | Result |
|---|---|
| below 2.1.224 | refused: no cross-session messaging (`claude update`) |
| below 2.1.232 | warns: no `/config` row "Messages from your other sessions" |
| below 2.1.248 | warns: an invalid value is silently ignored instead of handled as documented |
| 2.1.248 and later | no version finding |
| not found, unparseable or a pre-release | needs `--yes` |

The key's own first version is undocumented, so 2.1.224 is the messaging floor,
not a verified first-key version.

### Spawned scope and `--override-user`

`messaging.claude.crossSessionInbound` lives in cctrl's merged config
(defaults, legacy, user, then `data/config.local.json`; later wins). It is unset by
default. At each launch cctrl adds the key to the profile's `--settings`
overlay; a launch with no profile gets a key-only overlay, and no overlay file is
written when nothing applies. `cctrl peer setup --scope spawned|both` reads
the merged config the same way a spawn does. It prints the value in force and the
file it came from, and **refuses (exit 1, naming the file)** when
`config.local.json` sets the key, or when `--value unset` cannot remove a value
that a lower file sets. Edit that file by hand in those cases.

Because `--settings` outranks user settings, an overlay `accept` could override a
user `hold` or `refuse`. It does not, unless asked. At every launch and restart
cctrl keeps the stricter of the two (`refuse` over `hold` over `accept`): when the
user value is stricter than the configured one, the overlay omits the key and cctrl
prints one warning naming `--override-user`. `--override-user` (spawned or both
scope) writes `messaging.claude.overrideUser: true`, which lets the overlay
override a user value. Only the JSON boolean `true` counts; any other value
warns. Running setup again without `--override-user` removes it.

**Restart limit.** Spawned scope applies to new launches only. A running session
keeps the overlay it started with, even after a later change. `cctrl restart`
refreshes the overlay for a session that already has one (a profile session, or
one started with the key set) and drops a stale key. A session started with no
profile and no overlay has no `--settings` flag, and a restart does not add one,
so it picks the value up only when you close it and start a new one. This fails
closed: such a session simply keeps Claude's default.

### `cctrl peer doctor` messaging checks

Read-only. Each check is `{name, ok, status, summary, remedy}` in `--json`;
`status` is `pass`, `warn` or `fail`, and `ok` is false only for `fail`. A missing
opt-in is a warning, because `accept` is a choice. Every remedy for a Claude
check ends with `on another Mac: cctrl --host ALIAS peer setup --yes` for each
other registered host.

| Check | Warns or fails when | Fix |
|---|---|---|
| `claude_cli_version` | version below 2.1.224 (fail), 2.1.232 or 2.1.248 (warn), or not readable | `claude update` |
| `claude_inbound_own_sessions` | no value is set, so Claude's per-class default decides | `cctrl peer setup --scope user` |
| `claude_inbound_spawned` | the value for a cctrl spawn is not `accept` | `cctrl peer setup --scope spawned` (or `user`) |
| `claude_inbound_managed` | a managed value overrides, or is invalid (fail) | ask the administrator to change the managed settings |
| `claude_inbound_project_stricter` | a project or local file in the repo is stricter | edit that file |
| `claude_inbound_invalid` | an unrecognised value or unreadable settings file (fail): inbound mail is forced to `hold` | fix or remove the key in the named file |
| `claude_isolate_peer_machines` | `isolatePeerMachines` is `true` anywhere | remove it from the named file |
| `claude_dialog_expiry` | `dialogExpiry` or the dialog-timeout variable is not a positive value | set `dialogExpiry` to a positive value, or remove it |
| `codex_bridge_endpoints` | a live cctrl Codex session has no live bridge endpoint | run `cctrl bridge enable` inside that Codex session |
| `codex_bridge_orphans` | a bridge daemon belongs to an archived or missing Codex thread | the WARN counts only daemons whose Codex thread is archived or missing from the Codex state database; check the thread is really gone, then run `CODEX_THREAD_ID=<thread id> cctrl bridge stop`. Doctor never stops a daemon and never advises `kill`. Daemons whose thread is not archived (a Codex app thread, a hand-started codex) are listed on a separate passing check, `codex_bridge_unseen_owner`, as information |

Codex needs no admission setting. Bridge input enters through `thread/queue/add`
with no approval dialog (steer stays off by default and setup never changes
it). Codex needs a bridge endpoint so Claude can find it. A hook-driven
auto-enable for cctrl-started Codex sessions is not part of setup; see the
[auto-enable findings](findings/codex-bridge-auto-enable.md).

### Never set `isolatePeerMachines`

`cctrl peer setup` never writes `isolatePeerMachines`. Where it is `true`,
messages that cross machines wait for an approval prompt, and unattended bypass
workers would stall on it. Doctor warns when it is `true` in any scope.

### Remote Macs

The native bridge is local only. Each Mac reads its own settings, so each Mac
needs its own setup: `cctrl --host ALIAS peer setup --scope user --yes`. cctrl
never propagates the setting. Whether `accept` also governs messages arriving
from another machine through Remote Control is unverified; do not rely on it.

## Enable, discover, and send

The current bridge is local and POSIX-only: it does not expose a network
messaging service, and Windows fails closed when OS peer verification is
unavailable. Run enable inside each actual participating provider session:

```sh
cctrl bridge enable
cctrl bridge list
# From Codex to Claude: native, straight into the Claude's chat (an admission check may hold it):
cctrl bridge send claude:ACTUAL_SESSION_ID -- "Please review the result"
# --urgent is accepted and changes nothing; the mailbox is only a fallback when native is impossible:
cctrl bridge send claude:ACTUAL_SESSION_ID --urgent -- "Approve the rollback now"
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

### Codex to Claude: native by default, mailbox only as a fallback

A bridge send from a Codex session to `claude:SESSION_ID` goes **native**: straight into the
Claude's chat like a native message, with no mailbox hop and no wait for its turn end. The
recipient's approval check may hold it (the result says `held_for_approval: true` when it
does; held is not failed and is never replayed). `--urgent` (MCP `urgent: true`) is still
accepted and is now a no-op. This reverses the earlier mailbox-first rule (60c4425).

The mailbox is used only when native delivery is impossible **before anything is sent**.
The exact cases, all taken from a native row that FAILED with no write:

| Case | Where it comes from |
|---|---|
| The Claude has no live bridge endpoint, or its session is unavailable or ambiguous | `Daemon.target`: "Claude native session is unavailable or ambiguous; nothing submitted" |
| The recipient's peer key or connected identity did not match its process | `ClaudeEndpoint._send` raised before `writing` |
| The native text exceeds the input limit | `ClaudeEndpoint.send`: status `failed` |
| This session's bridge endpoint is not active | `ClaudeEndpoint._send`: status `failed` |
| This session's own bridge daemon cannot be reached or started, or is outdated (nothing was sent yet) | `ensure_daemon` or `check_daemon` raised in the CLI before the request |

Everything else stays native and is never resent through the mailbox: accepted, `submitted`,
`queued`, `held`, `released`, `denied`, `expired`, `refused`, `dropped`, `ambiguous`, an
unknown result, a timeout or a connection error while talking to the daemon, and any
`failed` row that also has an `ambiguous`/`submitted`/`queued`/`held` event. Reconcile those
with `cctrl bridge status ID --reconcile`.

- The fallback peer comes from `cctrl peer by-session claude:SESSION_ID`: the session
  id must be a live Claude (a `~/.claude/sessions` file with a live pid and
  matching start time) in a tmux pane whose session backs a registered Claude
  peer. The pane is matched by pane id and process ancestry, so a tmux session
  renamed after launch still resolves. Neither session records nor peer registry
  fields (`external_identity.session_id`, `provider_task_id`) are trusted. A Claude
  outside tmux has no mailbox fallback. Exactly one peer is required; zero or two
  means no fallback and cctrl never guesses a peer.
- The result says which way it went. Native: `"routed": "native"` plus
  `held_for_approval` and a note. Mailbox fallback: `"routed": "mailbox"`, `status: mailbox`,
  `mailbox_id` (the one to quote), `mailbox_peer`, `kind: routed`, and
  `fallback: {used: true, native_reason, native_id}`; the note says the Claude sees it when
  its current turn ends. If native failed and the mailbox cannot take it either, the failed
  native row comes back with `fallback: {used: false, native_reason, refused}`; nothing was
  delivered.
- The fallback leaves the failed native row (its own id) and writes a separate
  `kind: routed` row whose id is derived from the native id, so retrying the same `--id`
  can never write a second mailbox item. A routed row is not bridge work: `bridge ack` and
  `bridge reply` refuse it, and it never appears in `inbox` actionable or stranded. A row left
  `routing` (a crash between the ledger and the write) is refused until you check
  `cctrl peer outbox`.
- The Claude replies to fallback mail with `cctrl peer reply MAILBOX_ID -- "..."`, which sends to
  the Codex sender's mailbox identity and ACKs the original. The Codex reads it with
  `cctrl peer recv --all`. A bridge reply (`bridge reply ID`) is not the path for routed mail.
- Unchanged: Claude to Codex and Codex to Codex use the bridge. Claude to Claude
  stays rejected.
- The mailbox send runs `cctrl peer send` as the calling Codex session, with the
  body on stdin, so sender identity, sealing and the push gate are those of an
  ordinary mailbox send. No `--deliver` is added.

Codex-to-Claude bridge sends conservatively declare **prompting**
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

`cctrl bridge retire --handled [--dry-run] [--json]` sweeps the backlog: it
finds this session's received messages (`received` or `replied` set, status
`queued` or `ambiguous`) with no final native retirement and asks the daemon's
retire-only action to retire each one. That action never ACKs, replies or sends
a receipt, so a sweep creates no new messages. It only touches queue items this
bridge submitted (persisted queue ID plus message ID). It needs a daemon with
the `retire_handled` capability (protocol 3); an older daemon is refused with
`daemon-outdated` (`--dry-run` reports `daemon_outdated`). `--dry-run` reads the
ledger only and lists the IDs. Output (text by default, JSON with `--json`):
`candidates`, `outcomes` (count per `native_retirement.outcome`), `skipped_ids`
(no persisted queue identity: run `bridge status ID --reconcile`) and
`error_ids` (the daemon call failed or was refused: rerun the sweep or
`bridge ack ID`). A failed item never aborts the run; the command then exits 3 (partial run), 0 when every row succeeded, 1 when refused.

**Admission gate.** `bridge ack` and `bridge reply` refuse (exit 1, error says
the message is not admitted) while the status is `held`, `refused`, `denied`,
`expired` or `dropped`. A refusal sends no receipt and no reply and does not
mark the message handled. `inbox --view stranded` rows for those statuses carry
`admitted: false` and the body is replaced by `[NOT ADMITTED: body withheld ...]`;
`history` and `status` still show the stored text for inspection only.

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

Codex recipients have no delivery signal, so the ACK records what the retirement
outcome proves: `already_consumed` adds `late-native-delivery-after-handled`
(`late_native_delivery: true`, the item reached the model while being handled);
`absent`, `race`, `unknown`, `identity_mismatch` and `unknown_identity` add
`late-native-delivery-possible` (`late_native_delivery_possible: true`, the item
may still surface later as user input). Each marker is written once; neither
marker changes handling, and neither can remove text the model already received.

## Steer: correcting a running Codex turn

`--steer` injects text into the recipient's **running** Codex turn
(`turn/steer`) instead of queuing it for the next turn. Use it only to correct
or stop work already in flight, never for status, an acknowledgement or a
report (the message budget in AGENTS.md says the same).

```sh
cctrl bridge send codex:THREAD_ID --steer -- "Stop: use the staging table, not prod"
cctrl bridge reply MESSAGE_ID --steer -- "Wrong branch, switch to main"
# Recipient, once, in its own shell (the default is off):
cctrl bridge enable --accept-steer
cctrl bridge policy --steer allow --steer-from ACTOR   # or: --steer off ; no --steer shows it
```

**Scope: Codex app threads only.** A steer reaches only a thread the shared
Codex app server has loaded and that reports direct input (in practice the
Codex desktop app). A cctrl tmux worker and a CLI Codex run their own
in-process server, so they are never loaded there and **always queue**, exactly
as before. A sub-agent thread does not accept direct input and queues too.
`--steer` to `claude:*` is refused before anything is stored ("steer applies
only to Codex recipients; nothing sent"), and `--steer` with `--urgent` is a
usage error, so a steer never turns into a mailbox send.

**Both sides opt in.** The sender passes `--steer` (MCP `native_send` /
`native_reply` `steer: true`) on each message. The recipient sets a standing
policy for its own endpoint (`bridge policy`, `bridge enable --accept-steer`);
only the endpoint's own actor can set it, the allow list matches the routing
actor, and `bridge list` shows each policy. No policy row means off. A steer
confers no approval authority; its wire header carries `delivery=steer`.

**When a steer is not used, the message is queued, never refused.** The result
carries `steer.outcome` and a plain reason:

| outcome | why it queued |
|---|---|
| `declined` | recipient policy is off, or the sender is not in its allow list |
| `stale` | the row was older than 60 s at dispatch (for example after a daemon restart) |
| `rate_limited` | more than 1 steer per sender and recipient pair in 2 minutes |
| `not_loaded` | thread not loaded in the shared app server (tmux or CLI Codex), or it unloaded before the steer |
| `no_direct_input` | the thread does not accept direct input (for example a sub-agent) |
| `idle` | no running turn; the queue starts one |
| `busy_flag` | the turn waits on an approval or user input |
| `turn_unknown` | the active turn could not be read |
| `stale_turn` | the turn changed twice during the attempt |
| `unknown` | the thread state could not be read |

A steer never calls `turn/start`, `turn/interrupt`, `thread/resume` or
`thread/queue/start`. A policy skip is the first and only submission, not a
fallback after a possible send.

**Ledger statuses for a steer.**

| status | meaning | what to do |
|---|---|---|
| `steered` | the server accepted it into the active turn; not queued | wait; cctrl checks the turn history for the message ID |
| `queued` | not steered (see the outcome above); delivered by the normal queue | as any queued message |
| `lost` | accepted, but the text never appeared in the turn's history (for example the turn ended or was interrupted first). **Not requeued**: that would replay an accepted send | resend only if it still matters |
| `ambiguous` | transport failed after the steer was written; no retry and no queue fallback; cannot be reconciled (no queue item to look up) | ask the recipient, or resend with a note that it may be a duplicate |

`lost` means "not found in the steered turn" (a steer that landed in a later turn would also read as lost; this is not measured).
`lost` is a stranded, non-handleable row: its body is withheld and it cannot be
ACKed. `steered` messages are reply-ackable like `queued` ones; `bridge retire`
treats them as final with no queue item to delete. `steered` is not proof of
delivery: the server accepts a steer sent during an approval wait and can drop
it, which is why cctrl never steers a flagged turn and confirms by the message
ID (`clientUserMessageId` returns as `userMessage.clientId`).

A steer needs a protocol 4 daemon with the `steer` capability; an older daemon
refuses only `--steer` (`daemon-outdated`), and plain sends keep working. See
[bridge-daemon-migration.md](bridge-daemon-migration.md).

## Receipts are control facts

A receipt (`[cctrl-bridge receipt ... control=true]`) tells the original sender
that the recipient explicitly handled a message. It is not work: it is stored
as `kind: receipt`, born handled, never dispatched, never listed by the default
or `stranded` inbox views (only `history`), and cannot be ACKed, replied to, or
sent as a message (those return an error). Receipt submission is idempotent and
an ambiguous receipt is never replayed, so there are no receipt/ACK loops.

A receipt whose original sender is a Claude session is recorded but never
submitted natively: a native submit would raise an admission prompt on the
user's screen for a control fact. The ledger keeps a `receipt_attempts` row with
status `suppressed` and a `receipt-suppressed` event, so `bridge status` and the
inbox `history` view still show that the receipt happened. Receipts to Codex
senders are still submitted (a queued item, not a prompt). The only Claude-side
evidence of handling is therefore the ledger, not a message in the pane.

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

Result shapes: `bridge inbox --json` returns `{actor, view, messages, next_cursor,
...}`; `view` echoes the requested view (`actionable`, `stranded` or `history`).
`bridge send` and `bridge reply` make one read-only `thread/read` round trip to the
Codex app server before sending (the sender envelope, above); a failure there only
leaves the fields `unknown`. Native ingress text that starts with
`[cctrl-bridge receipt ` is classified as a receipt (a control fact, born handled,
never dispatched) by its prefix, not by an explicit kind, so such a body from a
native sender is stored as a receipt and is not shown as work.

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
# Retire stale Codex queue copies of messages already handled:
cctrl bridge retire --handled --dry-run
cctrl bridge retire --handled
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
cctrl peer send RECIPIENT --json -- "Status report"
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

After upgrading cctrl, an endpoint enabled earlier keeps its old daemon; `send`, `ack` and `reply` are refused with `daemon-outdated` until you migrate it. See [bridge-daemon-migration.md](bridge-daemon-migration.md).

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
