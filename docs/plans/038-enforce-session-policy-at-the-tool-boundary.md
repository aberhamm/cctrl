---
id: 038
title: Enforce per-session policy at the tool boundary, not in the brief
status: pending
blocked-by: []
priority: 10
goal: cctrl-fleet-safety
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-30
reviews:
  - type=eng verdict=approved date=2026-07-31 by=mstack-review
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
- [ ] Classification is an **explicit deny-list**: all 15 deny-list commands from
      the 2026-07-28 incident classify into their denied category
      (`delete`/`push`). A command that is not enumerated in an active denied
      category **passes**. See "Deny-list, not deny-unknown" in Design for why
      the inverse rule was rejected.
- [ ] The near-misses are **not** blocked: `git status`, `docker ps -a`, `rm`
      inside an `allow_paths_write` path, `npm ci` — and neither is any ordinary
      unenumerated command such as `git commit`, `git add`, or `git diff`.
- [ ] An empty or absent policy behaves byte-identically to today **except that
      the policy store stays protected** (see the self-protection criterion
      below) — opt-in, so it cannot brick the existing fleet or a spawn that
      predates the feature.
- [ ] `cctrl policy install` is idempotent (running it twice leaves one hook
      entry, not two) and `cctrl start` does not hand-edit settings as a side
      effect.
- [ ] `cctrl policy check <session> -- <command>` dry-runs classification so a
      policy can be validated before a spawn relies on it.
- [ ] `AGENTS.md` and the `cctrl-spawn` skill document that a brief states intent,
      the policy enforces it, and the brief is no longer the guardrail.
- [ ] **A policy flag on a launch shape that cannot enforce it REFUSES the
      spawn.** Not a warning, not an `unenforced` marker — a hard refusal with a
      nonzero exit. If the operator typed `--deny delete`, the only safe response
      to "I cannot enforce that here" is to not launch. A warning is exactly what
      a detached workflow does not read. Three shapes cannot enforce:
      1. *Non-Claude runtime.* cctrl spawns codex as a first-class runtime and a
         Claude Code `PreToolUse` hook enforces nothing there.
      2. *Non-tmux (foreground) launch.* `_launch_exec_agent` exports
         `CCTRL_SESSION_KIND=foreground` and **unsets** `CCTRL_SESSION_NAME`
         for any launch that is not tmux-backed (`cctrl:474-477`). A foreground
         **Claude** session therefore reaches the hook with no resolvable
         session, takes the opt-in "no policy → allow" branch, and enforces
         nothing — even though the runtime is fully hook-capable.
      3. *Remote-host spawn.* `cctrl --host <alias> start ...` runs cctrl on
         another machine over SSH (`_remote_exec`, `cctrl:7637`). The policy file
         and the hook must both exist on **that** host, and nothing verifies they
         do.
      Each refusal gets its own test. `unenforced` remains a valid **metadata
      state** for a session whose policy was cleared out-of-band, but it is no
      longer an acceptable outcome of a policy-bearing `cctrl start`.
- [ ] **The policy cannot disable itself, in every session, unconditionally:**
      the hook denies `Write`/`Edit`/`Bash` mutations of
      `$CCTRL_DATA_DIR/policy/` and of the settings entry that registers the
      hook — independent of the per-session `deny_paths_write` list, and
      **independent of whether the current session has any policy loaded at
      all**. An unrestricted session must not be able to delete a restricted
      session's policy file; otherwise the guardrail is removable by any
      neighbour and `cctrl session ls` keeps displaying a policy that no longer
      binds. "I'll update my policy" is the same self-authorization move that
      produced the incident; tested in both the policy-bearing and the
      empty-policy session.

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

**Deny-list, not deny-unknown.** Classification enumerates the denied commands
per category; anything not enumerated in an active denied category **passes**.

The inverse rule (per-binary safe-subcommand list, deny unknown subcommands of a
listed binary) was specified in an earlier draft and is **rejected**. Under
`deny: ["push"]` it makes `git` a listed binary, so every git subcommand not on
the safe list — `git commit`, `git add`, `git diff` — is denied. An agent doing
ordinary work is blocked on its first commit, someone switches the feature off,
and a guardrail that is switched off protects nothing. Enumerating an exhaustive
safe-list per binary is a permanent maintenance treadmill where each new
subcommand is a false-block bug, and a false-block in a detached session is
invisible until a human reads the transcript.

The cost is stated plainly: novel deletion syntax that nobody enumerated will
pass. That is the same class of gap already conceded under Known limits — this
is a guardrail, not a jail.

**Path-argument extraction still fails closed** for the path rules:
unresolvable, relative-outside-cwd, or glob paths are treated as not inside any
`allow_paths_write`. Filesystem aliasing defeats the "inside an allowed path"
model in ways string inspection cannot fully close — `rm -rf allowed/../forbidden`,
a symlink or hard link inside an allowed dir, `~` and env-var expansion,
`find allowed -exec rm /outside \;`, `tar --remove-files`. Resolve paths to their
canonical real form before the containment test, and treat a path that cannot be
canonicalized as outside. Residual aliasing risk is accepted and belongs in Known
limits, not in a claim of completeness.

