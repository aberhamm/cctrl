---
id: 100
title: Role-aware session naming (orchestrators: fleet-manager and repo-level; workers)
status: pending
blocked-by: []
priority: 100
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-10-07
tui-fixture: n/a  # naming, guard, ask and label tests use the fake agent, fake tmux, fake ssh and the pty helper
approved-by: Matthew 2026-10-07 (mdec-1007-cctrl-plan100, amended by mdec-1007-role-model-b)
reviews:
  - type=eng verdict=changes-requested date=2026-10-07 by=agent  # review of rev2
  - type=eng verdict=changes-requested date=2026-10-07 by=agent  # review of rev3
  - type=eng verdict=approved date=2026-10-07 by=agent  # rev4 confirmation review: approved for phases 1-2; phase 3 text items A and B applied in this commit
---

<!-- rev4, 2026-10-07. State: approved by Matthew (decisions M1-M9 + the "ask"
amendment). Eng reviews of rev2 and of rev3 = changes-requested (both recorded
above). rev4 answers the two phase-3 items of the rev3 review; awaiting
confirmation. rev4 confirmation review: approved for phases 1-2; phase 3 text
items A and B applied in this commit (status set to `pending` so phase 1 may
proceed; phase 3 was not re-reviewed after A and B).
Plan 097 shipped as e81e1f3, so nothing blocks this plan except the review. -->

