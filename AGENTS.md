# cctrl — agent instructions

cctrl is a CLI for managing Claude Code agent sessions (fleet view, per-session
state, profiles, costs, peer messaging). See [README.md](./README.md).

## Fleet roles

cctrl ships reusable, environment-agnostic **skills** (single source of truth —
the invocable skill *is* the doctrine):

- **[skills/cctrl-fleet-manager/SKILL.md](./skills/cctrl-fleet-manager/SKILL.md)** — orchestrate
  a fleet of concurrent cctrl sessions: monitor → decide → sequence, delegate all
  hands-on work (incl. validation), the two-mode autonomy model (auto-pilot /
  manual) with its always-confirm set and session-close gate, tmux driving gotchas,
  resource gating, and the handoff/startup-hang lessons.
- **[skills/cctrl-session-end/SKILL.md](./skills/cctrl-session-end/SKILL.md)** — gracefully
  wind down a session from the inside: pre-close checklist (uncommitted work, unsent
  drafts, session harvest, context save), completion reporting, self-close via
  `cctrl close`.
  Counterpart to `cctrl-spawn`.

`docs/` has thin pointers to each; `skills/README.md` explains the
symlink-into-skillshare setup. Skills contain **no environment specifics** (no
hostnames, URLs, IPs, tokens, ports, or repo names) — cctrl is public. The
concrete per-environment config (probe endpoints, service inventory, SSH map) and
the standing role brief live only in the operator's private infra repo.

A companion **stack-watcher** role (a periodic health sentinel that dispatches
cctrl fixer agents but never self-fixes prod) presumes a running stack to watch, so
it's environment-specific and lives in the operator's private infra repo, not here.

## Skill routing

See [CLAUDE.md](./CLAUDE.md) for skill-routing rules.
