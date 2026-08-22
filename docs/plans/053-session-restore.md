---
id: 053
title: cctrl session restore — waved, gated, dry-runnable fleet rebuild (human-in-the-loop)
status: done
blocked-by: [051, 052]
priority: 7
goal: fleet-restore-after-power-loss
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-08-03
completed: 2026-08-07
---

## Requirements

**Scope note (2026-08-05, post-audit re-scope).** An earlier draft of this plan
automated the resume picker (conditional `tmux send-keys Enter`) and inferred
per-session readiness from `_session_rich_state` to auto-release waves. An
independent cross-model audit (`docs/reviews/2026-08-05-fable-architecture-audit.md`,
findings F1/F2/F3) showed both mechanisms were built on false premises against
the current detectors — the resume picker matches none of
`_session_pane_has_dialog`'s signatures, so the specified corroboration could
never fire, and codex sessions can never satisfy the readiness allow-list —
and would have failed their first real run. That automation is now **deferred**
(see "Deferred: full automation" below and the TODOS entry) behind explicit
gates, plan 038 among them. This plan ships the half two reviews hardened:
the reader, the gates, the plan rendering, and waves — with a human releasing
each wave and answering pickers. **Restore performs no pane capture, no
keystroke injection, and no readiness inference. Ever.**

With 051 persisting `conversation_id` and 052 capturing the fleet, rebuilding
after a power-off is still a manual loop: read the snapshot, pick which sessions
matter, run `cctrl start -d <cwd> -r <uuid> -n <label>` for each, watch for the
resume picker, answer it, and stop before the machine thrashes. That loop was
run by hand on 2026-08-02 and twice on 2026-08-03. This plan automates the parts
a human gets wrong under pressure — the resource gate, the cap, and knowing what
will happen before it happens — and deliberately leaves the human the one part
they are *better* at than a pane-scraper: looking at a screen and pressing
Enter.

`cctrl session restore [--from latest|<path>] [--only <pattern>] [--dry-run]
[--limit N] [--yes]` reads a snapshot and respawns sessions by **resuming their
conversations**.

**Resume the conversation; never replay `initial_prompt`.** Those stored prompts
reference sibling sessions that no longer exist ("two siblings are live right
now", "I dispatched it minutes ago") and actively mislead a restored session into
coordinating with ghosts. 052 does not capture the field, so the snapshot cannot
tempt anyone — but the **session record still persists `initial_prompt`**
(the `_session_write_metadata` schema; populated in 39 of the 105 current
records), so the fallback is always one `_session_metadata_field` call away. The
rule is therefore stated as a prohibition on restore itself, not as an accident
of the snapshot's shape: **restore never reads `initial_prompt` from any
source.** A session with no `conversation_id` is reported and skipped, full stop.

**Acceptance criteria:**

- [ ] `cctrl session restore` reads `data/snapshots/latest.json` by default;
      `--from <path>` reads a specific history file. A snapshot whose
      `schema_version` is unknown is refused with the version it saw.
      Because 052 writes the history file *before* `latest.json`, a crash between
      the two leaves a history file newer than `latest.json`: when that is the
      case, restore uses the newest valid history file and says so, rather than
      silently reading a `latest.json` it can already see is stale.
- [ ] **Snapshot freshness is checked, not assumed.** 052 records `generated_at`
      and nothing reads it. Two things make a cold snapshot look identical to a
      fresh one: the timer is a LaunchAgent, so it stops entirely when the user
      is not logged into the GUI, and 052's empty-fleet guard *deliberately*
      preserves `latest.json` rather than overwriting it — a file frozen weeks
      ago is byte-for-byte indistinguishable from one written four minutes ago.
      Restore therefore prints the snapshot's age on every run (dry-run included,
      in the header), and past `CCTRL_RESTORE_MAX_SNAPSHOT_AGE` (default 24h)
      requires `--yes` or an explicit `--stale-ok` before it will spawn. The age
      line is unconditional; only the gate is thresholded.
