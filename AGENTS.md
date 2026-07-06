# cctrl — agent instructions

cctrl is a CLI for managing Claude Code agent sessions (fleet view, per-session
state, profiles, costs, peer messaging). See [README.md](./README.md).

## Fleet roles

Two reusable orchestration roles ship as generic, environment-agnostic **skills**
(single source of truth — the invocable skill *is* the doctrine). Read the relevant
one before acting as that role:

- **[skills/cctrl-fleet-manager/SKILL.md](./skills/cctrl-fleet-manager/SKILL.md)** — orchestrate
  a fleet of concurrent cctrl sessions: monitor → decide → sequence, delegate all
  hands-on work (incl. validation), the two-mode autonomy model (auto-pilot /
  manual) with its always-confirm set and session-close gate, tmux driving gotchas,
  resource gating, and the handoff/startup-hang lessons.
- **[skills/cctrl-fleet-watcher/SKILL.md](./skills/cctrl-fleet-watcher/SKILL.md)** — an hourly
  stack-health sentinel that investigates and dispatches fixer agents but never
  self-fixes prod.

`docs/cctrl-fleet-manager.md` and `docs/cctrl-fleet-watcher.md` are thin pointers to these
skills; `skills/README.md` explains the symlink-into-skillshare setup. The skills
contain **no environment specifics** (no hostnames, URLs, IPs, tokens, ports, or
repo names) — cctrl is public. The concrete per-environment config (probe
endpoints, service inventory, SSH map) and the standing role briefs live only in the
operator's private infra repo.

## Skill routing

See [CLAUDE.md](./CLAUDE.md) for skill-routing rules.
