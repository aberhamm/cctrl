# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased] - 2026-07-31

Peers became addressable as live agents, not just mailboxes: direct tmux chat by
peer name, a one-call orientation command, atomic reply, and an inline delivery
that no longer dead-ends the message lifecycle. Plus a docs and help-surface
catch-up, and a cost-reporting fix for anyone whose username isn't the author's.

### Added
- `cctrl peer say <peer> [--no-submit] [--force-busy] [--body-file PATH|-]
  [--json] -- <message>` is direct **live tmux chat** addressed by peer name or
  alias — the peer-addressed form of `session say`, sharing all its flags and its
  readiness/modal guard. It never writes `data/messages.jsonl`, never changes
  mailbox status, and never records nudge metadata. The companion
  `cctrl peer session <peer> [--json]` resolves a peer to its backing session
  (`{ok, name, label, session, tmux_target, host, live, status}`) and
  `cctrl peer attach <peer>` attaches to it. A peer whose `.host` is not this
  machine is refused with a `cctrl --host <host> peer …` hint rather than
  auto-SSHing from registry metadata, and human `cctrl peer ls` now shows each
  peer's backing SESSION with live/offline status by default (JSON unchanged).
- `cctrl peer overview [--as NAME] [--json]` is the orientation entry point: one
  call answers who you are, who you can reach, and whether you have unread mail
  (`{queued, delivered_unacked, oldest_queued_age_seconds}`), served from a
  single session enumeration instead of composing `whoami` + `list_peers` +
  `check_messages`. A matching `peer_overview` MCP tool passes through to it, and
  all eight pre-existing peer MCP tool descriptions were rewritten as
  workflow-aware instructions that cross-reference their siblings — no tool names
  changed.
- `cctrl peer reply <message-id> [--as NAME] [--subject TEXT]
  [--body-file PATH|-] [--no-ack] [--json] -- <body>` sends, delivers, and acks
  the original in one command, resolving the recipient from the referenced
  message's `sender` snapshot — so a replying agent never needs the sender's
  address. `cctrl peer send` gained `--deliver` for the same send-then-nudge
  behavior. Both report five named outcomes rather than failing silently:
  `sent-and-nudged` and `sent-and-queued` (exit 0), `send-failed`,
  `sent-but-undelivered`, and `sent-but-deferred` (non-zero). A delivery failure
  never rolls the send back — the message stays queued and the hint says to retry
  **delivery only**, because re-running would duplicate it. `--allow-unknown`
  cannot be combined with `--deliver`. MCP `send_message` now delivers too and
  surfaces the same five states, with only `send-failed` mapping to `ok:false`.
- `cctrl peer help-agent [--as NAME] [--json]` prints the compact agent-facing
  contract: when to `peer say` (live tmux agent, act now), when to `peer send`
  (durable async), and the `peer recv` / `peer ack` loop. A bare invocation gives
  generic guidance and never fails for a missing identity; `--as` or
  `CCTRL_PEER` canonicalizes through the same resolver the mailbox uses and
  tailors the examples. The contract is deliberately **not** auto-injected —
  `cctrl start --peer` adds no prompt text, so an agent gets it only by asking.
- MCP tool `say_peer` (`to`, `body`, optional `submit` defaulting true, optional
  `force_busy`) — the tool-call form of `cctrl peer say`. The body is piped
  through `cctrl peer say --body-file -` so multi-line and trailing-newline
  bodies survive byte-for-byte. It creates no mailbox message and fails rather
  than queueing when the peer has no live local tmux session.
- The peer operating contract now lives in `AGENTS.md` (with a `CLAUDE.md`
  routing pointer), not only in README — agents auto-load the former and not the
  latter.

### Changed
- `cctrl start -d <dir>` adopts a matching shortcut's alias for the session name,
  so `cctrl start -d ~/dev/unstructured-data-portal` and `cctrl start -d @portal`
  produce the identical `TMUX--<device>--portal` name and therefore the identical
  remote-control bridge prefix. On collision the first key by sorted order wins
  (deterministic). A directory with no matching shortcut keeps its repo-folder
  slug, foreground launches are unaffected, and duplicate-name auto-increment
  still runs afterward.
