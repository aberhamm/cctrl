---
id: 035
title: Add `cctrl repo status` — read-only repo state for the fleet's live working dirs
status: pending
blocked-by: []
priority: 35
goal: cctrl-fleet-repo-visibility
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-26
---

## Requirements

The fleet manager cannot currently answer *"does any repo my fleet is working in
have uncommitted or unpushed changes?"* without shelling out a `git status` loop
by hand. Four incidents in one week:

1. **Unattributable changes.** Multiple sessions share one working tree — three
   live in `~/dev/cctrl`, two in `~/dev/homelab`, eight in `~/dev/obsidian-vault`
   (verified from `cctrl session ls`, 2026-07-26). A mixed dirty tree could not
   be attributed to a session, because plain `git status` knows nothing about
   sessions. **This join is the feature's actual value-add**; the git half is
   commodity.
2. **Content that must never be auto-committed.** `~/dev/matthew-aberham-resume`
   carries 71 dirty entries including unreviewed `.tex` content. Any tool that
   sweeps repos and "helpfully" stages or commits is actively dangerous. The
   command **informs; it never fixes**.
3. **Silent drift.** Untracked plan files sat unnoticed in three repos for days;
   unpushed commits accumulated with nobody aware.
4. **Cost of asking.** Because the answer required a manual loop, it was asked
   rarely. It must be cheap enough to run habitually.

This plan ships the command over the scope that matters most and costs least:
**the distinct git repositories that live cctrl sessions are working in**
(~12 repos today). Broad scopes (`--root`, `--shortcuts`, `--all`) and parallel
fan-out are plan 036; teaching the fleet-manager role to use it is plan 037.

**Acceptance criteria:**

- [ ] `cctrl repo status` exists as a new top-level command, dispatched from
      `_dispatch` (`cctrl:7963-8007`), with `repos` as an alias and a bare
      `cctrl repo` defaulting to `status` (mirroring `cmd_session`'s
      `local action="${1:-ls}"`, `cctrl:4586`).
- [ ] Default scope = the distinct `git rev-parse --show-toplevel` of every live
      session's `dir` from `_session_list --json` (`cctrl:5108`). A session dir
      that is not in a git repo (`~/dev/obsidian-vault` today — verified not a
      repo, yet home to 8 live sessions) is reported as its own row with
      `vcs: null`, never silently dropped: 8 sessions producing unversioned work
      is a finding, not a non-event.
- [ ] Per repo it reports: absolute path, basename, current branch (and whether
      HEAD is detached), staged / unstaged / untracked counts, an advisory
      untracked-artifact count, stash count, per-branch unpushed commit counts
      (**every** local branch, not just HEAD), branches with no upstream, and
      **the live sessions whose cwd resolves into that repo** (name, purpose,
      state, agent).
- [ ] Human table by default; `--json` emits a JSON array following the
      `_session_list --json` conventions (`cctrl:5206-5217`): built with
      `jq -n --arg/--argjson`, empty strings normalized to `null`, `[]` when the
      scope is empty, deterministic ordering.
- [ ] **Read-only, enforced by test.** No code path in this subsystem may invoke
      a mutating git verb. There is no `--fetch` (see Design). A fixture repo's
      git state is byte-identical before and after a scan.
- [ ] **Fails closed.** A repo whose `git status` cannot be read is reported
      `unknown` with the error, never "clean". Adopted verbatim from
      wrapup-scan.sh's contract.
- [ ] Sorted attention-first (repos needing attention above clean ones), then by
      session count descending, then by name — stable and deterministic.
- [ ] Exits 0 whenever the scan ran, including when findings exist. Non-zero
      only for a usage error or a missing dependency (`git`, `jq`).
- [ ] `cctrl repo --help` and the `Session`/new `Repos` block in `cmd_help`
      (`cctrl:6267`) document it.
- [ ] Covered by `tests/run-tests.sh` in the style of `test_needs_me_digest`
      (`tests/run-tests.sh:1846`): fake tmux + real temporary git repos.

## Design

### Naming and placement: `cctrl repo status`

Three candidates were considered.

**Extending `cctrl session ls`** — rejected. `session ls` is the fleet's
most-used command and its row is *per session*; this data is *per repo*
(8 sessions → 1 row). Folding it in would either duplicate the same repo across
8 rows or change the row's identity. It would also tax every `session ls` with a
git sweep it usually doesn't need. Different cardinality, different subsystem,
different cost profile.

**`cctrl session repos`** — rejected. It nests the noun under `session`, but the
command must eventually cover repos with *no* session at all (plan 036's
`--root`/`--shortcuts`). Naming it after the wrong parent now guarantees a
rename later.

