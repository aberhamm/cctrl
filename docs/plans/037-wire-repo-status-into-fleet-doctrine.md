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
---

## Requirements

Plans 035 and 036 ship a command. A command nobody is told to run changes
nothing — the founding incident was not *"cctrl lacked a git wrapper"*, it was
*"the fleet manager shell-looped `git status` across `~/dev` repeatedly"* and
still missed untracked plans for days. The habit is the deliverable.

cctrl's own convention makes the fix unambiguous: per AGENTS.md, the invocable
skill **is** the doctrine — `skills/cctrl-fleet-manager/SKILL.md` and
`skills/cctrl-session-end/SKILL.md` are the single source of truth for how these
roles work, and `docs/` carries only thin pointers. So this plan edits doctrine,
not code.

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
carries 71 dirty entries including unreviewed `.tex` content. Doctrine that says
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
      `cctrl repo status` for the uncommitted-work step, and names the shared
      working tree hazard: sibling sessions in the same repo mean *"the tree is
      dirty"* is not the same as *"my work is uncommitted"* — stage explicit
      paths, never `git add .`, never `git add -A`.
- [ ] The `local-refs-only` caveat is carried into doctrine so neither role
      reads `ahead 0` as "pushed", and the livesync branch-switch hazard is
      named where it bites: check the branch before committing.
- [ ] Skills stay **environment-agnostic** — no `~/dev`, no hostnames, no repo
      names, no `--root` value that leaks this operator's layout (AGENTS.md).
      Concrete roots are the caller's to supply, or live in the operator's
      private infra brief.
- [ ] `README.md` and `cmd_help` (`cctrl:6267`) present the command as the
      answer to the question, not just as a flag list.
- [ ] `docs/` gains or updates its thin pointer, consistent with how the other
      skills are referenced from AGENTS.md.

## Design

### What goes where

| Sink | Content |
|---|---|
| `skills/cctrl-fleet-manager/SKILL.md` | New short subsection under the monitoring/decide material: run `cctrl repo status` (session scope) each monitoring pass; run `--all --dirty-only` on the wider cadence; read the verdict column; **route, do not fix**. |
| `skills/cctrl-session-end/SKILL.md` | Pre-close checklist step rewritten around `cctrl repo status`, plus the shared-tree staging rule. |
| `README.md` | Command reference + a one-line "answers: does any repo have uncommitted or unpushed changes, and who is responsible". |
| `cctrl` `cmd_help` | The `Repos` block from plan 035, extended with the `--all --dirty-only` habitual form. |
| `docs/` | Thin pointer only, per AGENTS.md. |

### The routing table doctrine must encode

This is the part that makes the command actionable rather than informational
noise. Keep it this short in the skill:

| Verdict | Live sessions in that repo | Action |
|---|---|---|
| `dirty` / `dirty+unpushed` | ≥1 | Ask the owning session(s) to dispose of their own changes. They hold the context; the manager does not. |
| `dirty` / `dirty+unpushed` | 0 | Surface to the human with the file counts. Do not commit orphaned changes — nobody can currently attest to what they are. |
| `unpushed` only | any | Report. Push is the human's call (and `local-refs-only` means the count may be stale-high). |
| `not-a-repo` | ≥1 | Flag: those sessions' work is unversioned. This is a real finding, not noise. |
| `unknown` | any | Investigate the repo by hand. **Never** treat as clean. |
| `clean` | any | Nothing. |

### Hazards doctrine must name (not soften)

- **Shared working trees.** Multiple sessions per repo is normal here — three in
  one repo, eight in another. A closing session must stage **explicit paths**;
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
an opt-in timer pattern (`session autoheal install`, `cctrl:5528`) so the
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

- Any behavior change to the command itself. If doctrine wants something the
  command cannot do, that is a new plan, not a widened one here.
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
3. Update `skills/cctrl-session-end/SKILL.md`'s pre-close checklist to use
   `cctrl repo status`, including the explicit-paths staging rule for shared
   trees.
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
  `--dirty-only`
- `[assert]` `grep -c 'local-refs-only\|no fetch' skills/cctrl-fleet-manager/SKILL.md`
  is at least 1
- `[manual]` A fresh reader of `cctrl-fleet-manager` can, from the skill alone,
  answer "a repo is dirty and two sessions live in it — what do I do?" without
  reaching for the command's `--help`.
