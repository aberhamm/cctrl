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
reviews:
  - type=eng verdict=changes-requested date=2026-07-28 by=mstack-review
---

## Requirements

The fleet manager cannot currently answer *"does any repo my fleet is working in
have uncommitted or unpushed changes?"* without shelling out a `git status` loop
by hand. Four incidents in one week:

1. **Unattributable changes.** Multiple sessions share one working tree — three
   live in `~/dev/cctrl`, six in `~/dev/homelab`, ten in `~/dev/obsidian-vault`
   (re-verified from `cctrl session ls`, 2026-07-28; 25 live sessions resolve to
   6 distinct git toplevels plus one non-repo). A mixed dirty tree could not
   be attributed to a session, because plain `git status` knows nothing about
   sessions. **This join is the feature's actual value-add**; the git half is
   commodity.
2. **Content that must never be auto-committed.** `~/dev/matthew-aberham-resume`
   carries 89 dirty entries including unreviewed `.tex` content. Any tool that
   sweeps repos and "helpfully" stages or commits is actively dangerous. The
   command **informs; it never fixes**.
3. **Silent drift.** Untracked plan files sat unnoticed in three repos for days;
   unpushed commits accumulated with nobody aware. Still true on 2026-07-28:
   `benedikt-thesis-audit` has 3 commits on a branch with no remote at all, and
   `next-chat-umbrella-app` has two such branches carrying 1 each.
4. **Cost of asking.** Because the answer required a manual loop, it was asked
   rarely. It must be cheap enough to run habitually.

This plan ships the command over the scope that matters most and costs least:
**the distinct git repositories that live cctrl sessions are working in**
(~12 repos today). Broad scopes (`--root`, `--shortcuts`, `--all`) and parallel
fan-out are plan 036; teaching the fleet-manager role to use it is plan 037.

**Acceptance criteria:**

- [ ] `cctrl repo status` exists as a new top-level command, dispatched from
      `_dispatch`, with `repos` as an alias and a bare `cctrl repo` defaulting
      to `status` (mirroring `cmd_session`'s `local action="${1:-ls}"`).
- [ ] Default scope = the distinct `git rev-parse --show-toplevel` of every live
      session's `dir` from `_session_list --json`. A session dir that is not in a
      git repo (`~/dev/obsidian-vault` today — verified not a repo, yet home to
      **10** live sessions) is reported as its own row with `vcs: null`, never
      silently dropped: 10 sessions producing unversioned work is a finding, not
      a non-event.
- [ ] `--here` scopes the scan to the caller's own repo — one row, still carrying
      the full session list for that repo, with the calling session marked. This
      is the form `cctrl-session-end` uses (plan 037); a closing session asking
      "is *my* work uncommitted?" must not have to read a fleet-wide table.
- [ ] Per repo it reports: absolute path, basename, current branch (and whether
      HEAD is detached), staged / unstaged / untracked counts, an advisory
      untracked-artifact count, stash count, per-branch unpushed commit counts
      (**every** local branch, not just HEAD), and
      **the live sessions whose cwd resolves into that repo** (name, purpose,
      state, agent).
- [ ] A local branch with **no upstream at all** reports a real commit count, not
      `null`. A never-pushed branch *is* founding incident #3; reporting it as
      unknown loses exactly the signal the plan exists to surface.
- [ ] Human table by default; `--json` emits a JSON array following the
      `_session_list --json` conventions: built with `jq -n --arg/--argjson`,
      empty strings normalized to `null`, `[]` when the scope is empty,
      deterministic ordering.
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
- [ ] `cctrl repo --help` and a new `Repos` block in `cmd_help` document it.
- [ ] Covered by `tests/run-tests.sh` in the style of `test_needs_me_digest`:
      fake tmux + real temporary git repos.

**Citation convention for this plan and its siblings:** refer to cctrl internals
by **function name, never by line number**. The original draft's line citations
were already stale two days later — a single unrelated commit (`f7db9ab`) shifted
`cctrl` by 13 lines, moving `_dispatch` 7963→7976, `cmd_help` 6267→6280,
`_session_list` 5108→5121, `_target_slug` 607→612. Function names are stable;
line numbers are a trap for an autonomous implementer.

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

*Namespace note:* `_dispatch` tries its builtin arms before falling through to
`_try_plugin`, so adding `repo` shadows any user plugin named `cctrl-repo`.
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
already does), and group sessions by the resulting toplevel. A `dir` that
resolves to nothing becomes a `vcs: null` row keyed on the dir itself.
Degrade to an empty scope rather than failing when tmux is unavailable, exactly
as `cmd_needs_me` does.

