---
id: 037
title: Make `cctrl repo status` the fleet's standing answer for repo hygiene
status: pending
blocked-by: [036]
priority: 37
goal: cctrl-fleet-repo-visibility
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-26
reviews:
  - type=eng verdict=changes-requested date=2026-07-28 by=mstack-review
---

## Requirements

Plans 035 and 036 ship a command. A command nobody is told to run changes
nothing — the founding incident was not *"cctrl lacked a git wrapper"*, it was
*"the fleet manager shell-looped `git status` across `~/dev` repeatedly"* and
still missed untracked plans for days. The habit is the deliverable.

cctrl's own convention makes the fix unambiguous: per AGENTS.md, the invocable
skill **is** the doctrine — `skills/cctrl-fleet-manager/SKILL.md` and
`skills/cctrl-session-end/SKILL.md` are the single source of truth for how these
roles work, and `docs/` carries only thin pointers. So this plan is
**doctrine-first**: its substance is the two skill files, and its only touch on
`cctrl` itself is help text (the `cmd_help` `Repos` block — see Files expected to
change). No behavior, no new flags, no logic. Stated precisely because the draft
said "edits doctrine, not code" while listing `cctrl` among its files, which is a
contradiction an implementer would have to resolve by guessing.

Two roles need it, at two different moments:

1. **The fleet manager, periodically.** "Does any repo my fleet is working in
   have uncommitted or unpushed changes, and *which session* is responsible?"
   is a monitoring question, and the manager's loop already has a monitor step.
   Today the answer requires a manual loop, so it is asked rarely.
2. **A session, before it closes.** The session-close gate already asks about
   uncommitted work, and MEMORY.md records the standing rule that a session is
   asked for cleanup opportunities before close *because its context is lost on
   close*. `cctrl repo status` makes that check one command with correct
   attribution instead of a per-repo `git status` the closing session runs on
   its own tree only.

There is one thing this plan must be at least as loud about as the command
itself: **the view informs, it never fixes.** `~/dev/matthew-aberham-resume`
carries 89 dirty entries including unreviewed `.tex` content. Doctrine that says
"check repo status" without saying "and never auto-commit what you find" is
worse than no doctrine, because it puts a sweeping tool in front of an agent
with commit rights.

**Acceptance criteria:**

- [ ] `skills/cctrl-fleet-manager/SKILL.md` gains repo hygiene as an explicit
      monitoring input: the command, when to run it, how to read the session
      attribution, and what to do with each verdict.
- [ ] That guidance states the **inform-never-fix** rule in the imperative, with
      the concrete failure mode (unreviewed content in a working tree) rather
      than as an abstraction. Disposition of dirty work belongs to the session
      that owns it or to the human — never to the manager sweeping the fleet.
- [ ] It states the correct escalation: when a repo is dirty and has live
      sessions, **ask those sessions** (they hold the context); when it is dirty
      with no live session, surface it to the human. Never `git add .`, never
      commit another session's tree.
- [ ] `skills/cctrl-session-end/SKILL.md`'s pre-close checklist uses
      `cctrl repo status` for the uncommitted-work step — in the **`--here`**
      form **if and only if** that flag survives the open human decision (see the
      provenance note below; `--here` is PARKED in plan 035, so do not assume it).
      The step also names the shared working tree hazard:
      sibling sessions in the same repo mean *"the tree is dirty"* is not the
      same as *"my work is uncommitted"* — stage explicit paths, never
      `git add .`, never `git add -A`.
- [ ] The `local-refs-only` caveat is carried into doctrine so neither role
      reads `ahead 0` as "pushed", and the livesync branch-switch hazard is
      named where it bites: check the branch before committing.
- [ ] Skills stay **environment-agnostic** — no `~/dev`, no hostnames, no repo
      names, no `--root` value that leaks this operator's layout (AGENTS.md).
      Concrete roots are the caller's to supply, or live in the operator's
      private infra brief.
- [ ] `README.md` and `cmd_help` present the command as the
      answer to the question, not just as a flag list.
- [ ] `docs/` gains or updates its thin pointer, consistent with how the other
      skills are referenced from AGENTS.md.

## Design

### What goes where