**`cctrl repo status` — chosen.** `repo` becomes a top-level noun-group
alongside `peer`, `host`, `session`, `fleet`, matching `_dispatch`'s existing
shape, and leaves room for later verbs (`repo ls`) without another rename.
`status` is the git-native word for exactly this question.

*Namespace note:* `_dispatch` tries builtins before `_try_plugin`
(`cctrl:7999`), so adding `repo` shadows any user plugin named `cctrl-repo`.
Call this out in the changelog entry; it is the price of claiming a top-level
noun and is acceptable — but do not also claim `git` or `status`.

### Relationship to `wrapup-scan.sh` — reimplement, cite, do not silently duplicate

`~/.config/skillshare/skills/mstack-run/scripts/wrapup-scan.sh` already answers
this question read-only for one repo. Three options were weighed:

- **Shell out to it per repo** — rejected. It lives inside the mstack skill tree
  at a `~/.config/skillshare/...` absolute path and `source`s a sibling
  `lib.sh` for `porcelain_paths` / `EXIT_SCAN_NOT_GIT`. cctrl is a public,
  standalone CLI; making a core command depend on an unrelated tool being
  installed at a path outside cctrl's tree is a hard no. Its output is also a
  bespoke line protocol that would need parsing back into JSON.
- **Extract a shared library** — rejected. It creates a cross-repo dependency in
  whichever direction it points, for ~120 lines of git plumbing with exactly two
  consumers whose output contracts differ (line protocol for a skill parser vs
  JSON for a CLI). The coupling costs more than the duplication.
- **Reimplement inside `cctrl`, adopting its rules explicitly — chosen.**

To make that reimplementation and not a silent fork, the implementer **must**:

1. Adopt these hard-won correctness rules as requirements, each already paid for
   in wrapup-scan.sh:
   - Parse `git status --porcelain -uall -z` NUL-safe with `read -r -d ''`.
     **Never awk** — it drops rename targets and mangles paths with spaces.
   - Handle `R`/`C` entries as two tokens (the original path follows bare, with
     no XY prefix) so renames are not miscounted as untracked.
   - Count unpushed for **every** local branch via
     `git for-each-ref --format='%(refname:short)%09%(upstream:short)' refs/heads`,
     not just HEAD — side-branch work must not produce a false all-clear.
   - A branch with no upstream is reported (`upstream: null`), never skipped.
   - Unreadable `git status` ⇒ fail closed, never "clean".
   - Branch-derived data is honestly marked as derived from local refs only.
   - Artifacts are matched on the **basename of untracked entries only**, and
     are advisory — a report line, never a deletion.
2. Leave a comment at the head of the repo subsystem naming
   `wrapup-scan.sh` as prior art and stating the divergence reason, so a future
   reader does not "discover" the duplication and unify them badly.
3. Deliberately **narrow** the artifact pattern list. wrapup-scan.sh uses
   `*.tmp *.bak *.orig test-* debug-* *.log`; `test-*`/`debug-*` are too
   aggressive for a repo-wide sweep across arbitrary projects (they hit
   legitimate `test-utils/`, `debug-server.ts`). cctrl's list is
   `*.tmp *.bak *.orig *.rej *.log .DS_Store`. State the divergence in the
   comment; within cctrl, cctrl's list is authoritative.

### Discovery (this plan: sessions only, but build the seam)

```
_repo_discover_json  →  [{path, sources:["session"], sessions:[…]}, …]
```

Read `_session_list --json` once. For each entry take `.dir`, resolve
`git -C "$dir" rev-parse --show-toplevel` (the same resolution `_target_slug`
already does at `cctrl:607`), and group sessions by the resulting toplevel. A
`dir` that resolves to nothing becomes a `vcs: null` row keyed on the dir itself.
Degrade to an empty scope rather than failing when tmux is unavailable, exactly
as `cmd_needs_me` does (`cctrl:7096-7100`).

`_repo_discover_json` must take its scope as arguments so plan 036 can add
`--shortcuts` / `--root` / `--all` by extending the source set and the `sources`
array, without touching the probe or the renderer. **Build the seam; do not
build the flags.**

*Worktrees:* `--show-toplevel` inside a `git worktree` returns the worktree path,
so an agent worktree under `.claude/worktrees/` correctly appears as its own row
rather than merging into the parent. That is the desired behavior — worktree
dirt is separately attributable — but note it so it is not later "fixed".

### Per-repo probe

One function, `_repo_probe_json <path>`, emitting one JSON object. Keep it a
standalone function taking a path and returning JSON on stdout: plan 036 will
drive it from `xargs -P`, and that only works if it has no shared mutable state.

Pinned JSON object (this contract is depended on by 036 and 037; extend
additively, never repurpose a key):