> **WARNING. Until phase 3 is installed, nobody runs `cctrl session reconcile-names` on the live fleet in any form (it writes even with --json; on today's build it would rewrite at least the fm-orchestrator and fm-homelab--3 labels).**
> "Any form" includes `--help` and `--dry-run`: today's parser looks only at a first argument of `--json` and ignores everything else, so those run for real too.

## Plain-English Summary

Every managing session is an ORCHESTRATOR. There are two kinds: the
FLEET-MANAGER orchestrator (at most one per runtime per machine) and REPO-LEVEL
orchestrators. Everything else is a WORKER. cctrl knows none of this today; its
only signal is a shortcut key starting with `fm-`.

This plan gives shortcuts and sessions a `role` (`orchestrator | worker`) and an
`orch_kind` (`fleet | repo`), and uses them for the tmux name, a star default
label, a one-fleet-manager guard, and a safe label-reconcile rule. When cctrl
cannot tell the kind it asks: a prompt for a human at a terminal, exit 78 with
the flags to pass for everything else. It never guesses and never hangs.

Changed from rev2:
- 4 phases instead of 9. Role replay through restore/realign ships in phase 1, before any name changes.
- No human dependency left. The in-process `/rename` push and its app spike moved to a stub for plan 101.
- The guard refuses a second fleet manager by name (`fleet-<runtime>`) instead of handing out `--2`.
- Reconcile is one rule: pull a Claude name only if cctrl has never seen it.
- Dropped: statusline/env role display, the ROLE table column, `purpose_source`, new shortcut keys, role flags in the child argv.

Changed from rev3 (answers the rev3 review; nothing else moved):
- D11: the known-names set now takes every title already in the transcript, at the baseline and on every `cctrl rename`; names are normalised (trailing ` (TMUX--…)` removed) before storing and comparing.
- Phase 3 adds `reconcile-names --dry-run`; the ship check is build assertion, then dry run, and a real run on the live fleet only with the orchestrator session's explicit go.
- The review's implementer notes are written into D3, D4, D7, D10 and the phase 1-4 text.

**Line references** are function names plus approximate lines in the working
tree on top of e81e1f3. Another worker has uncommitted edits in `cctrl` and
`tests/run-tests.sh`, so lines shift. Re-grep by function name before editing.
rev4: HEAD is now 3c95538 (plan 089) and that is the installed build; the D11
code facts were re-read there.

## Review rev2 → resolution

| # | Review finding | Resolved in | Mechanism in one line |
|---|---|---|---|
| R1 | New flags unknown to the start-argument scanners; injecting them crashes the agent | D2 | Nothing is injected into the child. Eight named parsers get explicit arms. One parity test. |
| R2 | Restore/realign do not work as described; replay scheduled after the name change | D7, phase 1 | Role/kind ride in `launch_flags`; replay marker (shell variable) never asks, skips the guard; realign pins the old name; legacy rows inferred from `tmux_session`. |
| R3 | One TTY test, wrong inside `$(...)` and over ssh | D3, D4 | Decided once in `main()` on fd 0 and fd 2; answer returned in a variable; bounded read; `--host` resolves by a remote preflight and forwards flags. |
| R4 | `orch-*` keys, `orch_kind` without `role`, invalid values, `@add` dropping fields | D5, D13 | Both prefixes are legacy orchestrator; kind implies orchestrator; invalid = 64; `_shortcut_add` merges; migration covers 9 keys. |
| R5 | "098's tests stay green" was false | Phase 1 tests | `test_at_fm_shortcut_launch_keeps_fm_name` is rewritten in phase 1 (fixture gets role + kind) and again in phase 2. |
| R6 | Carry sites incomplete | D6 | Provisional allow-list, registry relaunch field list, `launch_flags_for`, restore `case`, realign flags, list JSON, peers, fleet collector. |
| R7 | New reconcile would revert the live fleet's hand-set labels | D11 | A record with no known-names set gets a baseline on first sight and is not pulled. rev4: the baseline and every `cctrl rename` take every title in the transcript, so a later re-stamp is never pulled. |
| R8 | Typing `/rename` into live panes needs a safety contract | Plan 101 stub | Moved out of this plan. The contract is that plan's precondition. |
| R9 | Guard ships blind to the existing fleet manager | D8, phase 1 ship step | `set-role` (no relabel) runs on the live fleet right after the phase-1 install; the guard ships in phase 2. |

## Decisions (fixed, mdec-1007-cctrl-plan100 + mdec-1007-role-model-b)

| # | Resolved as |
|---|---|
| M1 | tmux prefixes: `fleet-<runtime>` / `orch-<repo>` / workers plain. `fm-` only means "old scheme". |
| M2 | Live sessions get a role tag now (`set-role`); new names arrive as sessions are replaced. No re-homing. |
| M3 | `★★ fleet manager (<runtime>)`, `★ orchestrator: <repo>`, workers no glyph, `☆` for a fleet manager handing over. |
| M4 | Skills: keep `cctrl-fleet-manager`, add `cctrl-repo-orchestrator`. |
| M5 | Existing `~/.local/state/fleet/fm-*.md` status files stay. New ones are `orch-<repo>.md`. |
| M6 | One new ledger record defines "fleet-primary". Old uses are not rewritten. |
| M7 | The one-fleet-manager guard is per machine (per tmux server), per runtime. |
| M8 | A legacy prefixed shortcut with no role = orchestrator. Its kind is ambiguous, so cctrl asks. |
| M9 | cctrl's label wins after a `cctrl rename`; Claude's wins only on a rename made inside Claude. Applies to every session, orchestrators included. |
| Amendment | Both levels are orchestrators. When the kind is ambiguous cctrl asks the user. Workers are not orchestrators. |

## Requirements

- [ ] (a) `role` + `orch_kind` on shortcuts and sessions; they drive the tmux name prefix and default label and replace plan 098's key-prefix test.
- [ ] (a2) Ask when the kind is ambiguous: prompt a human, exit 78 otherwise, never guess, never hang.
- [ ] (b) At most one live fleet manager per runtime per machine, with a handover path and an override.
- [ ] (c) `reconcile-names` never reverts a label cctrl gave; a rename made inside Claude still wins (M9).
- [ ] (d) A cheap way to label a session once its purpose is clear.
- [ ] (e) Migration for shortcut data, live sessions, skills and ledger wording, each with backup and rollback.

## Findings

| # | Finding | Status |
|---|---|---|
| F1 | cctrl passes claude `--name "<purpose> (<tmux name>)"` (`launch_display_name`, ~1150). | verified in code |
| F2 | With an initial prompt and no `-n`/`--purpose`, the purpose is `_generate_auto_purpose` (481) = `<repo_label>: <first words of the prompt>` (`_launch_detached`, ~4480). This is where "resume from handoff ..." titles come from. | verified in code |
| F4 | `cmd_rename` (14512) only appends a `custom-title` line to the transcript (`_claude_set_display_name`, 10125). The running process re-stamps its own name later. | code verified; live evidence from rev1 |
| F5 | `_session_reconcile_names` (14592) writes `.purpose` whenever Claude's last `custom-title` differs. With F4 that reverts every `cctrl rename`. Nothing runs it today. | verified in code |
| F6 | Plan 098's rule is the jq filter in `_shortcut_for_dir` (17083). Only one test launches an explicit `@fm-` key: `test_at_fm_shortcut_launch_keeps_fm_name` (tests ~3412). It hits ambiguity case A3 and must change in phase 1. The other two 098 tests are dir launches and stay as they are. | verified in tests |
| F7 | `data/shortcuts.json` has 26 keys. 9 are legacy-prefixed, none has `role`: `fm-homelab`, `fm-cctrl`, `fm-content`, `fm-personal`, `fm-orchestrator`, `fm-scraper`, `fm-comet`, `fm-portal`, `orch-rentkompass`. `fm-orchestrator` is the fleet manager; the other 8 are repo-level. `-d ~/dev/rentkompass` adopts `orch-rentkompass` today. | read 2026-10-07 (key names and dirs only) |
| F8 | Stored dirs with a trailing slash already match: `_shortcut_for_dir` normalises with `cd && pwd` when the dir exists. ADDENDA item 2 is wrong about the code. Test only, no code change. | verified in code |
| F9 | Every tmux-backed launch goes through `_launch_detached` (4059), called as a plain function from `cmd_start` (2229), `_shortcut_jump` (17273), `_session_restore` (12931), `_session_realign` (12355). It is never inside `$(...)`. Resolvers inside it are (`x="$(_resolve_agent_or_prompt ...)"`). | verified in code |
| F10 | The pane child is `cctrl start --foreground ...` or `cctrl @key --foreground ...`. Both foreground parsers send unknown flags to the agent (`*) passthrough+=`). | verified in code |
| F11 | Live sessions with a legacy-prefixed name (2026-10-07): `fm-orchestrator` (label `★★ fleet manager (claude)`), `fm-cctrl`, `fm-homelab--3`, `orch-rentkompass` (hand-set `★ orchestrator: ...` labels), `fm-comet`, `fm-scraper`, `fm-portal` (no label), `fm-homelab` (a worker). | `cctrl session ls --json` |

## Design

### D1. Role model and resolution

```
role:      orchestrator | worker
orch_kind: fleet | repo        (orchestrators only; unknown only on legacy or replayed sessions)
```

Role, in order:
1. `--role`, or implied by `--orch-kind`.
2. Explicit `@key` launch only: the shortcut's role (D5).
3. `worker`.

Kind, only for orchestrators:
1. `--orch-kind`.
2. Explicit `@key` launch only: the shortcut's `orch_kind`.
3. Replay (D7): stays unknown. No question.
4. Otherwise ambiguous: ask (D3).

A plain `-d <dir>` launch is a worker. Roles are never inherited through the
reverse dir lookup. No environment variable supplies a role or a kind.

Flag rules: `--orch-kind X` alone implies orchestrator. `--role worker --orch-kind X`
and any invalid value exit 64. A flag that disagrees with the shortcut wins,
with one stderr note.

One function does all of it and returns through globals, never stdout:

```
_role_resolve <role_flag> <kind_flag> <explicit_key_or_empty> <dir>
  sets ROLE_RESOLVED, ORCH_KIND_RESOLVED      returns 0 | 64 | 78
```

Call it as `_role_resolve ... || return $?`. Do not wrap it in `$(...)`.
Callers: `_launch_detached` (A1-A3; it looks the key up itself with
`_shortcut_lookup_key`, ahead of the existing shortcut block, and leaves a
missing key to the existing "Shortcut not found" error), `set-role` (A4),
`_shortcut_add` (A5).

### D2. Flags and every parser (R1)

New `cctrl start` flags: `--role V`, `--orch-kind V`, `--succeeds V` (value
flags), `--no-input` (bare). The override is env-only:
`CCTRL_ALLOW_SECOND_FLEET_MANAGER=1`.

**Nothing role-related goes to the pane child**: no argv, no env. The child
computes no name and writes no metadata. `_launch_detached` consumes the four
flags and never adds them to `passthrough` or `_inject`.

| Parser (function, approx line) | Change |
|---|---|
| `_launch_detached` arg loop (4080) | Arms for the 3 value flags and `--no-input`. Consumed. |
| `_start_args_have_explicit_target` (1968) | Add the 3 value flags to the `shift 2` arm, `--no-input` to the bare arm. Fixes `start --role orchestrator @x`. |
| `_start_requests_app_owned` (2004) | Add the 3 value flags to the `shift 2` arm. |
| `cmd_start` foreground loop (2290) | Role flags: exit 64, "role flags need a tmux-backed launch". `--no-input`: consume, ignore. |
| `_shortcut_jump` foreground loop (17400) | Same as `cmd_start`. |
| `_launch_app_owned_codex` (2110) | Add the role flags to the "incompatible with --app-owned" arm (64). App-owned Codex tasks have no role and are outside the guard. |
| `_codex_launch_to_app` in `lib/codex-launch-to-app.sh` (~105) | Add the role flags to the "incompatible with launch-to-app" arm (64). |
| `_remote_exec` purpose scan (16300) | Add the 3 value flags to the skip-value arm, so `orchestrator` is not taken as the default purpose. |

### D3. Ask when ambiguous (R3)

**Ambiguous cases (exhaustive, five).**

| # | Case |
|---|---|
| A1 | `cctrl start --role orchestrator` with no `--orch-kind` and no explicit `@key` that supplies a kind. Includes `-d <dir> --role orchestrator`. |
| A2 | Explicit `@key`; the shortcut says `role: orchestrator` with no `orch_kind`; no `--orch-kind`. |
| A3 | Explicit `@key`; key starts with `fm-` or `orch-` (any case); the shortcut has neither `role` nor `orch_kind`; no flags (M8). |
| A4 | `cctrl session set-role <session> orchestrator` with no `--orch-kind`. |
| A5 | `cctrl @add <key> <dir> --role orchestrator` with no `--orch-kind`. |

The review showed no sixth case. `orch_kind` without `role` is now a known
orchestrator, not a question. Legacy `orch-*` keys fold into A3.

**Never asks:** worker launches; a dir that has both kinds of shortcut (a `-d`
launch is a worker); read-only commands (`session ls`, `peer ls`, snapshot);
restore and realign (D7); `cctrl rename`; hooks.

**Interactivity is decided once**, in `main()` (17558) before flag parsing and
before any command substitution, on the script's own file descriptors:

```
_CCTRL_CAN_ASK=0
if [[ -t 0 && -t 2 \
      && "${CCTRL_NO_INPUT:-}" != "1" && "${CCTRL_TMUX_CONTEXT:-}" != "1" \
      && -z "${CCTRL_SESSION_KIND:-}" && -z "${CLAUDECODE:-}" ]]; then _CCTRL_CAN_ASK=1; fi
# then: a literal --no-input token before any "--" sets it back to 0
```

- **stdin and stderr, not stdout.** stdout is often captured (`out="$(cctrl start -d ...)"`, `CCTRL_EMIT_SESSION`). The prompt is written to fd 2 and the answer read from fd 0. Neither is redirected by `$(...)`.
- **`/dev/tty` is never opened by the ask**, not for the test and not for I/O. A subprocess of an agent can inherit a controlling terminal that no human reads.
- **Agent markers force non-interactive even on a pty.** `CCTRL_TMUX_CONTEXT=1` and `CCTRL_SESSION_KIND` are in the env of every agent cctrl launches and are inherited by its tool commands (only the non-tmux branch near 1130 unsets anything). Claude Code sets `CLAUDECODE` for its tool processes. A human shell has none of them.
- **Unset means no.** Code reads `${_CCTRL_CAN_ASK:-0}`, so tests that source the script never prompt.
- **Bounded.** `IFS= read -r -t "${CCTRL_ASK_TIMEOUT:-120}" answer`. Timeout, EOF, `q`, or three invalid answers in a row: exit 78. There is no default answer.
- **Checked again at the read.** The ask function tests, in this order: `_CCTRL_REPLAY` set (never ask), `${_CCTRL_CAN_ASK:-0}`, then `-t 0 && -t 2` again at the read site. Restore calls `_launch_detached` inside `while read ... done < <(jq ...)`, so fd 0 there is the row stream even when `main()` saw a terminal.
- **The read is written as** `if ! IFS= read -r -t ... answer; then return 78; fi`. The script runs under `set -e`; a bare failing `read` would exit 1 or 142 instead of 78.
- **A4 and A5** (`set-role`, `@add`) have their own parsers and do not take `--no-input`; use `CCTRL_NO_INPUT=1` there. The exit-64 message for role flags on a foreground launch says "add -d" (inside a session `cctrl start <dir>` is a foreground launch).

Prompt (stderr):

```
Which kind of orchestrator is this session?  (@fm-cctrl has no orch_kind)
  1) fleet   the fleet-manager orchestrator (one per runtime on this machine)
  2) repo    the repo-level orchestrator for ~/dev/cctrl
  q) abort
>
```

Accepts `1`, `2`, `fleet`, `repo`, `q`. After an answer on an `@key` launch,
print one line: how to save it on the shortcut.

Non-interactive result: exit **78**, nothing launched, nothing written, stdin
not read. stderr, starting at its first line:

```
cctrl: needs-user-decision: orchestrator-kind
Cannot tell which kind of orchestrator this is: <reason>.
Nothing was launched. Do not guess: ask the user, then re-run with one of
  --orch-kind fleet    the fleet-manager orchestrator (one per runtime on this machine)
  --orch-kind repo     a repo-level orchestrator for <dir>
  --role worker        not an orchestrator
To settle it for the shortcut: cctrl @add <key> <dir> --orch-kind fleet|repo
```

To keep that line first, `_role_resolve` runs in `_launch_detached` right after
the "target required" check, before `_launch_resource_guardrail`, profile and
agent resolution. Callers match exit code 78 first and the first line second.

Order in `_launch_detached`: parse args -> target check -> **role -> kind (ask)**
-> resource guardrail -> shortcut/profile/agent -> **fleet-manager guard** (needs
the runtime; only for kind `fleet`) -> peer check -> name -> metadata ->
`tmux new-session`. An unknown kind never reaches a new launch.

A caller that gets 78 must ask the human. It must not retry with a picked
value. cctrl cannot enforce that; the skills state it (phase 4).

### D4. Remote launches (`cctrl --host <alias> ...`)

Facts (`_remote_exec`, 16221): `start -d` runs the remote side as
`launch_out="$(ssh ...)"` with no TTY; `@key` and plain `start` use
`exec ssh -t`. The script runs under `set -e`, so a failing `x="$(ssh ...)"`
exits at once with ssh's status: the remote exit code and stderr reach the
caller, the captured stdout does not (read, not run).

Rule: **the remote side never asks. The local side resolves, asks if it can,
and forwards explicit flags.**

1. `_remote_exec` adds `CCTRL_NO_INPUT=1` to `env_prefix` for every remote tmux launch.
2. Preflight, only when the launch has an `@key` target or any role flag: run the hidden read-only verb on the remote with the same arguments,
   `ssh <target> "... CCTRL_NO_INPUT=1 cctrl _role-resolve <launch args>"`, written as `pre="$(...)" || rc=$?`.
   `_role-resolve` is `_launch_detached` itself stopped right after the role block (shell variable `_CCTRL_ROLE_RESOLVE_ONLY=1`), so there is no second parser. It is routed like `cmd_start` (`_start_args_have_explicit_target`, else `$PWD` as the target), prints one stdout line `role=<r> orch_kind=<k|->` and exits 0, 64, 66 (target not found; this mode only) or 78. It launches and writes nothing.
3. Result handling:

| Preflight exit | Local action |
|---|---|
| 0, stdout has a `role=` line | Append `--role <r>` and, for orchestrators, `--orch-kind <k>` to the remote args (before any `--`). The real launch then resolves nothing. Parse the last line that starts with `role=` (the remote sources `~/.zprofile` first and may print). |
| 0, no `role=` line | No result: launch unchanged. Never forward `--role ""`. |
| 78, local `_CCTRL_CAN_ASK=1` | Show the D3 prompt locally, append `--orch-kind <answer>`, launch. |
| 78, otherwise | Relay the remote stderr unchanged, return 78. |
| 64 | Relay stderr, return 64. |
| 66 | Fall through to the launch, unchanged. The real `@key` path offers to add a missing shortcut; the preflight must not hide that. |
| 1 (remote cctrl has no such verb) | If the user typed any role flag: exit 69, "cctrl on <host> does not support role flags; update it". Else launch unchanged. |
| 255 | ssh failed; return 255. |
| any other code (2, 126, 127, ...) | Default row: relay stderr, return that code. |

4. Phase 2 adds: when the preflight says orchestrator and the user gave no `--purpose`, skip the default-purpose prompt and injection (16360-16380) so the remote applies the canonical star label.

Cost: one extra ssh round trip for remote `@key` launches. Dir launches without
role flags skip it. An older local cctrl talking to a newer remote still never
guesses: the `$(ssh)` path has no TTY (78), and the `ssh -t` path is a real
terminal.

### D5. Shortcuts (R4)

Shortcut role, one jq definition kept in a bash variable (`_SHORTCUT_ROLE_JQ`)
and used by both `_shortcut_role_kind <key>` and the `_shortcut_for_dir` filter:

1. `.role` present: must be `orchestrator` or `worker`.
2. No `.role`, `.orch_kind` present: `orchestrator`.
3. Neither, key starts with `fm-` or `orch-` (case-insensitive): `orchestrator`, kind unknown (legacy fallback, M8).
4. Else `worker`.

`.orch_kind`, when present, must be `fleet` or `repo`.

- Explicit `@key` launch with an invalid value: exit 64, `cctrl: shortcut @<key>: invalid role "<v>"`.
- `_shortcut_for_dir` (17083): replace the `startswith("fm-") | not` line with "role per the rule above == worker". An entry with an invalid value is skipped, never adopted, no error. This is "exclude orchestrator shortcuts by role, with both prefixes as the legacy fallback".
- `_shortcut_add` (17174) replaces the whole entry today. New: after building the entry, merge the existing key's `role` and `orch_kind` back in unless `--role`/`--orch-kind` was given. New flags `--role`, `--orch-kind`. `--role worker` removes `orch_kind`. `--role orchestrator` with no kind is A5. The "update dir" path in `_shortcut_jump` already edits `.dir` only.
- No new shortcut keys and no key renames in this plan. With role-based names the key no longer decides the session name.

### D6. Session record and carry sites (R6)

`_session_write_metadata` (3702) takes three new optional trailing positionals:
19 `role`, 20 `orch_kind`, 21 `succeeds`. New launches always write `role`.
A record with no `role` is a pre-plan record.

`_session_role_of <tmux-name>` prints `role<TAB>kind`: the record's fields; else
the tmux options `@cctrl_role` / `@cctrl_orch_kind`; else legacy name inference
(`TMUX--<host>--fm-*` or `orch-*` = orchestrator, kind unknown); else worker.
Name inference is a fallback only. A recorded `worker` always wins (the live
`TMUX--ms--fm-homelab` is a worker).

Every site that must change:

| Site | Change |
|---|---|
| `_session_update_provisional_field` allow-list (3408, the `allowed = receipt \| {...}` line) | Add `role`, `orch_kind`, `succeeds` (phase 1) and `label_names_known` (phase 3). Without this `set-role` fails on a provisional record. |
| Registry relaunch merge, `terminal_relaunch` field list (~3039) | Add `role`, `orch_kind`, `succeeds`. Otherwise `merged.update(record)` keeps the stale role. Do not add `label_names_known` (D11). |
| `_launch_detached` after `tmux new-session` (4540) | Set `@cctrl_role`, `@cctrl_orch_kind` next to `@cctrl_profile`. Display and fallback only. |
| `launch_flags_for` in `lib/snapshot_restore.py` (212) | Copy the record's `role` and `orch_kind` into the flags, the way `profile` is copied. `launch_flags` is already in `DIGEST_TASK_FIELDS`; no schema change. Digests change once. |
| `_session_restore` flag `case` (13056) and `_session_realign_flags` (12312) | D7. |
| `_session_list` JSON row (~11088) | Add `role` and `orch_kind` (`null` when unknown). JSON only; no table column. |
| `_peer_derived_json` (4802) | Add `role`, `orch_kind` to the peer object. It builds an explicit object, so new list fields cannot break it. |
| `LEGACY_FIELDS` in `lib/cctrl_fleet_collect.py` (27) | Add `role`, `orch_kind` with `None` defaults so older hosts still aggregate. |
| `completions/_cctrl`, `cmd_help` | New flags and `session set-role`. |

Stable records need nothing else: the event reducer's `payload.set` has no field
allow-list (checked near 3132).

### D7. Replay: restore and realign (R2)

Facts: `_session_restore` relaunches each row as
`_launch_detached -d <cwd> -r <id> --purpose <p>` (13050), in-process, with
output thrown away (13095). The name is re-derived from the cwd. A `--name
TMUX--...` value is deliberately ignored (4146). `_session_realign` kills the
old session and then calls `_launch_detached` (12379).

Mechanism:
1. **Replay marker.** A shell variable, not an env var: `_CCTRL_REPLAY=restore|realign`, set by those two callers around their `_launch_detached` call and cleared in `main()`. It cannot be inherited or set from outside. In replay: the ask never fires (unknown kind stays unknown), the guard and its lock are skipped, and labels are taken verbatim (no glyph is added).
2. **Restore** adds two arms to the flag `case`: `role) --role`, `orch_kind) --orch-kind`. If the row's `launch_flags` has no `role`, infer from the row's `.tmux_session` with the same legacy name rule (`fm-*`/`orch-*` = orchestrator, kind unknown) before building the argv.
   **The current record comes first.** When the row has no role, restore reads the current record for the row's `resume_identity` before it falls back to name inference, and passes that record's `role` / `orch_kind` as flags. This read happens before the relaunch merge, so a snapshot older than the `set-role` step cannot erase a recorded kind or turn a recorded worker (`fm-homelab`) into an orchestrator. Replay never overwrites a recorded kind with "unknown".
3. **Names on restore** are re-derived, as today. Before phase 2 that is the current behaviour (a restored `fm-cctrl` comes back as `TMUX--ms--cctrl` since plan 098) but now with its role recorded. From phase 2 a restored fleet manager is `fleet-<runtime>` and a repo orchestrator `orch-<repo>`. An unknown-kind orchestrator gets the worker name for its dir and shows as `orch?`. Rev2's "keeps its recorded name" is dropped; a restore is a replacement (M2).
4. **Restore reports failures.** Replace `>/dev/null 2>&1` with stdout to `/dev/null` and stderr to a scratch file; on failure print `<tmux_session>: <first stderr line>`.
5. **Restored predecessor.** If a fleet manager of that runtime is already live when a fleet row is restored, the row is still restored (as `fleet-<runtime>--N`), label unchanged, and the summary says so. `session ls` then warns about two fleet managers.
6. **Realign** adds `--role` / `--orch-kind` to `_session_realign_flags` (so `_session_realign_cmd`'s printed hint carries them too) from `_session_role_of`. In `realign` replay the `--name TMUX--...` value IS honoured as the exact session name if it is not live. Realign exists to keep the tmux name and fix the app prefix, so it must not rename. Because replay cannot ask and skips the guard, nothing from this plan can refuse after the kill.

### D8. `cctrl session set-role` (R9)

```
cctrl session set-role <session> worker
cctrl session set-role <session> orchestrator --orch-kind fleet|repo [--relabel]
cctrl session set-role <session> --clear
```

- Writes `role` and `orch_kind` with `_session_update_metadata_field` and sets the two tmux options. If the record cannot be updated (legacy record with no stable id), it sets the tmux options only and says so.
- **Never touches the label** unless `--relabel` is given (phase 2 adds `--relabel`, which writes the canonical label through `cmd_rename`).
- Never renames the tmux session, never restarts anything.
- `orchestrator` with no kind is A4. `--orch-kind fleet` runs the guard (D10), excluding the session itself.
- `--clear` removes both fields and both options (rollback).

**Replay never renames (decided at phase 2 install).** A restore or realign reuses the recorded tmux name (`_CCTRL_REPLAY_TMUX` from the restore row; realign pins it with `--name`); if a live session holds it, the picker takes the next free `--N` of its base. The new names apply only to fresh launches. This amends D7/D9: a restore no longer re-derives `fleet-<runtime>` / `orch-<repo>`.

### D9. Names and default labels (phase 2)

Computed in `_launch_detached` where `session_name` is set (4430-4462):

| Role / kind | tmux name | Default label |
|---|---|---|
| orchestrator / fleet | `TMUX--<host>--fleet-<runtime>` exactly (D10) | `★★ fleet manager (<runtime>)` |
| orchestrator / repo | `TMUX--<host>--orch-<repo>`, `--N` on collision | `★ orchestrator: <repo>` |
| orchestrator / unknown (replay or legacy only) | as a worker | unchanged |
| worker | unchanged | unchanged |

`<repo>` = the worker shortcut alias for the dir (`_shortcut_for_dir`), else the
explicit key with a leading `fm-`/`orch-` removed, else the dir basename. This
keeps `@key` launches and `-d <dir>` launches (which restore uses) on one name.

Names the 9 real keys produce:

| Key | Session name |
|---|---|
| `fm-orchestrator` | `fleet-claude` (runtime of the launch) |
| `fm-homelab` | `orch-homelab` |
| `fm-cctrl` | `orch-cctrl` |
| `fm-content` | `orch-content` |
| `fm-personal` | `orch-obsidian` (its dir's worker alias is `obsidian`; see O2) |
| `fm-scraper` | `orch-scraper` |
| `fm-comet` | `orch-comet` |
| `fm-portal` | `orch-portal` |
| `orch-rentkompass` | `orch-rentkompass` |

Label rules:
- An orchestrator with no `-n`/`--purpose` gets the canonical label. `_generate_auto_purpose` and `_prompt_session_purpose` are not called for it. This removes F2 for orchestrators.
- An explicit label is kept. If it does not already start with `★` or `☆`, the kind's glyph is prepended. `cctrl rename` does the same for an orchestrator of known kind. Unknown kind: no glyph.
- No code path rewrites an existing label on its own. The live hand-set labels stay.
- Codex: `_session_app_display_name` (3684) skips its `<Repo>: ` prefix when the purpose starts with `★` or `☆`.

### D10. Guard: one live fleet manager per runtime, per machine (phase 2)

**Live fleet managers of runtime R** = live tmux sessions (`tmux has-session -t '=NAME'`) where either
- `_session_role_of` says orchestrator / fleet and the session's agent is R, or
- there is no recorded role and the name is `TMUX--<host>--fleet-R` or `fleet-R--N`.

Unknown-kind sessions do not count. `session ls` prints one footer line for
them, and one when two fleet managers of a runtime are live.

Launch with kind `fleet` (not replay), in `_launch_detached` after the agent is resolved:
1. Take the lock: `mkdir "$SESSION_METADATA_DIR/.fleet-manager-R.lock"` with a `pid` file inside. If it exists and its pid is alive: exit 65, "another fleet-manager launch is in progress". If the pid is dead, remove it and retry once. Release after `tmux new-session` returns and on every early return in between.
   **Age check as well as the pid check.** The lock also stores its creation time. A lock older than about 120 s is stale whatever its pid says (after a power cycle the pid can belong to an unrelated live process). A lock directory with no `pid` file counts as held only while it is a few seconds old (the creator writes the file right after `mkdir`).
2. No `--succeeds`: if the live set is not empty, refuse (65). Otherwise the name is exactly `fleet-R`. `_pick_safe_session_index` is NOT used, so no `--2` is ever handed out. If that exact name is live under a non-fleet session, refuse (65) and say which session holds it.
3. `--succeeds S`: allowed only when the live set is exactly `{S}`. The name is `fleet-R` if free, else the next free index from `_pick_safe_session_index`. The successor records `succeeds: S`. cctrl relabels S `☆ fleet manager (R), handing over` and does not close it. While both are live, nothing else can become a fleet manager.
4. `CCTRL_ALLOW_SECOND_FLEET_MANAGER=1`: skip the check and the lock; the name comes from `_pick_safe_session_index`. One stderr line names the live fleet manager every time the override is used.
5. **The env override is unset before `tmux new-session`.** A launch that starts the tmux server hands it its whole environment, and every later pane inherits it. Read `CCTRL_ALLOW_SECOND_FLEET_MANAGER` (and `CCTRL_NO_INPUT`) into locals and unset both before `tmux new-session`.

Why the lock as well as the name: metadata is written before `tmux new-session`,
and the failure path removes whatever record the name points to (4533). Two
racing launches would otherwise damage the winner's record even though tmux
lets only one of them create the session.

Refusal (exit 65, the code the `--peer` conflict uses):

```
Refusing to launch: a claude fleet manager is already live: TMUX--ms--fm-orchestrator ("★★ fleet manager (claude)").
There is at most one fleet manager per runtime on this machine.
  Repo-level orchestrator:  --orch-kind repo
  Handover:                 --orch-kind fleet --succeeds TMUX--ms--fm-orchestrator
  Override:                 CCTRL_ALLOW_SECOND_FLEET_MANAGER=1
```

Not covered: other machines (M7); Codex app-owned tasks.

### D11. Reconcile rule (R7, M9) (phase 3)

One rule for every session: **pull Claude's name only if cctrl has never seen it.**

**Invariant: reconcile pulls a Claude-side name only if it is not in the known
set after normalisation.** Every other case is a no-op.

How titles are stored (re-read at HEAD 3c95538 and in the transcript of
`TMUX--ms--fm-homelab--3`): a title is one transcript JSONL line
`{"type":"custom-title","customTitle":"<label> (<tmux name>)","sessionId":...}`.
`cctrl rename` appends one (`_claude_set_display_name`). The running process
appends its own in-memory name again and again: that transcript has 28 title
lines, line 1 the launch name, line 140 the `cctrl rename`, line 152 and every
later one the launch name again. `_claude_get_display_name` returns only the
last title, from a 500-line tail scan.

The record gains `label_names_known`: a JSON array stored as a string (both
update paths accept strings only), newest last, capped at 32 distinct names,
managed by `_session_names_known_add` / `_session_names_known_has`. It holds
every label cctrl launched the session with, set by `cctrl rename`, already
pulled, **and every title that was already in the transcript at the baseline or
at a `cctrl rename`**.

**Normalisation** (`_session_name_normalise`, used before every store and every
compare): remove one trailing ` (TMUX--...)` suffix, whatever tmux name is
inside it, then trim. Today's code strips only ` (<this session's name>)`
(~14615); after a restore the tmux name can differ and the old title
`label (TMUX--ms--oldname)` would look like a new name. An empty result is
ignored: never stored, never pulled.

**Transcript sweep** (`_session_names_known_sweep`): one pass over the whole
transcript file for `custom-title` lines (not the 500-line tail scan), each
`customTitle` normalised, distinct names added in file order. No transcript
yet: nothing to add.

| Event | Effect |
|---|---|
| Launch | `_session_write_metadata` writes `[purpose]`. |
| `cctrl rename` | Sweep the transcript (every title already in it), then add the new label. This is what keeps a name the process still holds in memory from being pulled later. |
| Reconcile, record has no `label_names_known` (every pre-plan session) | Write a baseline: current `.purpose` + the transcript sweep (every title, not only Claude's current one). **Pull nothing.** If the baseline cannot be written, pull nothing. |
| Reconcile, Claude's name is in the set after normalisation | Nothing. This covers the process re-stamping any earlier name after a `cctrl rename` (F4). |
| Reconcile, Claude's name is not in the set after normalisation | A rename made inside Claude. Pull it into `.purpose` and `@cctrl_purpose`, add it to the set. |

Checked against M9 and the rev3 review's two cases:
- Pre-plan session, `cctrl rename`, then the first reconcile, then a re-stamp of the older name: the baseline sweep already holds the older name (it is in the transcript), so it is not pulled.
- Rename inside Claude to X (not yet reconciled), then `cctrl rename` to Y, then a re-stamp of X: the rename's sweep put X in the set, so Y stays.
- A new name typed inside Claude after either of those is in no earlier title, so it is pulled, for orchestrators too.

Known limits: renaming inside Claude back to a name cctrl has already seen is
not pulled; use `cctrl rename`.

The set never evicts silently. Names are ordered by their LAST occurrence in the transcript (a name the process still re-stamps is always recent). When a session has more than 32 distinct names the record is marked full and reconcile pulls nothing for that session; it reports the session (also in `--dry-run`). `cctrl rename` keeps working.

A launch with a resume id never seeds the set from the purpose alone: `_session_write_metadata` leaves `label_names_known` out when `-r` is given. A record that already has a set keeps it (the field is not in the relaunch merge list); a record without one gets the normal baseline (pull nothing) on its first reconcile.

**Dry run.** `cctrl session reconcile-names` gets a real argument loop:
`--dry-run`, `--json`, `-h`/`--help` in any order; an unknown argument exits 64
and does nothing. `--dry-run` prints the corrections it would make and the
baselines it would write, and writes nothing: no metadata, no tmux option, no
transcript line. `--json` keeps meaning "output format" only; with `--dry-run`
the document carries `"dry_run":true`. `--help` prints usage and writes nothing.

`reconcile-names` is still not added to any sweep by this plan. cctrl's label
reaching a running Claude process is plan 101.

### D12. Labelling after creation (phase 3)

- `-n` stays mandatory in the spawn doctrine.
- `cctrl rename --self "<label>"`: resolves the session from `CCTRL_SESSION_NAME` when `CCTRL_SESSION_KIND=tmux`; otherwise exit 64.
- Worker auto label for a prompt starting `resume from handoff <slug>`: `<repo>: <slug>` instead of the first eight words.

### D13. Data migration

**`data/shortcuts.json`** (gitignored; `~/.local/lib/cctrl/current/data` is a
symlink to the repo's `data`, so every installed release reads the same file;
older code reads only `.dir/.profile/.agent/.resume/.prompt`, so the new fields
are harmless to it). One idempotent script, run before the phase-1 install:

1. Backup: `cp -p data/shortcuts.json data/shortcuts.json.bak-plan100-<UTC stamp>`.
2. jq: for every key starting `fm-` or `orch-` (any case) that has no `role`, add `"role":"orchestrator"` and `"orch_kind"`: `fleet` for `fm-orchestrator`, `repo` for the others. Write to a temp file in `data/`.
3. Validate: parses; same key count (26); exactly 9 entries changed; with `role` and `orch_kind` deleted the result equals the original. Then `mv` over the file.
4. Rollback: `cp -p data/shortcuts.json.bak-plan100-<stamp> data/shortcuts.json` if no key was added since; otherwise `jq 'map_values(del(.role, .orch_kind))'`, which keeps later keys.
5. Re-run the validate step after the phase-1 install: an `@add` on a migrated key by an older cctrl (the MacBook, or between migration and install) strips the fields again.

Re-count the keys when the step runs. The MacBook copy is hand-synced and gets
the same script before cctrl is updated there.

**Live sessions**: D8, phase 1 ship step.

**Status files, ledger (M5, M6)**: existing `fm-*.md` files stay; new repo
orchestrators write `orch-<repo>.md`. The "fleet-primary" record is written by
the fleet manager, the sole writer of `approvals.md`. cctrl code reads neither.

## Phases

One commit per phase. The suite runs only in the guarded isolated path (grant
limit). Register every new test (plan 097's guard fails on unregistered ones).
Code rollback for every phase is the same: before installing, note
`readlink ~/.local/lib/cctrl/current`; to roll back,
`ln -s <that value> ~/.local/lib/cctrl/current.next && mv -fh ~/.local/lib/cctrl/current.next ~/.local/lib/cctrl/current`
(the installer's own swap), then `git revert` the phase commit.

| Phase | Ships | Changes launch behaviour | Needs the owner |
|---|---|---|---|
| 1 | Role + kind plumbing, ask, remote preflight, replay, `set-role`. No name or label change. | yes | no |
| 2 | Names, default labels, fleet-manager guard and handover. | yes | no |
| 3 | Reconcile rule, `reconcile-names --dry-run`, `rename --self`, handoff-slug label. | auto label for handoff prompts only | no |
| 4 | Docs, skills, runbook leftovers. | no | no |

### Phase 1: role, kind, ask, replay

Review status: phases 1 and 2 had no blocker in the rev3 review; phase 3's two blockers are answered in rev4 (D11, ship step)

**Ships:** D1-D8 except `--relabel`. `_role_resolve`, the ask, exit 78,
`--no-input` / `CCTRL_NO_INPUT`, all parsers in D2, `_role-resolve` and the
`_remote_exec` preflight, shortcut rules and `_shortcut_add`, record fields and
every carry site in D6, restore and realign replay, `session set-role`, role in
`session ls --json`. Names and labels are exactly as today, with one exception.

**The one visible name change in phase 1.** `rentkompass` and `orch-rentkompass`
both point at `~/dev/rentkompass`, and `orch-rentkompass` sorts first, so
`-d ~/dev/rentkompass` is named `TMUX--ms--orch-rentkompass` today. From the
phase-1 install it is `TMUX--ms--rentkompass`. A restore of the live
`orch-rentkompass` session in the phase-1 window also comes back under
`rentkompass` (what plan 098 did to `fm-*`); phase 2 gives it `orch-rentkompass`
again. No shortcut has a `profile`, so no account changes. The ship step tags
that session first and ends with a snapshot, so a restore keeps its role, kind
and label. Goes in the CHANGELOG. Realign pinning the old name (D7) is the
second, intended change.

**Tests** (tests/run-tests.sh):

Harness
- The suite header unsets `CLAUDECODE`, `CCTRL_NO_INPUT`, `CCTRL_ASK_TIMEOUT` and `CCTRL_ALLOW_SECOND_FLEET_MANAGER`, next to the existing `unset CCTRL_TMUX_CONTEXT ...` lines (~103). The suite is run by an agent; with `CLAUDECODE` set every `test_ask_tty_*` would get 78.
- Fake ssh needs a variant that returns a chosen exit code, stdout and stderr per call. The existing `--host ms @homelab` test (~3125) sees one more ssh call.
- Three tests cannot use the log seams (the seams return before `_launch_detached`) and need the real path with fake tmux and `restore --yes` (pattern at tests ~9400 and ~3708): `test_restore_unknown_kind_row_never_asks`, `test_restore_prints_reason_for_failed_row`, `test_realign_keeps_recorded_tmux_name`.

Parsers
- `test_role_flags_before_dir_target_with_detach`
- `test_role_flags_before_at_target_without_detach`
- `test_role_flags_never_reach_child_command` (the `tmux new-session` command in the fake-tmux log contains no role flag and no role env)
- `test_role_flags_with_foreground_exit_64` (both `start --foreground` and `@key --foreground`)
- `test_role_flags_with_app_owned_and_launch_to_app_exit_64`
- `test_remote_role_value_not_taken_as_purpose`

Resolution and shortcuts
- `test_role_flag_recorded_in_metadata_and_tmux_option`
- `test_role_and_orch_kind_invalid_values_exit_64`
- `test_orch_kind_flag_implies_orchestrator_role`
- `test_role_worker_with_orch_kind_exits_64`
- `test_shortcut_role_and_kind_resolve_on_at_launch`
- `test_shortcut_orch_kind_without_role_is_orchestrator`
- `test_shortcut_invalid_role_exits_64_naming_key`
- `test_orch_kind_flag_overrides_shortcut_kind`
- `test_dir_launch_never_inherits_shortcut_role`
- `test_dir_launch_with_orch_key_and_plain_key_uses_plain_key`
- `test_dir_launch_with_only_orch_key_uses_basename`
- `test_dir_launch_matches_stored_dir_with_trailing_slash` (test only, F8)
- `test_dir_launch_skips_role_shortcut_without_legacy_prefix`
- `test_legacy_prefixed_key_with_worker_role_is_adopted`
- `test_no_env_var_supplies_role_or_kind`
- `test_shortcut_add_preserves_role_fields`
- `test_shortcut_add_role_flags_set_and_clear`
- `test_at_fm_shortcut_launch_keeps_fm_name`: **rewritten, not left alone.** Its fixture becomes `{"fm-atfm":{"dir":...,"role":"orchestrator","orch_kind":"repo"}}`; the launch line and the three name assertions stay. The original role-less fixture moves into `test_ask_a3_...` below. The two other plan-098 tests are dir launches and are unchanged.

Ask, non-interactive (each asserts exit 78, first stderr line `cctrl: needs-user-decision: orchestrator-kind`, the three flags listed, no tmux session, no record)
- `test_ask_a1_role_orchestrator_without_kind_exits_78`
- `test_ask_a2_shortcut_role_without_kind_exits_78`
- `test_ask_a3_legacy_fm_and_orch_keys_without_role_exit_78`
- `test_ask_a4_set_role_orchestrator_without_kind_exits_78`
- `test_ask_a5_shortcut_add_orchestrator_without_kind_exits_78`
- `test_non_interactive_never_reads_stdin` (stdin is a pipe holding `1`; exit 78; the byte is still unread)
- `test_no_input_flag_and_env_force_78_on_pty`
- `test_agent_env_markers_force_78_on_pty` (`CCTRL_TMUX_CONTEXT=1`, `CCTRL_SESSION_KIND=tmux`, `CCTRL_SESSION_KIND=foreground`, `CLAUDECODE=1`, one at a time)

Ask, interactive (`run_with_pty_input`, tests ~440)
- `test_ask_tty_accepts_fleet` / `test_ask_tty_accepts_repo`
- `test_ask_tty_prompts_when_stdout_is_captured` (the `out="$(cctrl start -d ...)"` case)
- `test_ask_tty_three_invalid_answers_exit_78`
- `test_ask_tty_read_timeout_exits_78` (`CCTRL_ASK_TIMEOUT=1`)
- `test_ask_tty_abort_exits_78_nothing_launched`

Remote (fake `ssh` on PATH)
- `test_remote_preflight_forwards_resolved_role_and_kind`
- `test_remote_ambiguous_prompts_locally_and_forwards_kind`
- `test_remote_ambiguous_non_interactive_returns_78_with_message`
- `test_remote_sets_no_input_on_remote_side`
- `test_remote_old_cctrl_with_role_flags_exits_69`
- `test_remote_dir_launch_without_role_flags_skips_preflight`
- `test_remote_preflight_exit_0_without_role_line_launches_unchanged`
- `test_remote_preflight_66_falls_through_to_launch`
- `test_remote_preflight_other_exit_code_is_relayed`

Record, replay, set-role
- `test_set_role_updates_live_session_and_keeps_label`
- `test_set_role_on_provisional_record`
- `test_set_role_clear_removes_fields`
- `test_relaunch_with_new_role_replaces_recorded_role`
- `test_snapshot_launch_flags_carry_role_and_kind`
- `test_restore_replays_role_and_kind` (via `CCTRL_RESTORE_LAUNCH_LOG`)
- `test_restore_legacy_row_infers_orchestrator_from_tmux_name`
- `test_restore_unknown_kind_row_never_asks`
- `test_restore_old_snapshot_does_not_erase_recorded_kind`
- `test_ask_rechecks_tty_at_read_site` (fd 0 is a pipe inside a loop although `_CCTRL_CAN_ASK=1`: 78, the pipe is not read)
- `test_restore_prints_reason_for_failed_row`
- `test_realign_flags_carry_role_and_kind` (via `CCTRL_DOCTOR_RELAUNCH_LOG`)
- `test_realign_keeps_recorded_tmux_name`
- `test_legacy_live_prefixed_session_reads_as_orchestrator_unknown_kind`
- `test_recorded_worker_beats_legacy_name_inference`
- `test_session_ls_json_exposes_role_and_kind`

**Ship step** (in this order):
1. Run the D13 shortcut migration (backup, validate, `mv`).
2. Self-install the phase-1 build.
3. Tag the live fleet, **no `--relabel`**, straight after the install (`set-role` does not exist before it). Tag `TMUX--ms--orch-rentkompass` first, the fleet manager's own session last; try the first one alone and check it (on a legacy record with a stable id `set-role` promotes the record, as `cctrl rename` already does). Save `cctrl session ls --json` first as the before-state. Re-list; as of 2026-10-07:
   - `TMUX--ms--fm-orchestrator`: `orchestrator --orch-kind fleet`
   - `fm-cctrl`, `fm-homelab--3`, `fm-comet`, `fm-scraper`, `fm-portal`, `orch-rentkompass`: `orchestrator --orch-kind repo`
   - `TMUX--ms--fm-homelab`: `worker`
   A legacy-prefixed session not on a confirmed list is left `orch?` and reported, not guessed.
4. Check: `session ls --json` shows the roles and every label is byte-identical to the before-state.
5. Last line of the ship step: `cctrl session snapshot`, so the newest snapshot carries the roles. This is a real command that writes a snapshot. The ship step runs it deliberately, with the orchestrator session's go; it is not part of any read-only check.

Not to run in this ship step or its smoke: `reconcile-names` in any form, `restore` without `--dry-run`, `doctor --fix`, any remote launch against the MacBook before its shortcuts file is migrated.

**Launch smoke after install:** a worker launch in a scratch dir; an existing
`@key` worker shortcut; `-d <scratch> --orch-kind repo`; one ambiguous launch
with stdin from `/dev/null` expecting 78 and no session; `cctrl session restore
--dry-run`; `cctrl start -d ~/dev/rentkompass -n smoke` must be named
`TMUX--ms--rentkompass`. Close the scratch sessions.

**Rollback:** code as above. Data: restore the shortcuts backup;
`cctrl session set-role <s> --clear` per tagged session (or leave the fields:
older code ignores them).

### Phase 2: names, labels, guard

Review status: phases 1 and 2 had no blocker in the rev3 review; phase 3's two blockers are answered in rev4 (D11, ship step)

**Ships:** D9, D10, `set-role --relabel`, the Codex title rule, the `--host`
purpose rule (D4 item 4), the two `session ls` footer lines.

**Tests:**
- `test_fleet_orchestrator_name_and_star_label`
- `test_repo_orchestrator_name_and_star_label`
- `test_repo_name_uses_dir_worker_alias_then_stripped_key_then_basename`
- `test_at_fm_shortcut_launch_keeps_fm_name` renamed to `test_at_legacy_orch_shortcut_launch_gets_orch_name`; assertions become `TMUX--ms--orch-atfm` (session, `new-session -s`, `--name`).
- `test_unknown_kind_orchestrator_keeps_worker_name`
- `test_orchestrator_ignores_prompt_derived_label`
- `test_orchestrator_explicit_label_gets_glyph_once`
- `test_rename_adds_glyph_for_known_kind_only`
- `test_replay_keeps_label_verbatim`
- `test_set_role_relabel_writes_canonical_label`
- `test_codex_title_skips_repo_prefix_for_star_label`
- `test_remote_orchestrator_launch_injects_no_default_purpose`
- `test_second_fleet_manager_same_runtime_refused_65`
- `test_fleet_launch_never_gets_index_suffix`
- `test_old_named_fleet_manager_with_role_blocks_new_one` (a live `fm-orchestrator` tagged by `set-role`)
- `test_fleet_manager_other_runtime_allowed`
- `test_repo_and_unknown_kind_sessions_never_trip_guard`
- `test_guard_runs_only_after_kind_known` (ambiguous launch with a live fleet manager: 78, not 65)
- `test_concurrent_fleet_launch_refused_by_lock`
- `test_stale_fleet_lock_is_reclaimed`
- `test_fleet_lock_older_than_limit_is_reclaimed_even_with_live_pid`
- `test_fleet_lock_without_pid_file_is_held_only_briefly`
- `test_override_env_is_unset_before_tmux_new_session`
- `test_succeeds_allows_one_handover_and_relabels_predecessor`
- `test_succeeds_wrong_session_or_two_live_refused`
- `test_allow_second_fleet_manager_env_override`
- `test_dead_fleet_manager_record_does_not_block`
- `test_set_role_fleet_goes_through_guard`
- `test_restore_bypasses_guard_and_reports_predecessor`
- `test_session_ls_warns_on_two_fleet_managers_and_unknown_kind`

**Ship step:** no data change. Before installing, confirm phase 1's tags are
still present (`session ls --json`), so the guard sees the live fleet manager.

**Launch smoke after install:** `-d <scratch> --orch-kind fleet` must be refused
with 65 and name the live fleet manager; `-d <scratch> --orch-kind repo` must
create `orch-<scratch>` with the `★` label and a matching remote-control prefix
(`cctrl session doctor`); a worker launch is unchanged. Close the scratch session.

**Rollback:** code as above. Sessions created under the new names keep working
on the older build (no code parses the segment after `TMUX--<host>--`).

### Phase 3: label bookkeeping

Review status: phases 1 and 2 had no blocker in the rev3 review; phase 3's two blockers are answered in rev4 (D11, ship step)

**Ships:** D11 (including `reconcile-names --dry-run` and the argument loop), D12.

> **WARNING. Until phase 3 is installed, nobody runs `cctrl session reconcile-names` on the live fleet in any form (it writes even with --json; on today's build it would rewrite at least the fm-orchestrator and fm-homelab--3 labels).**

**Tests:**
- `test_reconcile_names_legacy_record_without_known_names_is_not_pulled`
- `test_reconcile_names_writes_baseline_once`
- `test_reconcile_names_does_not_pull_launch_name_restamp`
- `test_reconcile_names_cctrl_label_stays_after_cctrl_rename`
- `test_reconcile_names_pulls_in_claude_rename_for_worker_and_orchestrator`
- `test_reconcile_names_cctrl_rename_after_pull_stays`
- `test_reconcile_names_no_pull_when_baseline_cannot_be_written`
- `test_restore_keeps_known_names_and_pulls_nothing`
- `test_reconcile_names_full_set_pulls_nothing`
- `test_restore_of_record_without_known_names_gets_baseline_not_seed`
- `test_reconcile_names_restamp_after_cctrl_rename_on_legacy_record_not_pulled` (pre-plan record: `cctrl rename`, baseline, then the older name is re-stamped; second reconcile pulls nothing)
- `test_reconcile_names_older_restamped_title_is_never_pulled` (any title that is earlier in the transcript)
- `test_reconcile_names_in_claude_rename_then_cctrl_rename_stays` (X inside Claude, never reconciled; `cctrl rename` Y; X re-stamped; Y stays)
- `test_reconcile_names_new_in_claude_rename_after_cctrl_rename_is_pulled` (M9: a name in no earlier title IS pulled)
- `test_reconcile_names_strips_old_tmux_suffix_after_restore`
- `test_reconcile_names_normalises_suffix_on_store_and_compare`
- `test_reconcile_names_dry_run_writes_nothing` (metadata files, tmux options and transcripts byte-identical before and after, in text and `--json` mode, including the baseline case)
- `test_reconcile_names_dry_run_reports_would_be_corrections`
- `test_reconcile_names_help_and_unknown_flag_write_nothing`
- `test_rename_self_resolves_current_session`
- `test_rename_self_outside_session_exits_64`
- `test_auto_label_for_handoff_prompt_uses_slug`

**Ship step:** no data migration (baselines are written lazily). In this order; stop at the first step that fails:
1. Save `cctrl session ls --json` as the before-state.
2. Assert the installed build is the phase-3 build, without calling `reconcile-names`: `readlink ~/.local/lib/cctrl/current` is the phase-3 release (`releases/<first 12 of the phase-3 commit>-...`) and `~/.local/lib/cctrl/current/VERSION` equals the phase-3 commit hash. Use the installed `cctrl`, never `./cctrl` from a tree. `reconcile-names --help` is not a probe: on an older build it runs for real.
3. Run `cctrl session reconcile-names --dry-run --json`. The output must carry `"dry_run":true`.
4. Require zero corrections for role sessions (every orchestrator, and every legacy-prefixed session). Review any other correction one by one. Pre-phase-3 sessions should show a baseline and no correction at all.
5. Compare `session ls --json` with the before-state: every label unchanged.
6. Only then may a real run be considered. The ship step does not need one. A real run on the live fleet needs the orchestrator session's explicit go; if given, run it once and repeat step 5.

**Launch smoke:** one worker launch with `-m "resume from handoff smoke-x"`;
expect the label `<repo>: smoke-x`.

**Rollback:** code as above. `label_names_known` is ignored by older code.

### Phase 4: docs, skills, runbook

Review status: phases 1 and 2 had no blocker in the rev3 review; phase 3's two blockers are answered in rev4 (D11, ship step)

**Ships:**
- New `skills/cctrl-repo-orchestrator/SKILL.md`; `skills/cctrl-fleet-manager/SKILL.md` becomes the fleet-manager orchestrator doctrine (handover with `--succeeds`). Both open with "you are an orchestrator; there are two kinds" and the ask rule.
- `skills/cctrl-spawn/SKILL.md`: `--role`, `--orch-kind`, the `-n` rule, `rename --self`, and "exit 78 = stop, ask the human, re-run with the flag they chose; never retry with a guessed kind".
- `skills/cctrl-session-end/SKILL.md`, `AGENTS.md`, `skills/README.md`, `docs/cctrl-fleet-manager.md`, `README.md`, `completions/_cctrl`, `CHANGELOG.md`.
- Plan bookkeeping: plan 055's status, and reword its 2026-10-07 note (it says "cctrl label wins for role sessions"; the rule is now D11). Plan 098's note stays.
- Skill and runbook text: on a build older than phase 3, never run `cctrl session reconcile-names` in any form; from phase 3, `--dry-run` first. After a power cycle the new fleet manager is `fleet-<runtime>` and restore brings the old one back as `fleet-<runtime>--2`; `--succeeds` needs exactly one live fleet manager, so one of the two is closed before any handover.
- Runbook, no code: new repo orchestrators write `orch-<repo>.md`; ask the fleet manager to append the "fleet-primary" record; the new skill's skillshare / `~/.claude/skills` link.

**Tests:** extend the skill-content check (the `rg` block on
`skills/cctrl-fleet-manager/SKILL.md`, tests ~14915) to require that
`skills/cctrl-repo-orchestrator/SKILL.md` exists and that both skills and
cctrl-spawn contain the ask rule and "exit 78".

**Ship step:** create the skill link. No launch smoke. **Rollback:** revert the commit; remove the link.

## Plan 101 (to be filed): push cctrl's label into a running Claude process

Not part of plan 100. Goal: after `cctrl rename`, the running Claude process
and the Claude app show the new label (today only the transcript line changes, F4).

Preconditions before any code:
1. **Spike (needs Matthew once):** on a throwaway session confirm that `/rename` exists, that it changes the per-pid session file's `name`, and what the Claude app shows for the launch name, after `/rename`, and for `--remote-control "<name>"`.
2. **A written safety contract, reviewed, covering at least:**
   - Send only in a positive allow-list of states (`idle-done`; `waiting-input` with a provably empty input line). Never on `blocked-dialog`, `unsent-draft`, `working` or unknown.
   - No `C-u`. If the input line is not provably empty, do not send. (`_session_repair_bridge`, 12293, sends `-X cancel`, `C-u`, text, `Enter`; that pattern is not acceptable here.)
   - Re-check the state immediately before sending; verify through the per-pid session file; one attempt per `cctrl rename`.
   - The label is one line, control characters removed, length capped, never starting with `/`.
   - Retries are opt-in (`reconcile-names --push`), capped, and never run from a sweep by default.
   - A kill switch (`CCTRL_LABEL_PUSH=0`).
   - Tests include a `blocked-dialog` case and a "state changed between check and send" case.

If the spike shows `/rename` is missing or ignored, plan 101 becomes "relaunch
with `--resume` to apply a label". Nothing in plan 100 changes either way.

## Review recommendations

**Adopted:** tmux name as the atomic part of the guard (rec 1, plus a lock);
simpler reconcile (rec 2); no statusline/env role display (rec 3); Codex title
prefix (rec 4); no injected default purpose for remote orchestrators (rec 5);
role in JSON only (rec 7); names for all 9 keys written out (rec 8); scripted,
validated migration (rec 9); name inference as a legacy fallback only (rec 10);
restored predecessor behaviour stated (rec 11, without the relabel); app-owned
tasks outside the guard (rec 12). Cuts: phase 7 to plan 101; `--succeeds`
shrunk to "exactly one live predecessor"; no new shortcut keys; phases merged.

**Declined:**

| Recommendation | Why not |
|---|---|
| One shared "flags that take a value" helper for the scanners | The three lists differ today; unifying them changes behaviour for existing flags. Explicit arms plus the parser tests instead. |
| Reserve `fleet` / `fleet-*` shortcut keys | This plan adds no such keys. |
| `_remote_exec` prompts locally on 78 and re-runs | The `@key` path uses `exec ssh -t`, so there is nothing to re-run from. A preflight covers both paths. |
| Backfill the pushed name from `CCTRL_SESSION_PURPOSE=` in `launch_command` | The first-sight baseline is simpler and also covers sessions renamed inside the process before this plan. |
| Rec 6, replay `purpose_source` on restore | `purpose_source` is dropped; the simpler reconcile does not need it. |
| Rec 11's relabel of a restored predecessor to `☆ ... (restored predecessor)` | Restore replays labels verbatim. A summary line and the `ls` warning are enough. |
| Cut `--no-input`, keep only the env var | The task brief for this revision requires both. |
| A hidden `--orch-kind-unresolved` flag, `CCTRL_LAUNCH_CHILD` (rev2) | Replaced by the in-process replay variable and by passing nothing to the child. |

## Remaining open points (defaults chosen; none blocks phase 1)

| # | Point | Default |
|---|---|---|
| O1 | M8 kind: ask, or "repo by default"? | Ask (A3). On this machine the migration makes A3 unreachable. |
| O2 | `fm-personal` becomes `orch-obsidian`, not `orch-personal`. | Keep the dir-alias rule (same name from `@key` and from restore). A key-first rule would give `orch-personal` but a different name after a restore. |
| O3 | Label wording now that both are orchestrators. | Keep the approved M3 text. |
| O4 | Are workers never orchestrators? | Yes (reading 2 of the owner's sentence). |
| O5 | Should restore bypass the guard? | Yes, and it reports the restored predecessor. |
| O6 | Ask timeout. | 120 s (`CCTRL_ASK_TIMEOUT`). |
| O7 | Who confirms the phase-1 `set-role` list for the three unlabelled sessions? | The fleet manager, from its ledger; unconfirmed sessions stay `orch?`. |

## NOT in scope

- Re-homing, tmux renames or closes of live fleet sessions (grant limit).
- Rewriting existing `approvals.md` records or `fm-*.md` status files (grant limit).
- Typing into live panes; the Claude app title (plan 101).
- Renaming or adding shortcut keys; statusline role display; a ROLE table column; `purpose_source`.
- Fixing the generic failure path that removes the record a name points to when `tmux new-session` fails (4533); the fleet lock keeps it away from fleet names only.
- Cross-machine fleet-manager detection (M7).
- Edits outside this repo (homelab briefs, mstack-handoff, auto-memory).

## Unverified (the design does not depend on any of these)

- What the Claude app / remote-control list renders, and whether `/rename` exists (plan 101's spike).
- Whether `/dev/tty` opens inside an agent's Bash tool. The ask never opens it.
- Whether Codex (or another runtime) gives its shell tool a pseudo-terminal. If it does and no cctrl marker is in its env, the bounded read ends in exit 78.
- That Claude Code always sets `CLAUDECODE` for tool processes. It is one of four independent markers; the stdin test and the timeout still apply.
- The `set -e` behaviour of `_remote_exec`'s `launch_out="$(ssh ...)"` was read, not run.
- (Settled by the rev3 review: `plan()` in `lib/snapshot_restore.py` passes rows through unchanged, `row = dict(source)`, ~589.)
- When the Claude process re-stamps its title, and whether a rename made inside Claude can sit in memory without a transcript line. D11 does not depend on the first; the second would be a gap only if `cctrl rename` runs in that window.
- How restore finds the current record for a row's `resume_identity` (D7 item 2); the lookup helper was not read.
- The MacBook's cctrl version and its copy of `shortcuts.json`.
- The live-session list is a snapshot from 2026-10-07; the F4 transcript evidence is carried from rev1.
- No test was run for this revision (read-only limit). Line numbers are approximate.

## Phase 1 review follow-ups

Phase 1 shipped as ffea995 (R1 and R2 fixed) plus the role-less relaunch fix below. Open items from the phase 1 Opus review (`.mstack/handoffs/2026-10-07-plan100-phase1-opus-review.md`) and the confirmation review:

- Remote `CCTRL_NO_INPUT=1` is prefixed before the arg loop finds `--foreground`, so a foreground remote agent inherits it (fails safe). Add the prefix only if `remote_tmux_launch` is still true after the loop. The same applies to a local `CCTRL_NO_INPUT=1 start -d` landing in the tmux server's global env: unset it before `tmux new-session`.
- `_remote_exec` maps a remote exit 1 to 69 ("update it"); `_role-resolve` also returns 1 for its own errors, so the message can be wrong.
- `_session_set_role`: a half-updated record if the kind write fails while the output says "tmux options only"; `--clear` stores null or "" (readers handle both).
- `_role_ask_kind` on a remote 78 passes `$host_alias` as the "for <dir>" text and drops the "To settle it" line (cosmetic).
- Tests: `_make_fake_ssh_role` overwrites `$TMPDIR/ssh`, which later remote tests may reuse; the third case in `test_role_and_orch_kind_invalid_values_exit_64` asserts no rc; `test_restore_replays_role_and_kind` uses a loose grep; `test_remote_foreground_skips_preflight_and_role_flags` does not cover `@k --foreground` and asserts no rc.

Deviations from the plan (phase 1):

1. Registry merge: `terminal_relaunch` needs a provisional launch id, which a launch of a known conversation (`-r <id>`, restore) lacks, so the role fields use a separate, wider merge condition (legacy-promotion, launched_by_cctrl, tmux control surface, incoming role set). A launch that states no role (no `--role`/`--orch-kind`, no shortcut role) now re-reads the recorded role+kind for that conversation before the write, so `start -d <dir> -r <id>` keeps a recorded orchestrator; an explicit flag or shortcut role still wins (test_roleless_relaunch_keeps_recorded_role_and_kind).
2. `--succeeds` is parsed and recorded only (no relabel or handover behaviour).
3. The restore failure reason prints the FIRST stderr line, which can be an unrelated warning (legacy-profile WARN) hiding the real error; consider the last error line.

## Phase 2 review follow-ups

Phase 2 review: `.mstack/handoffs/2026-10-07-plan100-phase2-opus-review.md` (1 REQUIRED, 9 RECOMMENDED). Applied in phase 2: REQUIRED 1 (predecessor relabelled only after the health check), RECOMMENDED 1 (stale lock reclaimed by atomic `mv`), 2 (own exit 74 + message when the registry dir cannot be created), 3 (`--succeeds` is exit 64 unless the kind is fleet, override and workers included), 4 (empty runtime counts as claude; `--relabel` never writes an empty runtime), 5 (`set-role --orch-kind fleet` takes the launch lock), 6 (repo `--relabel` falls back to the pane path, else refuses 64), 7 (remote skip only for a known kind), 9 (refusal wording per caller; exact-name refusal names the holder's role).

Left as follow-ups:

- #8: `_session_ls_role_footers` calls `_session_role_of` three times per session (unknown-kind pass, claude, codex). Compute the role once per session; about 150 extra subprocesses on a 20-session host, human `session ls` only.
- `set-role` writes the record and tmux options before `--relabel` renames; a failed rename leaves the tag applied (the output says so).
- The fleet lock is per machine and per runtime; a remote fleet manager is not seen by the guard (plan: per machine for now).
