---
id: 017
title: Live-aware session index picker — never assign an index that clobbers a live session
status: done
blocked-by: []
priority: 17
goal: cctrl-fleet-staleness
allows-migrations: false
needs-review: none
created: 2026-06-30
completed: 2026-07-02
reviewed: false
qa: automated
---

## Requirements

Launching a detached session can land on a name/index that belongs to a live
session and clobber it. In the diagnosing session, `cctrl start -d @obsidian`
reused index `--2` and stole/overwrote a live 204k-token session (the CHECK24
one), which had to be recovered from disk. The index picker must never select a
name whose tmux session is currently alive; it should pick the lowest
free-and-not-live index, or refuse with a clear error rather than collide.

**Acceptance criteria:**

- [ ] When deriving a detached session name, the picker skips every index whose
      tmux session currently exists, selecting the lowest index with no live
      tmux session (stale metadata for dead sessions does not reserve an index).
- [ ] A launch can never produce a `session_name` equal to an existing live tmux
      session (verified by a regression test reproducing the `@shortcut` reuse
      path).
- [ ] If no safe index can be assigned (pathological case), the command fails
      with a clear error and a non-zero exit code instead of colliding.
- [ ] Existing single-session and `--N` increment behavior is preserved for the
      normal (no-collision) case.

## Design

The base increment loop (~line 1465 in `cctrl`) already does
`while tmux has-session -t "${base_name}--${n}"; do ((n++)); done` for the
fresh-name path. The clobber came through a different path — the `@shortcut`
jump / reuse logic that can settle on a base name without the same liveness
guard. Audit all paths that compute `session_name` for detached launches
(`cmd_start` detached branch, `_shortcut_jump`, and the metadata-name
derivation) and route every one through a single
`_pick_safe_session_index <base_name>` helper that:

1. Considers an index "taken" **only** if `tmux has-session` is true for it — a
   live session is never overwritten. A stale metadata record for a dead session
   does NOT reserve the index (freed indices are reused, no `--N` sprawl); if a
   reused index has leftover metadata, overwrite/refresh it for the new session.
2. Returns the lowest free index (or the bare base name if that itself is free
   and not live).
3. Signals failure if it cannot find a safe slot within a sane bound.

**Files expected to change:**

- `cctrl`: add `_pick_safe_session_index`; replace the ad-hoc increment loop and
  any other name-derivation path with calls to it.
- `tests/run-tests.sh`: regression test stubbing `tmux has-session` to report a
  live session at the base index, asserting the picker skips it; plus a test
  asserting normal increment is unchanged.

**Testing approach:** unit-only.

**Out of scope:** the launch-time dir-vs-shortcut *naming convention*
reconciliation (that is plan 012) and realigning already-mismatched sessions
(plan 018). This plan is strictly about not overwriting a live session.

## Tasks

1. Inventory every detached-launch path that computes `session_name`.
2. Implement `_pick_safe_session_index` (metadata-taken OR tmux-live = taken).
3. Route all paths through it; add the refuse-on-no-slot guard.
4. Add a regression test reproducing the `@shortcut` reuse clobber and asserting
   it no longer collides; a normal-increment test; and a **freed-index-reuse**
   test (stale metadata at `--2` with no live tmux session → picker reuses `--2`,
   no sprawl).

## Verification

- [cmd] `bash -n cctrl`
- [cmd] `tests/run-tests.sh < /dev/null`
- [assert] regression test asserts the picked name differs from the stubbed
  live session name
- [assert] normal-case test asserts `base--2` is still chosen when only the bare
  base is live

## Implementation Notes

Added `_pick_safe_session_index <base_name>`: returns the lowest session name
with no LIVE tmux session (index "taken" only when `tmux has-session` is true —
stale metadata never reserves an index, so freed indices are reused with no
`--N` sprawl), and returns non-zero if 2-999 are all live so the caller refuses
instead of colliding. All detached-launch name derivation converges in
`_launch_detached` (the sole `tmux new-session` site); its ad-hoc
`while tmux has-session` loop is replaced by the helper + a refuse-on-no-slot
guard. Root cause of the original clobber: `_launch_detached`'s
write-metadata-then-`rm`-on-dup-failure stole a live session's identity when the
`@shortcut` path settled on a live name; the old guard only checked the bare
base. 3 tests: clobber regression, normal increment, freed-index reuse.

**Files changed:**

- `cctrl` (modified)
- `tests/run-tests.sh` (modified)

**Commit:** `3d38c73` — `fix(session): never assign a detached-launch index that clobbers a live session`
