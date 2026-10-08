---
id: 106
title: Lean MCP mode for cctrl-launched workers (Claude and Codex) and a read-only MCP-helper census
status: pending
blocked-by: []
priority: 106
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-10-08
tui-fixture: n/a  # launch flags + a read-only process report
approved-by: Matthew ("Okay, just go with what you think the best decisions are and keep going.", 2026-10-08 15:49Z via the cctrl orchestrator; approvals mdec-1008-cctrl-next-work (item 5c, lean MCP + helper census plan) + mdec-1008-cctrl-orch-successor-2 (carry-over to TMUX--ms--orch-cctrl--2))
reviews:
  - type=eng verdict=approved date=2026-10-08 by=opus-subagent
---

## Plain-English Summary

Every agent session starts the owner's full set of MCP servers (mail,
trading, notes, ...). A coding worker needs none of them. On 2026-10-08 one
shared Codex app-server held about 41 such sets (38.8 GB). This plan adds
(1) a read-only report of helper processes per owner, (2) an opt-in flag so
cctrl-launched workers start with only the MCP servers cctrl itself needs,
(3) operator documentation. cctrl never kills a helper and never edits the
owner's MCP configuration.

## Non-goals

- Killing, restarting or signalling the Codex app-server or any helper.
- Editing `~/.codex/config.toml`, `~/.claude.json`, `.mcp.json` or any plugin setting.
- Changing the default: `inherit` stays the default for every launch.
- Lean mode for app-owned threads (P4 is a spike that ships no code unless proven).
- A dedicated `CODEX_HOME` per worker (rejected, see facts).

## Verified facts (2026-10-08, code at 74a8fe3; only names and counts were read from config)

Launch paths (read in `cctrl`):
- `_launch_exec_agent`, Claude branch: adds `--settings <file>` from `_profile_settings_write` (the overlay holds `env` only) and, only when `CCTRL_PEER` is set, `--mcp-config '{"mcpServers":{"cctrl-peer":...}}'` (inline JSON built with `printf`). `--strict-mcp-config` appears nowhere in `cctrl`.
- `_launch_exec_agent`, Codex branch: for tmux sessions adds `-c mcp_servers.cctrl_runtime.command=...` and `-c mcp_servers.cctrl_runtime.args=[...]` (served by `lib/runtime_mcp.py`). cctrl registers no peer MCP for Codex.
- `_launch_apply_profile_args`: profile `agents.<agent>.args` entries it does not recognise are passed through to the agent. So an operator can already get a lean worker by hand through profile args; nothing in cctrl knows about it.
- `lib/session-wrapper.sh` restarts reuse the same option list (comment in `_launch_exec_agent`).
- `_launch_app_owned_codex`: rejects every profile arg except sandbox/approval/yolo, then calls `lib/codex_app_server.py launch`. `launch_task` sends `thread/start` with `cwd`, `ephemeral`, model fields and `config: {model_reasoning_effort}`. So the protocol carries a per-thread `config` object; whether the app-server honours `mcp_servers.*` there is (unverified).
- `lib/codex-launch-to-app.sh`: terminal launch via `_launch_detached -d --agent codex`, then release to the app.
- `cctrl` reads `CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"` once at start; hooks doctor and rollout/state lookups use it. A separate `CODEX_HOME` would split auth, hooks, state DB and rollouts from what cctrl reads (reasoned from code, not run).
- No top-level `doctor` or `helpers` command exists. Existing doctors: `session doctor` (bridge audit, has `--fix`), `peer doctor`, `host doctor`, `hooks doctor`.

Codex CLI 0.153.4 (read-only `codex mcp list --json`, `--help`):
- `~/.codex/config.toml` has 23 `[mcp_servers.*]` tables: 18 with `command` (stdio, one helper process tree each), 5 with `url`. The effective list has 27; 4 come from plugins (`code-review`, `codex_app`, `cua_repl`, `vercel`).
- `-c 'mcp_servers={}'` does NOT clear the list (27 remain).
- `-c mcp_servers.<name>.enabled=false` disables a `config.toml` server (checked on 2 names).
- The same override on a plugin-provided name makes the command fail. Plugin servers cannot be disabled this way.
- `-p/--profile <name>` layers `$CODEX_HOME/<name>.config.toml` (help text; no such file exists today).
- Whether an interactive `codex` launch honours `enabled=false` the same way as `mcp list` is (unverified).

