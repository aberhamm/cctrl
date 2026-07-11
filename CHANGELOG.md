# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

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
