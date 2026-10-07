---
id: 100
title: Role-aware session naming (orchestrators: fleet-manager and repo-level; workers)
status: blocked
blocked-by: [097]
priority: 100
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-10-07
tui-fixture: n/a  # naming, guard, ask and label tests use the fake agent and fake tmux fixtures
approved-by: Matthew 2026-10-07 (mdec-1007-cctrl-plan100, amended by mdec-1007-role-model-b); implementation queued after plan 097
---

<!-- rev2, 2026-10-07. Frontmatter note: the owner approved the plan and its
decisions. No eng review of this revision has happened yet, so there is no
`reviews:` entry and the plan stays `blocked` / `needs-review: eng` until
/mstack-plan-doctor records one and flips it to `pending`. -->

## Plain-English Summary

Matthew's role model (records `mdec-1007-role-model`, amended by
`mdec-1007-role-model-b`): every managing session is an ORCHESTRATOR. There are
two kinds: the FLEET-MANAGER orchestrator (top level, at most one per runtime)
and REPO-LEVEL orchestrators (one per repo). Everything else is a WORKER.

cctrl knows none of this today. The only signal is a shortcut key that starts
with `fm-`, and that prefix covers both kinds.

This plan gives each shortcut and session a `role` (`orchestrator | worker`)
and, for orchestrators, an `orch_kind` (`fleet | repo`), and uses them for:
- the tmux name prefix,
- a star-prefixed default label at creation,
- a guard that refuses a second live fleet manager per runtime,
- a rule that cctrl's label wins over Claude's for orchestrator sessions.

New in rev2: when cctrl cannot tell which kind of orchestrator a session is, it
ASKS. With a terminal it prompts. Without one (agents, detached launches) it
exits 78 with the flags to pass, and never guesses.

It also fixes why the Claude app shows "resume from handoff ..." (cctrl puts
that text there itself, Findings F1-F5), and lays out the migration.

**Human dependency:** one. Phase 0 needs Matthew to look at the Claude app
once. Only phase 7 waits on it. Phases 1-6 and 8 do not.

**Line references** were re-checked by function name against the working tree
on top of 9e8ba25 (2026-10-07, a worker has uncommitted edits in `cctrl` and
`tests/run-tests.sh`). Anything marked "as of 3917802" was not re-checked.
Re-grep by function name before editing.

## Interpretation (correct this if wrong)