Claude Code 2.1.290 (`claude --help`):
- `--mcp-config <configs...>` (files or JSON strings) and `--strict-mcp-config` ("only use MCP servers from --mcp-config") exist.
- Whether strict mode also drops claude.ai connectors and plugin-provided servers is (unverified).

Process measurements (this session, `ps` aggregates only):
- Codex app-server (`app-server --remote-control --listen unix://`): 360 direct children, 499 descendants, 33.9 GB helper RSS, 1.3 GB own RSS. 360 / 18 = 20 sets, about 1.7 GB per set.
- The earlier figure (about 740 children, 41 sets, 38.8 GB; given, not re-measured) matches 41 x 18 = 738.
- Terminal-owned Codex: 20 direct children, 0.86 GB helper RSS, 0.22 GB own.
- Claude session: 16-19 direct children, 0.82 GB helper RSS, 0.4-0.8 GB own.
- Three other `codex app-server` processes exist (ChatGPT.app, plugin app-server x2) with few children.
- That each app-server thread spawns its own set, and when sets are reaped, is inferred from the counts (unverified).

## Design

### D1. Helper census (read-only)

New command `cctrl helpers [--json] [--check] [--warn-sets N] [--warn-gb G]`,
implemented in `lib/helper_census.py` (same shape as `lib/release_prune.py`:
plain argv, stubbed `ps` in tests).

- Input: one `ps -axo pid=,ppid=,rss=,comm=`, plus `args=` for owner candidates only. Arguments are used to classify, never printed (they can hold tokens).
- Owner = a process whose executable is `codex` or `claude`. Label is one of a fixed set: `codex app-server (remote-control)`, `codex app-server (other)`, `codex tui`, `claude`.
- Per owner: pid, label, cctrl session name when the pid is a known pane process (from the session registry; else `-`), direct children, descendants, helper RSS, own RSS, top 5 child executable names with counts.
- `est_sets = round(direct_children / per_set)`; `per_set` = number of stdio servers the runtime's config declares, else the median child count of single-session owners, else 18.
- Flag an owner when `est_sets > N` (default 8) or helper RSS > G (default 8 GB). Human output ends with one line per flagged owner and the sentence "cctrl does not reap helpers; see README: MCP helper processes".
- Exit 0 always, except `--check`: exit 1 when anything is flagged (for the fleet watcher). A failed or empty `ps` is exit 69, not "nothing found".
- `cctrl task ls` (human mode only) prints one dim footer line when an owner is flagged. `--json` output of `task ls` is unchanged.
- No `--fix`, no kill path. A structural test asserts the module contains no `kill`, `signal`, `terminate` or `pkill`.

### D2. Lean MCP mode for terminal-owned workers

Flag `--mcp inherit|minimal|none` on `cctrl start` (also through `@shortcut`
and `launch-to-app`). Precedence: flag, then profile key
`agents.<agent>.mcp`, then `CCTRL_MCP_MODE`, then `inherit`. Unknown value:
exit 64.

What each mode starts:

| Mode | Claude | Codex |
|---|---|---|
| `inherit` | as today | as today |
| `none` | `cctrl-peer` only (when `--peer`) | `cctrl_runtime` only (tmux sessions) |
| `minimal` | `none` + the operator's keep list | `none` + the operator's keep list |

The keep list is `mcp.minimal.<agent>` (array of server names) in the cctrl
user config. Shipped default: empty, so `minimal` equals `none` until the
operator lists servers. cctrl's own servers are never removable: `cctrl-peer`
and `cctrl_runtime` are added after the lean filtering, by the existing code.

