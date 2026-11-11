---
id: 120
title: Overhaul B - split the bash source into modules and move the peer subsystem into tested Python
status: blocked
blocked-by: [115]
priority: 16
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-11-11
approval: "Operator approval on record (plan-only grant): PLAN ONLY. Run per phase under the orchestrator; never flip this plan to pending as a whole. Waits for Matthew's prioritisation from plan 115 (Q12: decide on this workstream after stop 2). Each install needs its own yes."
approved-by: pending (Matthew, via plan 115)
reviews: []
related: 115, 116, 118, 119, 121, 122, 105, 111
---

Workstream B of the overhaul (umbrella: plan 115). It covers Fable's plan (b), audit option 10,
and findings F1, F11, F12, F12b, F14, F16, F17 and L6. It is revised for:
- SH-S5 (the toggle becomes a config key);
- SH-S6 (the test-only tool-path override);
- MF-M7 (the security track's interfaces are frozen, and B4 absorbs the classifier);
- the reviewer's sizes.

**Start condition.** Do not start B3 until plan 121's E1 and E2 have landed: the split suite
must be steady and parallel. A refactor of the delivery path, gated by an 18-minute suite that
fails under load, teaches workers to re-run until green. Baseline is `main` at `8c249fc`.

## Problem (short; detail in Fable F1, F11, F12, F12b, F14)

- `cctrl` is one 23,746-line bash file with 552 functions, 13 of them over 200 lines
  (`_launch_detached` is 790). It has about 180 globals, 95 of them `PEER_*` used as
  out-parameters. Cross-domain references outnumber references within a domain.
- The peer subsystem is about a third of the file: 177-188 functions, 6,930-7,944 lines.
- 29-33 embedded Python heredocs (1,272-1,921 lines) that no Python test covers, and about
  813 lines of multi-line jq.
- 343 `|| true`, 697 `2>/dev/null`, no `die`/`warn` helper, errors on stdout in places.
- Four lock implementations, five copies of the perl-alarm shim, duplicated paste logic and
  launch flag parsing.
- One `peer send --deliver` at 31 sessions starts about 190 jq, 34 python and 100 tmux/ps
  processes (counted from code, not measured).

## End state

- **Bash:** about 13,000 lines in about 25 modules under `src/sh/`, none over about 1,200
  lines. `make build` concatenates them into the single shipped `cctrl`.
- **Python:** one stdlib-only package `src/py/cctrl/` (Python 3.9+), holding `paths`,
  `jsonio`, `locks`, `timeutil` and `exitcodes`, plus:
  - `store/{mailbox,registry,archive}`;
  - `peer/{model,attest,seal,caller,doorbell,deliver,cli,mcp}`;
  - `tmux/{client,servers,snapshot,pane}`;
  - `session/`, `codex/`, `release/`, `hooks/`.
- **One bash-Python convention.** `python3 -m cctrl <area> <verb>`: JSON on stdout, human text
  on stderr, exit codes from `exitcodes.py`, mirrored in the bash prelude. No `eval` of Python
  output.
- **Hooks stay fail-open** (plan 079). Each Python hook entry imports only the stdlib, turns a
  startup failure into "allow, with one stderr line", and keeps exit 2 for a deliberate block.
- **The seal key entry keeps its isolation.** `peer_seal.py` stays a self-contained module run
  by path under `python3 -I -S`.

## Frozen interfaces (byte-compatible through B3-B7)

These must not change in this workstream:
- 29 verbs plus the doorbell sub-verbs.
- The `--json` shapes parsed by `peer_mcp.py` and the remote hop.
- Exit codes 1/2/64/65/66/69/75, and **77** (plan 118).
- The ssh wire format; origin claims travel in `CCTRL_ORIGIN_ATTEST`, now with the class field
  (plan 118).
- The Stop-hook contract.
- The mailbox record format and the lock protocol from plan 116's A1. Old releases and the
  other Mac keep reading and writing the same files.
- **From plan 118 (MF-M7):**
  - the `say_gate`, `caller_checks` and `role_grant` fields;
  - `--operator` and `--raw`;
  - `session say-verify` and its JSON;
  - the `say.jsonl` and `admin.jsonl` shapes and mac domains;
  - the `[cctrl say]` line.
- **From plan 119:** the fence format, and exit 75 for unknown probes and ambiguous panes.

Do not port dead code: inline-over-socket, the app-server inline paths, and the always-empty
`delivery` field on remote sends (evidence F).

## Phases

Rollback for every phase: the previous release. From B3, also `peer_impl: sh` in
`config.local.json` (SH-S5: read per call, so MCP bridges, hooks and tmux jobs with env baked
at launch follow it without a restart). `CCTRL_PEER_IMPL` stays only as a test override.

### B0. Python foundation (step 8)

- **Scope.**
  - The `src/py/cctrl` package, with one atomic write, one JSON loader, one RFC 3339 parser,
    and one lock (plan 116's `locks.py`, the A1 protocol).
  - `exitcodes.py`, **including 77**.
  - `pyproject.toml` with ruff and mypy settings (dev-only tools).
  - Importable hook module names, with the old paths kept as two-line shims.
  - `lib/paths.py`, `lib/caller_class.py` and the existing modules move in without behaviour
    change.
- **Closes.** F11 (structure, helper duplication).
- **Size.** 10 h (Fable).
- **Risk.** Low. Mechanical; the import paths are the risk.
- **Tests.**
  - The existing Python tests pass unchanged; new helper tests.
  - `python3.9 -m compileall`.
  - The hooks fail-open matrix: python missing, a syntax error, the release missing, a slow
    start.
- **Blocked by.** Plan 121's E2.
- **Needs Matthew's yes:** the install on each Mac.

### B1. Split the bash source (step 8)

- **Scope.**
  - `src/sh/*.sh` plus `make build`. The built `cctrl` is **byte-identical** to the file
    before the split.
  - A CI check that the built file is current.
  - Update the path-bound tests: `test_syntax`, `test_no_unreferenced_functions` and the
    registration guard.
  - A build manifest (module → line ranges), used by plan 121's E11 to map coverage.
- **Closes.** F1 (first half).
- **Size.** 8 h (Fable).
- **Risk.** Low. No runtime change, by construction.
- **Tests.** `cmp` of the built file against the pre-split blob; the full suite on both
  bashes.
- **Blocked by.** B0.
- **Needs Matthew's yes:** none for B1 itself, since the built file is unchanged. It still
  goes through the normal install of the next phase.

### B2. Prelude and error discipline (step 8)

- **Scope.**
  - `die`, `warn` and `info`, with errors to stderr everywhere, including the unknown-command
    paths.
  - One temp-file registry with a single EXIT trap.
  - A `BASH_VERSINFO` guard (F17).
  - One lock helper (A1) and one timeout helper, replacing the five perl-alarm copies.
  - shellcheck clean against a recorded baseline that only shrinks.
  - `chmod 600` failures reported, not swallowed.
- **Closes.** F12, F17, F12b (locks, timeouts).
- **Size.** 10 h (Fable).
- **Risk.** Low-medium. It touches many lines, each trivially.
- **Tests.**
  - Every error path writes to stderr (a table-driven test).
  - A temp-leak test: no files left after each command class.
  - The lint baseline gate.
- **Blocked by.** B1.
- **Needs Matthew's yes:** the install on each Mac.

### B3. Mailbox store and message model in Python (step 8)

- **Scope.** Two steps.
  - **The read-side verbs** (recv, ack, check, inbox, outbox, show, gc). Bash keeps argument
    parsing, identity and the lock. One Python process does selection, state change, seal
    verify and the write under that same A1 lock.
  - **Then send and reply.**
  - `store/mailbox.py` and `peer/model.py` (the record, the status machine, filters, human and
    JSON rendering, the plan 119 fence).
  - The 36 tests that reach into bash internals are rewritten as black-box or unit tests in
    the phase that moves their target.
- **Closes.** F3 (structure), F14 (process spawns on the read path), L6 (part).
- **Size.** 32 h (reviewer; Fable 22).
- **Risk.** Medium. The hot path; JSON shapes are parsed by the MCP bridge.
- **Tests.**
  - All black-box mailbox tests unchanged.
  - A **differential test**: both implementations on the same fixtures, diffing output and
    exit codes.
  - Hypothesis operation sequences against both (plan 121's E12 differential fuzz).
  - Property tests: no message lost under any interleaving; round-trip.
  - The A1 corruption and concurrency set, including an old-release bash writer against the
    new Python writer.
- **Blocked by.** B2; plan 121's E1 and E2.
- **Needs Matthew's yes:** the install on each Mac.

### B4. Identity, attestation, seal, and the caller classifier (step 8)

- **Scope.**
  - The process-tree and tmux walk, levels and origin claims move to `peer/attest.py`, and the
    bash side of sealing to `peer/seal.py`.
  - **Adopt** plan 118's classifier (`peer/caller.py`) and role-grant verification
    (MF-M7).
  - Tools are called by absolute path (audit M5).
  - The tool-path override for fake `ps` and tmux in tests is honoured **only** under plan
    119's `_cctrl_test_mode` (SH-S6).
- **Closes.** M5 (complete), F1/F11 (peer part).
- **Size.** 26 h (reviewer: Fable's 16 plus 10 for the classifier and grants).
- **Risk.** Medium-high. Security-relevant; behaviour must not change in any mode.
- **Tests.**
  - The attestation tests unchanged.
  - A differential test, including the classifier's MF-M6 cases (detached tmux, `script`,
    argv[0] spoof, `pty.fork`, the tty rule) and the `proc_pidpath` walk.
  - Unit tests for `canonical`, `verify_one` and `eligibility_one`.
  - The override is ignored outside test mode.
- **Blocked by.** B3; plan 118 (O3.1, O4.2) landed.
- **Needs Matthew's yes:** the install on each Mac.

### B5. Doorbell (step 8)

- **Scope.**
  - Config, ring cap state (plan 119's per-sender form) and the Stop-hook evaluation move to
    `peer/doorbell.py`.
  - Fail-open becomes explicit and tested, instead of `( set +e; … ) 2>/dev/null || true`.
- **Closes.** F12 (doorbell fail-open by construction).
- **Size.** 14 h (Fable).
- **Risk.** Medium. Runs on every Stop of every session; latency matters.
- **Tests.**
  - The doorbell tests unchanged.
  - `tests/bench-doorbell.sh` becomes a budget test: median and p95 recorded, no more than 20%
    regression.
  - Hook contract tests.
- **Blocked by.** B4.
- **Needs Matthew's yes:** the install on each Mac.

### B6. Delivery (step 8; plan 119's O6b follows)

- **Scope.**
  - Pane readiness, modal detection, paste, the post-paste check, nudge, deliver-all, app
    delivery and `say` move to Python.
  - A `tmux/client.py` interface with a fake for unit tests.
  - `pane_draft.pl` and the other perl helpers fold into `tmux/pane.py` (F16).
  - Keep plan 119's O6a pane-id targeting.
  - One paste path for peer and session (F12b).
- **Closes.** F16, F12b (paste), F14 (delivery spawns).
- **Size.** 32 h (reviewer; Fable 22).
- **Risk.** High. Keystroke injection into live agents.
- **Tests.**
  - The delivery tests unchanged.
  - Pane fixtures replayed through both detectors.
  - Plan 121's E10 integration on a private socket with the fake agent.
  - A differential test.
- **Blocked by.** B5; plan 121's E10.
- **Needs Matthew's yes:** the install on each Mac.

### B7. Peer CLI in Python; delete the bash peer code (step 8)

- **Scope.**
  - `cctrl peer …` dispatches to `python3 -m cctrl peer`.
  - `peer/mcp.py` calls the package in-process instead of spawning `cctrl` per tool call
    (F14).
  - The `sh` toggle and the old bash are removed.
  - The remote wire format is pinned by tests.
  - **Mixed-version fleet:** a cross-version matrix (old sender to new receiver and back, and
    an old MacBook release reading a Studio-written mailbox file). This answers the
    reviewer's gap that B7 only covered the wire.
- **Closes.** F1 (peer half done), F14.
- **Size.** 12 h (Fable).
- **Risk.** Medium. Version skew between hosts.
- **Tests.**
  - The black-box suite.
  - MCP tool tests.
  - The cross-version matrix with plan 121's E8 fake ssh.
  - A `peer send` process-count budget (under 10 spawns at 31 fake sessions).
- **Blocked by.** B6 and plan 119's O6b.
- **Needs Matthew's yes:** the install on each Mac. Install both Macs in the same window,
  because of skew.

### B8. The rest of bash (step 9)

- **Scope.**
  - Break up `_launch_detached` and every function over 200 lines.
  - One `_session_row_json` for the four row loops.
  - The inline Python heredocs move into the package.
  - One launch flag parser shared by `cmd_start` and `_shortcut_jump`.
  - **A command table** that generates help, completions (zsh and bash) and the CLI reference.
    Plan 122's D4 consumes it.
  - The repo-label map is already gone (plan 122's D6a).
- **Closes.** F1 (complete), F11 (inline Python), F12b (launch flags, row loop), F6 (help,
  completion and dispatch drift).
- **Size.** 36 h (reviewer; Fable 24).
- **Risk.** Medium. Launch is the second most delicate area after delivery.
- **Tests.**
  - The start and launch tests unchanged.
  - Unit tests per extracted function.
  - A drift check between help, completions and dispatch.
  - A `session list` timing budget.
- **Blocked by.** B7.
- **Needs Matthew's yes:** the install on each Mac.

## Size summary

| Phase | h | Source |
|---|---|---|
| B0 | 10 | Fable |
| B1 | 8 | Fable |
| B2 | 10 | Fable |
| B3 | 32 | reviewer |
| B4 | 26 | reviewer (incl. classifier and grants) |
| B5 | 14 | Fable |
| B6 | 32 | reviewer |
| B7 | 12 | Fable |
| B8 | 36 | reviewer |
| **Total** | **180** | |

Every phase from B3 to B7 can end the workstream with a working system. The revision of
plans 115-122 changed no size here.

## Execution and acceptance criteria

- **Execution.** Run per phase under the orchestrator, B0 → B8 in order, and only after
  Matthew's decision on this workstream (plan 115 Q12) and after plan 121's E1 and E2. Never
  flip this plan to `pending` as a whole: it is 180 h of phases with installs between them.
  The frontmatter `blocked-by: [115]` is a guard (115 stays `split`). Rollback is stated once
  for every phase, above the phase list, because it is the same for each.
- [ ] B1: the built `cctrl` is byte-identical to the pre-split file (`cmp`).
- [ ] B2: every error path writes to stderr; no temp file leaks; the lint baseline only
  shrinks.
- [ ] B3-B7: each port passes the black-box suite unchanged and a differential test against
  the bash implementation; `peer_impl: sh` in `config.local.json` restores the old path
  without a restart.
- [ ] B4: the classifier's MF-M6 cases (detached tmux, `script`, argv[0] spoof, `pty.fork`)
  give the same class in both implementations.
- [ ] B7: the cross-version matrix passes; `peer send` stays under 10 spawns at 31 fake
  sessions.
- [ ] B8: help, completions and dispatch come from one command table, with a drift check.
- [ ] Every frozen interface listed above is unchanged, checked by test.

## Out of scope

- Changing the lock protocol or the record format.
- Dropping bash 3.2 for what stays in bash.
- A second test framework.
- Porting `lib/peer_seal.py`'s key handling out of its isolated entry.