| Sink | Content |
|---|---|
| `skills/cctrl-fleet-manager/SKILL.md` | New short subsection under the monitoring/decide material: run `cctrl repo status` (session scope) each monitoring pass; run `--all --attention-only` on the wider cadence; read the verdict column; **route, do not fix**. |
| `skills/cctrl-session-end/SKILL.md` | `### 1. Check for uncommitted work` (today: a bare `git status`) rewritten around `cctrl repo status` — `--here` form only if that flag survives the open human decision — plus the shared-tree staging rule. |
| `README.md` | Command reference + a one-line "answers: does any repo have uncommitted or unpushed changes, and who is responsible". |
| `cctrl` `cmd_help` | The `Repos` block from plan 035, extended with the `--all --attention-only` habitual form. |
| `docs/` | Thin pointer only, per AGENTS.md. |

### Provisional: a closing session uses `--here` (selector pick 2026-07-28, NOT yet re-confirmed)

> **PROVENANCE — read before relying on this.** The scope question was put to the
> session's human via an **`AskUserQuestion` selector** on 2026-07-28 (question
> rendered 21:11:36Z, answer returned 21:21:06Z); **Option A was selected**. The
> option text — including its `(Recommended)` label and its first position in the
> list — was **authored by the planning agent, not by the human**, so the human
> ratified the agent's recommendation rather than originating it. The tool payload
> does not identify the human by name; the earlier attribution
> *"Decision (Matthew, 2026-07-28)"* overstated that and has been corrected here.
> An `AskUserQuestion` renders only in the answering pane, so **no artifact of
> this exists that a reviewer or the fleet manager can independently inspect.**
>
> **Two questions are open with the human and must not be inferred from silence:**
> (1) does `--here` survive on the strength of a selector pick, and (2)
> fix-in-place vs park. Until both are answered, findings **035-5** and **035-6**
> (the four `--here` specification gaps and the mutual-exclusion owner) are
> **PARKED** — see plan 035. Everything else in these plans is independent of the
> outcome and proceeds regardless.

The eng review raised, correctly, that this plan wired doctrine to a command
shape that did not fit one of its two consumers. `cctrl-session-end` runs
**inside** the session being closed and asks "is *my* work uncommitted?", but
plan 035's default scope is fleet-wide — a closing session would be handed a
7-row table and left to locate itself in it.

**Scope question put to the session's human via an `AskUserQuestion` selector on
2026-07-28; Option A selected — add a `--here` scope to plan 035.** The option
text was authored and labeled `(Recommended)` by the planning agent (see the
provenance note above), so this records a ratification of the agent's
recommendation, not an independently originated instruction.
Session-end's step 1 becomes `cctrl repo status --here`: one row, the session's
own repo, listing every sibling session in that tree with the caller marked
`← you`. That is exactly the attribution the explicit-paths staging rule
depends on — "3 siblings share this tree" is what turns *never `git add .`* from
a rule into an obvious consequence.

The two alternatives were rejected: prescribing a `jq` filter in doctrine puts a
rotting incantation in a skill (and `$PWD` is not the toplevel, so it needs a
`rev-parse` first) for identical output; accepting the fleet-wide table makes a
closing session read N rows to answer a 1-row question and degrades as the fleet
grows.

Consequence for this plan's boundary: **"no behavior change to the command"
moves by exactly one flag.** `--here` is specified in plan 035 (Design §
Discovery, and its acceptance criteria), not here — this plan still only edits
doctrine. Plan 035 already required `_repo_discover_json` to take its scope as
arguments, so `--here` is a new scope source on an existing seam, ~5 lines.

### The routing table doctrine must encode

This is the part that makes the command actionable rather than informational
noise. Keep it this short in the skill:

| Verdict | Live sessions in that repo | Action |
|---|---|---|
| `dirty` / `dirty+unpushed` | ≥1 | Ask the owning session(s) to dispose of their own changes. They hold the context; the manager does not. |
| `dirty` / `dirty+unpushed` | 0 | Surface to the human with the file counts. Do not commit orphaned changes — nobody can currently attest to what they are. |
| `unpushed`, all branches `basis: "upstream"` | any | Report. Push is the human's call (and `local-refs-only` means the count may be stale-high). |
| `unpushed`, any branch `basis: "no-upstream"` | any | **Escalate above ordinary unpushed.** Those commits exist on **no remote at all** — one copy, one disk, no backup and no other machine. Name the branch and the count. |
| `not-a-repo` | ≥1 | Flag: those sessions' work is unversioned. This is a real finding, not noise. |
| `unknown` | any | Investigate the repo by hand. **Never** treat as clean. |
| `clean` | any | Nothing. |