- `cctrl help` now lists the verbs the messaging and maintenance loops actually
  depend on and previously omitted: `peer overview`, `peer check`, `peer recv`,
  `peer reply`, `session say`, `session autoheal`, `session ls --recap`, and
  `start --profile` — the last being the flag the README leads with.
- `cctrl fleet`'s local resource header renders an unmeasurable probe as an
  explicit `n/a` instead of a bare `?`, so "this platform can't measure it" no
  longer reads as "the value is broken". The unit suffix travels with the number
  and is dropped alongside it. The Darwin `sysctl` parsing is unchanged.
- README documents the surface that shipped over the last month: `session
  doctor` / `autoheal` / `prune`, `session ls --recap` and the rich STATE column
  (with a sample regenerated from a fixture fleet rather than hand-written),
  `cctrl fleet`, `cctrl needs-me`, the low-memory launch guard, peer messaging in
  the feature list, and the fact that `ports` and `scan` are plugins rather than
  core commands.

### Fixed
- `cctrl costs` no longer hardcodes one machine's username when naming projects.
  `claude_project_name` matched the literal strings `-Users-matthew--projects-`
  and `-Users-matthew-`, so on any other machine — or any other home directory —
  every Claude project fell through to its raw encoded path. The encoded `$HOME`
  prefix is now derived at runtime, and `codex_project_name` lost its matching
  hardcoded `~/_projects/` special case.
- `cctrl peer deliver <peer> --inline <message-id>` no longer strands the message
  as `queued` forever. Inline delivery previously pasted the raw body with no
  sender context and never transitioned status, so `cctrl peer ack` — which
  rejects queued messages — could never complete the lifecycle. The paste now
  carries a compact envelope (sender label and canonical name, message id,
  optional subject, and ready-to-run `peer reply` and `peer ack` lines) and moves
  the message to `delivered` with a `delivered_at`. Sender reachability is
  resolved at delivery time: live and mailbox-only senders get a reply line, a
  dead or unresolvable one gets `SENDER IS NO LONGER LIVE` and no reply command,
  and a `from == "user"` sender routes the reply out of band. The body still
  arrives byte-for-byte after a `---` separator, and legacy messages carrying only
  a bare `from` fall back to that.
- `cctrl peer say` rejects `--as` and `--from` at the peer-say level with a
  message pointing at `cctrl peer send`, instead of forwarding them to the
  internal `session say` and leaking `Unknown session say flag: --as`. `peer say`
  has no sender identity, so the flags were never meaningful. The flag scan stops
  at `--`, so a message body that mentions `--as` is not misread.
- `peer session`, `peer say`, and `peer attach` report their own failures again.
  The first two called the resolver bare under `set -e`, so an unresolvable,
  remote, or stale peer aborted `cctrl` before the error JSON or message printed;
  `peer attach` returned the exit status of its error-printer (always 0), so a
  non-local or unknown peer printed the hint and exited **successfully**.
  `peer session` also stopped colorizing the name, so `name -> target` is one
  contiguous copyable string.
- `cctrl save`, `cctrl rename`, and `cctrl edit` force profiles to mode `600`.
  There was no `chmod` anywhere in `cctrl`: `save` wrote through a plain shell
  redirect and landed at the ambient umask, commonly `0644`. Profiles routinely
  carry `PORTKEY_API_KEY` and `ANTHROPIC_CUSTOM_HEADERS`, so a live key was
  readable by every local account — for about two and a half months. `rename`
  carried the source mode across with `mv` and `edit` lost the mode to
  write-and-replace editors, so all three write paths needed it.

<!-- commits: a028d2b, d77d4f6, ad314dd, ee048b2, d0464c5, be93bd0, b90d621, 1ec2638, 55de8ee, f7db9ab, d82260b -->

## [Unreleased] - 2026-07-26

Direct session messaging, durable sender identity on peer mail, bundled role
skills, and a cost-reporting correction.

### Added
- `cctrl session say <session> -- "message"` pastes an exact message straight
  into a live tmux session and submits it, without touching peer mailbox state
  — the direct live-chat path alongside `peer send`'s durable async mailbox.
  `--no-submit` skips the Enter, `--body-file PATH|-` sends multi-line bodies,
  and `--json` reports `{ok, session, submitted, status}`. A visible
  Claude/Codex approval modal is a hard stop that `--force-busy` won't override.