```json
{
  "path": "/Users/matthew/dev/cctrl",
  "name": "cctrl",
  "vcs": "git",
  "branch": "main",
  "detached": false,
  "staged": 0,
  "unstaged": 1,
  "untracked": 2,
  "dirty": 3,
  "artifacts": 1,
  "stashes": 1,
  "unpushed": [
    {"branch": "main", "upstream": "origin/main", "ahead": 2},
    {"branch": "wip",  "upstream": null,          "ahead": null}
  ],
  "ahead_total": 2,
  "no_upstream": 1,
  "refs_scope": "local-refs-only",
  "sources": ["session"],
  "sessions": [
    {"name": "TMUX--ms--cctrl", "purpose": "…", "state": "working", "agent": "claude"}
  ],
  "verdict": "dirty",
  "error": null,
  "files": null
}
```

- `dirty` = `staged + unstaged + untracked` (the glanceable number);
  the three components are also reported because they mean different things —
  the untracked-plans incident is an `untracked > 0` story, the resume incident
  an `unstaged > 0` story.
- `artifacts` ⊆ `untracked`; advisory only.
- `verdict` ∈ `clean | dirty | unpushed | dirty+unpushed | not-a-repo | unknown`.
  `unknown` is the fail-closed value and carries `error`.
- `refs_scope` is always the literal `"local-refs-only"`. It exists so no reader
  can mistake `ahead_total: 0` for "pushed" (see below).
- `files` is `null` unless `--files`, then an object
  `{"changed": [...], "untracked": [...], "truncated": <bool>}` capped at 5
  entries each. It exists for the untracked-plans case: seeing *which* files
  is what turns a count into a decision.

### Read-only: no `--fetch`, deliberately

**There is no `--fetch`, and adding one is out of scope for the whole goal.**

1. `git fetch` **mutates the repository** — it rewrites remote-tracking refs,
   `FETCH_HEAD`, and the object store. That breaks the one property that makes
   this command safe to run habitually, safe to hand to an agent, and safe to
   point at the resume repo.
2. It destroys the performance budget. Network round-trips × N repos turns a
   sub-second command into a tens-of-seconds command, and a command that is slow
   is a command that is not run — the exact failure this feature exists to fix.
3. **Under livesync + multi-machine git it would give false precision, not
   truth.** The Studio and the MacBook share working files; either machine may
   have already pushed. Fetching would make the numbers *look* authoritative
   while a third mutation lands a second later.

Instead the command is **honest about what it knows**: `refs_scope:
"local-refs-only"`, and a legend line on the human output. The residual error is
in the safe direction — a stale remote-tracking ref makes `ahead` *over*-report
(work already pushed from the other machine still shows as ahead). For a tool
whose job is to inform, a false "look at this" beats a false "all clear".

Two related hazards to surface rather than paper over:

- **Livesync can switch a branch mid-session.** `branch` is therefore a
  first-class reported column, not a detail: an unexpected branch *is* the
  finding. The scan is a snapshot, never a lock — say so in `--help`.
- The command must not be read as "safe to commit from". It reports; disposition
  stays with the human or the owning session (plan 037 makes that doctrine).

### Human output

```
↑ = local refs only (no fetch) · read-only: nothing is ever modified
REPO                     BRANCH   S/U/?    ↑   STASH  SESS  STATE
cctrl                    main     0/1/2    2   1      3     dirty+unpushed
    ✦ TMUX--ms--cctrl--2   working   fleet-manager
    ✦ TMUX--ms--cctrl--3   idle-done backlog runner
    ✦ TMUX--ms--cctrl--4   working   plan repo-status command
obsidian-vault           -        -        -   -      8     not-a-repo
homelab                  main     0/0/0    0   0      3     clean
```

- One row per repo; the indented session lines print **only for repos whose
  verdict is not `clean`** (and for `not-a-repo`), so the table stays glanceable
  while attribution is right where the problem is.
- `S/U/?` is staged/unstaged/untracked. `-` for non-repos.
- Colors follow existing conventions (`RED`/`YELLOW`/`DIM`, `cctrl:60-67`).
  Reuse the `✦` managed marker from `_session_list` (`cctrl:5219`).
- Footer: `N repos · M need attention · K clean` and, when any repo is
  `unknown`, a loud line naming them.

### Flags (this plan)

```
cctrl repo status [--json] [--files] [--dirty-only] [-h|--help]
```

`--dirty-only` omits clean repos. `--files` adds the capped sample paths.
Parsed with the same simple `for a in "$@"` loop used by `_session_list`
(`cctrl:5110-5116`) and `cmd_needs_me` (`cctrl:7075`).

**Files expected to change:**

