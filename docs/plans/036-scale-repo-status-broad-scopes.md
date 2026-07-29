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
reviews:
  - type=eng verdict=changes-requested date=2026-07-28 by=mstack-review
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
tree has **88 directories under `~/dev`, 58 of them git repos at depth 1**
(re-measured 2026-07-28). At that size the serial probe from 035 is too slow to
run habitually — measured on this machine, warm cache, in two independent runs:

| scan                     | wall (author) | wall (reviewer) |
|--------------------------|---------------|-----------------|
| 58 repos, serial         | 13.0s         | **8.2s**        |
| 58 repos, `xargs -P 8`   | 1.9s          | **1.2s**        |
| 58 repos, `xargs -P 16`  | 1.2s          | —               |

Treat the slower column as the budget and the faster as the likely case; the two
runs differ by machine load (this box routinely runs ~25 concurrent agent
sessions). Either way the conclusion is the same: **~8-13s is a command you stop
running; ~1-2s is one you run on reflex**, and parallelism buys ~7×.

*Do not repeat the draft's "the work is I/O-bound, 0.18s user against 13s wall"
claim, in this plan or in a source comment — it is wrong.* That measured only
the driving shell's own user time, not its children's. The same 58 repos at
`-P 8` burn **7.00s user / 1.47s sys at 695% CPU**: the work is genuinely CPU-
and syscall-heavy, and parallelism helps because there are cores to spread it
across, not because the cores are idle waiting on disk.

