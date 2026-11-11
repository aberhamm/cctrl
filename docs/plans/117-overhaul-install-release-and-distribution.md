---
id: 117
title: Overhaul C - safe installs, a real rollback, settings safety, releases and distribution
status: blocked
blocked-by: [115]
priority: 12
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-11-11
approval: "Operator approval on record (plan-only grant): PLAN ONLY. Run per phase under the orchestrator; never flip this plan to pending as a whole. Waits for Matthew's prioritisation from plan 115. Every install, the MacBook clean-up, the first public tag and the tap repo each need their own yes."
approved-by: pending (Matthew, via plan 115)
reviews: []
related: 115, 116, 121, 122, 079, 083, 102, 105, 107
---

Workstream C of the overhaul (umbrella: plan 115). It covers Fable's plan (c), audit option 8,
findings F5, F15, M9, M10, the reviewer's MF-M2 (the layout guard) and SH-S11, plus the
release and distribution gaps in SH-S13. Baseline is `main` at `8c249fc`.

## Problem

- `install/self-install.sh` checks only that tracked files are clean. It does not check the
  branch (a file-sync tool covering the checkout can switch it), that HEAD is pushed, or that
  no other install is running.
  It copies the launcher and checks `self-install.sh` from the working tree, not from the
  release under test. It runs the gate with whichever `bash` is first on PATH: 5.3 on the
  Studio, 3.2 on the MacBook. That is how two MacBook gate failures reached install day.
- There is no rollback command (`cmd_release` has only `prune`). The rollback the installer
  and README print (`ln -sf $ROOT/cctrl $CCTRL_BIN`) restores the working-tree symlink that
  plan 079 removed. Plan 107 cites `cctrl self rollback`, which does not exist.
- `_hooks_install` treats a malformed `~/.claude/settings.json` as `{}`. It then truncates and
  rewrites the file with only `hooks`, with no lock, no backup and no atomic rename. It pastes
  the path into Python source text. The Codex installer in the same repo does all of this
  correctly (`hooks/codex-hook-config.py`).
- `hooks doctor` warns about stale working-tree paths for Codex but treats them as issues for
  Claude, so the MacBook reports OK with two Codex hooks running working-tree code. Doctor
  checks that files exist, not that the guard blocks.
- `install.sh` still installs the old live symlink.
- `VERSION` holds the git SHA, there is no `--version`, 7 of 8 CHANGELOG sections are
  "[Unreleased]", and all tags are `mstack/plan-NNN-done`. A user can only install through a
  clone plus an 18-minute test gate, and there is no uninstall.

## Phases

### C3. Atomic settings write and `hooks uninstall` (step 2, moved up per SH-S11)

- **Scope.**
  - The Claude part of `_hooks_install` calls a shared Python routine,
    `lib/settings_write.py`. It is extracted from `hooks/codex-hook-config.py` and both
    installers use it. The routine:
    - takes a lock file;
    - parses strictly;
    - refuses a malformed or non-object file with a clear message, leaving it untouched;
    - writes an exact-byte backup (`settings.json.cctrl-backup-<stamp>`, keep the last 5);
    - writes an fsynced temp file in the same directory and calls `os.replace`, then fsyncs
      the directory;
    - preserves the file mode, key order and unknown keys.
  - The path is passed as an argument, never pasted into source.
  - `cctrl hooks uninstall [--agent claude|codex|all] [--dry-run]` removes only cctrl's
    entries, or restores a named backup.
- **Closes.** F5 (settings wipe), M9 (settings), SH-S11.
- **Size.** 8 h (Fable).
- **Risk.** Low. Strictly safer than today.
- **Tests.**
  - Malformed JSON, a non-object, an empty file, a symlinked file.
  - Concurrent installs.
  - Unknown keys and key order preserved; idempotence; the backup is written and capped.
  - Uninstall removes only cctrl entries, leaving gstack and other hooks.
  - A path with a quote in it.
  - kill -9 between the temp write and the replace leaves the original intact.
- **Rollback.** Previous release. The backup file restores any settings change.
- **Blocked by.** Nothing. It can run in parallel with A1.
- **Needs Matthew's yes:** the install on each Mac. Running `hooks install` afterwards is a
  normal operator act; it now refuses rather than wipes.

