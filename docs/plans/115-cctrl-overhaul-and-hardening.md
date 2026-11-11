---
id: 115
title: cctrl overhaul and hardening (umbrella) - data safety, install safety, security track, tests, docs, modules
status: split
blocked-by: []
priority: 10
allows-migrations: true
needs-review: eng
review-required: eng
created: 2026-11-11
approval: "mdec-1111-fable-findings-plans (cctrl line): PLAN ONLY. Building any phase waits for Matthew's prioritisation from this file. Installs, the data migration on each Mac, enforce flips, history decisions and public-repo changes each need their own yes (see 'Needs Matthew's yes')."
approved-by: pending (Matthew prioritises from the summary below)
reviews: []
related: 116, 117, 118, 119, 120, 121, 122, 039, 040, 041, 049, 105, 107, 111, 114
---

Umbrella plan. It is split into seven workstream plans, 116 to 122, and is not
implemented directly (status `split`, as plan 075). This file holds the
summary, the ranking, the sequence, the stopping points, the traceability
tables, the decisions and the open questions. Each workstream file stands on
its own and has the per-phase detail.

## Summary (prioritise from this)

1. cctrl works and is well tested, but its live data sits in the git checkout, one bad mailbox line stops all mail, the hooks installer can wipe `~/.claude/settings.json`, and there is no rollback command and no CI.
2. The audit's main security holes are still open: unlogged `say` into any session (H1), self-assignable roles (H2) and draining another session's mail (H4). The kill guard and fail-closed mode (options 1 and 2) are done and installed.
3. The plan has 10 steps in 7 workstreams (plans 116-122). Data-loss and install safety come first, then the security checks in warn mode, then tests and docs, then the module split and the Python move.
4. Total: about **622 agent-hours**. That is the reviewer's ~570 for Fable's (a)-(e) plus options 3/4, 47 h for the audit items nobody had sized yet (options 5-7, M6, M7, M11, L4), and 6 h for the MF-M6 fix. Linux support would add about 25 h.
5. **First safe stop: about 95 agent-hours** (the reviewer budgets 125 for the same set). At that point settings cannot be wiped, a bad mail line is quarantined, there is a real rollback command, installs are preflighted, data has left the checkout on both Macs, and CI runs on every push.
6. Second stop, about 193 h: every audit security check runs in **warn** and logs who said or changed what. Enforce stays your separate call.
7. Each install, each Mac's data migration, each enforce flip and each public-repo change needs your yes. There are 12 open questions below, each with a recommendation. Q1 (is `data/` synced?) is answered by a canary test before the migration, not by assumption.

## Sources and conventions

- Fable review (architecture and quality, plans (a)-(e), findings **F1-F18**): `~/.local/state/fleet/reviews/fable-review-cctrl-2026-11-11.md`, its evidence A-F and its handoff.
- Fable security audit (findings **H1-H4, M1-M11, L1-L6**, options 1-11): `~/.local/state/fleet/reviews/fable-audit-cctrl-2026-11.md` and its handoff.
- Independent review of (a)-(e) and options 3/4: `~/.local/state/fleet/orch-cctrl-reports/overhaul-plans-independent-review.md`. Its MUST-FIX items are cited here as **MF-M1 to MF-M8**, and its SHOULD items as **SH-S1 to SH-S15**. The prefix keeps them apart from the audit's M1-M11.
- Option 3 and option 4 drafts: `orch-cctrl-reports/plan-audit-opt3-say-gate.md` and `plan-audit-opt4-caller-checks.md`. Both are folded into plan 118 and revised there for MF-M6 and MF-M7.
- Baseline: `main` at `8c249fc`. Audit options 1 and 2 are DONE and installed: `0135e89` and `8c249fc` (the kill guard knows the primary and extra servers, the `$'...'` pre-check is fixed, and an unknown attestation mode fails closed). H3 is closed; plan 121 keeps its regression tests.
- Phase ids: **A** data (116), **C** install and release (117), **O3/O4** say gate and caller checks (118), **O5-O12** other audit hardening (119), **B** modules and Python (120), **E** tests and CI (121), **D** docs and public project (122), **L1** the optional Linux port (121).
- Line numbers drift. The workstream files cite functions and files first, and line numbers only as "about, at 7742883".

