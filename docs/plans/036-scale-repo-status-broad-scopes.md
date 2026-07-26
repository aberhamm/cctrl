---
id: 036
title: Scale `cctrl repo status` to whole-tree scopes with parallel probing
status: pending
blocked-by: [035]
priority: 36
goal: cctrl-fleet-repo-visibility
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-26
---

## Requirements

Plan 035 answers the question for repos that currently have a live session
(~12 today). Two of the four founding incidents live outside that set:

- **Untracked plans sat in three repos for days.** By the time anyone looked,
  the sessions that created them were long closed. Session scope is blind to
  exactly the repos that have gone quiet — which is where drift accumulates.
- **Unpushed commits accumulated with nobody aware.** Same shape: a repo stops
  having a session and stops being looked at.

So the command needs a scope that covers repos with no session. The operator's
tree has **89 directories under `~/dev`, 58 of them git repos** (measured
2026-07-26). At that size the serial probe from 035 is too slow to run
habitually — measured on this machine, warm cache:

| scan                                    | wall time |
|-----------------------------------------|-----------|
| 58 repos, serial                        | **13.0s** |
| 58 repos, `xargs -P 8`                  | **1.9s**  |
| 58 repos, `xargs -P 16`                 | **1.2s**  |

13 seconds is a command you stop running. ~2 seconds is one you run on reflex.
The work is I/O-bound (0.18s user against 13s wall serial), so parallelism is
close to free.

