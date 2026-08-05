---
id: 053
title: cctrl session restore — waved, gated, dry-runnable fleet rebuild from a snapshot
status: blocked
blocked-by: [051, 052]
priority: 7
goal: fleet-restore-after-power-loss
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-08-03
---

## Requirements

With 051 persisting `conversation_id` and 052 capturing the fleet, rebuilding
after a power-off is still a manual loop: read the snapshot, pick which sessions
matter, run `cctrl start -d <cwd> -r <uuid> -n <label>` for each, watch for the
resume picker, answer it, wait for big transcripts to compact, and stop before
the machine thrashes. That loop was run by hand on 2026-08-02 and twice on
2026-08-03. This plan is that loop, with the four things a human gets wrong under
pressure — the picker, the resource gate, the cap, and knowing what will happen
before it happens — made explicit.

`cctrl session restore [--from latest|<path>] [--only <pattern>] [--dry-run]
[--limit N] [--yes]` reads a snapshot and respawns sessions by **resuming their
conversations**.

**Resume the conversation; never replay `initial_prompt`.** Those stored prompts
reference sibling sessions that no longer exist ("two siblings are live right
now", "I dispatched it minutes ago") and actively mislead a restored session into
coordinating with ghosts. 052 does not capture the field, so the snapshot cannot
tempt anyone — but the **session record still persists `initial_prompt`**
(cctrl:1255, and it is populated in 39 of the 105 current records), so the
fallback is always one `_session_metadata_field` call away. The rule is
therefore stated as a prohibition on restore itself, not as an accident of the
snapshot's shape: **restore never reads `initial_prompt` from any source.**
A session with no `conversation_id` is reported and skipped, full stop.

**Acceptance criteria:**

- [ ] `cctrl session restore` reads `data/snapshots/latest.json` by default;
      `--from <path>` reads a specific history file. A snapshot whose
      `schema_version` is unknown is refused with the version it saw.
- [ ] Candidate selection: sessions are ordered by `last_active` descending
      (most recently worked on first), `--only <pattern>` filters by
      case-insensitive substring against `name`, `display_label`, `purpose`, and
      `cwd`, and `--only` may be repeated (union). Any session whose tmux name is
      already live is skipped as `already-live` — which makes a partial restore
      resumable by re-running the same command.
- [ ] **Cap on the resulting total, not on the number spawned.** Restore stops
      once the live **cctrl-managed** session count reaches
      `CCTRL_RESTORE_MAX_ACTIVE` (default 8). Do **not** reuse
      `_active_session_count` (cctrl:1404) for this: despite its comment it is
      `_session_list --json | jq 'length'`, and `_session_list` enumerates every
      tmux session including plain shells (`kind: shell (zsh)`), so it
      over-counts. Restore needs
      `jq '[.[] | select(.managed)] | length'` over the same JSON. The working
      limit is ~8-10 active
      and snapshots routinely hold 20+, so a cap on "how many I spawn" is the
      wrong axis — it ignores whatever is already running. `--limit N`
      additionally caps spawns in this invocation. Everything past the cap is
      reported as `deferred: cap reached`, with the exact command to restore it
      later.
- [ ] **Resource gate before every wave.** Restore checks `_res_mem_free_pct`
      and `_res_swap_used_mb` directly against the existing launch-guardrail
      thresholds (`CCTRL_MEM_FREE_MIN_PCT` 15, `CCTRL_MEM_FREE_SOFT_PCT` 20,
      `CCTRL_SWAP_USED_HI_MB` 8192 — cctrl:1423) and stops cleanly with
      `stopped: N of M restored, free memory X% below threshold; re-run to
      continue`. It must **not** pass `--force` to `cctrl start` (that defeats
      the guardrail) and must not rely on the guardrail's own refusal: with no
      TTY the guardrail hard-refuses (cctrl:1462), which would abort a wave
      mid-flight instead of stopping at a clean boundary.
- [ ] Never burst-spawn. Sessions go out in waves of `CCTRL_RESTORE_WAVE_SIZE`
      (default 2); a wave is complete only when every session in it is *ready*
      (below), and the gate is re-checked before the next wave.
- [ ] **Resume picker, conditional on pane content — never a blind Enter.**
      After each spawn, poll `tmux capture-pane -t <name> -p` every 2s for up to
      60s:
      - If the pane shows `Resume from summary` in **two consecutive captures
        ~1s apart** (stable render, not mid-paint), send `tmux send-keys -t
        <name> Enter` exactly once — option 1, "Resume from summary
        (recommended)", is preselected. Re-capture afterwards and confirm the
        picker string is gone; if it is still there after one retry, mark the
        session `picker-stuck` and stop touching it.
        The picker is a modal, so `_session_rich_state` should report
        `blocked-dialog` while it is up: use that as the corroborating signal
        and the literal string as the identifying one. If the two disagree
        (blocked-dialog with no picker string), treat it as some *other* modal —
        a trust or permission prompt — and mark it `picker-stuck` rather than
        sending Enter into an unknown dialog. That distinction is the whole
        reason this is conditional on pane content.
      - If the pane reaches a normal ready prompt with no picker string, record
        `picker: skipped` and move on. Small transcripts (roughly <1 MB) skip
        the picker entirely, so a blind Enter would land in the session's input
        box as a stray submit.
      - If neither state is reached inside the window, mark `picker: timeout`
        and do not send anything.
      Always option 1: full-session resume on a 14-23 MB transcript is expensive
      and lands over the ~200k handoff line immediately.
- [ ] **Large transcripts self-compact; a compacting session is not ready.**
      Readiness polling after the picker allows `CCTRL_RESTORE_READY_TIMEOUT`
      (default 180s), raised to 600s when the snapshot's `transcript_bytes`
      exceeds 10 MB. In the 2026-08-03 snapshot three transcripts were over
      10 MB (23.2, 22.2, 14.2 MB) — the normal case for long-lived sessions, not
      an edge case.
- [ ] **Readiness reuses the existing detectors; it does not invent pane
      strings.** "Ready" is defined as `_session_rich_state` (cctrl:5898)
      returning a non-`working`, non-`blocked-dialog` state. That function
      already layers `blocked-dialog` (a visible modal), `unsent-draft`,
      `waiting-input`, and `idle-done` onto plan 014's base state, is documented
      read-only ("no keystroke injection, ever"), is cost-bounded to one
      `tmux display` + one `capture-pane` + one bounded transcript tail per
      call, and fails safe to the base state on an ambiguous signal. Polling it
      is exactly the contract restore needs, and it means restore adds no second
      pane-parsing implementation to keep in sync.
- [ ] **Compaction completion is detected from the transcript, not the pane.**
      A self-compacting session writes a `type:user` entry flagged
      `isCompactSummary`, which `_session_recap` already parses (cctrl:5996).
      A restored session whose `transcript_bytes` exceeded 10 MB is not ready
      until either a new `isCompactSummary` entry appears after the resume or
      the rich state settles to a non-`working` value. Spinner text in the pane
      is a rendering detail and must not be the signal.
- [ ] Sessions with `conversation_id: null` are **never** fresh-spawned. They are
      listed as `skipped: no conversation_id`, with `transcript_path` shown when
      the snapshot has one so a human can resume manually.
- [ ] Codex sessions are restored only if 051 populated their `conversation_id`;
      otherwise `skipped: no conversation_id` like any other. No codex-specific
      branch beyond passing `--agent` through from the snapshot.
- [ ] **The snapshot's tmux session name cannot be restored, and the plan must
      not pretend otherwise.** In `_launch_detached`, `--name/-n` is a *label*,
      not the tmux name (cctrl:1548-1556): the comment is explicit that a
      friendly name "must NOT reach claude as `--name`", the tmux session name
      is derived from the target (cwd slug or `@shortcut`) and then run through
      `_pick_safe_session_index`, and a value that already looks like a tmux id
      (`TMUX--…`) is **deliberately ignored** as a realign artifact. So passing
      the snapshot's `name` back would be silently dropped. This matters most
      exactly where restore matters most: 15 of the 39 sessions in the
      2026-08-03 snapshot shared `~/dev/obsidian-vault`, so they would come back
      as `obsidian-vault`, `obsidian-vault--2`, … in spawn order, with no
      relationship to their old indices.
- [ ] Therefore **identity on restore is `purpose` + `display_label` + `cwd` +
      `conversation_id`, never the tmux name.** The tmux name is an index that
      gets re-derived. Restore passes `--purpose <purpose>` (which is what
      `session ls` shows and what a human reads) and reports an explicit
      `was <old-name> → now <new-name>` mapping line per restored session. The
      `--only` filter therefore matches on label/purpose/cwd as specified, and
      the `already-live` skip must compare on `conversation_id`, not on name —
      comparing names would both miss a restored session under a new index and
      falsely skip an unrelated session that happens to hold the old name.
- [ ] Teaching `_launch_detached` to accept an explicit tmux session name is a
      plausible alternative, but it is **out of scope**: it changes the naming
      contract for every launch path (`start -d`, `@shortcut`, doctor realign)
      and deserves its own plan. Note it in the notes; do not do it here.
- [ ] `--dry-run` prints, per candidate: the wave it lands in, the exact `cctrl
      start` argv, `transcript_bytes`, whether a picker is expected (bytes above
      the ~1 MB threshold), the expected ready timeout, and the disposition
      (`restore` / `already-live` / `no conversation_id` / `deferred: cap` /
      `filtered out`). It spawns nothing and touches no tmux state. Dry-run is
      the artifact you check before a real restore, so it must show commands, not
      a summary.
- [ ] A real restore requires `--yes`, or an interactive confirmation of the
      dry-run plan. With no TTY and no `--yes`, restore prints the plan and exits
      non-zero rather than spawning.
- [ ] `--json` emits the same plan/result structure machine-readably.
- [ ] Tests use a `CCTRL_RESTORE_LAUNCH_LOG` seam — when set, the resolved launch
      argv is appended to the log and **nothing is spawned** — mirroring
      `CCTRL_DOCTOR_RELAUNCH_LOG` (cctrl:6206). Cover: ordering by last_active;
      `--only` filtering; cap on resulting total with pre-existing live sessions;
      null `conversation_id` skipped, not fresh-spawned; dry-run spawns nothing;
      picker Enter sent for a picker pane and **not** sent for a benign pane;
      gate stop below threshold via `CCTRL_FAKE_MEM_FREE_PCT` (cctrl:1337).
- [ ] Full suite passes.

## Design

Last of the three. 051 makes the link durable, 052 makes the fleet durable, 053
makes the rebuild one command.

**On the resource gate's metric.** The gate reuses `_res_mem_free_pct`, which on
macOS reads `memory_pressure`'s "System-wide memory free percentage" — a pressure
metric that accounts for compression and purgeable memory, not naive free RAM.
That matters because the operator's own hard-won rule is that raw free RAM lies
(2026-07-20: 1.0 GB "free" with an idle compressor and a shrinking swap file was
zero actual pressure, and sessions were closed for nothing). `memory_pressure`'s
number is the better of the two available signals and is already what the launch
guardrail and `cctrl fleet` use, so restore uses it too. Gating on compressor
occupancy and swap-in rate instead would be a change to the guardrail itself,
affecting every launch — out of scope here, and it should not be invented inside
a restore command.

**Why re-runnable beats resumable-state.** Restore keeps no cursor or partial
state. Skipping already-live names means the recovery procedure after any stop —
cap reached, memory low, a `picker-stuck` session — is literally the same
command again. No state file to go stale, no `--continue` flag.

**Failure isolation.** One session failing to spawn, sticking at the picker, or
timing out during compaction never aborts the run: it is recorded and the wave
moves on. The final report groups every session by disposition, and the exit code
is non-zero only if *nothing* was restored.

**Files expected to change:**

- `cctrl`: `_session_restore` (+ `_restore_wait_picker`, `_restore_wait_ready`),
  `cmd_session` dispatch, help lines
- `README.md`: restore section, the flags, the cap/gate/wave defaults, and the
  "resume the conversation, never replay initial_prompt" rule
- `skills/cctrl-fleet-manager/SKILL.md`: post-outage recovery — snapshot exists,
  run `session restore --dry-run` first, restore in waves, respect the cap
- `tests/run-tests.sh`: the restore tests above
- `CHANGELOG.md`: Added entry

**Testing approach: E2E** — real binary, fake tmux, fixture snapshot files, the
`CCTRL_RESTORE_LAUNCH_LOG` seam, and `CCTRL_FAKE_MEM_FREE_PCT` for the gate. No
real agent is launched by any test.

**Out of scope:** restoring to a different machine or across hosts; recreating
tmux window/pane layout; reattaching sessions to terminal tabs (that is the
spawn skill's step 5, environment-specific); reviving sessions with no
`conversation_id`; any change to the launch guardrail's metric or thresholds.

## Tasks

1. Snapshot reader + `schema_version` check + candidate ordering and `--only`
   filtering.
2. Disposition pass: `already-live`, `no conversation_id`, cap on resulting
   total, `--limit`; build the plan structure.
3. `--dry-run` / `--json` plan rendering with exact argv per candidate.
4. Wave executor: pre-wave resource gate, spawn via the detached-launch path,
   per-session tracking.
5. `_restore_wait_picker` — two-consecutive-capture confirmation, single Enter,
   post-send verification, `picker-stuck` / `timeout` states.
6. `_restore_wait_ready` — compaction-aware readiness with the >10 MB timeout
   bump.
7. Final grouped report and exit-code rule; `--yes` / TTY confirmation gate.
8. Add the `CCTRL_RESTORE_LAUNCH_LOG` seam; write the tests; wire help, README,
   and the fleet-manager skill's recovery section. Run the full suite.

## Verification

Checks:

Check format note: tag outside the backticks — see the same note in plan 051.

- [cmd] `bash tests/run-tests.sh`
- [cmd] `grep -q "_session_restore" cctrl`
- [cmd] `grep -q "Resume from summary" cctrl` — the picker match is on literal pane text
- [cmd] `grep -q "CCTRL_RESTORE_LAUNCH_LOG" cctrl`
- [cmd] `grep -q "CCTRL_RESTORE_MAX_ACTIVE" cctrl`
- [assert] `cat README.md` contains session restore
- [assert] `./cctrl session restore --help 2>&1` contains --dry-run
- [assert] `./cctrl session restore --help 2>&1` contains --only
- [cmd] `bash -c '! sed -n "/_session_restore()/,/^}/p" cctrl | grep -q "initial_prompt"'` — restore never replays a stored prompt (shell-dependent, not probeable at authoring time)

<!-- mstack:seam
produced:
- kind: command; name: session restore; file: cctrl
assumed:
- from: 051; kind: schema; name: conversation_id; file: data/sessions/*.json
- from: 052; kind: schema; name: data/snapshots/latest.json; file: cctrl
-->
