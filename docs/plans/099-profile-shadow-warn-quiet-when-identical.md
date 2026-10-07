---
id: 099
title: Quiet the profile "exists in both" WARN when the two copies are byte-identical
status: done
completed: 2026-10-07
blocked-by: []
priority: 99
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-10-07
tui-fixture: n/a  # profile listing/current fixtures only
approved-by: Matthew ("Approve", 2026-10-07 07:54 UTC, via fm-cctrl; mdec-1007-cctrl-profile-warn-quiet)
reviews:
  - type=eng verdict=approved date=2026-10-07 by=opus-subagent
---

## Plain-English Summary

After `cctrl profile migrate`, `cctrl ls`/`cctrl current` kept printing
`WARN: <name> exists in both; using ~/.config/cctrl/profiles/<name>.json`
for every migrated profile forever, even when the repo copy and the
migrated XDG copy are byte-identical (the normal, expected post-migrate
state). The WARN is only useful when the two copies have actually
diverged — a stale repo original someone forgot to update, or a hand-
edited XDG copy. This plan quiets it in the identical case and keeps it
for the differing case.

## Fix

New helper `_profile_shadow_differs <name>` (added just above `cmd_ls` in
`cctrl`): returns true only when both `$PROFILES_REPO_DIR/$name.json` and
`$PROFILES_USER_DIR/$name.json` exist AND `cmp -s` reports them as
differing. Never reads or compares file *contents* at the shell level
beyond `cmp`'s own byte comparison — no profile env values are printed or
inspected.

Both existing WARN print sites now gate on it:
- `cmd_ls`'s per-row WARN (previously gated only on the pre-existing
  `shadowed` flag from `_profile_list`).
- `cmd_current`'s WARN (previously gated only on `-z
  "${CCTRL_PROFILES_DIR:-}" && both files exist`).

No other WARN, no precedence change, no file deletion: this only changes
whether a message prints, not which profile file is read or used.

## Tests (tests/run-tests.sh)
- Identical repo/XDG copies (`test_profile_shadow_identical_warn_quiet`):
  `cctrl ls` and `cctrl current` print the profile with no `WARN: ...
  exists in both` line.
- Differing repo/XDG copies, `cctrl current`
  (`test_profile_shadow_current_warns_when_differs`): the WARN still
  prints. The `cctrl ls` half of the differing case was already covered
  by the pre-existing `test_profile_repo_fallback_and_clash`, which keeps
  passing unchanged.

## NOT in scope
- Any other WARN (`defaultProfile` override, clash-wins message, etc.).
- Profile precedence (XDG still always wins when both exist).
- Deleting a repo or XDG profile file.
