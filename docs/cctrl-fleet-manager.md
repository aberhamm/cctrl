# Fleet Manager — role doctrine

The canonical doctrine for the **fleet manager** role (orchestrating a fleet of
concurrent cctrl-managed Claude Code sessions) is the skill itself — a single source
of truth, no duplicated copy to drift:

➡️ **[`skills/cctrl-fleet-manager/SKILL.md`](../skills/cctrl-fleet-manager/SKILL.md)**

It covers the core "manage, don't do hands-on work" rule, the two-mode **autonomy
model** (auto-pilot / manual) with its always-confirm set and session-close gate,
the monitor → decide → sequence loop, tmux driving gotchas, resource gating, and the
handoff / startup-hang lessons.

The doctrine is deliberately free of environment specifics (cctrl is public).
Concrete probe endpoints, service inventory, SSH map, and the standing role brief
live only in the operator's private infra repo.

See also: [`skills/README.md`](../skills/README.md). A companion stack-watcher
(sentinel) role is environment-specific and kept in the operator's private infra
repo, not here.
