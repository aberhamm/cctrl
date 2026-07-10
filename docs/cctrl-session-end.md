# Session End — graceful shutdown doctrine

The canonical doctrine for **gracefully winding down** a cctrl-managed agent session
is the skill itself — a single source of truth, no duplicated copy to drift:

➡️ **[`skills/cctrl-session-end/SKILL.md`](../skills/cctrl-session-end/SKILL.md)**

It covers the pre-close checklist (uncommitted work, unsent drafts, context save),
completion reporting, the `cctrl close` self-close command, fleet-manager integration
(session-close gate), and the handoff-then-close pattern for context-limit sessions.

This is the counterpart to `cctrl-spawn` — spawn gets you in, session-end gets you
out cleanly.

See also: [`skills/README.md`](../skills/README.md).
