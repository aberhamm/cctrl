# Profile settings spike (plan 071, Phase 0)

Throwaway `claude -p` runs, each with a temp `CLAUDE_CONFIG_DIR` (a copy of
the real OAuth credentials, no other state) — the global `~/.claude/`
directory and `~/.claude.json` were never touched.

## Q1: does `--settings <file>` merge its `env` block with user settings.json `env`, or replace it?

Setup: user settings.json (temp `CLAUDE_CONFIG_DIR`) set
`env: {SPIKE_A: "from-user-settings", SPIKE_SHARED: "user-value"}`.
`--settings` overlay set `env: {SPIKE_B: "from-overlay", SPIKE_SHARED:
"overlay-value"}`. The agent ran `env | grep '^SPIKE_'` via its Bash tool.

Result:
```
SPIKE_A=from-user-settings
SPIKE_B=from-overlay
SPIKE_SHARED=overlay-value
```

**Merge, per variable** — not a block replace. `SPIKE_A` (only in user
settings) survived; `SPIKE_B` (only in the overlay) was added; `SPIKE_SHARED`
(in both) took the overlay's value, consistent with the documented
precedence ("the settings file value applies" / `--settings` sits above
user settings).

**Consequence for Phase 5:** the R4 contingency ("if block-replace, also
copy the global settings.json's non-provider `env` keys into the generated
overlay file") does not apply. A profile's `--settings` overlay only needs
to set the provider keys it cares about (plus `""` for unused
`CCTRL_PROVIDER_ENV_KEYS` entries) — any non-provider `env` keys a user
already has in their real settings.json (e.g. `HEALTHCHECKS_API_KEY`-style
keys) keep applying through the normal layering, un-copied and un-duplicated.
This is simpler and avoids ever writing a copy of those keys into a
0600-but-still-at-rest profile-settings file.

## Q2: which leaked Desktop vars change behaviour?

Informational only, per the plan — the Phase 4 prefix scrub
(`^(CLAUDE|ANTHROPIC)_|^CLAUDECODE$`, exported vars only) removes every
candidate in the plan's list unconditionally, so none of them need
individual handling:
`CLAUDE_CODE_DISABLE_TERMINAL_TITLE`, `CLAUDE_EFFORT`,
`CLAUDE_CODE_DISABLE_CRON`, `CLAUDE_CODE_SESSION_ATTENDED`,
`CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH`,
`CLAUDE_CODE_OAUTH_SCOPES`, `CLAUDE_CODE_ENABLE_ASK_USER_QUESTION_TOOL`,
`CLAUDE_CODE_CHILD_SESSION`, `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`,
`CLAUDE_PID`.

The keep-list (`CCTRL_LAUNCH_ENV_KEEP=(CLAUDE_CONFIG_DIR)` plus any
user-configured `launchEnvKeep`) stays minimal: nothing above needs to be
added to it. `CLAUDE_CONFIG_DIR` is the one exception already called out by
D7, since it is an explicit user choice of config location, not a Desktop
leak.

## Exit criterion

This findings doc, committed. No code changes in this phase.