### C2. A real rollback, with a state-layout guard (step 3, before A2)

- **Scope.**
  - New commands:
    - `cctrl release list` (name, sha, install time, layout range, current/previous marks);
    - `cctrl release current`;
    - `cctrl release rollback [name] [--force] [--dry-run]`.
  - Rollback is an atomic re-point of `current` to the recorded previous release, or to a
    named complete one. It refuses a missing, incomplete or `.tmp-*` target.
  - The installer records the previous release in `$CCTRL_HOME/install-log.jsonl` (0600).
  - `release prune` always keeps the previous release and the rollback target, and rejects
    `--keep 0`.
  - **Layout guard (MF-M2).**
    - Each release ships `share/state-compat.json` with `{"layout_min":1,"layout_max":2}`
      (layout 2 is plan 116's A2). A release may declare `layout_max: 2` only if it carries
      A0's layout-2 resolver rule; a CI check ties the two, so the ids stay honest after A4
      removes the compat link (review S7).
    - A release without the file counts as layout 1 only.
    - `rollback` reads the current layout from the state marker and refuses a target that
      cannot read it, unless `--force` is given. `--force` prints what will break, and
      after A4's repoint the old release does read the state dir.
    - The guard ships **before** A2, so the first layout bump is protected.
  - The stale rollback text is removed from `self-install.sh`, `README.md` and plan 107, and
    replaced by `cctrl release rollback` plus the manual atomic recipe, written once in
    CONTRIBUTING (plan 122).
- **Closes.** F5 (rollback), M9 (rollback), MF-M2 (first half), F15 (plan 107 text).
- **Size.** 10 h (Fable).
- **Risk.** Low-medium. It touches the activation pointer.
- **Tests.**
  - Install, install, rollback, rollback again (back and forth).
  - Rollback during a running hook (the hook completes on the old target).
  - Prune never removes the rollback target; `--keep 0` is refused.
  - The guard: a layout-1 release is refused once the state marker says 2, and `--force`
    works.
  - A missing target, a `.tmp-*` target.
  - Rollback to a release whose launcher differs.
  - Rollback to a pre-A0 (layout-1) release when the live `data/config.json` is missing
    prints a warning that names plan 116's A0 runbook (review S5).
- **Rollback.** The manual atomic re-point, `ln -s` then `mv -fh current.next current`.
- **Blocked by.** Plan 116's A0 (the dormant layout-2 rule, so a release that declares
  `layout_max: 2` really reads layout 2; review S7). It must land before A2 (plan 116).
- **Needs Matthew's yes:** the install on each Mac.

### C1. Install preflight and lock (step 3)

- **Scope.** `self-install.sh` changes:
  - It requires branch `main` and `HEAD == origin/main` after a fetch.
  - **Offline:** it refuses unless `--allow-unpushed` is given. That flag prints a banner and
    records itself in the install log (reviewer: state the offline behaviour).
  - An install lock (A1's link protocol on `$CCTRL_HOME/install.lock`) stops two concurrent
    installs from fighting over `current.next`.
  - The launcher and the installer's own checks are taken from the release being installed,
    not the working tree.
  - `CCTRL_TEST_NAMES`, `CCTRL_TEST_ONLY` and `CCTRL_TEST_KEEP_GOING` are unset for the gate.
  - **Both bash legs** run when both exist (`/bin/bash` and the Homebrew bash). This is plan
    105 P5, absorbed here.
  - One install-log line per run: time, sha, previous release, gate result for each leg, and
    flags.
  - It writes A0's `.installed` marker after the gate passes.
- **Closes.** F5 (preflight), M9 (preflight and gate scope), F4 (part: install day stops being
  the first two-bash run).
- **Size.** 8 h (Fable).
- **Risk.** Low. Installs become stricter, which is the point. The gate doubles in time until
  E2 makes the suite parallel.
- **Tests (fixture repo in a temp `CCTRL_HOME` with a stub suite).**
  - A dirty tree; the wrong branch; unpushed; behind origin; offline with and without the
    flag.
  - Two installs at once.
  - A filter variable set in the environment.
  - One bash leg fails.
  - The launcher really comes from the release.
- **Rollback.** `git revert`; the installer is self-contained.
- **Blocked by.** Plan 116's A0 (the `.installed` marker) and A1 (the link-protocol lock
  helper used for `install.lock`). It must land before A2.