`_repo_discover_json` must take its scope as arguments so plan 036 can add
`--shortcuts` / `--root` / `--all` by extending the source set and the `sources`
array, without touching the probe or the renderer. **Build the seam; do not
build the flags.**

**`--here` is the second scope source this plan ships**, and it exercises the
seam rather than bypassing it: resolve `git -C "$PWD" rev-parse --show-toplevel`,
scope to that single repo, and still run the full session join so the row lists
every sibling session in that tree. Two details make it worth its ~5 lines:

- The calling session is **marked** in the session list (`← you`), resolved from
  `CCTRL_SESSION_NAME` / `_session_current_name`. Knowing three siblings share
  the tree is the fact that makes "stage explicit paths, never `git add .`"
  land; knowing which one is *you* is what makes it actionable.
- Outside a repo, `--here` reports the `not-a-repo` row for `$PWD` — the same
  fail-visible shape as any other scope, not an error. A session in
  `~/dev/obsidian-vault` running it before close must be told its work is
  unversioned, which is precisely when that matters most.

`--here` is mutually exclusive with plan 036's scope flags; combining them is a
usage error, not a union.

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
    {"branch": "main", "upstream": "origin/main", "ahead": 2, "basis": "upstream"},
    {"branch": "wip",  "upstream": null,          "ahead": 3, "basis": "no-upstream"}
  ],
  "ahead_total": 5,
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
- **`ahead` is never `null`, including for a branch with no upstream.** For an
  upstream-tracking branch it is `rev-list --count "$up..$b"` (`basis:
  "upstream"`). For a branch with no upstream it is
  `git rev-list --count "$b" --not --remotes` (`basis: "no-upstream"`) — the
  commits that exist on no remote at all. Both are read-only, both stay
  local-refs-only, both cost nothing.
  `basis` exists so a reader can tell the two kinds of count apart: `ahead: 3`
  against an upstream means "pushed somewhere, 3 newer here"; against
  `no-upstream` it means "this branch has never been pushed anywhere". Rolling
  them into one number without the discriminator would be worse than the `null`
  it replaces.
  `ahead_total` sums both kinds — a never-pushed branch is unpushed work, and a
  total that silently excludes it is the false all-clear this plan exists to
  prevent. (Live example on 2026-07-28: `benedikt-thesis-audit` `main` carries 3
  commits and has no remote; the original `null` design reported that repo's
  `ahead_total` as `0`.)
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
obsidian-vault           -        -        -   -     10     not-a-repo
homelab                  main     0/0/0    0   0      6     clean
```

- One row per repo; the indented session lines print **only for repos whose
  verdict is not `clean`** (and for `not-a-repo`), so the table stays glanceable
  while attribution is right where the problem is. Under `--here` the session
  lines always print — that row *is* the output — and the calling session is
  marked `← you`.
- `S/U/?` is staged/unstaged/untracked. `-` for non-repos.
- Colors follow existing conventions (`RED`/`YELLOW`/`DIM`). Reuse the `✦`
  managed marker from `_session_list`.
- Footer: `N repos · M need attention · K clean` and, when any repo is
  `unknown`, a loud line naming them.

### Flags (this plan)

```
cctrl repo status [--json] [--files] [--attention-only] [--here] [-h|--help]
```

`--attention-only` omits `clean` repos. It is deliberately **not** named
`--dirty-only`: it retains `unpushed`, `unknown`, and `not-a-repo` rows, so
"dirty" would misdescribe it — and plan 036 makes it the habitual pairing for
the wide scope, which is exactly where a lying flag name does the most damage.
The name also matches the footer's own wording ("N need attention").

`--files` adds the capped sample paths. Flags are parsed with the same simple
`for a in "$@"` loop used by `_session_list` and `cmd_needs_me`.

**Files expected to change:**

- `cctrl`: new `_repo_*` function block (place it near `cmd_needs_me`, the
  closest analogue: a read-only aggregate that consumes `_session_list --json`);
  `cmd_repo` dispatcher with `-h/--help`; `repo|repos` arm in `_dispatch`;
  a `Repos` block in `cmd_help`.
- `tests/run-tests.sh`: `test_repo_status` (+ registration alongside the other
  `test_*` calls at the foot of the file).
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
  design, and the global `--host` flag makes `cctrl --host <alias> repo status`
  work for free. Do **not** build a `fleet`-style SSH aggregator here.
- Special-casing plan files, `docs/plans/`, or any mstack concept. cctrl is
  generic; `untracked` + `--files` covers that incident without coupling.

## Tasks

1. Add the `_repo_*` block with a header comment citing `wrapup-scan.sh` as
   prior art and stating the divergence (packaging boundary + narrowed artifact
   list).
2. Implement `_repo_probe_json <path>`: NUL-safe porcelain parse with `R`/`C`
   two-token handling, artifact basename match on untracked only, stash count,
   branch/detached, per-branch ahead with `basis` (`upstream` via
   `rev-list --count "$up..$b"`, `no-upstream` via
   `rev-list --count "$b" --not --remotes`), verdict, fail-closed `unknown` +
   `error`. No shared state — it must be safe to run as a subprocess.

   **`set -e` hazard, read this before writing the fail-closed paths.** `cctrl`
   runs `set -euo pipefail`. `local x="$(git …)"` **masks** a non-zero exit
   status (the `local` builtin's own status wins), while bare `x="$(git …)"`
   propagates it and will kill the function. Fail-closed correctness here depends
   entirely on getting that distinction right: declare `local` first, assign on a
   separate line, and check `$?` explicitly — or guard with `|| return`.
3. Implement `_repo_discover_json`: read `_session_list --json` once, resolve
   toplevels, group sessions per repo, emit `not-a-repo` rows for unresolvable
   dirs, degrade to `[]` when tmux is absent. Take the scope as arguments.
4. Implement `_repo_render_human` and the `--json` path; sort attention-first →
   session count desc → name.
5. Add `cmd_repo` with `status` (default), `-h|--help`; wire `repo|repos` into
   `_dispatch`; add the `Repos` block to `cmd_help`.
6. Add `--files` (capped at 5 per list, `truncated` flag) and `--attention-only`.
7. Add `--here`: resolve `$PWD`'s toplevel, scope to it, run the full session
   join, mark the calling session `← you`, and report `not-a-repo` when `$PWD`
   is outside a repo. Reject `--here` combined with any other scope flag.
8. Write `test_repo_status` in `tests/run-tests.sh`: build four real temp git
   repos (clean / dirty-with-untracked / ahead-of-a-local-bare-remote /
   commits-on-a-branch-with-no-remote), plus a non-repo dir; assert the JSON
   shape, the session join, the fail-closed path, and read-only invariance.

   **The fake tmux needs a real extension, not a copy.** `test_needs_me_digest`'s
   fake answers `list-panes … pane_current_path` with one hardcoded
   `echo /tmp/demo` for every session; this plan needs a **per-session dir
   mapping**, since the entire session→repo join is what is under test. The `-t`
   target extraction already exists in that fake, so the change is small — but
   budget for it rather than assuming "in the style of" is free.
9. Update `CHANGELOG.md` and `README.md`.

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
- `[assert]` **static mutation guard** — the `_repo_*` source block, **with
  comment lines stripped first**, contains no occurrence of
  `git .*\b(add|commit|stash push|stash save|checkout|switch|reset|fetch|pull|push|clean|restore|rm|mv)\b`:

      sed 's/#.*//' <block> | grep -Eq 'git .*\b(add|commit|…)\b' && fail

  **Stripping comments is mandatory, not incidental.** Task 1 requires a header
  comment naming `wrapup-scan.sh` as prior art, and the natural read-only
  disclaimer — "never runs `git add`, `git commit`, `git fetch`, or `git push`"
  — matches this regex verbatim. Without the strip, the plan's own guard rejects
  the plan's own mandated comment, and the implementer's likely "fix" is to
  delete the comment. Guard the code, not the prose.
- `[assert]` a repo with an unreadable `.git` yields `verdict: unknown` and a
  non-null `error`, and the string `clean` does not appear for it (fail closed).
- `[assert]` a session dir that is not a git repo yields one row with
  `vcs: null` and `verdict: "not-a-repo"`, carrying its sessions.
- `[assert]` a repo containing a commit on a **non-HEAD** local branch that is
  ahead of its upstream is reported in `unpushed` (guards the side-branch
  false-all-clear that wrapup-scan.sh's per-branch loop exists to prevent).
- `[assert]` a repo whose only commits sit on a branch with **no upstream and no
  remote** reports `ahead > 0`, `basis: "no-upstream"`, and a non-zero
  `ahead_total` — never `ahead: null` and never `ahead_total: 0`. This is
  founding incident #3's regression test.
- `[assert]` `cctrl repo status --here` run inside a fixture repo returns exactly
  one row whose `path` is that repo's toplevel, carrying every session in that
  tree; run outside a repo it returns one `not-a-repo` row and exits 0.
- `[assert]` `--here` combined with a plan-036 scope flag exits non-zero with a
  usage message.
- `[manual]` Run against the live fleet: `~/dev/matthew-aberham-resume` (89
  dirty entries as of 2026-07-28) is reported and untouched; `~/dev/obsidian-vault`
  shows as not-a-repo with its 10 sessions attributed.

## Eng review — 2026-07-28

Reviewed by an independent session (not the author), at the fleet manager's
request. Verdict: **changes-requested** — approve once the two edits below land.
Both are small. The plan is otherwise sound and unusually well-argued.

Scores: clarity 9 · testability 9 · scope-fit 8 · autonomy 9 · trap-resistance 8
→ composite **8.7/10**.

Verified against the working tree on 2026-07-28: bash 3.2.57; `_dispatch` tries
builtins before `_try_plugin`, so the `cctrl-repo` plugin shadowing this plan
calls out is real; `~/dev/obsidian-vault` is not a git repo and now holds **10**
live sessions (plan said 8); 25 live sessions resolve to 6 distinct toplevels
plus that one non-repo. `~/dev/matthew-aberham-resume` now carries **89** dirty
entries (plan said 71) — the incident is if anything stronger than written.

### Edit 1 (required): the static mutation guard contradicts the mandated header comment

Task 1 requires a header comment naming `wrapup-scan.sh` as prior art and
stating the divergence. Verification asserts the `_repo_*` block contains no
match for:

    git .*\b(add|commit|stash push|stash save|checkout|switch|reset|fetch|pull|push|clean|restore|rm|mv)\b

The natural header comment — "read-only: never runs `git add`, `git commit`,
`git fetch`, or `git push`" — **matches that regex and fails the plan's own
guard**. So does any prose in the block naming a mutating verb after the word
`git`.

Fix: specify that the guard strips comment lines before matching, e.g.

    sed 's/#.*//' <block> | grep -Eq 'git .*\b(add|commit|...)\b' && fail

State this in the Verification bullet, so the implementer does not rediscover it
the hard way and then "fix" it by deleting the comment Task 1 requires.

### Edit 2 (recommended): no-upstream branches make founding incident #3 invisible

The pinned contract reports a branch with no upstream as
`{"branch":"wip","upstream":null,"ahead":null}`, and `ahead_total` excludes it.
But a local branch that has **never been pushed** is exactly incident #3
("unpushed commits accumulated with nobody aware") — and the design reports its
count as unknown rather than as a number.

Real instances in this operator's tree on 2026-07-28:

    benedikt-thesis-audit    main                        3 commits on no remote
    next-chat-umbrella-app   feat/org-rate-limiting      1
    next-chat-umbrella-app   feat/seed-wine-collection   1

`git rev-list --count "$b" --not --remotes` gives the true count, stays
read-only, stays local-refs-only, and costs nothing. Recommend: make `ahead`
non-null for no-upstream branches and add a `basis` field
(`"upstream"` | `"no-upstream"`) so a reader can tell the two kinds of count
apart — rather than reporting `null` and losing the signal.

### Non-blocking notes

- **Line-number citations are already stale.** Commit `f7db9ab` alone added 13
  lines to `cctrl`. Actual as of 2026-07-28: `_dispatch` 7976 (cited 7963),
  `cmd_help` 6280 (6267), `_session_list` 5121 (5108), `_target_slug` 612 (607),
  colors 59-66 (60-67), `test_needs_me_digest` 1879 (1846), test registration
  3802 (3768). Cite function names, not line numbers.
- **The test fixture needs more than "in the style of `test_needs_me_digest`".**
  That fake tmux returns one hardcoded `pane_current_path` (`echo /tmp/demo`)
  for every session; this plan needs a per-session dir mapping. The `-t` target
  extraction is already present in the fake, so it is a small extension — but it
  is not free, and Task 7 reads as though it were.
- **`set -e` and command substitution.** `local x="$(git …)"` masks a failing
  exit status; bare `x="$(git …)"` trips `set -e`. Fail-closed correctness in
  `_repo_probe_json` depends on getting this distinction right.
- **`--dirty-only` is misnamed.** It is defined here as "omits clean repos", so
  it retains `unpushed` / `unknown` / `not-a-repo`. Plan 036 makes it the
  habitual pairing, where the name matters most. `--attention-only` matches this
  plan's own footer wording ("N need attention"). Taste, not a blocker.

### Kept as-is — do not "improve" these

The refusals are the strongest part of the plan and each was checked against the
codebase: no `--fetch`; no shared library with `wrapup-scan.sh`;
reimplement-and-cite; the narrowed artifact list; not folding into `session ls`;
and the session→repo join as the actual value-add rather than the git plumbing.

### Author response — 2026-07-28 (revised, awaiting re-review)

Both required/recommended edits applied, plus every non-blocking note.

- **Edit 1 (required) — applied.** The static mutation guard now strips comment
  lines (`sed 's/#.*//'`) before matching, and Verification says *why*, so the
  implementer does not "fix" the conflict by deleting the mandated header
  comment. Good catch: the guard as drafted rejected the comment the plan itself
  requires.
- **Edit 2 (recommended) — applied, and promoted to an acceptance criterion.**
  `ahead` is now never `null`; no-upstream branches count via
  `rev-list --count "$b" --not --remotes` and carry `basis: "no-upstream"` to
  distinguish the two kinds of count. `ahead_total` sums both. Re-verified the
  three live instances independently (`benedikt-thesis-audit` main ×3,
  `next-chat-umbrella-app` ×2 branches ×1) — the draft would have reported that
  repo's `ahead_total` as `0`, which is exactly incident #3.
- **Line numbers — removed everywhere**, and a stated citation convention added
  (function names only) so the next draft does not reintroduce them.
- **Test fixture — Task 8 now spells out** that the fake tmux needs a per-session
  dir mapping, since the session→repo join is the thing under test.
- **`set -e` masking — added to Task 2** as an explicit warning about
  `local x="$(…)"` vs bare assignment, since fail-closed correctness depends on it.
- **`--dirty-only` → `--attention-only`.** Agreed it was misnaming a flag that
  retains `unpushed`/`unknown`/`not-a-repo`; free to fix pre-implementation.
- **New: `--here`** (from plan 037's escalated scope question; Matthew chose
  Option A on 2026-07-28). One row, the caller's own repo, sibling sessions
  listed, caller marked `← you`. Specified here because it is a command
  behavior; 037 remains doctrine-only.

Nothing in the "Kept as-is" list was touched.