Claude: write a per-session MCP file next to the settings overlay
(`_profile_settings_dir`, mode 600, same key, suffix `.mcp.json`, removed by
`_profile_settings_gc` and the wrapper like the settings file), then pass
`--strict-mcp-config --mcp-config <file>`. The file holds `cctrl-peer` (built
with `jq`, replacing the `printf`) and, for `minimal`, the kept servers'
definitions copied from the user's Claude MCP config. A file, not argv,
because definitions can contain secrets.
Cleanup and restart (eng review REQUIRED): `_profile_settings_gc` derives the
session key with `basename "$f" .json`, so `<key>.mcp.json` would read as key
`<key>.mcp`, match no live session and be deleted after 10 minutes while the
session runs. Therefore `_profile_settings_gc` strips a trailing `.mcp` from
the key immediately after `basename`, before the `fg-<pid>` match and the tmux live check, and `cmd_restart` rewrites the MCP file
whenever the record's `mcp_mode` is not `inherit`, whatever the profile
(today it rewrites only the settings file, and only when a profile is set). Reading the user's Claude MCP config
(location and schema) is (unverified): P2 ships `none` only for Claude;
`minimal` for Claude lands in P3 after that is checked.

Codex: read the table names `[mcp_servers.<name>]` from
`$CODEX_DIR/config.toml` (names only, line scan, no TOML library: system
python is 3.9); for every name not kept, add
`-c mcp_servers.<name>.enabled=false`. argv then holds names only.
Plugin-provided servers stay on; the launch line prints
`mcp: lean (kept: cctrl_runtime; not controllable: <plugin names>)`.

Both: the resolved mode is stored on the session record through
`_session_update_metadata_field` (no new positional on
`_session_write_metadata`) and shown in `session ls --json` as `mcp_mode`.
Passthrough after `--` still wins: a caller can add its own `--mcp-config`
or `-c`.

`--mcp` other than `inherit` with `--app-owned`: exit 64, message "app-owned
threads use the app-server's MCP configuration". With `launch-to-app`: the
mode applies to the terminal phase; the result prints one line saying the
app-server owns MCP after release.

### D3. Operator documentation

README section "MCP helper processes": what a set is and what it costs
(numbers above), how to read `cctrl helpers`, what lean mode does and does
not cover, and reaping: helpers of a terminal session end with the session
(`cctrl close`); helpers of the Codex app-server end only when the app-server
or the Codex app restarts, which is the owner's decision and interrupts
running app threads. Also: one line in `skills/cctrl-fleet-manager` (add
`cctrl helpers --check` to the local-health tick) and one in
`skills/cctrl-spawn` (state the MCP mode in the brief when a worker is lean).

## Phases (each ships alone; both full suites green is the gate)

**P1. Census. [x] DONE 2026-10-08** (both full suites EXIT=0 under bash 3.2.57 and 5.3.20; Opus review changes-requested then REQUIRED applied: fixture now exercises the sets estimate; see .mstack/handoffs/2026-10-08-plan106-p1-opus-review.md). `lib/helper_census.py`, `cctrl helpers`, `task ls` footer,
README section (census part). No launch-path change.