- **Needs Matthew's yes:** the install on each Mac. From then on, installs refuse unpushed
  trees.

### C4. Doctor parity, a functional self-test, and the MacBook (step 6)

- **Scope.**
  - `hooks doctor` treats stale absolute working-tree paths in Codex `hooks.json` as an issue,
    as it already does for Claude.
  <!-- tmux-lint: allow (a canned input the doctor feeds to the guard; never run it) -->
  - Doctor runs a **functional** check: it feeds the guard a canned `tmux kill-server`, and
    the `-L <primary>` form from option 1, and expects a block. A broken guard is an issue
    (M10).
  - **A swallowed guard exception becomes visible (review S16, M10).** Today an exception
    inside the PreToolUse guard is swallowed (`hooks/pre-tool-use.py`, the top-level
    handler) and the call is allowed. It stays fail-open by design (plan 079), but the
    handler now writes one stderr line and bumps a 0600 error counter in the state dir, and
    `hooks doctor` reports a non-zero count since the last check as an issue.
  - The kill guard covers only the Bash tool matcher. That is **accepted and stated** in
    SECURITY.md (plan 122's D2): the kill guard is about shell commands, and other tools
    cannot run tmux. Widening the kill guard's matcher is out of scope. (The separate
    state-file rule of plan 118's O4.4 does match Write, Edit and NotebookEdit, because
    those tools can write state files.)
  - `hooks install --agent codex` removes working-tree leaves, with the Codex installer's
    backup.
  - Then **one supervised session on the MacBook** clears its two stale Codex hooks
    (`block-git-commit.py`, `session-log.py` from `~/dev/cctrl/hooks`).
- **Closes.** M10 (doctor parity, tamper evidence in part, the swallowed exception; the
  Bash-only matcher is accepted), F5 (MacBook drift).
- **Size.** 6 h (Fable), plus about 1 h on the MacBook.
- **Risk.** Low.
- **Tests.**
  - Doctor fixtures for each stale form, for Claude and Codex.
  - The functional self-test with a guard that is missing, broken or always-allowing.
  - The installer cleans a fixture `hooks.json` and writes a backup.
  - A guard that raises: the call is allowed, one stderr line is written, the counter rises
    and doctor reports it (plan 121's E7 keeps it as a regression).
- **Rollback.** The Codex installer backup (`hooks.json.cctrl-backup-*`).
- **Blocked by.** C3 (the shared writer).
- **Needs Matthew's yes:** the install, and the supervised MacBook session.

### C5. Retire `install.sh` (step 6)

- **Scope.**
  - Replace `install.sh` with a short bootstrap that clones and runs `self-install.sh`, for
    maintainers. Users get C7's tarball and tap. Or delete it and point to C7.
  - `statusline install` writes the `current/` path, never a release path that dangles after
    prune.
- **Closes.** F15 (`install.sh`), part of M9.
- **Size.** 4 h (Fable).
- **Risk.** Low.
- **Tests.** The bootstrap in a temp HOME; a statusline path assertion.
- **Rollback.** `git revert`.
- **Blocked by.** C1.
- **Needs Matthew's yes:** a public-repo change (the old installer goes away).

### C6. SemVer source of truth and the release process (step 6)

- **Scope.**
  - A tracked `VERSION` holds the SemVer version (start at `0.9.0`).
  - The installer writes the git SHA to `BUILD`, not `VERSION`.
  - `cctrl --version` prints `cctrl 0.9.0 (<sha12>)`, and `--version --json` prints the
    layout range too.
  - CHANGELOG follows Keep a Changelog with real version sections. A CI check requires a
    CHANGELOG entry for any change under `cctrl`, `lib/`, `hooks/`, `src/` or `install/`,
    unless the PR is labelled `no-changelog`.
  - Tags `vX.Y.Z` (the `mstack/plan-*` tags stay).
  - A GitHub Release with notes copied from the CHANGELOG section (a CI job, on tag).
  - SemVer policy in CONTRIBUTING: CLI flags, `--json` shapes and exit codes are the public
    API.
- **Closes.** SH-S13 (release process), F6 (no version).
- **Size.** 3 h (this plan's estimate, part of the reviewer's 10 h for release, packaging and
  governance).
- **Risk.** Low.
- **Tests.**
  - `--version` text and JSON.
  - The CHANGELOG check on fixture diffs.
  - The release notes extraction.
- **Rollback.** `git revert`. A published tag stays published, so publish deliberately.
- **Blocked by.** C1 (installer), E0 (CI).
- **Needs Matthew's yes:** the first public tag and GitHub Release (v0.9.0 at stop 2b of plan
  115).

