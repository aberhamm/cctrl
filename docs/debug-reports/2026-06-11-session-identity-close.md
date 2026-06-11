# Session Identity and Unsafe Self-Close

Date: 2026-06-11

## Symptom

An agent asked to close its current session could close a tmux session even when
the caller was not actually running inside that cctrl tmux session.

## Root Cause

`cctrl close` with no explicit session name trusted ambient tmux state:
`TMUX` plus `tmux display-message -p '#{session_name}'`. Agent subprocesses can
inherit tmux-looking state, and `tmux display-message` can still resolve a
session even when the caller is not a descendant of that session's pane process.

Detached launches also built the foreground agent command before auto-increment
resolved the final tmux session name, so agent display/identity could use the
base name while the actual tmux session was `--2` or later.

## Fix

Tmux-backed launches now export explicit session identity:

- `CCTRL_SESSION_KIND=tmux`
- `CCTRL_SESSION_NAME=<exact tmux session>`
- `CCTRL_SESSION_TARGET=<dir or @shortcut>`
- `CCTRL_SESSION_PURPOSE=<purpose>`

Foreground launches export `CCTRL_SESSION_KIND=foreground` and clear tmux
session identity.

`cctrl close` no longer trusts `TMUX` alone. It verifies the caller process is a
descendant of one of the target session's tmux pane PIDs before treating that
session as "current." Stale inherited tmux state is refused for no-arg
self-close.

`cctrl session current [--json]` now exposes machine-readable identity so agents
can inspect whether self-close is safe before acting.

## Evidence

- Added regression coverage for stale `TMUX` env refusing no-arg close.
- Added JSON identity coverage for verified cctrl tmux sessions.
- Added auto-increment coverage that the launched agent receives the final exact
  `CCTRL_SESSION_NAME` and `--name`.
- `tests/run-tests.sh`: passed locally.

Status: DONE
