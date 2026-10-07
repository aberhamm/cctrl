---
id: 089
title: Release pruning under ~/.local/lib/cctrl/releases (`cctrl release prune`)
status: done
completed: 2026-10-07
blocked-by: []
priority: 89
allows-migrations: false
needs-review: none
reviews:
  - type=eng verdict=approved date=2026-10-07 by=opus-subagent
review-required: eng
created: 2026-09-28
tui-fixture: n/a
approved-by: Matthew 2026-10-02 (via fm-cctrl; mdec-1007-cctrl-plan100)
---

## Plain-English Summary

Split from plan 075. This is a design question, not a fix — noted during
the 2026-09-28 review pass, not implemented. Do not pick this up as part
of the general 075-split-out queue; it needs Matthew's decision on
approach before any code is written. See memory
[[cctrl-checked-install-design]] for how releases and `current` work
today.

## The question

Old releases under `~/.local/lib/cctrl/releases` are never auto-pruned by
`install/self-install.sh` today, by design: a long-lived session bakes its
release's literal path into its MCP config for the session's life, so
deleting an older release out from under it would break that session. As
of 2026-09-28 there are 4 releases (~3.9M each, ~16M total) — no
disk-pressure urgency, so this is a design note, not a bug.

A real `--keep-last-N` (or similar) is not just "delete everything older
than the last N by timestamp" — it needs to first cross-reference which
release paths any currently-live session's MCP config still points at
(via the session registry, not just wall-clock recency) and exclude those
from deletion regardless of age, or a long-running session could still
get its release pulled out from under it even under a generous N. That
cross-reference design (and how to query it without a live-registry
write, consistent with plan 081's read-only-investigation pattern) is the
open question — decide it before implementing, don't just add a naive
count-based prune.

## Out of scope for this filing

Implementation. Nothing under `~/.local/lib/cctrl/releases` should be
deleted in the course of resolving this plan — live sessions may still
reference old release paths.

## Decision and implementation (2026-10-07)

Approved approach: a manual `cctrl release prune [--keep N] [--apply] [--json]`.
Dry run by default; default keep 5 (newest by build time, from the release
directory's timestamp suffix); never auto-run from `install/self-install.sh`.

- **Always kept:** `current`'s target, the launcher's target (if `~/.local/bin/cctrl`
  is a symlink into releases), and the newest N *complete* releases (a release is
  complete if it has `cctrl` and `VERSION`).
- **Referenced = kept regardless of age**, discovered read-only:
  live process argv (`ps -ww -axo pid=,command=`, never `ps e`/`eww`) and every open file and cwd of
  the user's processes (`lsof -u <uid> -Fpn`, paths only; this catches a long-lived cctrl started via
  `current/cctrl` before an install, whose script and libs now live in the old release dir); registry records (`TMUX--*.json`, `task-*.json`, `launch-*.json`) whose `name` is a *live tmux*
  session and whose `lifecycle_state` is not `closed` (leftover records of dead sessions do not pin a
  release; the process/open-file scans are the independent backstop); per-session `--settings` overlay files;
  `~/.local/bin` symlinks/launchers; and `~/.claude.json`,
  `~/.claude/settings.json`, `~/.codex/config.toml` (only release-path fragments
  are extracted; contents are never kept or printed). Output names only the
  source (process pid + executable name, file name), never contents.
- **Fail closed:** if any scan fails or is incomplete (ps/lsof/tmux error, a
  file unreadable, `current` missing, releases dir missing), every release is
  treated as referenced, nothing is deleted, and the command exits 69.
- **Delete guards (`--apply`):** name must match `<12 hex>-<UTC timestamp>`; entry
  must not be a symlink; its realpath must be a direct child of the realpath of
  the releases dir, non-empty, and not `current`'s target; removal is
  `shutil.rmtree` of that exact resolved path. Partial/incomplete
  (`.tmp-*`, missing `cctrl`/`VERSION`) and unrecognised entries are reported and
  never deleted in this plan.
- **Where:** `lib/release_prune.py` (scan + guards), thin `cmd_release` in `cctrl`.
- **Tests:** `test_release_prune` uses a sandbox `CCTRL_HOME` with stubbed
  `ps`/`lsof`/`tmux`; it never touches the real releases dir. Covers dry-run
  default, keep-N and `--keep 0`, each reference source, dead-session metadata not
  pinning, fail-closed on ps and lsof failure (exit 69), apply deleting exactly the
  right set, symlink entries not followed, and the installer not invoking prune.
- **Rule for operators/agents:** `--apply` against the real releases dir is a
  separate, explicit decision; this plan only ships the tool and its dry run.

## Review

Opus eng/safety review: changes-requested; all required fixes applied (not re-reviewed):
1. Session-registry scan read `TMUX--<name>.json` only, which holds no release paths in real data;
   it now parses every `*.json` record and pins by `.name` of live sessions (not closed records);
   test fixtures are real-shaped `task-<hex>.json` records.
2. A tmux permission error was treated as "no server"; only no-server / missing socket /
   connection-refused mean "no live sessions", anything else fails closed.
3. lsof now scans all of the user's open files, not just cwd.
4. An error during `--apply` no longer crashes after partial deletion: it stops, reports
   `FAILED deleting ...`, and exits 70; a crash anywhere else exits 70 without a traceback.
5. `current` and the launcher target are re-resolved immediately before each delete.
6. Tests added: lsof open-file reference, `~/.claude.json` reference, tmux failure -> 69,
   unreadable overlay -> 69, closed record not pinning, direct `safe_to_delete` guard checks,
   apply-time delete failure -> 70.
7. Docs aligned. Nits applied: `ps -ww`, JSON-escaped `releases\/` match, `--keep` limited to 0-9999,
   launcher target walks up to the release directory, oversized bin files and symlink chains.

## Follow-ups
- Shell completions do not list `release` yet.
- `--apply` on the real releases dir is a separate explicit decision (this plan did not run it).