### C7. Distribution: tarball, Homebrew tap, `cctrl uninstall` (step 10)

- **Scope.**
  - **Tarball.** CI builds `cctrl-X.Y.Z.tar.gz` from the tag with `git archive` (the built
    single file, once plan 120's B1 exists), plus a SHA-256 checksum. The tarball install
    path skips the maintainer's test gate, because CI already ran the suite on that tag.
  - **Homebrew tap.** A formula in a separate public repo (`homebrew-cctrl`). It depends on
    bash, tmux, jq and python@3, and has a `test do` block that runs `cctrl --version` and a
    smoke command.
  - **`cctrl uninstall [--dry-run] [--purge]`.**
    - Removes the launcher, releases, the completions, cctrl's hook entries (C3) and cctrl's
      launchd agents.
    - Keeps the state dir and config unless `--purge` is given. `--purge` needs a typed
      confirmation and writes a tarball backup first.
    - It is dry-run by default.
- **Closes.** SH-S13 (packaging, uninstall).
- **Size.** 5 h (this plan's estimate, part of the reviewer's 10 h).
- **Risk.** Low.
- **Tests.**
  - Uninstall in a temp HOME after a fixture install: nothing of cctrl's is left except
    state, and `--purge` removes that too.
  - The tarball install in a temp HOME.
  - `brew audit --strict` on the formula, in CI on macOS.
- **Rollback.** Reinstall. Uninstall never touches state without `--purge`.
- **Blocked by.** C6, A4 (paths final), C3 (hooks uninstall).
- **Needs Matthew's yes:** creating the tap repo (public), and the v1.0 tag.

## Size summary

| Phase | h | Source |
|---|---|---|
| C3 | 8 | Fable |
| C2 | 10 | Fable |
| C1 | 8 | Fable |
| C4 | 6 + 1 supervised | Fable |
| C5 | 4 | Fable |
| C6 | 3 | this plan (part of the reviewer's 10) |
| C7 | 5 | this plan (part of the reviewer's 10) |
| **Total** | **44** (+1 supervised) | unchanged by the revision |

## Execution and acceptance criteria

- **Execution.** Run per phase under the orchestrator: C3 at step 2, C2 and C1 at step 3
  (both before plan 116's A2), C4-C6 at step 6, C7 at step 10. Never flip this plan to
  `pending` as a whole. The frontmatter `blocked-by: [115]` is a guard (115 stays `split`).
- [ ] C3: a malformed, non-object or empty `settings.json` is refused and left byte-identical;
  kill -9 mid-write leaves the original intact; uninstall removes only cctrl's entries.
- [ ] C2: `release rollback` round-trips; prune never removes the rollback target; the layout
  guard refuses a layout-1 target once the marker says 2; a release declares
  `layout_max: 2` only with A0's resolver rule.
- [ ] C1: installs refuse a dirty tree, the wrong branch, an unpushed HEAD and a concurrent
  install; both bash legs run; the launcher comes from the release.
- [ ] C4: doctor flags stale Codex paths and a broken or raising guard; the MacBook's stale
  hooks are gone.
- [ ] C5-C7: the bootstrap, `--version`, CHANGELOG check, tarball, formula audit and
  `cctrl uninstall` (state kept unless `--purge`) all pass in a temp HOME.

## Out of scope

- Signing releases or notarising. Revisit if a binary component appears.
- Package managers other than Homebrew.
- Changing the fail-open launcher contract (plan 079/083). It stays as it is.