- [ ] **Refuse a snapshot from another host unless overridden.** 052 records
      `hostname`; cross-host restore is explicitly out of scope for this plan, so
      a mismatch is refused with both hostnames named and a `--force-host` escape
      rather than silently rebuilding another machine's fleet against local cwds
      that may not exist.
- [ ] Candidate selection: sessions are ordered by `last_active` descending
      (most recently worked on first), `--only <pattern>` filters by
      case-insensitive substring against `name`, `display_label`, `purpose`, and
      `cwd`, and `--only` may be repeated (union). **A session whose
      `conversation_id` is already live is skipped as `already-live`** — never
      matched on tmux name, for the reason set out under identity below — which
      makes a partial restore resumable by re-running the same command.
- [ ] **The already-live check joins live sessions back to their metadata
      records; it does not read the live JSON's `session_id` alone.**
      `_session_list --json` reports `session_id` from the *live per-PID Claude
      file*, which a just-restored session does not populate until the agent has
      booted — and a codex session never populates at all. A restore that
      compares the snapshot's `conversation_id` against live `session_id` will
      therefore see its own just-spawned sessions as not-live and respawn them on
      a re-run, which is exactly the duplicate this check exists to prevent. The
      live set must be built as: for each live tmux session, its
      `conversation_id` from the session record (051), falling back to live
      `session_id` when the record has none. Record first, live second.
- [ ] **Cap on the resulting total, not on the number spawned.** Restore stops
      once the live **cctrl-managed** session count reaches
      `CCTRL_RESTORE_MAX_ACTIVE` (default 8). Restore calls
      `_active_session_count` for this — **plan 051 fixes that function** to
      `jq '[.[] | select(.managed)] | length'`, matching its own comment.
      Restore must NOT carry a private copy of that jq expression: two counts
      for one concept drift, and the guardrail and `cctrl fleet` read the same
      function. The working limit is ~8-10 active and snapshots routinely hold
      20+, so a cap on "how many I spawn" is the wrong axis — it ignores
      whatever is already running. `--limit N` additionally caps spawns in this
      invocation. Everything past the cap is reported as `deferred: cap
      reached`, with the exact command to restore it later.
      **The cap fails CLOSED, not open.** `_active_session_count` collapses any
      `_session_list` failure to `0` (its `[[ "$n" =~ ^[0-9]+$ ]] || printf '0'`
      fallback). For the launch guardrail that bias is acceptable — one launch
      slips through. For a restore loop it is not: a transient tmux failure
      mid-restore would read as "empty fleet" and admit a full wave over the
      cap, under exactly the degraded post-outage conditions restores run in.
      Restore must therefore distinguish "count unavailable" from "count is
      zero" (call `_session_list --json` itself and check the exit/parse, or
      extend the helper) and treat unavailable as **stop the run** with a
      clear message, never as headroom. Audit finding F8.
- [ ] **Restore replays the captured launch configuration, not just `--agent`.**
      052 captures `model` and a parsed `launch_flags` object; restore threads
      them back onto the `cctrl start` argv (`--model`, `--profile`,
      `--permission-mode`, `--sandbox`, `--ask-for-approval`, `--no-bridge`,
      `--peer`). Without this, restore is not fleet restoration — every session
      comes back on post-reboot defaults. That is live on the current fleet: five
      records carry an explicit `--model` (`claude-fable-5` ×2, `fable`,
      `claude-opus-5`, `claude-opus-4-6`), so a third of the fleet would come
      back on the wrong model with no indication. Any flag the snapshot could not
      parse is reported per session as `launch config: partial (<flag> not
      restored)` rather than silently dropped, and `--dry-run` shows the fully
      resolved argv including these flags.
- [ ] **Resource gate before every wave.** Restore checks `_res_mem_free_pct`
      and `_res_swap_used_mb` directly against the existing launch-guardrail
      thresholds (`CCTRL_MEM_FREE_MIN_PCT` 15, `CCTRL_MEM_FREE_SOFT_PCT` 20,
      `CCTRL_SWAP_USED_HI_MB` 8192 — `_launch_resource_guardrail`) and stops
      cleanly with `stopped: N of M restored, free memory X% below threshold;
      re-run to continue`. It must **not** pass `--force` to `cctrl start` (that
      defeats the guardrail) and must not rely on the guardrail's own refusal:
      with no TTY the guardrail hard-refuses, which would abort a wave
      mid-flight instead of stopping at a clean boundary.
