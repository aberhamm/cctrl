---
id: 012
title: Reconcile directory-launch session names with configured shortcut aliases
status: pending
blocked-by: []
priority: 12
allows-migrations: false
needs-review: none
created: 2026-06-19
---

## Background

Follow-up to the bridge name-reconciliation work shipped in commit `fa2af76`
(`feat(session): reconcile remote-control bridge names + add session doctor`).
That commit made the `--remote-control` prefix derive from the explicit
`--name` instead of the cwd/repo slug, so the Claude Code app session name
matches the tmux session name and same-repo sessions get unique prefixes. It
also added `cctrl session doctor`.

Learnings captured while diagnosing and fixing a live fleet (Mac Studio,
~17 Claude sessions):

- **Shared prefixes cause real bridge collisions, not just cosmetic name
  drift.** When several sessions of one repo advertised the same
  `--remote-control-session-name-prefix` (e.g. `TMUX--ms--homelab-`),
  reconnecting one session generated a bridge name that collided with another's
  and **stole** its bridge. The evicted session's `bridgeSessionId` dropped to
  null. Two sessions even ended up sharing a single Claude `sessionId`.
- **`bridgeSessionId` in `~/.claude/sessions/<pid>.json` is the authoritative
  liveness signal** (null = not bridged). The on-screen `/rc active` footer is a
  *rotating* hint — a single capture can miss it, producing false negatives.
- **`session doctor` must cross-check `bridgeSessionId`s** to detect collisions:
  two sessions reporting the same id read "live" individually but are in
  conflict.
- **tmux copy-mode silently swallows injected keystrokes.** Any `send-keys`
  repair must `send-keys -X cancel` first (checked via `#{pane_in_mode}`).
- **Directory launches and shortcut launches produce different names.**
  `cctrl start -d ~/dev/unstructured-data-portal` yields
  `TMUX--ms--unstructured-data-portal` (repo-dir slug), while
  `cctrl start -d @portal` yields `TMUX--ms--portal` (shortcut key slug). Both
  are now internally consistent (name == bridge prefix), but they diverge from
  each other, so the *same repo* can get two different naming conventions
  depending on how it was launched. The rest of the fleet uses the short
  shortcut aliases.

## Requirements

When a detached session is launched by **directory** (`cctrl start -d <dir>`)
and that directory matches a configured shortcut, the session should adopt the
shortcut's short alias for naming — so directory launches and shortcut launches
of the same repo produce the same `TMUX--<device>--<alias>` name (and therefore
the same unique bridge prefix). This keeps the fleet's naming convention
consistent regardless of launch path.

**Acceptance criteria:**

- [ ] `cctrl start -d <dir>` where `<dir>` resolves to a configured shortcut's
      directory produces the same session name as `cctrl start -d @<shortcut>`.
- [ ] When multiple shortcuts point at the same directory, selection is
      deterministic (e.g. first match by sorted key) and documented.
- [ ] When no shortcut matches the directory, behavior is unchanged
      (repo-dir slug via `_tmux_session_slug`).
- [ ] The chosen name still flows through to `--name` and therefore to the
      `--remote-control-session-name-prefix`, preserving the `fa2af76` bridge
      reconciliation (name == prefix).
- [ ] Auto-increment for duplicate names still applies after alias resolution.
- [ ] A test asserts dir-launch and shortcut-launch of the same repo yield the
      same name and the same remote-control prefix.
- [ ] No change to foreground (`--foreground`) launches that pass no `--name`.

## Design

Add a reverse lookup `_shortcut_for_dir <abs-dir>` that scans
`data/shortcuts.json` for an entry whose resolved directory equals the launch
directory, returning the shortcut key (deterministic on collision). In
`_launch_detached`, in the directory branch (around the `target_kind == "dir"`
case), after resolving the absolute `dir`, consult `_shortcut_for_dir`; if a
key is found, derive `context_name` / `session_name` from that key via
`_tmux_session_slug "<key>"` exactly as the shortcut branch does, and set
`display_label` / `metadata_target` to `@<key>` for parity. Otherwise keep the
current repo-dir slug.

This is naming-only: it does not change which agent runs, the cwd, resume, or
the bridge mechanism — it just makes the *name* (and the derived prefix)
identical across the two launch paths.

### Out of scope

- Renaming or migrating already-running sessions (relaunch realigns them; the
  shipped `cctrl session doctor` reports the drift).
- Any change to the homelab case where the repo basename already equals the
  alias (`homelab`), which is already consistent.

## Notes

- Core fix already shipped: commit `fa2af76` (bridge prefix from `--name`,
  `session doctor [--fix] [--yes] [--json]`, `rc` column on `session ls`).
- Operational recipe for repairing/realigning existing sessions, validated on
  the live fleet: `cctrl session doctor` to find drift/dead/collision, then
  relaunch via the shortcut with resume —
  `cctrl start -d @<shortcut> --agent claude --resume <sessionId> --purpose ...`
  — which restores the short name and gives each session a unique prefix.