- Peer messages now carry a `sender` snapshot (name, label, tmux target, agent,
  host), so you can still tell who wrote a message after the sending session
  has closed — previously `from:` held only an ephemeral tmux name that became
  unresolvable. `peer show` and the inbox render the sender's label; legacy
  messages without the snapshot still display.
- Three bundled skills, invocable from any repo: `cctrl-spawn` (launch a
  managed session properly — runtime choice, detached-create then attach, brief
  seeding, boot verification, resource gate), `cctrl-session-end` (wind a
  session down cleanly: pre-close checklist, harvest what only that session
  knows, then self-close), and `cctrl-fleet-manager` (orchestrate many
  concurrent sessions under a two-mode autonomy model). All are
  environment-agnostic; pair them with a private brief for host specifics.

### Changed
- `cctrl-fleet-manager` doctrine (1.1.0) folds in three operational lessons:
  verification runs in both directions (verify triage claims before writing
  them into a dispatch brief, and write briefs so the receiving agent may
  refuse a wrong order); the brief is the only guardrail, since spawned
  sessions typically run with permissions bypassed, so every prohibition must
  be written in explicitly; and the `unsent-draft` session state carries no
  signal in either direction — only a pane or transcript read confirms whether
  a real draft is sitting in the input line.

### Fixed
- `cctrl` now actually detects an unsent draft in a Claude Code pane. The
  detector anchored on ASCII `>` while Claude Code's input line starts with `❯`
  (U+276F), so it never fired on a real pane — leaving two consumers silently
  inert: `session autoheal`'s draft safety gate ran unguarded (a scheduled
  `C-u` could wipe typed-but-unsent text), and the `unsent-draft` state never
  appeared in `session ls`. An empty input box still never reads as a draft.
- Cost reporting no longer overstates Opus spend by ~3x. The pricing table was
  still on Opus 4.1-era rates ($15/$75 per M tokens); Opus 4.5 through Opus 5
  are all $5/$25, with cache at $6.25/$0.50. Haiku was likewise still on Haiku
  3.5 rates and is now Haiku 4.5 ($1/$5, cache $1.25/$0.10). Because the rate
  keys match on model-name prefix, historical Opus 4.x rows are repriced too.

<!-- commits: 805299d, 42b097f, 943df6a, 8fa8086, 128854b, 1b10a29, e81c290, 9895abb, d7e539e, 7f7cd1e -->

## [Unreleased] - 2026-07-04

Session-title enforcement and a launch-time memory guardrail, both from a
fleet-management incident where friendly names hid the tmux session id and
too many heavy sessions exhausted RAM.

### Added
- `cctrl start` now enforces the tmux session id in every Claude Code pane
  title. The `--name` that reaches the agent is always the resolved tmux
  session id (`TMUX--…`); when a `--purpose`/`-n` description exists the title
  leads with it, e.g. `Plan: reference mstack plans by name (TMUX--ms--mstack)`,
  falling back to the bare id otherwise. The remote-control prefix and
  `session doctor` name-alignment continue to use the bare id.
- A friendly `-n`/`--name` on `cctrl start -d` is now recorded as the session
  **purpose** (shown in `session ls`) instead of leaking as the agent's
  `--name` — it no longer diverges from the tmux session id.
- `cctrl start` checks free memory before launching and refuses (with a clear
  warning, current numbers, and a `-f`/`--force` or `CCTRL_FORCE=1` override)
  when the machine is genuinely low on RAM. It uses the same metric as the
  fleet monitor (macOS `memory_pressure` free percentage); it gates on memory
  only, not session count, and factors swap when free RAM is already low.
- `cctrl fleet` prints a `local: mem …% free · swap …MB used · load … · N
  sessions` line for at-a-glance local health.

