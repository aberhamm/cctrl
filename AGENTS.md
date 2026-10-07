# cctrl — agent instructions

cctrl is a CLI for managing coding-agent sessions (fleet view, per-session
state, profiles, costs, peer messaging). See [README.md](./README.md).

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

## Peer messaging

Sessions coordinate through a local mailbox (`cctrl peer ...`). A peer identity
is a registry or derived **name** — for a tmux-backed session, the session name
itself. This is the operating contract; commands take real flags as shown.

- **Orient first:** `cctrl peer overview --json` answers who you are, who you
  can reach, and whether you have unread mail, in one call.
- **Receive:** `cctrl peer check --json` for counts, `cctrl peer recv --json`
  to take the next message, then `cctrl peer ack <id> --json` once handled.
  Unacked messages get re-nudged, so acking is not optional.
- **Reply:** `cctrl peer reply <message-id> --as <you> --json -- "<body>"`. It
  resolves the recipient from the message itself and both sends **and** delivers,
  so you never need the sender's address. Never reply with a bare
  `cctrl peer send` — send only **queues**, and nothing arrives until a deliver
  runs (no watcher runs by default). Always pass `--as`; a non-interactive shell
  may not export `CCTRL_PEER`.
- **Send:** find a peer with `cctrl peer overview` (or `cctrl peer ls`), then
  `cctrl peer send <peer> --as <you> --json -- "<body>"` and deliver it.
- Received messages carry a `sender` object; reply to `sender.name`.
- **Cross-machine:** `cctrl peer send` routes transparently across machines
  via SSH. Remote peers appear in `cctrl peer ls` / `cctrl peer overview` with
  a different host label — no special flags needed. The routing is automatic
  based on the peer's `host` field vs `CCTRL_HOST_PREFIX`.
- **Do NOT use Claude Code's built-in `SendMessage`/`ListAgents`** for peer
  messaging. Those tools discover peers through local `~/.claude/sessions/`
  files and cannot reach sessions on other machines. Always use the cctrl peer
  tools (`send_message` MCP tool or `cctrl peer send` CLI).
- **Limitation:** derived peer names are tmux session names, so an address can
  dangle once that session closes. Treat a `sender` snapshot as historical and
  verify liveness with `cctrl peer ls` before relying on it.
