---
id: 047
title: Fleet-manager Q&A triage doctrine — protocol-first, tools named
status: pending
blocked-by: [037, 042, 043]
priority: 19
goal: revised-cctrl-audit-backlog
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-30
reviews:
  - type=eng verdict=approved date=2026-07-30 by=mstack-review
---

## Requirements

The fleet-manager skill tells the manager to relay/decide agent questions and
forbids hands-on probing — but gives no path for acquiring context it lacks,
which is the operator's #1 recurring pain: a subagent asks something the
manager can't answer, and the doctrine models every question as a *decision*
(make it or relay it), never a *knowledge question*. Compounding it, the skill
never names the CLI's own messaging/monitoring verbs (`fleet`, `needs-me`,
`session say`, `peer reply` / `send --deliver`, and — after 042/043 —
`session key` / `session ask`), so managers improvise raw `send-keys`. The
agent-facing messaging contract itself already shipped: plan 026 (done) added
`## Peer messaging` to AGENTS.md (overview / check / recv / ack / reply /
send `--deliver`, plus the queue-vs-deliver rule), and CLAUDE.md routes to it —
so this plan **extends that shipped contract from the manager's side**; it does
not author a second one. And the handoff doctrine carries a real — though
narrower than a blanket disk-handoff ban — contradiction: session-end's
`## Fleet-manager integration` section already mandates report-and-wait for
fleet-managed work sessions, but its `## Handoff-then-close` step still
unconditionally self-closes, with no fleet-managed carve-out and no
manager-side step to capture the dying pane.

**Acceptance criteria:**

