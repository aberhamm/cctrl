---
id: 019
title: cctrl session prune — stale + never-prompted detection with --dry-run
status: in-progress
blocked-by: [013, 014]
priority: 19
goal: cctrl-fleet-staleness
allows-migrations: false
needs-review: none
created: 2026-06-30
---

## Requirements

With ~20 sessions accumulating, dead weight piles up: genuinely stale sessions
and "never-prompted" ones (launched with a purpose label but zero user turns —
exactly the 6 empty Codex sessions seen this session). The user needs a safe way
to find and close them. This plan adds `cctrl session prune`, which uses the
accurate last-active signal (plan 013) and a never-prompted detector to propose
sessions for closing — defaulting to a non-destructive dry run.

**Acceptance criteria:**

- [ ] `cctrl session prune` defaults to `--dry-run`: it lists prune candidates
      and their reason, and closes nothing unless explicitly told to.
- [ ] Candidates include sessions whose accurate last-active (plan 013) exceeds a
      staleness threshold — default **3 days (72h)**, overridable via a
      `--older-than <duration>` flag.
- [ ] Candidates include "never-prompted" sessions, detected **per agent**:
      Claude sessions with zero user turns in their Claude transcript; codex
      sessions with zero user-input events in their `~/.codex` rollout log.
- [ ] A live session is **never** flagged never-prompted merely because it lacks
      a Claude transcript (a busy codex session must not be a candidate).
- [ ] A non-dry-run mode (e.g. `--yes` / `--close`) closes the candidates via the
      existing graceful close path, reporting each action.
- [ ] prune never proposes the session it is being run from, and never proposes
      attached sessions unless explicitly forced.
- [ ] `--json` lists candidates with `name`, `reason`, and `last_active`.

## Design

Add a `prune` action to `cmd_session` dispatch. Reuse `_session_last_active_ms`
and `_session_transcript_path` (plan 013). **Never-prompted is agent-aware:**
Claude → its Claude transcript exists but has zero `role:user`/`type:user`
entries (bounded scan); codex → resolve its
`~/.codex/sessions/**/rollout-*-<uuid>.jsonl` (correlate by cwd + recency, or
the codex uuid) and find zero user-input events. A session whose
agent-appropriate log is simply **absent** is NOT auto-flagged — this both
guards a just-launched session and prevents treating a codex session's lack of
a *Claude* transcript as "never prompted" (the false-positive bug). Staleness =
`now - last_active_ms > threshold`, threshold default 72h (`--older-than`
overrides; accept `7d`/`48h`); where `_session_last_active_ms` is unavailable
(codex / no per-pid file), fall back to metadata `created_at` as the age floor.
Compose candidates, exclude self
(`_session_current` name) and attached sessions by default, print a dry-run
table; under the confirm flag, route each through the existing `_session_close`
graceful path.

**Files expected to change:**

- `cctrl`: add `prune` to `cmd_session` dispatch + help; implement
  `_session_prune` (candidate computation, dry-run table, confirmed close);
  add a never-prompted helper.
- `tests/run-tests.sh`: fixtures for a stale session, a never-prompted session,
  and a fresh active session; assert dry-run lists exactly the right candidates
  with reasons and closes nothing; assert self/attached exclusion.

**Testing approach:** unit-only.

**Out of scope:** cross-host pruning (the fleet view is plan 020 and prune stays
host-local here) and auto-scheduling prune. Default must be non-destructive.

## Tasks

1. Add `prune` dispatch + help text in `cmd_session`.
2. Implement staleness candidate selection using `_session_last_active_ms` with
   a threshold flag.
3. Implement agent-aware never-prompted detection (Claude transcript zero user
   turns; codex rollout-log zero user-input events; absent log → not flagged).
4. Implement dry-run table (default) and confirmed close; exclude self/attached.
5. Add tests: Claude never-prompted flagged; codex never-prompted (via rollout
   fixture) flagged; a **busy codex session with no Claude transcript is NOT
   flagged** (the bug-guard); dry-run closes nothing; self/attached excluded.

## Verification

- [cmd] `bash -n cctrl`
- [cmd] `tests/run-tests.sh < /dev/null`
- [assert] dry-run test asserts a never-prompted fixture appears as a candidate
  with reason and that no close action fired
- [assert] a test asserts a fresh active fixture is NOT a candidate
- [assert] a bug-guard test asserts a codex session lacking a Claude transcript
  is NOT flagged never-prompted
