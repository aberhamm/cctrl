---
id: 105
title: Test harness (shim-safe PATH helper, per-test filter, timing, auto-registration, both-bash install gate, then file split)
status: pending
blocked-by: []
priority: 105
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-10-08
tui-fixture: n/a  # test harness + install gate only
approved-by: Matthew ("Okay, just go with what you think the best decisions are and keep going.", 2026-10-08 15:49Z via the cctrl orchestrator; approvals mdec-1008-cctrl-next-work (item 3a, test-harness plan) + mdec-1008-cctrl-orch-successor-2 (carry-over to TMUX--ms--orch-cctrl--2))
reviews:
  - type=eng verdict=approved date=2026-10-08 by=opus-subagent
---

## Progress

- [x] **P0 baseline** (2026-10-08, clean HEAD cab3eb4, run from a `git archive` copy plus the gitignored `profiles/` and `.active-profile`, see note). Both legs EXIT=0, 367 `ok:` lines each (identical sorted name lists). Wall time: `/bin/bash` 3.2 **478 s**, Homebrew bash 5.3 **502 s** (so the "about 40 minutes" in plan 090 is wrong: a full leg is about 8 minutes, install gate with two legs about 16). 445 definitions, 441 distinct top-level call names. Artifacts: `~/.local/state/fleet/fm-cctrl-artifacts/plan-105-106/p0-baseline/`.
  - Finding: `test_session_doctor_realign_carries_profile_model_peer` fails (`expected output to contain: --profile work`) when the tree has no `profiles/work.json`, so the suite has a hidden dependency on the gitignored `profiles/` dir (the installer's scratch copy deletes `profiles/` at `install/self-install.sh:71`; check how the gate still passes before P5). Follow-up in TODOS.
- [x] **P1 PATH helper.** `_test_path [--sbin] <dir>...` added; all 28 shim-less + 10 shim-first sites converted (38 lines, mechanical). Allowlisted: the 2 `CCTRL_HOOK_GUI_PATH="$doctor_bin:..."` sites (cctrl uses that variable only for `command -v cctrl`; matched by exact assignment). No site needed to stay bare for a bash 5 failure: the six converted tests passed under bash 5 unchanged, and no product bug was found. Lint `test_no_shimless_test_path` (does not match itself: pattern and helper are assembled from parts) has a built-in self-test (planted site must be flagged, allowlisted form must not) and was also proven with a planted bare site in a /tmp copy via `CCTRL_LINT_ROOT`. `test_bash_leg_is_honest` checks `_test_path` output starts with the shim.
- [x] **P2 flake.** `FAKE_APP_SCHEMA_DELAY` added to the app-owned fake codex. **Confirmed**: with `FAKE_APP_SCHEMA_DELAY=0.1` the old test fails with `ambiguous creation result is wrong ... "reason": "required App Server capability is not proven: thread/start"` (the recorded text). Option A applied: the two timeout cases use `CCTRL_CODEX_REQUEST_TIMEOUT=.5` with the fake sleeping 2 s (adds about 2 s). After the change the test passes even with `FAKE_APP_SCHEMA_DELAY=0.1`. Loop of the `app-owned-launch` group, strictly sequential: **50/50 pass under `/bin/bash` 3.2 and 50/50 under bash 5.3**.
  - Follow-up (option B, product, not done): the schema probe should have its own deadline instead of sharing `CCTRL_CODEX_REQUEST_TIMEOUT` (`lib/codex_app_server.py`, `capability_report` -> `_schema_evidence`).
  - Follow-up (test): the fake sleeps before reading its next message, so a retry sent during the sleep is never traced; `continue` without the sleep would make the "not retried" check sound (Opus review RECOMMENDED).
- Gate (after the last edit): full suite EXIT=0, 367 `ok:` lines, 0 FAIL on both legs; wall `/bin/bash` 561 s, bash 5.3 583 s; sorted `ok:` names identical to the P0 baseline on both legs (the new lint test prints no `ok:` line); tmux session list unchanged.
- [ ] P3, P4, P5, P6 pending.

## Plain-English Summary

`tests/run-tests.sh` is one 17,510-line file with a hand-kept call list. You
cannot run one test, nothing reports how long a test takes, 28 call sites
still run cctrl under the wrong bash on the bash 5 leg, and the install gate
tests only one bash. This plan fixes those in small steps, and only then
splits the file. cctrl behaviour does not change.

Gate for every phase: full suite green under `/bin/bash` (3.2.57) AND under
Homebrew bash, tmux session list identical before/after. Everything must stay
bash 3.2 compatible (no `declare -A`, `mapfile`, `EPOCHREALTIME`-only code,
`wait -n`, `((i++))` from 0 under `set -e`).

## Non-goals

- No change to `cctrl` or `lib/` (one exception is listed as a follow-up, not done here: flake fix option B).
- No test body rewrites except where a phase says so (P1 PATH sites, P2 flake, P4 order-dependence fixes).
- No fake-tmux consolidation, no `make_rootcopy` helper (audit A3 extras; later plan).
- No parallel test execution. No cut of suite runtime (P3 only measures).
- No change to what `CCTRL_TEST_ONLY=<group>` runs.

## Verified facts (checked at 74a8fe3, by reading and counting; no suite was run)

- `tests/run-tests.sh`: 445 `test_*` definitions, 720 bare call lines (the brief says ~713).
- A full run executes 443 distinct tests. Not run: `test_peer_mailbox_concurrency_and_stale_lock` (allowlisted skip) and **`test_task_inventory_provider_neutral_readonly`**: it is called only from the `task-inventory` group and from `run_codex_ownership_matrix_paths` (used only by the `codex-ownership-matrix` group). `test_every_defined_test_is_registered` counts it as registered. Plan 097 already notes "guard cannot see a test registered only in a focused group".
- Registration today: main list inside one `if` (skipped for 7 codex/health groups); a second list at the end of the file; two calls inside `if [[ -z CCTRL_TEST_ONLY ]]`; `test_tmux_default_server_is_private` defined at line 178 but called at top level at line 13544 ("before any test, focused group or not"). 30 groups in the `case`, 7 more dispatched by `if` blocks near the end.
- **Run order is not definition order.** 148 of the 440 listed tests (420 in the main list at lines 14928-15349, 20 in the tail list) are out of definition order. Example: `test_tmux_sockets_left_behind` is the first test defined and runs mid-list, after the private-socket tests it backstops.
- **Tests run in the harness shell, not in subshells** (7 tests have a `( ... )` body). 9 tests use function-scope `export`/`cd`/`unset`/`trap`. `test_health_check_transition_guard` sources a function file into the harness shell that redefines `_session_update_metadata_field` and `_tmux_run_with_timeout`, then sources `lib/health-check.sh`. This is the real "defined after fixtures" constraint: the health-check and codex blocks are defined and run last because they change the shell.
- `declare -F` prints names alphabetically under `/bin/bash` 3.2 (tested with a 3-function snippet). It cannot give definition order.
- `fail()` is `exit 1`: first failure ends the run. No timing code exists (`SECONDS`/`date +%s` are used only inside fixtures).
- Shim: `$TMPDIR/bash-shim/bash -> $BASH`, first on PATH (bootstrap). `test_bash_leg_is_honest` checks it.
- 28 `PATH="$x:/usr/bin:/bin..."` call sites omit the shim: `test_app_owned_launch` 14, `test_fleet_v2_provider_neutral_federation` 9, `test_codex_handoff_state_machine` 2, `test_snapshot_tmux_absent_preserves` 1, `test_remote_detach_attach_escapes_exact_target` 1, `SR_PATH` in `test_restore_cap_fails_closed` 1. The last two tests named here are not in the plan-103 list. On the bash 5 leg these resolve `#!/usr/bin/env bash` to `/bin/bash` 3.2, so these tests never run cctrl under bash 5.
- 2 more sites set `CCTRL_HOOK_GUI_PATH="$doctor_bin:/usr/bin:/bin"` in `test_codex_hook_installation_is_additive_and_observer_is_bounded`. That variable simulates a GUI PATH for `hooks doctor`; whether bash is resolved through it is (unverified).
- `install/self-install.sh` runs `LANG=en_US.UTF-8 bash "$SCRATCH/tests/run-tests.sh"` once, with PATH bash.
- Three tests replace the suite's EXIT trap in the harness shell (`trap cleanup_terminate EXIT` line 8231, `cleanup_reap` 8357, `cleanup_exact_stop` 8559). Nothing restores `_suite_exit`, so after the first of them the "suite aborted" diagnostic and TMPDIR/tmux cleanup are lost. Under D4 these traps fire at the end of each test's subshell: a behaviour change P4 must verify.
- Path-bound guards: `test_syntax` (`bash -n "$ROOT/tests/run-tests.sh"`, no glob over `tests/`), `test_every_defined_test_is_registered` (awk over that one file), `test_no_unreferenced_functions` (file list names that one file; after a split, a cctrl function referenced only from `tests/suite/*.sh` would look dead).
- Flake: plan 097 recorded `FAIL: ambiguous creation result is wrong: {... "reason": "required App Server capability is not proven: thread/start" ...}`. Code path: the test sets `CCTRL_CODEX_REQUEST_TIMEOUT=.05` for its two timeout cases; `lib/codex_app_server.py:capability_report` calls `_schema_evidence(runtime, timeouts.request)`, which runs `codex app-server generate-json-schema` as a subprocess with that same 0.05 s limit; on timeout it returns no methods and `launch_task` emits exactly that reason. The fake codex is a `#!/usr/bin/python3` script; its bare start measured 0.02-0.03 s on an idle Studio. So a loaded machine can push the schema probe past 50 ms. Chain read in code; not reproduced.
- Suite runtime "about 40 minutes" comes from plan 090 (unverified, not measured). Handoff 16 reports 367 `ok` lines per full run.

## Design

**D1. One PATH helper.** `_test_path [--sbin] <dir>...` prints
`$TMPDIR/bash-shim:<dirs>:/usr/bin:/bin[:/usr/sbin:/sbin]`. Shim first, as
`test_bash_leg_is_honest` requires. All 28 sites and the 10 already-fixed
sites use it. New lint test `test_no_shimless_test_path`: fails on any
literal `:/usr/bin:/bin` in `tests/` outside the helper, with an allowlist
line (with reason) for `CCTRL_HOOK_GUI_PATH` if P1 shows it must stay bare.

**D2. Runner.** One function `_run_test <name>`: records start time, runs the
test, records end time and status, appends `name<TAB>seconds<TAB>status` to
an in-memory list. Time source: `EPOCHREALTIME` when set, else one
`perl -MTime::HiRes` call per test boundary (about 3 s per full run on 3.2,
unverified). stdout stays exactly as today (plans count `ok` lines). Run each test as a plain statement, never in an `||`, `&&`, `if` or `!` context (bash ignores `set -e` there, and bare failing statements are how failures surface today): `set +e; ( set -e; "$name" ); rc=$?; set -e` (P4); P3 has no subshell, so it times passing tests and fail-fast exits through `_suite_exit`. End-of-run reports (slowest-20, KEEP_GOING summary) must not depend on the EXIT trap; the
slowest-20 table goes to stderr at the end of a full run; the full TSV is
written when `CCTRL_TEST_TIMINGS=<file>` is set.

**D3. Per-test filter.** `bash tests/run-tests.sh test_a test_b` (positional)
or `CCTRL_TEST_NAMES="test_a test_b"`. Unknown name: exit 64 with the list
of near matches. Both a filter and `CCTRL_TEST_ONLY`: exit 64. The always-on
`test_tmux_default_server_is_private` still runs first. Selected tests run
in registry order, not argument order. `--list` prints the full-run names in
run order and exits (this is the proof tool below). The Python unittests do
not run in a filtered run.

**D4. Auto-registration.** Discovery = `awk` over the test files in source
order for `^test_[A-Za-z0-9_]+\(\)` (not `declare -F`). Two small explicit
lists remain in the runner, each entry with a reason: `SKIP` (today: the
mailbox concurrency test) and `RUN_LAST` (ordered; today:
`test_tmux_sockets_left_behind`). Each test runs in a subshell
(`( "$name" )`), so `export`, `cd`, `source` and function redefinitions stop
leaking and definition order becomes safe. Default stays fail-fast (stop at
the first failing test, same exit code and `FAIL:` line as today);
`CCTRL_TEST_KEEP_GOING=1` runs everything and lists failures at the end.
Groups become data: `_group_tests <group>` prints names; the three groups
with extra steps (`codex-adapter`, `provider-neutral`, `codex-ownership-matrix`)
keep their custom blocks.

Guard after D4 (`test_every_defined_test_is_registered` keeps its name):
- every `SKIP`, `RUN_LAST` and group entry names a defined test;
- every `tests/suite/*.sh` on disk was sourced (file count match);
- no test is reachable only through a group (closes the plan-097 hole);
- the discovered count equals the count of `^test_` definitions found by a second, independent `grep -c`.

**D5. Install gate.** `self-install.sh` runs the suite twice, sequentially:
`/bin/bash` first (stricter, fails earlier), then PATH `bash`, when the two
differ in version. `CCTRL_INSTALL_SUITE_LEGS=both|bash32|path` (default
`both`); any value other than `both` prints a loud line into the install
log. Cost: install time roughly doubles (about +40 min, unverified). No
"trust a recorded green run" stamp: a stamp is a gate an agent could write.

**D6. Split (last).** `tests/run-tests.sh` stays the entry point and sources
`tests/lib/*.sh` (bootstrap, assertions, fakes), then `tests/suite/NN-name.sh`
in sorted glob order (`LC_ALL` is already pinned). Seams follow the existing
section banners. Rule: **a split commit moves text and changes no test
body.** Top-level statements between functions (`LIVE_GUARD_PY=...`,
`_SR_HOST_ID=...`, the top-level `test_tmux_default_server_is_private` call)
move with their neighbours, order kept.

## Proving no test was lost (used by P3, P4, P6)

1. Names: `--list` output before vs after, sorted, `diff` empty. Baseline for the pre-runner tree comes from the static extraction used above (443 names; script kept in the plan's artifact dir).
2. Count: 445 defined, 443 run before P4; after P4 444 run (the group-only test joins the full run) and 1 skipped. Any other number fails the phase.
3. Behaviour: sorted `ok:` lines of the full-run log before vs after, per bash; `diff` must be empty except the lines the phase is declared to add.
4. Split only: `declare -f` dump of every function (Homebrew bash), before vs after, byte-identical; plus `git diff --color-moved` shows moves only.

## Phases (each ships alone; both full suites green is the gate for each)

**P0. Baseline (no repo change).** Record: definition list, full-run list,
sorted `ok:` lines and wall time of both legs. One full run per bash.

**P1. PATH helper.** Add `_test_path` and the lint; convert the 28 + 10
sites; decide the 2 `CCTRL_HOOK_GUI_PATH` sites (read `_hooks_doctor` first).
Expect new bash 5 failures in the 6 converted tests: this is the first time
they run cctrl under bash 5. Fix them here. A site that cannot be fixed in this phase stays on the bare PATH with an allowlist line in `test_no_shimless_test_path` naming the follow-up and the failing line; the phase gate (both suites green) stays unchanged.

**P2. `test_app_owned_launch` root cause.** (a) Add `FAKE_APP_SCHEMA_DELAY`
to the fake codex and show that a 0.1 s delay reproduces the recorded FAIL
text exactly. (b) If confirmed: raise the two timeout cases to
`CCTRL_CODEX_REQUEST_TIMEOUT=.5` with the fake sleeping 2 s (adds about 1 s),
then loop the `app-owned-launch` group 50 times under load on both bashes.
(c) If not confirmed: leave the test alone, record what was ruled out. File
option B as a follow-up either way: the schema probe should not share the
per-request deadline (product change in `lib/codex_app_server.py`).

**P3. Runner, timing, filter.** Convert the existing lists to
`_run_test name` lines in the same order (still hand-kept; no isolation
change yet). Add D2, D3, `--list`. Publish the slowest-20 table and the real
full-run time in the README testing note.

**P4. Auto-registration.** (a) "Runs alone" audit: run each of the 443 tests
by itself through the P3 filter on both bashes; every test that fails alone
has a hidden dependency; fix it (body changes allowed in this phase only,
each listed in the plan). (b) Switch to D4: subshell per test, discovery,
`SKIP`/`RUN_LAST`, groups as data, new guard; delete both call lists.
(c) `test_task_inventory_provider_neutral_readonly` joins the full run.

**P5. Install gate on both bashes.** D5, plus `bash -n` under `/bin/bash`
for `cctrl`, `lib/*.sh`, `hooks/*.sh`. Independent of P3/P4; can ship any
time after P1.

**P6. Split.** One commit for `tests/lib/`, then one commit per suite file.
In the same commits: `test_syntax` globs `tests/*.sh tests/lib/*.sh
tests/suite/*.sh`; the dead-test guard and `test_no_unreferenced_functions`
scan all of `tests/`. Needs a quiet tree (no other worker editing tests).

## Tests added

- `test_no_shimless_test_path` (P1).
- `test_bash_leg_is_honest` extended: `_test_path` output starts with the shim (P1).
- `test_runner_filter_and_list` (also: a fixture test whose bare `false` must fail, proving `set -e` is live in the runner): runs the harness as a subprocess against a 3-test fixture file (pass, fail, skip): filter selects, unknown name exits 64, `--list` order, fail-fast exit code, `KEEP_GOING` summary, timing TSV has one row per test (P3, extended in P4).
- Guard self-test: a fixture dir with an unsourced suite file, a bad `SKIP` name and a group-only test each make the guard fail (P4).
- `test_self_install_runs_both_bash_legs`: stub suite records `$BASH_VERSION`; assert two runs and the loud line for a non-default leg setting (P5).

## Ship step

Per phase: both suite logs with `EXIT=0`, the proof diffs above attached,
commit, `self-install.sh`, then `/bin/bash cctrl help` and `cctrl session ls`
rc 0. P5 changes the installer itself: run it once into a sandbox
`CCTRL_HOME` before the real install. Update README (testing section),
CHANGELOG, `TODOS.md` harness entry, and the worker brief template (how to
run one test).

## Rollback

Every phase is one or a few commits in `tests/` or `install/`; `git revert`
restores the previous harness. No data, no installed-release format, no cctrl
runtime change. P5 rollback: `CCTRL_INSTALL_SUITE_LEGS=path` restores today's
behaviour without a revert.

## Risks

- P1 surfaces real bash 5 failures in six large codex tests. Mitigation: phase allows listing them as follow-ups.
- P4 order change exposes tests that pass only after a neighbour ran. Mitigation: the "runs alone" audit comes first; fallback in open question 1.
- Subshell per test hides a suite-level variable a later test reads (unverified whether any exist). The audit catches it.
- P6 conflicts with every open change to the test file. Schedule it alone.
- Double suite at install makes a 40-minute step 80 minutes; a tired operator sets `path` permanently. The loud log line is the only guard.
- Timing on 3.2 depends on `perl` with `Time::HiRes` (ships with macOS; unverified on other hosts). Fall back to `SECONDS` when missing.

## Decisions and open questions

Decided 2026-10-08 by the cctrl orchestrator under Matthew's delegation of 2026-10-08 15:49 UTC (approval mdec-1008-cctrl-next-work, item 3a):

1. **Decision (2026-10-08): order-dependence.** If the P4 audit finds more than 15 order-dependent tests, stop P4 at "one generated order file, checked by the guard" (today's run order frozen as data), keep subshell isolation off, and file the isolation work separately.
2. **Decision (2026-10-08): install gate legs.** `both`, sequential, `/bin/bash` 3.2 first. Revisit with P3 timing data.
3. **Decision (2026-10-08): `test_task_inventory_provider_neutral_readonly`** joins the full run (P4c). If P4 shows it was kept out on purpose, it goes into `SKIP` with the reason.

Still open (default applies unless the owner says otherwise):

4. **Fail-fast or keep-going by default?** Default: fail-fast (unchanged behaviour); workers opt in to keep-going.
5. **Flake fix A (test timing) or B (product: separate schema-probe deadline)?** Default: A here, B as its own small plan.
6. **Directory names.** Default `tests/lib/` and `tests/suite/` (the audit wrote `tests/suites/`; the brief says `tests/suite/`).

## Fact check (2026-10-08, at HEAD 74a8fe3, grep/count only)

Re-verified: 17,510 lines, 445 `test_*` definitions, 28 shimless `PATH=` call sites (14/9/2/1/1/1 per test as listed) plus 2 `CCTRL_HOOK_GUI_PATH` sites, 10 shim-first sites, `test_task_inventory_provider_neutral_readonly` referenced only at its definition, the `task-inventory` group and the ownership-matrix block (not in the main list), `self-install.sh` line 98 runs the suite once with PATH bash. No numbers needed correcting.

## Review history

- Eng pass 1 (Opus sub-agent, 2026-10-08): changes-requested. REQUIRED, all applied as text: (1) runner must not run tests in `||`/`&&`/`if`/`!` context, with a fixture test for a bare `false` (D2, tests); (2) P1 gate contradicted its follow-up allowance (P1 reworded: allowlist line, gate stays green); (3) three tests replace the EXIT trap (facts, D2). Also fixed two wrong facts from the RECOMMENDED list (line numbers of `test_tmux_default_server_is_private`; 420+20 list split).
- Eng pass 2 (same reviewer): approved. The `reviews:` entry is this final verdict (`review-gate.sh record` replaces in place, so pass 1 lives only here).
- RECOMMENDED items left for the implementer: exclude the always-on test from discovery (`RUN_FIRST`) so it does not run twice; move the "every suite file sourced" guard bullet to P6; make `test_no_shimless_test_path` not match its own pattern; settle `CCTRL_HOOK_GUI_PATH` now (`_hooks_doctor` only uses it for `command -v cctrl`: allowlist it); P6 scans `tests/run-tests.sh tests/lib tests/suite`, not all of `tests/`; proof step 4 also compares concatenated `tests/lib/*.sh tests/suite/*.sh` with the original body minus added `source` lines; `_run_test` prints `FAIL: <name> (rc=N)`.
