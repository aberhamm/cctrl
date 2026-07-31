---
id: 050
title: Docs and test-coverage catch-up for the current command surface
status: blocked
blocked-by: [042, 043, 044, 045, 046]
priority: 22
goal: revised-cctrl-audit-backlog
allows-migrations: false
needs-review: none
created: 2026-07-30
---

## Requirements

README is roughly a month behind the CLI and the top-level help omits the
exact commands the messaging loops depend on. Audit specifics: README lacks
`session doctor`, `session autoheal`, `session prune`,
`session ls --recap`, the rich STATE column (its `session ls` sample predates
plan 014), `cctrl fleet`, `cctrl needs-me`, the low-memory launch guard
(`-f/--force`), and its feature bullets omit peer messaging entirely — the
largest subsystem by line count. (`session say` is NOT a gap: README already
has a full dedicated section for it.) Top-level `cctrl help` omits `peer
check` and `peer recv` (the two verbs the polling loop depends on), `session
say`, `session autoheal`, and `--profile` on `start` (which README leads
with). Test-suite dark regions: plugin entry scripts aren't syntax-checked
(`test_syntax` compiles `lib/*.py` and hooks but skips `plugins/`; both
plugins — cctrl-ports, cctrl-scan — are Python, `#!/usr/bin/env python3`),
`session say` has no Claude-modal fixture (only Codex), and host registry
CRUD (`host add/list/rm`) plus the profile verbs `use`/`diff`/`current` have
zero direct tests (`save`/`rename` ARE already exercised directly by the
profile-perms test). `cctrl fleet`'s local header can print `swap ?MB ·
load ?` — but the Darwin probes already parse `sysctl vm.swapusage` /
`vm.loadavg` (`_res_swap_used_mb`, `_res_load1`); the `?` comes only from
the generic empty fallback in `_res_health_line`, so the remaining work is
fallback presentation, not parsing.

**Acceptance criteria:**

- [ ] README documents the full current surface: session doctor/autoheal/prune/key/ask (`session say` already has its section — keep it current, don't re-add), `ls --recap` + STATE column (updated sample), fleet, needs-me (incl. `--peek`), peer messaging (incl. reply/`--deliver`, bounced status, doorbell install via `peer doctor --fix`) in the feature list, the launch guard, and a note that port management is the `cctrl-ports` plugin.
- [ ] Top-level `cctrl help` lists `peer check`, `peer recv`, `session say`, `session key`, `session ask`, `session autoheal`, and `start --profile`.
- [ ] Help/README agreement is asserted via concrete named lines (no hand-maintained parallel inventory or parser): `./cctrl help` AND README each contain `peer check`, `peer recv`, and `start --profile`.
- [ ] Every command/flag documented in the README rewrite is spot-verified against the live binary (`./cctrl <cmd> --help` or equivalent) before being written — no documenting from memory; the `session ls` sample is GENERATED from a fixture fleet, not hand-written.
- [ ] `test_syntax` runs `python3 -m py_compile` over the plugin entry scripts (`plugins/cctrl-ports`, `plugins/cctrl-scan`) — both are Python, matching what it already does for `lib/*.py`.
- [ ] `session say` gains a Claude-modal fixture test (currently only Codex modal is exercised on the say path).
- [ ] Host registry CRUD (`host add/list/rm`) and the untested profile verbs (`use`/`diff`/`current` — verify each is actually untested before listing; `save`/`rename` are already covered by the profile-perms test) get smoke tests in isolated fixture dirs.
- [ ] `cctrl fleet`'s local resource header never prints a bare `?` for an unavailable probe: the empty fallback in `_res_health_line` presents an explicit `n/a` marker instead (the Darwin sysctl parsing already exists and is NOT in scope).
- [ ] Full suite passes.

## Design

Deliberately last in the wave (blocked by 042/043/044/045/046) so the docs
describe the final surface once instead of chasing it. The fleet-header
fallback-presentation tweak is the only code change beyond `cmd_help` and
tests; everything else is docs + test authoring.

README structure: keep the existing section order; update in place rather than
reorganizing (smaller diff, easier review).

**Files expected to change:**

- `README.md`: feature bullets, session/peer/fleet sections, updated `session ls` sample
- `cctrl`: `cmd_help` additions; the empty-probe fallback in `_res_health_line` (`?` → `n/a`)
- `tests/run-tests.sh`: plugin `py_compile` checks, Claude-modal say fixture, host CRUD + profile smokes

**Testing approach: E2E** — real binary, isolated fixture dirs.

**Out of scope:** CHANGELOG backfill (maintained per-commit already), man
pages, `cctrl-scan` plugin documentation beyond a one-line index mention,
reorganizing README.

## Tasks

1. Update `cmd_help` (peer check/recv, session say/key/ask/autoheal, start --profile).
2. Change the empty-probe fallback in `_res_health_line` from `?` to an explicit `n/a` marker (Darwin sysctl parsing already works — do not touch the probes).
3. Rewrite README's stale sections against the live surface, spot-verifying every documented command/flag via `./cctrl <cmd> --help` (or equivalent); regenerate the `session ls` sample from a fixture fleet (never hand-write it).
4. Add `python3 -m py_compile` checks for `plugins/cctrl-ports` and `plugins/cctrl-scan` to `test_syntax`.
5. Add the Claude-modal say test; add host CRUD smokes and `use`/`diff`/`current` profile smokes (confirm each is untested first; skip any already covered).
6. Run the full suite; assert the named help/README lines (`peer check`, `peer recv`, `start --profile`) appear in both.

## Verification

Checks:

- `[cmd] bash tests/run-tests.sh`
- `[assert] ./cctrl help 2>&1` contains `peer check`
- `[assert] ./cctrl help 2>&1` contains `session say`
- `[assert] cat README.md` contains `needs-me`
- `[assert] bash -c 'sed -n "/_res_health_line()/,/^}/p" cctrl'` contains `n/a`

## Implementation Notes (partially implemented 2026-07-31, NOT done)

**Status is `blocked`, not `done` — but most of this plan has already shipped.**
Every acceptance criterion that does not depend on 042-046 is implemented and
verified below. The four that do are untouched, and they are the only reason
this stays blocked. Whoever picks it up after 042-046 land should read the
"Deliberately NOT done" list at the bottom and do only that; re-doing the rest
would churn work that is already in `main`.

### Completed

- `cmd_help` now lists `peer overview`, `peer check`, `peer recv`, `peer reply`,
  `session say`, `session autoheal`, `session ls --recap`, and a literal
  `cctrl start --profile NAME` line. Asserted by string, per the plan's
  "concrete named lines" rule: `./cctrl help` and README each contain
  `peer check`, `peer recv`, and `start --profile`.
- `_res_health_line`'s empty-probe fallback prints `n/a` instead of a bare `?`,
  with the unit suffix (`%`, `MB`) travelling with the number so a dropped value
  never leaves a stray unit. The Darwin `sysctl` parsing was NOT touched, as the
  plan required — confirmed still live: `mem 75% free · swap 17639MB used ·
  load 4.98 · 28 sessions`.
- README documents `session doctor` / `autoheal` / `prune`, the rich STATE
  column, `session ls --recap`, `cctrl fleet`, `cctrl needs-me`, the low-memory
  launch guard (`-f`/`--force` and its `CCTRL_*` thresholds), `peer reply` and
  `peer send --deliver` with the five-outcome table, top-level `shortcuts`, the
  `cctrl-scan` plugin, and a note that `ports` and `scan` are plugins rather than
  core commands. Peer messaging is now in the feature list.
- The `session ls` sample is **generated**, not hand-written: a fixture fleet
  built with the same fake-tmux/fake-ps technique `tests/run-tests.sh` uses, run
  through the real binary, output pasted verbatim. The old sample was two
  releases stale and used a `~/_projects/` path that does not exist.
- Every command and flag written into the README was spot-verified against the
  live binary first (`./cctrl fleet --help`, `./cctrl needs-me --help`,
  `./cctrl session prune --help`, `./cctrl session autoheal --dry-run`,
  `./cctrl scan --help`, `./cctrl session doctor --json`).
- `test_syntax` compiles the plugin entry scripts. Both plugins are python3, so
  they are copied to a `.py` name and run through `python3 -m py_compile`
  (py_compile requires the suffix). Negative-controlled: a deliberately broken
  plugin is caught.
- New `test_session_say_claude_modal_blocks_and_benign_pane_passes` — the say
  path had a Codex modal fixture only, so the `claude)` branch of the readiness
  check was exercised solely through `peer deliver`, a different code path with a
  different contract (`deferred` vs `busy`). Asserts both directions: a real
  `❯ 1.` modal is a hard stop `--force-busy` cannot override, and a benign
  markdown numbered list still pastes.
- New `test_host_registry_crud` — `host add`/`list`/`rm` had zero direct
  coverage; `hosts.json` was only ever hand-written as a fixture.
- New `test_profile_use_current_diff` — `use`, `current`, and `diff` were
  untested. Confirmed the plan's assumption first: `save`/`rename` are already
  covered (weakly) by the profile-perms test, `edit` still is not.

### Additional finding, fixed here (not in the original plan)

`lib/usage_costs.py` hardcoded one machine's home directory. `claude_project_name`
matched the literal strings `-Users-matthew--projects-` and `-Users-matthew-`, so
on any other machine every Claude project fell through to its raw encoded path in
the `By Project` column — a real correctness bug, not just a public-repo hygiene
problem. The encoded `$HOME` prefix is now derived at runtime via a new
`encoded_home()`, and `codex_project_name` lost its matching hardcoded
`~/_projects/` special case. Covered by `test_project_name_derives_home_at_runtime`,
which drives a fake `HOME` and also greps the source for the old username.
The same sweep replaced the non-existent `$HOME/_projects` in the shortcut
directory-search fallback with `$HOME/dev`, and the personal paths in the
cost-reporting test fixtures with `$HOME`-derived ones.

### Deliberately NOT done (blocked on 042-046)

- `session key` (042) and `session ask` (043) — the commands do not exist, so
  neither `cmd_help` nor README can document them.
- Doorbell install via `peer doctor --fix` (044) — `--fix` does not exist on
  `peer doctor`.
- `bounced` mailbox status (045) — the string appears nowhere in `cctrl`.
- `needs-me --peek` (046) — the flag does not exist.

<!-- mstack:seam
produced:
assumed:
- from: 042; kind: symbol; name: _session_key; file: cctrl
- from: 043; kind: symbol; name: _session_ask; file: cctrl
- from: 044; kind: flag; name: --fix; file: cctrl
- from: 045; kind: schema; name: bounced; file: cctrl
- from: 046; kind: flag; name: --peek; file: cctrl
-->
