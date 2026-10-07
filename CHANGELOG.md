# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased] - 2026-10-02

### Added
- `cctrl profile migrate [--dry-run] [--remove-old]` copies repo-tracked
  `profiles/*.json` into the new XDG profiles dir (`~/.config/cctrl/profiles/`,
  override with `XDG_CONFIG_HOME`), byte-verified and 0600, and migrates a
  legacy `data/.active-profile` into `defaultProfile` in
  `~/.config/cctrl/config.json`. It never overwrites a differing XDG copy;
  `--remove-old` deletes only byte-identical repo originals and needs `--yes`
  off a tty, since the repo `profiles/` dir may be livesynced across
  machines — migrate on every machine before removing originals on any one
  of them. `cctrl profile <ls|use|current|diff|save|edit|migrate>` now also
  works as an alias namespace alongside the existing top-level verbs. (plan
  071 phase 1)

### Added (plan 100, phase 1: roles)
- Sessions and shortcuts have a `role` (`orchestrator | worker`) and, for
  orchestrators, an `orch_kind` (`fleet | repo`): `cctrl start -d ... --role X
  --orch-kind Y [--succeeds NAME] [--no-input]`, `cctrl @add ... --role/--orch-kind`
  (an existing entry's role fields are kept on re-add), `cctrl session set-role
  <session> worker | orchestrator --orch-kind K | --clear`. Recorded in the session
  record and the `@cctrl_role` / `@cctrl_orch_kind` tmux options, shown in
  `session ls --json` and `peer ls --json`, carried in snapshot `launch_flags` and
  replayed by `session restore` and `session doctor --fix` (replay never asks).
- When the orchestrator kind is ambiguous cctrl prompts at a terminal and
  otherwise exits 78 with `cctrl: needs-user-decision: orchestrator-kind` as the
  first stderr line, nothing launched. Remote launches resolve the role with a
  read-only `_role-resolve` preflight and forward explicit flags; the remote side
  runs with `CCTRL_NO_INPUT=1`.
- `cctrl session restore` now prints `<session>: <first stderr line>` for a row
  whose launch failed.

### Changed (plan 100, phase 1)
- A plain `cctrl start -d <dir>` no longer adopts an `orch-*` shortcut (or any
  orchestrator shortcut: by role, with `fm-*` / `orch-*` keys as the legacy
  fallback). Visible effect today: `-d ~/dev/rentkompass` is named
  `TMUX--<host>--rentkompass` instead of `TMUX--<host>--orch-rentkompass`; a
  restore of that live session before the later naming phase also comes back under
  the worker name. No other session name or label changes in this phase.
- `session doctor --fix` (realign) now keeps the session's recorded tmux name.
- A cctrl tmux launch that states a role replaces the recorded role on the
  conversation's record (including `-r <id>` launches).
- `--role` / `--orch-kind` / `--succeeds` are rejected with exit 64 on foreground,
  `--app-owned` and `launch-to-app` launches. `session set-role --orch-kind
  fleet` has no one-fleet-manager guard until the next phase.

### Added (plan 100, phase 2: names, labels, the guard)
- New launches are role-named: a fleet manager is `TMUX--<host>--fleet-<runtime>`
  (label `★★ fleet manager (<runtime>)`), a repo orchestrator
  `TMUX--<host>--orch-<repo>` (label `★ orchestrator: <repo>`); workers are
  unchanged. An explicit `-n` / `--purpose` wins and gets the star once; an
  orchestrator never takes a prompt-derived label. `cctrl rename` keeps the star
  of a known-kind orchestrator. Existing sessions are not renamed or relabelled.
- One fleet manager per runtime per machine: a second `--orch-kind fleet` launch
  exits 65 (name-atomic; `fleet-<runtime>` is the lock, never an index suffix;
  a launch lock with pid and age checks guards the race). `--succeeds <session>`
  hands over beside exactly one live predecessor and relabels it `☆ ... handing
  over`. `CCTRL_ALLOW_SECOND_FLEET_MANAGER=1` overrides (env only, unset before
  tmux starts). `restore` / `doctor --fix` bypass the guard.
- `cctrl session set-role --relabel`; `set-role --orch-kind fleet` goes through
  the guard. `cctrl session ls` footers for unknown-kind orchestrators and for
  two live fleet managers. A remote orchestrator launch injects no default
  purpose. The Codex app title skips its repo prefix for a star label.

### Changed (plan 100, phase 2)
- A repo orchestrator launch is no longer named like a worker: `@fm-cctrl` is now
  `orch-cctrl`, not `cctrl`. A restore or realign never renames: it reuses the
  recorded tmux name (next free `--N` if a live session holds it), so the new
  names apply only to fresh launches.

### Fixed (plan 102)
- `cctrl release prune` hardening, all fail closed (exit 69, nothing deleted,
  dry run and `--apply`): a `current` that is dangling or not a direct child of
  `releases/` is a scan error; the `ps` and `lsof` scans must each show the
  tool's own pid (exact match); a missing data or bin dir is a scan error (the
  lazily-created settings-overlay dir stays optional); the python module no
  longer accepts flag abbreviations.

### Added (plan 089)
- `cctrl release prune [--keep N] [--apply] [--json]`: manual, dry-run-by-default
  pruning of old releases under `~/.local/lib/cctrl/releases` (default keep 5,
  newest by build time). Always keeps `current`, the launcher target and any
  release still referenced by a live process (argv, open files, cwd), live
  session registry records, a `--settings` overlay, `~/.local/bin` or the user's Claude/Codex
  config; fails closed (exit 69, nothing deleted) when a reference scan cannot
  complete; deletes only exact direct-child release directories and never
  touches partial or unrecognised entries. Not run by `self-install.sh`.

### Fixed
- `cctrl session restore` honours `CCTRL_RESTORE_MAX_ACTIVE` again (default 8):
  restores beyond live + planned tasks reaching the cap are deferred as
  `insufficient-evidence`. The cap silently stopped working in the
  ownership-aware restore rewrite. (plan 097)

### Internal
- 28 restore/snapshot tests that had been defined but never called since the
  ownership-aware restore rewrite are registered again (fixtures ported to the
  v2 evidence model); 3 tests of removed behaviour were deleted. New guard
  `test_every_defined_test_is_registered` fails the suite when a `test_*`
  function is defined but never called. (plan 097)

### Changed
- Profiles and the user config move to XDG: `~/.config/cctrl/profiles/*.json`
  and `~/.config/cctrl/config.json` (both overridable — `CCTRL_USER_CONFIG`,
  `CCTRL_PROFILES_DIR`, or `XDG_CONFIG_HOME`). The repo's `profiles/` dir is
  now a legacy read fallback only: a same-named profile in the XDG dir always
  wins, and `cctrl ls`/`cctrl current` warn when a name exists in both.
  `cctrl save` and `cctrl edit` (copy-on-write for a repo-only profile) write
  only to the XDG dir, at 0600 in a 0700 directory. (plan 071 phase 1)
- Launch-time profile resolution now follows one explicit precedence —
  explicit `--profile` > a matched shortcut's `.profile` > the configured
  `defaultProfile` > the legacy `.active-profile` (read-only, warns to
  migrate) > none — used consistently by `cctrl start`, `cctrl @<shortcut>`,
  and `start --app-owned`. An unknown explicit or shortcut profile now fails
  closed (exit 64) instead of silently launching without it; an unknown
  configured default warns and falls through to none. Fixes a regression
  where `cctrl @<shortcut> --profile <name> --foreground` fell into the
  argument parser's catch-all and leaked `--profile <name>` straight into
  the agent's own argv while still applying the shortcut's own profile
  instead of the requested one. A detached `cctrl start -d <dir>` whose
  directory matches a configured shortcut now also adopts that shortcut's
  profile (previously only its session name/alias was adopted). (plan 071
  phase 2)
- `cctrl use` only writes `defaultProfile` into `~/.config/cctrl/config.json`
  now — it no longer merges a profile's model/env into
  `~/.claude/settings.json`, and no longer writes the legacy
  `data/.active-profile` (a pre-existing legacy file is migrated to
  `defaultProfile` the first time `cctrl use` or `cctrl profile migrate`
  runs). `cctrl ls`/`cctrl current` mark the configured default from this
  resolver, not the legacy file, and `cctrl ls` adds an auth-backend column.
  `cctrl current` names the config file that supplied `defaultProfile`, warns
  when `data/config.local.json` overrides the user config or when
  `~/.claude/settings.json`'s `env` sets a provider key, and lists live
  sessions (grouped under `unknown` until plan 071 phase 6 adds per-session
  profile metadata). `cctrl diff <profileA> [profileB]` now diffs two
  profiles (or a profile vs. the configured default) instead of a profile vs.
  `settings.json`, with credential-shaped env values redacted. `cctrl save`
  refuses the reserved name `none` and no longer writes `.active-profile`.
  Profile renames move to `cctrl profile rename <old> <new>` (plain `cctrl
  rename <name> "label"` was already, and remains, the session rename). (plan
  071 phase 3)
- Every launch (`cctrl start`, `cctrl @<shortcut>`, detached, and
  `--app-owned` Codex) now scrubs every exported `CLAUDE_*`/`ANTHROPIC_*`/
  `CLAUDECODE` env var inherited from the caller's shell or a leaky tmux
  server env, then applies the resolved profile's overlay on top — so a
  profile's own values always win, and an unprofiled launch never silently
  inherits a stray provider var leaked from elsewhere (e.g. Claude Desktop).
  `CLAUDE_CONFIG_DIR` is always kept; add more names to keep with
  `launchEnvKeep` in config (`~/.config/cctrl/config.json` or
  `data/config.local.json`). `CCTRL_KEEP_HOST_ENV=1` skips the scrub
  entirely. Every launch also now exports `CCTRL_SESSION_PROFILE`,
  `CCTRL_SESSION_PROFILE_SOURCE`, and `CCTRL_SESSION_AUTH_BACKEND` as
  hook/UI labels (they never feed profile resolution). A shortcut's own
  `.profile: "none"` is now an explicit no-overlay, matching `--profile
  none`, instead of failing closed as an unknown profile name. (plan 071
  phase 4)
- `cctrl restart` regenerates the session's `--settings` profile overlay
  file from its current profile before restarting, so a `cctrl profile
  save`/`use` edit actually takes effect on the restarted agent instead of
  the stale file the original launch wrote. If that regeneration fails (a
  refused or unwritable profile-settings dir), it warns and continues with
  the existing file rather than silently aborting the restart. (plan 071
  phase 5)
- A session's resolved profile is now part of its recorded identity, not
  just its launch argv: metadata gains `profile`, `profile_source`,
  `auth_backend`, `requested_model`, `claude_config_dir`, and `profile_file`,
  set for every detached launch (explicit, shortcut, config default, or
  none) rather than only the dir-adopts-a-shortcut's-profile case. `cctrl
  session ls`/fleet's `@cctrl_profile`/`@cctrl_auth_backend` tmux options
  mirror it as a display hint; metadata stays authoritative. A resumed
  conversation relaunched under a different profile now updates the stored
  identity instead of keeping the old one. Restore's `launch_flags_for`
  prefers a session's own recorded `profile` field over re-parsing
  `launch_command`, falling back to the old argv parse for pre-change
  records. `session doctor --fix`'s realign now carries the old session's
  profile/model/peer/no-bridge forward through the same resolver, instead of
  hand-adding only the corrected `--name`/`--resume` and silently dropping
  the rest. Known, accepted behavior: a realign or restore replay records
  the carried-forward profile's `profile_source` as `explicit` (it replays
  it as a literal `--profile` flag) rather than preserving the original
  session's shortcut/default/legacy source — the profile name itself is
  still correct, this is cosmetic. (plan 071 phase 6)
- `session ls`/`session doctor`/`session autoheal` now share one
  remote-control bridge classifier (`_session_bridge_state`), adding `na`
  (the session's profile uses a non-subscription backend — Bedrock, Vertex,
  Foundry, or a direct API key/token — which can't authenticate the app
  bridge), `na-inferred` (a pre-071 session with no recorded profile, no
  bridge, and a non-subscription provider var found in the claude process's
  own env), and `unknown` (same pre-071 case, but that env read couldn't be
  confirmed) alongside the existing `live`/`dead`/`off`/`collision`/`-`.
  Only `dead` is ever repaired by `doctor --fix` or autoheal; the new states
  are always skipped. Launch itself now skips `--remote-control` for a
  non-subscription backend unless the profile sets `"bridge": true`
  (`_profile_bridge_override`), so new sessions on those backends land
  straight in `na` territory instead of `dead`. (plan 071 phase 7)
- `session ls` gets a PROFILE column (`personal`, `work·bedrock`, `none` for
  an explicit `--profile none` no-overlay record, or `?` for a genuinely
  pre-071 record that never had a `profile` field at all) and `--json`
  carries `profile`/`profile_source`/`auth_backend` through; `cctrl task ls
  --json` and `cctrl fleet` gain the same `profile`/`auth_backend` fields.
  The statusline now shows a `[profile·backend]` prefix sourced from the
  launching session's own `CCTRL_SESSION_PROFILE`/`CCTRL_SESSION_AUTH_
  BACKEND` (never the configured default or the legacy single-machine
  `.active-profile` file), only when the backend isn't the subscription
  default. `hooks/session-log.py` now logs only the transcript the Stop
  hook's own stdin names (with the launching profile/auth_backend from
  env), instead of rglobbing every `~/.claude/projects/*.jsonl` touched in
  the last 120s — which could misattribute token usage between two
  concurrent sessions on different profiles. `cctrl hooks run stop` now
  captures that stdin once and tees it to both `notify.sh` and
  `session-log.py` (previously the second script always got nothing, since
  the first one being a `cat` already drained the pipe). (plan 071 phase 8)

- README gains a "Where cctrl keeps files" table (XDG config/profiles vs.
  the per-session `--settings` runtime dir vs. unchanged livesynced repo
  state) and `cctrl-spawn`/`cctrl-fleet-manager` document spawning a worker
  on its own `--profile` alongside other live sessions. (plan 071 phase 9,
  docs only; all 9 phases implemented and installed — live smoke still
  pending Matthew's go-ahead)

- `launch-to-app` is a new opt-in Codex compound workflow: create the normal
  detached cctrl/tmux owner, prove the exact provider identity (including
  guarded launch-ID recovery), attest it, and delegate the single-writer
  transition to `release-to-app`. `--keep-terminal-owned` verifies the same
  identity while deliberately retaining tmux ownership. Existing `start` and
  `session attach` behavior is unchanged. (plan 082)
- `task resolve-conflicts [--apply] [--json]` settles stale ownership
  conflicts from live evidence. A record whose pane is gone while another
  execution holds its tmux name is closed (`stale-anchor`). A record whose pane
  now runs another conversation is closed (`superseded-by`). A record whose
  pane runs exactly its task gets cctrl ownership back (`live-owner`). Codex
  changes also need App Server confirmed-absence. It is dry-run by default;
  `--apply` re-collects evidence and every write is guarded by the digest the
  decision was made against. (plan 070 S5)
- Stop a listed tmux execution through `session stop-exact` with its opaque
  `execution_id`. Exact server and session checks reject stale or reused names.
- Inspect local and cross-host coding-agent tasks with `task ls` and
  `fleet --json-v2`, including provider identity, ownership, lifecycle, and
  per-action capabilities. Stable task records and a locked event reducer
  preserve concurrent observations and expose ownership conflicts.
- Launch Codex tasks directly in the app with `start --agent codex --app-owned`,
  observe lifecycle events through additively installed hooks, and reconcile
  exact task ownership with `session reconcile-codex`. App Server calls use
  bounded transport and capability checks.
- Preview and perform an explicit single-writer terminal-to-app handoff with
  `session release-to-app`. Ownership-aware snapshots restore only authorized
  terminal workers; app tasks remain provider-managed references.
- Recover a provisional terminal receipt with `session recover-terminal-identity`,
  read-only by default. Recovery requires exact live process/root-rollout proof,
  atomically preserves its evidence, and refuses existing canonical destinations.
  Lossy historical commands additionally require a verified original launch event.

### Changed
- The bundled `cctrl-spawn` and `cctrl-fleet-manager` skills now document the
  shared fleet approvals contract (`~/.local/state/fleet/approvals.md`), so a
  worker can verify a scope-widening pasted follow-up against a recorded
  grant instead of trusting the paste on its own, and every new seed brief
  carries the contract by default. (plan 096)
- `cctrl start -d` answers Claude Code's folder-trust dialog with "Yes, I trust
  this folder". The health check moves the selection off the default
  "No, exit" and presses Enter only after the screen shows "Yes" selected. If
  it can't select it, it reports `needs-human` and presses nothing. The
  external-imports dialog and Codex's directory trust are still left to you.
  (plan 072)
- Spawn and fleet skills honor explicit provider selection and configured
  preferences for workers and reviewers. Agent-aware profiles isolate model
  settings, while explicit CLI model flags take precedence.
- Codex rollout discovery is bounded and leaves ambiguous identity unknown.
  Resource checks count managed tmux sessions without scanning transcripts.
  Model labels conservatively report command evidence rather than prompt text.

### Fixed
- `cctrl ls`/`cctrl current`'s `WARN: <name> exists in both; using
  ~/.config/cctrl/profiles/<name>.json` now stays silent once the repo
  and XDG copies are byte-identical (the normal post-`profile migrate`
  state) — it still prints when the two copies genuinely differ. No
  other WARN, precedence, or deletion behavior changed (plan 099).
- Only fleet-manager shortcuts get an `fm-` session name now. `cctrl start
  -d <dir>`'s reverse shortcut lookup (`_shortcut_for_dir`) picked the
  alphabetically-first key on a dir collision, and `fm-*` sorts before
  most plain names (`fm-homelab` < `homelab`), so a plain directory launch
  sharing a dir with a manager's own shortcut was silently named — and
  profiled — as that manager. The lookup now excludes `fm-*` keys
  entirely: a dir launch names from the first non-`fm-` match, or the dir
  basename if only `fm-` key(s) match. An explicit `cctrl @fm-<x>` launch
  is unaffected (plan 098).
- `cctrl restart`'s background agent kill no longer uses an untargeted
  `tmux display-message -p '#{pane_pid}'`. With `TMUX` unset (e.g. a test
  harness, or any caller outside a pane) that resolved to the default tmux
  server's *current* session and SIGTERMed an unrelated session's agent — in
  one incident, the session running the test suite itself. The agent pid is
  now resolved synchronously, before the marker is written, from this
  process's own verified ancestry (walking up to the pane process of the
  session `_session_current_name` confirms we're actually inside, requiring
  that pane to be `session-wrapper.sh`); if nothing qualifies, it warns and
  schedules no kill, leaving the marker so the next normal exit still
  restarts. The delayed kill re-checks the pid's parent before firing, to
  guard against pid reuse during the 3s window. The profile-settings orphan
  sweep (`_profile_settings_gc`) now skips entirely when `tmux list-sessions`
  fails (tmux missing, timed out, or a different socket — all of which look
  identical to "session absent" otherwise) and only removes a
  confirmed-absent session's file once it's at least 10 minutes old. The test
  harness now runs every `tmux` call against a private, initially empty
  server (`TMUX_TMPDIR` under a short `/tmp/...` path, since macOS's
  `AF_UNIX` `sun_path` is 104 bytes) and a new guard test
  (`test_tmux_default_server_is_private`) statically fails on any other
  untargeted `tmux display-message` in `cctrl`/`lib/*.sh`. See
  `docs/findings/tmux-untargeted-default-server.md`. (plan 071 phase 5)
- `_display_path` (the `~`-for-`$HOME` display helper used by `cctrl current`,
  `ls`, `profile migrate`, etc.) no longer leaks the REAL process's home
  directory when a caller runs cctrl with a different `$HOME` (every test
  fixture that sandboxes it; also any real invocation where `$HOME` differs
  from the inherited one). The bug: on bash >= 4.x (Homebrew bash 5, first on
  `PATH` on this fleet) an unquoted `~` in a parameter-expansion's
  *replacement* text is itself tilde-expanded against the live `$HOME`,
  rather than kept as a literal character — bash 3.2 doesn't do this, which
  is how it went unnoticed. (plan 071 phase 3)
- `cctrl` no longer aborts silently under bash >= 4.1 (e.g. Homebrew bash 5,
  now first on `PATH` on some hosts). A bare `((x++))` whose old value is 0
  evaluates to 0 and returns exit 1 under `set -e`, so several counters and
  scan loops (the remote-shortcut purpose scan, peer `--as`/`--from` flag
  scans, `session sync-titles`) could abort the whole command silently. The
  install gate's own silent-abort failure mode now has a named test too, so a
  future regression fails loudly instead of looking like host load. (plan 094)
- Codex panes now stop cleanly on a bare `tmux kill-session` or
  `respawn-pane -k`, not only through cctrl's own `kill`/`close`/
  `stop-exact` paths. The session wrapper runs Codex as a waited background
  child so its SIGHUP trap can escalate SIGTERM -> SIGKILL the same way it
  already does for Claude, instead of leaving Codex and the wrapper
  orphaned. (plan 076)
- `peer send --as` now refuses to send when the caller is inside a tmux
  session but its own identity can't be resolved (e.g. a stale or inherited
  `CCTRL_SESSION_NAME`), instead of silently treating "unresolvable" the same
  as "not in tmux at all" and letting the send through. (plan 091)
- The advisory-only git-commit hook's docstring and `cctrl hooks run` help
  text no longer overclaim that it blocks disallowed commands — the wording
  now matches that it only warns; no hook wired through `hooks run` exits 2
  today. (plan 088)
- `session close`/`kill`/`stop-exact` reaper hardening: the process snapshot
  and the kill now resolve the same session id instead of a prefix match in
  one path and an exact match in another; SIGCONT now precedes the delayed
  SIGTERM so a stopped process can act on it; the wrapper's SIGKILL now also
  kills the agent's descendant processes (MCP servers, tool processes); and a
  malformed `CCTRL_WRAPPER_TERM_GRACE` no longer skips signalling the agent.
  (plan 087)
- Fixed a regression from plan 086: `session ls` could show an idle session
  as `unsent-draft` (and autoheal would skip it) when its pane's only visible
  divider was tmux's own titled pane-border-status line. The single-border
  fallback now scopes the composer from the last glyph-start before that
  border, not the first. (plan 093)
- The unsent-draft detector now judges every composer line up to the bottom
  border, not just the first, so a wrapped or multi-line draft — or one that
  starts with placeholder-looking text — is still recognized. A composer
  that can't be found at all (a bash prompt, a pager, a crashed shell) now
  gets its own exit code so autoheal treats it as unverifiable instead of
  guessing. (plan 086)
- Remote `session attach` no longer risks the remote shell re-expanding an
  exact `=NAME` tmux target as a filename glob; the `=` is now escaped in
  the remote command string, not just shell-quoted. A malformed `pane_id`
  read from a launch baseline can no longer target the wrong pane. (plan 085)
- `session prune`/`mark-closed` and the provisional-close path got several
  fail-open corrections found in review: a transcript read or `grep` error
  no longer counts toward "never-prompted" in the destructive-prune
  classifier, a freshly launched session now gets the same 300s startup
  grace against a premature `mark-closed` that snapshot/restore already had,
  and a provisional close now honors the same digest guard a canonical close
  does. (plan 084)
- `session snapshot` (and `session restore --from latest`, and the doctor's
  timer staleness check) now default to `${CCTRL_DATA_DIR:-data}/snapshots`
  instead of always writing the real `data/snapshots`, so a test or script
  that sets `CCTRL_DATA_DIR` but forgets `--dir` can no longer touch the live
  store. The now-redundant static lint enforcing `--dir` on every test call
  is removed. (plan 078)
- Review fixes for plan 074:
  - A failed process snapshot no longer aborts `session kill`, `close` or
    `stop-exact`. The kill proceeds and a warning is printed.
  - Processes that survive the reap are reported as a warning, not an error,
    so `session prune --yes` no longer stops at the first such session.
  - The reap grace defaults to 12 s, longer than the wrapper's 10 s, so an
    agent's shutdown isn't cut short.
  - Start times are read with `LC_ALL=C TZ=UTC0`, so the tmux-server job
    matches them regardless of locale.
- The unsent-draft detector recognises placeholder text only at the start of
  the composer, so a typed draft containing words like "lib/ for" or "for
  commands" is no longer missed. That miss could have let autoheal's `C-u`
  erase the draft. The detector also parses colon SGR sub-parameters
  (`\e[4:3m`) and OSC 8 links ended by ST. If the detector fails, autoheal
  skips the session as `unverifiable-input` instead of treating the composer
  as empty. (plan 073 review)
- Closing a session no longer leaves its wrapper and agent running. On tmux
  hangup, `lib/session-wrapper.sh` stops a Claude agent with SIGTERM and then
  SIGKILL after `CCTRL_WRAPPER_TERM_GRACE` (10 s); before, it waited forever
  on an agent that didn't exit. Codex runs in the foreground and isn't covered
  by the wrapper (follow-up plan 076). `session kill`, `session close`
  (immediate and delayed) and `session stop-exact` record the pane's process
  tree before the kill and make sure it exits: SIGTERM, then SIGKILL after
  `CCTRL_CLOSE_REAP_GRACE` (12 s), matching on start time so a reused pid is
  never signalled. A delayed close of the last session reaps from a detached
  helper, because the tmux server exits with its run-shell job. (plan 074)
- `session ls` no longer reports `unsent-draft` for an empty composer. The
  draft detector reads the pane with escapes (`capture-pane -e`), ignores
  Claude Code's dimmed ghost suggestion (SGR 2) and the reverse-video cursor,
  and judges only the last prompt line (the composer), not submitted messages
  in the transcript above it. Autoheal's draft gate uses the same detector.
  (plan 073)
- A delayed `session close` (`--in N`, or a session closing itself) records
  the end from the tmux-server job that performs the kill, not from a
  background process started by the closing pane. The recorder can no longer
  die with the pane it is closing. If the session id can't be resolved, close
  warns and points to `session mark-closed` instead of skipping silently.
  (plan 070 re-review P3)
- `task resolve-conflicts` fails closed when a live Claude process has no
  readable session file: that process might be running the task, so nothing
  is closed. Claude Code launched through `node` (npm installs) is recognised
  as Claude. (plan 070 re-review P3)
- Snapshot rows for tmux sessions that are not live now carry their
  `launch_flags` too, so a capture taken while restore is only partly done
  still has what restore replays. The metadata index is read once per
  capture. A record owned by the Codex app no longer makes a cctrl record on
  the same dead tmux name ambiguous. (plan 070 re-review P3)
- Snapshot retention never prunes the newest history file by age. Because
  history is now written only on change, the newest file can be old and still
  be the last known state. (plan 070 review P3)
- `task resolve-conflicts` never closes a record whose conversation is running
  anywhere. Before closing it checks command lines and every live Claude
  process's session file, so a conversation resumed with `/resume` or
  relaunched in another pane is no longer closed as `stale-anchor` or
  `superseded-by`. (plan 070 review P2)
- `session kill` and `session close` record a task as `closed` only after the
  tmux kill succeeds. A failed kill leaves the records untouched and exits
  non-zero. A delayed close (`--in N`, or closing from inside the session)
  records the end once that exact tmux session is gone, via a detached waiter,
  instead of before the kill runs. When no record is anchored to the killed
  pane but older records still claim the name, the command says so and points
  to `session mark-closed`. (plan 070 review P2/P3)
- For a tmux name that is not live, which is the normal state after a reboot,
  `session snapshot` no longer lets catalogue order decide which record
  represents it. An ended record never hides the open one. Several open
  records claiming the name make the row `ambiguous-tmux-claim` (not
  restorable), with the others listed in `shadowed_task_ids`. (plan 070 review P1)
- `task resolve-conflicts` closes a Codex record only when the App Server
  confirms the app is not running that task (`confirmed-absence`). An
  `ambiguous` answer is still enough to hand a live pane back to cctrl, the
  same rule as `reconcile-codex`, but never enough to close. (plan 070 D6)
- The first `session snapshot` after a reboot no longer replaces the last good
  `latest.json`. With no tmux session live, the capture still holds surviving
  registry rows, so it slipped past the empty-fleet guard. `session restore`
  would then have started from it by default. A capture with no live session
  now goes to history only when `latest.json` has live sessions;
  `--allow-empty` overrides. (plan 070 D7)
- `task resolve-conflicts` never touches tasks owned by the Codex app. It
  accepts the App Server's `ambiguous` answer (the inventory answered with no
  live app-owner fact) as "the app is not writing", the same rule
  `reconcile-codex` uses. Before this it closed app-owned tasks whose old tmux
  pane was gone, and left live Codex conflicts unresolved even with the App
  Server running. (plan 070 S5)
- The post-spawn health check no longer reports "ready" while Claude Code or
  Codex waits on a startup selector. Covered: Claude's folder-trust and
  external CLAUDE.md import dialogs, Codex's directory trust dialog, and any
  selector footer ("Enter to confirm", "Press enter to continue"). Each is
  reported as `needs-human` with the dialog named. The message says which
  option keeps the session, because the default choice quits or denies. None
  of these dialogs is auto-answered. Peer delivery and dialog detection share
  the same patterns, so messages are no longer pasted into these dialogs.
  (plan 072)
- Relaunching a task in a cctrl terminal after handing it to the Codex app, or
  after it was recorded closed, takes ownership back (`cctrl-reclaim`
  evidence) instead of merging into an ownership `conflict`. A relaunch older
  than the handoff still conflicts. A pane-anchor receipt no longer promotes a
  legacy name-keyed record. That promotion gave an older conversation the live
  pane's anchor, which made two records contradict each other on one pane.
  (plan 070 S4)
- `session kill`, `session close`, and `session stop-exact` record the task as
  `closed`, so `session restore` no longer resurrects sessions ended on
  purpose. `kill --keep-restorable` opts out. The new
  `session mark-closed <name> [--apply]` backfills sessions that ended earlier;
  it is dry-run by default and refuses live names. Closed and archived tasks no
  longer claim their old tmux name, so a session reusing the name is not an
  ownership conflict. (plan 070 S3)
- `session snapshot` no longer grows without bound. On the live fleet a capture
  went from 40 MB to about 100 KB. The changes:
  - Labels are capped at 200 characters, with a hash of the full title.
  - Discovery-only Codex tasks are counted rather than stored.
  - A history file is written only when the restore-relevant `content_digest`
    changes.
  - History is capped by count and bytes.
  - A capture over `CCTRL_SNAPSHOT_MAX_BYTES` (default 5 MB) is refused with
    exit 69 and the existing files are kept. (plan 070 S2)
- `session snapshot` records the conversation actually running in a tmux
  session when several registry records claim the same name. The live
  session's provider id decides; if no record matches it, the row is marked
  `ambiguous-tmux-claim` and is never restorable. Rows it doesn't pick are
  listed in `shadowed_task_ids`. A cctrl/tmux/active record whose pane is gone
  is no longer labelled `already-live`. (plan 070 S1)
- The test suite's "did not touch the real live store" guards ignore
  `data/rate-limits.json` and `data/rate-limits-history.jsonl`. Live Claude
  sessions' statusline hook rewrites them every few seconds, which failed the
  suite whenever any session was active.
- Detached Codex sessions started with `--resume <id>` resume that task instead
  of opening a new one with the id as the first prompt. In-place restarts keep
  Codex `-c` config options and no longer resend the initial prompt.
- Relaunching an existing task under a different tmux session moves its record
  and name index to the new session, so `session ls` no longer shows another
  task's provider, purpose, or state for a reused tmux name.
- The read-only tmux inventory (task list, snapshots) parses sessions on
  tmux 3.7, which prints control-character field separators as `_`; every
  session was previously rejected and snapshots always reported degraded.
- Updating cctrl while it runs is now safe. `cctrl` and the session wrapper
  are each parsed as a single unit that ends in `exit`. A partially written
  file, such as one read during a git checkout, now fails before running
  anything; a cut at a function boundary used to exit 0 silently. A
  long-lived process also no longer executes bytes rewritten into its file
  after launch.
- `start -d` now reports a session ready only once the agent's input prompt is
  on screen, with no numbered selector such as Codex's update prompt. It used
  to report "ready" after 3 seconds of a blank, still-booting pane. An agent
  that exits during startup now fails the launch with its exit status and
  error output instead of printing "detached session started". The session
  wrapper keeps that pane open briefly (`CCTRL_EARLY_EXIT_HOLD_SECONDS`) so
  the error stays readable.
- Deliver long multi-line `session say`, `peer say`, nudge, and inline bodies
  exactly. Pastes now use bracketed paste with LF preserved, so newlines no
  longer reach Claude Code as Enter presses that split and dropped the message
  and swallowed the submit. Paste buffers are unique per invocation, and the
  Claude socket adapter no longer appends a newline to the payload.
- Restore passes the snapshot provider explicitly and refreshes exact Codex
  ownership immediately before each launch, including later restore waves.
- App handoff preserves provider writer-lock files after ownership transfer.
- Secret detection cannot be overridden by a legacy scanner fallback.
- Codex sessions no longer inherit stale Claude model, bridge, recency, or recap
  metadata. Prompted identity discovery cannot silently reuse an unrelated ID.
- Fresh launches save all terminal anchors atomically before provider identity
  is known. Unicode prompts survive detached-command serialization on older Bash.
- Snapshot restore explicitly selects each task's provider and rechecks exact
  Codex ownership before every launch, including after confirmation and wave
  pauses, so a newly app-owned task is not resumed as a second terminal writer.
- App Server proxy initialization uses validated WebSocket framing, with explicit
  legacy JSONL selection. Malformed tmux snapshots no longer imply absence, and
  ambiguous terminal evidence cannot authorize an app-only ownership claim.

### Internal
- Test-only: the three private-socket tests now unlink their own tmux socket
  file after `kill-server` (which doesn't remove it on this host), and a
  guard now catches any test that leaves a stray socket behind. (plan 095)
- Test-only: the "tests didn't touch the real live store" guard now names
  which paths changed on failure instead of reporting a bare pass/fail, and
  tolerates only known registry-churn files, so a flake caused by other live
  fleet sessions on a shared dev machine is distinguishable from a real
  leak. (plan 090)
- Test-only: fixed an intermittent full-suite teardown failure (a non-empty
  `$TMPDIR` at exit) in the `launch-to-app` workflow test; confirmed plan
  082's shared launch-code edits are safe for plain `cctrl start -d` too, not
  only the new compound workflow. (plan 092)

## [Unreleased] - 2026-09-17

### Added
- A deterministic `codex-ownership-matrix` integration group now exercises the
  three supported Codex ownership paths against the versioned lifecycle fixture
  boundary: native app observation, cctrl app-owned creation, cctrl/tmux launch,
  contested-writer refusal, verified release-to-app, provider-neutral fleet
  display, and ownership-aware snapshot restore.

### Changed
- README, CLI help, zsh completions, and the bundled spawn/end/fleet skills now
  share one ownership contract. `--remote unix://` is explicitly a terminal TUI
  transport, not simultaneous desktop-app access; app `+` tasks are observed
  only after creation; and only authorized terminal workers may be restored
  after reboot.

## [Unreleased] - 2026-08-23

Cross-machine messaging, session self-restart, portable hooks, and session
name reconciliation — four features that make the fleet work across machines
and survive config changes without losing conversation context.

### Added
- **Cross-machine peer messaging** (951f45f, 58ac604): `cctrl peer send`
  now routes transparently across machines via SSH. Remote peers appear in
  `cctrl peer ls` with their host label; no special flags needed. Sessions
  launched with `--peer` auto-register the peer MCP server so agents have
  peer tools available (the prior gap that caused agents to fall back to
  Claude Code's local-only SendMessage).
- **Session self-restart** (e09909f): `cctrl restart` lets an agent restart
  itself to pick up config changes (MCP servers, CLAUDE.md, settings, hooks).
  The conversation context is preserved via `--resume`. A new session wrapper
  (`lib/session-wrapper.sh`) runs as the tmux pane process and re-launches the
  agent on restart. Works for both Claude Code and Codex.
- **Portable hook installation** (53994fb): `cctrl hooks run <name>` resolves
  hooks via `$PATH` instead of absolute paths. `cctrl hooks install` writes
  configs for both Claude Code and Codex using portable commands.
  `cctrl hooks doctor` validates the setup. Moving cctrl to a different
  directory no longer breaks hooks.
- **Session name reconciliation** (53a6993): `cctrl rename <session> "label"`
  updates the display name across cctrl metadata, tmux, and Claude Code's
  transcript (syncs to desktop and iOS). `cctrl session reconcile-names`
  detects drift between Claude's UI and cctrl, correcting automatically
  (Claude wins by default; explicit `cctrl rename` wins explicitly).
- **Auto-generated session titles** (b0c1892): sessions started with `-m`
  get short, descriptive titles generated from the initial prompt via a
  local LLM (configurable endpoint) or a heuristic fallback.

### Changed
- AGENTS.md peer contract now documents cross-machine routing and warns
  against using Claude Code's built-in SendMessage/ListAgents for peer
  messaging (those are local-only).
- The `send_message` MCP tool description now mentions cross-machine
  capability.

### Fixed
- Peer MCP server was never registered on `--peer` sessions — agents had no
  peer tools and fell back to Claude Code's local-only messaging (58ac604).
- Stale comment in cross-host peer routing corrected (4ce9f94).

<!-- commits: 53a6993, 53994fb, b0c1892, cb56c55, e09909f, 58ac604, 4ce9f94, 951f45f -->

## [Unreleased] - 2026-08-06

### Added
- **Persisted `conversation_id`** (plan 051): session records now carry a
  `conversation_id` field (Claude's `sessionId` / transcript UUID) and
  `transcript_path`, both surviving process death. Populated at launch time for
  `--resume` launches and by a best-effort background poll for fresh launches.
  `session ls` and `session doctor` refresh the stored value when they observe a
  non-empty live value that differs from the record. Records with no recoverable
  UUID carry `null`.
- `cctrl session backfill-ids [--dry-run] [--apply] [--json]`: backfill
  `conversation_id` on all session records from `--resume`/`-r` UUIDs in the
  record's `launch_command`. Anchored on the flag (never matches bare UUIDs in
  paths). Reports three counts: filled, already-set, unrecoverable. Dry-run is
  the default.
- `_session_update_metadata_field`: read-modify-write of a single field via
  same-dir `mktemp` + `mv` for atomicity. Never creates a partial record.
- `cctrl session snapshot [--dir PATH] [--allow-empty] [--json] [--quiet]`
  captures the live fleet to `data/snapshots/latest.json` plus a timestamped
  history file, with atomic writes, an empty-fleet guard that preserves the
  last good snapshot when the fleet is empty (e.g. at boot), and retention
  pruning (7 days full, then daily up to 90). A `contrib/launchd/` template
  runs it every 5 minutes so the fleet state survives an unplanned power loss.
  `session doctor` warns when the timer is not installed or snapshots are stale.
- `cctrl session restore [--from PATH] [--only PATTERN] [--dry-run] [--limit N]
  [--yes] [--stale-ok] [--force-host] [--json] [--quiet]` reads a fleet
  snapshot and respawns sessions by resuming their conversations (plan 053).
  Human-in-the-loop: waves are operator-released (interactive) or gate-paced
  (`--yes`), never inferred from pane state. Launch configuration (model,
  permission-mode, peer, profile, etc.) is replayed from the snapshot.
  Idempotent: re-run the same command to continue where you left off.

### Fixed
- `_active_session_count` now counts only managed sessions (was counting all tmux
  sessions including unmanaged ones).
- Failed session metadata writes now show a warning on all launches, not just
  `--peer` launches.

## 2026-07-31

Peers became addressable as live agents, not just mailboxes: direct tmux chat by
peer name, a one-call orientation command, atomic reply, and an inline delivery
that no longer dead-ends the message lifecycle. Plus a docs and help-surface
catch-up, and a cost-reporting fix for anyone whose username isn't the author's.

### Added
- `cctrl peer say <peer> [--no-submit] [--force-busy] [--body-file PATH|-]
  [--json] -- <message>` is direct **live tmux chat** addressed by peer name or
  alias — the peer-addressed form of `session say`, sharing all its flags and its
  readiness/modal guard. It never writes `data/messages.jsonl`, never changes
  mailbox status, and never records nudge metadata. The companion
  `cctrl peer session <peer> [--json]` resolves a peer to its backing session
  (`{ok, name, label, session, tmux_target, host, live, status}`) and
  `cctrl peer attach <peer>` attaches to it. A peer whose `.host` is not this
  machine is refused with a `cctrl --host <host> peer …` hint rather than
  auto-SSHing from registry metadata, and human `cctrl peer ls` now shows each
  peer's backing SESSION with live/offline status by default (JSON unchanged).
- `cctrl peer overview [--as NAME] [--json]` is the orientation entry point: one
  call answers who you are, who you can reach, and whether you have unread mail
  (`{queued, delivered_unacked, oldest_queued_age_seconds}`), served from a
  single session enumeration instead of composing `whoami` + `list_peers` +
  `check_messages`. A matching `peer_overview` MCP tool passes through to it, and
  all eight pre-existing peer MCP tool descriptions were rewritten as
  workflow-aware instructions that cross-reference their siblings — no tool names
  changed.
- `cctrl peer reply <message-id> [--as NAME] [--subject TEXT]
  [--body-file PATH|-] [--no-ack] [--json] -- <body>` sends, delivers, and acks
  the original in one command, resolving the recipient from the referenced
  message's `sender` snapshot — so a replying agent never needs the sender's
  address. `cctrl peer send` gained `--deliver` for the same send-then-nudge
  behavior. Both report five named outcomes rather than failing silently:
  `sent-and-nudged` and `sent-and-queued` (exit 0), `send-failed`,
  `sent-but-undelivered`, and `sent-but-deferred` (non-zero). A delivery failure
  never rolls the send back — the message stays queued and the hint says to retry
  **delivery only**, because re-running would duplicate it. `--allow-unknown`
  cannot be combined with `--deliver`. MCP `send_message` now delivers too and
  surfaces the same five states, with only `send-failed` mapping to `ok:false`.
- `cctrl peer help-agent [--as NAME] [--json]` prints the compact agent-facing
  contract: when to `peer say` (live tmux agent, act now), when to `peer send`
  (durable async), and the `peer recv` / `peer ack` loop. A bare invocation gives
  generic guidance and never fails for a missing identity; `--as` or
  `CCTRL_PEER` canonicalizes through the same resolver the mailbox uses and
  tailors the examples. The contract is deliberately **not** auto-injected —
  `cctrl start --peer` adds no prompt text, so an agent gets it only by asking.
- MCP tool `say_peer` (`to`, `body`, optional `submit` defaulting true, optional
  `force_busy`) — the tool-call form of `cctrl peer say`. The body is piped
  through `cctrl peer say --body-file -` so multi-line and trailing-newline
  bodies survive byte-for-byte. It creates no mailbox message and fails rather
  than queueing when the peer has no live local tmux session.
- The peer operating contract now lives in `AGENTS.md` (with a `CLAUDE.md`
  routing pointer), not only in README — agents auto-load the former and not the
  latter.

### Changed
- `cctrl start -d <dir>` adopts a matching shortcut's alias for the session name,
  so `cctrl start -d ~/dev/unstructured-data-portal` and `cctrl start -d @portal`
  produce the identical `TMUX--<device>--portal` name and therefore the identical
  remote-control bridge prefix. On collision the first key by sorted order wins
  (deterministic). A directory with no matching shortcut keeps its repo-folder
  slug, foreground launches are unaffected, and duplicate-name auto-increment
  still runs afterward.
- `cctrl help` now lists the verbs the messaging and maintenance loops actually
  depend on and previously omitted: `peer overview`, `peer check`, `peer recv`,
  `peer reply`, `session say`, `session autoheal`, `session ls --recap`, and
  `start --profile` — the last being the flag the README leads with.
- `cctrl fleet`'s local resource header renders an unmeasurable probe as an
  explicit `n/a` instead of a bare `?`, so "this platform can't measure it" no
  longer reads as "the value is broken". The unit suffix travels with the number
  and is dropped alongside it. The Darwin `sysctl` parsing is unchanged.
- README documents the surface that shipped over the last month: `session
  doctor` / `autoheal` / `prune`, `session ls --recap` and the rich STATE column
  (with a sample regenerated from a fixture fleet rather than hand-written),
  `cctrl fleet`, `cctrl needs-me`, the low-memory launch guard, peer messaging in
  the feature list, and the fact that `ports` and `scan` are plugins rather than
  core commands.

### Fixed
- `cctrl costs` no longer hardcodes one machine's username when naming projects.
  `claude_project_name` matched the literal strings `-Users-matthew--projects-`
  and `-Users-matthew-`, so on any other machine — or any other home directory —
  every Claude project fell through to its raw encoded path. The encoded `$HOME`
  prefix is now derived at runtime, and `codex_project_name` lost its matching
  hardcoded `~/_projects/` special case.
- `cctrl peer deliver <peer> --inline <message-id>` no longer strands the message
  as `queued` forever. Inline delivery previously pasted the raw body with no
  sender context and never transitioned status, so `cctrl peer ack` — which
  rejects queued messages — could never complete the lifecycle. The paste now
  carries a compact envelope (sender label and canonical name, message id,
  optional subject, and ready-to-run `peer reply` and `peer ack` lines) and moves
  the message to `delivered` with a `delivered_at`. Sender reachability is
  resolved at delivery time: live and mailbox-only senders get a reply line, a
  dead or unresolvable one gets `SENDER IS NO LONGER LIVE` and no reply command,
  and a `from == "user"` sender routes the reply out of band. The body still
  arrives byte-for-byte after a `---` separator, and legacy messages carrying only
  a bare `from` fall back to that.
- `cctrl peer say` rejects `--as` and `--from` at the peer-say level with a
  message pointing at `cctrl peer send`, instead of forwarding them to the
  internal `session say` and leaking `Unknown session say flag: --as`. `peer say`
  has no sender identity, so the flags were never meaningful. The flag scan stops
  at `--`, so a message body that mentions `--as` is not misread.
- `peer session`, `peer say`, and `peer attach` report their own failures again.
  The first two called the resolver bare under `set -e`, so an unresolvable,
  remote, or stale peer aborted `cctrl` before the error JSON or message printed;
  `peer attach` returned the exit status of its error-printer (always 0), so a
  non-local or unknown peer printed the hint and exited **successfully**.
  `peer session` also stopped colorizing the name, so `name -> target` is one
  contiguous copyable string.
- `cctrl save`, `cctrl rename`, and `cctrl edit` force profiles to mode `600`.
  There was no `chmod` anywhere in `cctrl`: `save` wrote through a plain shell
  redirect and landed at the ambient umask, commonly `0644`. Profiles routinely
  carry `PORTKEY_API_KEY` and `ANTHROPIC_CUSTOM_HEADERS`, so a live key was
  readable by every local account — for about two and a half months. `rename`
  carried the source mode across with `mv` and `edit` lost the mode to
  write-and-replace editors, so all three write paths needed it.

<!-- commits: a028d2b, d77d4f6, ad314dd, ee048b2, d0464c5, be93bd0, b90d621, 1ec2638, 55de8ee, f7db9ab, d82260b -->

## [Unreleased] - 2026-07-26

Direct session messaging, durable sender identity on peer mail, bundled role
skills, and a cost-reporting correction.

### Added
- `cctrl session say <session> -- "message"` pastes an exact message straight
  into a live tmux session and submits it, without touching peer mailbox state
  — the direct live-chat path alongside `peer send`'s durable async mailbox.
  `--no-submit` skips the Enter, `--body-file PATH|-` sends multi-line bodies,
  and `--json` reports `{ok, session, submitted, status}`. A visible
  Claude/Codex approval modal is a hard stop that `--force-busy` won't override.
- Peer messages now carry a `sender` snapshot (name, label, tmux target, agent,
  host), so you can still tell who wrote a message after the sending session
  has closed — previously `from:` held only an ephemeral tmux name that became
  unresolvable. `peer show` and the inbox render the sender's label; legacy
  messages without the snapshot still display.
- Three bundled skills, invocable from any repo: `cctrl-spawn` (launch a
  managed session properly — runtime choice, detached-create then attach, brief
  seeding, boot verification, resource gate), `cctrl-session-end` (wind a
  session down cleanly: pre-close checklist, harvest what only that session
  knows, then self-close), and `cctrl-fleet-manager` (orchestrate many
  concurrent sessions under a two-mode autonomy model). All are
  environment-agnostic; pair them with a private brief for host specifics.

### Changed
- `cctrl-fleet-manager` doctrine (1.1.0) folds in three operational lessons:
  verification runs in both directions (verify triage claims before writing
  them into a dispatch brief, and write briefs so the receiving agent may
  refuse a wrong order); the brief is the only guardrail, since spawned
  sessions typically run with permissions bypassed, so every prohibition must
  be written in explicitly; and the `unsent-draft` session state carries no
  signal in either direction — only a pane or transcript read confirms whether
  a real draft is sitting in the input line.

### Fixed
- `cctrl` now actually detects an unsent draft in a Claude Code pane. The
  detector anchored on ASCII `>` while Claude Code's input line starts with `❯`
  (U+276F), so it never fired on a real pane — leaving two consumers silently
  inert: `session autoheal`'s draft safety gate ran unguarded (a scheduled
  `C-u` could wipe typed-but-unsent text), and the `unsent-draft` state never
  appeared in `session ls`. An empty input box still never reads as a draft.
- Cost reporting no longer overstates Opus spend by ~3x. The pricing table was
  still on Opus 4.1-era rates ($15/$75 per M tokens); Opus 4.5 through Opus 5
  are all $5/$25, with cache at $6.25/$0.50. Haiku was likewise still on Haiku
  3.5 rates and is now Haiku 4.5 ($1/$5, cache $1.25/$0.10). Because the rate
  keys match on model-name prefix, historical Opus 4.x rows are repriced too.

<!-- commits: 805299d, 42b097f, 943df6a, 8fa8086, 128854b, 1b10a29, e81c290, 9895abb, d7e539e, 7f7cd1e -->

## [Unreleased] - 2026-07-04

Session-title enforcement and a launch-time memory guardrail, both from a
fleet-management incident where friendly names hid the tmux session id and
too many heavy sessions exhausted RAM.

### Added
- `cctrl start` now enforces the tmux session id in every Claude Code pane
  title. The `--name` that reaches the agent is always the resolved tmux
  session id (`TMUX--…`); when a `--purpose`/`-n` description exists the title
  leads with it, e.g. `Plan: reference mstack plans by name (TMUX--ms--mstack)`,
  falling back to the bare id otherwise. The remote-control prefix and
  `session doctor` name-alignment continue to use the bare id.
- A friendly `-n`/`--name` on `cctrl start -d` is now recorded as the session
  **purpose** (shown in `session ls`) instead of leaking as the agent's
  `--name` — it no longer diverges from the tmux session id.
- `cctrl start` checks free memory before launching and refuses (with a clear
  warning, current numbers, and a `-f`/`--force` or `CCTRL_FORCE=1` override)
  when the machine is genuinely low on RAM. It uses the same metric as the
  fleet monitor (macOS `memory_pressure` free percentage); it gates on memory
  only, not session count, and factors swap when free RAM is already low.
- `cctrl fleet` prints a `local: mem …% free · swap …MB used · load … · N
  sessions` line for at-a-glance local health.

### Fixed
- `cctrl peer deliver` no longer silently misroutes a queued message to a
  different session that has taken over the recipient's tmux session name. A
  tmux name doubles as a mailbox address and freed name slots are reused, so a
  resumed or brand-new session can inherit a name and receive mail meant for the
  name's previous occupant — including hard-holds and corrections meant for
  someone else. Delivery, `peer recv`, and `peer inbox` now withhold a message
  whose current occupant was created after the message was sent: it is marked
  `addressee-replaced` (or `addressee-ambiguous` when the timestamps tie or the
  message stamp can't be parsed) and the sender is told, instead of the wrong
  session silently acting on it. Sessions with no recorded creation time (manual
  peers) and already-queued mail are unaffected.
- `cctrl session ls` and `cctrl peer ls` now identify a session's agent by its
  process name rather than scanning the whole command line, so a Claude session
  whose prompt happens to mention `codex` (or a `~/.codex/...` path) is no
  longer mislabeled `codex`. This was not cosmetic: the agent field selects
  which approval-modal pattern `peer deliver` scans for, so a mislabeled Claude
  session could have a delivery nudge pasted into an open modal. The agent
  runtime is now also recorded in session metadata at spawn.
- `cctrl peer deliver` no longer silently defers messages to Claude sessions
  that are emitting normal output. The claude modal-detector grepped the pane
  for `. 1\.` — whose `.` is a regex any-char, not the intended `❯` arrow — so
  it matched any markdown numbered list (which fleet-manager sessions emit
  constantly), plus bare `Do you want`/`Do you trust` prose. It now anchors on
  the modal's highlighted selection line `❯ 1.`, precise for all three Claude
  proceed/trust/permission modals.
- The same guard's codex branch is fixed too. Its markers
  (`Allow command`/`Approve`/`y/N`) were doubly wrong: `Allow command` never
  matched a real Codex modal (the header is ``Allow Codex to run `…` ``), while
  bare `Approve`/`y/N` false-flagged normal prose and shell `[y/N]` prompts.
  Verified against the Codex CLI TUI, it now anchors on real modal text:
  `Allow Codex to …`, the network-access prompt, and the `tell Codex what to do
  differently` option line (Codex modals have no `❯` cursor to key off).

## [Unreleased] - 2026-07-02

Fleet management: accurate session recency, real per-session state, and
triage/repair tooling for running many concurrent agent sessions.

### Added
- `cctrl session ls` now shows an accurate **last-active** time per session,
  sourced from the live Claude transcript instead of tmux terminal activity
  (which went stale when a session was driven remotely or finished quietly).
  Rows sort most-recently-active first.
- `cctrl session ls` now shows a **STATE** column: `working`/`idle`/`shell`,
  plus richer states — `waiting-input`, `blocked-dialog`, `unsent-draft`, and
  `idle-done` — so you can tell at a glance which sessions actually need you.
  (Each detector fails safe to the base state; toggle individual detectors with
  `CCTRL_STATE_DETECT_*`.)
- `cctrl session ls --recap` surfaces each session's one-line recap (what it's
  about) from the transcript's compact-summary; shows `-` when none exists.
- `cctrl session prune` proposes stale and never-used sessions for closing.
  Dry-run by default (`--yes`/`--close` to act); `--older-than 7d` to tune
  staleness. Never-prompted detection is agent-aware (Claude transcripts and
  Codex rollout logs) and never flags a busy session.
- `cctrl fleet` gives one unified view of sessions across all your machines,
  sorted by last-active, with offline hosts marked inline.
- `cctrl session autoheal` repairs dead remote-control bridges, with an opt-in
  `autoheal install` launchd timer. It skips busy sessions and never touches a
  session with an unsent draft.
- `cctrl needs-me` reports only the sessions that *newly* went waiting,
  blocked, or finished since you last looked — ideal for a phone glance.
- `cctrl session doctor --fix` can now **realign** sessions whose tmux and app
  names have drifted, relaunching them with `--resume` so the conversation is
  preserved (skips busy/copy-mode; report-only prints a copy-paste hint).

### Fixed
- Launching a detached session can no longer clobber a live session: index
  assignment now skips any name held by a live tmux session (and reuses freed
  indices instead of sprawling). Previously `cctrl start -d @shortcut` could
  overwrite a running session.

<!-- commits: 8cd755c, 7aada2c, 5a3867d, 9103294, 4dbab80, afc3163, 77f55a2, d1fccb6, b1b5d4f, 5f05bc9 -->