Crucially, cctrl must **not learn about `~/dev`**. It is a public,
environment-agnostic CLI (AGENTS.md: skills and code carry "no environment
specifics — no hostnames, URLs, IPs, tokens, ports, or repo names"). The scope
must come from data cctrl already owns or from the caller.

**Acceptance criteria:**

- [ ] `--shortcuts` adds the target dir of every entry in `data/shortcuts.json`
      to the scope. This is the operator's own declared list of repos-that-matter
      and requires no new configuration surface.
- [ ] `--root DIR` (repeatable) adds every git repository that is a **depth-1
      child** of `DIR`. `cctrl repo status --root ~/dev` is how the 58-repo sweep
      is expressed — `~/dev` is supplied by the caller, never by cctrl.
- [ ] `CCTRL_REPO_ROOTS` (colon-separated, like `PATH`) supplies default roots
      so the habitual invocation is a bare `cctrl repo status --all` with no
      arguments to remember.
- [ ] `--all` = sessions ∪ shortcuts ∪ `CCTRL_REPO_ROOTS` ∪ every `--root`.
      Default scope stays sessions-only: the fast, always-relevant answer.
- [ ] Repos are deduplicated by resolved toplevel; `sources` accumulates every
      origin (`["session","shortcut","root"]`) so the human output can show *why*
      a repo is in the list.
- [ ] Probing is parallel with a bounded worker pool. Default 8; `--jobs N`
      overrides; `--jobs 1` forces serial (the debugging escape hatch).
- [ ] Whole-tree scan of ~58 repos completes in **under 3s** warm, and the
      default session scope stays **under 1s**.
- [ ] Parallelism changes performance only. Byte-identical output to `--jobs 1`
      for the same scope: same ordering, same fields, same fail-closed rows.
- [ ] Still strictly read-only. All of plan 035's guarantees hold unchanged,
      including the static mutation guard and the read-only invariance test,
      now also exercised through the parallel path.
- [ ] A `--root` that does not exist, or contains no repos, is a warning on
      stderr and an empty contribution — never a hard failure that voids an
      otherwise good scan.

## Design

### Where scopes come from — and why not a config file

cctrl already knows two sets of directories, and neither needs new state:

1. **Session cwds** (plan 035's default) — where work is happening *now*.
2. **Shortcut targets** — `data/shortcuts.json`, the operator's hand-curated
   "repos I jump to". Today: 16 entries covering cctrl, homelab, mstack,
   agent-hub, finance-hub, the scraper, and so on. Read it exactly as
   `_shortcut_list` does (`cctrl:7501-7529`): `jq -r 'to_entries[] | .value.dir'`.

Everything else comes from the caller via `--root` / `CCTRL_REPO_ROOTS`. A new
`data/repo-roots.json` was considered and rejected: it duplicates what shortcuts
already express, adds a file to keep in sync across two machines under livesync,
and needs its own CRUD verbs. An env var plus a flag is the whole feature.

*Gotcha to handle:* `SHORTCUTS_FILE` is hardcoded to `$SCRIPT_DIR/data/shortcuts.json`
at `cctrl:13` and, unlike the peer/session/needs-me paths, is **not** overridable
via `CCTRL_DATA_DIR` (`cctrl:16-41`). Testing `--shortcuts` therefore requires
either adding a `_repo_refresh_paths`-style override (preferred: follow the
existing four-function convention at `cctrl:16-41`) or running against a copied
script dir as `test_profile_*` already does. Pick the override; it is three
lines and removes a real testability gap.

*Shortcut dirs are not all repos.* Today `@projects → /Users/matthew/dev` — a
root, not a repo. Do **not** auto-promote a non-repo shortcut into a root; that
magic would silently turn `--shortcuts` into a 58-repo scan. It resolves to a
`not-a-repo` row exactly as plan 035 specifies, and the operator writes
`--root ~/dev` when they mean a root. Predictable beats clever.

### `--root` semantics: depth 1, deliberately

`--root DIR` scans `DIR/*/.git` — depth-1 children only. Not recursive:
unbounded `find` descent through `node_modules`, build dirs, and nested
worktrees is both slow and surprising. A repo nested deeper is added with its
own `--root` or by having a session in it. If a recursive mode is ever wanted it
arrives as an explicit `--depth N`, not as a default. `DIR` itself is also
checked: a `--root` that is itself a repo contributes itself.

### Parallel probing

`_repo_probe_json` is already a pure path-in/JSON-out function (plan 035
required this). Drive it as a subprocess pool:

- **Primitive: `xargs -P N`.** This machine runs **bash 3.2.57** (macOS system
  bash — `cctrl` is `#!/usr/bin/env bash` and must keep working there), so
  `wait -n` and `mapfile` are unavailable. `xargs -P` is the portable pool.
- **Re-entry, not a helper script.** Each worker invokes the cctrl binary with a
  hidden internal subcommand, `cctrl repo _probe <path>`, which calls
  `_repo_probe_json` and prints one JSON object. Measured cctrl startup is
  **~21ms**; 58 re-entries at `-P 8` add ~150ms total, which is noise against a
  1.9s scan. The alternative — a second file under `lib/` — would fork cctrl's
  single-file distribution for no measurable gain.
  `_probe` is undocumented in `--help`, prefixed with `_` to signal internal,
  and rejects being given anything other than a single existing path.
- **Never share stdout.** `PIPE_BUF` on Darwin is **512 bytes** (verified), and
  a probe object with a session array routinely exceeds that, so concurrent
  writes to one pipe would interleave and corrupt JSON. Each worker writes to
  `$TMPDIR_SCAN/<n>.json` in a `mktemp -d`; the parent concatenates and
  `jq -s`'s them after the pool drains. `trap 'rm -rf …' RETURN`/`EXIT` cleans up.
- **Ordering is the parent's job.** Workers finish out of order by definition;
  the parent applies plan 035's sort (attention-first → session count desc →
  name) after collection. This is what makes output byte-identical to `--jobs 1`.
- **A crashed worker is `unknown`, not a gap.** If a worker's output file is
  missing or unparseable, synthesize a fail-closed `verdict: "unknown"` row with
  the path and an error. Fail closed applies to the harness, not just to git.
- `--jobs` is clamped to `[1, 32]`; a non-numeric value is a usage error.

### Human output at 58 repos

At session scope every repo prints. At `--all` scope, 58 rows of mostly-clean
repos buries the signal, so:

- `--dirty-only` (already added in plan 035) becomes the recommended pairing and
  is mentioned in `--help`.
- The footer gains scope accounting:
  `58 repos (12 session · 16 shortcut · 58 root) · 9 need attention · 48 clean · 1 unknown`.
- A `SRC` column (`s`/`c`/`r` letters, or `sc` for both) shows why each repo is
  in the list, so a surprising row is explicable at a glance.
- Nothing about the per-row format changes; a wider scope must not mean a
  different-looking table.

**Files expected to change:**

- `cctrl`: `_repo_discover_json` gains the shortcut/root/env sources and
  `sources` accumulation; new `_repo_scan_parallel`; `cmd_repo` gains
  `--shortcuts`, `--root`, `--all`, `--jobs`, and the hidden `_probe`;
  `_repo_refresh_paths` added next to the existing path-refresh functions
  (`cctrl:16-41`) to make `SHORTCUTS_FILE` overridable; `cmd_help` updated.
- `tests/run-tests.sh`: `test_repo_status_scopes` and
  `test_repo_status_parallel_determinism`.
- `CHANGELOG.md`, `README.md`.

**Out of scope:**

- Recursive root scanning (`--depth`), repo-exclude patterns, and any
  `.cctrlignore`. Add them when a real case demands it.
- Caching or incremental scans. 1.9s does not need a cache, and a cache would
  introduce staleness into a tool whose entire value is being current.
- Any form of `--fetch` — see plan 035's Design. Broadening the scope makes the
  argument stronger, not weaker: 58 network round-trips is not a habitual
  command.
- Multi-host aggregation; `cctrl --host <alias> repo status --all` already
  works through the global flag (`cctrl:7943-7957`).
- Changing the default scope. Sessions-only stays the default precisely because
  it is sub-second and always relevant.

## Tasks

1. Add `_repo_refresh_paths` beside the existing path-refresh functions so
   `SHORTCUTS_FILE` honors `CCTRL_DATA_DIR`; keep the current default byte-identical.
2. Extend `_repo_discover_json` with shortcut, `--root`, and `CCTRL_REPO_ROOTS`
   sources; dedupe by resolved toplevel; accumulate `sources`.
3. Add the hidden `cctrl repo _probe <path>` arm (single existing path only;
   absent from `--help`).
4. Implement `_repo_scan_parallel`: `mktemp -d`, `xargs -P "$jobs"`, per-worker
   output files, `jq -s` collection, missing/unparseable file ⇒ synthesized
   `unknown` row, cleanup trap. `--jobs 1` takes the in-process serial path.
5. Wire `--shortcuts`, `--root DIR` (repeatable), `--all`, `--jobs N` into
   `cmd_repo`; clamp and validate `--jobs`; warn-not-fail on a bad `--root`.
6. Add the `SRC` column and the scope-accounting footer.
7. Tests: (a) scope composition against temp repos and a fake shortcuts file;
   (b) `--jobs 8` output byte-identical to `--jobs 1` over ≥12 fixture repos;
   (c) a worker that produces no output yields an `unknown` row rather than a
   missing one; (d) plan 035's read-only invariance re-run through the parallel
   path.
8. Update `CHANGELOG.md` and `README.md`.

## Verification

- `[cmd]` `bash -n cctrl`
- `[cmd]` `tests/run-tests.sh`
- `[assert]` `cctrl repo status --all --json | jq -e 'type=="array"'` prints `true`
- `[assert]` determinism —
  `diff <(cctrl repo status --root "$FIXTURES" --jobs 1 --json) <(cctrl repo status --root "$FIXTURES" --jobs 8 --json)`
  exits 0. This is the load-bearing check for the whole plan.
- `[assert]` `cctrl repo status --root "$FIXTURES" --json | jq -e '[.[] | .sources[]] | index("root") != null'`
  prints `true`
- `[assert]` a `--root` pointing at a nonexistent path exits 0, writes a warning
  to stderr, and still reports the other scopes' repos
- `[assert]` `--jobs 0` and `--jobs abc` exit non-zero with a usage message
- `[cmd]` performance gate — a scan of ≥50 fixture repos at default `--jobs`
  completes in under 5s wall (generous headroom over the measured 1.9s; the gate
  exists to catch an accidental serialization regression, not to benchmark CI
  hardware)
- `[assert]` read-only invariance (plan 035's fixture check) still passes when
  run through `--jobs 8`
- `[manual]` `time cctrl repo status --root ~/dev --dirty-only` on the live tree:
  under 3s, and the reported set matches a hand-run `git status` loop.