**Policy file integrity.** The store is a security control, so its handling is
specified rather than assumed:

- Write atomically (temp file in the same directory, then `mv`), so a partially
  written policy is never observable.
- Refuse to read a policy file that is a symlink, or whose ownership or mode
  allows non-owner writes.
- A policy file that fails to parse is **fail-closed**: deny, do not fall through
  to allow. A corrupt policy is not an absent policy.

**`--policy-file PATH` semantics**, fixed here so the implementer does not
choose: the file is **read and copied** into `policy/<CCTRL_SESSION_NAME>.json`
at spawn time. The spawned session never references the source path, so mutating
the source afterwards changes nothing. A relative `PATH` resolves against the
invoking shell's cwd, before any target-directory change. When both flags are
given, `--deny` is **merged into** the copied policy's `deny` list (union, not
replace), so the flag can only ever tighten the file.

**Write-capable tools.** The hook must name every write-capable tool the
`PreToolUse` protocol can emit, not only `Bash`/`Write`/`Edit`. Enumerate the
current set against the installed Claude Code version at implementation time
(`MultiEdit` and `NotebookEdit` are the ones most likely to be missed) and fail
closed on an unrecognised tool name that carries a path argument.

**Denial audit trail.** `cctrl session ls` showing a policy is not observability.
Every denial appends one line to `$CCTRL_DATA_DIR/policy/denials.log` — timestamp,
session, tool, the command, and the category that matched. Without it there is no
way to answer "did the guardrail fire?", "why was this classified `delete`?", or
"how often is this session hitting the wall", and the only evidence lives in a
transcript nobody reads.

**Stale-cleanup race.** Cleanup keys off session name, and names recur across
realign/relaunch/kill. Do not delete a `policy/<name>.json` whose session is
still live: check the name against `tmux list-sessions` first and skip cleanup
when it is present.

Do **not** assume `cctrl start` already serializes this. The existing duplicate
guard is keyed on **peer identity**, not session name — it refuses a second
launch for a peer that "already has a live tmux session"
(`tests/run-tests.sh:609-611`), so a spawn with no `--peer` never reaches it.
Two concurrent starts resolving the same session name is therefore a real
interleaving: A cleans up the stale policy, B writes the new one, A's cleanup
lands after B's write and deletes a policy that belongs to a live session. Guard
the write+cleanup pair for a given name (an flock on the policy directory is
sufficient) rather than relying on inherited ordering.

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

- `cctrl` (modified) — `_session_write_metadata` named-argument refactor (task 0,
  landed as its own change before any policy field is added). `cmd_start`:
  `--deny` / `--policy-file` flag parsing, policy-file write, stale-policy
  cleanup under flock, unconditional `CCTRL_DATA_DIR` export (see Session-id
  resolution above), and the three refusal paths (codex, foreground, `--host`).
  New `cmd_policy` (`install` / `check`) plus its `_dispatch` case.
  `_session_write_metadata` then gains policy fields, and `cmd_session`'s
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

0. **Structural first, behavioural second (do not combine).** `_session_write_metadata`
   (`cctrl:1212`) already takes 10 positional parameters; adding policy fields as
   an 11th and 12th means a single misordered argument silently writes the wrong
   value into session metadata with no error. Refactor it to named/associative
   arguments and update every existing call site as its own change, with a
   regression test proving the existing metadata fields still round-trip. Only
   then add policy fields to the clean signature. Reuse
   `_session_metadata_file` (`cctrl:1207`) for the filename-safe transform rather
   than reinventing it, and model `cctrl policy install`'s idempotency check on
   `_peer_doorbell_registered` (`cctrl:5289`), which already scans `$SETTINGS`,
   `~/.claude.json`, and the codex config.
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
7. Refusal paths for the three shapes that cannot enforce (codex runtime,
   foreground launch, `--host` remote spawn), each with its own test. These are
   hard refusals with a nonzero exit, not warnings.
8. Policy-store hardening from Design: atomic write, symlink/ownership refusal,
   fail-closed on unparseable JSON, canonical-path resolution before the
   `allow_paths_write` containment test, the flock around write+stale-cleanup,
   and the `denials.log` audit line on every block.

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
- `[cmd]` **CRITICAL regression (task 0):** after `_session_write_metadata` is
  refactored to named arguments, every pre-existing metadata field
  (`name`, `created_at`, `cwd`, `target_kind`, `target`, `display_label`,
  `purpose`, `initial_prompt`, `launch_command`, `peer`, `agent`) still
  round-trips through `_session_metadata_field` with the same values as before
  the refactor. This modifies existing behaviour with existing callers, so the
  test is mandatory, not optional.
- `[cmd]` `--deny frobnicate` (an unknown category) is rejected with a nonzero
  exit and a message naming the valid categories — not silently written into the
  policy file where it would deny nothing.
- `[cmd]` `--policy-file` pointing at a nonexistent path, and at a file
  containing malformed JSON, each fail the spawn with a clear error. A policy
  that cannot be parsed must never degrade to "no policy".
