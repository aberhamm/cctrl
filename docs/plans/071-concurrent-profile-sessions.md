---
id: 071
title: Run sessions on different profiles side by side
status: pending
blocked-by: []
priority: 71
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-24
tui-fixture: n/a  # launch env and metadata tests use the fake agent and fake tmux
approved-by: none  # plan only; do not implement until Matthew approves (2026-09-24)
reviews:
  - type=eng verdict=approved date=2026-09-24 by=plan-eng-review (subagent, v3 re-check)
---

## Plain-English Summary

Run a work session (Bedrock through the Portkey gateway) and a personal session (claude.ai subscription) at the same time, without one affecting the other. Each launch:
- picks its profile from a configurable default,
- clears inherited provider and Desktop env,
- applies the profile through `--settings`,
- records the profile as part of the session's identity.

Global `~/.claude/settings.json` is never written again. Profiles and user config move to `~/.config/cctrl/`, following the XDG Base Directory spec.

**Status:** plan only. Implementation waits for Matthew's go-ahead.

**Line references** date from commit 3462171 and will drift. Each one is anchored to a function name, so re-grep before editing.

## Goal
Run work (Bedrock via Portkey) and personal (claude.ai subscription) Claude sessions side by side under cctrl. Each session's provider, model, and auth are fixed at launch and recorded as its identity. Global `~/.claude/settings.json` is never mutated. MCP servers and memory stay shared.

## Decisions (final)
| # | Decision |
|---|---|
| D1 | Phased; one commit per phase; `tests/run-tests.sh` green before each commit. |
| D2 | The Desktop/host env scrub applies to EVERY cctrl launch (claude and codex, profiled or not). Escape hatch: `CCTRL_KEEP_HOST_ENV=1`. |
| D3 | Prefix scrub of exported `CLAUDE_*` and `ANTHROPIC_*`, with an explicit keep-list. |
| D4 | Scrub at launch only. Never touch the tmux server's global env. |
| D5 | Profile settings files live at `$TMPDIR/cctrl-$UID/profile-settings/` (dir 0700, files 0600). Removed by the session-wrapper `_cleanup` trap plus an orphan sweep. |
| D6 | Profile rename becomes `cctrl profile rename`. `cctrl rename` stays the session rename. |
| D7 | An inherited `CLAUDE_CONFIG_DIR` is respected (on the keep-list) and recorded in session metadata. |
| D8 | Keep phase 5 (`--settings` overlay). Docs: settings-file `env` beats the inherited process env, so only `--settings` can beat a contaminated global settings.json. |
| D9 | XDG config home. `_config_home` = `${XDG_CONFIG_HOME:-$HOME/.config}/cctrl`. Profiles are read from `$(_config_home)/profiles` first, falling back to repo `profiles/`; the XDG copy wins on a name clash, with a warning. All profile writes go to XDG (dir 0700, files 0600). `cctrl profile migrate` copies without overwriting and keeps the repo originals unless `--remove-old` is given. `cctrl use` writes `defaultProfile` to `$(_config_home)/config.json`. Per-session `--settings` files stay in the TMPDIR runtime dir (D5 + R3). |
| — | Config layering is unchanged: data/config.json < `$(_config_home)/config.json` < data/config.local.json. `cctrl current` names the file that supplied `defaultProfile` and warns when data/config.local.json overrides the user config. |
| — | New field/env name for the model backend is `auth_backend` everywhere. `provider` already means agent runtime (claude/codex) in task records (`_session_write_metadata` cctrl:2798/2830; task key cctrl:~10009; lib/cctrl_fleet_collect.py:328). |
| — | Labels (`CCTRL_SESSION_PROFILE`, `CCTRL_SESSION_PROFILE_SOURCE`, `CCTRL_SESSION_AUTH_BACKEND`) are hook/UI labels only. They never feed profile resolution. |
| — | `AWS_*` is never scrubbed. Profile settings never appear inline in argv (argv is visible via ps). |

## Facts from official docs (code.claude.com, checked 2026-09-24)
- env-vars, Precedence: "When the same variable is set in both your shell and a settings file `env` block, the settings file value applies." In `env`, `"X": ""` "is treated as unset for provider selection"; subprocesses still inherit "".
- settings: `--settings` sits above local/project/user and below managed. It "takes a key you set here over the same key ... and keeps the lower-level value for a key you omit."
- remote-control: needs claude.ai subscription auth. It fails on Bedrock, Vertex (Agent Platform) and Foundry, and whenever `ANTHROPIC_BASE_URL` is not api.anthropic.com. `--remote-control` still starts the session and shows a failure notice.
- statusline: `rate_limits` "appears only for claude.ai Pro and Max subscribers" (or behind a Claude apps gateway).

## Launch env pipeline (target)
```
tmux server env (may carry Claude Desktop leaks) ──► child: cctrl start|@x --foreground ...
caller env (foreground)                          ──┘
                                   │
                  _resolve_launch_target  (dir ─► canonical @shortcut if one matches)
                                   │
                  _resolve_profile  ─► name, source, pf   (see diagram below; fail-closed rules)
                     pf = _profile_find NAME: $(_config_home)/profiles/NAME.json
                                              else <repo>/profiles/NAME.json
                                   │
                  _resolve_agent_or_prompt (uses profile defaultAgent)
                                   │
          ┌────────────── _launch_exec_agent ──────────────────────────────────┐
          │ _launch_prepare_env agent pf name source                           │
          │   1 scrub: unset exported CLAUDE_* / ANTHROPIC_* not on keep-list  │
          │      (skipped if CCTRL_KEEP_HOST_ENV=1; AWS_* never touched)       │
          │   2 overlay: export profile env (shared + agents.<agent>.env)      │
          │   3 labels: CCTRL_SESSION_PROFILE / _PROFILE_SOURCE / _AUTH_BACKEND│
          │      (source from one-shot CCTRL_LAUNCH_PROFILE_SOURCE, then unset)│
          │   4 claude + profile: write settings file (0600, runtime dir R3)   │
          │        {model, env: profile env + "" for unused provider keys}     │
          │      LAUNCH_FLAGS += --settings <path>                             │
          │ bridge: auth_backend != subscription ─► omit --remote-control      │
          └───────────────► exec session-wrapper.sh claude|codex ... (tmux)    │
                             or exec claude|codex (foreground)                 │
                                   │
             wrapper restart: same argv + env; cmd_restart regenerates the     │
             settings file before writing the marker; _cleanup trap deletes it │
```