**Why the `no-upstream` row is not a nicety.** Plan 035 added the `basis`
discriminator precisely so a reader can tell a tracking branch that is 3 ahead
from a branch that has never been pushed anywhere. Doctrine that collapses both
into "push is the human's call" throws that discriminator away at the exact
moment it matters. Live instance on 2026-07-28: `benedikt-thesis-audit` `main`
carries 3 commits and the repo has no remotes at all. "Report it" is right for a
branch whose commits are also on a server; it is wrong for a branch whose loss
mode is a disk failure.

### Hazards doctrine must name (not soften)

- **Shared working trees.** Multiple sessions per repo is normal here — on
  2026-07-28: 3 sessions in one repo, 6 in another, and 10 in a directory that is
  not a repo at all. A closing session must stage **explicit paths**;
  `git add .` in a shared tree commits a sibling's in-flight work. This exact
  rule is already in force for this planning session and belongs in the skill.
- **`local-refs-only`.** No fetch means `ahead` is derived from local
  remote-tracking refs. Under multi-machine git the error is toward
  over-reporting (work pushed from the other machine still shows ahead). Read it
  as "look at this", never as a precise ledger.
- **Livesync can switch a branch mid-session** (already recorded as a standing
  project hazard). `repo status` reports `branch` per repo precisely so an
  unexpected branch is visible; doctrine must say *check the branch before
  committing*, not merely *note it*.
- **A scan is a snapshot, not a lock.** Another session can dirty a tree the
  moment after the scan. Doctrine should not encourage decisions that assume the
  state held.

### Why not automate it

A tempting fourth plan — a launchd timer or a `peer watch` hook that runs
`repo status` and nags — is deliberately **not** proposed. cctrl already carries
an opt-in timer pattern (`session autoheal install`) so the
machinery exists, and that is exactly why the restraint is worth writing down:
the fleet's periodic monitor already has a human or a manager in the loop, and
an unattended nagger for a condition whose correct resolution is almost always
"ask a human" adds alert fatigue, not safety. Revisit only if the manual habit
demonstrably fails to stick.

**Files expected to change:**

- `skills/cctrl-fleet-manager/SKILL.md`
- `skills/cctrl-session-end/SKILL.md`
- `README.md`
- `cctrl` (`cmd_help` `Repos` block only — no behavior change)
- `docs/` pointer file(s), `CHANGELOG.md`

**Out of scope:**

- Any behavior change to the command itself, **with one resolved exception**:
  `--here`, which the eng review surfaced and which is specified in **plan 035**,
  not here (see "Resolved" above). That carve-out is closed — if doctrine wants
  anything further the command cannot do, it is a new plan, not a widened one
  here.
- Automated/scheduled scanning, notifications, or a `peer watch` integration.
- Any doctrine that authorizes an agent to commit, stage, stash, or push on
  another session's behalf. The whole point is the opposite.
- The operator's private infra brief. Concrete roots (`--root <their tree>`) and
  host specifics live there, not in cctrl's public skills.

## Tasks

1. Read `skills/cctrl-fleet-manager/SKILL.md` and place the repo-hygiene
   subsection where the monitoring inputs already are — matching the file's
   existing voice and density; do not append a bolt-on section.
2. Add the verdict routing table and the inform-never-fix rule, with the
   concrete unreviewed-content failure mode stated once, plainly.
