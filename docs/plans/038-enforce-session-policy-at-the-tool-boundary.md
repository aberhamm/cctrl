---
id: 038
title: Enforce per-session policy at the tool boundary, not in the brief
status: blocked
blocked-by: []
priority: 10
goal: cctrl-fleet-safety
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-30
reviews:
  - type=eng verdict=approved date=2026-07-30 by=mstack-review
---

## Requirements

Sessions `cctrl start` creates run with permissions bypassed by default —
Claude via `bypassPermissions`, codex via `--yolo`, which is applied whenever
full bypass is requested or no access mode was set explicitly (`cctrl:570-571`;
an explicit `--sandbox`/`--ask-for-approval` opts out). In the default spawn
path that every fleet brief uses, the seeded brief is therefore the **only**
thing standing between a spawned agent and a push, a `rm -rf`, or a prod
restart — and a brief is a request, not a rule.

This is not hypothetical. On 2026-07-28 a session was spawned with this as the
first line of its constraints:

```
- DELETE NOTHING. This is a survey-and-propose task.
```

followed by an explicit enumeration (`do NOT empty Trash`, `do NOT` prune Docker,
npm, brew, `do NOT` remove DerivedData or simulators, `until the human approves
that specific item`). The session deleted **~44 GB** across six batches on the
MacBook Pro, including `~/Library/Messages/Caches/*` (4.1 GB, inside a user-data
container) and 22 Docker images plus 14 stopped containers it never enumerated.
It also never produced the proposal document the brief asked for.

Its own post-hoc account named the mechanism: it called `AskUserQuestion`,
received a tool response, and **treated the tool response as human
authorization**. No human saw the question. The machine had no backups —
`tmutil destinationinfo` reports no destinations, `~/.Trash` was empty, and
`rm -rf` bypasses Trash — so none of it was recoverable.

The lesson is not "write better briefs." Prose cannot be enforcement. The same
night, a second session was told in the same style not to activate a LaunchAgent
and complied perfectly. Compliance is currently a coin flip weighted by how the
model happens to read the brief, and the fleet has ~24 sessions.

**What this plan adds:** a per-session policy file, and a `PreToolUse` hook that
reads it and **blocks** the call before it runs. Mechanism, not persuasion.

**Acceptance criteria** (formalized from the Tasks and Verification below; no
new scope):

- [ ] `cctrl start` writes `policy/<session-id>.json` from new flags (`--deny
      push,delete`, `--policy-file PATH`) and records the resolved policy in the
      session metadata so `cctrl session ls` can show it.
- [ ] A `PreToolUse` hook resolves the session id, loads its policy, classifies
      the pending `Bash`/`Write`/`Edit` call, and **blocks** a denied call before
      it runs, with a denial message that names the policy and states what to do
      instead.
- [ ] Classification fails closed: all 15 deny-list commands from the 2026-07-28
      incident classify into their denied category (`delete`/`push`), and an
      unrecognised command inside a denied family is denied, not allowed.
- [ ] The near-misses are **not** blocked: `git status`, `docker ps -a`, `rm`
      inside an `allow_paths_write` path, `npm ci`.
- [ ] An empty or absent policy behaves byte-identically to today — opt-in, so it
      cannot brick the existing fleet or a spawn that predates the feature.
- [ ] `cctrl policy install` is idempotent (running it twice leaves one hook
      entry, not two) and `cctrl start` does not hand-edit settings as a side
      effect.
- [ ] `cctrl policy check <session> -- <command>` dry-runs classification so a
      policy can be validated before a spawn relies on it.
- [ ] `AGENTS.md` and the `cctrl-spawn` skill document that a brief states intent,
      the policy enforces it, and the brief is no longer the guardrail.
- [ ] **No launch shape gets a silent no-op policy.** There are two distinct
      ways enforcement can be absent, and both must be handled — an operator
      must never believe a guardrail exists where none does:
      1. *Non-Claude runtime.* cctrl spawns codex as a first-class runtime and a
         Claude Code `PreToolUse` hook enforces nothing there.
      2. *Non-tmux (foreground) launch.* `_launch_exec_agent` exports
         `CCTRL_SESSION_KIND=foreground` and **unsets** `CCTRL_SESSION_NAME`
         for any launch that is not tmux-backed (`cctrl:474-477`). A foreground
         **Claude** session therefore reaches the hook with no resolvable
         session, takes the opt-in "no policy → allow" branch, and enforces
         nothing — even though the runtime is fully hook-capable.
      In both cases `cctrl start` must either refuse the spawn or warn loudly
      AND record the policy as `unenforced` in the session metadata (visible in
      `cctrl session ls`), each with its own test.
