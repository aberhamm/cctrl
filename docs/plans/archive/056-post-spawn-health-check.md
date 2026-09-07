---
id: 056
title: Post-spawn health check with auto-dismiss for known prompts
status: done
blocked-by: []
priority:
goal: post-spawn-health-check
allows-migrations: false
needs-review: none
review-required: none
created: 2026-09-07
completed: 2026-09-07
reviewed: false
qa: automated
---

## Plain-English Summary

When cctrl starts a new session, it currently returns success as soon as the
tmux session exists — but the agent inside may be stuck on a blocking prompt
(workspace trust, login URL, conversation picker). The operator has to manually
check the pane and dismiss these. This plan adds a post-spawn health check that
polls the pane output, auto-dismisses known-safe prompts, and reports the
session's actual readiness before returning.

**What changes in the code:** The existing `_session_pane_has_dialog` function
(cctrl:7211) is refactored into a shared pattern table (`lib/health-check-patterns.sh`)
with action metadata (auto-dismiss key sequence or needs-human extraction).
A new `lib/health-check.sh` implements the poll-match-act loop. The `cctrl start`
flow gains a post-spawn health check on `--detach` spawns only. Results are
reported via session metadata (`health_status` field), NOT via exit codes —
`cctrl start` always exits 0 when the tmux session was created successfully.
`_peer_pane_ready_for_delivery` is migrated to use the shared pattern table.

## Requirements

After `cctrl start -d` creates a tmux session, the command should not return
until the agent inside is either (a) ready to accept input, or (b) blocked
on something that requires human intervention, in which case the blocking
reason and any actionable info (e.g. login URL) is reported.

**Acceptance criteria:**

- [ ] `cctrl start -d` polls the tmux pane after spawn and detects known blocking prompts
- [ ] Workspace trust prompt ("Do you trust the files") is auto-dismissed (press Enter to confirm default "Yes" selection) for `--detach` spawns
- [ ] Conversation picker prompt is auto-dismissed (press Enter to accept pre-selected option) for `--resume` spawns
- [ ] Login prompt is detected (anchored on modal chrome, not bare keywords), the login URL is extracted, and reported as needs-human
- [ ] Unknown/unrecognized blocking states are reported with the raw pane content
- [ ] Agent reaches ready state (no blocking prompt matched after N consecutive stable polls) → exit 0, metadata `health_status: ready`
- [ ] Agent stuck on needs-human prompt → exit 0, metadata `health_status: needs-human`, prints blocking reason and extracted info
- [ ] Health check timeout → exit 0, metadata `health_status: timeout`, prints last pane content
- [ ] `--no-health-check` flag skips the check (backward compat, scripting)
- [ ] Works for both `claude` and `codex` agent types with agent-specific pattern sets
- [ ] Poll timeout is configurable via `--health-check-timeout` (default ~30s)
- [ ] Health check runs ONLY for `--detach` spawns, never for attach-after or foreground
- [ ] Auto-dismiss fires at most once per pattern per health check run (transition guard)
- [ ] Patterns anchored on modal chrome (❯ selector, modal frame), not bare keywords — prevents false matches from seeded prompt text
- [ ] `_session_pane_has_dialog` refactored to use the shared pattern table
- [ ] `_peer_pane_ready_for_delivery` migrated to use the shared pattern table
- [ ] Automated tests in tests/run-tests.sh covering pattern matching, action dispatch, timeout, bypass, and refactor regression

## Design

### Shared pattern table: `lib/health-check-patterns.sh`

Sourced by the health check, `_session_pane_has_dialog`, and
`_peer_pane_ready_for_delivery`. Defines parallel indexed arrays per agent type
(no pipe-delimited strings — regex alternation would break a pipe parser):

```bash
# Parallel arrays — index i across all four arrays forms one entry.
# PATTERN: extended regex anchored on modal chrome (❯ selector, dialog text)
# LABEL: human-readable label for logging
# ACTION: auto-dismiss | needs-human | info-only
# KEYS: tmux send-keys sequence for auto-dismiss, or regex capture for needs-human

CLAUDE_HC_PATTERN=(
  "Do you trust the files|❯ 1\. Yes"
  "Continue from a previous|❯ 1\."
  "❯ 1\..*(login|sign.in|authenticate)"
  "login isn.t available|auth.* required"
)
CLAUDE_HC_LABEL=(
  "workspace-trust"
  "conversation-picker"
  "auth-login"
  "login-unavailable"
)
CLAUDE_HC_ACTION=(
  "auto-dismiss"
  "auto-dismiss"
  "needs-human"
  "needs-human"
)
CLAUDE_HC_KEYS=(
  "Enter"
  "Enter"
  "https://[^ ]*"
  ""
)

CODEX_HC_PATTERN=(
  "Allow Codex to |approve network access|tell Codex what to do differently"
  "Hooks need review|PreToolUse hooks|Press t to trust|Trust all and continue"
)
CODEX_HC_LABEL=(
  "codex-approval-modal"
  "codex-hooks-trust"
)
CODEX_HC_ACTION=(
  "needs-human"
  "needs-human"
)
CODEX_HC_KEYS=(
  ""
  ""
)
```