- [ ] Never burst-spawn. Sessions go out in waves of `CCTRL_RESTORE_WAVE_SIZE`
      (default 2). **Wave advance is human-released, not inferred.**
      - *Interactive (TTY):* after each wave spawns, restore prints the wave
        report (below) and prompts `Release wave N+1? [y/N/q]` — `y` re-checks
        the resource gate and proceeds, `N`/Enter stops cleanly at the wave
        boundary (re-run to continue, same idempotent command), `q` likewise
        stops. The operator decides when the fleet looks settled, using
        `cctrl session ls` in another pane if they want detail.
      - *Non-interactive (`--yes`, no TTY):* waves advance after the resource
        gate re-check plus a fixed pause of `CCTRL_RESTORE_WAVE_PAUSE` seconds
        (default 60). This is pacing, not readiness detection — the pause is
        documented as "time for the previous wave's resumes to boot and start
        compacting before the gate is re-read", and the gate (memory pressure)
        is the actual protection.
- [ ] **Per-wave report tells the human where the pickers are.** For each
      spawned session, the report line shows: `was <old-name> → now <new-name>`,
      the purpose, `transcript_bytes`, and — when `transcript_bytes` exceeds the
      ~1 MB picker threshold — `picker expected: tmux attach -t <new-name>
      (option 1 "Resume from summary" is preselected; press Enter)`. Small
      transcripts get `picker: not expected`. Restore itself never captures the
      pane to check; the threshold is advisory routing for the human, computed
      from snapshot data alone. Codex sessions get `picker: n/a (codex)`.
- [ ] **No pane inference, structurally asserted.** The `_session_restore` body
      (and any helper it introduces) contains no `send-keys`, no `paste-buffer`,
      no `load-buffer`, and no `capture-pane`. This is the same class of assert
      as 052's no-mutation check, one notch stronger: the earlier draft's
      conditional-Enter machinery is out of scope entirely, so even *reading*
      panes has no business here — its presence would mean the deferred
      automation is being smuggled in without its gates.
- [ ] Sessions with `conversation_id: null` are **never** fresh-spawned. They are
      listed as `skipped: no conversation_id`, with `transcript_path` shown when
      the snapshot has one so a human can resume manually.
- [ ] Codex sessions are restored only if 051 populated their `conversation_id`;
      otherwise `skipped: no conversation_id` like any other. No codex-specific
      branch beyond passing `--agent` through from the snapshot and the
      `picker: n/a (codex)` report line.
- [ ] **The snapshot's tmux session name cannot be restored, and the plan must
      not pretend otherwise.** In `_launch_detached`, `--name/-n` is a *label*,
      not the tmux name: the comment is explicit that a friendly name "must NOT
      reach claude as `--name`", the tmux session name is derived from the
      target (cwd slug or `@shortcut`) and then run through
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
      the ~1 MB threshold), and the disposition (`restore` / `already-live` /
      `no conversation_id` / `deferred: cap` / `filtered out`). It spawns
      nothing and touches no tmux state. Dry-run is the artifact you check
      before a real restore, so it must show commands, not a summary — and its
      argv lines double as the copy-paste manifest if the operator prefers to
      run the loop entirely by hand.
- [ ] A real restore requires `--yes`, or an interactive confirmation of the
      dry-run plan. With no TTY and no `--yes`, restore prints the plan and exits
      non-zero rather than spawning.
