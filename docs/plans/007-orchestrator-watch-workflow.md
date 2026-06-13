---
id: 007
title: Add orchestrator watch workflow for peer messaging
status: done
blocked-by: [004, 005, 006]
priority: 7
goal: cctrl-agent-peer-messaging
allows-migrations: false
needs-review: none
created: 2026-06-08
completed: 2026-06-13
reviewed: false
qa: automated
---

## Requirements

After peers, mailbox, polling, tmux nudges, and MCP exist, users need a
coherent operating workflow for an overseeing agent. This plan adds status,
manual re-nudge, garbage collection, a watch loop, a doctor command, docs,
completions, and scenario tests so the feature is usable end-to-end instead of
a collection of primitives.

**Acceptance criteria:**

- [ ] `cctrl peer status --json` summarizes peers, queued messages, delivered-but-unacked messages, peers with repeatedly failing nudges, and available transports
- [ ] `cctrl peer nudge <name>` re-nudges one recipient's queued messages through the plan 004 adapter
- [ ] `cctrl peer nudge --stale [--older-than 15m]` re-nudges recipients whose queued messages have no nudge or a nudge older than the threshold, and surfaces delivered-but-unacked messages past the threshold
- [ ] `cctrl peer gc --older-than 7d --status acked --dry-run` reports messages eligible for cleanup without deleting them
- [ ] `cctrl peer gc --older-than 7d --status acked` archives only messages matching the retention filter to `data/messages-archive.jsonl` and removes them from the active mailbox
- [ ] `cctrl peer watch --once` performs one orchestrator pass over queued messages and reports what happened
- [ ] `cctrl peer watch --interval 5` repeatedly checks queued messages and invokes the tmux nudge adapter for tmux-capable peers
- [ ] Watch re-nudges stale queued messages per `--renudge-after` and backs off per-recipient after repeated failed nudges
- [ ] Watch is a singleton: a second concurrent `watch` exits with "already running (pid N)"; `--once` bypasses the singleton check only with `--force`
- [ ] Watch leaves polling/MCP-only peers' messages queued for agent-side pickup and never nudges peers without tmux capability
- [ ] `cctrl peer doctor [name]` checks jq presence, tmux availability, session liveness, pane reachability, mailbox parseability, stale locks, and that the MCP bridge starts
- [ ] README includes the recommended orchestrator prompt, examples for "send a message to the Comet agent", and a cross-host section
- [ ] zsh completions cover all new `peer` subcommands and common flags
- [ ] Scenario tests cover nudge delivery, polling-only pickup, stale re-nudge, backoff, and status summaries

## Design

Add orchestration commands on top of the completed primitives. `watch` invents
no delivery semantics: it calls the plan 004 nudge adapter for tmux peers and
leaves polling/MCP peers' messages in the mailbox. The user-facing model stays
clear: `cctrl` is the registry and delivery layer; the overseeing agent makes
reasoning and routing decisions.

Testing approach: unit-only.

**Re-nudge and backoff.** There is no `failed` message state (plan 003), so
recovery means re-nudging, not state resets. Watch re-nudges queued messages
whose `last_nudge_at` exceeds `--renudge-after` (default 15m). Per-recipient
backoff counts trailing `event: "nudge", ok: false` history records (plan 003
schema): after K consecutive failed nudges (default 3) a recipient is skipped
until `--backoff` (default 10m) elapses, and shows as nudge-failing in
`peer status`.

**Singleton watch.** `watch` takes its own lock file under
`${CCTRL_DATA_DIR}` containing the holder PID, reclaiming it when that PID is
dead (same staleness rule as the plan 003 mailbox lock). This prevents two
loops from double-nudging; combined with plan 004 holding the mailbox lock
across its nudge cycle, concurrent manual `deliver` calls remain safe.

**Implementation notes.** `nudge` and `watch` call the plan 004 delivery
functions in-process (the adapter is shell functions inside `cctrl`), never
`cctrl peer deliver` as a subprocess. The watch singleton reuses the plan 003
lock-directory helper (PID + staleness reclaim) at
`${CCTRL_DATA_DIR}/watch.lock.d`; watch traps INT/TERM to remove its lock on
graceful exit (kill -9 is covered by stale-PID reclamation). Durations (`7d`,
`15m`, `10m`) are parsed by a new `_duration_to_seconds` helper accepting
`Ns|Nm|Nh|Nd` with pure shell arithmetic; ISO 8601 timestamp comparisons
convert to epoch via `jq` (portable across BSD/GNU date). The doctor's MCP
check starts `cctrl peer mcp --as <name>`, writes an `initialize` request to
its stdin, and expects a JSON-RPC response within a 2-second timeout before
killing the process.

**Garbage collection** is explicit and conservative. Default behavior dry-runs
or targets only `acked` messages older than a retention window. Queued and
delivered-but-unacked messages are never removed unless the user passes an
explicit status filter. GC archives matching records to
`${CCTRL_DATA_DIR}/messages-archive.jsonl` (created lazily on first archive)
and removes them from the active mailbox through the plan 003 locking helper. Hard deletion is out of scope.