- `[cmd]` `cctrl --host <alias> start --deny delete` refuses with a nonzero exit
  (the remote host has neither the policy file nor the hook).
- `[cmd]` `cctrl policy check <session> -- rm -rf /tmp/x` reports the category it
  would match and whether it would be denied, without spawning anything and
  without mutating the policy store. Asserts the dry-run path the acceptance
  criteria promise but nothing currently exercises.
- `[cmd]` `cctrl session ls` displays the resolved policy for a policy-bearing
  session. Asserts the "visible in `cctrl session ls`" half of the acceptance
  criteria, which no other check covers.
- `[cmd]` A `Write` to a path inside `deny_paths_write` is denied even when it is
  also inside an `allow_paths_write` entry (deny wins), and a path escaping an
  allowed dir via `allowed/../forbidden` or a symlink is treated as outside.
- `[cmd]` **Empty-policy session cannot sabotage a restricted one:** with session
  A holding `{"deny":["delete"]}` and session B holding no policy, a `Bash`/
  `Write`/`Edit` from B targeting `$CCTRL_DATA_DIR/policy/A.json` or the hook's
  settings registration is denied. This is the AC5/AC8 collision — assert it
  directly, since every other check passes while the hole is open.
- `[cmd]` Hook input protocol: the hook handles a well-formed `PreToolUse`
  payload, a payload with missing fields, an unrecognised tool name carrying a
  path argument, and malformed JSON on stdin — denying (exit 2) rather than
  crashing or exiting 0 in the last three. The in-repo precedent
  `hooks/block-git-commit.py:33` exits 1, which is non-blocking; assert exit 2
  explicitly rather than copying it.
- `[cmd]` Every denial appends one parseable line to `policy/denials.log` naming
  the session, tool, command, and matched category.
- `[cmd]` Tests isolate `CCTRL_DATA_DIR` to a temp dir (the harness pattern at
  `tests/run-tests.sh:548`). The repo's own `data/` is the **live fleet store**
  and is gitignored, so a test that writes there both pollutes the running fleet
  and produces vacuous `git status`-based assertions.
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

Two items raised by the 2026-07-31 outside voice and deliberately left open:

- **Capability opt-in instead of a deny-list.** Rather than enumerating dangerous
  commands, launch survey/propose sessions without bypass and grant capabilities
  explicitly (an `--allow-tools` shape). The "Why the hook" section rejects
  *dropping* `bypassPermissions` wholesale because it defeats detached operation,
  but it never evaluated per-capability grants, which would not. This is a
  strictly better primitive if it works, and it would make the classifier mostly
  unnecessary. Not folded in here because it is a different plan with a different
  blast radius — but it should be evaluated before this classifier accretes more
  categories.
- **The classifier is narrower than the sample policy.** The example JSON lists
  `service-restart`, `credential-write`, and `purchase` as deny categories, but
  only `delete` and `push` have enumerated command lists and tests. Either ship
  the remaining three with real lists and tests, or drop them from the example so
  the policy format does not advertise enforcement it lacks.

Deliberately **not** in scope: the status-card and fleet-reader work discussed on
2026-07-29. That design (sessions declare, readers read, measured facts kept
separate from self-report) is sound but rests on a single night's evidence, so it
waits for the `mstack recap` experiment to show whether the cheap in-session
version is what actually gets used. This plan is independent of all of it and
would still be worth doing if that work is never built.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | issues_found | 4 findings (1 blocking), all folded |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | clean | 6 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | not applicable (no UI surface) |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

**CODEX:** Outside voice ran twice — a pre-fix adversarial audit (4 findings: the
`CCTRL_DATA_DIR` forwarding gap, the foreground `CCTRL_SESSION_NAME` hole, the
`session_id` naming collision, and unverified stale cleanup) and a post-review
challenge (14 findings). Both were verified against source before folding; the
two most severe — an empty-policy session being able to delete a restricted
session's policy file, and refusal-vs-warning for unenforceable launch shapes —
became acceptance-criteria changes.

**CROSS-MODEL:** Three tension points surfaced and were resolved by the user, not
auto-applied. (1) Empty-policy sabotage: the eng review treated AC5 and AC8 as
independent; the outside voice showed they collide. Resolved by making
self-protection unconditional. (2) Warn vs refuse: the eng review left codex and
foreground spawns at "warn + unenforced"; the outside voice argued refusal is the
only safe response to an explicit `--deny`. Resolved as refuse, which also removes
the inconsistency created by refusing on `--host`. (3) Scope: the eng review
scored scope-fit 6/10; the outside voice recommended a 4-way split. Held whole —
the backlog is dependency-wired and the plan sits under both complexity
thresholds (7 files, 2 new components).

**VERDICT:** ENG CLEARED — ready to implement. Classifier inverted to an explicit
deny-list, self-protection made unconditional, three refusal paths added, the
metadata refactor sequenced ahead of the behavioural change, and verification
grown from 11 to 22 executable checks including a mandatory regression test.

NO UNRESOLVED DECISIONS