**P2. `--mcp none` for terminal-owned Claude and Codex. [x] IMPLEMENTED 2026-10-09** (commit and install status: see the P2 notes below; the manual real-launch smoke is the orchestrator's). Flag, env, record
field, launch line, `--app-owned` rejection, `launch-to-app` notice. Before
shipping: one manual check per runtime on the Studio (launch a throwaway
lean session, compare its `cctrl helpers` row with an inherit session,
close it).

P2 as built (deviations and choices, 2026-10-09):
- `--mcp minimal` is rejected with exit 64 ("not available yet"); the plan was silent for P2. `--mcp inherit|none` and `CCTRL_MCP_MODE` work; precedence is flag > env > inherit, with the P3 profile key's seam in `_mcp_mode_resolve`.
- The mode crosses the tmux hop as `CCTRL_LAUNCH_MCP_MODE=<mode>` in the pane child's env (added only when the mode is not `inherit`; the pane child ignores `CCTRL_MCP_MODE`, which a long-lived tmux server could hold stale), never in the agent's argv. `_launch_exec_agent` captures it into `LAUNCH_MCP_MODE` and unsets both env vars before `exec`, so neither the agent nor a nested launch inherits it.
- `mcp_mode` is written to the record only when not `inherit` (`_session_update_metadata_field`; `mcp_mode` added to the provisional-receipt whitelist). `session ls --json` shows `mcp_mode` (`inherit` for a managed session without the field, `null` for an unmanaged one). `cmd_restart` reads the record, not the env.
- Claude file: `{"mcpServers":{}}` without a peer, exactly `cctrl-peer` with one; `CCTRL_PROFILE_MCP_FILE` names it for the wrapper; a failed write exits 70 and never falls back to `inherit`. Under `none` the inline peer JSON is replaced by the file; under `inherit` the inline JSON path is untouched.
- Codex: a sub-table header such as `[mcp_servers.foo.env]` names server `foo`; `cctrl_runtime` is never listed; headers with other characters are counted and printed as "not controllable: N" (plugin servers cannot be seen from `config.toml`). Lean flags come before passthrough, so a caller's `-c` wins.
- `--app-owned --mcp <non-inherit>` exits 64 with the documented message; `launch-to-app --mcp ...` prints one stderr line (human mode) that the app-server owns MCP after release.
- Not done (follow-ups): `session snapshot`/`restore` do not carry the mode, so a restored lean worker is `inherit`.
- P1 follow-up shipped here: `lib/helper_census.py` `exe_name` no longer shows a credential-shaped or `KEY=value` token, and the docstring no longer says "redaction".
- Tests: `test_launch_mcp_none_claude` (incl. the golden inherit argv), `test_launch_mcp_none_codex`, `test_launch_mcp_mode_validation`, `test_launch_mcp_detached_record_and_env`, `test_profile_settings_gc_keeps_live_mcp_file`, `test_profile_mcp_restart_and_wrapper_cleanup`, `test_launch_to_app_mcp_notice`, `test_helper_census_comm_name_safe`.

**P3. Profile key and `minimal`.** `agents.<agent>.mcp`, `mcp.minimal.<agent>`
keep list, Claude definition copy, shortcut field, help/README, completions.

**P4. Spike: app-owned threads (no code unless proven). NEEDS-OWNER: blocked on Matthew; do not run, and no worker may start it.** With a throwaway
thread, test whether `thread/start` `config` carrying
`mcp_servers.<name>.enabled=false` reduces that thread's helper set, and
whether sets are released when a thread ends. Needs the owner's OK (it
creates a thread on the live app-server). Output: a findings note and, if
positive, a follow-up plan.

## Tests

- `test_helper_census` (P1): stub `ps` fixtures: one app-server with 40 sets (flagged), a tui, a claude, an unrelated process; assert counts, labels, `--check` exit 1, exit 69 on empty/failed `ps`, and that no command-line text appears in output.
- `test_helper_census_never_kills_structural` (P1).
- `test_task_ls_helper_footer` (P1): footer only in human mode, JSON byte-identical with and without a flagged owner.
- `test_launch_mcp_none_claude` (P2): fake `claude` records argv; assert `--strict-mcp-config`, one `--mcp-config <file>`, file mode 600, file holds exactly `cctrl-peer` with `--peer` and `{}` without; `inherit` argv byte-identical to today.
- `test_launch_mcp_none_codex` (P2): fixture `config.toml` with 3 servers; assert three `enabled=false` overrides, `cctrl_runtime` overrides still present, no other change; missing `config.toml` gives no overrides and no error.
- `test_launch_mcp_mode_validation` (P2): bad value 64; `--app-owned` plus `--mcp none` 64; precedence flag > profile > env.
- `test_profile_settings_gc_*` extended (P2): the `.mcp.json` file is collected with its settings file and regenerated on restart.
- `test_profile_settings_gc_keeps_live_mcp_file` (P2): a live tmux session's `.mcp.json` and an `fg-<live pid>.mcp.json`, both older than 600 s, survive gc; a dead session's is removed.
- `test_launch_mcp_minimal_keep_list` (P3): kept names survive in both runtimes; a kept name that does not exist is a warning, not an error.
- Guard: no secret-bearing value reaches argv (assert the Claude argv contains a path, never a `{`), P2/P3.

## Ship step

Per phase: both suite logs `EXIT=0`, commit, `self-install.sh`, then
`cctrl helpers` and `cctrl session ls` rc 0 on the Studio. Update `cmd_help`,
README, CHANGELOG, completions (`helpers`, `--mcp`), the worker brief
template. P2/P3 are opt-in: no running session changes.

