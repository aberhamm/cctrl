# cctrl skills

Reusable, environment-agnostic role skills that ship with cctrl. Each is the
**single source of truth** for its doctrine — the invocable skill and the public
reference are the same file, so there is nothing to keep in sync.

| Skill | Role |
|---|---|
| [`fleet-manager`](./fleet-manager/SKILL.md) | Orchestrate a fleet of concurrent cctrl sessions: monitor → decide → sequence, delegate all hands-on work, a two-mode autonomy model (auto-pilot / manual) with an always-confirm set and session-close gate. |
| [`fleet-watcher`](./fleet-watcher/SKILL.md) | An hourly stack-health sentinel that investigates and dispatches fixer agents but never self-fixes prod. |

## How these load as skills

These directories are the source. To make them live as agent skills, symlink each
into your skill host — e.g. skillshare:

```sh
ln -s ~/dev/cctrl/skills/fleet-manager ~/.config/skillshare/skills/fleet-manager
ln -s ~/dev/cctrl/skills/fleet-watcher ~/.config/skillshare/skills/fleet-watcher
```

(This mirrors how mstack skills are symlinked from `~/dev/mstack/skills/`.) The
symlink is a filesystem artifact; the version-controlled copy lives here. Edit the
doctrine here and every symlinked host picks it up instantly.

`docs/fleet-manager.md` and `docs/fleet-watcher.md` are thin pointers back to these
files, so the `docs/` reference path still resolves.

## The public/private boundary

These skills contain **no environment specifics** — no hostnames, URLs, IPs,
tokens, service ports, channel names, or repo names (cctrl is a public repo). The
concrete per-environment config (probe endpoints, service inventory, SSH map,
security-regression probes) and the standing role briefs live only in the
operator's **private** infra repo. Keep it that way: change doctrine here, change
environment there.
