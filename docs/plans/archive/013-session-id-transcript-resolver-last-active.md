---
id: 013
title: Resolve Claude session-id + transcript path, add real last-active column to session ls
status: done
blocked-by: []
priority: 13
goal: cctrl-fleet-staleness
allows-migrations: false
needs-review: none
created: 2026-06-30
completed: 2026-07-02
reviewed: false
qa: automated
---

## Requirements

`cctrl session ls` shows no recency signal, and the only signal that exists
elsewhere (tmux `session_activity`) is unreliable — it ticks only on terminal
*output*, so a session driven via the remote-control bridge or one that
finished quietly can read arbitrarily stale (a "4d idle" session was confirmed
to have been used 0 minutes ago). The user runs ~20 concurrent sessions and
cannot triage them without an accurate "when was this last used."

The fix rests on a keystone helper that the rest of this backlog depends on:
authoritatively map a live tmux session to its Claude `sessionId` (the
transcript uuid) and to its transcript file on disk. cctrl already reads
`~/.claude/sessions/<pid>.json` for remote-control bridge detection
(`_session_bridge_field`); that same file carries `sessionId`, `updatedAt`,
and `statusUpdatedAt`. This plan adds the resolver helpers and uses them to add
a real `last-active` column to `session ls`, sorted most-recent-first.

**Acceptance criteria:**

- [ ] A helper resolves a session's Claude `sessionId` from
      `$CLAUDE_SESSIONS_DIR/<pid>.json` (via the existing `_session_claude_pid`),
      returning empty for non-Claude (codex/shell) sessions or when the file is
      absent.
- [ ] A helper resolves the transcript path by globbing
      `$CLAUDE_PROJECTS_DIR/*/<sessionId>.jsonl` (the sessionId uuid is globally
      unique, so no cwd-slug reconstruction), returning the single match or empty.
- [ ] A helper returns a session's last-active epoch-ms, preferring the per-pid
      file's `updatedAt`, falling back to the transcript file mtime (`stat -f %m`,
      seconds→ms) when `updatedAt` is absent; empty if neither resolves.
- [ ] `cctrl session ls` shows a `last-active` column rendered as a relative age
      (e.g. `2m`, `3h`, `4d`, or `-` when unknown), and rows are sorted
      most-recently-active first.
- [ ] `cctrl session ls --json` includes `session_id` (or null), `transcript`
      (path or null), and `last_active` (ISO-8601 string or null) fields.
- [ ] Sessions with no resolvable transcript/sessionId still list (with `-` /
      null), never erroring out.

## Design

The keystone is a *live read*, not launch-time persistence: cctrl already knows
the backing pid (`_session_claude_pid`) and already reads the per-pid JSON
(`_session_bridge_field`). Add sibling helpers next to those.

`$CLAUDE_SESSIONS_DIR` already exists (line ~36 of `cctrl`). Add a
`$CLAUDE_PROJECTS_DIR` constant (`${CLAUDE_CONFIG_DIR:-$CLAUDE_DIR}/projects`)
alongside it, overridable via env for tests.

New helpers (place beside `_session_bridge_field`, ~line 4230):

- `_session_claude_field <sess> <field>` — generalize the existing per-pid read
  so `sessionId`, `updatedAt`, `statusUpdatedAt`, `status` are all reachable
  (refactor `_session_bridge_field` to delegate, preserving behavior).
