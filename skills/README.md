# cctrl skills

Reusable, environment-agnostic role skills that ship with cctrl. Each is the
**single source of truth** for its doctrine — the invocable skill and the public
reference are the same file, so there is nothing to keep in sync.

| Skill | Role |
|---|---|
| [`cctrl-fleet-manager`](./cctrl-fleet-manager/SKILL.md) | Orchestrate a fleet of concurrent cctrl sessions: monitor → decide → sequence, delegate all hands-on work, a two-mode autonomy model (auto-pilot / manual) with an always-confirm set and session-close gate. |
| [`cctrl-session-end`](./cctrl-session-end/SKILL.md) | Gracefully wind down a session from the inside: check for uncommitted work, save context/handoff, report completion, then self-close. Counterpart to `cctrl-spawn`. |

## How these load as skills

These directories are the source. To make them live as agent skills, symlink each
into your skill host — e.g. skillshare:

```sh
ln -s ~/dev/cctrl/skills/cctrl-fleet-manager ~/.config/skillshare/skills/cctrl-fleet-manager
ln -s ~/dev/cctrl/skills/cctrl-session-end   ~/.config/skillshare/skills/cctrl-session-end
```

(This mirrors how mstack skills are symlinked from `~/dev/mstack/skills/`.) The
symlink is a filesystem artifact; the version-controlled copy lives here. Edit the
doctrine here and every symlinked host picks it up instantly.

`docs/cctrl-fleet-manager.md` is a thin pointer back to this file, so the `docs/`
reference path still resolves.

A companion **stack-watcher** role (a periodic health sentinel that investigates
failures and dispatches cctrl fixer agents but never self-fixes prod) is
environment-specific — it presumes a running stack to watch — so it lives in the
operator's private infra repo, not in this public repo.

## The public/private boundary

These skills contain **no environment specifics** — no hostnames, URLs, IPs,
tokens, service ports, channel names, or repo names (cctrl is a public repo). The
concrete per-environment config (probe endpoints, service inventory, SSH map,
security-regression probes) and the standing role briefs live only in the
operator's **private** infra repo. Keep it that way: change doctrine here, change
environment there.