- [ ] `skills/cctrl-fleet-manager/SKILL.md` gains an "Answering agent questions" section with a three-tier triage:
  - **Tier 1 — policy/priority/scope:** the manager answers from its own fleet-level context; reply channel is `session say` (Mode A) or relay-with-recommendation (Mode B).
  - **Tier 2 — task-context questions, protocol-first:** the primary mechanism is one bounded re-ask via `session say`: "include what you found, what you tried, and the exact choice you need" — converting the question into Tier 1. Only when a re-asked question still needs deep context does the manager dispatch a read-only **context-fetcher sub-agent** (question verbatim + the asker's transcript path from `session ls --json` + its working dir → returns draft answer + confidence + citations). The section names the fetcher's known failure modes as checks the manager applies: secret leakage into a new prompt, confidence laundering of a weak answer, stale transcript.
  - **Tier 3 — one-way-door questions:** always escalate to the human; the tier **references** the skill's existing ALWAYS-CONFIRM set at the top of the triage — a composition pointer into the autonomy model, not a second copy of its list.
- [ ] The monitoring/messaging tools are named with their real invocations: `cctrl fleet`, `cctrl needs-me` (and `--peek` once 046 lands), `cctrl session say/key/ask`, `cctrl peer reply` / `peer send --deliver`. The raw `send-keys` driving guidance is replaced by `session say` for text and `session key` for dialogs, with the "pressing a dialog button can equal granting permission" policy note binding `key` usage to the ALWAYS-CONFIRM set.
- [ ] The new section **cross-references** AGENTS.md's `## Peer messaging` contract (plan 026, shipped) and **never restates the reply lifecycle** — no second, divergent copy of `--as`, ack rules, or queue-vs-deliver. Mailbox asks are answered with `cctrl peer reply <message-id>` per that contract; `session say` is the channel for pane-level replies to a session that asked by blocking in waiting-input.
- [ ] Secret handling for the context-fetcher is a stated rule, not a checklist mention: the fetcher returns a **paraphrase** plus citations (transcript line refs / file paths), never raw transcript blocks — and transcript content is never pasted into another session's brief or prompt.
- [ ] The handoff contradiction is resolved at its actual (narrower) scope: `cctrl-session-end`'s **existing** `## Fleet-manager integration` section — report-and-wait already lives there — is the text to **extend**, and the genuinely missing pieces land: a fleet-managed carve-out inside `## Handoff-then-close` (whose final step today unconditionally self-closes) plus the manager-side rule to capture the dying pane before close. Fleet-managed sessions hand off via first-prompt injection; non-fleet-managed sessions may use `/context-save`-style persistence.
- [ ] Skills remain environment-agnostic: no hostnames, IPs, ports, URLs, tokens, or private repo names introduced (cctrl's own subcommands are fine).
- [ ] Version bumps + changelog lines in each touched SKILL.md frontmatter/header per the skills' existing convention.

## Design

Doctrine-only plan: no `cctrl` code changes. Blocked by 042/043 so the section
names verbs that exist, and by 037 (fleet-doctrine wiring) because both edit
the same SKILL.md. 037's recorded state is ambiguous — its body records an eng
re-review verdict of APPROVE ("all applied") while its frontmatter still says
changes-requested — so **confirm 037's actual state via the recorded review
state** (`mstack-backlog` / the review gate) rather than taking either reading
as fact; resolve or supersede any genuine block first to avoid conflicting
doctrine merges.

The 042/043 verb shapes (exact names and flags) are taken from the **shipped
`--help` output at implementation time**, not from this plan's text — those
plans are pre-review and their surfaces may change.

Emphasis order matters (multi-model review consensus): self-contained
questions at spawn (plan 048) prevent most Tier-2 cases; the bounded re-ask
handles most of the rest; the context-fetcher is the *exception*, not the
default — the doctrine text must present it in that order.

**Files expected to change:**

- `skills/cctrl-fleet-manager/SKILL.md`: new triage section, tool naming, send-keys replacement, handoff clarification
- `skills/cctrl-session-end/SKILL.md`: fleet-managed handoff-then-close carve-out
- `docs/cctrl-fleet-manager.md`, `docs/cctrl-session-end.md`: pointer freshness only

**Testing approach: unit-only** — doctrine text; verification is structural
greps.

**Out of scope:** cctrl code changes; the spawn-brief template (plan 048);
the peer contract itself (plan 026, shipped — AGENTS.md's `## Peer messaging`
is cross-referenced, never restated); any environment-specific brief content
(lives in the operator's private repo).

## Tasks

1. Confirm 037's review state via `mstack-backlog` / the review gate before editing (its body records an eng re-review APPROVE while the frontmatter lags at changes-requested); resolve or supersede any genuine block.
2. Draft the "Answering agent questions" section (three tiers, protocol-first Tier 2, fetcher failure-mode checklist).
3. Replace the raw-tmux driving passage with `session say`/`key` guidance + the permission-policy note; name all monitoring verbs.
4. Reconcile handoff doctrine across fleet-manager and session-end.
5. Environment-specifics scan (`grep -nE '\b(ssh|http|100\.|:80|~/dev/)' skills/`) — must stay clean.
6. Bump versions/changelogs.

## Verification

Checks:

- `[assert] cat skills/cctrl-fleet-manager/SKILL.md` contains `Answering agent questions`
- `[assert] bash -c "grep -q 'session say' skills/cctrl-fleet-manager/SKILL.md && echo yes"` contains `yes`
- `[assert] bash -c "grep -q 'cctrl fleet' skills/cctrl-fleet-manager/SKILL.md && echo yes"` contains `yes`
- `[assert] bash -c "grep -q 'needs-me' skills/cctrl-fleet-manager/SKILL.md && echo yes"` contains `yes`
- `[assert] bash -c "grep -q 'session key' skills/cctrl-fleet-manager/SKILL.md && echo yes"` contains `yes`
- `[assert] bash -c "grep -q 'session ask' skills/cctrl-fleet-manager/SKILL.md && echo yes"` contains `yes`
- `[assert] bash -c "grep -q 'peer reply' skills/cctrl-fleet-manager/SKILL.md && echo yes"` contains `yes`
- `[assert] bash -c "grep -qi 'paraphrase' skills/cctrl-fleet-manager/SKILL.md && echo yes"` contains `yes` — pins the fetcher secret-handling rule
- `[cmd] bash -c "awk '/^## Handoff-then-close/{f=1;next}/^## /{if(f)exit}f' skills/cctrl-session-end/SKILL.md | grep -q 'fleet-managed'"` — scoped to the section because `fleet-managed` already appears elsewhere in session-end today; a whole-file check would pass with zero work done
- `[cmd] bash -c '! grep -nE "~/dev/[a-z-]+" skills/cctrl-fleet-manager/SKILL.md skills/cctrl-session-end/SKILL.md'`

**Note on check form:** use existence checks (`grep -q … && echo yes`), never
`grep -c … contains N` — the runner substring-matches output, so `contains 1`
fails on a legitimate count of `3` and silently passes on `11`.

<!-- mstack:seam
produced:
assumed:
- from: 037; kind: file; name: skills/cctrl-fleet-manager/SKILL.md; file: skills/cctrl-fleet-manager/SKILL.md
- from: 042; kind: symbol; name: _session_key; file: cctrl
- from: 043; kind: symbol; name: _session_ask; file: cctrl
-->