### Fixed
- `cctrl peer deliver` no longer silently misroutes a queued message to a
  different session that has taken over the recipient's tmux session name. A
  tmux name doubles as a mailbox address and freed name slots are reused, so a
  resumed or brand-new session can inherit a name and receive mail meant for the
  name's previous occupant — including hard-holds and corrections meant for
  someone else. Delivery, `peer recv`, and `peer inbox` now withhold a message
  whose current occupant was created after the message was sent: it is marked
  `addressee-replaced` (or `addressee-ambiguous` when the timestamps tie or the
  message stamp can't be parsed) and the sender is told, instead of the wrong
  session silently acting on it. Sessions with no recorded creation time (manual
  peers) and already-queued mail are unaffected.
- `cctrl session ls` and `cctrl peer ls` now identify a session's agent by its
  process name rather than scanning the whole command line, so a Claude session
  whose prompt happens to mention `codex` (or a `~/.codex/...` path) is no
  longer mislabeled `codex`. This was not cosmetic: the agent field selects
  which approval-modal pattern `peer deliver` scans for, so a mislabeled Claude
  session could have a delivery nudge pasted into an open modal. The agent
  runtime is now also recorded in session metadata at spawn.
- `cctrl peer deliver` no longer silently defers messages to Claude sessions
  that are emitting normal output. The claude modal-detector grepped the pane
  for `. 1\.` — whose `.` is a regex any-char, not the intended `❯` arrow — so
  it matched any markdown numbered list (which fleet-manager sessions emit
  constantly), plus bare `Do you want`/`Do you trust` prose. It now anchors on
  the modal's highlighted selection line `❯ 1.`, precise for all three Claude
  proceed/trust/permission modals.
- The same guard's codex branch is fixed too. Its markers
  (`Allow command`/`Approve`/`y/N`) were doubly wrong: `Allow command` never
  matched a real Codex modal (the header is ``Allow Codex to run `…` ``), while
  bare `Approve`/`y/N` false-flagged normal prose and shell `[y/N]` prompts.
  Verified against the Codex CLI TUI, it now anchors on real modal text:
  `Allow Codex to …`, the network-access prompt, and the `tell Codex what to do
  differently` option line (Codex modals have no `❯` cursor to key off).

## [Unreleased] - 2026-07-02

Fleet management: accurate session recency, real per-session state, and
triage/repair tooling for running many concurrent agent sessions.

### Added
- `cctrl session ls` now shows an accurate **last-active** time per session,
  sourced from the live Claude transcript instead of tmux terminal activity
  (which went stale when a session was driven remotely or finished quietly).
  Rows sort most-recently-active first.
- `cctrl session ls` now shows a **STATE** column: `working`/`idle`/`shell`,
  plus richer states — `waiting-input`, `blocked-dialog`, `unsent-draft`, and
  `idle-done` — so you can tell at a glance which sessions actually need you.
  (Each detector fails safe to the base state; toggle individual detectors with
  `CCTRL_STATE_DETECT_*`.)
- `cctrl session ls --recap` surfaces each session's one-line recap (what it's
  about) from the transcript's compact-summary; shows `-` when none exists.
- `cctrl session prune` proposes stale and never-used sessions for closing.
  Dry-run by default (`--yes`/`--close` to act); `--older-than 7d` to tune
  staleness. Never-prompted detection is agent-aware (Claude transcripts and
  Codex rollout logs) and never flags a busy session.
- `cctrl fleet` gives one unified view of sessions across all your machines,
  sorted by last-active, with offline hosts marked inline.
- `cctrl session autoheal` repairs dead remote-control bridges, with an opt-in
  `autoheal install` launchd timer. It skips busy sessions and never touches a
  session with an unsent draft.
- `cctrl needs-me` reports only the sessions that *newly* went waiting,
  blocked, or finished since you last looked — ideal for a phone glance.
- `cctrl session doctor --fix` can now **realign** sessions whose tmux and app
  names have drifted, relaunching them with `--resume` so the conversation is
  preserved (skips busy/copy-mode; report-only prints a copy-paste hint).

### Fixed
- Launching a detached session can no longer clobber a live session: index
  assignment now skips any name held by a live tmux session (and reuses freed
  indices instead of sprawling). Previously `cctrl start -d @shortcut` could
  overwrite a running session.

<!-- commits: 8cd755c, 7aada2c, 5a3867d, 9103294, 4dbab80, afc3163, 77f55a2, d1fccb6, b1b5d4f, 5f05bc9 -->