## Common rules for every phase

- Each phase is one or more commits that leave `main` installable. Each is gated by the full suite on `/bin/bash` 3.2 and Homebrew bash 5, and by CI once E0 lands.
- Each phase ends with a verify by a different worker (fleet doctrine). Under mdec-1107 the orchestrator pushes its own repo after that verify. **Installing on either Mac always needs Matthew's yes**, phase by phase.
- Rollback always starts with "activate the previous release" plus `git revert`. Before C2 that means re-pointing `current` with the atomic `ln -s … current.next && mv -fh current.next current` recipe. After C2 it means `cctrl release rollback`. Any extra steps for state changes are named in the phase.
- All tests are hermetic. They use a private `TMUX_TMPDIR` and socket, the sandboxed `CCTRL_*` and XDG paths, and never the live fleet, the live mailbox or the seal key.
- New modes ship in **warn**. An unknown mode value fails closed, matching option 2.
- Interfaces frozen through plan 120: everything in Fable §4(b)'s byte-compatible list, plus the security track's artifacts (exit code 77, `say_gate`, `caller_checks`, `role_grant`, `--operator`, `--raw`, `session say-verify`, `say.jsonl`, `admin.jsonl`, the `[cctrl say]` line, and the class field in `CCTRL_ORIGIN_ATTEST`). This is MF-M7.

## Ranked phases

Rank = step order. Security and data-loss items come first. Sizes are agent-hours, each including its own verify. The **Src** column says where a size comes from:
- **R**: the reviewer's revised size (used wherever it differs from Fable's);
- **F**: Fable's size, which the reviewer accepted;
- **O→R**: an option 3/4 draft size, rescaled to the reviewer's 40 h and 35 h totals;
- **P**: this plan's own estimate, for work nobody had sized.