- [ ] `--json` emits the same plan/result structure machine-readably.
- [ ] Tests use a `CCTRL_RESTORE_LAUNCH_LOG` seam — when set, the resolved launch
      argv is appended to the log and **nothing is spawned** — mirroring
      `CCTRL_DOCTOR_RELAUNCH_LOG`. Cover: ordering by last_active;
      `--only` filtering; cap on resulting total with pre-existing live sessions;
      null `conversation_id` skipped, not fresh-spawned; dry-run spawns nothing;
      gate stop below threshold via `CCTRL_FAKE_MEM_FREE_PCT`. Plus:
      - **`--limit N`** caps spawns in this invocation independently of the cap.
      - **No TTY and no `--yes`** prints the plan, spawns nothing, exits 2.
      - **Unknown `schema_version`** is refused, naming the version it saw.
      - **Stale snapshot past the threshold** without `--yes`/`--stale-ok`
        refuses; the age line is printed even when fresh.
      - **Host mismatch** refuses without `--force-host`.
      - **Cap fails closed**: a `_session_list` failure (fake tmux exiting
        non-zero mid-run) stops the run with the count-unavailable message and
        spawns nothing further — it is NOT treated as zero live sessions.
      - **Picker-expected routing**: a snapshot row with `transcript_bytes`
        above the threshold produces the `picker expected` report line with the
        attach command; below it, `picker: not expected`; codex, `n/a`.
      - **Non-interactive wave pacing**: with `--yes` and no TTY, the launch
        log shows wave 2's spawns only after the gate re-check (drive with
        `CCTRL_RESTORE_WAVE_PAUSE=0` to keep the test fast).
      - **Interactive stop at wave boundary**: answering `N` to the release
        prompt stops cleanly; a re-run skips the wave-1 sessions as
        `already-live` (via the record join) and plans wave 2 first.
      - **Exit codes**: all-already-live re-run exits 0; a spawn failure exits 1;
        an unreadable snapshot exits 2.
      - **Launch config replay**: a snapshot row with
        `launch_flags.model = claude-fable-5` produces a launch argv containing
        `--model claude-fable-5` in the `CCTRL_RESTORE_LAUNCH_LOG`.
      - **Restore never passes `--force`** to `cctrl start` — structural assert
        over the `_session_restore` body, mirroring the no-send-keys assert in 052.
      - **No pane inference** — structural assert: the `_session_restore` body
        contains no `send-keys`, `paste-buffer`, `load-buffer`, or
        `capture-pane`.
      - **already-live joins on the record**: a live session whose *record* has
        the conversation_id but whose live `session_id` is still empty is
        recognised as already-live and not respawned.
- [ ] Full suite passes.

## Design

Last of the three. 051 makes the link durable, 052 makes the fleet durable, 053
makes the rebuild one command — with a human in the loop where a human belongs.

**Why human-in-the-loop instead of automated readiness (the re-scope
rationale).** The earlier draft's automation rested on pane/state inference,
and the audit showed each leg was wrong against the shipped detectors: the
resume picker matches none of `_session_pane_has_dialog`'s signatures (so the
specified `blocked-dialog` corroboration could never fire — F1); codex
sessions can never reach an allow-listed readiness state because every such
state requires an `idle` base from the per-PID *Claude* file codex never
writes (F2); and the picker's own selection line plausibly matches the
unsent-draft regex, an allow-listed "settled" state (F3). Those are not
implementation bugs to be caught later — they were in the cleared spec, after
two model reviews. Pane-scraping code needs live-fire iteration this event
(twice a year, verified against the reboot log) cannot provide. Meanwhile the
operator is *always present* during a real restore — someone rebooted the
machine — and answering a picker is seconds of their time. So the human keeps
the eyes-on-screen job; the tool keeps the jobs humans fumble under pressure:
argv construction, ordering, the cap, the memory gate, and idempotent
re-runnability.

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
state. Skipping already-live conversations means the recovery procedure after
any stop — cap reached, memory low, operator declined a wave — is literally the
same command again. No state file to go stale, no `--continue` flag.

**Failure isolation.** One session failing to spawn never aborts the run: it is
recorded and the wave moves on. The final report groups every session by
disposition.

**Exit code.** Non-zero means "this run could not do the thing you asked",
which is narrower than "nothing was restored". An earlier draft said non-zero
whenever nothing was restored — that breaks the re-runnability this design is
built on, because the *successful* second run, where every candidate is already
live, restores nothing and would exit non-zero. The rule is therefore:

