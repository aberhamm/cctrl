---
id: 121
title: Overhaul E - CI on hosted runners, a steady parallel suite, and the best-case test set
status: blocked
blocked-by: [115]
priority: 15
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-11-11
approval: "Operator approval on record (plan-only grant): PLAN ONLY. Run per phase under the orchestrator; never flip this plan to pending as a whole. Waits for Matthew's prioritisation from plan 115. Enabling Actions on the public repo needs his yes; tests need no install."
approved-by: pending (Matthew, via plan 115)
reviews: []
related: 115, 116, 117, 118, 119, 120, 122, 090, 095, 097, 105
---

Workstream E of the overhaul (umbrella: plan 115). It covers Fable's plan (e) and findings F4,
F7, F15 (skips) and F18, and parts of M9 and L6. It is revised for the independent review:
- MF-M8: the Linux decision;
- SH-S7: a coverage method that works;
- SH-S8: mutation, soak, crash, disk-full, escape and differential cases;
- SH-S9: the public-repo CI rules.

It absorbs the remaining phases of plan 105: P5 (both-bash gate) goes to plan 117's C1, and
P4-P6 (file split) go to E2. Baseline is `main` at `8c249fc`. The suite was not run for this
plan; timings come from earlier reports.

## Problem

- There is no CI, linter or coverage. The only automatic run is the install gate, one bash leg
  with whatever `bash` is first on PATH.
- 608 tests in one 25,111-line file, run in sequence: about 18 minutes, slower under load.
  Flakes on record are all load-related.
- 47 tests return "ok" when python3, perl or tmux is missing. Two tests are SKIPped with stale
  reasons. Ten `lib/` modules and four or five hooks have no unit tests.
- There are no hostile-input, malformed-settings, rollback or Linux runs.

## Rules for CI on this public repo (SH-S9, plan 115 Q4)

- **Hosted runners only; never a self-hosted runner** on the Studio or the MacBook. Fork PRs
  would run arbitrary code on a fleet machine.
- Actions are pinned by full SHA. Each workflow sets `permissions: contents: read` and has no
  secrets. Workflows use `pull_request`, never `pull_request_target` with a checkout of the
  PR.
- Deps come from Homebrew on the runner: tmux, bash 5, jq. `/bin/bash` 3.2 is the macOS
  system bash.

## Phases

### E0. CI skeleton (step 1)

- **Scope.** GitHub Actions jobs:
  - **lint:** shellcheck against a recorded baseline, `bash -n`, ruff, and `py_compile` on 3.9
    and the current Python;
  - **python:** the Python unit tests;
  - **smoke:** a fast macOS subset on every push, bash 3.2 and 5, chosen by `--list` tags;
  - **full:** both bash legs on macOS, on PRs and nightly;
  - **gitleaks;**
  - **deny-list:** plan 122's D6a, for private names and home paths in tracked files;
  - **hooks-no-python:** the hook contract tests with python3 removed from PATH. Hooks must
    fail open (SH-S8).
  - **Linux:** no Ubuntu leg unless plan 115 Q5 = supported (MF-M8). A permanently red or
    allowed-to-fail job reads worse than none.
- **Closes.** F4, M9 (no CI), SH-S8 (gitleaks, pinned Actions, hooks without python3), SH-S9.
- **Size.** 14 h (reviewer; Fable 8).
- **Risk.** Low. Runner time: the full run is 40+ minutes until E2, hence nightly and on PRs.
- **Tests.** The matrix itself. A deliberately broken branch must fail each job once, recorded
  in the verify.
- **Rollback.** Delete the workflow files.
- **Blocked by.** Nothing.
- **Needs Matthew's yes:** enabling Actions on the public repo. The workflow files are a
  public change.

### E1. De-flake and honest results (step 6)

- **Scope.**
  - Replace the four remaining wall-clock ceilings with call-count or alarm proofs.
  - Give the Codex schema probe its own deadline (plan 105 follow-up, option B).
  - Bound the two busy-wait loops.
  - **A missing tool is a reported SKIP locally and a FAIL in CI, never "ok".**
  - Fix or delete the two SKIPped tests. The mailbox one is fixed in plan 116's A1.
  - Fix the `ResourceWarning` from `hooks/tmux_kill_guard.py` (F18).
  - Per-test time budgets, and a quarantine list where each entry has an expiry date and an
    owner (SH-S8).
  - A nightly job that runs the suite five times under synthetic CPU load.
- **Closes.** F7 (flakes, silent ok), F15 (stale skips), F18, SH-S8 (budgets, quarantine).
- **Size.** 10 h (Fable).
- **Risk.** Low.
- **Tests.**
  - A guard test that no test compares elapsed time to a constant.
  - A guard that every quarantine entry has an unexpired date.
  - The stress job.