- [ ] **The policy cannot disable itself:** the hook implicitly denies `Write`/
      `Edit`/`Bash` mutations of `$CCTRL_DATA_DIR/policy/` and of the settings
      entry that registers the hook, independent of the per-session
      `deny_paths_write` list. "I'll update my policy" is the same
      self-authorization move that produced the incident; tested.

### Why the hook, and not the alternatives

- **Better briefs** — already disproven above.
- **Dropping `bypassPermissions`** — would make every session prompt for every
  tool call, which defeats detached operation entirely. The point of a detached
  fleet is that it runs unattended.
- **Post-hoc detection** (notice the delete, alert) — the 44 GB was unrecoverable
  the instant it ran. Detection after an irreversible act is not a control.

## Design

**Policy file.** Written at spawn time next to the session's other state, keyed
by the **tmux session name** (`CCTRL_SESSION_NAME`, e.g. `TMUX--ms--homelab--4`).
Sessions share working directories — five sessions were in `~/dev/homelab` and
ten in `~/dev/obsidian-vault` on 2026-07-28 — so anything repo-scoped collides.

```
$CCTRL_DATA_DIR/policy/<CCTRL_SESSION_NAME>.json
```

**Naming caution for the implementer:** "session id" is already taken in this
codebase and means something else. `_session_id` (`cctrl:5741`) returns Claude's
*transcript UUID*, and `cctrl session ls --json` emits that UUID as the
`session_id` field (`cctrl:6113`). Policy files are **not** keyed by that. Keying
them by the transcript UUID would break for any session whose UUID is absent
(pre-first-turn) or has changed, and would not match what `cctrl start` can
write at spawn time — the UUID does not exist yet when the policy is written.
Use `CCTRL_SESSION_NAME` throughout; the filename-safe transform already exists
as `_session_metadata_file` (`cctrl:1207`, `tr '/:' '__'`) and should be reused
rather than reinvented.

```json
{
  "session": "TMUX--ms--homelab--4",
  "deny": ["push", "delete", "service-restart", "credential-write", "purchase"],
  "allow_paths_write": ["/Users/matthew/dev/homelab/docs/findings"],
  "deny_paths_write": ["/Users/matthew/Library", "/Users/matthew/.claude.json"],
  "note": "survey-and-propose only; deletions require per-item human approval"
}
```

Default-deny is **not** proposed for v1: an empty or absent policy behaves
exactly as today. This ships as opt-in so it cannot brick the existing fleet, and
so a spawn that predates the feature is unaffected.

**Hook.** A `PreToolUse` hook matching `Bash` (plus `Write`/`Edit` for the path
rules) that resolves the session id, loads the policy, classifies the pending
call, and denies with a message the agent can act on:

```
BLOCKED by session policy: this session may not delete (policy: survey-and-propose
only; deletions require per-item human approval). Propose the deletion to the
fleet manager instead. Policy file: <path>
```

The denial text matters: an agent that gets an opaque failure will retry with a
variation. An agent told *why*, and what to do instead, reports back.

**Classification** is the crux and must fail closed. `rm`, `rmdir`, `trash`,
`shred`, `find -delete`, `docker system prune`, `docker rm`, `npm cache clean`,
`brew cleanup`, `pnpm store prune`, `yarn cache clean`, `xcrun simctl runtime
delete`, `tmutil deletelocalsnapshots`, `git clean`, and `truncate` all count as
`delete` — that list is drawn directly from what the 2026-07-28 session actually
ran, not invented. `git push`, `gh release create`, `gh repo edit --visibility`
count as `push`. Anything unrecognised inside a denied category's command family
is **denied, not allowed**.

**Session-id resolution.** `cctrl start` bakes `CCTRL_SESSION_KIND=tmux` and
`CCTRL_SESSION_NAME` unconditionally into the launched agent's environment
(`cctrl:1801`), so the hook subprocess reliably inherits the session id.

`CCTRL_DATA_DIR` is **not** in the same position, and the implementer must not
assume it is. The forwarding loop at `cctrl:1697-1699` copies `CCTRL_DATA_DIR`
only when it is already non-empty in the parent environment; on a default
install it is unset (the CLI falls back to `$SCRIPT_DIR/data` internally at
`cctrl:17`), so the spawned agent — and therefore the hook — receives nothing.
A hook that resolves the policy directory from `$CCTRL_DATA_DIR` alone would
find no policy on every default-install spawn, take the opt-in "no policy →
allow" branch, and enforce nothing while `cctrl session ls` still displayed a
policy. That is precisely the silent-no-op failure acceptance criterion 7
forbids, arrived at by a different route.