### Health check flow: `lib/health-check.sh`

Sourced by the main `cctrl` script. Exports `_health_check_run()`:

```
_health_check_run <session_name> <agent_type> <timeout_seconds>
```

1. Source `lib/health-check-patterns.sh` to load pattern arrays
2. Select the agent's arrays (CLAUDE_HC_* or CODEX_HC_*)
3. Initialize `DISMISSED` associative array (transition guard: tracks which pattern indices have been acted on)
4. Enter poll loop (default 30s timeout, 1s intervals)
5. Each tick: `tmux capture-pane -p -S -40 -t $SESSION` → match against pattern arrays
6. On match:
   - `auto-dismiss` + not yet dismissed: send key sequence via `tmux send-keys`, mark DISMISSED[i]=1, log the action, continue polling
   - `auto-dismiss` + already dismissed: log "already dismissed, waiting for prompt to clear", continue polling
   - `needs-human`: extract info via KEYS regex if non-empty, write `health_status: needs-human` to metadata, print report, return 0
   - `info-only`: log it, continue polling
7. On no match for N consecutive polls (stable-no-match): write `health_status: ready` to metadata, return 0
8. On timeout: write `health_status: timeout` to metadata, print last 20 lines of pane, return 0

### Consumer migration

`_session_pane_has_dialog` (cctrl:7211) is rewritten to:
1. Source `lib/health-check-patterns.sh` if not already sourced
2. Loop over the agent's pattern array
3. Return 0 (true) if any pattern matches — action metadata is ignored

`_peer_pane_ready_for_delivery` (cctrl:4269) is rewritten to:
1. Source `lib/health-check-patterns.sh` if not already sourced
2. Loop over the agent's pattern array
3. Return 1 (modal visible) if any pattern matches

### Integration into `_launch_detached`

After line 2156 (attestation anchor), before the conversation_id poller:

```bash
if [[ "${no_health_check:-false}" != "true" && "${CCTRL_ATTACH_AFTER_START:-}" != "1" ]]; then
    _health_check_run "$session_name" "$detach_agent" "${health_check_timeout:-30}"
fi
```

Health check results are printed to the user and written to session metadata.
The function always returns 0 — the session exists regardless of health status.

**Files changed:**

- `lib/health-check-patterns.sh`: NEW — shared pattern table (parallel indexed arrays)
- `lib/health-check.sh`: NEW — poll + match + act logic
- `cctrl`: Modified — wire health check into `_launch_detached`, refactor `_session_pane_has_dialog` and `_peer_pane_ready_for_delivery` to use shared patterns, add `--no-health-check` and `--health-check-timeout` flags to `cmd_start`
- `tests/run-tests.sh`: Modified — automated tests

**Out of scope:**

- Auto-handling login (requires browser auth flow)
- Health checks for already-running sessions (`_session_rich_state` handles this)
- Health check for `--foreground` spawns (no tmux pane, user sees prompts directly)
- Health check for attach-after spawns (user handles prompts after attaching)

## Tasks

1. Create `lib/health-check-patterns.sh` with shared parallel-array pattern table for Claude and Codex
2. Refactor `_session_pane_has_dialog` (cctrl:7211) to source and loop over the shared pattern table
3. Migrate `_peer_pane_ready_for_delivery` (cctrl:4269) to source and loop over the shared pattern table
4. Create `lib/health-check.sh` implementing the poll-match-act loop with transition guard
5. Wire `lib/health-check.sh` into `_launch_detached`, gated on `--detach` (not attach-after)
6. Add `--no-health-check` flag to `cmd_start` arg parser
7. Add `--health-check-timeout` flag to `cmd_start` arg parser (default 30)
8. Write health_status to session metadata on health check completion
9. Add automated tests: pattern matching against fixture pane text (each pattern hits, no false positives from seeded prompt text)
10. Add automated tests: transition guard (auto-dismiss fires once per pattern)
11. Add automated tests: timeout path, bypass flag, _session_pane_has_dialog regression
12. Manual test: fresh clone spawn triggers and auto-dismisses workspace trust
13. Manual test: `--resume` spawn auto-dismisses conversation picker
14. Manual test: timeout path works when agent hangs