3. Rewrite `skills/cctrl-session-end/SKILL.md`'s `### 1. Check for uncommitted
   work` step (currently a bare `git status`) around `cctrl repo status`,
   including the explicit-paths staging rule for shared trees. Use the `--here`
   form and explain the `← you` marker **only if `--here` has survived the open
   human decision** — otherwise write the step against the default scope and
   leave a TODO naming the open question.
4. Add the `local-refs-only`, branch-switch, and snapshot-not-a-lock caveats to
   both skills, in one or two sentences each — enough to prevent the misread,
   short enough to survive editing.
5. Update `README.md` and the `cmd_help` `Repos` block; add/refresh the `docs/`
   pointer.
6. Grep both skills for environment specifics (`~/dev`, hostnames, repo names,
   host aliases) and remove any this plan introduced.
7. Update `CHANGELOG.md`.

## Verification

- `[cmd]` `bash -n cctrl`
- `[cmd]` `tests/run-tests.sh` *(no behavior change expected; this guards the
  `cmd_help` edit)*
- `[assert]` `grep -c 'cctrl repo status' skills/cctrl-fleet-manager/SKILL.md`
  is at least 1
- `[assert]` `grep -c 'cctrl repo status' skills/cctrl-session-end/SKILL.md`
  is at least 1
  *(the `--here` form is asserted only if `--here` survives the open human
  decision — see the provenance note in Design; until then this bullet asserts
  the command, not the flag)*
- `[assert]` the bare `git status` is gone from the uncommitted-work step —
  mechanical form: `awk '/^### 1\. Check for uncommitted work/,/^### 2\./'
  skills/cctrl-session-end/SKILL.md | grep -c '^\s*git status\b'` is `0`.
  Given a mechanical form because every sibling bullet has one; a lone prose
  check in a grep-shaped verification block is a check that silently never runs.
- `[assert]` both skills contain the never-auto-commit rule —
  `grep -Eic 'never (auto-)?commit|never .*git add' skills/cctrl-fleet-manager/SKILL.md skills/cctrl-session-end/SKILL.md`
  is non-zero for each
- `[assert]` **environment-agnostic gate** —
  `grep -REn '~/dev|/Users/|ms-128g|100\.[0-9]+\.[0-9]+\.[0-9]+' skills/cctrl-fleet-manager/SKILL.md skills/cctrl-session-end/SKILL.md`
  returns nothing (AGENTS.md requires cctrl's skills carry no environment
  specifics). Scope the gate to the two files this plan edits: `skills/README.md`
  and `skills/cctrl-spawn/SKILL.md` legitimately carry `~/dev/...` example paths
  in install instructions and a private-brief pointer, and must not be flagged.
- `[assert]` `cctrl repo status --help` and `cctrl help` both mention
  `--attention-only`
- `[assert]` `grep -c 'local-refs-only\|no fetch' skills/cctrl-fleet-manager/SKILL.md`
  is at least 1
- `[manual]` A fresh reader of `cctrl-fleet-manager` can, from the skill alone,
  answer "a repo is dirty and two sessions live in it — what do I do?" without
  reaching for the command's `--help`.

## Eng review — 2026-07-28

Reviewed by an independent session (not the author). Verdict:
**changes-requested**, on one open question only. Decide the scope question
below and this plan is ready — everything else in it checks out.

Scores: clarity 9 · testability 7 · scope-fit 9 · autonomy 7 · trap-resistance 9
→ composite **8.0/10**.

Premises verified 2026-07-28: `skills/cctrl-fleet-manager/SKILL.md` has
`## The monitor → decide → sequence loop` (the monitoring-inputs location this
plan targets); `skills/cctrl-session-end/SKILL.md` has `### 1. Check for
uncommitted work`, which today says simply `git status`; and this plan's
environment-agnostic grep gate **currently passes clean** on both files. The
shared-working-tree hazard is real and current: 4 live sessions in one repo, 6
in another, and 10 in a directory that is not a repo at all.

### OPEN QUESTION (for Matthew): what scope does a closing session use?

`cctrl-session-end` runs **inside** the session being closed. Its step 1 today
is `git status` — implicitly *"my own working directory's repo"*. This plan
replaces that with `cctrl repo status`, whose default scope (per plan 035) is
*every repo the whole fleet is working in* — 7 rows on the current fleet. A
closing session would be handed a fleet-wide table and left to locate itself in
it. Plans 035 and 036 provide no single-repo scope, and this plan's own
"Out of scope" forbids adding one: *"Any behavior change to the command itself.
If doctrine wants something the command cannot do, that is a new plan."*

So as written, this plan wires doctrine to a command shape that does not fit the
second of its two consumers. Pick one:

**Option A — add a `--here` scope to plan 035.** *(recommended)*
Session-end's step 1 becomes `cctrl repo status --here`: one row, the session's
own repo, with its sibling sessions listed — which is exactly the attribution
the shared-tree staging rule needs. Plan 035 already requires
`_repo_discover_json` to take its scope as arguments, so this is a new scope
source, not a new seam.
*Consequence:* a small edit to plan 035 (already changes-requested, so it is
being touched anyway), and this plan's "no behavior change" boundary moves by
exactly one flag. Cost ~5 lines.

**Option B — prescribe a filter in the doctrine.** Step 1 becomes
`cctrl repo status --json | jq …` selecting the row whose `path` matches the
session's repo toplevel.
*Consequence:* no code change anywhere; this plan's boundary holds exactly as
written. But doctrine now carries a jq incantation, which is the kind of thing
that rots, and `$PWD` is not the repo toplevel, so it needs a `rev-parse` first.
Strictly worse ergonomics for the same result.

