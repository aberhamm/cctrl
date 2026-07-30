---
id: 048
title: Spawn and close coherence — brief contract, close safety, leak fix
status: pending
blocked-by: []
priority: 20
goal: revised-cctrl-audit-backlog
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-30
reviews:
  - type=eng verdict=approved date=2026-07-30 by=mstack-review
---

## Requirements

The spawn skill creates permission-bypassed sessions without saying so, and
its brief template doesn't produce what the fleet-manager doctrine assumes.
Concretely: (1) `cctrl start` defaults to `bypassPermissions` — the
fleet-manager skill calls briefs "the only guardrail," yet `cctrl-spawn` (the
skill that performs the spawn) never mentions it; (2) the brief template lacks
the fleet-managed contract ("report done and wait; don't self-close"), wiring
to the ask channel that already exists (AGENTS.md's `## Peer messaging`, plan
026 — shipped), and the self-contained-questions rule that prevents most
manager-can't-answer situations (plan 047's Tier 2); (3) close safety is
"check `git status`" — but the fleet's own learned doctrine is that work can
live only in the conversation, so the thread must be read before closing, and
the manager-side "ask the session for cleanup/doc opportunities before
closing" rule exists nowhere in the public skills; (4)
`skills/cctrl-spawn/SKILL.md` references `~/dev/homelab/fleet/spawn-env.md` —
a private infra repo name in a public repo, violating the skills' own
no-environment-specifics boundary (skills/README.md also names `~/dev/mstack/`);
(5) the skills index is incomplete: cctrl-spawn is missing from the
skills/README table and AGENTS.md's fleet-roles list.

**Acceptance criteria:**

- [ ] `cctrl-spawn` states the bypassPermissions default prominently and derives the rule: every prohibition must be written into the brief; where plan 038's tool-boundary policy mechanism exists, the brief additionally references the session policy file as the enforced layer (briefs advise; 038 enforces).
- [ ] The brief template gains three mandatory elements: (a) fleet-managed contract — report completion and wait, never self-close, never push unless told; (b) ask-channel wiring — the channel itself already exists (AGENTS.md's `## Peer messaging`, plan 026), so the brief tells the spawned session to use that contract toward the manager: block in waiting-input for a sync ask; for an async ask **initiate** with `peer send --deliver <manager> …` (`peer reply` only answers a received message id — it cannot initiate). This works only if the manager itself holds a peer identity (started with `--peer` or registered via `peer register`): `cctrl start --peer` names only the **child's** identity, so the brief must name the manager's peer identity explicitly; (c) self-contained questions — include findings, attempts, and the exact choice needed.
- [ ] Close safety in both manager-facing skills upgrades from "check git status" to: read the session's recent transcript/pane AND ask the session itself for cleanup/doc-update opportunities before any non-throwaway close. The closer distinguishes the two classes using the session-close gate's existing exemption wording: **ephemeral throwaways with no work product** (liveness/health probes, read-only scout/validator sub-agents, context-fetchers) stay exempt; anything not clearly in that class is a work session and gets the full treatment.
- [ ] The `~/dev/homelab/...` reference is replaced by a neutral placeholder (e.g. `<your-private-infra-repo>/fleet/spawn-env.md`); skills/README's `~/dev/mstack/` mention is generalized the same way.
- [ ] skills/README's table and AGENTS.md's fleet-roles list include cctrl-spawn.
- [ ] Environment-specifics scan comes back clean, scoped to the files this plan edits (the three SKILL.md files, `skills/README.md`, and this plan's AGENTS.md additions), with repo-self-references (e.g. `~/dev/cctrl` in the top-level README) explicitly allowed. The scan runs **after** this plan's own leak fix — run today it would fail on the pre-existing `~/dev/homelab` reference, which is exactly the thing being fixed.
- [ ] Version bumps + changelog lines per the skills' convention.

## Design

Doctrine-only, and **not blocked by 038**: the leak fix, index fix, and
close-safety work stand alone, and the brief's policy-layer reference is
conditional by design — "where plan 038's mechanism exists, reference it" — so
nothing here waits on 038 shipping (038 is priority 10 and exists because a
brief-only prohibition already failed once — the ~44 GB deletion incident).

Coordinate with 038 (same doctrine, two writers): 038's Task 6 also writes
brief-vs-policy doctrine into AGENTS.md and the cctrl-spawn skill. **This plan
owns the brief-template sentence** ("briefs advise; the policy layer enforces"),
and that sentence must carry 038's own stated limits — opt-in, string
classification bypassable via shell indirection, no visibility into MCP tools
("a guardrail, not a jail") — so briefs never overstate what the policy layer
enforces. Whichever plan lands second rebases.

Coordinate with 037 too: 037 rewrites session-end's "Check for uncommitted
work" step (bare `git status` → `cctrl repo status`) — the very wording this
plan's close-safety criterion quotes. Whichever lands second rebases that
sentence.

Boundary rule of thumb for the leak fix: cctrl's own subcommands and generic
paths are fine; any path or name that identifies the operator's other repos is
not.

Coordinate with 047 (same SKILL.md files, different sections): 047 owns the
manager's answering side; this plan owns the spawned-session side (brief) and
close mechanics. Land in either order; whichever lands second rebases.

**Files expected to change:**

- `skills/cctrl-spawn/SKILL.md`: bypassPermissions statement, brief template additions, placeholder fix
- `skills/cctrl-fleet-manager/SKILL.md`: pre-close ask + read-the-thread close safety
- `skills/cctrl-session-end/SKILL.md`: cross-reference the manager-side pre-close ask (inside view already exists)
- `skills/README.md`: cctrl-spawn row, `~/dev/mstack` generalization
- `AGENTS.md`: cctrl-spawn in the fleet-roles list

**Testing approach: unit-only** — structural greps.

**Out of scope:** implementing 038 itself; the Q&A triage section (047); any
change to `cctrl start` defaults (a separate decision, deliberately not made
here); private-repo brief content.

## Tasks

1. Write the bypassPermissions section and the three brief-template elements into cctrl-spawn.
2. Replace the private-path references with placeholders (spawn SKILL.md, skills/README.md).
3. Add manager-side pre-close ask + read-the-thread rule to fleet-manager; cross-reference from session-end.
4. Add cctrl-spawn to skills/README table and AGENTS.md.
5. Environment-specifics scan; version bumps.

## Verification

Checks:

- `[assert] cat skills/cctrl-spawn/SKILL.md` contains `bypassPermissions`
- `[cmd] bash -c '! grep -rn "~/dev/homelab" skills/'`
- `[cmd] bash -c '! grep -rn "~/dev/mstack" skills/README.md'`
- `[cmd] bash -c "grep -Eq '^\| \[.cctrl-spawn' skills/README.md"` — anchored on the row's FIRST cell (a `| [`cctrl-spawn`](...)` link), because both a plain substring check AND `^\|.*cctrl-spawn` pass today on the existing session-end row's "Counterpart to `cctrl-spawn`" prose
- `[cmd] bash -c "grep -Eq '^- .*skills/cctrl-spawn/SKILL.md' AGENTS.md"` — a fleet-roles list entry, for the same reason

<!-- mstack:seam
produced:
assumed:
-->