Matthew's sentence, verbatim (2026-10-07 09:10 UTC): "i think we should go
along with everything you're saying but i would say that technically everything
is an orchestrator. if there's any ambiguity over what type of orchestrator it
is (whether it's a fleet manager orchestrator or a repo-level orchestrator), it
can ask the user".

The orchestrator session read this as:
1. Decisions M1-M9 are accepted as recommended.
2. "Everything is an orchestrator" means both managing levels are orchestrators. Workers stay workers. It does not mean workers are orchestrators too.
3. "It can ask the user" is a rule, not an option: cctrl and agents ask instead of guessing the kind.

If reading 2 is wrong (workers are also orchestrators), `role` collapses to a
single value and only `orch_kind` matters. Nothing in phases 1-2 would need to
be undone, only the default for a plain `-d <dir>` launch.

## Decisions (resolved 2026-10-07, mdec-1007-cctrl-plan100)

| # | Resolved as |
|---|---|
| M1 | tmux prefixes: `fleet-<runtime>` / `orch-<repo>` / workers plain. `fm-` now only means "old scheme". |
| M2 | Live sessions get a role tag now (`set-role`); new names arrive as sessions are replaced. No re-homing. |
| M3 | `★★ fleet manager (<runtime>)`, `★ orchestrator: <repo>`, workers no glyph, `☆` for a fleet manager handing over. |
| M4 | Skills: keep `cctrl-fleet-manager`, add `cctrl-repo-orchestrator`. |
| M5 | Existing `~/.local/state/fleet/fm-*.md` status files stay. New ones are `orch-<repo>.md`. |
| M6 | One new ledger record defines "fleet-primary". Old uses are not rewritten. |
| M7 | The one-fleet-manager guard is per machine (per tmux server), per runtime. |
| M8 | A legacy `fm-*` shortcut with no role = orchestrator. Its KIND is ambiguous, so cctrl asks (see "M8 and the kind"). |
| M9 | cctrl's label wins after a `cctrl rename`; Claude's wins only on a rename made inside Claude. |

## Requirements

- [ ] (a) `role` + `orch_kind` on shortcuts and sessions; they drive the tmux name prefix and default label; they replace plan 098's key-prefix test.
- [ ] (a2) Ask when the kind is ambiguous: prompt on a terminal, exit 78 without one, never guess, never hang.
- [ ] (b) At most one live fleet manager per runtime per machine, with a handover path and an explicit override. Evaluated only after the kind is known.
- [ ] (c) For orchestrator sessions the cctrl label is what Claude shows, and `reconcile-names` never reverts it.
- [ ] (d) A cheap way to label a session once its purpose is clear.
- [ ] (e) A migration path for live sessions, shortcut keys, status files, skills and ledger wording.

## Findings (unchanged from rev1 unless noted)

### F1-F5: why the app title shows the first prompt

| # | Finding | Status |
|---|---|---|
| F1 | cctrl passes claude `--name "<purpose> (<tmux name>)"` and `--remote-control --remote-control-session-name-prefix "<tmux name>-"`. It never passes a name to `--remote-control` itself. Launch-flag builder: `launch_display_name` at 1150-1155; the remote-control lines (1176, 1214-1220) are as of 3917802. | verified in code |
| F2 | With an initial prompt and no `-n`/`--purpose`, the purpose is generated from the prompt: `_generate_auto_purpose "$initial_prompt" "$repo_label"` (`_launch_detached`, 4481-4488) -> `_heuristic_title` (421) = `<repo_label>: <first 8 words>`. For a shortcut launch `repo_label` is the shortcut key. | verified in code |
| F3 | So cctrl itself puts the first-prompt text into Claude's session name at launch. Live proof (rev1): `~/.claude/sessions/48181.json` (fm-orchestrator) had `name` = "fm-orchestrator: resume from handoff orchestrator-fleet-3 (TMUX--ms--fm-orchestrator)", `nameSource: "user"`; the transcript's line 0 `custom-title` is the same string. Same shape on `TMUX--ms--comet--2`. | verified in live data (rev1) |
| F4 | `cctrl rename` does not change a running Claude session's name. `cmd_rename` (14512) calls `_claude_set_display_name` (10125), which appends one `custom-title` line to the transcript JSONL. The running process never reads it, and re-appends its own in-memory name as a `custom-title` + `agent-name` pair on later turns. Proof in fm-cctrl's transcript (rev1): cctrl's lone `custom-title` at lines 110 and 278, each overwritten by the process's pair at 126 and 286. | verified in live data (rev1) |
| F5 | `cctrl session reconcile-names` (`_session_reconcile_names`, 14592; dispatch 9517) is "Claude wins": it reads the last `custom-title` and overwrites `.purpose`. Given F4, running it reverts every `cctrl rename` label on any session that has taken a turn since. No skill runs it today, so the bug is latent. | verified in code; not executed |

A rename made inside the process does stick: fm-orchestrator's session file
showed `nameSince` 2026-10-07 10:08 CEST with the old name under `formerNames`.
What triggered it was not determined.

**Hypothesis only:** the Claude app / remote-control list shows the session's
in-process name, or, when the bridge session has no explicit name, a title
derived from the first user message. Phase 0 confirms which.

Bookkeeping: plan 055's frontmatter says `status: pending`, but `cmd_rename`,
`_claude_get/set_display_name` and `reconcile-names` are implemented. The
working tree already carries (uncommitted) one-line pointer notes to plan 100
in plans 055 and 098. Phase 6 keeps them and fixes 055's status.

### F6: plan 098 vs a role field

098's test is the jq filter in `_shortcut_for_dir` (17048; filter at 17086). It
becomes the fallback of the role resolver. 098's three tests keep passing
through phases 1-2 (no name change). `test_at_fm_shortcut_launch_keeps_fm_name`
is rewritten in phase 3.

### F7: current state (2026-10-07, read-only)

- `data/shortcuts.json`: 25 keys (rev1 said 24; a plain `content` key was added under mdec-1007-role-model-b). 8 start with `fm-`: `fm-homelab`, `fm-cctrl`, `fm-content`, `fm-personal`, `fm-orchestrator`, `fm-scraper`, `fm-comet`, `fm-portal`. No key has a `role` field.
- `fm-orchestrator` is the fleet manager; the other 7 are repo-level. So the `fm-` prefix really does cover both kinds (this is what makes M8 ambiguous).
- Dirs with more than one shortcut: `~/dev/homelab` (`homelab`, `fm-homelab`, `fm-orchestrator`), the Content Creation dir (`content`, `fm-content`).
- Live sessions (rev1, not re-listed): `fm-orchestrator` (fleet manager, claude), `fm-homelab--3`, `fm-cctrl`, `fm-scraper`, `fm-comet`, `fm-portal` (repo orchestrators), and `fm-homelab`, a worker with an `fm-` name. No Codex fleet manager.

### F8 (new): how cctrl prompts today

- `_prompt_tty_available` (3838) tests `/dev/tty`. `_prompt_agent_choice` (562) uses it and returns 1 when it fails.
- `_launch_resource_guardrail` (3998) uses the stricter `[[ ! -t 0 || ! -t 1 ]]` (4039) and refuses without `--force`.
- A detached launch re-runs `cctrl start --foreground` inside the new tmux pane and forwards parent-resolved values through the `_inject` array (`_launch_detached`, ~4398). That child HAS a terminal. A prompt there would hang in a pane nobody is watching.
- Exit codes in use in `cctrl` (60-79 range): 64, 65, 66, 69, 70, 74, 75, 76. 78 is free (no `exit/return 78` in `cctrl`, `lib/` or `hooks/`).

## Design

### (a) Role model

```
role:      orchestrator | worker
orch_kind: fleet | repo        (orchestrators only; may be unknown on old sessions)
```

Why two fields and not a flat `fleet-manager | orchestrator | worker`:
1. It is what Matthew said: both levels are orchestrators, and the kind is a second question.
2. "Orchestrator, kind not known" is a real state (every legacy `fm-*` key and live session). Two fields can store it. A flat enum would force a guess at write time, which is exactly what the amendment forbids.
3. Most code only asks "is this an orchestrator?" (dir-lookup filter, label-wins rule, no prompt-derived label). Only the guard and the name prefix need the kind.

| Where | Field | Authority |
|---|---|---|
| `data/shortcuts.json` | `"role"`, `"orch_kind"` (both optional) | input |
| `cctrl start` | `--role orchestrator\|worker`, `--orch-kind fleet\|repo` | input, wins |
| session metadata (task record) | `role`, `orch_kind` | authoritative for a session |
| tmux options | `@cctrl_role`, `@cctrl_orch_kind` | display hint only, same rule as `@cctrl_profile` (4542) |
| child env | `CCTRL_SESSION_ROLE`, `CCTRL_SESSION_ORCH_KIND` | for hooks/statusline; never feeds resolution |

Flag rules:
- `--orch-kind X` alone implies `--role orchestrator`.
- `--role worker --orch-kind X`: exit 64. Invalid value for either: exit 64.
- There is NO environment variable that supplies the kind. An inherited variable would silently turn every child launch of a fleet manager into a fleet manager.

Role resolution, `_resolve_role <role-flag> <kind-flag> <explicit-shortcut-key>`:
1. `--role` (or implied by `--orch-kind`)
2. the shortcut's `.role`, for an explicit `@key` launch only
3. legacy: explicit `@key`, key starts with `fm-`, no `.role` -> `orchestrator` (M8)
4. `worker`

Kind resolution, only when role = `orchestrator`:
1. `--orch-kind`
2. the shortcut's `.orch_kind`, for an explicit `@key` launch only
3. otherwise: AMBIGUOUS -> ask (next section)

A plain `-d <dir>` launch is a worker unless `--role`/`--orch-kind` is given.
Roles and kinds are never inherited through the reverse dir lookup.

`_shortcut_for_dir` keeps one jq filter, now role-based:

```
select((.value.role // (if (.key|ascii_downcase|startswith("fm-")) then "orchestrator" else "worker" end)) == "worker")
```

`_session_write_metadata` (3702) takes `role` and `orch_kind` as new optional
trailing positionals (19th, 20th), the pattern plan 071 phase 6 used. A record
without `role` reads as `worker`, except a live session named `TMUX--*--fm-*`,
which reads as `orchestrator` with unknown kind.

Display: `cctrl session ls` gets a ROLE column with `fleet`, `repo`, `orch?`
(kind unknown) or `worker`. `--json` carries `"role"` and `"orch_kind"`
(`null` when unknown).

### (a2) Ask when ambiguous

**Ambiguous cases (exhaustive).** cctrl asks in exactly these:

| # | Case |
|---|---|
| A1 | `cctrl start --role orchestrator` with no `--orch-kind`, and no explicit `@key` that has `.orch_kind`. Includes `-d <dir> --role orchestrator`, even when the dir has orchestrator shortcuts. |
| A2 | Explicit `@key` launch, shortcut has `"role":"orchestrator"` but no `"orch_kind"`, no `--orch-kind`. |
| A3 | Explicit `@key` launch, key starts with `fm-`, shortcut has no `"role"`, no flags (legacy, M8). |
| A4 | `cctrl session set-role <session> orchestrator` with no `--orch-kind`. |
| A5 | `cctrl shortcut add ... --role orchestrator` with no `--orch-kind`. |

**Not ambiguous (never asks):**
- Plain `-d <dir>` or `@key` on a non-`fm-` key with no role: worker.
- A dir with both kinds of shortcut (`~/dev/homelab`): a `-d` launch is a worker; an `@key` launch uses that key's own fields. It only becomes A1 when `--role orchestrator` is added, and then the message lists the dir's orchestrator shortcuts as hints. cctrl does not pick one.
- Flag vs shortcut disagreement (`@fm-orchestrator --orch-kind repo`): the flag wins, with one stderr note.
- Read-only commands (`session ls`, `peer ls`, snapshot, statusline, hooks): show `orch?`, never ask.
- `cctrl session restore`: replays the recorded role and kind, including "unknown". It makes no new decision, so it never asks (see "Restore").
- `cctrl rename` on an `orch?` session: no glyph is added, nothing is asked.

**What "ask" means, by context.** One function,
`_resolve_orch_kind_or_ask <reason> <dir> <runtime>`, used by A1-A5.

| Context | Test | Behaviour |
|---|---|---|
| Interactive terminal | `[[ -t 0 && -t 1 ]]`, and no `--no-input` / `CCTRL_NO_INPUT=1` | Prompt on stderr, read stdin. Two options, no default. |
| Non-interactive: agent Bash tool, pipe, cron, `cctrl session say`-driven, any detached launch's parent without a TTY | the test above fails | Do not prompt, do not launch, do not write metadata. Print the message below to stderr. Exit **78**. |
| The `--foreground` child inside the tmux pane | n/a | Never resolves. `_launch_detached` resolves in the parent and always injects `--role <r>` and, for orchestrators, `--orch-kind <k>` through `_inject`. If the child still reaches the ask (bug), it exits 78; it never prompts. Guarded by an internal `CCTRL_LAUNCH_CHILD=1` in the child env. |
| Hooks and statusline (`hooks/*`) | n/a | Never ask, never resolve. They read `CCTRL_SESSION_ROLE` / `CCTRL_SESSION_ORCH_KIND` and render `orch?` when the kind is empty. |

The stricter `-t 0 && -t 1` test (not `/dev/tty`) is deliberate: an agent's
subprocess can still have a controlling terminal, so `/dev/tty` may open even
though no human is reading it.

Interactive prompt:

```
Which kind of orchestrator is this session?  (@fm-cctrl has no orch_kind)
  1) fleet   the fleet-manager orchestrator (top level; one per runtime on this machine)
  2) repo    the repo-level orchestrator for ~/dev/cctrl
  q) abort
>
```

- Accepts `1`, `2`, `fleet`, `repo`, `q`. Empty or anything else re-prompts. There is no default.
- `q` or EOF: exit 78, nothing launched.
- If a fleet manager of this runtime is already live, option 1 shows `(TMUX--... is live; needs --succeeds)`. This is a hint only; the guard still runs afterwards.
- After an answer on an `@key` launch, print one line: how to save it on the shortcut.

Non-interactive message (first line is stable for callers to match):

```
cctrl: needs-user-decision: orchestrator-kind
Cannot tell which kind of orchestrator this is: <reason>.
Nothing was launched. Do not guess: ask the user, then re-run with one of
  --orch-kind fleet    the fleet-manager orchestrator (one per runtime on this machine)
  --orch-kind repo     a repo-level orchestrator for <dir>
  --role worker        not an orchestrator
To settle it for the shortcut: add "orch_kind" to @<key> in data/shortcuts.json.
```

**Flags that remove ambiguity:** `--orch-kind fleet|repo`, `--role worker`,
`"role"`/`"orch_kind"` on the shortcut, and `--no-input` (forces the
non-interactive branch even on a terminal).

Passing `--orch-kind` is the caller stating what it knows. A caller that does
not know (an agent that got exit 78) must ask the human; it must not retry with
a picked value. That rule goes in the skills (phase 6), since cctrl cannot
enforce it.

**Order of evaluation in `_launch_detached`:** agent resolved (4315) -> role ->
kind (ask) -> fleet-manager guard (only when kind = `fleet`) -> name -> metadata
-> `tmux new-session`. The guard never runs on an unknown kind, and an unknown
kind never reaches a new launch.

### M8 and the kind

Approved: a legacy `fm-*` key with no role is an orchestrator. That settles the
role. It cannot settle the kind, because the decision was made when
"orchestrator" meant the repo level only.

**Resolution: ask (case A3). Not "repo by default".** Reasons:
- The prefix demonstrably covers both kinds on this machine (`fm-orchestrator` is the fleet manager). A repo default is a guess that is wrong for 1 of 8 keys.
- The wrong guess is the harmful one: a fleet manager recorded as `repo` is invisible to the one-fleet-manager guard.
- Matthew's amendment is later and more specific than M8.
- The cost is bounded: phase 1's ship step adds `role` + `orch_kind` to all 8 keys before that build is installed, so on this machine A3 never fires. Elsewhere the fix is one flag, named in the message.

What M8 still guarantees: a legacy `fm-*` key is never treated as a worker and
is never adopted by the dir lookup. This differs from the rejected option M8(b)
("refuse until a role is set") only in scope: nothing is refused on a terminal,
and nothing is refused once the key has `orch_kind`. It is listed under
"Remaining open points" so Matthew can flip it to "repo by default".

### (a) Name prefix and default label

Computed in `_launch_detached` where `session_name` is set today (4430-4462),
before `_pick_safe_session_index` (4471):

| Role / kind | tmux name | Default label |
|---|---|---|
| orchestrator / fleet | `TMUX--<host>--fleet-<runtime>` | `★★ fleet manager (<runtime>)` |
| orchestrator / repo | `TMUX--<host>--orch-<repo>` | `★ orchestrator: <repo>` |
| worker | unchanged (shortcut key or dir basename, `--N` on collision) | unchanged, see (d) |

`<repo>` = the worker shortcut alias for the session's dir (`_shortcut_for_dir`),
else the shortcut key with a leading `fm-`/`orch-` removed, else the dir
basename. `--N` suffixes still come from `_pick_safe_session_index`, so a
handover successor is `fleet-claude--2`.

Label wording stays exactly as approved in M3, even though both are now
orchestrators (see "Remaining open points").

Label rules for orchestrator sessions:
- Never generated from the initial prompt (removes F2 for them).
- An explicit `-n "text"` is kept, with the kind's glyph prepended if missing.
- `cctrl rename` keeps the glyph the same way. `orch?` sessions get no glyph.

### (b) Guard: one live fleet manager per runtime, per machine

- **Counts as a live fleet manager:** a tmux session on this machine's tmux server with `role=orchestrator`, `orch_kind=fleet` (metadata, falling back to the tmux options) and `@cctrl_agent` equal to the runtime being launched. Liveness test: `tmux has-session -t '=NAME'`. Sessions with unknown kind do not count; `session ls` warns about them instead.
- **Check point:** `_launch_detached`, after the kind is known, next to the `--peer` live-identity check (4348-4361), before any metadata write. `set-role ... --orch-kind fleet` goes through the same `_fleet_manager_guard <runtime> <succeeds>`.
- **Failure** (exit 65, the code the peer conflict uses):

```
Refusing to launch: a claude fleet manager is already live: TMUX--ms--fleet-claude ("★★ fleet manager (claude)").
There is at most one fleet manager per runtime on this machine.
  Repo-level orchestrator:  --orch-kind repo
  Handover:                 --orch-kind fleet --succeeds TMUX--ms--fleet-claude
  Override:                 --allow-second-fleet-manager
```

- **Override:** `--allow-second-fleet-manager` (or `CCTRL_ALLOW_SECOND_FLEET_MANAGER=1`). Not `--force`, which fleet managers already pass for the memory gate (`_launch_resource_guardrail`, 3998).
- **Handover:** `--succeeds <session>` is accepted only when `<session>` is the one live fleet manager of the same runtime. The successor's metadata records `succeeds`. A fleet manager that a live session names in `succeeds` no longer counts. cctrl relabels the predecessor `☆ fleet manager (<runtime>), handing over`; it does not close it.
- `cctrl session ls` warns while two fleet managers of one runtime are live.
- Not covered: two launches racing in the same second, and other machines (M7).

### Restore

`cctrl session restore` (`_session_restore`, 12931; `lib/snapshot_restore.py`)
replays recorded state:
- It passes the recorded `--role` and `--orch-kind` explicitly. A row recorded as orchestrator with unknown kind is relaunched with a hidden, restore-only `--orch-kind-unresolved`, keeps its recorded name, and is listed in the restore summary as "kind unknown: run `cctrl session set-role`".
- It never asks and never exits 78 for a row.
- It bypasses the fleet-manager guard (it restores, it does not add) and prints the two-fleet-managers warning if the snapshot held two. `succeeds` is not restored.

### (c) cctrl's label reaches Claude and stays

1. **Creation:** orchestrator sessions get the canonical label as `--name`.
2. **Reconcile direction** (replaces 055's "Claude wins"; M9). Metadata gains `purpose_source` (`auto | flag | rename | role | claude`) and `claude_name_pushed` (the last name cctrl launched or pushed).
   - Orchestrator sessions, and any session with `purpose_source` in `rename|role|flag`: cctrl wins. Reconcile never overwrites `.purpose`.
   - Otherwise Claude's name is pulled only if it differs from `claude_name_pushed`, i.e. someone renamed it inside Claude. A re-stamp of the launch name (F4) is never pulled.
3. **Push into the process (phase 7, needs phase 0):** `cmd_rename` on a Claude session sends `/rename <label> (<tmux name>)` into the pane, reusing the send pattern of `_session_repair_bridge` (12293, which injects `/rc`), then confirms via the per-pid session file's `name`. It sends only when the session is idle with no unsent draft; otherwise it records `label_push_pending: true` and reconcile retries. The JSONL append stays as the offline fallback.
4. `reconcile-names` is added to the fleet-manager sweep only after phase 4 ships.

Items 1-2 do not depend on phase 0. Item 3 does.

### (d) Labelling after creation

| Option | Cost | Problem |
|---|---|---|
| 1. Spawner always passes `-n` | none; already in `skills/cctrl-spawn` | purpose not always known at spawn; handoff spawns skip it (F3) |
| 2. Session renames itself once | one command; needs `cctrl rename --self` | relies on the brief; sticks in the app only after phase 7 |
| 3. Stop-hook auto-label | title generation on every stop; hook failure modes (plans 079, 083, 088) | labels churn; surprise renames |
| 4. Dedicated labelling session | an extra session under the memory gate | heaviest option for the smallest job |

**Decision: 1 as the rule, 2 as the fallback. No hook, no extra session.**

- `-n` stays mandatory in the spawn doctrine.
- Add `cctrl rename --self "<label>"` (resolves the session from `CCTRL_SESSION_NAME`). The seed brief gets one line: "once your task is clear, run it once".
- `cctrl session ls --json` exposes `purpose_source`. The fleet manager's sweep lists sessions still on `auto` and renames the stragglers.
- For a prompt starting "resume from handoff <slug>", the auto label is `<repo>: <slug>`.

### (e) Migration

**shortcuts.json** (gitignored, hand-synced between Studio and MacBook; the
grant allows this edit as a migration step, with a backup):
1. Phase 1 ship step, BEFORE the phase-1 build is self-installed: back up to `data/shortcuts.json.bak-<date>`, then add to the 8 `fm-*` keys: `fm-orchestrator` -> `"role":"orchestrator","orch_kind":"fleet"`; the other 7 -> `"role":"orchestrator","orch_kind":"repo"`. Keys unchanged. Sync the MacBook copy before cctrl is updated there.
2. Phase 3: add `fleet` / `orch-<repo>` keys, keep the `fm-*` keys for one cycle, then remove them. `cctrl shortcut add` gains `--role` and `--orch-kind`.

**Live sessions.** tmux names are not changed in place (the name is the
metadata key, the peer address, the remote-control prefix and what grants cite;
the grant also forbids it).
1. Now, no restart: `cctrl session set-role <session> worker` or `... orchestrator --orch-kind fleet|repo` writes metadata, the tmux options and the canonical label. The guard and label rules then work on old-named sessions.
2. New names arrive when a session is replaced through the normal close doctrine. No re-homing under this plan.
3. `TMUX--ms--fm-homelab` (a worker with an `fm-` name) gets `set-role worker`.

Until step 1 runs, a live `fm-*` session shows `orch?`. That is display only;
nothing blocks on it.

**Status files** (`~/.local/state/fleet/`, outside this repo, M5): existing
`fm-*.md` files and `fm-cctrl-artifacts/` stay. A new repo orchestrator writes
`orch-<repo>.md`. cctrl code reads none of them.

**Skills (M4).**
- `skills/cctrl-fleet-manager/SKILL.md` (246 lines) keeps its name and becomes the fleet-manager orchestrator doctrine: single ledger writer, cross-repo sequencing, resource gate, handover with `--succeeds`.
- New `skills/cctrl-repo-orchestrator/SKILL.md`: one repo, reports up, spawns and reviews workers, writes `orch-<repo>.md`.
- Both open with the same two lines: "you are an orchestrator; there are two kinds", and the ask rule: an agent that cannot tell which kind it (or a session it is spawning) is asks the user.
- `skills/cctrl-spawn/SKILL.md` (175 lines): `--role`, `--orch-kind`, the `-n` rule, the `rename --self` brief line, and: "exit 78 = stop, ask the human, re-run with the flag they chose; never retry with a guessed kind".
- `skills/cctrl-session-end/SKILL.md` (174 lines): decide per "fleet manager" mention which kind it means.
- `AGENTS.md`, `skills/README.md`, `docs/cctrl-fleet-manager.md` (pointer file), `README.md`, `completions/_cctrl`, `CHANGELOG.md`.
- The new skill directory needs its skillshare / `~/.claude/skills` links created at install; the existing skill's links are untouched.

**approvals.md (M6).** Append-only; do not rewrite. One new record defines
"fleet-primary" = the fleet-manager orchestrator for the claude runtime. It is
written by the fleet manager (sole writer), not by this plan's worker.

**Hard-coded references in this repo** (counts as of 3917802;
`tests/run-tests.sh` has changed heavily since, re-run `git grep`):

| Pattern | Where (count) |
|---|---|
| `fm-` | `tests/run-tests.sh` (19), `docs/plans/098` (9), `cctrl` (5: one comment near 362, four in `_shortcut_for_dir`'s comment; the only logic is the jq filter at 17086), `CHANGELOG.md` (4), `docs/plans/096` (3), `docs/plans/081` (3), `docs/plans/071` (1), `README.md` (1), two test fixtures (1 each) |
| "fleet manager" (any spelling) | `skills/cctrl-fleet-manager/SKILL.md` (7), `skills/cctrl-session-end/SKILL.md` (6), `tests/run-tests.sh` (8), `CHANGELOG.md` (6), `skills/README.md` (3), `docs/cctrl-fleet-manager.md` (3), `README.md` (2), `AGENTS.md` (1), `cctrl` (1 comment), plus about 35 plan docs (history, leave) |
| "fleet-primary" | `docs/plans/096` (1) |

**Outside this repo** (not in this plan's write scope):
`~/dev/homelab/fleet/README.md`, `~/dev/homelab/fleet/manager-brief.md`,
`~/dev/homelab/skills/homelab-fleet-watcher/SKILL.md`, the auto-memory notes,
and the mstack-handoff skill, whose spawns produce the "resume from handoff"
prompts.

**Other code that must carry role and kind:** `lib/snapshot_restore.py`
(`DIGEST_TASK_FIELDS`), `lib/cctrl_fleet_collect.py` (`LEGACY_FIELDS`),
`_session_list` and `cctrl peer ls` output, `hooks/statusline.sh`,
`completions/_cctrl`.

## Phases

One commit per phase. The suite is green before each commit, run only in the
guarded isolated path (grant limit: nobody runs it in `~/dev/cctrl`). Register
every new test (plan 097's guard fails on unregistered ones).

| Phase | Ships | Needs Matthew |
|---|---|---|
| 0 | Spike, no code. On a throwaway session confirm that `/rename` changes the per-pid `name`, and what the Claude app shows for (i) the current launch, (ii) after `/rename`, (iii) `--remote-control "<name>"`. Record the result in this plan. | **YES: look at the app once. The only human dependency.** |
| 1 | Role + kind plumbing and the ask. `_resolve_role`, `_resolve_orch_kind_or_ask`, `--role`, `--orch-kind`, `--no-input`, exit 78, shortcut fields, metadata, tmux options, env, `_inject` forwarding, role-based `_shortcut_for_dir` filter, ROLE column in `session ls` / `--json`, `cctrl session set-role`, `shortcut add --role/--orch-kind`. No name change. Ship step: shortcut data migration (e, step 1) before self-install. | no |
| 2 | Guard: `_fleet_manager_guard`, `--succeeds`, `--allow-second-fleet-manager`, the `ls` warnings. | no |
| 3 | Name prefixes and star default labels at creation; orchestrator sessions never take the prompt-derived label; new `fleet` / `orch-<repo>` shortcut keys. | no |
| 4 | Reconcile safety: `purpose_source`, `claude_name_pushed`, new reconcile direction (design c, items 1-2); snapshot/restore carry role and kind. | no |
| 5 | `cctrl rename --self`, the handoff-prompt default label, `purpose_source` in `ls --json`. | no |
| 6 | Docs and skills: `cctrl-repo-orchestrator` added, `cctrl-fleet-manager` trimmed, cctrl-spawn, session-end, AGENTS.md, README, skills/README, pointer doc, completions, CHANGELOG, plan 055 status + the 055/098 notes. | no |
| 7 | In-process label push: `cmd_rename` sends `/rename`, `label_push_pending`, reconcile retries the push (design c, item 3). | no, but blocked on phase 0's result |
| 8 | Data runbook, not code: `set-role` on live sessions, `orch-<repo>.md` for new orchestrators, the "fleet-primary" ledger record (asked of the fleet manager). | no (already approved: M2, M5, M6) |

Order: 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 8, with 0 at any time and 7 whenever 0 is
done. If phase 0 shows `/rename` does not exist or the app ignores it, phase 7
is replaced by "relaunch with `--resume` to apply a label" and nothing earlier
changes.

### Tests per phase (tests/run-tests.sh)

Phase 1: resolution
- `test_role_flag_recorded_in_metadata_and_tmux_option`
- `test_role_invalid_value_exits_64`
- `test_orch_kind_invalid_value_exits_64`
- `test_orch_kind_flag_implies_orchestrator_role`
- `test_role_worker_with_orch_kind_exits_64`
- `test_shortcut_role_and_kind_resolve_on_at_launch`
- `test_orch_kind_flag_overrides_shortcut_kind`
- `test_dir_launch_never_inherits_shortcut_role`
- `test_dir_launch_skips_role_shortcut_without_fm_prefix`
- `test_fm_prefixed_key_with_worker_role_is_adopted`
- `test_no_env_var_supplies_orch_kind`
- 098's three tests unchanged and green.

Phase 1: ask, non-interactive (each asserts exit 78, first stderr line `cctrl: needs-user-decision: orchestrator-kind`, no tmux session created, no metadata written)
- `test_ask_a1_role_orchestrator_without_kind_exits_78`
- `test_ask_a1_dir_with_both_kinds_of_shortcut_exits_78_and_lists_hints`
- `test_ask_a2_shortcut_role_without_kind_exits_78`
- `test_ask_a3_legacy_fm_key_without_role_exits_78`
- `test_ask_a4_set_role_orchestrator_without_kind_exits_78`
- `test_ask_a5_shortcut_add_orchestrator_without_kind_exits_78`
- `test_non_interactive_never_prompts` (stdin is a pipe holding "1\n"; asserts exit 78, the input is not consumed, nothing is written to `/dev/tty`, and the command returns without a read)
- `test_no_input_flag_forces_78_even_with_tty`

Phase 1: ask, interactive (pty fixture; `script` or the suite's existing pty helper)
- `test_ask_tty_prompts_and_accepts_fleet`
- `test_ask_tty_prompts_and_accepts_repo`
- `test_ask_tty_empty_answer_reprompts_no_default`
- `test_ask_tty_abort_exits_78_nothing_launched`

Phase 1: never asks
- `test_detached_child_argv_carries_role_and_kind` (child argv has both flags)
- `test_launch_child_env_never_prompts` (`CCTRL_LAUNCH_CHILD=1` + ambiguous input on a pty exits 78)
- `test_session_ls_shows_orch_unknown_without_asking`
- `test_statusline_renders_unknown_kind_without_asking`
- `test_legacy_live_fm_session_reads_as_orchestrator_unknown_kind`
- `test_set_role_updates_live_session`

Phase 2
- `test_second_fleet_manager_same_runtime_refused_65`
- `test_fleet_manager_other_runtime_allowed`
- `test_repo_orchestrators_never_trip_guard`
- `test_unknown_kind_session_does_not_count_as_fleet_manager`
- `test_guard_runs_only_after_kind_known` (ambiguous launch with a live fleet manager: exit 78, not 65)
- `test_succeeds_allows_handover_and_blocks_third`
- `test_succeeds_wrong_session_refused`
- `test_allow_second_fleet_manager_override`
- `test_dead_fleet_manager_metadata_does_not_block`
- `test_set_role_fleet_goes_through_guard`

Phase 3
- `test_fleet_orchestrator_name_and_star_label`
- `test_repo_orchestrator_name_and_star_label`
- `test_orchestrator_session_ignores_prompt_derived_label`
- `test_orchestrator_explicit_label_gets_glyph`
- `test_unknown_kind_rename_adds_no_glyph`
- `test_at_fm_shortcut_launch_keeps_fm_name` rewritten: `@fm-x` with `orch_kind: repo` -> `orch-<repo>`.

Phase 4
- `test_reconcile_names_does_not_pull_launch_name_restamp`
- `test_reconcile_names_cctrl_wins_for_orchestrator_session`
- `test_reconcile_names_cctrl_wins_after_cctrl_rename`
- `test_reconcile_names_pulls_real_claude_rename_for_worker`
- `test_snapshot_restore_preserves_role_and_kind`
- `test_restore_unknown_kind_row_does_not_ask_or_fail`
- `test_restore_bypasses_fleet_guard_and_warns`

Phase 5
- `test_rename_self_resolves_current_session`
- `test_rename_self_outside_session_fails`
- `test_auto_label_for_handoff_prompt_uses_slug`
- `test_session_ls_json_exposes_purpose_source`

Phase 6
- Extend the existing skill-content check (the `rg` on `skills/cctrl-fleet-manager/SKILL.md` near `tests/run-tests.sh:14742`) to assert `skills/cctrl-repo-orchestrator/SKILL.md` exists and both skills contain the ask rule and "exit 78".

Phase 7
- `test_rename_sends_slash_rename_when_idle`
- `test_rename_defers_push_when_draft_present`
- `test_reconcile_retries_pending_label_push`

## Remaining open points (defaults chosen; none blocks implementation)

| # | Point | Default used in this plan |
|---|---|---|
| O1 | M8 kind: ask, or "repo by default"? | Ask (A3). Flip = change one resolver line and one test. |
| O2 | Label wording now that both are orchestrators (e.g. `★★ orchestrator: fleet (<runtime>)`). | Keep the approved M3 text unchanged. |
| O3 | Is reading 2 under "Interpretation" right (workers are not orchestrators)? | Yes. |
| O4 | Phase 0 result. | Phases 1-6, 8 proceed; phase 7 waits. |
| O5 | Should restore bypass the fleet-manager guard? | Yes, with a warning (restore replays, it does not add). |

## NOT in scope

- Re-homing, tmux renames or closes of live fleet sessions (grant limit).
- Rewriting existing `approvals.md` records or `fm-*.md` status files (grant limit).
- Amending plan 098's pushed code beyond the filter change above.
- Cross-machine fleet-manager detection (M7).
- A Stop-hook or a dedicated labelling session (rejected in d).
- Edits outside this repo (homelab briefs, mstack-handoff, auto-memory).

## Could not verify

- What the Claude app / remote-control list renders, and whether it follows an in-process rename (phase 0).
- That `/rename` exists and behaves as assumed in the installed Claude Code (not run, to avoid touching a live session).
- What caused fm-orchestrator's in-process rename at 10:08 CEST on 10-07.
- Whether `/dev/tty` opens inside an agent's Bash tool. The design does not depend on it (it tests `-t 0 && -t 1`), but it is the reason for that choice.
- That the test suite has a pty helper for the interactive ask tests; if not, phase 1 adds one using `script`.
- Codex: `cmd_rename` writes the Codex app title through `_session_codex_set_display_name` (14816); whether it survives later turns was not checked.
- The live-session list and the F3/F4 transcript evidence are carried over from rev1 and were not re-read.
- Line numbers marked "as of 3917802", and all reference counts in the hard-coded table.
