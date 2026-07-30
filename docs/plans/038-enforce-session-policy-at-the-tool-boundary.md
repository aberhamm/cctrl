---
id: 038
title: Enforce per-session policy at the tool boundary, not in the brief
status: pending
blocked-by: []
priority: 10
goal: cctrl-fleet-safety
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-30
---

## Requirements

Every session `cctrl start` creates runs with permissions bypassed. The seeded
brief is therefore the **only** thing standing between a spawned agent and a
push, a `rm -rf`, or a prod restart — and a brief is a request, not a rule.

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

### Why the hook, and not the alternatives

- **Better briefs** — already disproven above.
- **Dropping `bypassPermissions`** — would make every session prompt for every
  tool call, which defeats detached operation entirely. The point of a detached
  fleet is that it runs unattended.
- **Post-hoc detection** (notice the delete, alert) — the 44 GB was unrecoverable
  the instant it ran. Detection after an irreversible act is not a control.

## Design

**Policy file.** Written at spawn time next to the session's other state, keyed
by session id (sessions share working directories — five sessions were in
`~/dev/homelab` and ten in `~/dev/obsidian-vault` on 2026-07-28, so anything
repo-scoped collides):

```
$CCTRL_DATA_DIR/policy/<session-id>.json
```

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

**Known limits, stated so nobody mistakes this for a sandbox:**

- Shell indirection defeats string classification (`eval`, a variable holding
  `rm`, a script that deletes). This raises the cost of an accident; it does not
  stop a determined agent. It is a guardrail, not a jail.
- The hook cannot see inside an MCP tool that deletes server-side.
- It cannot judge intent — a legitimate `rm` of a scratch file in an allowed path
  is permitted, and that is deliberate.

## Tasks

1. `cctrl start` writes `policy/<session-id>.json` from new flags
   (`--deny push,delete`, `--policy-file PATH`), and records the resolved policy
   in the session metadata so `cctrl session ls` can show it.
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
