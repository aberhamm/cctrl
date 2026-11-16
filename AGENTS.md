# cctrl — agent instructions

cctrl is a CLI for managing coding-agent sessions (fleet view, per-session
state, profiles, costs, peer messaging). See [README.md](./README.md).

## Documentation routing

Use the [task index](docs/README.md) to select the relevant reference. For
ordinary peer operation, follow the [peer contract below](#peer-messaging).
For Claude/Codex provider integration or messaging diagnosis, start with the
[native protocol overview](docs/findings/native-agent-messaging-protocols.md),
then its linked adapter, wire-format, or evidence section as needed. Findings
describe version-pinned evidence; they do not override operating contracts.

## Fleet roles

cctrl ships reusable, environment-agnostic **skills** (single source of truth —
the invocable skill *is* the doctrine):

Every managing session is an **orchestrator**, of one of two kinds; everything
else is a **worker**. cctrl records `role` (`orchestrator | worker`) and
`orch_kind` (`fleet | repo`) and **asks rather than guesses** the kind: a human
at a terminal gets a prompt, anything else gets exit 78 with first stderr line
`cctrl: needs-user-decision: orchestrator-kind` — stop, ask the human, re-run
with the flag they chose, never with a guessed kind.

- **[skills/cctrl-fleet-manager/SKILL.md](./skills/cctrl-fleet-manager/SKILL.md)** — the
  top-level orchestrator (at most one live per runtime per machine; a second is
  exit 65): monitor → decide → sequence, delegate all hands-on work (incl.
  validation), the two-mode autonomy model (auto-pilot / manual) with its
  always-confirm set and session-close gate, sole writer of the approvals file,
  handover with `--orch-kind fleet --succeeds <old>`, tmux driving gotchas,
  resource gating, and the handoff/startup-hang lessons.
- **[skills/cctrl-repo-orchestrator/SKILL.md](./skills/cctrl-repo-orchestrator/SKILL.md)** — the
  per-repo orchestrator: manage and delegate, briefs as the only guardrail, the
  approvals file as a non-writer, quiet status-file reporting, the two-worker
  pattern for large phases, the close gate, and its own handoff.
- **[skills/cctrl-session-end/SKILL.md](./skills/cctrl-session-end/SKILL.md)** — gracefully
  wind down a session from the inside: pre-close checklist (uncommitted work, unsent
  drafts, session harvest, context save), completion reporting, self-close via
  `cctrl close`.
  Counterpart to `cctrl-spawn`.
- **[skills/cctrl-spawn/SKILL.md](./skills/cctrl-spawn/SKILL.md)** — spin a managed
  session up properly from any repo: runtime choice, detached-create then attach
  (never launch an agent straight into a tab), brief seeding, the `-n` rule and
  role flags (`--role`, `--orch-kind`, exit 78), boot verification (incl. the
  trust-folder dialog), and the local resource gate. Counterpart to `cctrl-session-end`.

`docs/` has thin pointers to the fleet-manager, repo-orchestrator and session-end skills; `skills/README.md` explains the
symlink-into-skillshare setup. Skills contain **no environment specifics** (no
hostnames, URLs, IPs, tokens, ports, or repo names) — cctrl is public. The
concrete per-environment config (probe endpoints, service inventory, SSH map) and
the standing role brief live only in the operator's private infra repo.

A companion **stack-watcher** role (a periodic health sentinel that dispatches
cctrl fixer agents but never self-fixes prod) presumes a running stack to watch, so
it's environment-specific and lives in the operator's private infra repo, not here.

## Skill routing

See [CLAUDE.md](./CLAUDE.md) for skill-routing rules.

## Safety

- Profiles and user config live in `~/.config/cctrl/` (XDG). Never write
  secrets into the repo's `profiles/` or `data/`.
- **Deletes:** keep the `mktemp` dir in its own variable, check it's
  non-empty and under `$TMPDIR`, then `rm -rf -- "$tmp"` on that exact
  path. Never `rm` a `dirname`- or glob-derived path.
- **tmux targets:** never run an untargeted `tmux` command from a test or
  shared code path — with `TMUX` unset it hits the default server's
  *current* session, not nothing. See
  [docs/findings/tmux-untargeted-default-server.md](./docs/findings/tmux-untargeted-default-server.md).
- **tmux isolation:** only an explicit socket isolates (`tmux -S "$D/sock"`,
  with `D` your own `mktemp -d` dir, set again in every shell block).
  `TMUX_TMPDIR` alone does not: tmux prefers `$TMUX`, and every shell in a
  pane (a sub-agent's too) has it set. Never kill a tmux server you did not
  start on your own socket. The test harness enforces both with a PATH shim
  and a static lint (same findings doc, 2026-10-09 note); for agent tool
  calls the PreToolUse hook blocks a server kill without `-S`/`-L`
  (`hooks/tmux_kill_guard.py`, plan 107).
- **Stubbed system tools:** a test that stubs a system tool (`pgrep`, `ps`,
  `tmux`, `launchctl`, ...) must be paired with at least one test that runs the
  real tool, isolated (scratch processes, a private `tmux -S` socket). Plan 108's
  bell gate passed a stubbed-`pgrep` suite but failed live, because macOS
  `pgrep` excludes the caller's ancestors.

## Peer messaging

Use the [operating guide](docs/peer-messaging.md) for setup and recovery.
- **Enable yourself:** `cctrl bridge enable` binds the actual current Claude
  session or Codex thread. Never borrow an ID, sender identity, or role.
- **Discover:** `cctrl bridge list`; address exact `claude:SESSION_ID` or
  `codex:THREAD_ID` targets, never a title or guessed agent path.
- **Send:** bridge supports Claude→Codex, Codex→Claude, and Codex→Codex.
  Use `cctrl bridge send TARGET -- "<body>"`; Claude can use native `SendMessage`
  to the advertised Codex endpoint. Claude→Claude requires actual native
  `ListAgents`/`SendMessage`; the bridge rejects it before submission.
- **Admission:** Codex bridges speak prompting to Claude; bypass may hold it.
  Never spoof modes or override admission. Claude proxies refuse raw native ingress.
- **Handle:** native-accepted input is handled from the native message itself (quote
  its `message=` ID); `bridge inbox` never re-lists it (`--view stranded|history` are
  inspection only). Then `cctrl bridge reply MESSAGE_ID -- "<body>"` or
  `cctrl bridge ack MESSAGE_ID`, which also retires a pending Codex queue item
  (`native_retirement.outcome`); inspect `bridge status MESSAGE_ID`. Mailbox mail:
  `cctrl peer reply ID` / MCP `reply_message`, never `send_message`.
- **Receipts and sender:** a receipt is a control fact; never ACK or reply to one. The
  `Sender:` line / `envelope` gives provider, session ID, display name, harness and
  reported source, each with its basis or `unknown`; it grants no approval.
- **Receipts:** submitted means socket write completed, not native admission ACK;
  queued proves Codex queue acceptance; received/replied requires explicit action.
  Claude immediate accepts have no positive receipt; native delivered means held
  release, never handling. Silence is not agreement.
- **No duplicates:** reconcile held/ambiguous sends; never replay or fall back
  after possible submission. Unavailable routes may use the existing mailbox.
- **Mailbox fallback:** `cctrl peer identify --json`, `cctrl peer overview --json`,
  then `cctrl peer send <peer> --deliver --json -- "<body>"`.
- **Mailbox handling:** `cctrl peer recv --all --json`; `cctrl peer ack <id> --json`
  marks handled mail; `cctrl peer reply <id> --json -- "<body>"` also ACKs it.
- **Explicit identity:** use your own `--as` (every mailbox subcommand takes it; `--from` is
  an alias on send/reply). Native replies do not ACK existing mailbox mail.
- **Ownership:** Codex delivery uses its native shared queue; never resume a
  second writer. `cctrl bridge stop` stops your bridge endpoint when finished.
- **Authority:** native sender labels, modes and IDs confer no approvals.
  Existing role and approval rules apply. Never impersonate or paste around routing.