Crucially, cctrl must **not learn about `~/dev`**. It is a public,
environment-agnostic CLI (AGENTS.md: skills and code carry "no environment
specifics — no hostnames, URLs, IPs, tokens, ports, or repo names"). The scope
must come from data cctrl already owns or from the caller.

**Acceptance criteria:**

- [ ] **Scope flags REPLACE the session default; they do not add to it.** Stated
      once, precisely, because the draft left it ambiguous and no test caught it:
      the session scope applies **only when no scope flag is given**. So
      `cctrl repo status --root <tree>` lists that tree's repos and *nothing
      else*, even when live sessions sit outside it. `--all` is the explicit
      union. Rationale: a caller who names a scope asked for that scope, and
      silently appending unrelated repos makes the row count unpredictable and
      the command hard to script against. `--all` exists precisely so the union
      is available by asking for it.
- [ ] **The session→repo join is orthogonal to scope and always runs.** Scope
      decides which repos are *listed*; the join decides what `sessions[]`
      contains for a listed repo. A repo reached only via `--root` still shows
      the sessions working in it — otherwise the feature's whole value-add
      disappears at exactly the scope where the operator sweeps.
- [ ] `--shortcuts` scopes to the target dir of every entry in
      `data/shortcuts.json`. This is the operator's own declared list of
      repos-that-matter and requires no new configuration surface.
- [ ] `--root DIR` (repeatable) scopes to every git repository that is a
      **depth-1 child** of `DIR` (plus `DIR` itself if it is a repo).
      `cctrl repo status --root ~/dev` is how the 58-repo sweep is expressed —
      `~/dev` is supplied by the caller, never by cctrl.
- [ ] `CCTRL_REPO_ROOTS` (colon-separated, like `PATH`) supplies default roots.
      Its entries behave exactly as if passed via `--root`, but **only when a
      scope flag asks for them** — that is, under `--all`, or under a bare
      `--root` with no argument if that form is offered. A no-flag invocation
      stays sessions-only **even when the env var is set**. Stated explicitly
      because the alternative — an env var that silently redefines the default
      scope — would make `cctrl repo status` mean different things on two
      machines, which is the one property a habitual command cannot afford.
- [ ] `--all` = sessions ∪ shortcuts ∪ `CCTRL_REPO_ROOTS` ∪ every `--root`.
      Default scope stays sessions-only: the fast, always-relevant answer.
- [ ] Scope composition is covered by a test with a **non-empty** fake session
      set, asserting exact row counts for `--root` alone vs `--all`. The draft's
      checks all ran with an empty session set, where replace and add are
      indistinguishable.
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
      otherwise good scan. **This includes the empty-array case**: on bash 3.2 a
      bare `"${paths[@]}"` on an empty array aborts under `set -u`, and `set +e`
      does not suppress it, so the pool invocation must use
      `${paths[@]+"${paths[@]}"}` or short-circuit on zero length.
- [ ] **Truncation is impossible to miss**: collection iterates the scope's input
      path list (never a temp-dir glob) and the row count always equals the scope
      count. Required because BSD `xargs` returns `1` for both "a worker failed"
      and "input was truncated", so the exit status can never detect the
      difference — and a worker killed by a signal drops the remaining input no
      matter what exit codes `_probe` promises.

## Design

### Where scopes come from — and why not a config file

cctrl already knows two sets of directories, and neither needs new state:

1. **Session cwds** (plan 035's default) — where work is happening *now*.
2. **Shortcut targets** — `data/shortcuts.json`, the operator's hand-curated
   "repos I jump to". Today: 16 entries covering cctrl, homelab, mstack,
   agent-hub, finance-hub, the scraper, and so on. Extract dirs with
   `jq -r 'to_entries[] | .value.dir // empty'` against `SHORTCUTS_FILE`.

   *This is new code, not reuse — do not go looking for a helper to call.*
   `_shortcut_list` is a human renderer whose jq emits interleaved fields
   (`to_entries[] | .key, (.value.dir // ""), …`) for its read loop; it exposes
   no dir extractor. The expression above is correct against the *file*, which is
   the actual contract. Also: shortcut dirs carry trailing slashes
   (`/…/cctrl/`), which `rev-parse --show-toplevel` normalizes away, so dedup by
   toplevel is safe without pre-trimming.

Everything else comes from the caller via `--root` / `CCTRL_REPO_ROOTS`. A new
`data/repo-roots.json` was considered and rejected: it duplicates what shortcuts
already express, adds a file to keep in sync across two machines under livesync,
and needs its own CRUD verbs. An env var plus a flag is the whole feature.

*Gotcha to handle:* `SHORTCUTS_FILE` is hardcoded to `$SCRIPT_DIR/data/shortcuts.json`
as a top-level assignment and, unlike the peer/session/needs-me paths, is **not** overridable
via `CCTRL_DATA_DIR`. Testing `--shortcuts` therefore requires
either adding a `_repo_refresh_paths`-style override (preferred: follow the
existing four-function `*_refresh_paths` convention) or running against a copied
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

**Depth-1 has a real, live cost — document it rather than discovering it.**
On 2026-07-28 a live session is working in
`~/dev/repo-audits/natively-cluely-audit` — depth **2**. So
`cctrl repo status --root ~/dev` does **not** cover every repo the fleet is
working in, and under the replace-not-add semantics decided above it would omit
that session's repo entirely. This is not an argument for recursion; it is the
argument for `--all` (the union with session scope catches exactly this) and for
the human footer's `SRC` column, which makes "why is this repo here / where did
it go" answerable at a glance. Say so in `--help`: `--root` is a *tree sweep*,
`--all` is *everything cctrl knows about*.

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
  **This guarantee does not hold for free — see the next section, which is the
  single most important part of this plan.**
- `--jobs` is clamped to `[1, 32]`; a non-numeric value is a usage error.

### `xargs -P` under `set -euo pipefail` — the trap that voids fail-closed

`cctrl` runs `set -euo pipefail` on line 2. **`xargs` exits non-zero when any
worker exits non-zero, and on certain worker terminations it aborts the remaining
input entirely** — dropping repos from the scan. Under `set -e` plus `pipefail`,
that non-zero status kills the parent **before it ever reaches the collection
step**, so the synthesize-an-`unknown`-row logic never runs and the command emits
*nothing at all*. Reproduced on this machine (2026-07-28, and independently
re-verified 2026-07-29):

    $ bash -c 'set -euo pipefail
      run() { printf "a\nb\n" | xargs -P 2 -I{} sh -c "exit 1"; echo AFTER-XARGS; }
      run; echo FUNCTION-RETURNED'
    outer rc=1        # neither AFTER-XARGS nor FUNCTION-RETURNED ever printed

    $ printf 'a\nb\nc\n' | xargs -P 2 -I{} sh -c 'exit 255'
    xargs: sh: exited with status 255; aborting     # remaining input dropped

The trigger is exactly the condition `unknown` exists for: an unreadable `.git`,
a path that vanishes mid-scan, a `jq` failure inside a probe, or the probe
tripping `set -e` on its own.

#### Two corrections to the previous revision — both were load-bearing and wrong

**BSD `xargs` has no distinct status codes.** The earlier text claimed "status
123 for worker statuses 1–125", which is **GNU** behavior. On macOS, measured:

    worker exit 1 → rc=1 · exit 42 → rc=1 · exit 125 → rc=1 · exit 255 → rc=1

BSD's man page: *"if any other error occurs, xargs exits with a value of 1."*
There is no 123/124/125. **Consequence: `rc=1` cannot distinguish "one worker
failed" from "input was truncated by an abort."** Any implementation branching on
123 is dead code, and — critically — **the exit status can never be used to
detect truncation.** That is the whole reason defense 3 below must iterate the
input path list.

**`|| true` does bind to the whole pipeline; the previous justification for
`set +e` was false.** The earlier text asserted "the guard must cover the whole
pipeline, not just the last command." `||` binds to the entire pipeline in shell
grammar; `pipefail` only changes which status the pipeline *reports*. Measured:

    $ set -euo pipefail; printf "a\nb\n" | xargs -P 2 -I{} sh -c "exit 1" || true
    REACHED-COLLECTION

And `set +e` is strictly **worse**, because it is shell-global rather than
function-scoped — any `return` on an error branch between `set +e` and `set -e`
silently disables `errexit` for the rest of the process. Measured: `f(){ set +e;
false; return 0; }; f; false; echo LEAKED` → prints `LEAKED`. **Mandate `|| true`
(or an explicit `PIPESTATUS` capture) and delete the false claim.** This matters
beyond tidiness: this plan explicitly instructs its prose to reach source
comments, so a wrong rule here propagates into the code.

#### Three defenses — only the third actually closes the hole

1. **Guard the pool invocation with `|| true`** so a worker's status cannot kill
   the parent. Note the empty-scope guard, which is not optional:

       printf '%s\0' ${paths[@]+"${paths[@]}"} \
         | xargs -0 -P "$jobs" -n 1 "$CCTRL_SELF" repo _probe \
         || true

   **`${paths[@]+"${paths[@]}"}` is mandatory.** On bash 3.2 a bare
   `"${paths[@]}"` on an **empty** array is an unbound-variable error under
   `set -u`, and `set +e` does **not** suppress it — measured:
   `a=(); set +e; printf "%s\n" "${a[@]}"` → `a[@]: unbound variable`. An empty
   scope is reachable via an empty `--root`, `--shortcuts` against an empty
   `shortcuts.json`, or a nonexistent `--root`, and an abort there directly
   voids this plan's own AC (*"a `--root` that does not exist… never a hard
   failure"*). Every other array expansion in `cctrl` is already guarded this
   way; this must not be the one exception. An explicit zero-length
   short-circuit before the pipeline is equally acceptable and clearer.

   **`-0 -n 1`, not `-I{}`.** NUL-delimited input, with the path appended as the
   final argument. This fixes two BSD-specific defects at once: `xargs -I` has a
   hard **254-byte** replstr limit (255 fails with *"command line cannot be
   assembled, too long"* and aborts the whole scan), and BSD `xargs` **parses
   quotes and backslashes in its input** — a path containing a double quote kills
   the scan with *"unterminated quote"*, and a newline in a directory name splits
   one path into two. `--root` sweeps whatever is on disk, so neither is
   hypothetical. Dropping `-I` removes the replstr limit entirely rather than
   merely leaving headroom under it.

   **`CCTRL_SELF` must be defined** — it does not exist in `cctrl` today (grep:
   zero matches), so the previous revision's mandated line was itself an
   unbound-variable abort under `set -u`. Define it once near `SCRIPT_DIR` as the
   resolved path to the running script.

2. **`cctrl repo _probe` always exits 0**, emitting a `verdict: "unknown"` object
   carrying `error` on any internal failure. Useful hygiene — but **this defense
   is insufficient by construction and must not be relied on.** A worker killed
   by a *signal* aborts remaining input identically: SIGKILL, SIGTERM and SIGPIPE
   all produce `aborting`, `rc=1`, and survivors dropped. `_probe` can promise its
   own exit code; it cannot promise not to be OOM-killed on a box running ~25
   concurrent agent sessions, that `jq` will not SIGSEGV, or that it will not take
   SIGPIPE when a downstream reader closes. Left here alone, the failure mode is
   *worse* than the original blocker: the scan reports 7 of 39 repos **and exits
   0**, which looks like success.

3. **Collection iterates the SCOPE'S INPUT PATH LIST — never a glob of the temp
   dir.** This is the only defense that actually closes the hole, and the only
   sound truncation detector (per the BSD exit-status correction above). For each
   path in the scope list, read its expected output file; if the file is missing,
   empty, or unparseable, synthesize a fail-closed `verdict: "unknown"` row for
   **that path**. Globbing the temp dir cannot detect truncation, because a
   dropped repo leaves no file to find.

   **This requires a deterministic path → filename mapping**, which also fixes
   the previous revision's `"$TMPDIR_SCAN/<n>.json"` — where `<n>` had no source
   (`-n 1` hands the worker a path, not an index) and `TMPDIR_SCAN` was a parent
   variable a separate process never sees. Use a **hash of the absolute path**
   (e.g. `cksum`/`shasum` of the path string) as the filename, computed
   identically by parent and worker, and **export** `TMPDIR_SCAN` before the pool
   runs. The worker redirects its own stdout to that file — which is also what
   satisfies the "never share stdout" bullet above, since the previous revision's
   snippet had **no redirection at all** and would have had every worker writing
   JSON into one shared pipe, reproducing the >512-byte `PIPE_BUF` interleaving
   corruption that bullet exists to prevent.

   **Assert `row-count == scope-count`.** Unconditionally, in the implementation
   and in the tests. It is the one invariant that makes silent truncation
   impossible.

**All path overrides must be exported before the pool runs.** `_probe` is a
separate process and re-resolves `CCTRL_DATA_DIR` / `CCTRL_SESSION_METADATA_DIR`
/ `TMPDIR_SCAN` from its own environment. A test that sets one without `export`
configures only the parent — and the `--jobs 1` vs `--jobs 8` determinism diff
would then be comparing two different data dirs while appearing to pass.

### Human output at 58 repos

At session scope every repo prints. At `--all` scope, 58 rows of mostly-clean
repos buries the signal, so:

- `--attention-only` (added in plan 035; renamed there from the draft's
  `--dirty-only` precisely because this plan makes it the habitual pairing)
  becomes the recommended form and is mentioned in `--help`.
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
  (`_peer_refresh_paths` / `_session_refresh_paths` / `_autoheal_refresh_paths` /
  `_needs_me_refresh_paths`) to make `SHORTCUTS_FILE` overridable; `cmd_help`
  updated.
- `tests/run-tests.sh`: `test_repo_status_scopes` and
  `test_repo_status_parallel_determinism`.
- `CHANGELOG.md`, `README.md`.

**Out of scope:**

- Recursive root scanning (`--depth`), repo-exclude patterns, and any
  `.cctrlignore`. Add them when a real case demands it.
- Caching or incremental scans. 1-2s does not need a cache, and a cache would
  introduce staleness into a tool whose entire value is being current.
- Any form of `--fetch` — see plan 035's Design. Broadening the scope makes the
  argument stronger, not weaker: 58 network round-trips is not a habitual
  command.
- Multi-host aggregation; `cctrl --host <alias> repo status --all` already
  works through the global flag.
- Changing the default scope. Sessions-only stays the default precisely because
  it is sub-second and always relevant.

## Tasks

1. Add `_repo_refresh_paths` beside the existing path-refresh functions so
   `SHORTCUTS_FILE` honors `CCTRL_DATA_DIR`; keep the current default byte-identical.
2. Extend `_repo_discover_json` with shortcut, `--root`, and `CCTRL_REPO_ROOTS`
   sources; dedupe by resolved toplevel; accumulate `sources`.
3. Add the hidden `cctrl repo _probe <path>` arm (single existing path only;
   absent from `--help`). **It always exits 0**, emitting a `verdict: "unknown"`
   object with `error` on any internal failure. It writes its JSON to
   `$TMPDIR_SCAN/<hash-of-path>.json`, not to stdout. Treat its exit-code
   discipline as hygiene, not as a guarantee — signals bypass it entirely.
4. Define `CCTRL_SELF` (resolved path to the running script) near `SCRIPT_DIR`;
   it does not exist today and the pool line cannot work without it.
5. Implement `_repo_scan_parallel`: `mktemp -d`; **export** `TMPDIR_SCAN` and all
   path overrides; `printf '%s\0' ${paths[@]+"${paths[@]}"} | xargs -0 -P "$jobs"
   -n 1 "$CCTRL_SELF" repo _probe || true`; then **collect by iterating the scope
   path list** (never a temp-dir glob), synthesizing `unknown` for any path whose
   file is missing/empty/unparseable; assert `row-count == scope-count`; cleanup
   trap. `--jobs 1` takes the in-process serial path.
   Do **not** write `set +e` (shell-global, leaks errexit past a `return`) and do
   **not** branch on exit status 123 (GNU-only; BSD returns 1 for everything).
6. Wire `--shortcuts`, `--root DIR` (repeatable), `--all`, `--jobs N` into
   `cmd_repo`; implement **replace-not-add** scope semantics; clamp and validate
   `--jobs`; warn-not-fail on a bad `--root`. Preserve plan 035's `--here`
   mutual-exclusion when those flags appear — **but note 035's `--here` is
   currently PARKED pending an open human decision; if it has not landed, this
   task has nothing to preserve and finding 035-6 stays open.**
7. Add the `SRC` column and the scope-accounting footer.
8. Tests:
   (a) **scope composition with a NON-EMPTY fake session set** — assert exact row
       counts for `--root` alone (fixture repos only, no session repos) vs
       `--all` (the union). An empty session set makes replace and add
       indistinguishable, which is how the draft's ambiguity survived review.
   (b) `--jobs 8` output byte-identical to `--jobs 1` over ≥12 fixture repos.
   (c) **The truncation test — the one that actually guards the blocker.**
       The previous revision's exit-1 fixture still passes against a broken
       implementation: exit 1 is precisely the case `|| true` already fixes, and
       since BSD xargs returns 1 for *both* "worker failed" and "input
       truncated", an exit-1 fixture never exercises the abort path where the
       data loss lives. Required shape instead:
       - **≥16 fixture repos**, `--jobs 8`, and the rigged repo named to sort
         **EARLY** (e.g. `00-boom`) so an abort has survivors left to eat. A
         2-repo fixture with the rigged repo scheduled last passes trivially.
       - **Three mandatory rigged variants**, each run separately: `exit 1`,
         `exit 255`, and `kill -9 $$`. 255 is no longer "if it can be arranged
         cheaply" — it is `sh -c 'exit 255'`, and it is the **only** variant that
         proves defense 3. `kill -9` covers the signal path that defense 2
         provably cannot close.
       - Assert for each: `jq 'length'` **== the exact scope count**,
         `[.[]|select(.verdict=="unknown")]|length == 1`, and that row's `path`
         == the rigged repo's path.
   (d) plan 035's read-only invariance re-run through the parallel path.
   (e) empty scope: `--root <empty-dir>` and `--shortcuts` against an empty
       shortcuts file each exit 0 with `[]` — the `set -u` unbound-array guard.
9. Update `CHANGELOG.md` and `README.md`.

## Verification

- `[cmd]` `bash -n cctrl`
- `[cmd]` `tests/run-tests.sh`
- `[assert]` `cctrl repo status --all --json | jq -e 'type=="array"'` prints `true`
- `[assert]` determinism —
  `diff <(cctrl repo status --root "$FIXTURES" --jobs 1 --json) <(cctrl repo status --root "$FIXTURES" --jobs 8 --json)`
  exits 0. This is the load-bearing check for the whole plan.
- `[assert]` `cctrl repo status --root "$FIXTURES" --json | jq -e '[.[] | .sources[]] | index("root") != null'`
  prints `true`
- `[assert]` **fail-closed through the pool — the truncation gate.** ≥16 fixture
  repos, `--jobs 8`, rigged repo named to sort EARLY (`00-boom`). Run three
  variants separately — `exit 1`, `exit 255`, `kill -9 $$` — and for each assert:
  the scan exits 0; `jq 'length'` **== the exact scope count**;
  `[.[]|select(.verdict=="unknown")]|length == 1`; that row's `path` == the
  rigged repo. The `exit 255` and `kill -9` variants are the load-bearing ones —
  `exit 1` is the case `|| true` already fixes, and BSD xargs returns 1 for both
  "worker failed" and "input truncated", so an exit-1 fixture never reaches the
  abort path where the data loss lives.
- `[assert]` **empty scope does not abort** — `--root <empty-dir>` and
  `--shortcuts` against an empty shortcuts file each exit 0 and print `[]`.
  Guards the `set -u` unbound-array expansion, which `set +e` does not suppress.
- `[assert]` **no `set +e` and no 123-branching in the implementation** — the
  repo subsystem contains neither `set +e` (shell-global, leaks errexit past a
  `return`) nor a comparison against exit status 123/124/125 (GNU-only; BSD
  returns 1 for everything). Cheap lint against two corrections that a future
  edit could silently undo.
- `[assert]` **scope semantics** — with a non-empty fake session set,
  `cctrl repo status --root "$FIXTURES" --json | jq 'length'` equals the fixture
  repo count (session repos excluded), while `--all` returns the union count
- `[assert]` a `--root` pointing at a nonexistent path exits 0, writes a warning
  to stderr, and still reports the other scopes' repos
- `[assert]` `--jobs 0` and `--jobs abc` exit non-zero with a usage message
- `[cmd]` performance gate — **opt-in, gated behind `CCTRL_TEST_PERF=1`**: a scan
  of ≥50 fixture repos at default `--jobs` completes in under 5s wall. Not a
  default gate: it would be the only wall-clock assertion in `tests/run-tests.sh`
  (there are none today), building ≥50 fixture repos costs real time before the
  gate even starts, and this machine routinely runs ~25 concurrent agent
  sessions — it would flake. The `--jobs 1` vs `--jobs 8` determinism diff stays
  the hard gate; it is the genuinely load-bearing check for this plan.
- `[assert]` read-only invariance (plan 035's fixture check) still passes when
  run through `--jobs 8`
- `[manual]` `time cctrl repo status --root ~/dev --attention-only` on the live
  tree: under 3s, and the reported set matches a hand-run `git status` loop.
- `[manual]` `cctrl repo status --all` includes the live session working in
  `~/dev/repo-audits/…` (depth 2) that `--root ~/dev` alone necessarily misses —
  confirming `--all` is the union and depth-1 is a documented boundary, not a bug.

## Eng review — 2026-07-28

Reviewed by an independent session (not the author). Verdict:
**changes-requested** — one blocking defect, plus one specification ambiguity
that no current test can catch.

Scores: clarity 9 · testability 8 · scope-fit 8 · autonomy 6 · trap-resistance 7
→ composite **7.6/10**.

Environment claims verified 2026-07-28: bash **3.2.57** ✓, Darwin `PIPE_BUF`
**512** ✓, **58** depth-1 git repos under the operator's tree ✓ (88 dirs, plan
said 89), cctrl startup ~25ms ✓. Measured timings differ from the plan's table —
serial **8.2s** (plan: 13.0s), `xargs -P 8` **1.2s** (plan: 1.9s) — but both
acceptance targets (<3s all-scope, <1s session-scope) remain comfortably
reachable.

### BLOCKER: `xargs -P` aborts the entire scan under `set -euo pipefail`

**What the plan currently specifies.** Design § "Parallel probing" drives
`_repo_probe_json` as a subprocess pool via `xargs -P N`, each worker
re-entering the cctrl binary as `cctrl repo _probe <path>` and writing to
`$TMPDIR_SCAN/<n>.json`. Worker failure is handled only at the *output* layer:
"If a worker's output file is missing or unparseable, synthesize a fail-closed
`verdict: "unknown"` row with the path and an error."

**The exact failure mode.** `cctrl` runs `set -euo pipefail` (`cctrl:2`).
`xargs` exits non-zero when **any** worker exits non-zero — status 123 for
worker statuses 1–125, and on status 255 it *aborts remaining input entirely*.
Under `set -e` plus `pipefail`, that non-zero status kills the parent **before
it ever reaches the collection step**, so the synthesized-unknown logic never
executes. The command produces no output at all, instead of a table with one
`unknown` row.

Trigger: any single probe failing. Realistically — a repo whose `.git` is
unreadable, a path that vanishes mid-scan, a `jq` parse failure inside the
probe, or the probe itself tripping `set -e`. That is not an edge case; it is
precisely the condition the `unknown` verdict was invented for.

Demonstrated on this machine, 2026-07-28:

    $ bash -c 'set -euo pipefail
      run() { printf "a\nb\n" | xargs -P 2 -I{} sh -c "exit 1"; echo AFTER-XARGS; }
      run; echo FUNCTION-RETURNED'
    outer rc=1        # neither AFTER-XARGS nor FUNCTION-RETURNED ever printed

    $ printf 'a\nb\nc\n' | xargs -P 2 -I{} sh -c 'exit 255'
    xargs: sh: exited with status 255; aborting     # remaining input dropped

**The guarantee this breaks**, quoted from this plan's Design § "Parallel
probing": *"**A crashed worker is `unknown`, not a gap.** If a worker's output
file is missing or unparseable, synthesize a fail-closed `verdict: "unknown"`
row with the path and an error. Fail closed applies to the harness, not just to
git."* As specified, a crashed worker is neither `unknown` nor a gap — it is a
dead command with no output. It also breaks this plan's Acceptance Criterion
*"Still strictly read-only. All of plan 035's guarantees hold unchanged"*, by way
of 035's *"**Fails closed.** A repo whose `git status` cannot be read is
reported `unknown` with the error, never 'clean'."*

**Why the plan's own test does not catch it.** Task 7(c) reads: *"a worker that
produces no output yields an `unknown` row rather than a missing one."* The
cheapest fixture satisfying that wording — and the way it naturally reads — is a
worker that **succeeds while printing nothing** (exit 0, empty file). That
passes against the broken implementation, because exit 0 never trips `set -e`.
The test only fails if the fixture worker exits **non-zero**, which the task
text does not require. The determinism check (`--jobs 1` vs `--jobs 8`) does not
catch it either: both paths behave identically on a healthy fixture set, and
neither is ever exercised with a failing probe.

**Concrete fix** — make all three explicit in the plan rather than leaving them
to discovery:

1. Guard the pool invocation so a worker's status cannot kill the parent:

       set +e
       printf '%s\n' "${paths[@]}" | xargs -P "$jobs" -I{} "$CCTRL_SELF" repo _probe {}
       set -e
       # or: ... | xargs ... || true   — note pipefail: the guard must cover the
       # whole pipeline, not just the last command.

2. Require in Task 3 that `cctrl repo _probe` **always exits 0**, emitting a
   `verdict: "unknown"` object carrying `error` on any internal failure, and
   **never** exits 255 (which would abort the remaining input rather than
   degrading one row).

3. Restate Task 7(c) so the fixture worker **exits non-zero**, not merely
   silent:

       (c) a worker that exits non-zero, AND a worker that exits 0 with no
           output, each yield an `unknown` row — and the scan still reports
           every other repo in the scope.

### MUST DECIDE: does `--root` add to, or replace, the default session scope?

The Acceptance Criteria say `--root DIR` "**adds** every git repository that is
a depth-1 child of `DIR`", and separately that "Default scope stays
sessions-only". So does `cctrl repo status --root <tree>` return that tree's
repos, or that tree's repos **plus** every live session's repo? The two readings
give different output for the primary invocation in this plan's own `[manual]`
check.

Neither verification check disambiguates: both use `--root "$FIXTURES"` in a
test environment where the session set is empty, so both readings pass. The same
ambiguity applies to `CCTRL_REPO_ROOTS`, which the AC calls "default roots" but
then only reaches via `--all`.

Fix: state the chosen semantics in the AC for both, and add a test with a
**non-empty** fake session set that asserts the resulting row count.

### Non-blocking notes

- **The 5s performance gate will flake.** It would be the only wall-clock
  assertion in `tests/run-tests.sh` (verified: there are none today); building
  ≥50 fixture repos costs real time before the gate even starts; and this
  machine routinely runs 25 concurrent agent sessions. Recommend warn-only, or
  gate it behind an env var (`CCTRL_TEST_PERF=1`). Keep the `--jobs 1` vs
  `--jobs 8` determinism diff as the hard gate — that one is excellent and is
  the genuinely load-bearing check for this plan.
- **The "I/O-bound" rationale is wrong.** The plan states "0.18s user against
  13s wall serial". Measured over the same 58 repos, `-P 8` burns **7.00s user /
  1.47s sys at 695% CPU** — the plan measured only the driving shell's own user
  time, not its children's. The conclusion (parallelism buys ~7×) is unaffected,
  but do not let that number survive into a source comment.
- **`_shortcut_list` does not expose a dir extractor.** The plan says to read
  shortcuts "exactly as `_shortcut_list` does: `jq -r 'to_entries[] |
  .value.dir'`". `_shortcut_list` is a human renderer whose jq is
  `to_entries[] | .key, (.value.dir // ""), …`. The plan's expression is correct
  against the *file*, but this is new code, not reuse — the citation misleads.
  Also: shortcut dirs carry trailing slashes (`/…/cctrl/`); `rev-parse
  --show-toplevel` normalizes them, so dedup is safe.
- **`--jobs 1` as a separate in-process path** doubles the code that must stay
  byte-identical to the parallel path. `xargs -P 1` through the same path would
  make the determinism test tautological but eliminate the drift risk. Either is
  defensible; the current choice is the more testable one.

### Kept as-is

`PIPE_BUF`-driven per-worker temp files, parent-side ordering, binary re-entry
over a second `lib/` file, depth-1 `--root`, refusing a `data/repo-roots.json`,
refusing to auto-promote a non-repo shortcut into a root, refusing a cache, and
refusing `--fetch` at 58 repos. All checked; all correct.

### Author response — 2026-07-28 (revised, awaiting re-review)

- **BLOCKER — accepted in full and fixed.** The `set -euo pipefail` × `xargs`
  interaction is real and would have voided the fail-closed guarantee entirely.
  A new Design section states the failure mode, reproduces it, and mandates
  three defenses: a `set +e` guard spanning the whole pipeline (`pipefail`),
  `_probe` always exiting 0 and never 255, and the collection-step fallback
  (now genuinely reachable). The review's point that the *test wording* was the
  root cause is the sharper half: Task 7(c) and a new Verification check now
  require a fixture worker that **exits non-zero**, since an exit-0-and-silent
  fixture passes against the broken implementation.
- **MUST DECIDE — decided: scope flags REPLACE the session default.** `--all` is
  the explicit union. Rationale in the AC. Also made explicit that the
  session→repo join is orthogonal to scope and always runs, and that
  `CCTRL_REPO_ROOTS` never silently redefines the default scope. Scope
  composition is now tested with a **non-empty** fake session set.
- **Perf gate — now opt-in behind `CCTRL_TEST_PERF=1`.** Agreed it would be the
  only wall-clock assertion in the suite and would flake on a box running ~25
  concurrent sessions. The `--jobs 1` vs `--jobs 8` determinism diff stays the
  hard gate.
- **"I/O-bound" claim — corrected.** The plan now carries the real numbers
  (7.00s user / 1.47s sys at 695% CPU) and an explicit instruction not to let
  the wrong figure reach a source comment. Timing table shows both runs.
- **`_shortcut_list` citation — corrected** to "this is new code, not reuse",
  with the actual jq expression against the file and the trailing-slash note.
- **`--jobs 1` as a separate path — kept**, per the review's own framing that it
  is the more testable of the two defensible options.
- **New (author, not from review): depth-1 has a live cost.** A session is
  currently working in `~/dev/repo-audits/natively-cluely-audit` — depth 2 — so
  `--root ~/dev` provably does not cover the fleet. Documented as the argument
  for `--all` and the `SRC` column, not as an argument for recursion.

## Eng re-review — 2026-07-28 · author response 2026-07-29

Re-review verdict: **CHANGES REQUESTED** (S1–S3 blockers, S4–S6 major, S7–S9
minor). All accepted; every claim independently re-verified on this machine
before editing (2026-07-29) rather than taken on faith. Results:

| # | Claim | Re-verified | Outcome |
|---|---|---|---|
| S1 | empty array aborts under `set -u`; `set +e` does not suppress | `a[@]: unbound variable` both ways; guarded form reaches | **fixed** |
| S2 | signals abort input identically; defense 2 cannot close it | accepted (SIGKILL/SIGPIPE bypass exit-code discipline by construction) | **fixed** |
| S3 | mandated snippet had no redirection, no `<n>` source, undefined `CCTRL_SELF` | `grep CCTRL_SELF cctrl` → 0 matches | **fixed** |
| S4 | "status 123 for 1–125" is GNU, not BSD | exits 1/42/125/255 all → `rc=1` | **corrected** |
| S5 | `\|\| true` binds to the whole pipeline; `set +e` leaks | `REACHED-COLLECTION`; `LEAKED-ERREXIT-IS-OFF` | **corrected** |
| S6 | exit-1 fixture still passes against a broken impl | accepted | **test rewritten** |
| S7/S8 | `-I` 254-byte limit; BSD xargs parses quotes | accepted | **fixed via `-0 -n 1`** |
| S9 | overrides must be exported for the subprocess | accepted | **fixed** |

**S4 and S5 were corrections to claims I introduced in the previous revision**,
not to the original draft — the reviewer caught me codifying a false rule
(`set +e` over `|| true`) in a plan that explicitly instructs its prose to reach
source comments. Both are now stated as corrections, with the measurement, so a
future editor cannot quietly restore them.

The structural point I had wrong: I presented three defenses as belt-and-braces
when in fact **only defense 3 closes the hole**. Defenses 1 and 2 are hygiene.
The plan now says so plainly and makes defense 3's two load-bearing details
mandatory — iterate the scope's input path list (never a temp-dir glob), and
assert `row-count == scope-count` — because BSD's exit status cannot distinguish
failure from truncation.

S7/S8 collapsed into one change: `-0 -n 1` instead of `-I{}`, which removes the
replstr limit rather than leaving headroom under it.
