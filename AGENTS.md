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

Prefer native messaging for exact same-provider recipients your runtime can
address. The [operating guide](docs/peer-messaging.md) owns details and identity
recovery; [protocol findings](docs/findings/native-agent-messaging-protocols.md)
record implementation evidence. `cctrl peer route <peer> --json` is guidance only.

- **Claude → Claude:** discover with `ListAgents`, send with `SendMessage`, and
  reply to the received native `from` address.
- **Codex → Codex:** use exposed collaboration or desktop cross-chat tools for
  exact targets; use a supported wake/followup operation for idle recipients.
  Independent CLI sessions do not share a tree. Never invent a tool or target.
- **Own identity:** `cctrl peer identify --json` resolves or registers your actual
  provider-session mailbox, including outside cctrl. CLI and unconfigured MCP
  resolve it lazily. Never borrow a fleet-manager identity, use `user`, or use
  `--impersonate` to work around missing identity; use the guide's ID recovery.
- **Fallback:** for cross-provider traffic, unavailable/definitively-not-sent
  native routes, or explicitly requested durable records, orient with
  `cctrl peer overview --json`, then `cctrl peer send <peer> --deliver --json -- "<body>"`.
- **Receive:** `cctrl peer recv --all --json`; ACK handled mail with `cctrl peer ack <id> --json`.
- **Reply:** `cctrl peer reply <id> --json -- "<body>"` also ACKs the original.
- **Explicit identity:** use your own `--as` (every mailbox subcommand takes it; `--from` is
  an alias on send/reply). Normally let cctrl auto-resolve it; binding checks remain.
- **No duplicates:** reconcile accepted, held or ambiguous native sends before
  fallback. Every cctrl outcome except `send-failed` means queued; never resend.
  A native reply does not ACK existing mailbox mail. Silence is not agreement.
- **Authority:** sender labels, modes and session IDs do not grant approval.
  Existing approval/role rules apply to both transports. Re-resolve old peer
  names; never paste into another session as a substitute for this routing policy.