- **Rollback.** `git revert`.
- **Blocked by.** E0.
- **Needs Matthew's yes:** none (tests only).

### E2. Split the test file and run in parallel (step 6)

- **Scope.**
  - `tests/lib/`, holding the about 1,322 shared lines.
  - About 18 `tests/suite/NN-domain.sh` files along evidence C §8's seams.
  - The runner gains `--jobs N`, with one sandbox and one private tmux socket per file. The
    harness already creates one per run.
  - The registration and dead-test guards work across files.
  - Target: under 5 minutes on 8 cores.
  - This is plan 105 P4-P6.
- **Closes.** F7 (speed, shape).
- **Size.** 20 h (reviewer; Fable 14).
- **Risk.** Medium. There are hidden order dependencies, and helpers are defined mid-file.
- **Tests.**
  - Each file alone, and in random order, in CI.
  - The sorted list of passed tests equals the pre-split list (plan 105's no-loss proof).
- **Rollback.** `git revert` (tests only).
- **Blocked by.** E1.
- **Needs Matthew's yes:** none.

### E3. Unit tests (step 8)

- **Scope.**
  - Python unit tests for every module without them, starting with `peer_seal`,
    `snapshot_restore`, `release_prune` and `usage_costs` (`cctrl costs` and `cctrl usage` are
    almost untested).
  - Bash unit tests for pure functions, by sourcing single `src/sh` modules in the existing
    harness. No second framework.
- **Closes.** F7 (unit gaps), L6.
- **Size.** 20 h (Fable). About 250 cases.
- **Risk.** Low.
- **Tests.** The new cases are the deliverable. Check: each named module has a test file;
  every new test fails when its target function is stubbed to return a wrong value (a
  one-off sabotage run recorded in the verify); the suite stays inside E1's time budgets.
- **Rollback.** n/a.
- **Blocked by.** Plan 120's B0 and B1.
- **Needs Matthew's yes:** none.

### E4. Hostile input and security cases (step 5, before the hardening phases)

- **Scope.**
  - Bodies and subjects with ESC, `ESC[201~`, CR, NUL, BEL, a leading `/` or `!`, a forged
    envelope line, 1 MB, and mixed Unicode.
  - Names and labels through the validator.
  - **Kill guard regressions for option 1:** `-L fleet`, normalised `-S` paths, `$'…'`. These
    now pass, and stay as regressions.
  - `hosts.json` values starting with `-`.
  - `CCTRL_NOW_UTC` outside test mode.
  - **Output-escape tests (SH-S8):** `peer inbox`, `show` and `recv` printing hostile bodies
    to a pty must not emit raw ESC or CR to the operator's terminal.
  - Cases that expose open audit findings are recorded as **expected failures keyed to the
    audit id** (M3, M4, M5, M6, M11, H1, H2, H4). They flip to passing when plans 118 and 119
    land, and never block unrelated work.
- **Closes.** L6 (no hostile tests), SH-S8 (escape output).
- **Size.** 12 h (Fable). About 80 cases.
- **Risk.** Low.
- **Tests.** Every expected failure names its audit id and fails today for the stated reason
  (not a harness error); a guard test fails if an expected failure starts passing without
  its marker being removed; the output-escape cases run on a real pty.
- **Rollback.** n/a.
- **Blocked by.** E0.
- **Needs Matthew's yes:** none.

### E5. Mailbox corruption and concurrency, as a named suite (step 8)

- **Scope.** Plan 116's A1 set is kept as `tests/suite/mailbox-integrity.sh`. It runs on both
  lock kinds and both bashes, with fault injection at every write step, plus the
  old-release-writer case.
- **Closes.** F3 and L2 (test side).
- **Size.** 6 h beyond A1 (Fable).
- **Risk.** Low.
- **Tests.** The named suite runs on both lock kinds and both bashes; a fault injected at each
  write step leaves a readable mailbox with no lost message; the old-release writer case and
  the three-party steal case (plan 116's A1) are included.
- **Rollback.** n/a.
- **Blocked by.** A1, E2.
- **Needs Matthew's yes:** none.

### E6. Approvals doc-lint (step 6)

- **Scope.** A doc-lint test that the APPROVALS block in the skills matches the usage of
  plan 119's `cctrl approvals check`, and the real record shape. The command's own parser
  tests are in O7.
- **Closes.** M8 (drift).
- **Size.** 3 h (Fable). Separate from O7's own 8 h; no double count.
- **Risk.** Low.
- **Tests.** The lint fails on a fixture skill whose block drifts from the command's usage, and
  passes on the real skills.
- **Rollback.** n/a.
- **Blocked by.** Plan 119's O7.
- **Needs Matthew's yes:** none.

### E7. Install and rollback suite (step 6)

- **Scope.**
  - Plan 117's C1, C2 and C3 fixtures as a permanent suite.
  - Interruption at each installer step.
  - After plan 116's A4: no release ever links into a working tree.
  - Hooks fail open with python3 missing, a syntax error, or the release missing.
  - A raising PreToolUse guard is allowed, logs one stderr line and bumps the counter that
    `hooks doctor` reports (plan 117's C4; review S16).
- **Closes.** M9 (no install tests), L6, M10 (the swallowed-exception regression).
- **Size.** 4 h beyond plan 117 (Fable).
- **Risk.** Low.
- **Tests.** The suite is the deliverable. Check: an interruption at each installer step
  leaves either the old or the new release active, never neither; each fail-open case
  exits 0 with one stderr line.
- **Rollback.** n/a.
- **Blocked by.** C1, C2, C3.
- **Needs Matthew's yes:** none.

### E8. Remote exec over ssh, mocked (step 8)

- **Scope.**
  - A fake `ssh` that really executes the received command string under `zsh -c` and
    `bash -c` in a sandbox HOME.
  - Bodies with quotes, newlines and a leading `=`.
  - Hostile host values, and `--` present in every argv (plan 119's O12).
  - Unknown-name routing and ambiguity.
  - Version skew in both directions (plan 120's B7, plan 118's O3.4).
- **Closes.** M11 and L4 (test side), L6.
- **Size.** 8 h (Fable). About 30 cases.
- **Risk.** Low.
- **Tests.** The fake `ssh` itself has a self-test (it runs the received string under both
  shells and records argv); each case asserts the exact argv, including `--`, and the remote
  result.
- **Rollback.** n/a.
- **Blocked by.** E2.
- **Needs Matthew's yes:** none.

### E9. Property and fuzz tests (step 8)

- **Scope.** Python `hypothesis` (dev-only):
  - message round-trip;
  - seal sign and verify;
  - the name validator;
  - store invariants under random operation sequences;
  - the kill-guard parser never crashes, and blocking is stable under quoting changes;
  - quoting round-trips through real bash 3.2 and 5.

  Plus a small generator loop for bash-side validators.
- **Closes.** F7 (depth).
- **Size.** 12 h (Fable).
- **Risk.** Low.
- **Tests.** Each property runs with a fixed seed in CI and a random seed nightly; a failing
  example is saved to the hypothesis database and replayed as a regression.
- **Rollback.** n/a.
- **Blocked by.** B0.
- **Needs Matthew's yes:** none.

### E10. Integration on an isolated tmux socket (step 8)

- **Scope.**
  - A scripted fake agent TUI that replays pane fixtures: prompt, modal, busy, draft, and a
    modal raised mid-delivery.
  - End to end: send, deliver, ack.
  - A split-pane target (audit M1, plan 119's O6a).
  - A second server; close and reap.
  - **A detached-tmux caller, a `script` caller, an argv[0]-spoofed root and a `pty.fork`
    caller for the classifier** (MF-M6 and the plan 115 review's MUST-FIX 1, plan 118).
  - A separate, slower CI job with a pinned tmux version.
- **Closes.** M1, M2, MF-M6 (test side).
- **Size.** 20 h (reviewer; Fable 12).
- **Risk.** Medium. Real tmux in CI.
- **Tests.** Each scenario runs on its own private socket and leaves no server behind (checked
  after the job); the fake agent's fixtures are replayed through both detectors; the job is
  run three times in a row on the verify to show it is steady.
- **Rollback.** n/a.
- **Blocked by.** E2. It must land before plan 120's B6.
- **Needs Matthew's yes:** none.

### E11. Coverage that works (step 10; SH-S7)

- **Scope.**
  - **Python:**
    - `coverage.py` with `COVERAGE_PROCESS_START` and a `sitecustomize`, so subprocesses
      are measured.
    - `peer_seal.py` runs under `python3 -I -S`, which coverage cannot see, so it gets
      direct unit tests and is excluded from the subprocess figure.
    - Gate: 85% of lines overall, and 90% with branches for `store/` and `peer/`.
  - **Bash:**
    - bashcov (xtrace via `BASH_XTRACEFD`, which needs bash 4.1+) on the macOS bash 5 leg,
      after a half-day trial against kcov's macOS support.
    - `BASH_ENV` to follow child processes; the tests that scrub env are listed as blind
      spots.
    - Measure the **built** `cctrl` and map lines back to `src/sh` with plan 120's B1 build
      manifest.
    - No 3.2 coverage exists, and that is stated.
    - Report first, then a ratchet that never goes down, aiming at 70% of `src/sh`.
  - Numbers go in the job summary and a README badge.
- **Closes.** F4 (coverage), SH-S7, MF-M8 (no Linux dependency).
- **Size.** 16 h (reviewer; Fable 8).
- **Risk.** Low. The tools are slow; it runs nightly.
- **Tests.** A fixture subprocess call shows up in the Python figure; a fixture bash function
  run in a child shows up in the bash figure, mapped to its `src/sh` line; the ratchet job
  fails on a planted coverage drop.
- **Rollback.** n/a.
- **Blocked by.** B1, E2.
- **Needs Matthew's yes:** none (the badge is part of plan 122's D1 README change).

### E12. Mutation, soak, crash, disk-full and differential fuzz (step 8; SH-S8)

- **Scope.**
  - **Mutation testing** (mutmut, dev-only) on the security pure functions:
    - seal and verify;
    - eligibility;
    - the kill-guard parser;
    - the say/caller gate tables and the classifier.

    Surviving mutants are triaged, and each gets a test or a recorded reason.
  - **Nightly soak** on a private socket: N fake agents exchanging mail for 15 minutes, with
    gc and the doorbell on. No lost mail, bounded file growth, no leaked sockets.
  - **Crash consistency** for the other stores: `peers.json`, `shortcuts.json`, `sessions/`,
    the ring state, the plan 118 logs, and the `hooks/session-log.py` race.
  - **ENOSPC and a read-only filesystem**, on a small disk image (`hdiutil`) mounted for the
    test: every writer fails cleanly, and no file is truncated.
  - **Differential fuzz:** hypothesis operation sequences fed to both the `sh` and `py`
    implementations during plan 120's B3-B7, diffing outputs and states.
- **Closes.** SH-S8.
- **Size.** 10 h (reviewer, "mutation + soak"). This is lean for the full list. If it
  overruns, the disk-image cases move to a follow-up, and that is the first thing to cut.
- **Risk.** Low.
- **Tests.** A planted mutant in the seal verify is killed; the soak job fails on a planted
  lost message; the disk image is always detached after the test, even on failure.
- **Rollback.** n/a.
- **Blocked by.** B0, B3 (the differential part), E10 (the soak harness).
- **Needs Matthew's yes:** none.

### L1. Linux port (step 9; only if plan 115 Q5 = supported; MF-M8)

- **Scope.**
  - Portable shims for `stat -f`, `date -j`, `readlink -f` and `mv -fh`.
  - Plan 116's A1 lock protocol on Linux (no shlock).
  - systemd timer and cron for A3; the `launchctl`, `sysctl` and `vm_stat` paths guarded.
  - An Ubuntu CI leg (bash 5 and a 3.2 container) that is **blocking**.
- **Closes.** MF-M8 (if supported).
- **Size.** 25 h (reviewer).
- **Risk.** Medium.
- **Tests.** The full suite on Ubuntu.
- **Rollback.** `git revert`.
- **Blocked by.** E2, and plan 116's A1 and A3.
- **Needs Matthew's yes:** the Q5 decision itself.

## Size summary

| Phase | h | Source |
|---|---|---|
| E0 | 14 | reviewer |
| E1 | 10 | Fable |
| E2 | 20 | reviewer |
| E3 | 20 | Fable |
| E4 | 12 | Fable |
| E5 | 6 | Fable |
| E6 | 3 | Fable |
| E7 | 4 | Fable |
| E8 | 8 | Fable |
| E9 | 12 | Fable |
| E10 | 20 | reviewer |
| E11 | 16 | reviewer |
| E12 | 10 | reviewer (new) |
| **Total** | **155** | |
| L1 (optional) | 25 | reviewer |

The revision of plans 115-122 changed no size here.

## Execution and acceptance criteria

- **Execution.** Run per phase under the orchestrator: E0 at step 1, E4 at step 5, E1, E2, E6
  and E7 at step 6, E3, E5 and E8-E10, E12 at step 8, E11 at step 10. Never flip this plan to
  `pending` as a whole. The frontmatter `blocked-by: [115]` is a guard (115 stays `split`).
- [ ] E0: every job fails once on a deliberately broken branch (recorded); Actions are pinned
  by SHA; no workflow has secrets or `pull_request_target`; no self-hosted runner.
- [ ] E1: no test compares elapsed time to a constant; a missing tool is SKIP locally and FAIL
  in CI; every quarantine entry has an owner and an unexpired date.
- [ ] E2: the sorted list of passed tests equals the pre-split list; the parallel run is under
  5 minutes on 8 cores.
- [ ] E4: every open audit finding has an expected-failure case keyed to its id.
- [ ] E5-E12: each named suite runs in CI (nightly where stated) and meets its own Tests line.
- [ ] Every test is hermetic: no live fleet, live mailbox or live seal key (plan 116's
  test-mode gate refuses the live key).

## Out of scope

- bats or any second framework.
- Windows.
- Running any test against the live fleet. Every test is hermetic.
