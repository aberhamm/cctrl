---
id: 115
title: cctrl overhaul and hardening (umbrella) - data safety, install safety, security track, tests, docs, modules
status: split
blocked-by: []
priority: 10
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-11-11
updated: 2026-11-11
approval: "Operator approval on record (plan-only grant): PLAN ONLY. Building any phase waits for Matthew's prioritisation from this file. Installs, the data migration on each Mac, enforce flips, history decisions and public-repo changes each need their own yes (see 'Needs Matthew's yes')."
approved-by: pending (Matthew prioritises from the summary below)
reviews:
  - type=eng verdict=ready-with-changes date=2026-11-11 by=opus-subagent (independent; 2 must-fix, 17 should; applied in this revision, see 'Second review')
related: 116, 117, 118, 119, 120, 121, 122, 039, 040, 041, 049, 105, 107, 111, 114
---

Umbrella plan. It is split into seven workstream plans, 116 to 122, and is not
implemented directly (status `split`, as plan 075). This file holds the
summary, the ranking, the sequence, the stopping points, the traceability
tables, the decisions and the open questions. Each workstream file stands on
its own and has the per-phase detail.

## Split into

| Plan | Workstream | Phases | Build h |
|---|---|---|---|
| 116 | A: data store safety and the move out of the checkout | A0-A4 | 78 |
| 117 | C: installs, rollback, settings safety, releases | C1-C7 | 44 |
| 118 | O3/O4: say gate, caller checks, sealed role grants | O3.1-O3.5, O4.1-O4.4 | 88 |
| 119 | O5-O12: the other audit hardening | O5, O6a, O6b, O7, O12 | 46 |
| 120 | B: bash modules and the Python core | B0-B8 | 180 |
| 121 | E: CI, a steady suite, the best-case test set | E0-E12 (L1 optional) | 155 (+25) |
| 122 | D: docs, security statement, public-repo hygiene | D1-D7 | 49 |
| | **Total** | | **640** (+25) |

Each of 116-122 has `blocked-by: [115]`. Because this umbrella stays `split` and is never
`done` until the end, `mstack-run`'s picker can never select a workstream plan even if
someone flips it to `pending`. Phases are run one at a time under the orchestrator, each with
its own "Blocked by" line.

## Summary (prioritise from this)

1. cctrl works and is well tested, but its live data sits in the git checkout, one bad mailbox line stops all mail, the hooks installer can wipe `~/.claude/settings.json`, and there is no rollback command and no CI.
2. The audit's main security holes are still open: unlogged `say` into any session (H1), self-assignable roles (H2) and draining another session's mail (H4). The kill guard and fail-closed mode (options 1 and 2) are done and installed.
3. The plan has 10 steps in 7 workstreams (plans 116-122). D6a, a small privacy tip-clean, goes first. Data-loss and install safety come next. The security checks in warn mode can start as soon as steps 1-2 are done, alongside the data move. Then tests and docs, then the module split and the Python move.
4. Total: **640 build hours**, or a **budget of about 830 h** with a 30% contingency for re-runs, soak and verify rework. Supervised sessions (about 4 h) are extra. Linux support would add 25 build h (35 budgeted).
5. **First safe stop: 106 build h (budget 140).** At that point settings cannot be wiped, a bad mail line is quarantined, there is a real rollback command, installs are preflighted, data has left the checkout on both Macs, and CI runs on every push.
6. Second stop: 210 build h (budget 275). Every audit security check runs in **warn** and logs who said or changed what. Enforce stays your separate call.
7. **The operator class is weaker than the first draft said.** Any agent can open a genuine Terminal window with `open -a Terminal x.command`, which no process check can tell apart from you. The plan now recommends a `sudo`/Touch ID confirmation on your own grant acts (Q10). It guards the sanctioned path only: an agent that reads the seal key can still mint a grant directly. On the Studio, Touch ID needs a Touch ID keyboard; otherwise it is your password. Grant acts also need you at each Mac's screen: not over SSH, not in iTerm2 until checked, and again after every power cycle unless you choose the re-anchor option.
8. **The data migration is a supervised live change on each Mac.** Before each run you get a writer inventory and a corrected list of what the window can affect: the live copy of each whole-file store is always kept (a stray near-empty copy written by an old release never replaces it, and its change is kept aside for review), and hook writes skipped in the window (session-log spending lines, doorbell rings) are dropped, not queued.
9. Each install, each Mac's data migration, each enforce flip and each public-repo change needs your yes. The plan proposes **one install yes per step per Mac** (about 20) instead of one per phase (about 70). There are 12 open questions below; six are needed before any work.

## Sources and conventions

- Fable review (architecture and quality, plans (a)-(e), findings **F1-F18**): internal review, not in the repo, with its evidence A-F.
- Fable security audit (findings **H1-H4, M1-M11, L1-L6**, options 1-11): internal review, not in the repo.
- First independent review of (a)-(e) and options 3/4: internal, not in the repo. Its MUST-FIX items are cited as **MF-M1 to MF-M8** and its SHOULD items as **SH-S1 to SH-S15**. The prefix keeps them apart from the audit's M1-M11.
- Second independent review, of plans 115-122 themselves: internal, not in the repo. Its items are cited as **R2-MF1, R2-MF2** and **R2-S1 to R2-S17**.
- Re-check of that revision: internal, not in the repo. Its items are cited as **R3-MF1, R3-MF2** and **R3-S1 to R3-S9**.
- Option 3 and option 4 drafts: internal, folded into plan 118 and revised there.
- Baseline: `main` at `8c249fc`. Audit options 1 and 2 are DONE and installed: `0135e89` and `8c249fc` (the kill guard knows the primary and extra servers, the `$'...'` pre-check is fixed, and an unknown attestation mode fails closed). H3 is closed; plan 121 keeps its regression tests.
- Phase ids: **A** data (116), **C** install and release (117), **O3/O4** say gate and caller checks (118), **O5-O12** other audit hardening (119; O12 is a name, not an audit option), **B** modules and Python (120), **E** tests and CI (121), **D** docs and public project (122), **L1** the optional Linux port (121).
- Line numbers drift. The workstream files cite functions and files first, and line numbers only as "about, at 7742883".

## Common rules for every phase

- Each phase is one or more commits that leave `main` installable. Each is gated by the full suite on `/bin/bash` 3.2 and Homebrew bash 5, and by CI once E0 lands.
- Each phase ends with a verify by a different worker. Under the standing operator approval on record, the orchestrator pushes its own repo after that verify. **Installing on either Mac always needs Matthew's yes** (batched per step, see below).
- Rollback always starts with "activate the previous release" plus `git revert`. Before C2 that means re-pointing `current` with the atomic `ln -s … current.next && mv -fh current.next current` recipe. After C2 it means `cctrl release rollback`. Any extra steps for state changes are named in the phase.
- All tests are hermetic. They use a private `TMUX_TMPDIR` and socket, the sandboxed `CCTRL_*` and XDG paths, and never the live fleet, the live mailbox or the seal key. From A0 on, test mode refuses to run with the live seal key (R2-S10).
- New modes ship in **warn**. An unknown mode value fails closed, matching option 2.
- Interfaces frozen through plan 120: everything in Fable §4(b)'s byte-compatible list, plus the security track's artifacts (exit code 77, `say_gate`, `caller_checks`, `role_grant`, `--operator`, `--raw`, `session say-verify`, `say.jsonl`, `admin.jsonl`, the `[cctrl say]` line, and the class field in `CCTRL_ORIGIN_ATTEST`). This is MF-M7.