- `cctrl`: new `_repo_*` function block (place it near `cmd_needs_me`, the
  closest analogue: a read-only aggregate that consumes `_session_list --json`);
  `cmd_repo` dispatcher with `-h/--help`; `repo|repos` arm in `_dispatch`
  (`cctrl:7976-7997`); a `Repos` block in `cmd_help`.
- `tests/run-tests.sh`: `test_repo_status` (+ registration near line 3768).
- `CHANGELOG.md`: entry noting the new command **and** the `cctrl-repo` plugin
  shadowing.
- `README.md`: command reference entry.

**Out of scope:**

- `--root` / `--shortcuts` / `--all` broad scopes and parallelism → **plan 036**.
  Do not pre-build them; do build `_repo_discover_json`'s scope seam.
- Fleet-manager doctrine, README/skill wiring → **plan 037**.
- Any `--fetch`, `--fix`, `--commit`, `--stash`, or interactive disposition.
  Permanently out of scope for this goal.
- Multi-host aggregation. It already works: `repo status` is local-only by
  design, and the global `--host` flag (`cctrl:7943-7957`) makes
  `cctrl --host mbp repo status` work for free. Do **not** build a `fleet`-style
  SSH aggregator here.
- Special-casing plan files, `docs/plans/`, or any mstack concept. cctrl is
  generic; `untracked` + `--files` covers that incident without coupling.

## Tasks

1. Add the `_repo_*` block with a header comment citing `wrapup-scan.sh` as
   prior art and stating the divergence (packaging boundary + narrowed artifact
   list).
2. Implement `_repo_probe_json <path>`: NUL-safe porcelain parse with `R`/`C`
   two-token handling, artifact basename match on untracked only, stash count,
   branch/detached, per-branch ahead + `upstream: null`, verdict, fail-closed
   `unknown` + `error`. No shared state — it must be safe to run as a subprocess.
3. Implement `_repo_discover_json`: read `_session_list --json` once, resolve
   toplevels, group sessions per repo, emit `not-a-repo` rows for unresolvable
   dirs, degrade to `[]` when tmux is absent. Take the scope as arguments.
4. Implement `_repo_render_human` and the `--json` path; sort attention-first →
   session count desc → name.
5. Add `cmd_repo` with `status` (default), `-h|--help`; wire `repo|repos` into
   `_dispatch`; add the `Repos` block to `cmd_help`.
6. Add `--files` (capped at 5 per list, `truncated` flag) and `--dirty-only`.
7. Write `test_repo_status` in `tests/run-tests.sh`: build three real temp git
   repos (clean / dirty-with-untracked / ahead-of-a-local-bare-remote), plus a
   non-repo dir; fake tmux maps session names to those dirs; assert the JSON
   shape, the session join, the fail-closed path, and read-only invariance.
8. Update `CHANGELOG.md` and `README.md`.

## Verification

- `[cmd]` `bash -n cctrl`
- `[cmd]` `shellcheck -S error cctrl` *(skip if shellcheck is absent; do not
  add it as a hard dependency)*
- `[cmd]` `tests/run-tests.sh`
- `[assert]` `cctrl repo status --json | jq -e 'type=="array"'` prints `true`
- `[assert]` `cctrl repo status --help` output contains `read-only`
- `[assert]` `cctrl repo status --json | jq -e 'all(.[]; has("verdict") and has("sessions") and .refs_scope=="local-refs-only")'`
  prints `true`
- `[assert]` **read-only invariance** — in the test fixture, capture
  `git status --porcelain -uall`, `git stash list`, `git for-each-ref`, and the
  existence of `.git/FETCH_HEAD` before and after `cctrl repo status`; assert
  every one is identical. This is the acceptance test for "informs, never fixes".
- `[assert]` **static mutation guard** — the `_repo_*` source block contains no
  occurrence of `git .*\b(add|commit|stash push|stash save|checkout|switch|reset|fetch|pull|push|clean|restore|rm|mv)\b`.
  A cheap regression net that survives future edits by other agents.
- `[assert]` a repo with an unreadable `.git` yields `verdict: unknown` and a
  non-null `error`, and the string `clean` does not appear for it (fail closed).
- `[assert]` a session dir that is not a git repo yields one row with
  `vcs: null` and `verdict: "not-a-repo"`, carrying its sessions.
- `[assert]` a repo containing a commit on a **non-HEAD** local branch that is
  ahead of its upstream is reported in `unpushed` (guards the side-branch
  false-all-clear that wrapup-scan.sh's per-branch loop exists to prevent).
- `[manual]` Run against the live fleet: `~/dev/matthew-aberham-resume` (71
  dirty entries) is reported and untouched; `~/dev/obsidian-vault` shows as
  not-a-repo with its 8 sessions attributed.