## Rollback

`git revert` per phase; no data migration. The `mcp_mode` record field is
additive and ignored by older code. Sessions launched lean keep their flags
until closed; closing them is the rollback for a live session. P1 has no
runtime effect to roll back.

## Risks

- A lean worker silently lacks a tool its brief assumes (for example Telegram). Mitigation: opt-in, mode shown in the launch line, `session ls --json` and the brief.
- Codex restart with stale overrides: the wrapper reuses the option list; if a server was removed from `config.toml` meanwhile, whether `enabled=false` on a now-unknown name fails startup is (unverified; it failed for a plugin name). Mitigation: the P2 manual check covers it; if it fails, regenerate the overrides on restart.
- `--strict-mcp-config` may also remove something a worker needs (Chrome integration, connectors) (unverified). Covered by the P2 manual check.
- Line-scanning TOML misreads quoted or dotted server names. Mitigation: accept only `[A-Za-z0-9_-]+`, print anything else as "not controllable".
- The census mislabels an unrelated binary named `codex`/`claude`. Report-only, so the cost is a wrong row.
- Lean mode does nothing for the measured 38 GB, which sits in the app-server. Only P1 (visibility) and D3 (operator action) address that until P4 answers.

## Decisions and open questions

Decided 2026-10-08 by the cctrl orchestrator under Matthew's delegation of 2026-10-08 15:49 UTC (approval mdec-1008-cctrl-next-work, item 5c):

1. **Decision (2026-10-08): command name.** Top-level `cctrl helpers` (read-only, no kill path, no `--fix`). Not `cctrl task helpers`, not a `session doctor` section.
3. **Decision (2026-10-08): shipped `minimal` keep list** is empty for both runtimes, so `minimal` equals `none` until the operator lists servers.
5. **Decision (2026-10-08): P4 spike is NOT run.** It touches the live Codex app-server and stays blocked on Matthew's explicit OK (needs-owner).

Still open (default applies unless the owner says otherwise):

2. **Thresholds.** Default: flag above 8 sets or 8 GB per owner. The app-server today (20 sets, 34 GB) is flagged; a normal session (1 set) is not.
4. **Should orchestrator-spawned workers become lean by default later?** Default: no change in this plan; decide after two weeks of opt-in use.
6. **Plugin-provided Codex servers.** Default: leave on and report them. A `plugins.<id>.enabled=false` override was not tested.

## Fact check (2026-10-08, at HEAD 74a8fe3, grep only)

Re-verified: no `helpers` command and no `--mcp` flag / `CCTRL_MCP_MODE` / `mcp_mode` exist in `cctrl`; `--mcp-config` appears once (`cctrl:1249`, the peer config); `lib/release_prune.py` exists as the module-shape model; `lib/peer_mcp.py` and `lib/runtime_mcp.py` exist. Process and Codex/Claude CLI measurements were not re-run (read-only `ps` not needed for the doc).

## Review history

- Eng pass 1 (Opus sub-agent, 2026-10-08): changes-requested. REQUIRED: `_profile_settings_gc` would delete a live session's `<key>.mcp.json`; restart would not rewrite it. Applied in D2 plus a new test.
- Eng pass 2 (same reviewer): changes-requested. REQUIRED: strip `.mcp` before the `fg-<pid>` match too. Applied.
- Eng pass 3 (same reviewer): approved. The `reviews:` entry below is this final verdict (`review-gate.sh record` replaces in place, so the earlier verdicts live only here).
- RECOMMENDED items left open for the implementer: exit 70 on failed MCP file write; name `CCTRL_PROFILE_MCP_FILE` and test wrapper cleanup; skip `cctrl_runtime` in the `enabled=false` list; P2 manual check terminal-only (never `--app-owned`/`launch-to-app`), tests stub `lib/codex-launch-to-app.sh` and `lib/codex_app_server.py`; tests for `session ls --json` `mcp_mode`, the `launch-to-app` notice and the plugin "not controllable" line; register new tests in both lists; note the `ps` cost of the `task ls` footer; renumber Decisions.