Two changes, both required:

1. `cctrl start` must export `CCTRL_DATA_DIR` unconditionally into the session
   env (resolved to its effective value, not the possibly-empty inherited one),
   alongside `CCTRL_SESSION_NAME`.
2. The hook must independently fall back to the cctrl install's default
   `data/` directory when `CCTRL_DATA_DIR` is absent, and must **fail closed**
   if it can resolve a session id but cannot resolve a policy directory at all
   — an unreadable policy directory is not the same as "no policy configured",
   and must not silently degrade to allow.

Unresolvable session id (no `CCTRL_SESSION_NAME` — e.g. a non-cctrl Claude
session) → no policy → allow, consistent with opt-in.

**"Command family" defined:** classification is a per-binary safe-subcommand
list — known-safe subcommands of a listed binary pass (`docker ps -a`,
`git status`), unknown subcommands of a listed binary are denied
(`docker frobnicate`). Path-argument extraction for the path rules fails
closed: unresolvable, relative-outside-cwd, or glob paths are treated as not
inside any `allow_paths_write`.

**Stale policy cleanup:** session names recur across the fleet's lifetime
(realign/relaunch, kills). `cctrl start` without policy flags removes any stale
`policy/<session-id>.json` for that name, so a new session never inherits a
dead session's policy.

**Hook-protocol caveat for the implementer:** the in-repo precedent
`hooks/block-git-commit.py` exits 1, which under the PreToolUse protocol is
*non-blocking* (exit 2 blocks). Task 4's verify-against-a-live-session step is
load-bearing — the precedent may itself be subtly wrong; do not copy its exit
code blindly.

**Known limits, stated so nobody mistakes this for a sandbox:**

- Shell indirection defeats string classification (`eval`, a variable holding
  `rm`, a script that deletes). This raises the cost of an accident; it does not
  stop a determined agent. It is a guardrail, not a jail.
- The hook cannot see inside an MCP tool that deletes server-side.
- It cannot judge intent — a legitimate `rm` of a scratch file in an allowed path
  is permitted, and that is deliberate.

**Files expected to change:**

- `cctrl` (modified) — `cmd_start`: `--deny` / `--policy-file` flag parsing,
  policy-file write, stale-policy cleanup, unconditional `CCTRL_DATA_DIR`
  export (see Session-id resolution above), and the codex/non-Claude
  `unenforced` path. New `cmd_policy` (`install` / `check`) plus its `_dispatch`
  case. `_session_write_metadata` gains policy fields, and `cmd_session`'s
  listing renders them.
- `hooks/policy-guard.py` (created) — the `PreToolUse` hook: session-id
  resolution, policy load, command classification, path rules, the
  self-protection rule, and the exit-2 denial message.
- `tests/run-tests.sh` (modified) — the table-driven classifier suite (15
  deny-list commands, 4 near-misses), absent-policy regression guard,
  `policy install` idempotency, the codex `unenforced` assertion, and the
  self-protection assertion.
- `completions/_cctrl` (modified) — completions for `policy` and its
  subcommands, and for the new `start` flags.
- `AGENTS.md` (modified) — the brief-states-intent / policy-enforces doctrine.
- `skills/cctrl-spawn/SKILL.md` (modified) — same doctrine at the spawn
  procedure, where the operator actually chooses flags.
- `README.md` (modified) — `cctrl policy` in the command reference.

**Out of scope:**

- **Default-deny.** v1 is opt-in; an absent or empty policy behaves exactly as
  today. Flipping the default is a separate decision with fleet-wide blast
  radius.
- **Suppressing or rerouting `AskUserQuestion`** in detached sessions. Named in
  Notes as the adjacent hazard and deliberately left open.
- **Enforcing policy inside codex sessions.** A Claude `PreToolUse` hook cannot
  reach them; this plan only guarantees they are marked `unenforced` rather than
  silently unprotected. Real codex-side enforcement is future work.
- **Sandboxing.** Shell indirection (`eval`, a variable holding `rm`, a script
  that deletes) defeats string classification by construction, as does an MCP
  tool deleting server-side. This is a guardrail, not a jail, and no task here
  should attempt to close those.
- **The status-card / fleet-reader design** from 2026-07-29 (also stated in
  Notes).
- **Retrofitting policy onto already-running sessions.** Policy is written at
  spawn time; live sessions are unaffected until relaunched.

## Tasks