```
  exit 0   every candidate ended in a benign disposition:
           restored / already-live / filtered out / deferred: cap /
           stopped-at-wave-boundary by the operator
           (this covers the idempotent re-run: all already-live → 0)
  exit 1   at least one candidate was selected for restore and FAILED
           (spawn error)
  exit 2   the run could not start or continue safely: unreadable or
           unknown-schema snapshot, host mismatch without --force-host,
           stale beyond threshold without --yes/--stale-ok, no TTY and no
           --yes, or live-count unavailable (cap fails closed)
```

`skipped: no conversation_id` is benign for exit-code purposes — it is a
documented limitation of the data, not a failure of this run — but it is always
reported, and the summary line names the count so it cannot pass unnoticed.

**Deferred: full automation (picker Enter + readiness-released waves).** The
automation is not abandoned; it is gated. It may be revived as its own plan
only when ALL of the following hold (tracked in TODOS.md):

1. A real power event demonstrates the human-in-the-loop flow is the actual
   bottleneck (the Aug 2-3 events were bottlenecked on UUID archaeology, which
   051 removes, not on picker-pressing).
2. The two Claude-modal detectors (`_peer_pane_ready_for_delivery`'s claude
   arm vs `_session_pane_has_dialog`) are unified, the picker signature is
   added deliberately, and the fixture is a **dated `tmux capture-pane` dump
   of the real picker**, not hand-typed text (audit findings F1/A4, and the
   fixture-provenance rule).
3. Codex readiness is defined explicitly (F2) and the draft-detector picker
   overlap is excluded (F3).
4. Plan 038 (per-session policy at the tool boundary) has landed, so a
   misfired keystroke no longer lands in a `bypassPermissions` session by
   default.

**Files expected to change:**

- `cctrl`: `_session_restore`, `cmd_session` dispatch, help lines
- `README.md`: restore section, the flags, the cap/gate/wave defaults, the
  "resume the conversation, never replay initial_prompt" rule, and the
  picker-answering step (attach, Enter)
- `skills/cctrl-fleet-manager/SKILL.md`: post-outage recovery — snapshot exists,
  run `session restore --dry-run` first, restore in waves, answer pickers on
  attach, respect the cap
- `tests/run-tests.sh`: the restore tests above
- `CHANGELOG.md`: Added entry

**Testing approach: E2E** — real binary, fake tmux, fixture snapshot files, the
`CCTRL_RESTORE_LAUNCH_LOG` seam, and `CCTRL_FAKE_MEM_FREE_PCT` for the gate. No
real agent is launched by any test.