- `_session_id <sess>` — echo `sessionId` or empty.
- `_session_transcript_path <sess>` — resolve the transcript by **globbing for
  the sessionId uuid across all project dirs**: `$CLAUDE_PROJECTS_DIR/*/<sessionId>.jsonl`.
  The sessionId is a globally-unique uuid, so this needs exactly one match and
  sidesteps reconstructing Claude Code's cwd-slug entirely (immune to paths
  containing `.` or other special characters). Echo the single match, or empty
  if none. Do NOT rebuild the slug by hand (`/`→`-` is not Claude's full rule).
- `_session_last_active_ms <sess>` — `updatedAt` (epoch-ms) if present, else the
  transcript file's **mtime** via `stat -f %m` (macOS, epoch-seconds → ×1000);
  echo empty if neither resolves. No ISO-8601 date parsing (avoids the BSD
  `date` fractional-seconds/`Z` footgun).
- `_fmt_age_ms <ms>` — format epoch-ms delta from now as `Ns/Nm/Nh/Nd`.

Wire into `_session_list` (line ~4247): compute `last_active_ms` per row, add it
to both the `--json` object and the human table, and sort the collected rows by
`last_active_ms` descending before printing. Keep the existing columns; insert
`last-active` after `state` (adjust the `printf` width string).

**Files expected to change:**

- `cctrl`: add `$CLAUDE_PROJECTS_DIR` const; add the resolver/format helpers;
  refactor `_session_bridge_field` to delegate to `_session_claude_field`;
  extend `_session_list` (human + `--json` + sort).
- `tests/run-tests.sh`: add cases using `CCTRL_CLAUDE_SESSIONS_DIR` (already
  supported) plus a new `CCTRL_CLAUDE_PROJECTS_DIR` override to inject fixture
  per-pid files and transcripts.

**Testing approach:** unit-only — the helpers are pure functions over injectable
fixture dirs; no web/API surface.

**Out of scope:** the STATE column (014), recap (015), prune (019). Do not
change launch/resume code or persist anything to session metadata records — the
resolution is a live read. Do not touch codex session handling beyond returning
empty.

## Tasks

1. Add `$CLAUDE_PROJECTS_DIR` constant with `CCTRL_CLAUDE_PROJECTS_DIR` test
   override, next to `$CLAUDE_SESSIONS_DIR`.
2. Add `_session_claude_field`; refactor `_session_bridge_field` to delegate.
3. Add `_session_id`, `_session_transcript_path`, `_session_last_active_ms`,
   and `_fmt_age_ms` helpers (portable to macOS `date`).
4. Extend `_session_list`: compute last-active per row, add `last-active` human
   column + `session_id`/`transcript`/`last_active` JSON fields, sort rows by
   last-active desc.
5. Add tests injecting fixture per-pid files + a transcript, asserting: `--json`
   carries the right `session_id`/`last_active`; the **mtime-fallback** path is
   used when a fixture omits `updatedAt` (set a known mtime, assert the derived
   age); an **unresolvable** session lists with nulls; and sessions with null
   last-active sort **last** in the rendered order.

## Verification

- [cmd] `bash -n cctrl`
- [cmd] `tests/run-tests.sh < /dev/null`
- [assert] `tests/run-tests.sh < /dev/null` output contains `session_id`
- [assert] `bash -c 'CCTRL_CLAUDE_SESSIONS_DIR=... cctrl session ls --json' ` (in-harness) produces JSON containing `last_active` — covered by a new test case asserting the field is present.

## Implementation Notes

Added a `$CLAUDE_PROJECTS_DIR` constant (with `CCTRL_CLAUDE_PROJECTS_DIR` test
override) next to `$CLAUDE_SESSIONS_DIR`, plus five helpers beside
`_session_bridge_field`: `_session_claude_field` (session-keyed field read,
delegating to the still-intact pid-based `_session_bridge_field`), `_session_id`,
`_session_transcript_path` (globs the unique sessionId across project dirs — no
cwd-slug reconstruction), `_session_last_active_ms` (prefers `updatedAt` epoch-ms,
falls back to transcript `stat -f %m` ×1000), and `_fmt_age_ms` (Ns/Nm/Nh/Nd, `-`
for empty). `_session_list` now computes recency per row, adds a `last-active`
human column after `state` plus `session_id`/`transcript`/`last_active` JSON
fields, and sorts rows by last-active epoch-ms descending (unknowns last via a
`-1` sort key). Four tests cover the updatedAt path, mtime fallback, an
unresolvable session (null, no error), and sort ordering.

Deviation: the Design said "refactor `_session_bridge_field` to delegate to
`_session_claude_field`"; instead `_session_bridge_field` stays the pid-based
core and the new session-keyed `_session_claude_field` delegates to it,
preserving all existing pid-based callers.

**Files changed:**

- `cctrl` (modified)
- `tests/run-tests.sh` (modified)

**Commit:** `81a7bdd` — `feat(session): add sessionId/transcript resolver + real last-active column`