| Step | Phase | What ships | Closes | h | Src | Risk | Needs Matthew's yes | Plan |
|---|---|---|---|---|---|---|---|---|
| 1 | E0 | CI on hosted runners: lint, Python tests, macOS bash 3.2 and 5; smoke subset per push, full run on PRs and nightly; gitleaks; Actions pinned by SHA | F4, M9 (no CI), SH-S8 part, SH-S9 | 14 | R | Low | Enable Actions on the public repo; the workflow is a public change | 121 |
| 1 | A0 | One path resolver (shell and Python, no cctrl spawn per call), private modes, shipped config default moved out of `data/`, explicit installed-mode marker | F10, F2 prep, L1 modes, MF-M1, SH-S2, SH-S3 | 12 | R | Low | Install on each Mac (one-time chmod of live files) | 116 |
| 1 | D6a | Privacy tip-clean: repo-label map out of the source and into config, ops note out of `TODOS.md`, deny-list grep in CI | F8 | 3 | P | Low | Public-repo change; no history rewrite | 122 |
| 2 | A1 | Mailbox hardening, keeping the lock protocol shlock-compatible: quarantine, backups, same-dir fsync rename, `peer repair`, `v` field, locked `peers.json`/`shortcuts.json` | F3, L2, MF-M4, SH-S1; plan 049 items 1-2 | 20 | R | Medium | Install on each Mac | 116 |
| 2 | C3 | Atomic `~/.claude/settings.json` write (lock, strict parse, backup, `os.replace`); `cctrl hooks uninstall` | F5, M9, SH-S11 | 8 | F | Low | Install on each Mac | 117 |
| 3 | C2 | `cctrl release list/current/rollback`, with a state-layout guard that ships before A2 | F5, M9, MF-M2 | 10 | F | Low-medium | Install on each Mac | 117 |
| 3 | C1 | Install preflight (main == origin/main, install lock, launcher from the release, both bash legs, filter vars unset, offline rule) | F5, M9, F4 part; plan 105 P5 | 8 | F | Low | Install on each Mac | 117 |
| 4 | A2 | `cctrl state migrate`: sync canary preflight, quiesce, atomic marker flip, symlink compat; MacBook first, then Studio | F2, L1, F13, MF-M3, MF-M5, SH-S3, SH-S4 | 20 (+2 supervised) | R | Medium-high | **The migration on each Mac**; Matthew reads the livesync scope; install | 116 |
| 5 | E4 | Hostile-input tests, with expected failures keyed to audit ids; output-escape tests | L6, SH-S8 part | 12 | F | Low | None (tests only) | 121 |
| 5 | O3.1 | Caller classifier (small Python module), MF-M6 tightening, say gate in warn, sealed `say.jsonl` | H1, M5 part, MF-M6, MF-M7 | 18 | O→R + P6 | Low (warn) | Install on each Mac | 118 |
| 5 | O3.2 | `[cctrl say]` provenance line, slash and `--raw` exemptions, `session say-verify` | H1 | 9 | O→R | Medium (pasted bytes change) | Install; skills and APPROVALS wording | 118 |
| 5 | O4.1 | Caller checks on set-role, `start --role orchestrator`, the second-FM override and the doorbell mutators; `admin.jsonl` | H2 | 10 | O→R | Low (warn) | Install on each Mac | 118 |
| 5 | O4.2 | Sealed `role_grant`; attest and eligibility read it; `--regrant-live` | H2 | 13 | O→R | Medium | Install; Matthew runs `--regrant-live` in Terminal on each Mac | 118 |
| 5 | O4.3 | Mailbox read and ack bound to the caller; gc of unread mail limited to FM and operator; archive 0600 | H4 | 9 | O→R | Low (warn) | Install on each Mac | 118 |
| 5 | O5 | Envelope hardening (subject validation, random fence, C0 strip on display); `CCTRL_NOW_UTC` and path overrides honoured in test mode only | M3, M4, M5 | 8 | P | Low | Install on each Mac | 119 |
| 5 | O6a | Pane-id targeting for check, capture, paste and Enter | M1 | 6 | P | Medium | Install on each Mac | 119 |
| 5 | O12 | Ring cap per sender with reserve, corrupt state counted as at-cap; fail closed on a server-probe timeout; host values validated and `--` before ssh targets; L4 quoting | M6 (audit), M7 short-term, M11, L4 | 13 | P | Low | Install on each Mac | 119 |
| 6 | A3 | `cctrl state gc` plus retention and a launchd template; statusline appends less; locked `session-log.py` | F9, L3, F3 | 8 | F | Low-medium | Plist install on each Mac; install | 116 |
| 6 | C4 | Codex doctor parity, functional guard self-test, MacBook stale hooks cleaned | M10, F5 | 6 (+1 supervised) | F | Low | One supervised MacBook session; install | 117 |
| 6 | C5 | Retire `install.sh`; `statusline install` writes the `current/` path | F15 | 4 | F | Low | Public-repo change | 117 |
| 6 | C6 | SemVer source of truth, `cctrl --version`, CHANGELOG policy and check, GitHub Releases | SH-S13, F6 | 3 | P (part of R's 10) | Low | First public tag and release (v0.x) | 117 |
| 6 | O7 | `cctrl approvals check <id>` plus a corrected APPROVALS block | M8 | 8 | P | Low | Install; skills change | 119 |
| 6 | E1 | De-flake, fix or delete the SKIPs, missing tool = SKIP locally and FAIL in CI, time budgets with a quarantine expiry | F7, F15, F18, SH-S8 part | 10 | F | Low | None | 121 |
| 6 | E2 | Split the test file and run it in parallel (absorbs plan 105 P4-P6) | F7 | 20 | R | Medium | None | 121 |
| 6 | E6, E7 | Approvals doc-lint; install and rollback suite, hooks fail open without python3 | M8, M9, SH-S8 part | 3 + 4 | F | Low | None | 121 |
| 6 | D1-D3 | README of at most ~300 lines; architecture plus SECURITY.md (states the MF-M6 residual); CONTRIBUTING | F6, SH-S13, MF-M6 statement | 6 + 8 + 5 | F | None | Public-repo change | 122 |
| 6 | D7 | CODE_OF_CONDUCT, CODEOWNERS, branch protection with required checks, PR workflow, private vulnerability reporting | SH-S13 | 2 | P (part of R's 10) | Low | Repo settings on the public repo | 122 |
| 7 | O3.3 | say-gate enforce code path (live stays warn), exit 77, `--operator` | H1 | 8 | O→R | Low | Install on each Mac | 118 |
| 7 | O3.4 | Remote say: origin-side gate, class carried in `CCTRL_ORIGIN_ATTEST` | H1 | 6 | O→R | Low | Install on each Mac | 118 |
| 7 | O3.5 | PreToolUse rule matching resolved paths (`--operator`, `CCTRL_ORIGIN_ATTEST=`) | H1, MF-M7 | 5 | O→R | Medium | Changes `settings.json` and Codex `hooks.json` on each Mac | 118 |
| 7 | O4.4 | Docs and skills; a hook rule for writes to state files, by resolved path | H2, MF-M7 | 3 | O→R | Low | Same as O3.5 | 118 |
| 7 | (flips) | Enforce flips, in order: `say_gate`, then `caller_checks`, then `attestation` | H1, H2, H4 | 0 | n/a | Medium | **Each flip is its own yes** | 118 |
| 8 | B0-B7 | Python package; byte-identical bash split; prelude and errors; mailbox, attest (absorbs the classifier and grants), doorbell, delivery and peer CLI in Python | F1, F11, F12, F12b, F14, F16, F17, L6, SH-S5, SH-S6 | 10+8+10+32+26+14+32+12 = 144 | R | Medium-high | Install per phase | 120 |
| 8 | O6b | Post-paste verification, inverted modal detection, unique buffers (plans 040/041), built in Python on B6 | M2 | 12 | P | High | Install | 119 |
| 8 | E3, E5, E8-E10, E12 | Unit tests; corruption set; mocked ssh; property and fuzz tests; isolated-tmux integration; mutation, soak, crash and disk-full cases, differential fuzz | F7, L6, SH-S8 | 20+6+8+12+20+10 = 76 | F / R | Low-medium | None | 121 |
| 9 | B8 | The rest of bash; command table that generates help and completions | F1, F6 part, F12b, F14 | 36 | R | Medium | Install | 120 |
| 9 | D4, D5 | Generated CLI reference and `--help`; module headers, data formats, JSON Schemas | F6 | 10 + 12 | F | Low | Public-repo change | 122 |
| 9 | A4 | Remove the compat symlink after a quiet period; repoint or prune pre-A2 releases | F2, MF-M2 | 6 | R | Low | Install; pruning old releases on each Mac | 116 |
| 9 | L1 | Linux port (only if Q5 = supported) | MF-M8 | (25) | R | Medium | Q5 | 121 |
| 10 | D6b | Internal plans to `docs/internal/`, CHANGELOG in real versions, commit-message policy for internal ids | F8, SH-S12 | 3 | P | Low | Public-repo change; history stays as is | 122 |
| 10 | E11 | Coverage that works: `coverage.py` across subprocesses, bash coverage on bash 5 mapped to `src/sh`, ratchet | F7, SH-S7 | 16 | R | Low | None | 121 |
| 10 | C7 | Release tarball, Homebrew tap, `cctrl uninstall` | SH-S13 | 5 | P (part of R's 10) | Low | Create the tap repo (public); v1.0 tag | 117 |

## Sequence, dependencies and safe stops

```
0 decisions (Q1 canary, Q2, Q3 profiles)                     no code
1 E0 + A0 + D6a          -> 2 A1 + C3     -> 3 C2 + C1       -> 4 A2 (MacBook, soak 1 day, Studio)
                                                        [STOP 1 ~95 h]
5 E4, O3.1, O3.2, O4.1-O4.3, O5, O6a, O12 (all warn)    [STOP 2 ~193 h] then one week of warn
6 A3, C4, C5, C6, O7, E1, E2, E6, E7, D1-D3, D7         [STOP 2b ~280 h]
7 O3.3-O3.5, O4.4; enforce flips are separate decisions [STOP 3 ~302 h]
8 B0, B1, B2, then B3..B7 (+O6b after B6); E3, E5, E8-E10, E12 alongside  [STOP 4 ~534 h]
9 B8, D4, D5, A4 (after quiet period), L1 if chosen     [~598 h]
10 D6b, E11, C7, v1.0                                    [STOP 5 ~622 h]
```

Dependencies that matter (each phase lists all of its own in its plan):
- A0 comes before everything that touches a path: A1, A2, A3, all of 118 (MF-M7), E7 and D2.
- C2's layout guard must ship **before** A2 (MF-M2). A2 also needs A0, A1, C1, C2, the Q1 canary and the Q3 decision.
- O3.1 (the classifier) comes before O3.2-O3.5 and O4.1-O4.4. O4.2 (grants) comes before any attestation enforce flip.
- The enforce flips need one week in warn with zero unexplained `would-refuse`, the skills changes (O3.2, O4.4), and, for attestation, O4.2.
- E1 and E2 come before B3 (no refactor of the delivery path on a slow, flaky suite). B1 comes before E11's mapping to `src/sh`.
- A4 waits until no retained release or live process uses the old path, and at least two weeks after A2 on both Macs.
- D1 waits for step 5, so the README is not rewritten twice. D4 waits for B8's command table.

What is true at each stop:

| Stop | After | Cumulative h | True at that point |
|---|---|---|---|
| 1 | step 4 | ~95 (the reviewer's budget for this set: 125) | A malformed settings file is refused, not wiped. A bad mail line is quarantined and readable, with backups and `peer repair`. `cctrl release rollback` exists and refuses a release that cannot read the current layout. Installs refuse unpushed or wrong-branch trees and run both bash legs. Live data is in `~/.local/state/cctrl` at 0700/0600 on both Macs, so `git clean -fdx` cannot reach it. CI runs on every push. No private names in tracked files. Nothing is restructured. |
| 2 | step 5 | ~193 | Every say, role change, doorbell edit and cross-mailbox read is classified, logged in sealed logs and shown in `peer doctor`. The say line shows provenance and `say-verify` checks it. Roles carry sealed grants. Forged envelopes, timestamp tricks, wrong-pane pastes, hostile ssh host values and ring-cap burning are fixed. Nothing is refused yet (warn). |
| 2b | step 6 | ~280 | Plus scheduled gc and retention, the MacBook clean, a steady split suite in parallel, an approvals check command, a ~300-line README, architecture and SECURITY.md, a contributor guide, governance files and v0.x releases. A good point to show the repo. |
| 3 | step 7 | ~302 | The security track is complete and enforce-ready. Each flip is a one-line config change and Matthew's decision. |
| 4 | step 8 | ~534 | The peer subsystem (mailbox, attest, doorbell, delivery, CLI) is tested Python. Bash is split into modules with one error and lock discipline. M2 is fixed. |
| 5 | step 10 | ~622 | Every planned phase is done. Coverage is gated, there is a release tarball and a Homebrew tap, and v1.0 is tagged. |

The reviewer gives ~125 h for its first-stop set (A0, A1, A2, C1, C2, C3, E0). Its own per-phase figures for that set add up to 92 h; mine adds D6a (3 h) to make 95. Use 125 h as the budget ceiling for stop 1: the gap covers the supervised migrations, the MacBook soak day and the load-related re-runs the reviewer warns about.

## MUST-FIX traceability (independent review)

| MUST-FIX | Phase | How it is resolved |
|---|---|---|
| MF-M1 tracked `data/config.json` breaks A2 and every later install | A0 (116); A2 preflight | The shipped default moves to `share/config.default.json`, read as the lowest config layer. `git rm --cached data/config.json`. A2 refuses unless `git ls-files data` is empty. There is a note for the MacBook and for the worktrees. |
| MF-M2 A4 sends rollbacks to old releases into the wrong store | C2 (117) before A2; A4 (116) | Each release declares the state layouts it can read. Pre-A2 releases count as layout 1 only. `release rollback` refuses a target that cannot read the current layout unless `--force` is given. A4 runs only after a quiet period and repoints every retained release's `data`/`costs` link to the state dir, or prunes it. A4 is never part of an early stop. |
| MF-M3 sync status assumed, not tested | A2 preflight (116); Q1 | Two-way canary test on both Macs. Matthew reads livesync-cli's include and exclude scope (the config may hold credentials, so an agent does not open it). The `TODOS.md` "reload livesync" item is closed or scoped with `data/`, `costs/`, `profiles/` and `.active-profile` excluded. If livesync is found live, A2 stops and plan 116 has a written branch for that case. |
| MF-M4 A1's lock must stay compatible with running code | A1 (116) | Same lock path and shlock semantics: pid in the file, atomic link create, stale only on a dead pid. Release checks ownership. The mkdir fallback is replaced by a portable implementation of the same link protocol, which also fixes the Linux race. Every Python writer (A2, B3) uses the same protocol. There is a concurrency test of an old-release writer against a new-release writer. |
| MF-M5 A2's concurrent-writer handling under-specified | A2 (116) | Explicit quiesce: unload the snapshot agent; refuse while watch, needs-me or doorbell loops run (or stop them with `--stop-loops`); run at a quiet time. The layout marker travels inside the renamed directory, so new-release writers switch atomically. Merge and retry is bounded, then the tool aborts and rolls back. Losable writes (statusline samples only) are listed. The "sender during the window" case is tested on a fixture. |
| MF-M6 agents can reach `operator-tty` via detached tmux or `script` | O3.1 (118); D2 (122); Q10 | `operator-tty` now requires a login-rooted tty: the walk must reach Terminal, iTerm2 or `login` with no agent ancestor. Panes of a daemonised tmux server and reparented `script` processes are capped at `script`. Role grants, `--regrant-live`, the doorbell mutators and the second-FM override accept only an attested fleet manager with a good grant, or `operator-tty`, never `operator-flag`. The detached-tmux and `script` cases are tests. The residual (an agent driving Terminal.app through osascript, and the same-uid ceiling) is stated plainly in SECURITY.md and plan 118. |
| MF-M7 opt 3/4 must use A0/A2 paths and B's interfaces | 118 throughout; B0, B4 (120) | Logs and hook rules use the A0 resolver and match resolved real paths, so they cover the repo symlink, release symlinks and the state dir. The security artifacts join the frozen interface list (above). B0's exit-code table includes 77. B4 is sized at 26 h and adopts the classifier and grants. Log rotation uses the A1 lock helper, not a fifth lock. |
| MF-M8 the Linux leg has no port phase; E11 depends on it | Q5; E0, E11, L1 (121) | Recommended: macOS only for now. The Ubuntu leg is dropped, the README says macOS only, and bash coverage runs on the macOS bash 5 leg. If Q5 = supported, L1 (25 h: stat/date shims, the A1 lock protocol on Linux, systemd/cron for A3) is scheduled at step 9 and the Ubuntu leg becomes blocking. |

## SHOULD items (independent review)

| SHOULD | Disposition |
|---|---|
| SH-S1 two overstatements; stale skip reason | Folded into A1: the skip reason is replaced (cctrl never used flock) and the test is fixed and un-skipped. The plans' wording is corrected in 116. |
| SH-S2 hooks must not spawn `cctrl paths --json` per call | Folded into A0: a sourced `lib/paths.sh` plus `paths.py`. `cctrl paths` is for humans and tests only. |
| SH-S3 VERSION is not an installed-mode signal | Folded into A0 (an explicit marker written after the gate, plus a launcher export) and A2 (a test that gate and checkout resolve the same under the harness). |
| SH-S4 `profiles/` and `.active-profile` left in the checkout | Folded into A2 per Q3 (recommended: profiles go to `~/.config/cctrl/profiles`, and the `.active-profile` reader is retired in A4). |
| SH-S5 the `CCTRL_PEER_IMPL` toggle must be a config key | Folded into B3: `peer_impl` in `config.local.json`, read per call. The env var stays as a test override. |
| SH-S6 B4's tool-path override must be test-only | Folded into O5 (one test-mode gate for every override) and B4. |
| SH-S7 a realistic coverage method | Folded into E11 (16 h). |
| SH-S8 gaps to "best case" | Folded: mutation, soak, crash consistency for other stores, ENOSPC and read-only FS, differential fuzz (E12); output-escape tests (E4); per-test budgets and quarantine expiry (E1); gitleaks and SHA-pinned Actions (E0); hooks fail open without python3 (E7). |
| SH-S9 E0 on a public repo | Folded into E0: hosted runners only, never self-hosted; smoke per push, full on PR and nightly. |
| SH-S10 A3's plist meets caller checks | Folded into A3: the plist passes `--operator` and only gc's acked mail (allowed for `script` in O4.3's table). The plist install needs a yes. |
| SH-S11 move C3 earlier | Done: C3 is at step 2. |
| SH-S12 D6 and git history | Folded into D6b: tip-clean only, no rewrite, CI deny-list, commit-message policy (Q6). |
| SH-S13 release, packaging and governance gaps | Folded into C6, C7 and D7, plus D1 (demo, support matrix, privacy note, LICENSE link). |
| SH-S14 sizes about 30% low | Adopted: every size where the reviewer differs is the reviewer's. |
| SH-S15 opt 3/4 sizes light | Adopted: 40 h and 35 h, plus 6 h for MF-M6. |

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
| M5 env steers the attest walk | O3.1 (absolute tools, override caps the class), O5 (test-mode gate), B4 | |
| M6 (audit) ring cap burnable | O12 | |
| M7 (audit) name = identity | O12 short-term | The real fix, stable identity (plans 028/029/034), is out of scope. |
| M8 approvals recipe | O7, E6 | Authenticity (a signed writer) is out of scope. |
| M9 install and rollback | C1-C3, E0, E7 | |
| M10 guards fail open, no tamper evidence | C4 (functional doctor), E7; fail-open by design is stated in SECURITY.md (D2) | Accepted risk: fail-open is a deliberate choice (plan 079). |
| M11 remote host values | O12 | |
| L1 state in the tree | A0, A2 | |
| L2 mailbox robustness | A1 | |
| L3 doorbell debug on | A3 | |
| L4 small quoting items | O12 | |
| L5 registry edits without owner check | Deferred (see Out of scope) | Same pattern as opt 4 Q4; a later plan. |
| L6 complexity and tests | B, E | |

## Needs Matthew's yes (all of it, in one place)

- **Installs:** every phase that changes runtime code, on each Mac, each time (mdec-1107 covers the push after a verify, not the install).
- **Data migration:** A2 on the MacBook, then a day of soak, then A2 on the Studio. Each is a supervised session. Before that, he reads the livesync scope himself (Q1).
- **Live machine changes:** the A3 launchd plist on each Mac; the C4 MacBook clean-up; the O3.5/O4.4 hook rules (they change `~/.claude/settings.json` and Codex `hooks.json`); `--regrant-live` on each Mac (he runs it in Terminal); A4's repoint or prune of old releases.
- **Enforce flips:** `say_gate`, `caller_checks` and `attestation`, each separately and in that order.
- **Public-repo changes:** enabling Actions (E0); D6a/D6b; C5 (`install.sh`); C6's first tag and GitHub Release; D7 repo settings (branch protection, private vulnerability reporting); C7's tap repo; v1.0.
- **History decisions:** none planned. The recommendation is no rewrite (Q6). Any rewrite would be its own decision.

## Open questions for Matthew (merged and deduplicated)

Sources: Fable Q1-Q6, reviewer Q1-Q13, option 3 Q1-Q4, option 4 Q1-Q4.

1. **Sync (blocks A2).** Run the two-way canary test on both Macs, and you read livesync-cli's scope to confirm it excludes `~/dev/cctrl/{data,costs,profiles,.active-profile}`. Close the `TODOS.md` "reload livesync" item, or scope it? *Recommendation: run the canary; close the item unless you still want livesync for other repos, in which case add those four excludes first.*
2. **A hand-run checkout keeps its own private `data/`,** so only installed releases touch the live store. That also means a rollback to a pre-move release is refused unless forced, and A4 repoints old releases. OK? *Recommendation: yes.*
3. **`profiles/` and `.active-profile`.** *Recommendation: move `profiles/` to `~/.config/cctrl/profiles` (it exists at 0700 and is already the user profile dir) during A2, and retire the legacy `.active-profile` reader in A4.*
4. **CI.** Free hosted macOS runners, never a self-hosted runner on the Studio (the repo is public, and fork PRs would run code there), Actions pinned by SHA. *Recommendation: yes.*
5. **Linux.** Supported (+25 h port; today the Linux mailbox lock is the racy fallback until A1) or macOS only? *Recommendation: macOS only until stop 4; revisit when the store is in Python.*
6. **Internal docs and history.** Internal plans go to `docs/internal/` in this repo, or to a private repo? Clean the tip only, with no history rewrite (the repo is already public, and a rewrite breaks SHA-named releases and plan citations)? Keep `mdec-` ids out of future commit messages (use plan ids)? *Recommendation: `docs/internal/`; tip only; yes.*
7. **Versions and distribution.** SemVer in a tracked `VERSION`, with the build SHA kept separate. v0.x tags from stop 2b, v1.0 at stop 5. `self-install` stays maintainer-only, and users get a tarball and a Homebrew tap. *Recommendation: yes to all.*
8. **Contributors.** Outsider PRs with required CI checks, while you keep direct push to main. Contributor Covenant CoC and CODEOWNERS. *Recommendation: yes.*
9. **Security track vs the Python move.** Land options 3/4 in bash with the classifier as a small Python module (B4 grows by about 10 h), or write them directly in Python as B4's first piece? *Recommendation: bash plus the small module now (step 5), so warn-mode data arrives months earlier.*
10. **Operator class (MF-M6).** Accept the tightened, login-rooted `operator-tty` (with grants limited to an attested FM or `operator-tty`) and document the residual: an agent driving Terminal.app through osascript, plus the same-uid ceiling. Or add an out-of-band confirmation (password or Touch ID) for grants and doorbell edits? *Recommendation: accept and document now; revisit only if warn logs show abuse.*
11. **The eight defaults in the option 3/4 drafts.** Repo orchestrators may say into any session (opt3 Q1). The Paperclip runner uses `--operator` (opt3 Q2). Remote say in enforce is allowed on FM, orchestrator or operator claims, labelled as unverified (opt3 Q3). Codex app threads are refused by default, with a per-name opt-in in `push_senders.peers`, one answer for both plans (opt3 Q4 and the opt4 Codex row). The FM and operator may recv or ack as others, with the real caller recorded (opt4 Q1). Sealed grants come before the attestation flip (opt4 Q2). Only the FM and the operator start or tag orchestrators (opt4 Q3). Checks on close/kill/rename and register/unregister wait for a later plan (opt4 Q4). *Recommendation: accept all eight as written.*
12. **Budget.** Approve through stop 1 (~95 h, budget 125) and re-plan, or through stop 2 (~193 h), or everything (~622 h)? *Recommendation: approve through stop 2, then decide on the Python move (step 8) after a week of warn data.*

## Out of scope

- Rewriting git history (Q6). Anything already published stays published.
- Stable peer identity across name recycling (plans 028/029/034); O12 does only the short-term fail-closed fixes.
- Authentication beyond the same-uid ceiling: a signed approvals writer, a separate OS user, or key storage agents cannot read. Plan 118 states the residual.
- Choosing to flip any enforce mode. The code paths are built; the flips are decisions.
- Caller checks on `session close/kill/rename/reconcile-names` and `peer register/unregister` of other sessions (opt4 Q4, audit L5): a later plan.
- `cctrl session key` (plan 042), the native-socket work of plan 114, and plan 049 items 3-4 (lock-hold vs timeout, nudge dedupe), which stay with plan 049 or B6.
- Moving config-like files (`shortcuts.json`, `hosts.json`) to `~/.config/cctrl`. A2 is a pure relocation.
- Windows. Linux unless Q5 says supported.
- Homelab-side edits that the security track triggers (the Paperclip runbook, homelab plan 219, `runner-brief.md`). They are listed in plan 118 for the homelab orchestrator.
- A second test framework (bats). The existing harness stays.

## Top risks across the programme

- **A2 on a live fleet** (rename window, old-release writers). Mitigated by the C2 guard, the marker-inside-the-directory flip, quiesce, a rehearsal on a copy, MacBook first and a bounded abort.
- **The pasted-bytes change in O3.2** breaks workers that expect raw follow-ups, which repeats the worker-briefs incident. Mitigated: the APPROVALS wording says a missing line means "unverified, as today", never "reject"; the skills change in the same window.
- **Ports of attest, doorbell and delivery** (B4-B6). Mitigated by toggles kept as config, differential tests on both implementations, and E10 integration.
- **Programme length.** Every stop leaves a coherent, installed system. Nothing after stop 2 is needed for safety.

## Acceptance criteria (umbrella)

- Every MUST-FIX row above is closed by the named phase's tests, and its verify report cites the row.
- Every phase in 116-122 states scope, findings closed, size and source, risk, tests, rollback, dependencies and "Needs Matthew's yes".
- Each stop's "true at that point" list is checked by a separate verify worker against the live read-only status commands on both Macs before the stop is reported done.