**Out of scope:** picker automation and readiness inference (deferred, gated —
see Design); restoring to a different machine or across hosts; recreating
tmux window/pane layout; reattaching sessions to terminal tabs (that is the
spawn skill's step 5, environment-specific); reviving sessions with no
`conversation_id`; any change to the launch guardrail's metric or thresholds.

## Tasks

1. Snapshot reader: `schema_version` check, `generated_at` age line + staleness
   gate, hostname match, newest-history-beats-stale-`latest` fallback; candidate
   ordering and `--only` filtering.
2. Disposition pass: `already-live` (joined on the session record's
   `conversation_id`, live `session_id` as fallback), `no conversation_id`, cap
   on resulting total via the 051-fixed `_active_session_count` **with the
   fail-closed count check**, `--limit`; build the plan structure.
3. `--dry-run` / `--json` plan rendering with exact argv per candidate,
   including the replayed `launch_flags` and the picker-expected column.
4. Wave executor: pre-wave resource gate, spawn via the detached-launch path
   with the captured launch configuration threaded on, per-session tracking,
   the per-wave report with picker routing, and the human release prompt
   (TTY) / gated pause (`--yes`, `CCTRL_RESTORE_WAVE_PAUSE`).
5. Final grouped report and the three-way exit-code rule; `--yes` / TTY
   confirmation gate.
6. Add the `CCTRL_RESTORE_LAUNCH_LOG` seam; write the tests including both
   structural asserts (no `--force`; no pane verbs); wire help, README,
   and the fleet-manager skill's recovery section. Run the full suite.

## Verification

Checks:

Check format note: tag outside the backticks — see the same note in plan 051.

- [cmd] `bash tests/run-tests.sh`
- [cmd] `grep -q "_session_restore" cctrl`
- [cmd] `grep -q "CCTRL_RESTORE_LAUNCH_LOG" cctrl`
- [cmd] `grep -q "CCTRL_RESTORE_MAX_ACTIVE" cctrl`
- [cmd] `grep -q "CCTRL_RESTORE_WAVE_PAUSE" cctrl`
- [assert] `cat README.md` contains session restore
- [assert] `./cctrl session restore --help 2>&1` contains --dry-run
- [assert] `./cctrl session restore --help 2>&1` contains --only
- [cmd] `bash -c '! sed -n "/_session_restore()/,/^}/p" cctrl | grep -q "initial_prompt"'` — restore never replays a stored prompt (shell-dependent, not probeable at authoring time)
- [cmd] `bash -c '! sed -n "/_session_restore()/,/^}/p" cctrl | grep -Eq "send-keys|paste-buffer|load-buffer|capture-pane"'` — restore performs no pane inference or keystroke injection (same)

<!-- mstack:seam
produced:
- kind: command; name: session restore; file: cctrl
assumed:
- from: 051; kind: schema; name: conversation_id; file: data/sessions/*.json
- from: 052; kind: schema; name: data/snapshots/latest.json; file: cctrl
-->

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | issues_found | 11 findings, 10 accepted, 1 dismissed |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | clean | 18 issues, 3 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

Reviewed 2026-08-05 at commit `1339aa2` as part of the 051→052→053 batch.

**Changes folded in by the eng review (2026-08-05):** the `already-live`
self-contradiction resolved to `conversation_id` with the record join; readiness
changed from a negative form to an allow-list; the three-way exit-code rule; the
`and`-gated compaction check; launch-configuration replay; snapshot age and
hostname validation; the history-newer-than-`latest` fallback. Fourteen test
gaps added.

**Empirically verified during review:** `claude --resume <uuid>` preserves the
conversation UUID — five of five live resumed sessions report a `session_id`
identical to the UUID they were resumed from. Keying `already-live` on
`conversation_id` is sound.

**CODEX:** Five of the eleven outside-voice findings landed here — launch
configuration replay, the `already-live` JSON-contract gap, loose readiness, the
contradictory compaction rule, the exit-code rule, and missing host validation.
All accepted.

**FABLE AUDIT RE-SCOPE (2026-08-05, post-clearance):** an independent
cross-model audit (`docs/reviews/2026-08-05-fable-architecture-audit.md`) found
two P1 defects in the cleared spec's automation layer — the picker's
`blocked-dialog` corroboration could never fire against
`_session_pane_has_dialog`'s actual signatures (F1), and the readiness
allow-list was unsatisfiable for codex sessions, guaranteeing a ~4-minute stall
and a spurious exit 1 per codex session (F2) — plus a plausible
picker-reads-as-`unsent-draft` misclassification (F3) and a fail-open cap on
`_active_session_count` errors (F8). Disposition: the picker/readiness
automation (`_restore_wait_picker`, `_restore_wait_ready`, and their tests) is
**removed from this plan** and deferred behind the four gates listed in Design;
waves are human-released; the cap fails closed; the no-pane-inference
structural assert replaces the picker-string checks. The eng review's
hardening of the surviving half (gates, dispositions, replay, exit codes,
record join) is retained unchanged. *Provenance: the re-scope was the
auditor's recommendation ("Option A"), implemented under Matthew's general
write grant and endorsed implicitly when he directed execution of the
re-scoped plans — he did not explicitly pick between the offered options
(recorded per the plan-035 provenance-precision precedent).*

**VERDICT:** ENG CLEARED as re-scoped — ready to implement (blocked on 051 and
052 by design). The deferred automation requires a NEW plan and a fresh eng
review; it must not be revived by editing this one.

NO UNRESOLVED DECISIONS
