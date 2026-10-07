# Repo Orchestrator — role doctrine

The canonical doctrine for the **repo orchestrator** role (the per-repository
orchestrator that reports to the fleet manager) is the skill itself — a single
source of truth, no duplicated copy to drift:

➡️ **[`skills/cctrl-repo-orchestrator/SKILL.md`](../skills/cctrl-repo-orchestrator/SKILL.md)**

It covers the role model (two kinds of orchestrator, the ask rule and exit 78),
manage-and-delegate, briefs as the only guardrail, the approvals file as a
non-writer, quiet status-file reporting, the two-worker pattern for large phases,
the close gate, restore / `reconcile-names` cautions, and handing off its own
session.

The doctrine is deliberately free of environment specifics (cctrl is public).

See also: [`skills/README.md`](../skills/README.md) and the top-level counterpart,
[`docs/cctrl-fleet-manager.md`](./cctrl-fleet-manager.md).