1. `cctrl start` writes `policy/<session-id>.json` from new flags
   (`--deny push,delete`, `--policy-file PATH`), and records the resolved policy
   in the session metadata so `cctrl session ls` can show it. In the same pass,
   export `CCTRL_DATA_DIR` unconditionally into the session env (resolved to its
   effective value) so the hook can locate the policy directory on a default
   install — see Session-id resolution; without this the feature is a silent
   no-op everywhere `CCTRL_DATA_DIR` is not already set.
2. Ship the hook script in-repo, plus an installer (`cctrl policy install`) that
   registers it in the right settings file and is idempotent. Do **not** hand-edit
   settings as a side effect of `start`.
3. Classifier with a table-driven test suite: every command listed above, plus
   the near-misses that must NOT be blocked (`git status`, `docker ps -a`,
   `rm` inside an `allow_paths_write` path, `npm ci`).
4. Denial path: exit code and message shape that Claude Code surfaces to the
   agent as feedback rather than a crash. Verify against a live session.
5. `cctrl policy check <session> -- <command>` for dry-run inspection, so a
   policy can be validated before a spawn relies on it.
6. Document in `AGENTS.md` and in the `cctrl-spawn` skill: a brief states intent,
   the policy enforces it, and **the brief is no longer the guardrail**.

## Verification

- `[cmd]` Classifier suite passes, including all 15 deny-list commands from the
  incident and the 4 near-misses.
- `[cmd]` With `{"deny":["delete"]}`, a spawned session running `rm -rf /tmp/x`
  is blocked and receives the message; with an empty policy the same command
  succeeds. Both asserted, since a guard that always blocks is as broken as one
  that never does.
- `[cmd]` With `{"deny":["push"]}`, `git push` is blocked and `git status`
  is not.
- `[cmd]` Absent policy file → behaviour byte-identical to today (regression
  guard for the whole existing fleet).
- `[cmd]` `cctrl policy install` twice leaves one hook entry, not two.
- `[cmd]` Policy flags on a codex spawn refuse or mark the policy `unenforced`
  in session metadata (never a silent no-op).
- `[cmd]` With any non-empty policy, a `Write`/`Edit`/`Bash` mutation of
  `$CCTRL_DATA_DIR/policy/` or the hook's settings registration is denied
  regardless of `deny_paths_write`.
- `[cmd]` With `CCTRL_DATA_DIR` unset in the parent environment, the launch
  command `cctrl start` builds still carries `CCTRL_DATA_DIR=`, and the hook
  resolves the same policy directory `cctrl start` wrote to. Asserts the
  `cctrl:1697-1699` conditional-forwarding gap is actually closed rather than
  assumed — the default install is the case that would otherwise silently
  enforce nothing.
- `[cmd]` A hook run that resolves a session name but cannot read the policy
  directory exits non-zero / denies rather than allowing. Distinguishes
  "no policy configured" (allow) from "policy unreadable" (fail closed).
- `[cmd]` Stale-policy cleanup: write `policy/<name>.json` with
  `{"deny":["delete"]}`, then `cctrl start` the **same** session name with no
  policy flags; assert the file is gone and the new session is unrestricted.
  Session names recur across realign/relaunch/kill, so without this a dead
  session's deny list silently governs a live one — and every other check in
  this list passes while it does.
- `[cmd]` A foreground Claude launch (`--foreground`) with `--deny delete`
  refuses, or records `unenforced` in session metadata. Guards the
  `cctrl:474-477` path where `CCTRL_SESSION_NAME` is unset and the hook would
  otherwise allow everything.
- `[manual]` A real detached session, spawned with `--deny delete`, is handed a
  deletion task and reports back that it was blocked rather than silently
  failing or looping.

## Notes

`AskUserQuestion` inside a detached session is the adjacent hazard this plan does
not close: a session can come to believe it holds human approval that no human
gave and no fleet manager can audit. It produced both the 44 GB deletion and a
`Decision (Matthew, 2026-07-28)` line written into plans 035 and 037 on the
strength of a click on an agent-authored option labelled "(Recommended)". Whether
to suppress it in detached sessions, or route it through a logged channel, is a
separate decision — record it, do not fold it in here.

Deliberately **not** in scope: the status-card and fleet-reader work discussed on
2026-07-29. That design (sessions declare, readers read, measured facts kept
separate from self-report) is sound but rests on a single night's evidence, so it
waits for the `mstack recap` experiment to show whether the cheap in-session
version is what actually gets used. This plan is independent of all of it and
would still be worth doing if that work is never built.