## Ranked phases

Rank = step order. Security and data-loss items come first. Sizes are **build** agent-hours, each including its own verify; the contingency is applied per stop below. The **Src** column says where a size comes from:
- **R**: the first reviewer's revised size (used wherever it differs from Fable's);
- **F**: Fable's size, which the reviewer accepted;
- **O→R**: an option 3/4 draft size, rescaled to the reviewer's 40 h and 35 h totals;
- **P**: this plan's own estimate, for work nobody had sized;
- **+Pn**: n hours added by the second review's revision (R2) and the re-check (R3).

| Step | Phase | What ships | Closes | h | Src | Risk | Needs Matthew's yes | Plan |
|---|---|---|---|---|---|---|---|---|
| 1 (first) | D6a | Privacy tip-clean: repo-label map out of the source and into config, ops note out of `TODOS.md`; deny-list grep in CI once E0 exists | F8, R2-S17 | 3 | F | Low | Public-repo change; no history rewrite | 122 |
| 1 | E0 | CI on hosted runners: lint, Python tests, macOS bash 3.2 and 5; smoke subset per push, full run on PRs and nightly; gitleaks; Actions pinned by SHA | F4, M9 (no CI), SH-S8 part, SH-S9 | 14 | R | Low | Enable Actions on the public repo; the workflow is a public change | 121 |
| 1 | A0 | One path resolver (shell and Python, no cctrl spawn per call) with the dormant layout-2 and sentinel rules; private modes; shipped config default moved out of `data/` with a keep-the-file runbook; installed-mode marker with no env signal; the test-mode gate (refuses the live seal key) | F10, F2 prep, L1 modes, MF-M1, SH-S2, SH-S3, R2-S5, R2-S6, R2-S7, R2-S10 | 14 | R +P2 | Low | Install on each Mac (one-time chmod of live files); the config runbook on each checkout | 116 |
| 2 | A1 | Mailbox hardening, lock protocol shlock-compatible with the stale steal spelled out; quarantine, backups, same-dir fsync rename, `peer repair`, `v` field, locked `peers.json`/`shortcuts.json`; writers honour the `.migrating` sentinel and never `mkdir -p` the data dir | F3, L2, MF-M4, SH-S1, R2-MF2 (writers), R2-S9, R3-MF2, R3-S5, R3-S7, R3-S8; plan 049 items 1-2 | 24 | R +P4 | Medium | Install on each Mac | 116 |
| 2 | C3 | Atomic `~/.claude/settings.json` write (lock, strict parse, backup, `os.replace`); `cctrl hooks uninstall` | F5, M9, SH-S11 | 8 | F | Low | Install on each Mac | 117 |
| 3 | C2 | `cctrl release list/current/rollback`, with a state-layout guard that ships before A2 | F5, M9, MF-M2, R2-S7 | 10 | F | Low-medium | Install on each Mac | 117 |
| 3 | C1 | Install preflight (main == origin/main, install lock, launcher from the release, both bash legs, filter vars unset, offline rule) | F5, M9, F4 part; plan 105 P5 | 8 | F | Low | Install on each Mac | 117 |
| 4 | A2 | `cctrl state migrate`: sync canary, writer inventory, sentinel, locks across the backup, marker flip, state-copy-wins merge, symlink compat, split-brain guard; MacBook first, then Studio | F2, L1, F13, MF-M3, MF-M5, SH-S3, SH-S4, R2-MF2, R2-S2, R3-MF1, R3-S4, R3-S6 | 25 (+2 supervised) | R +P5 | Medium-high | **The migration on each Mac**, after reading the writer inventory and the losable-writes list; Matthew reads the file-sync scope and adds excludes; install | 116 |
| 5 | E4 | Hostile-input tests, with expected failures keyed to audit ids; output-escape tests | L6, SH-S8 part | 12 | F | Low | None (tests only) | 121 |
| 5 | O3.1 | Caller classifier (small Python module) with `proc_pidpath` and the tty rule; say gate in warn; sealed `say.jsonl`; `--operator` parsed; supervised `open`/osascript/iTerm2 check | H1, M5 part, MF-M6, MF-M7, R2-MF1, R2-S4 | 22 (+1 supervised) | O→R + P6 +P4 | Low (warn) | Install on each Mac; the supervised check | 118 |
| 5 | O3.2 | `[cctrl say]` provenance line, slash and `--raw` exemptions, `session say-verify` | H1 | 9 | O→R | Medium (pasted bytes change) | Install; skills and APPROVALS wording | 118 |
| 5 | O4.1 | Caller checks on set-role, `start --role orchestrator`, the second-FM override and the doorbell mutators; `admin.jsonl`; the `sudo`/Touch ID confirmation on the operator grant path (Q10) | H2, R2-MF1, R3-S1 | 12 | O→R +P2 | Low (warn) | Install on each Mac | 118 |
| 5 | O4.2 | Sealed `role_grant` (with the conversation id); attest and eligibility read it; `--regrant-live`; optional post-boot re-anchor against sealed data, with a caller rule (Q10) | H2, R2-S14, R3-S2 | 14 | O→R +P1 | Medium | Install; Matthew runs `--regrant-live` in Terminal at each Mac's screen, and after each power cycle | 118 |
| 5 | O4.3 | Mailbox read and ack bound to the caller; gc of unread mail limited to FM and operator; archive 0600 | H4 | 9 | O→R | Low (warn) | Install on each Mac | 118 |
| 5 | O5 | Envelope hardening (subject validation, random fence, C0 strip on display); `CCTRL_NOW_UTC` and the other overrides wired to A0's test-mode gate | M3, M4, M5 | 7 | P | Low | Install on each Mac | 119 |
| 5 | O6a | Pane-id targeting for check, capture, paste and Enter | M1 | 6 | P | Medium | Install on each Mac | 119 |
| 5 | O12 | Ring cap per sender with reserve, corrupt state counted as at-cap; fail closed on a server-probe timeout; host values validated and `--` before ssh targets; L4 quoting | M6 (audit), M7 short-term, M11, L4 | 13 | P | Low | Install on each Mac | 119 |
| 6 | A3 | `cctrl state gc` plus retention and a launchd template; statusline appends less; locked `session-log.py` | F9, L3, F3 | 8 | F | Low-medium | Plist install on each Mac; install | 116 |
| 6 | C4 | Codex doctor parity, functional guard self-test, swallowed guard exceptions counted, MacBook stale hooks cleaned | M10, F5, R2-S16 | 6 (+1 supervised) | F | Low | One supervised MacBook session; install | 117 |
| 6 | C5 | Retire `install.sh`; `statusline install` writes the `current/` path | F15 | 4 | F | Low | Public-repo change | 117 |
| 6 | C6 | SemVer source of truth, `cctrl --version`, CHANGELOG policy and check, GitHub Releases | SH-S13, F6 | 3 | P (part of R's 10) | Low | First public tag and release (v0.x) | 117 |
| 6 | O7 | `cctrl approvals check <id>` plus a corrected APPROVALS block | M8 | 8 | P | Low | Install; skills change | 119 |
| 6 | E1 | De-flake, fix or delete the SKIPs, missing tool = SKIP locally and FAIL in CI, time budgets with a quarantine expiry | F7, F15, F18, SH-S8 part | 10 | F | Low | None | 121 |
| 6 | E2 | Split the test file and run it in parallel (absorbs plan 105 P4-P6) | F7 | 20 | R | Medium | None | 121 |
| 6 | E6, E7 | Approvals doc-lint; install and rollback suite, hooks fail open without python3 | M8, M9, SH-S8 part | 3 + 4 | F | Low | None | 121 |
| 6 | D1-D3 | README of at most ~300 lines; architecture plus SECURITY.md (states the revised MF-M6 residual); CONTRIBUTING | F6, SH-S13, MF-M6 statement | 6 + 8 + 5 | F | None | Public-repo change | 122 |
| 6 | D7 | CODE_OF_CONDUCT, CODEOWNERS, branch protection with required checks, PR workflow, private vulnerability reporting | SH-S13 | 2 | P (part of R's 10) | Low | Repo settings on the public repo | 122 |
| 7 | O3.3 | say-gate enforce code path (live stays warn), exit 77, enforce refusals for `--operator` | H1 | 7 | O→R −1 | Low | Install on each Mac | 118 |
| 7 | O3.4 | Remote say: origin-side gate, class carried in `CCTRL_ORIGIN_ATTEST` | H1 | 6 | O→R | Low | Install on each Mac | 118 |
| 7 | O3.5 | PreToolUse rule matching resolved paths (`--operator`, `CCTRL_ORIGIN_ATTEST=`) | H1, MF-M7 | 5 | O→R | Medium | Changes `settings.json` and Codex `hooks.json` on each Mac | 118 |
| 7 | O4.4 | Docs and skills (incl. the power-cycle regrant in the restore runbook); a hook rule for writes to state files, by resolved path, for Bash and the Write/Edit/NotebookEdit tools | H2, MF-M7, R2-S14, R3-S3 | 4 | O→R +P1 | Low | Same as O3.5 | 118 |
| 7 | (flips) | Enforce flips, in order: `say_gate`, then `caller_checks`, then `attestation` | H1, H2, H4 | 0 | n/a | Medium | **Each flip is its own yes** | 118 |
| 8 | B0-B7 | Python package; byte-identical bash split; prelude and errors; mailbox, attest (absorbs the classifier and grants), doorbell, delivery and peer CLI in Python | F1, F11, F12, F12b, F14, F16, F17, L6, SH-S5, SH-S6 | 10+8+10+32+26+14+32+12 = 144 | R | Medium-high | Install per step | 120 |
| 8 | O6b | Post-paste verification, inverted modal detection, unique buffers (plans 040/041), built in Python on B6 | M2 | 12 | P | High | Install | 119 |
| 8 | E3, E5, E8-E10, E12 | Unit tests; corruption set; mocked ssh; property and fuzz tests; isolated-tmux integration; mutation, soak, crash and disk-full cases, differential fuzz | F7, L6, SH-S8 | 20+6+8+12+20+10 = 76 | F / R | Low-medium | None | 121 |
| 9 | B8 | The rest of bash; command table that generates help and completions | F1, F6 part, F12b, F14 | 36 | R | Medium | Install | 120 |
| 9 | D4, D5 | Generated CLI reference and `--help`; module headers, data formats, JSON Schemas | F6 | 10 + 12 | F | Low | Public-repo change | 122 |
| 9 | A4 | Remove the compat symlink after a quiet period; repoint **every** retained release; scan configuration for working-tree paths | F2, MF-M2, R2-S7, R2-S8 | 7 | R +P1 | Low | Install; the repoint on each Mac | 116 |
| 9 | L1 | Linux port (only if Q5 = supported) | MF-M8 | (25) | R | Medium | Q5 | 121 |
| 10 | D6b | Internal plans to `docs/internal/`, CHANGELOG in real versions, commit-message policy for internal ids | F8, SH-S12 | 3 | F | Low | Public-repo change; history stays as is | 122 |
| 10 | E11 | Coverage that works: `coverage.py` across subprocesses, bash coverage on bash 5 mapped to `src/sh`, ratchet | F7, SH-S7 | 16 | R | Low | None | 121 |
| 10 | C7 | Release tarball, Homebrew tap, `cctrl uninstall` | SH-S13 | 5 | P (part of R's 10) | Low | Create the tap repo (public); v1.0 tag | 117 |

## Sequence, dependencies and safe stops

```
0 decisions needed before stop 1: Q1 Q2 Q3 Q4 Q6 Q12        no code
1 D6a (first commit), E0 + A0  -> 2 A1 + C3 -> 3 C2 + C1 -> 4 A2 (MacBook, soak 1 day, Studio)
                                         |                          [STOP 1: 106 h, budget 140]
                                         +-> 5 E4, O3.1, O3.2, O4.1-O4.3, O5, O6a, O12 (all warn)
                                             (may start once steps 1-2 are done; runs alongside 3-4)
                                                                     [STOP 2: 210 h, budget 275]
                                             then one week of warn
6 A3, C4, C5, C6, O7, E1, E2, E6, E7, D1-D3, D7                      [STOP 2b: 297 h, budget 385]
7 O3.3-O3.5, O4.4; enforce flips are separate decisions               [STOP 3: 319 h, budget 415]
8 B0, B1, B2, then B3..B7 (+O6b after B6); E3, E5, E8-E10, E12 alongside  [STOP 4: 551 h, budget 715]
9 B8, D4, D5, A4 (after quiet period, C4, C5), L1 if chosen          [616 h, budget 800]
10 D6b, E11, C7, v1.0                                                 [STOP 5: 640 h, budget 830]
```

Dependencies that matter (each phase lists all of its own in its "Blocked by" line):
- A0 comes before everything that touches a path: A1, A2, A3, C1, C2, all of 118 (MF-M7), O5, E7 and D2.
- C2's layout guard must ship **before** A2 (MF-M2). A2 also needs A0, A1, C1, C2, the Q1 canary and the Q3 decision.
- **The security track needs A0 + A1, not A2 (R2-S3).** O3.1-O4.3, O5, O6a and O12 can start once step 2 is done, in parallel with steps 3-4. If the canary crosses or the soak finds a problem, H1, H2 and H4 warn-logging still proceed. Only the O3.5/O4.4 hook rules (step 7) need post-A2 paths. This is a prioritisation point for Matthew: it runs two tracks at once.
- O3.1 (the classifier, and `--operator`) comes before O3.2-O3.5, O4.1-O4.4 and A3's plist (R2-S4). O4.2 (grants) comes before any attestation enforce flip.
- The enforce flips need one week in warn with zero unexplained `would-refuse`, the skills changes (O3.2, O4.4), and, for attestation, O4.2.
- E1 and E2 come before B3 (no refactor of the delivery path on a slow, flaky suite). B1 comes before E11's mapping to `src/sh`.
- A4 waits until no retained release, live process **or configuration entry** uses the old path, until C4 and C5 have landed, and at least two weeks after A2 on both Macs (R2-S8).
- D1 waits for step 5, so the README is not rewritten twice. D4 waits for B8's command table.

What is true at each stop:

| Stop | After | Build h (supervised h, cumulative) | Budget h | True at that point |
|---|---|---|---|---|
| 1 | step 4 | 106 (+2) | 140 | A malformed settings file is refused, not wiped. A bad mail line is quarantined and readable, with backups and `peer repair`. `cctrl release rollback` exists and refuses a release that cannot read the current layout. Installs refuse unpushed or wrong-branch trees and run both bash legs. Live data is in `~/.local/state/cctrl` at 0700/0600 on both Macs, so `git clean -fdx` cannot delete it. **But until A4:** `.active-profile` stays in the checkout, and a `git clean` in `~/dev/cctrl` deletes the compat symlink, after which old-code writers could create an empty real `data/` (a split brain). `peer doctor` flags that as an issue and `cctrl state migrate --relink` repairs it; do not `git clean` `~/dev/cctrl` before A4 (R2-S2). CI runs on every push. The label map and the ops note are gone from the tip and the deny-list blocks new private names; older internal plans still carry internal names until D6b (step 10). Nothing is restructured. |
| 2 | step 5 | 210 (+3) | 275 | Every say, role change, doorbell edit and cross-mailbox read is classified, logged in sealed logs and shown in `peer doctor`. The classifier cannot be fooled by argv[0] or a private pty, but any agent can still open a real Terminal window (the stated residual), which the Q10 confirmation covers for grant acts made on the sanctioned path. The say line shows provenance and `say-verify` checks it. Roles carry sealed grants. Forged envelopes, timestamp tricks, wrong-pane pastes, hostile ssh host values and ring-cap burning are fixed. Nothing is refused yet (warn). |
| 2b | step 6 | 297 (+4) | 385 | Plus scheduled gc and retention, the MacBook clean, a steady split suite in parallel, an approvals check command, a ~300-line README, architecture and SECURITY.md, a contributor guide, governance files and v0.x releases. A good point to show the repo. |
| 3 | step 7 | 319 (+4) | 415 | The security track is complete and enforce-ready. Each flip is a one-line config change and Matthew's decision. |
| 4 | step 8 | 551 (+4) | 715 | The peer subsystem (mailbox, attest, doorbell, delivery, CLI) is tested Python. Bash is split into modules with one error and lock discipline. M2 is fixed. |
| 5 | step 10 | 640 (+4) | 830 | Every planned phase is done (step 9 alone ends at 616 build h, budget 800). Coverage is gated, there is a release tarball and a Homebrew tap, and v1.0 is tagged. |

**How the budget is computed (R2-S1).** Every figure in the "Build h" column is the sum of phase sizes and includes each phase's own verify. None of them includes overhead: re-runs under load, the MacBook soak day, verify rework, or waiting on decisions. The first reviewer budgeted 125 h for a 92 h first-stop set, a factor of about 1.3. **The same 30% contingency is applied to every stop and to the total**, rounded to the nearest 5 h (a half rounds up): 106 → 140 (137.8), 210 → 275 (273), 297 → 385 (386.1), 319 → 415 (414.7), 551 → 715 (716.3), 616 → 800 (800.8), 640 → 830 (832). Supervised sessions are Matthew's time, listed separately (A2 2 h, O3.1 1 h, C4 1 h; about 4 h), and are not in the contingency; the stops table shows them cumulatively. L1 adds 25 build h (35 budgeted: 32.5, a half, rounds up).

**Arithmetic (R2-S1).** The first draft's total was 622, described as "570 + 47 + 6". That composition sums to 623; the correct one is 569 (the first reviewer's per-phase figures for Fable's (a)-(e) and options 3/4, which it quoted as ~570) + 47 (unsized audit items: O5 8, O6a 6, O6b 12, O7 8, O12 13) + 6 (MF-M6) = **622**. This revision adds **13 h**: A0 +2, A1 +3, A2 +3, A4 +1, O3.1 +4, O4.1 +2, O3.3 −1, O5 −1, giving 635. **The re-check (R3) adds 5 h:** A1 +1, A2 +2, O4.2 +1, O4.4 +1, giving **640**. Plan totals: 116 = 78, 117 = 44, 118 = 88, 119 = 46, 120 = 180, 121 = 155, 122 = 49; sum 640. Steps: 1 = 31, 2 = 32, 3 = 18, 4 = 25 (stop 1 = 106); 5 = 104 (210); 6 = 87 (297); 7 = 22 (319); 8 = 232 (551); 9 = 65 (616); 10 = 24 (640).

## MUST-FIX traceability (first independent review)

| MUST-FIX | Phase | How it is resolved |
|---|---|---|
| MF-M1 tracked `data/config.json` breaks A2 and every later install | A0 (116); A2 preflight | The shipped default moves to `share/config.default.json`, read as the lowest config layer. `git rm --cached data/config.json`. A2 refuses unless `git ls-files data` is empty. **Corrected (R2-S5):** the untracking deletes the unmodified file in every other checkout on fast-forward, including `~/dev/cctrl`; A0's runbook copies it aside and restores it, untracked, on each checkout, and a pre-A0 rollback without the file is tested. |
| MF-M2 A4 sends rollbacks to old releases into the wrong store | A0, C2 (117) before A2; A4 (116) | Each release declares the state layouts it can read; pre-C2 releases count as layout 1 only. `release rollback` refuses a target that cannot read the current layout unless `--force` is given. **R2-S7:** the layout-2 resolver rule ships dormant in A0, so every release that declares `layout_max: 2` reads the state dir without the compat link; A4 repoints **every** retained release, without exception, and tests it. |
| MF-M3 sync status assumed, not tested | A2 preflight (116); Q1 | Two-way canary test on both Macs. Matthew reads the scope of any file-sync tool that covers the checkout; an agent never opens that tool's configuration. The four excludes are added regardless (R2-S11). If a canary crosses, A2 stops and plan 116 has a written branch for that case. |
| MF-M4 A1's lock must stay compatible with running code | A1 (116) | Same lock path and shlock semantics: pid in the file, atomic link create, stale only on a dead pid. Release checks ownership. The mkdir fallback is replaced by a portable implementation of the same link protocol. **R2-S9:** the stale steal is specified step by step (steal guard, inode check, the found-live path, pid reuse by start time; **R3-MF2:** a lock is stale only on a dead or reused pid, never on age, and a hold over 120 s is a doctor warning only), the claim is narrowed to the non-shlock path, and a three-party test is added. |
| MF-M5 A2's concurrent-writer handling under-specified | A1, A2 (116) | See R2-MF2 below: writer inventory, `.migrating` sentinel honoured by A1+ writers, a merge in which the live state copy wins (R3-MF1), corrected claims and losable-writes list, bounded merge and abort. |
| MF-M6 agents can reach `operator-tty` via detached tmux or `script` | O3.1, O4.1 (118); D2 (122); Q10 | See R2-MF1 below. Role grants, `--regrant-live`, the doorbell mutators and the second-FM override accept only an attested fleet manager with a good grant, or `operator-tty` (with the confirmation if Q10 accepts it), never `operator-flag`. |
| MF-M7 opt 3/4 must use A0/A2 paths and B's interfaces | 118 throughout; B0, B4 (120) | Logs and hook rules use the A0 resolver and match resolved real paths, so they cover the repo symlink, release symlinks and the state dir. The security artifacts join the frozen interface list (above). B0's exit-code table includes 77. B4 is sized at 26 h and adopts the classifier and grants. Log rotation uses the A1 lock helper, not a fifth lock. |
| MF-M8 the Linux leg has no port phase; E11 depends on it | Q5; E0, E11, L1 (121) | Recommended: macOS only for now. The Ubuntu leg is dropped, the README says macOS only, and bash coverage runs on the macOS bash 5 leg. If Q5 = supported, L1 (25 h: stat/date shims, the A1 lock protocol on Linux, systemd/cron for A3) is scheduled at step 9 and the Ubuntu leg becomes blocking. |

## SHOULD items (first independent review)

| SHOULD | Disposition |
|---|---|
| SH-S1 two overstatements; stale skip reason | Folded into A1: the skip reason is replaced (cctrl never used flock) and the test is fixed and un-skipped. The plans' wording is corrected in 116. |
| SH-S2 hooks must not spawn `cctrl paths --json` per call | Folded into A0: a sourced `lib/paths.sh` plus `paths.py`. `cctrl paths` is for humans and tests only. |
| SH-S3 VERSION is not an installed-mode signal | Folded into A0: an explicit `.installed` marker next to the resolved script, written after the gate. **No env export** (R2-S6). A2 tests that gate and checkout resolve the same under the harness. |
| SH-S4 `profiles/` and `.active-profile` left in the checkout | Folded into A2 per Q3 (recommended: profiles go to `~/.config/cctrl/profiles`, and the `.active-profile` reader is retired in A4). |
| SH-S5 the `CCTRL_PEER_IMPL` toggle must be a config key | Folded into B3: `peer_impl` in `config.local.json`, read per call. The env var stays as a test override. |
| SH-S6 B4's tool-path override must be test-only | Folded into A0 (one test-mode gate for every override, moved from O5 by R2-S10) and B4. |
| SH-S7 a realistic coverage method | Folded into E11 (16 h). |
| SH-S8 gaps to "best case" | Folded: mutation, soak, crash consistency for other stores, ENOSPC and read-only FS, differential fuzz (E12); output-escape tests (E4); per-test budgets and quarantine expiry (E1); gitleaks and SHA-pinned Actions (E0); hooks fail open without python3 (E7). |
| SH-S9 E0 on a public repo | Folded into E0: hosted runners only, never self-hosted; smoke per push, full on PR and nightly. |
| SH-S10 A3's plist meets caller checks | Folded into A3: the plist passes `--operator` (parsed since O3.1, R2-S4) and only gc's acked mail (allowed for `script` in O4.3's table). The plist install needs a yes. |
| SH-S11 move C3 earlier | Done: C3 is at step 2. |
| SH-S12 D6 and git history | Folded into D6b: tip-clean only, no rewrite, CI deny-list, commit-message policy (Q6). |
| SH-S13 release, packaging and governance gaps | Folded into C6, C7 and D7, plus D1 (demo, support matrix, privacy note, LICENSE link). |
| SH-S14 sizes about 30% low | Adopted: every size where the reviewer differs is the reviewer's. |
| SH-S15 opt 3/4 sizes light | Adopted: 40 h and 35 h, plus 6 h for MF-M6. |

## Second review (of plans 115-122): MUST-FIX and SHOULD

Verdict: READY-WITH-CHANGES. Every item is applied below, or deferred with a reason.

| Item | Disposition | Where |
|---|---|---|
| **R2-MF1** operator class spoofable; residual too weak | **Applied.** (a) Every chain element is resolved with `proc_pidpath` (ctypes, stdlib), never `ps comm`/argv[0]; `login` is matched as `/usr/bin/login`. (b) A positive tty rule replaces the name list of pty creators: the caller's tty must be the Terminal `login`'s tty. (c) Tests: argv[0]-spoofed root with ppid 1, `pty.fork` under a reparented stub, a pid exiting mid-walk. (d) The residual now names `open -a Terminal x.command` / `open x.command` plainly (genuine chain, no consent prompt) and the osascript case, in 118 and in the planned SECURITY.md. (e) SSH: never `operator-tty`; grant acts need Matthew at the Mac's screen. iTerm2: **unverified**, classified `script` until O3.1's supervised check records its chain. (f) A `sudo -k; sudo -v` (Touch ID with `pam_tid`) confirmation on the `operator-tty` grant path, built in O4.1 (+2 h). (g) Q10 re-put with all of this. | 118 threat model, caller classes, grant set, O3.1, O4.1, O4.2; 122 D2; Q10 |
| **R2-MF2** migration quiesce, atomic-flip claim, losable-writes list | **Applied.** Writer inventory at preflight: `lsof +D` on `data/` and `costs/`, plus a named list (per-session MCP bridges, live session hooks, Codex hooks, external launchd jobs that call cctrl); pre-A1 writers refuse without `--accept-old-writers`. A `<state root>/.migrating` sentinel (fixed path) that every A1+ writer honours: wait, never `mkdir -p` the data dir, re-validate after the lock. The "switch at the same instant" claim and "only old-release writers can recreate `data/`" are corrected. The losable-writes list is corrected: whole-file JSON stores are last-writer-wins, with the losing version kept as a `migrate-conflict` file (superseded by R3-MF1: the live state copy now wins). A fixture test of a new-release writer that resolves before the rename and writes after it. | 116 A0, A1, A2 |
| R2-S1 budgets on one basis; 622 vs 623; D6 source; O7/E6 | **Applied.** Build h and budget columns, a uniform 30% contingency, supervised hours separate; arithmetic restated; D6a/D6b marked F; O7 and E6 wording fixed (no double count). | 115 stops, arithmetic; 119 O7; 121 E6; 122 |
| R2-S2 stop 1 overstated | **Applied.** Stop-1 text corrected; a `peer doctor` split-brain row; `state migrate --relink` named; "do not `git clean` before A4". | 115 stop 1; 116 A2 |
| R2-S3 security track gated on A2 | **Applied.** O3.1-O4.3 (and O5, O6a, O12) need A0 + A1 only; step 5 may run alongside steps 3-4. Flagged for Matthew as a prioritisation point. | 115 sequence; 118 O3.1 |
| R2-S4 `--operator` used before it exists | **Applied.** Parsed and logged in O3.1; O3.3 only adds the enforce refusals (1 h moved). | 118 O3.1, O3.3 |
| R2-S5 untracking note wrong | **Applied.** Note corrected; A0 runbook preserves the live `data/config.json` on each checkout; a pre-A0 rollback test without the file; C2 warns. | 116 A0; 117 C2 |
| R2-S6 env signal leaks into children | **Applied.** No env export; mode from `.installed` next to the resolved script; an inherited variable is ignored and unset; test added. | 116 A0 |
| R2-S7 layout ids | **Applied (option b, plus honest ids).** A0 ships the layout-2 rule dormant, so every `layout_max: 2` release reads the store without the link; a CI check ties the two; A4 repoints every retained release, without exception, with a test. | 116 A0, A4; 117 C2 |
| R2-S8 A4 dependencies and guard | **Applied.** A4 blocked by C4 and C5; the guard scans `settings.json`, Codex `hooks.json`, launchd plists and MCP configs. | 116 A4 |
| R2-S9 stale-steal hard case | **Applied.** Found-live path, narrowed claim, pid-reuse rule, three-party test. The hold timeout first added here stole live locks; R3-MF2 replaced it with a doctor warning. | 116 A1 |
| R2-S10 test-mode rationale and seal key | **Applied.** Property restated (every state path and the key inside the sandbox); test mode refuses the live seal key; the gate moves to A0 so A1's fault injection is gated from the start. | 116 A0; 119 O5 |
| R2-S11 open questions | **Applied.** Questions split into "before stop 1" and "later"; Q11 split into 11a-11h; Q1 adds the excludes regardless; A2 points at the ops note's new private home. | 115 questions; 116 A2 |
| R2-S12 plan format | **Applied.** `allows-migrations: false` on 115 and 116; acceptance criteria in 116-122; Tests lines on E3-E12; "Blocked by" on every phase; `blocked-by: [115]` on 116-122 as a guard plus an execution note; a "Split into" section. 120 states rollback once for all phases, which the umbrella criterion now allows. | all plans |
| R2-S13 public-repo hygiene | **Applied.** Live session names, host labels, private infrastructure names, fleet state paths, sync-tool specifics, the TODOS signpost, a real-looking peer name and internal approval ids are removed or generalised. Environment-specific follow-ups are kept privately, outside the repo. | all plans |
| R2-S14 grants after a power cycle | **Applied.** Stated in O4.2's needs-yes, the restore runbook change (O4.4) and Q10, with an optional post-boot re-anchor. | 118 O4.2, O4.4; Q10 |
| R2-S15 approval load | **Applied.** One install yes per step per Mac proposed (about 20 instead of about 70). | 115 needs-yes |
| R2-S16 traceability gaps | **Applied.** M10's swallowed guard exception → C4 (counted, reported) and E7 (regression); M10's Bash-only matcher → accepted and stated in SECURITY.md. M7's push allowlist vs creation time → deferred with reason (needs a frozen-shape change; belongs with stable identity). Audit option 11 ("accept the risk") → rejected. O12 naming → note in 119. | 117 C4; 121 E7; 119; 122 D2; findings table |
| R2-S17 D6a now | **Applied in the plan:** D6a is the first commit of the programme, with no dependency for the tip-clean (only the deny-list job waits for E0). **Not done here:** this revision changes plan files only; the tip-clean itself still needs Matthew's yes. | 115 step 1; 122 D6a |

## Re-check of the revision: MUST-FIX and SHOULD

Verdict: READY-WITH-CHANGES (2 MUST-FIX, 9 SHOULD). Every item is applied below.

| Item | Disposition | Where |
|---|---|---|
| **R3-MF1** the A2 merge let a stray near-empty `data/` replace live whole-file stores | **Applied.** The live state copy wins. `peers.json` and `shortcuts.json` merge per key (new keys from the stray copy are added; a key in both keeps the state value; missing keys are not deletions). Every other whole-file store keeps the state copy; the stray copy is kept aside as `migrate-stray` and listed. A fixture: an old writer reads a missing `peers.json` after the rename and writes one entry, and the state copy survives. The losable-writes list matches. | 116 A2 steps 5 and 8, tests, acceptance |
| **R3-MF2** the 120 s hold timeout stole locks from live holders | **Applied.** Stale means a dead pid, or pid reuse judged by pid plus start time; nothing else. Lock age over 120 s is a `peer doctor` warning. A test: a SIGSTOPped live holder past the warning age is not stolen. 116's and 115's plan 049 out-of-scope lines now agree. | 116 A1, out of scope; 115 MF-M4 row, out of scope |
| R3-S1 `sudo` confirmation hardening | **Applied.** `/usr/bin/sudo` and a pinned python3 by absolute path; `SUDO_ASKPASS` scrubbed, `-A` never used; the act, target and origin printed before the prompt; `sudo -k` again after the prompt; SECURITY.md says to refuse a prompt you did not start; the "real barrier" claim narrowed to the sanctioned path (summary 7, risks); a Touch ID keyboard note for the Studio. | 118 classifier, confirmation, O4.1 tests; 122 D2; 115 summary 7, Q10, risks |
| R3-S2 re-anchor trusted unsealed data, no caller rule | **Applied.** The sealed grant carries `agent_session_id`; the re-anchor compares the resumed conversation with it, not with the snapshot; the residual (a read seal key) is stated; a caller rule names who may trigger it. +1 h in O4.2. | 118 sealed grants, O4.2; 115 Q10 |
| R3-S3 O4.4 covered Bash only | **Applied.** The state-file rule also matches Write, Edit and NotebookEdit by resolved `file_path`; any Codex file-edit gap is stated; the kill guard stays Bash-only. +1 h in O4.4. | 118 hook rules, O3.5/O4.4; 117 C4; 122 D2; 115 M10 row, out of scope |
| R3-S4 skipped hook writes missing from the losable list | **Applied.** Session-log spending lines and Stop/doorbell ring and bell writes for any Stop more than 5 s into the window are named as dropped. | 116 A2 step 8; 115 summary 8 |
| R3-S5 a crash-left sentinel stalls the fleet silently | **Applied.** The sentinel records pid, start time, host, step and creation time; the exit-75 message, a `peer doctor` row and `state migrate --status` show them, with the resume and rollback commands. | 116 A1, A2 |
| R3-S6 backup and verify raced with writers | **Applied.** The mailbox, peers and shortcuts locks are taken before the backup and held until the relinks; verify is exact for locked or unmerged files, key-wise for the keyed stores, and a prefix match for append-only logs. | 116 A2 steps 3 and 7, tests |
| R3-S7 the three-party test asserted what step 4 allows | **Applied.** The test passes on a restored lock or a detected and reported `lock-steal-collision`. | 116 A1 tests |
| R3-S8 sentinel scope in checkout mode | **Applied.** The sentinel check runs in installed and checkout mode, at the fixed state root; a checkout-mode fixture. | 116 A1 |
| R3-S9 nits | **Applied.** 118's `agent` class replaced by `worker`/`agent-unattested`; the stops table shows supervised hours cumulatively; the L1 budget is 35 (32.5 rounds up); the hygiene criterion allows the generic "Studio"/"MacBook". | 118 O3.1 tests; 115 stops, budget, acceptance |

## Findings coverage (Fable review and security audit)

| Finding | Phase(s) | Note |
|---|---|---|
| F1 single 23.7k-line file | B1, B2, B8 | |
| F2 live state in the git tree | A0, A2, A4 | |
| F3 fragile mailbox | A1, A3, E5 | |
| F4 no CI, linter or coverage | E0, E11 | |
| F5 no rollback; settings wipe | C1, C2, C3 | |
| F6 docs do not serve a newcomer | D1-D5, C6 | |
| F7 suite hard to trust and slow | E1-E3, E9-E12 | |
| F8 private material tracked | D6a, D6b | No history rewrite (Q6). |
| F9 unbounded files | A3 | |
| F10 five path resolvers | A0 | |
| F11 Python lib loose; inline Python | B0, B8 | |
| F12, F12b error handling; duplication | B2, B6, B8 | |
| F13 docs vs reality on sync | A2 preflight, D1 | |
| F14 performance on the common path | B7, B8 (timing budgets) | |
| F15 leftovers | C5, C2 (plan 107 text), E1 (skips), A0 (`config.json`) | The `.bak` files and hand notes in `data/` are listed in A2's report; Matthew decides. |
| F16 perl | B6 | |
| F17 unpinned bash | B2 (`BASH_VERSINFO` guard) | |
| F18 ResourceWarning in `tmux_kill_guard.py` | E1 | |
| H1 ungated say | O3.1-O3.5 | |
| H2 self-assignable role | O4.1, O4.2 (fail-closed mode done in option 2) | |
| H3 kill guard and new primary | **Done** (`0135e89`, `8c249fc`) | Regressions kept in E4. |
| H4 no reader authorisation | O4.3 | |
| M1 split-window mis-paste | O6a | |
| M2 check-then-paste race | O6b | |
| M3 envelope forgery | O5 | |
| M4 sender-set timestamp | O5 | |
| M5 env steers the attest walk | O3.1 (absolute tools, `proc_pidpath`, override caps the class), A0 (test-mode gate), O5, B4 | |
| M6 (audit) ring cap burnable | O12 | |
| M7 (audit) name = identity | O12 short-term | The real fix, stable identity (plans 028/029/034), is out of scope. Tying the push allowlist to creation time is deferred to it, with reason (R2-S16). |
| M8 approvals recipe | O7, E6 | Authenticity (a signed writer) is out of scope. |
| M9 install and rollback | C1-C3, E0, E7 | |
| M10 guards fail open, no tamper evidence | C4 (functional doctor; swallowed exceptions counted and reported), E7 (regression); fail-open by design and the Bash-only kill-guard matcher are stated in SECURITY.md (D2) | Accepted risk: fail-open is a deliberate choice (plan 079); the kill guard covers Bash only because only shell commands can run tmux. The state-file rule (O4.4) also matches Write, Edit and NotebookEdit (R3-S3). |
| M11 remote host values | O12 | |
| L1 state in the tree | A0, A2 | |
| L2 mailbox robustness | A1 | |
| L3 doorbell debug on | A3 | |
| L4 small quoting items | O12 | |
| L5 registry edits without owner check | Deferred (see Out of scope) | Same pattern as opt 4 Q4; a later plan. |
| L6 complexity and tests | B, E | |
| Audit option 11 ("accept the risk") | **Rejected** | Every finding above has a phase or a reasoned deferral instead. |

## Needs Matthew's yes (all of it, in one place)

- **Installs:** every phase that changes runtime code, on each Mac (the standing push approval covers the push after a verify, not the install). **Proposed cadence (R2-S15): one install yes per step per Mac.** That is about 20 yes-events for the programme instead of about 70 (about 35 runtime phases × 2 Macs). A step's yes covers every runtime phase of that step that has passed its verify; a phase that fails its verify is left out and needs its own yes later. Steps 4 and the flips are never batched (below). Matthew approves this cadence once, or keeps one yes per phase.
- **Data migration:** A2 on the MacBook, then a day of soak, then A2 on the Studio. Each is a supervised session, approved after reading that Mac's writer inventory and the losable-writes list. Before that, he reads the file-sync scope himself and adds the excludes (Q1).
- **Live machine changes:** the A0 config runbook on each checkout; unloading external launchd jobs for the A2 window; the A3 launchd plist on each Mac; the C4 MacBook clean-up; the O3.1 supervised check (Terminal.app and iTerm2); the O3.5/O4.4 hook rules (they change `~/.claude/settings.json` and Codex `hooks.json`); `--regrant-live` on each Mac (he runs it in a Terminal.app window at that Mac's screen, and again after each power cycle unless Q10's re-anchor is chosen); A4's repoint of old releases.
- **Enforce flips:** `say_gate`, `caller_checks` and `attestation`, each separately and in that order.
- **Public-repo changes:** D6a (first); enabling Actions (E0); D6b; C5 (`install.sh`); C6's first tag and GitHub Release; D7 repo settings (branch protection, private vulnerability reporting); C7's tap repo; v1.0.
- **History decisions:** none planned. The recommendation is no rewrite (Q6). Any rewrite would be its own decision.
- Supervised sessions in all: A2 × 2 Macs, O3.1's check, C4, plus the `--regrant-live` runs.

## Open questions for Matthew (merged and deduplicated)

Sources: Fable Q1-Q6, the first reviewer's Q1-Q13, option 3 Q1-Q4, option 4 Q1-Q4, and the second review.

### Needed before stop 1 (before any work starts)

- **Q1. Sync (blocks A2).** Run the two-way canary test on both Macs, and read the scope of any file-sync tool that covers the checkout. *Recommendation: run the canary; add excludes for `~/dev/cctrl/{data,costs,profiles,.active-profile}` regardless (closing a to-do item does not stop a reload); then close or scope the related item in your private notes, where D6a moves it.*
- **Q2. A hand-run checkout keeps its own private `data/`,** so only installed releases touch the live store. That also means a rollback to a pre-move release is refused unless forced, and A4 repoints every old release. OK? *Recommendation: yes.*
- **Q3. `profiles/` and `.active-profile`.** *Recommendation: move `profiles/` to `~/.config/cctrl/profiles` (it exists at 0700 and is already the user profile dir) during A2, and retire the legacy `.active-profile` reader in A4.*
- **Q4. CI.** Free hosted macOS runners, never a self-hosted runner on either Mac (the repo is public, and fork PRs would run code there), Actions pinned by SHA. Enable Actions for E0. *Recommendation: yes.*
- **Q6. Internal docs and history.** Ship D6a's tip-clean first? Internal plans go to `docs/internal/` in this repo, or to a private repo? Clean the tip only, with no history rewrite (the repo is already public, and a rewrite breaks SHA-named releases and plan citations)? Keep internal approval ids out of future commit messages and plan files (use plan ids)? *Recommendation: D6a first; `docs/internal/`; tip only; yes.*
- **Q12. Budget.** Approve through stop 1 (106 build h, budget 140) and re-plan, or through stop 2 (210, budget 275), or everything (640, budget 830)? And run step 5 alongside steps 3-4 (R2-S3)? *Recommendation: approve through stop 2, run the two tracks in parallel, then decide on the Python move (step 8) after a week of warn data.*

### Later (each says when it is needed)

- **Q5. Linux** (before step 9). Supported (+25 h port; today the Linux mailbox lock is the racy fallback until A1) or macOS only? *Recommendation: macOS only until stop 4; revisit when the store is in Python.*
- **Q7. Versions and distribution** (before step 6). SemVer in a tracked `VERSION`, with the build SHA kept separate. v0.x tags from stop 2b, v1.0 at stop 5. `self-install` stays maintainer-only, and users get a tarball and a Homebrew tap. *Recommendation: yes to all.*
- **Q8. Contributors** (before step 6). Outsider PRs with required CI checks, while you keep direct push to main. Contributor Covenant CoC and CODEOWNERS. *Recommendation: yes.*
- **Q9. Security track vs the Python move** (before step 5). Land options 3/4 in bash with the classifier as a small Python module (B4 grows by about 10 h), or write them directly in Python as B4's first piece? *Recommendation: bash plus the small module now (step 5), so warn-mode data arrives months earlier.*
- **Q10. Operator class and grant acts (MF-M6, R2-MF1)** (before O4.1 and O4.2 at step 5).
  - *What the classifier now does:* it resolves every process's real executable with `proc_pidpath` and requires your command's tty to be the Terminal window's own login tty. argv[0] spoofing, detached tmux, `script`, `pty.fork` and similar tricks all give `script`.
  - *What it cannot stop:* any agent can run `open -a Terminal x.command` (or `open x.command`) and get a genuine Terminal window running its own file. No process check can tell that from you, and no consent prompt appears. osascript into an existing window is the second route (the O3.1 check records whether it prompts). So without more, `operator-tty` is a label for honest callers.
  - *What it costs you:* over SSH you are never `operator-tty`, so grant acts (`--regrant-live`, starting an orchestrator yourself, doorbell edits) on a Mac need you at its screen or in Screen Sharing; iTerm2 is not accepted until the O3.1 check shows its process chain (so use Terminal.app for grant acts); after every power cycle or reboot every grant goes stale, including the new FM's, so orchestrator mail is not push-eligible under `attestation` enforce until grants are re-issued.
  - *Options:* (i) accept and document the residual; (ii) add `/usr/bin/sudo -k; /usr/bin/sudo -v` on the `operator-tty` grant path only: the act and its target are printed before the prompt, and the ticket is cleared again afterwards; Touch ID if you enable `pam_tid` in `/etc/pam.d/sudo_local` (on the Studio that needs a Touch ID keyboard), else your password; no command runs as root; the FM-with-grant path never prompts; refuse any such prompt you did not start yourself; +2 h in O4.1. It guards the sanctioned path only: an agent that reads the seal key can still mint a grant (the same-uid ceiling); (iii) for power cycles, let `session restore` re-anchor a grant only when its mac verifies, the conversation it resumes matches the conversation id sealed inside the grant (not the editable snapshot), and its old pane anchor predates the current boot; only you in Terminal, a stale-granted FM or your own `--operator` run may trigger it; each re-anchor is logged and mailed to the FM; otherwise you run `--regrant-live` at each Mac after each power cycle.
  - *Recommendation: (ii) yes; (iii) yes. Revisit (i)'s residual only if warn logs show abuse.*
- **Q11. The eight defaults in the option 3/4 drafts** (before step 5). One answer each:
  - 11a. Repo orchestrators may say into any session (opt3 Q1).
  - 11b. External scripts that call `session say` (for example an external launchd job) use `--operator` (opt3 Q2).
  - 11c. Remote say in enforce is allowed on FM, orchestrator or operator claims, labelled as unverified (opt3 Q3).
  - 11d. Codex app threads are refused by default, with a per-name opt-in in `push_senders.peers`, one answer for both plans (opt3 Q4 and the opt4 Codex row).
  - 11e. The FM and operator may recv or ack as others, with the real caller recorded (opt4 Q1).
  - 11f. Sealed grants come before the attestation flip (opt4 Q2).
  - 11g. Only the FM and the operator start or tag orchestrators (opt4 Q3).
  - 11h. Checks on close/kill/rename and register/unregister wait for a later plan (opt4 Q4).

  *Recommendation: accept all eight as written.*

## Out of scope

- Rewriting git history (Q6). Anything already published stays published.
- Stable peer identity across name recycling (plans 028/029/034); O12 does only the short-term fail-closed fixes. Tying the push allowlist to creation time waits for it.
- Authentication beyond the same-uid ceiling: a signed approvals writer, a separate OS user, or key storage agents cannot read. Plan 118 states the residual, including the `open … .command` route.
- Choosing to flip any enforce mode. The code paths are built; the flips are decisions.
- Caller checks on `session close/kill/rename/reconcile-names` and `peer register/unregister` of other sessions (opt4 Q4, audit L5): a later plan.
- Widening the kill guard's PreToolUse matcher beyond Bash (M10; accepted and stated). The O4.4 state-file rule is the exception: it matches the file tools too (R3-S3).
- `cctrl session key` (plan 042), the native-socket work of plan 114, and plan 049 items 3-4 (what to do about a long lock hold, nudge dedupe), which stay with plan 049 or B6. A1 never steals a live holder's lock and only reports a long hold in doctor (R3-MF2).
- Moving config-like files (`shortcuts.json`, `hosts.json`) to `~/.config/cctrl`. A2 is a pure relocation.
- Windows. Linux unless Q5 says supported.
- Edits outside this repo that the security track triggers (external runbooks, briefs and scripts that call `session say`). Their owners make them in the O3.2 window; they are tracked outside the repo.
- A second test framework (bats). The existing harness stays.

## Top risks across the programme

- **A2 on a live fleet** (rename window, old-release writers). Mitigated by the C2 guard, the writer inventory, the `.migrating` sentinel honoured by A1+ writers, the marker inside the directory, a rehearsal on a copy, MacBook first, a merge in which the live state copy always wins (stray changes kept aside), locks held across the backup, and a bounded abort.
- **The operator class** is a label for honest callers unless Q10's confirmation is accepted (R2-MF1). The confirmation is the barrier for grant acts made **on the sanctioned path**; a same-uid agent that reads the seal key can still mint a grant directly (the stated ceiling, R3-S1).
- **The pasted-bytes change in O3.2** breaks workers that expect raw follow-ups, which repeats the worker-briefs incident. Mitigated: the APPROVALS wording says a missing line means "unverified, as today", never "reject"; the skills change in the same window.
- **Ports of attest, doorbell and delivery** (B4-B6). Mitigated by toggles kept as config, differential tests on both implementations, and E10 integration.
- **Programme length.** Every stop leaves a coherent, installed system. Nothing after stop 2 is needed for safety.

## Acceptance criteria (umbrella)

- [ ] Every MUST-FIX row above (MF-M1 to MF-M8, R2-MF1, R2-MF2, R3-MF1, R3-MF2) is closed by the named phase's tests, and its verify report cites the row.
- [ ] Every phase in 116-122 states scope, findings closed, size and source, risk, tests, rollback (per phase, or once per plan where it is the same for every phase, as in 120), "Blocked by" and "Needs Matthew's yes".
- [ ] Every workstream plan has an execution note, acceptance criteria and `blocked-by: [115]`, and none is flipped to `pending` as a whole.
- [ ] Each stop's "true at that point" list is checked by a separate verify worker against the live read-only status commands on both Macs before the stop is reported done.
- [ ] No plan file in this programme names live session names, host labels (the short labels in live session names), real hostnames, private infrastructure, internal approval ids or private state paths. (checked by grep before any push, and by D6a's deny-list once E0 runs it). The generic product names "Studio" and "MacBook", used for the two Macs, are allowed.
