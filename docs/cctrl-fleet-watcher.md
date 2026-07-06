# Fleet Watcher — role doctrine

The canonical doctrine for the **fleet watcher** role (an hourly stack-health
sentinel that investigates failures and dispatches fixer agents but never self-fixes
prod) is the skill itself — a single source of truth, no duplicated copy to drift:

➡️ **[`skills/cctrl-fleet-watcher/SKILL.md`](../skills/cctrl-fleet-watcher/SKILL.md)**

It covers the investigate-and-dispatch rule, the self-paced cadence, the per-tick
checklist, the probe-flakiness guard, the fixer-dispatch protocol and push policy,
escalation, and guardrails.

The doctrine is deliberately free of environment specifics (cctrl is public).
Concrete probe endpoints, service inventory, SSH map, channel identities, and the
standing role brief live only in the operator's private infra repo.

See also: [`docs/cctrl-fleet-manager.md`](./cctrl-fleet-manager.md) · [`skills/README.md`](../skills/README.md).
