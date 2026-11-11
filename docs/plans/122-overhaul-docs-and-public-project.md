---
id: 122
title: Overhaul D - docs for newcomers, a security statement, public-repo hygiene and governance
status: blocked
blocked-by: []
priority: 17
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-11-11
approval: "mdec-1111-fable-findings-plans: PLAN ONLY. Waits for Matthew's prioritisation from plan 115. Every change here is a public-repo change and needs his yes; repo settings (branch protection, vulnerability reporting) too."
approved-by: pending (Matthew, via plan 115)
reviews: []
related: 115, 116, 117, 118, 119, 120, 121, 050
---

Workstream D of the overhaul (umbrella: plan 115). It covers Fable's plan (d) and findings F6,
F8 and F13 (docs), the reviewer's SH-S12 (history) and SH-S13 (governance and outsider items),
and MF-M6's requirement to state the residual risk plainly. **The GitHub repo is public** and
has an MIT `LICENSE` already. Baseline is `main` at `8c249fc`.

## Problem

- `README.md` is 2,418 lines. One section is 1,638 lines. There is no table of contents, no
  requirements list (jq and python3 are never named), no uninstall and no security section,
  and Linux is not mentioned. Its rollback text breaks the checked install. It says `data/`
  is live-synced, which reports contradict (F13).
- There is no architecture document, data-format reference, `CONTRIBUTING.md`, `SECURITY.md`,
  issue or PR templates, docs index, CODE_OF_CONDUCT or CODEOWNERS.
- 113 of 129 tracked files under `docs/` are internal plans.
- Private material is tracked in the public repo:
  - a hard-coded map of the owner's private repo names in `_session_pretty_repo_label`;
  - a personal ops note in `TODOS.md` with a Tailscale-range IP, home paths and a hostname;
  - "homelab" in 29 tracked files, and `mdec-` ids in 28.

  `AGENTS.md` claims the opposite.
- Help, completions and dispatch are three hand-kept command lists that have drifted.

## Phases

### D6a. Privacy tip-clean (step 1)