## Verification

- [cmd] `cctrl start -d /tmp/test-repo --no-health-check` exits 0 without polling
- [assert] `grep -r 'CLAUDE_HC_PATTERN' lib/health-check-patterns.sh` shows parallel arrays
- [assert] `grep -r 'auto-dismiss\|needs-human' lib/health-check.sh` shows both action types
- [assert] `grep -r 'DISMISSED' lib/health-check.sh` shows transition guard
- [cmd] `bash -n lib/health-check-patterns.sh` exits 0 (valid shell syntax)
- [cmd] `bash -n lib/health-check.sh` exits 0 (valid shell syntax)
- [cmd] `tests/run-tests.sh` passes all health check tests
- [assert] `grep 'health_status' cctrl` shows metadata write in _launch_detached

## Implementation Tasks
Synthesized from this review's findings. Each task derives from a specific
finding above. Run with Claude Code or Codex; checkbox as you ship.

- [ ] **T1 (P1, human: ~2h / CC: ~15min)** — patterns — Create shared pattern table with parallel indexed arrays
  - Surfaced by: Architecture D1 + Code Quality D5 — shared table with parallel arrays, not pipe-delimited
  - Files: lib/health-check-patterns.sh
  - Verify: `bash -n lib/health-check-patterns.sh` exits 0

- [ ] **T2 (P1, human: ~1h / CC: ~10min)** — cctrl — Refactor _session_pane_has_dialog to use shared patterns
  - Surfaced by: Architecture D1 — DRY violation with existing dialog detection
  - Files: cctrl, lib/health-check-patterns.sh
  - Verify: existing tests still pass

- [ ] **T3 (P1, human: ~1h / CC: ~10min)** — cctrl — Migrate _peer_pane_ready_for_delivery to shared patterns
  - Surfaced by: TODO D10 — complete the DRY story in one change
  - Files: cctrl, lib/health-check-patterns.sh
  - Verify: existing peer delivery tests still pass

- [ ] **T4 (P1, human: ~3h / CC: ~20min)** — health-check — Implement poll-match-act loop with transition guard
  - Surfaced by: Architecture D2 (stable-no-match), D3 (Enter only), D7 (transition guard), D9 (modal chrome anchoring)
  - Files: lib/health-check.sh
  - Verify: `bash -n lib/health-check.sh` exits 0

- [ ] **T5 (P1, human: ~1h / CC: ~10min)** — cctrl — Wire health check into _launch_detached, gated on --detach
  - Surfaced by: Architecture D4 (detach only) + D8 (exit 0 always, metadata for status)
  - Files: cctrl
  - Verify: `cctrl start -d --no-health-check` exits 0 without polling

- [ ] **T6 (P2, human: ~2h / CC: ~15min)** — tests — Automated test suite for health check
  - Surfaced by: Test Review D6 — 14 test gaps, all automated
  - Files: tests/run-tests.sh
  - Verify: `tests/run-tests.sh` passes

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | — | — |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR (PLAN) | 10 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

**CODEX:** 8 findings from outside voice; 3 new issues accepted (transition guard, exit code semantics, false-match anchoring), 5 aligned with existing review decisions.

**CROSS-MODEL:** No tension — both reviewers agree on all accepted findings.

**VERDICT:** ENG CLEARED — ready to implement.

NO UNRESOLVED DECISIONS

## Implementation Notes

Created shared pattern table (lib/health-check-patterns.sh) with parallel indexed arrays
for Claude and Codex agent types. Patterns anchored on modal chrome to prevent false
matches from seeded prompt text. Created poll-match-act loop (lib/health-check.sh) with
bash 3.2-compatible transition guard. Refactored _session_pane_has_dialog and migrated
_peer_pane_ready_for_delivery to use the shared pattern table with inline fallback for
environments without lib/. Wired health check into _launch_detached, gated on --detach.
Added --no-health-check and --health-check-timeout flags plus CCTRL_NO_HEALTH_CHECK env
var. Added 7 automated tests covering pattern matching, transition guard, needs-human,
timeout, bypass flag, and dialog regression.

**Files changed:**

- `lib/health-check-patterns.sh` (created)
- `lib/health-check.sh` (created)
- `cctrl` (modified)
- `tests/run-tests.sh` (modified)

**Commit:** `4a1969d` — `feat(start): post-spawn health check with auto-dismiss`