## Profile resolution order
```
_resolve_profile <explicit> <shortcut_profile>         (explicit may be "none")
  1 explicit --profile NAME    ── missing ─► ERROR exit 64 (fail closed)
        "none"                 ── no overlay, source=explicit
  2 shortcut .profile          ── missing ─► ERROR exit 64 (fail closed)
  3 config defaultProfile      ── missing ─► WARN, fall to 5 (source=default-missing)
        (layered: data/config.json < $(_config_home)/config.json < data/config.local.json;
         the winning file is reported by `cctrl current`)
  4 legacy .active-profile     ── read-only; WARN "run cctrl use NAME to migrate"; missing ─► 5
  5 none                       ── no overlay, source=none
Name grammar ^[A-Za-z0-9._-]+$ ; "none" reserved (save/rename refuse it).
Profile file lookup (every step): CCTRL_PROFILES_DIR if set (sole dir, for tests)
  else $(_config_home)/profiles/NAME.json  ─► hit (warn if repo copy also exists)
  else <repo>/profiles/NAME.json           ─► hit (legacy location)
  else missing
Output: name<TAB>source  where source ∈ explicit|shortcut|default|legacy|none
```
Behaviour change: today `_active_profile` returns `personal` when `.active-profile` is missing (cctrl:84-90). v2 returns `none`. On this machine `.active-profile` is `personal`, so the first `cctrl use`/migration writes `defaultProfile: personal` to `$(_config_home)/config.json` with no visible change.

---

## Phase 0: Spike (small; gates the keep-list and phase 5 merge semantics)
Throwaway `claude -p` runs with a temp `CLAUDE_CONFIG_DIR`, never the global one. Write results to `docs/findings/profile-settings-spike.md`.
1. Does `--settings <file>` `env` merge per variable with user settings.json `env`, or replace the whole `env` object? Test: user env `{A:1}`, `--settings` env `{B:2}`, then echo both in a Bash tool call.
   - If it replaces, phase 5 must copy the user's non-provider `env` keys into the generated file (secret-free keys only; document it).