- **Scope.**
  - The repo-label map leaves the source. Labels come from an optional `repo_labels` object
    in the user config, with a neutral basename default.
  - The ops note leaves `TODOS.md`. Its content goes to Matthew's private notes, written by
    him: an agent writes nothing into the vault.
  - Home paths and hostnames in tracked docs are replaced with placeholders.
  - A CI deny-list test (plan 121's E0) blocks the private names, private IP ranges and
    `/Users/<name>` paths in tracked files. The list lives in a tracked file of **patterns**
    that are neutral by themselves, plus an optional untracked local extension.
  - **No history rewrite.** It is already published, and a rewrite breaks SHA-named releases,
    the mstack tags and plan citations (SH-S12, plan 115 Q6).
  - `AGENTS.md`'s claim is corrected.
- **Closes.** F8 (tip).
- **Size.** 3 h (this plan's estimate).
- **Risk.** Low. Labels change to basenames unless configured.
- **Tests.** The deny-list test with a planted violation; a label default test.
- **Rollback.** `git revert` (not wanted, since the content is private).
- **Depends on.** Plan 121's E0 (deny-list job) can land in the same step.
- **Needs Matthew's yes:** the public-repo change. Matthew moves the ops note content himself.

### D1. README (step 6)

- **Scope.** At most about 300 lines:
  - what it is, and who it is for;
  - a 60-second example and a demo asciinema or GIF;
  - **requirements:** bash 3.2+, tmux 3.x (3.8 tested), jq, python3 3.9+; macOS only, unless
    plan 115 Q5 says otherwise;
  - install (the tarball and tap from plan 117's C7 once they exist, plus the maintainer
    `self-install`);
  - quickstart and core concepts;
  - **what it changes on your machine:** `~/.claude/settings.json` hooks, Codex `hooks.json`,
    launchd agents, `~/.local/state/cctrl`, `~/.config/cctrl`;
  - **a privacy note:** it stores prompts, message bodies and transcript paths locally, at
    0600;
  - the trust model in one paragraph, linking SECURITY.md;
  - uninstall (`cctrl uninstall`);
  - a support matrix; the CI and coverage badges; LICENSE (MIT).

  The reference material moves to `docs/`. The sync statement is corrected from plan 116's A2
  canary result (F13).
- **Closes.** F6 (README), F13 (docs), SH-S13 (demo, matrix, privacy, licence link).
- **Size.** 6 h (Fable).
- **Risk.** None to code.
- **Tests.** A CI fresh-machine walkthrough that follows the README commands literally on a
  clean macOS runner; a link checker.
- **Rollback.** `git revert`.
- **Depends on.** Plan 115 step 5 done, so the say and caller sections are not rewritten
  twice. Plan 116's A2 done.
- **Needs Matthew's yes:** the public-repo change.

### D2. Architecture overview and SECURITY.md (step 6)

- **Scope.**
  - `docs/architecture.md` with Mermaid diagrams:
    - components and languages;
    - the on-disk layout (state, config, releases) after plan 116;
    - the life of a peer message from send to ack;
    - session lifecycle states;
    - the install and release layout, including rollback and the layout guard.
  - **`SECURITY.md`:**
    - the trust model in the audit's words: guards for cooperative agents, not a boundary;
      one uid, with bypassPermissions;
    - what each mode does (`attestation`, `say_gate`, `caller_checks`) and their current
      defaults;
    - **the MF-M6 residual, stated plainly:**
      - an agent that drives Terminal.app via osascript gets the operator class, with the
        supervised MacBook check's result;
      - a same-uid process can read the seal key or edit state;
      - hook rules are text heuristics;
      - raw tmux bypasses `say`;
    - the hooks fail open by design (plan 079, audit M10);
    - how to report a vulnerability: GitHub private vulnerability reporting (D7).
- **Closes.** F6 (architecture), MF-M6 (statement), M10 (stated accepted risk).
- **Size.** 8 h (Fable).
- **Risk.** None.
- **Tests.** The diagrams render in CI (mermaid-cli). A doc-lint check that every path named
  in the doc exists in the resolver's output.
- **Rollback.** `git revert`.
- **Depends on.** Plan 116's A2, and plan 118's O3.1 (the classifier rules being documented).
- **Needs Matthew's yes:** the public-repo change, and the wording of the residual-risk
  section.

### D3. Contributor guide (step 6)

- **Scope.**
  - `CONTRIBUTING.md`:
    - setup;
    - building (`make build`, once plan 120's B1 exists);
    - running one test file or the whole suite;
    - the bash 3.2 rules and why;
    - Python style;
    - how to add a command;
    - commit and plan conventions, including **no internal decision ids in commit
      messages** (plan 115 Q6);
    - the manual atomic rollback recipe, written once (plan 117's C2);
    - the SemVer policy (plan 117's C6).
  - `.editorconfig`, plus issue and PR templates.
- **Closes.** F6 (contributors).
- **Size.** 5 h (Fable).
- **Risk.** None.
- **Tests.** The guide's commands run in CI.
- **Rollback.** `git revert`.
- **Depends on.** Plan 121's E2 (test commands); B1 later updates the build line.
- **Needs Matthew's yes:** the public-repo change.

### D7. Governance for outsiders (step 6; SH-S13, plan 115 Q8)

- **Scope.**
  - `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1, with a contact address chosen by
    Matthew).
  - `CODEOWNERS` (Matthew for everything; `skills/` and `hooks/` called out).
  - Branch protection on `main`: required checks are the plan 121 E0 lint, python and smoke
    jobs. Outsiders work through PRs. **Matthew keeps direct push** (an admin bypass), so the
    fleet's push-after-verify doctrine still works.
  - The PR workflow is documented in CONTRIBUTING.
  - GitHub private vulnerability reporting is enabled.
  - **No self-hosted runners**, restated as a repo rule (plan 121).
- **Closes.** SH-S13 (governance).
- **Size.** 2 h (this plan's estimate, part of the reviewer's 10 h).
- **Risk.** Low. Branch protection must not block the fleet's direct push; verify with a dry
  run on a scratch branch rule first.
- **Tests.** A CODEOWNERS syntax check (`gh api` validation in CI).
- **Rollback.** Remove the protection rule; `git revert`.
- **Depends on.** Plan 121's E0.
- **Needs Matthew's yes:** the repo settings (branch protection, vulnerability reporting) and
  the CoC contact address.

### D4. Generated CLI reference (step 9)

- **Scope.**
  - Plan 120's B8 command table generates `cctrl help`, per-command `--help` in one format,
    zsh and bash completions, and `docs/cli/*.md`.
  - `cctrl --version` already exists (plan 117's C6).
- **Closes.** F6 (help, completion and dispatch drift).
- **Size.** 10 h (Fable).
- **Risk.** Low.
- **Tests.** A drift check: the committed generated output equals fresh output, and every
  dispatched command has help.
- **Rollback.** `git revert`.
- **Depends on.** Plan 120's B8.
- **Needs Matthew's yes:** the public-repo change.

### D5. Per-module docs and data formats (step 9)

- **Scope.**
  - A header contract in each `src/sh` module: purpose, public functions, globals read and
    written.
  - Docstrings on every public Python function.
  - `docs/data-formats.md` for the message, session record, doorbell, ring state, say/admin
    log and `role_grant` formats. Each is checked against a JSON Schema that the tests also
    use.
- **Closes.** F6 (data formats), F11 (docstrings).
- **Size.** 12 h (Fable), spread across plan 120.
- **Risk.** None.
- **Tests.** A header lint, the ruff docstring gate, and schema validation tests.
- **Rollback.** `git revert`.
- **Depends on.** Plan 120's B1-B7.
- **Needs Matthew's yes:** the public-repo change.

### D6b. Internal docs and the changelog (step 10)

- **Scope.**
  - Internal plans, reviews and debug reports move to `docs/internal/` with a one-page index
    (plan 115 Q6; the alternative is a private repo).
  - The mstack tooling's `docs/plans/` path is kept working through config, or by leaving
    active plans in place and moving only archived ones. Choose by a check of what
    `mstack-run` and `pick-next` read.
  - CHANGELOG is restructured into real versions (plan 117's C6 policy).
- **Closes.** F8 (internal docs), SH-S12.
- **Size.** 3 h (this plan's estimate).
- **Risk.** Low. Plan cross-references must keep resolving.
- **Tests.** A link checker across `docs/`; mstack `plan-ref` still resolves.
- **Rollback.** `git revert`.
- **Depends on.** Plan 117's C6.
- **Needs Matthew's yes:** the public-repo change, and the location choice (Q6).

## Size summary

| Phase | h | Step | Source |
|---|---|---|---|
| D6a | 3 | 1 | this plan |
| D1 | 6 | 6 | Fable |
| D2 | 8 | 6 | Fable |
| D3 | 5 | 6 | Fable |
| D7 | 2 | 6 | this plan (part of the reviewer's 10) |
| D4 | 10 | 9 | Fable |
| D5 | 12 | 9 | Fable |
| D6b | 3 | 10 | this plan |
| **Total** | **49** | | |

## Out of scope

- Rewriting git history.
- A docs website or generator beyond Markdown in the repo.
- Moving plans out of the repo before mstack's paths are confirmed (D6b checks this first).
