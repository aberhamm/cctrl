---
id: 098
title: Only fleet managers get "fm-" session names
status: done
completed: 2026-10-07
blocked-by: []
priority: 98
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-10-07
tui-fixture: n/a  # naming/profile-adoption fix uses the fake agent and fake tmux fixtures
approved-by: Matthew ("Only orchestrators/fleet managers should get that in their name", 2026-10-06, via fm-cctrl)
reviews:
  - type=eng verdict=approved date=2026-10-07 by=opus-subagent
---

## Plain-English Summary

Matthew noticed non-manager sessions picking up "fm-" names. Root cause:
`_shortcut_for_dir` (the reverse dir->shortcut-key lookup used by `cctrl
start -d <dir>`) resolves a sorted-key collision by picking the
alphabetically-first key, and `fm-` sorts before most plain names
(`fm-homelab` < `homelab`, `fm-personal` < `obsidian`). A plain directory
launch that happened to share its dir with a manager's own shortcut was
silently named and profiled as if it were that manager.

## Fix

`_shortcut_for_dir` now excludes any key starting with `fm-` from its
candidate set entirely (a jq `select(.key | startswith("fm-") | not)`
added to the existing sorted-key pipeline). Chosen over adding a new
`"role": "manager"` field to shortcuts.json because:
- No data migration: every manager shortcut already follows the `fm-*`
  naming convention in practice (checked `data/shortcuts.json`).
- One change, one place: all three call sites of `_shortcut_for_dir`
  (session naming in the dir-launch branch, `.profile` adoption earlier
  in the same function, and `_session_repo_name`'s display repo label)
  get the fix for free, since they already share this single reverse
  lookup. For `_session_repo_name`, this also means a dir matched only
  by an fm- key now shows the dir-basename label (e.g. "Homelab")
  instead of the manager's own label (e.g. "Fm Homelab") — a smaller
  version of the same bug, fixed the same way.
- A `role` field would need every existing manager shortcut edited to add
  it, plus validation that nothing silently falls back to the fm- prefix
  heuristic anyway when the field is absent — strictly more surface for
  the same outcome.

Effect: a `-d <dir>` launch now names from the first **non-fm-** shortcut
key that matches that dir, or the dir basename if only fm- key(s) match
(same as no match at all). An explicit `cctrl @fm-<x>` launch is
unaffected — it resolves the key directly via `_shortcut_lookup_key`, not
through the reverse lookup, so it still gets its own fm- name as before.

## Tests (tests/run-tests.sh)
- `test_dir_launch_skips_manager_shortcut_for_plain_key` — a dir shared by
  an `fm-aaa` key (sorts first) and a `zzz` key now names from `zzz`, not
  `fm-aaa`.
- `test_dir_launch_only_manager_shortcut_uses_dir_basename` — a dir with
  only an `fm-only` key falls back to the dir basename, not `fm-only`.
- `test_at_fm_shortcut_launch_keeps_fm_name` — regression guard: `cctrl
  @fm-<x>` still names from the fm- key (unaffected, different code path).
- Pre-existing `test_dir_launch_adopts_shortcut_alias` and
  `test_dir_launch_shortcut_collision_deterministic` continue to pass
  unchanged (neither fixture uses an fm- prefixed key).

## NOT in scope
- Renaming any existing live fleet-manager tmux session.
- Editing `data/shortcuts.json` (the real file) — fixtures only.
- A `"role"` field on shortcuts (considered, rejected above).
- Plan 097 (separate follow-up, tracked independently).

> Note (2026-10-07): plan 100 supersedes the "key starts with `fm-`" test with a `role` field on shortcuts/sessions (see `docs/plans/100-role-aware-session-naming.md`).