2. Which leaked Desktop vars change behaviour? Candidates observed in the live tmux global env: `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`, `CLAUDE_EFFORT=high`, `CLAUDE_CODE_DISABLE_CRON`, `CLAUDE_CODE_SESSION_ATTENDED`, `CLAUDE_CODE_ENTRYPOINT=claude-desktop`, `CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH`, `CLAUDE_CODE_OAUTH_SCOPES`, `CLAUDE_CODE_ENABLE_ASK_USER_QUESTION_TOOL`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID`.
   - Output: confirm the keep-list is minimal. This is informational, since the prefix scrub removes them all anyway.

Tests: none (spike). Exit criterion: findings doc committed.

## Phase 1: Config home (D9)
Touch:
- cctrl prelude (cctrl:9, 15-20):
  - add `_config_home` (`${XDG_CONFIG_HOME:-$HOME/.config}/cctrl`; a relative XDG_CONFIG_HOME is ignored, per the XDG spec). Put a code comment at `_config_home` pointing to https://specifications.freedesktop.org/basedir-spec/latest/.
  - `CONFIG_USER_FILE="${CCTRL_USER_CONFIG:-$(_config_home)/config.json}"` replaces the hard-coded `$HOME/.config/cctrl/config.json` (cctrl:17-19).
  - `PROFILES_DIR` (cctrl:9) becomes `PROFILES_REPO_DIR="$SCRIPT_DIR/profiles"` plus `PROFILES_USER_DIR="$(_config_home)/profiles"`. `CCTRL_PROFILES_DIR`, if set, is the ONLY dir (no fallback) so tests are deterministic.
- Split `_profile_path` (cctrl:92, 17 call sites) into:
  - `_profile_find NAME`: read path. XDG, then repo; empty if missing.
  - `_profile_write_path NAME`: always XDG. Creates the dir with umask 077 and then `chmod 700`.
  - `_profile_exists` uses `_profile_find`. Name-grammar validation lives here (moved from the old phase 2 list).
- `_profile_list`: union of both dirs, XDG first. A name in both → flag `shadowed`. `cmd_ls` and `cmd_current` print `WARN: <name> exists in both; using ~/.config/cctrl/profiles/<name>.json`.
- Write paths:
  - `cmd_save` (1023) writes to `_profile_write_path`.
  - `cmd_edit` (1071): if the profile exists only in the repo dir, copy it to XDG first (0600) with a notice, then edit the XDG copy. The repo copy is now shadowed, and `ls` shows that.
  - `_profile_rename` (phase 3) renames within XDG. For a repo-only profile, it copies to the new XDG name and leaves the repo original.
  - All of these call `_profile_secure_perms` (104).
- New `cctrl profile migrate [--remove-old] [--dry-run]`:
  - for each repo `profiles/*.json`: if the XDG target exists, skip and report (`exists`, plus `identical` or `differs`). Otherwise copy via temp file + mv, chmod 600, `cmp`-verify byte-identical, and report `copied`.
  - Idempotent: a second run reports `exists identical` for every profile.
  - `--remove-old` deletes a repo original ONLY if its XDG copy is byte-identical, and never deletes one marked `differs`.
  - `--remove-old` prints a livesync warning and needs `--yes` when not on a tty (see N1).
  - Also migrates legacy `.active-profile` via the shared helper `_legacy_active_profile_migrate` (N6). The helper writes `defaultProfile` into `$(_config_home)/config.json` only if that key is unset, then removes `.active-profile`. It is idempotent, and it is the ONLY implementation, called by both `profile migrate` and the first `cctrl use`.
  - Exit non-zero if any copy failed verification.
- tests/run-tests.sh prelude (~lines 5-45): `export XDG_CONFIG_HOME="$TMPDIR/xdg"` and `unset CCTRL_PROFILES_DIR` globally (N2). Today HOME is only sandboxed for one test (lines 7-10), so an XDG default would read the real `~/.config/cctrl/profiles`. The existing real-home guard (~line 52) that watches `~/.config/cctrl` stays.
- README "Profiles": profiles live in `~/.config/cctrl/profiles/` (machine-local, not synced); run `cctrl profile migrate` once per machine (Studio and MacBook separately) before any `--remove-old`. The "Where cctrl keeps files" section is added in phase 9 (a stub is fine here).
- AGENTS.md: add one line: "Profiles and user config live in ~/.config/cctrl/ (XDG). Never write secrets into the repo's profiles/ or data/."

Tests:
- XDG_CONFIG_HOME honoured for both config.json and profiles/. A relative XDG_CONFIG_HOME falls back to `$HOME/.config`.
- Fallback: a profile only in repo profiles/ resolves.
- Clash: the XDG copy wins; `ls` and `current` show the warning.
- `CCTRL_PROFILES_DIR` is the only dir searched.
- `save` / `edit` (copy-on-write) / `profile rename` write only to XDG, at 0600 in a 0700 dir.
- migrate:
  - copies at 0600 and byte-identical.
  - second run: no changes.
  - never overwrites a differing XDG file.
  - `--remove-old` removes only identical originals.
  - `--dry-run` writes nothing.
  - migrates `.active-profile`.
- Existing profile tests (tests ~485-620, 884-907, 1024, 10077) stay green with the repo fallback.

## Phase 2: Resolver, config default, shortcut `--profile` fix
Touch:
- cctrl `_config_default_agent` (cctrl:191): add `_config_default_profile` beside it, reusing `_config_jq`.
- cctrl `_active_profile` (84) / `_detect_active` (912): replace them with `_resolve_profile` plus `_legacy_active_profile` (read-only).
- Generalise the app-owned resolver block in `_launch_app_owned_codex` (cctrl:1366-1375) into `_resolve_profile`, then call it from there.
- cctrl `_launch_detached` (3113): move the dir to shortcut adoption (`_shortcut_for_dir`, ~3422) BEFORE profile and agent resolution (~3310-3320), so a dir launch uses the matching shortcut's `.profile`.
- `cmd_start` (1451; profile fallback ~1600-1612): use the resolver.
- `_shortcut_jump` (14861):
  - add a `--profile` case to the foreground arg loop (~14982-15035).
  - resolve via `_resolve_profile "$cli_profile" "$shortcut_profile"`.
  - replace the `_active_profile` call (~15038).
- Other `_active_profile` callers switch to the resolver's default: `_default_agent_label` (307), statusline target (~13052), doctor (~14461).
- Profile file lookup goes through `_profile_find` (phase 1).

Tests (tests/run-tests.sh; the fake agent already echoes argv):
- Precedence table: 5 sources × presence (explicit > shortcut > default > legacy > none).
- `--profile none` gives no overlay.
- A missing explicit profile exits 64. A missing shortcut profile exits 64. A missing default warns and launches with none.
- REGRESSION (critical): `cctrl @x --profile work --foreground` does not pass `--profile` to the agent, and the overlay is applied.
- Launching the same repo as a dir and as @shortcut resolves the same profile and source.
- Name grammar rejects `../x`; `none` is reserved.

## Phase 3: Profile commands (D)
Touch:
- `cmd_use` (925): atomic jq write of `defaultProfile` into `$CONFIG_USER_FILE` (`$(_config_home)/config.json`). Create the dir at 0700. If the file is a symlink, write through `realpath` so a dotfiles link survives (N4). Temp file in the same dir, then mv. Remove the settings.json merge and the "Already on profile" short-circuit. On first run, call `_legacy_active_profile_migrate` (phase 1, N6); no second implementation.
- `cmd_current` (1003):
  - print the default profile, its resolution source, and the config FILE that supplied it (walk `_config_files` from highest precedence down).
  - WARN when data/config.local.json sets `defaultProfile` and so overrides the user config.
  - WARN on shadowed profile names (phase 1).
  - list live sessions grouped by profile. Before phase 6 lands this shows `unknown`.
  - WARN if the global settings.json `env` contains any `CCTRL_PROVIDER_ENV_KEYS`.
  - drop the settings-vs-profile equality check.
- `cmd_diff` (1049): `cctrl diff A [B]` compares profile to profile, or to the default. Values of keys matching `*KEY*|*TOKEN*|*SECRET*|*HEADERS*|*AUTH*|*PASSWORD*` print as `<redacted>` (covers HEALTHCHECKS_API_KEY, R4).
- `cmd_save` (1023): stop writing `.active-profile`. Refuse the name `none`.
- `cmd_ls` (980): `*` marks the configured default; add an `auth_backend` column.
- New `cmd_profile` with `rename` (and aliases `ls|use|current|diff|save|edit` delegating to the existing commands):
  - move the body of the profile `cmd_rename` (cctrl:1145) into `_profile_rename`, which writes through `_profile_write_path`.
  - `migrate` subcommand from phase 1 lives here.
  - `_profile_rename` also rewrites `defaultProfile` when it pointed at the old name.
  - delete the dead first definition.
  - dispatch: add `profile|profiles)`; remove the duplicate `rename)` line (15216 vs 15227 → keep one, pointing at the session rename).
- New shared definitions near the profile helpers (~cctrl:500):
  - `CCTRL_PROVIDER_ENV_KEYS=(CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_SKIP_BEDROCK_AUTH CLAUDE_CODE_SKIP_VERTEX_AUTH CLAUDE_CODE_SKIP_FOUNDRY_AUTH ANTHROPIC_MODEL ANTHROPIC_BASE_URL ANTHROPIC_BEDROCK_BASE_URL ANTHROPIC_VERTEX_BASE_URL ANTHROPIC_FOUNDRY_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL)`. One array, used by `current`, the phase 4 scrub keep-logic, the phase 5 "" neutraliser, and `diff`.
  - `_profile_auth_backend <agent> <pf>` returns `subscription|bedrock|vertex|foundry|api|codex`:
    - `USE_*` flags are checked first.
    - `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, or a non-api.anthropic.com `BASE_URL` → `api`.
    - otherwise `subscription`.
    - It replaces `provider_for` inside `_profile_summary` (517-546).
- README "Profiles" section rewritten; drop the legacy merge note. Add `cctrl profile` to help.

Tests:
- `use` writes `$XDG_CONFIG_HOME/cctrl/config.json` (not data/config.local.json); settings.json fixture is byte-identical (shasum before/after); a symlinked user config stays a symlink.
- `current` reports the source file; with data/config.local.json also setting `defaultProfile`, it shows that file and the override warning.
- Migration: `.active-profile` becomes `defaultProfile` in the user config and the file is removed; the same helper runs from both `cctrl use` and `profile migrate`, and whichever runs second is a no-op.
- `diff` redaction: the fixture secret value never appears in output.
- `current` warns on a fixture settings.json with `CLAUDE_CODE_USE_BEDROCK`.
- REGRESSION: `cctrl rename <session> "label"` still hits the session rename. `cctrl profile rename a b` renames the file and updates `defaultProfile`.
- `_profile_auth_backend` table: bedrock / api (key) / api (base URL) / subscription / codex.

## Phase 4: Hermetic launch env (A), T1 + D2/D3/D4/D7
Touch:
- New `_launch_prepare_env <agent> <pf> <profile> <source>`, called at the top of `_launch_exec_agent` (630) before flag assembly:
  - Scrub:
    - `if [[ "${CCTRL_KEEP_HOST_ENV:-}" != 1 ]]`: for each name from `compgen -e` (exported vars only, so internal shell arrays like `CLAUDE_HC_PATTERN` are untouched), if it matches `^(CLAUDE|ANTHROPIC)_|^CLAUDECODE$` and is not in `CCTRL_LAUNCH_ENV_KEEP`, run `unset`.
    - `CCTRL_LAUNCH_ENV_KEEP=(CLAUDE_CONFIG_DIR)` plus the optional config `launchEnvKeep` array (layered config) for user-intended vars. Comment the array with why each entry is kept.
    - The same scrub runs for codex. The prefixes don't overlap `CODEX_*`, so CODEX_HOME is untouched.
  - Overlay: call the existing `_apply_profile_overlay "$agent" "$pf"` (477), now AFTER the scrub.
  - Labels:
    - export `CCTRL_SESSION_PROFILE` (`none` if none), `CCTRL_SESSION_PROFILE_SOURCE`, `CCTRL_SESSION_AUTH_BACKEND`.
- Signature: `_launch_exec_agent` gains the profile name and source. Update both callers: `cmd_start` (1646) and `_shortcut_jump` (15103).
- Remove the caller overlays at `cmd_start` (1614) and `_shortcut_jump` (15052). Keep the narrow peer-path overlay in `_launch_detached` (~3329); it runs in the parent only to resolve `CCTRL_DATA_DIR` for peer lookup and never reaches the child.
- Detached child source handoff (R1): `_launch_detached` puts a one-shot `CCTRL_LAUNCH_PROFILE_SOURCE=<source>` into `env_q` (~3469) next to the explicit `--profile`. `_launch_prepare_env` uses it only when the child resolved source=explicit, then immediately `unset`s it. `CCTRL_SESSION_*` labels are always re-derived at launch and never read back, so a nested foreground launch inside a labelled session can't inherit a stale source.
- App-owned codex (`_launch_app_owned_codex` 1340): run the same scrub before invoking `lib/codex_app_server.py` (~1412). Label only; no settings file.
- Rollout: the CHANGELOG notes that the scrub is global and names `CCTRL_KEEP_HOST_ENV=1`.

Tests (extend `make_fake_agent`, tests/run-tests.sh:172, to print `ENV_<name>=` for a names list given in `FAKE_AGENT_ENV_NAMES`; no new dry-run flag):
- Inherited `CLAUDE_CODE_USE_BEDROCK=1` with `--profile personal`: absent.
- `--profile work` (fixture): present. This guards the scrub-then-overlay ordering.
- Inherited `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_EFFORT`, `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`, `CLAUDECODE`: absent.
- `CLAUDE_CONFIG_DIR`: kept. `AWS_PROFILE`: kept. A config `launchEnvKeep` entry: kept.
- `CCTRL_KEEP_HOST_ENV=1`: Desktop var kept.
- Codex path: `ANTHROPIC_API_KEY` absent, `CODEX_HOME` kept.
- Labels present, and the detached child keeps `source=default` via the handoff var, which is absent from the agent env.
- R1: a nested foreground `--profile work` run with inherited `CCTRL_SESSION_PROFILE_SOURCE=default` records source=explicit.
- `cmd_restart` still finds the session id (Claude sets `CLAUDE_CODE_SESSION_ID` for its own children; the scrub runs only at launch).

## Phase 5: `--settings` overlay (C), T4 + D5/D8
Touch:
- New `_profile_settings_dir`:
  - path (R3): `<runtime_tmp>/cctrl-$(id -u)/profile-settings`, where `<runtime_tmp>` = `getconf DARWIN_USER_TEMP_DIR` on macOS (stable across tmux, SSH, launchd, `--host`), else `${TMPDIR:-/tmp}`. Resolved once by `_cctrl_runtime_dir`.
  - `_launch_exec_agent` exports the full file path as `CCTRL_PROFILE_SETTINGS_FILE`. The wrapper, cmd_restart and GC use that value or `_cctrl_runtime_dir`, never a bare `$TMPDIR`.
  - create with `mkdir -p` then `chmod 700` (umask 077 subshell).
  - refuse if the dir is not owned by `$UID`.
- New `_profile_settings_write <agent> <pf> <key>` (claude only):
  - builds from the existing `_profile_overlay_json_for_agent` (499), then adds `""` for every `CCTRL_PROVIDER_ENV_KEYS` entry the profile doesn't set.
  - If spike Q1 = block-replace, also copy the global settings.json `env` keys that are NOT in `CCTRL_PROVIDER_ENV_KEYS` (R4: these can be secrets such as HEALTHCHECKS_API_KEY; same 0600 exposure as the profile; stated in the spike doc).
  - Write to a temp file in the same dir at 0600, then mv.
  - Key: tmux `$CCTRL_SESSION_NAME`, or `fg-$$` for foreground.
- `_launch_exec_agent`: when agent=claude and a profile is set, `LAUNCH_FLAGS+=(--settings "$path")`. The process-env overlay stays as belt-and-braces.
- Profile `none` gets no settings file. Its only protection is the scrub, which is accepted: with no profile, global settings apply by design.
- Cleanup:
  - lib/session-wrapper.sh `_cleanup` trap (~37-46) and normal exit remove `$CCTRL_PROFILE_SETTINGS_FILE`, exported by `_launch_exec_agent`.
  - Foreground non-tmux launches `exec claude` directly and have no owner. Orphan sweep `_profile_settings_gc`:
    - `tmux-*`: delete when no live tmux session has that name.
    - `fg-<pid>`: delete when the pid is dead.
    - Run it at every launch and in `_session_prune` (12707).
- `cmd_restart` (12158): before writing the marker, call `_profile_settings_write` from `CCTRL_SESSION_PROFILE`, so profile edits apply on restart ("fresh config").
- lib/agent_model.py: add `--settings` to `values`. It's needed only if `--settings` precedes `--model`; add it anyway.

Tests:
- File and dir modes (0600/0700) under a stubbed `_cctrl_runtime_dir`.
- R3: GC run with TMPDIR unset scans the same dir the launch wrote to.
- Argv contains the path and no profile secret value (grep the fake-agent ARG lines for a fixture secret).
- An unused provider key is written as "".
- The wrapper trap removes the file (drive `session-wrapper.sh` with a fake claude that exits).
- GC removes the file for a dead fake session and keeps it for a live one.
- `cmd_restart` regenerates the file.
- `agent_model.py`: `claude --settings /p --model opus ...` → `opus`.

## Phase 6: Profile as session identity
Touch:
- `_launch_detached`: pass explicit `--profile <name|none>` into the child args (it already does so when explicit, ~3190; extend to every resolved source). The labels from phase 4 carry source and backend.
- `_session_write_metadata` (2778): new args and fields:
  - `profile`, `profile_source`, `auth_backend`, `requested_model` (CLI or profile model, null if none), `claude_config_dir` (D7, null if not inherited; R5: metadata only, no env label), `profile_file` (the resolved path, i.e. XDG or repo; a path, never contents).
  - `provider` is NOT touched.
  - Store empty as JSON null (prior learning: jq `//` does not fall through "").
  - Sequence after the in-flight worker's task-record merge change lands; extend its per-execution field tuple rather than adding a second block.
- Task-record merge (inline python ~cctrl:2190-2235, `merged = incoming; merged.update(record)`): the stored record wins, so a resumed conversation relaunched under another profile would keep the OLD profile. Add `profile`, `profile_source`, `auth_backend`, `requested_model`, `claude_config_dir` and `profile_file` to the per-execution field set that a newer cctrl launch overwrites. That set is the same block the in-flight worker change adds for terminal anchors (~2218-2230). Coordinate with that change.
- tmux: `@cctrl_profile` and `@cctrl_auth_backend` beside `@cctrl_agent` (3500). Metadata stays authoritative; the options are a display hint (prior learning: tmux options are restorable, mutable state).
- lib/snapshot_restore.py `launch_flags_for` (70): prefer the metadata `profile` field, falling back to parsing `launch_command`.
- Realign: `_session_realign_cmd` (10786) and `_session_realign` (~10800) build the argv from metadata through `launch_flags_for` (profile, model, peer, no-bridge, agent) rather than hand-adding `--profile`.
- `cmd_restart`: in-place only (the wrapper reuses argv and env); no change beyond phase 5.
- Pre-change sessions: no `profile` field means display `?`, and the profile name is never guessed (phase 7's bridge state may be `na-inferred`; that's a bridge state, not a profile).

Tests:
- A detached launch writes all six fields plus the tmux options; `provider` is still `claude`/`codex` (guard).
- Snapshot → restore replays `--profile work` for a default-sourced profile (extend `test_restore_launch_config_replay`, tests ~6034-6058).
- The realign cmd contains `--profile work --model X --peer p` from fixture metadata (`CCTRL_DOCTOR_RELAUNCH_LOG` seam).
- The merge test: resuming a record under profile B updates `profile` to B.

## Phase 7: Bridge awareness (single classifier first)
Touch:
- New `_session_bridge_state <name> <cmd>` returns `live|dead|off|collision|na|unknown|-` and is the only classifier. Replace:
  - `_session_rc_state` (9292) → delete it or make it a thin alias.
  - the inline block in `_session_list` (~9652-9660).
  - the inline verdict in `_session_doctor` (~10890-10906; keep its collision/alignment extras layered on top of the shared state).
- Rules:
  - agent is not claude: `-`.
  - no `--remote-control` in argv: `off`.
  - metadata `auth_backend` ≠ subscription: `na`.
  - pre-change session (no metadata `profile` field): if there's no bridge, inspect the claude pid's env with `ps eww -o command= -p <pid>` (macOS shows same-user env; verified). Match only `CLAUDE_CODE_USE_(BEDROCK|VERTEX|FOUNDRY)=(1|true)` as a key=value test inside the tool, and never store or print other env content. A match → `na-inferred`; no match → `dead`; ps unreadable → `unknown` (R2).
  - An argv `--model` heuristic is NOT used (work.json passes `--model sonnet`; the Bedrock id lives in env).
- `_launch_exec_agent` (bridge block ~690): skip `--remote-control` when `auth_backend` ≠ subscription, unless the profile sets `"bridge": true`. Reuse the existing `no_bridge` plumbing.
- `_session_doctor --fix` and `_session_autoheal` (11506): only `dead` is repairable. `na`/`na-inferred` render as `n/a (<backend>)`; `unknown` is skipped with a reason.
- README "Sessions" + skills/cctrl-fleet-manager doc: document the new states.

Tests:
- Fixture Bedrock session (metadata `auth_backend=bedrock`, argv has `--remote-control`, no bridgeSessionId) → `na` in ls, doctor, and autoheal. No `/rc` is sent (fake tmux log).
- Pre-change fixture (no profile field, fake `ps` env with `CLAUDE_CODE_USE_BEDROCK=1`) → `na-inferred`, skipped. Unreadable fake `ps` → `unknown`, skipped. Plain pre-change with no bridge → `dead`, healed.
- The fake `ps` output contains a fixture secret, which never appears in ls, doctor, or JSON output.
- Subscription dead still heals (existing autoheal tests stay green).
- ls, doctor, and autoheal agree on the same fixture.

## Phase 8: Fleet UI + telemetry, T5
Touch:
- `_session_list` (9534):
  - read `profile` and `auth_backend` in the EXISTING per-record jq read (9607; add two fields, not a new jq call).
  - PROFILE column: `personal`, `work·bedrock`, or `?`.
  - `--json` adds `profile`, `profile_source`, `auth_backend`.
- lib/cctrl_fleet_collect.py: add `profile` and `auth_backend` to `LEGACY_FIELDS` (28) and to the task-row normaliser (~325-336). `agent` keeps coming from `provider`.
- needs-me / task ls / repo status: pass the fields through where they render rows (grep for `display_label` in those renderers).
- hooks/statusline.sh (44-66):
  - label from `CCTRL_SESSION_PROFILE`, else `unknown` (never the configured default, and never `.active-profile`).
  - prefix `[work·bedrock]` when `CCTRL_SESSION_AUTH_BACKEND` ≠ subscription.
  - the rate-limit write is already gated on `rate_limits` presence (41), which the docs say is subscription-only; keep that and add the label.
- Stop runner (`cmd_hooks run stop`, ~13256-13258): capture stdin once (`input=$(cat)`) and pipe it to both `notify.sh stop` and `session-log.py`.
- hooks/session-log.py:
  - read hook JSON from stdin and log ONLY that `session_id`/`transcript_path`. Delete the `find_recent_sessions` 120s rglob (28-40), which mislabels concurrent sessions and walks all of ~/.claude/projects every turn.
  - profile and auth_backend come from env, else `unknown`.
- Optional, low priority: lib/usage_costs.py splits cost by auth_backend using the model-id prefix (`us.anthropic.`/`anthropic.` = Bedrock).

Tests:
- `session ls` golden output with mixed profiles plus a pre-change `?` row; `--json` fields.
- statusline: fixture input without `rate_limits` plus a Bedrock label env gives the prefix and no rate-limit file write. Unset label gives `unknown`.
- REGRESSION (concurrency): two fixture transcripts touched within 120s; the hook stdin names one; only that one is logged, with the env profile.
- The stop runner delivers the same stdin to notify.sh and session-log.py (fake scripts record their input).

## Phase 9: Docs + live smoke
- README "Where cctrl keeps files" section. Name and link the XDG Base Directory Specification (https://specifications.freedesktop.org/basedir-spec/latest/) once. Table:
  | What | Path | Role |
  |---|---|---|
  | user config | `$XDG_CONFIG_HOME/cctrl/config.json` (default `~/.config/cctrl/config.json`) | config |
  | profiles | `$XDG_CONFIG_HOME/cctrl/profiles/*.json` (0600; repo `profiles/` is a legacy fallback) | config |
  | per-session `--settings` files | `$(getconf DARWIN_USER_TEMP_DIR)cctrl-$UID/profile-settings/` (TMPDIR fallback off macOS) | runtime state; fills the XDG_RUNTIME_DIR role, which macOS doesn't provide |
  | sessions, mailbox, shortcuts, config.local | repo `data/` | state, unchanged for now (livesynced on purpose) |
  | cost logs | repo `costs/` | state, unchanged for now |
  Overrides: `XDG_CONFIG_HOME`, `CCTRL_USER_CONFIG` (user config file), `CCTRL_PROFILES_DIR` (sole profiles dir, mainly for tests).
  One line: "~/.config isn't synced between machines, so run `cctrl profile migrate` on each Mac, both before `--remove-old`."
- AGENTS.md: the XDG/no-secrets line (added in phase 1; verify it's present).
- CHANGELOG entry: profiles and user config moved to `~/.config/cctrl` (XDG), `cctrl profile migrate` (with `--dry-run`/`--remove-old`), `defaultProfile` via `cctrl use`.
- README Profiles + Sessions, CHANGELOG (global scrub + `CCTRL_KEEP_HOST_ENV`, `cctrl profile rename`, `cctrl profile migrate`, XDG profiles dir, `defaultProfile` in the user config), skills cctrl-spawn / cctrl-fleet-manager ("spawn with --profile").
- Live smoke on the Studio, after Matthew approves, using throwaway sessions:
  0. Run `cctrl profile migrate` on the Studio AND the MacBook, without `--remove-old`. `cctrl ls` shows no shadow warnings.
  1. `cctrl start -d <scratch> --profile work` and a personal session run concurrently.
  2. `/status` in each shows the expected model and provider.
  3. `session ls` shows both profiles; doctor shows `n/a (bedrock)` for work and `live` for personal.
  4. The personal pane title carries the TMUX id (Desktop `DISABLE_TERMINAL_TITLE` scrubbed).
  5. `cctrl restart` on work stays Bedrock.
  6. Snapshot, close both, restore: each comes back on its own profile.
  7. Global settings.json shasum and `defaultProfile` are unchanged; the runtime profile-settings dir is empty after close; `~/.config/cctrl/profiles/*` are 0600.

## Order
```
P0 ─► P1 ─► P2 ─► P3 ─► P4 ─► P5 ─► P6 ─► P7
                                        └─► P8 ─► P9
```
Everything is serial because it all lands in the single `cctrl` file. After P6, the hooks and lib parts of P8 can run in a parallel worktree.

## Updated test diagram
```
[P1] config home   XDG honoured/relative ignored [T] | repo fallback [T] | clash XDG wins+warn [T]
                     PROFILES_DIR sole [T] | writes to XDG 0600/0700 [T] | edit copy-on-write [T]
                     migrate copy/verify/idempotent/no-overwrite/remove-old/dry-run/.active-profile [T]
                     harness XDG isolation (N2) [T]
[P2] resolver        precedence x5 [T] | none [T] | fail-closed explicit/shortcut [T] | default-missing warn [T]
                     dir==@shortcut [T] | shortcut --profile REGRESSION [T] | name grammar/none reserved [T]
[P3] commands        use -> user config (+symlink) [T] | current source file + local override warn [T]
                     use ≠ settings.json [T] | migrate [T] | diff redact [T] | current warn [T]
                     rename dispatch REGRESSION [T] | profile rename + defaultProfile [T] | auth_backend table [T]
[P4] prepare_env     personal strips BEDROCK [T] | work keeps (ordering) [T] | Desktop prefix gone [T]
                     keep-list/CLAUDE_CONFIG_DIR/AWS kept [T] | KEEP_HOST_ENV [T] | codex [T] | labels+source [T]
                     nested source re-derived R1 [T]
                     restart session id [T]
[P5] settings file   0600/0700/TMPDIR [T] | no secret argv [T] | "" neutraliser [T] | wrapper trap [T]
                     GC live/dead [T] | GC with TMPDIR unset R3 [T] | restart regen [T] | agent_model --settings [T]
[P6] identity        fields + tmux opts [T] | provider unchanged guard [T] | restore default-sourced [T]
                     realign from launch_flags_for [T] | merge newer-launch profile [T]
[P7] bridge          na [T] | na-inferred via ps env R2 [T] | unknown unreadable [T] | no secret echo [T] | ls/doctor/autoheal agree [T] | subscription heals [existing]
[P8] UI/hooks        ls golden [T] | json [T] | statusline label/unknown [T] | session-log concurrency REGRESSION [T]
                     stop stdin tee [T] | rate_limits absent no write [existing statusline.sh:41]
[P9] E2E             concurrent /status | title | restart | snapshot/restore | settings untouched  [→E2E manual]
Planned: 58 unit/integration + 8 E2E steps; 4 regressions marked.
```

## Failure modes (v3)
| Codepath | Failure | Test | Handling | Visible |
|---|---|---|---|---|
| scrub vs overlay order | work session silently runs on the subscription | P4 ordering test | order fixed in `_launch_prepare_env` | covered |
| prefix scrub | a user-intended CLAUDE_* var dropped | keep-list test | `launchEnvKeep`, `CCTRL_KEEP_HOST_ENV` | CHANGELOG |
| `--settings` env block-replace | HEALTHCHECKS_* lost | spike Q1 | copy non-provider keys | covered after P0 |
| settings file orphan | secret at rest | GC test | trap + GC | covered |
| TMPDIR shared/owned by another user | read or planting | dir-owner check | refuse to launch | loud |
| merge keeps old profile on resume | wrong label and restore profile | merge test | per-execution fields | covered |
| resolver typo | wrong credentials | fail-closed test | exit 64 | loud |
| hooks with no label | old sessions relabelled | unknown test | `unknown` | covered |
| Bedrock pre-change session | autoheal spams /rc | na-inferred test | skip | covered |
| ps env scan | leaks env secrets into output | no-echo test | key=value match only | covered |
| XDG vs repo clash | stale repo copy silently used | clash test | XDG wins + warn | loud |
| tests read real ~/.config/cctrl | secrets in test runs / flaky | harness isolation | XDG_CONFIG_HOME sandbox | covered |
| `migrate --remove-old` + livesync | other machine loses repo profiles before it migrates | refuse-without-yes test | warning + `--yes`, identical-only | loud |
| user config.json is a symlink | dotfile link replaced by a plain file | symlink test | write through realpath | covered |
Critical gaps remaining: 0 on paper. They depend on the P4 ordering test, the P5 GC, and the P8 stdin binding landing as specified.

## NOT in scope
- Separate CLAUDE_CONFIG_DIR per profile (option B): deferred by user.
- Per-profile MCP/memory: not needed now.
- tmux global env cleanup: D4, rejected.
- Portkey key rotation: do now, separately.
- Stale TMUX--ms--cctrl--2 metadata.
- personal pinning `claude-opus-4-6[1m]`.
- usage_costs backend split: optional, low priority.
- Splitting the cctrl source (TODOS.md).

## What already exists (reused)
- `_config_jq`/`_config_default_agent` (156-205) and `CONFIG_USER_FILE` (17-19, already `~/.config/cctrl/config.json`): layered config; phase 1 only swaps in `_config_home`.
- `_profile_secure_perms` (104): the 0600 helper for every profile write.
- The test real-home guard (run-tests.sh ~52) already watches `~/.config/cctrl`.
- The app-owned resolver (1366-1375): becomes `_resolve_profile`.
- `_profile_overlay_json_for_agent` (499): builds the settings JSON.
- `no_bridge` plumbing (630/690): phase 7 skips the bridge through it.
- `launch_flags_for` (snapshot_restore.py:70): realign and restore share it.
- `make_fake_agent` (tests:172), `CCTRL_RESTORE_LAUNCH_LOG`, `CCTRL_DOCTOR_RELAUNCH_LOG`: test seams.
- session-wrapper `_cleanup` trap: settings-file owner.
- statusline's `rate_limits` presence gate: already subscription-only.

## Follow-ups (TODO)
- Restart marker path uses a bare `${TMPDIR:-/tmp}` (cctrl:733/797). Move it to `_cctrl_runtime_dir` (same issue as R3).
- TODOS.md entry (not in scope): consider moving `data/` state (sessions, mailbox, costs) to `$XDG_STATE_HOME/cctrl`. Blocked on livesync, which syncs that data between machines on purpose, and on how many fleet code paths it touches.

---

## Quick re-check of v3 (2026-09-24, read-only, spawned; no AskUserQuestion)
D9 is folded in as a new Phase 1 (old phases 1-8 are now 2-9). R1-R5 are folded into the phase text. These issues surfaced while checking D9 against the source; each is already addressed in the text above:
- N1 [P1] (conf 8) `migrate --remove-old` vs livesync: the repo `profiles/` dir is livesynced, so deleting the originals on the Studio also deletes them on the MacBook, possibly before the MacBook has migrated. The other machine then has no profiles. Handled: identical-only removal, a warning, `--yes` required off-tty, and the README/runbook say to migrate on both machines before `--remove-old` on either.
- N2 [P1] (conf 9) The test harness only sandboxes HOME for one test (run-tests.sh:7-10), so an XDG default would read the real `~/.config/cctrl/profiles`. Fixture names (work, personal, home, team) would then be shadowed by the real, secret-bearing files. Handled: a global `XDG_CONFIG_HOME="$TMPDIR/xdg"` plus `unset CCTRL_PROFILES_DIR` in the harness prelude.
- N3 [P2] (conf 8) `_profile_path` (cctrl:92) serves both reads and writes across 17 call sites. Handled: split into `_profile_find` (read) and `_profile_write_path` (XDG write). `cmd_edit` on a repo-only profile copies it to XDG first.
- N4 [P2] (conf 6) The user config may be a dotfiles symlink, and the temp-file + mv write would replace the link. Handled: write through `realpath`.
- N5 [P3] A relative XDG_CONFIG_HOME is ignored, per the spec. Handled.
- N6 [P3] (conf 7) `.active-profile` migration appeared in two places (phase 1 `profile migrate`, phase 3 first `cctrl use`). Now folded: one shared `_legacy_active_profile_migrate` helper called by both (phase 1/3 text).
- Check: `CONFIG_USER_FILE` already defaults to `~/.config/cctrl/config.json` (cctrl:17-19), so phase 1 only swaps in `_config_home` and XDG. No layering change, as D9 requires.
- Check: `~/.config/cctrl` does not exist on this host yet. The first `use`/`migrate` creates it at 0700.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | issues_found | 16 findings on v1, all folded |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 3 | clean (v3 quick re-check) | v1: 17 issues, 3 critical, folded. v2: R1-R5, folded. v3: N1-N6 (2 P1, 2 P2, 2 P3), all folded incl. N6; docs addendum (XDG file-locations section, AGENTS.md, CHANGELOG, TODO) added; 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **CROSS-MODEL:** No new tension. The v1 phase-4 tension was resolved by D8.
- **VERDICT:** ENG CLEARED (PLAN v3). Ready to implement, starting with Phase 0 then Phase 1 (config home). Land Phase 6 after the in-flight worker's task-record merge change.

NO UNRESOLVED DECISIONS