**Cross-host (README task, no code).** Plan 001's `--host` already composes:
`cctrl --host studio peer send ...` operates the remote machine's mailbox over
SSH. Each machine owns its own mailbox; there is no replication and none is
planned. Document this as the federation answer.

**Watch behavior:**

- `--once`: one pass, exits zero when work was checked successfully; `--force` bypasses the singleton check for `--once` only
- `--interval N`: loop until interrupted
- `--max-passes N`: optional bounded loop for tests and controlled automation
- `--renudge-after DURATION`, `--backoff DURATION`: staleness and backoff tuning
- `--json`: emit machine-readable pass summaries
- `--dry-run`: report actions without pasting or mutating nudge metadata

**Files expected to change:**

- `cctrl`: add `peer status`, `peer nudge`, `peer gc`, `peer watch`, and `peer doctor`
- `tests/run-tests.sh`: add end-to-end fake mailbox/fake tmux scenarios
- `README.md`: full peer messaging workflow, orchestrator prompt, cross-host section, retention guidance, and known limitations
- `completions/_cctrl`: complete the peer command tree

**Out of scope:** automatic agent idle detection (plan 008 covers hook-based
doorbells), real-time push delivery without polling, cross-host mailbox
replication, automatic deletion without an explicit retention command, and UI
dashboards.

## Tasks

1. Implement `peer status` using the registry, mailbox, and nudge metadata.
2. Implement `peer nudge <name>` and `--stale --older-than` on top of the plan 004 adapter.
3. Implement `peer gc --older-than`, `--status`, `--dry-run`, and `--json` with archive-only cleanup.
4. Implement `peer watch` with `--once`, `--force`, `--interval`, `--max-passes`, `--renudge-after`, `--backoff`, `--dry-run`, `--json`, the INT/TERM cleanup trap, and the PID-staleness singleton lock.
5. Implement `peer doctor` checks with actionable output.
6. Add scenario tests for orchestrator passes across tmux and polling peers, stale re-nudge, backoff, and singleton behavior.
7. Add retention tests for dry-run, acked cleanup, and protection of queued and delivered-but-unacked messages.
8. Complete zsh completions for all peer commands.
9. Update README with architecture, examples, cross-host section, retention and orchestrator prompt guidance, the trust model (same-user cooperative identity — `--as` is addressing, not authentication), and known limitations.

## Verification

Checks:
- [cmd] `bash -n cctrl && bash -n tests/run-tests.sh && zsh -n completions/_cctrl`
- [cmd] `tests/run-tests.sh`
- [assert] `cctrl peer watch --once --dry-run --json` in the test suite reports nudge candidates without pasting or mutating nudge metadata
- [assert] `cctrl peer nudge --stale --older-than 15m --json` in the test suite re-nudges only stale queued messages and reports delivered-but-unacked ones
- [assert] a second concurrent `cctrl peer watch` in the test suite exits with an already-running error, and a dead-PID watch lock is reclaimed
- [assert] backoff tests prove a recipient with repeated failed nudges is skipped until the backoff window elapses and appears in `peer status`
- [assert] `cctrl peer gc --older-than 7d --status acked --dry-run --json` in the test suite reports eligible acked messages and leaves the mailbox unchanged
- [assert] `cctrl peer gc --older-than 7d --status acked --json` in the test suite archives eligible acked messages and removes them from the active mailbox
- [assert] `cctrl peer watch --once --dry-run --json` in the test suite leaves polling/MCP-only queued messages queued
- [assert] `cctrl peer watch --interval 1 --max-passes 2 --dry-run --json` in the test suite emits two pass summaries and exits cleanly

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | Orchestration loop concurrency and retention semantics need review | 1 | CLEAR | 0 issues; doctor gains jq check; trust model added to README scope |

- **VERDICT:** ENG CLEARED. Ready to implement.

## Implementation Notes

Added the orchestrator-facing peer messaging workflow: status summaries,
manual and stale nudges, bounded and continuous watch passes with singleton
locking and backoff, archive-only mailbox GC, and a doctor command for local
peer messaging health. The watch path leaves polling-only peers queued,
reuses tmux nudges only for tmux-capable peers, and validates edge cases found
in review: GC preserves the active mailbox when archive writes fail, explicit
nudge target typos fail, and zero-second watch intervals are rejected.

**Files changed:**

- `cctrl` (modified)
- `tests/run-tests.sh` (modified)
- `README.md` (modified)
- `completions/_cctrl` (modified)
- `docs/plans/007-orchestrator-watch-workflow.md` (modified)

**Verification:**

- `PLAN_ID=007 bash /Users/matthew/dev/projects/mstack/skills/mstack-run/scripts/health-check.sh run` -> PASS, composite 9.9/10
- `codex review --uncommitted` -> 3 findings, all fixed

**Commit:** `PENDING` — `feat(peer): add orchestrator watch workflow`