**Option C — accept the fleet-wide table.** Doctrine says "run `cctrl repo
status`, find your repo's row".
*Consequence:* free, and defensible — the sibling-session attribution is visible
either way. But it makes a closing session read 7 rows to answer a 1-row
question, and it degrades as the fleet grows.

Recommendation: **A**. The command's whole value is attribution, and `--here` is
the form that delivers attribution to the one role guaranteed to want it.

### Non-blocking notes

- The verdict routing table is the best part of this plan and should survive
  editing intact. Its `not-a-repo` ⇒ "those sessions' work is unversioned" row
  is live and true right now (10 sessions in a non-repo).
- The "Why not automate it" section is correct restraint and worth keeping as
  written — including the observation that `session autoheal install` proves the
  machinery already exists. That is what makes it a decision rather than an
  oversight.
- Verification is grep-shaped by nature (this is a docs plan), which is fine.
  The real acceptance is the `[manual]` fresh-reader test; keep it.

### Kept as-is

The inform-never-fix rule stated with a concrete failure mode rather than as an
abstraction; the explicit-paths staging rule for shared trees; carrying
`local-refs-only` and the livesync branch-switch hazard into doctrine; and
scoping the environment-agnostic gate to only the two files this plan edits.

### Author response — 2026-07-28 (revised, awaiting re-review)

- **OPEN QUESTION — selector pick 2026-07-28, Option A (`--here`); STILL OPEN
  with the human.** The review was right that this plan wired doctrine to a
  command shape that did not fit its second consumer. A new Design section
  records the pick and why B (a jq incantation in a skill) and C (read N rows for
  a 1-row question) lost. `--here` is specified in **plan 035**, so this plan
  still edits doctrine only.
  **Correction (2026-07-29):** this bullet originally read *"resolved by Matthew"*
  and the Design section read *"Decision (Matthew, 2026-07-28)"*. Both overstated
  the evidence. The input was an `AskUserQuestion` selector pick on an option the
  planning agent wrote and labeled `(Recommended)`; the tool payload names no
  human, and no inspectable artifact exists outside the answering pane. See the
  provenance note in Design. Two questions remain open with the human — does
  `--here` survive on that basis, and fix-in-place vs park — and **must not be
  inferred from silence**.
- Session-end's step 1 is named precisely (`### 1. Check for uncommitted work`,
  today a bare `git status`) rather than described, and the `← you` marker is
  part of what doctrine must explain.
- Verified facts refreshed: 89 dirty entries in the resume repo, and 3/6/10
  sessions across two repos and one non-repo.
- Flag name synced to `--attention-only` following plan 035's rename.
- The three "Kept as-is" items (routing table, "Why not automate it", the
  `[manual]` fresh-reader test) are untouched.

## Eng re-review — 2026-07-28 · author response 2026-07-29

Re-review verdict: **APPROVE**, with one edit plus two minors. All applied.

- **The `no-upstream` routing row — applied, and it was the sharpest single
  finding across all three plans.** Plan 035 added the `basis` discriminator
  precisely so a reader can tell "3 ahead of a remote" from "exists on no remote
  at all", and the doctrine then discarded it. Added a dedicated row that
  escalates above ordinary unpushed, with the loss mode named (one copy, one
  disk) and the live instance cited.
- **Minor (a) — applied.** The "bare `git status` is gone" bullet was the only
  verification item without a mechanical form; it now has an `awk`-scoped `grep`.
  A lone prose check in a grep-shaped block is a check that silently never runs.
- **Minor (b) — applied.** "This plan edits doctrine, not code" contradicted a
  Files-expected-to-change list containing `cctrl`. Reworded to "doctrine-first",
  with the `cmd_help`-text-only scope stated inline.
- **Provenance correction (2026-07-29, not from this review).** The
  `--here` decision section previously read *"Decision (Matthew, 2026-07-28)"*.
  That overstated the evidence: the input was an `AskUserQuestion` selector pick
  on an option this agent authored and labeled `(Recommended)`, the tool payload
  names no human, and no artifact exists that a reviewer can inspect. Replaced
  with the defensible form and a provenance note. **Two questions remain open
  with the human and must not be inferred from silence.**

Note: this plan's `[assert]` for the session-end step now asserts
`cctrl repo status` rather than `cctrl repo status --here`, since `--here` is
parked in 035. If `--here` lands, tighten it back.
