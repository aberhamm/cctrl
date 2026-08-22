---
id: 052
title: cctrl session snapshot — periodic, atomic, side-effect-free fleet capture
status: done
blocked-by: [051]
priority: 6
goal: fleet-restore-after-power-loss
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-08-03
completed: 2026-08-07
---

## Requirements

Once 051 persists `conversation_id`, the fleet's shape is recoverable from the
session records — but only for sessions cctrl still has records for, and only by
someone willing to iterate 105 JSON files. What the fleet manager actually needs
after a power-off is one file that says what was running, what it was for, and
which conversation to resume. That file exists today: it was written by hand
(`<private-infra-repo>/fleet/restore-manifest.md`, 2026-08-03, 39 rows), and it
went stale the moment the fleet changed. This plan generates it.

`cctrl session snapshot` writes the whole live fleet to
`data/snapshots/latest.json` plus a timestamped history file, and a launchd
timer runs it on an interval so the fleet survives an unplanned power cut.

The snapshot has to be safe to run unattended every few minutes: cheap, atomic,
and with **zero** effect on running sessions. Specifically no `tmux send-keys`,
no `tmux paste-buffer`, no pane mode changes, no mailbox writes, no metadata
writes beyond 051's already-guarded refresh.

**Acceptance criteria:**

- [ ] `cctrl session snapshot [--dir PATH] [--allow-empty] [--json] [--quiet]`
      writes `data/snapshots/latest.json` and
      `data/snapshots/<UTC YYYYMMDDTHHMMSSZ>.json` with identical content.
      `data/` is already gitignored, so snapshots never enter the repo.
- [ ] Per-session fields: `name`, `display_label`, `cwd`, `target`,
      `target_kind`, `purpose`, `agent`, `conversation_id`, `transcript_path`,
      `transcript_bytes`, `state` (rich state), `attached`, `remote_control`,
      `last_active`, `created_at`, `peer`, `host`, `managed`.
- [ ] `initial_prompt` is **deliberately not stored**. Restoring by replaying a
      stored initial prompt is wrong: those prompts reference sibling sessions
      that no longer exist ("two siblings are live right now", "I dispatched it
      minutes ago") and actively mislead a restored session. Resuming the
      conversation is the only correct restore. Omitting the field from the
      snapshot is the enforcement — you cannot replay what was never captured.
      A comment in the writer states this so nobody helpfully adds it back.
- [ ] Header fields: `schema_version`, `generated_at` (UTC ISO-8601),
      `hostname`, `session_count`, and a `resource_line` string.
      **Build the header from parts already in hand — do not call
      `_res_health_line` (cctrl:1408).** That function calls
      `_active_session_count`, which runs a *second* full `_session_list
      --json` enumeration purely to embed a count this snapshot has already
      computed from its own rows. At the measured ~106ms/session that doubles
      every tick (~6s, not ~3s, at 30 sessions). Derive `session_count` from
      the captured rows and compose `resource_line` from the three cheap
      probes directly (`_res_mem_free_pct`, `_res_swap_used_mb`,
      `_res_load1`), matching `_res_health_line`'s format so the string stays
      grep-compatible with `cctrl fleet` output.
- [ ] "Context size" is recorded as `transcript_bytes` (`stat -f %z … ||
      stat -c %s …` — the `-f %z` form is Darwin-only, and every other probe
      in cctrl already carries a Linux branch, e.g. `_res_mem_free_pct` /
      `_res_swap_used_mb`), not tokens. cctrl has no token-context probe — verified,
      nothing in the script measures one. Bytes is the signal restore decisions
      actually key off: whether the resume picker is worth answering and whether
      the session will self-compact. Naming it `transcript_bytes` keeps that
      honest.
- [ ] Atomic write: `mktemp` **inside the target directory** then `mv`. A
      `mktemp` in `$TMPDIR` can land on a different filesystem, where `mv` is a
      copy and a power cut mid-write leaves a truncated `latest.json`. The
      history file is written first, then `latest.json`, so a crash between them
      loses nothing.
      **Claim scoped honestly: same-dir `mktemp` + `mv` gives atomic *rename*,
      not durability.** Without an `fsync` of the file and its directory, a hard
      power cut can still lose the most recent write even though the rename was
      issued — the rename is atomic with respect to *readers*, not with respect
      to power loss. Portable `fsync` from bash is not really available (`sync`
      is whole-filesystem and too coarse to run every 5 minutes), so the correct
      resolution is to state the limit rather than overstate the guarantee: the
      snapshot is crash-*consistent* (you never read a half-written file), not
      crash-*durable* (you may lose the last interval). That is exactly the
      5-minute worst case the interval already budgets for, so nothing else
      changes. README says the same in one line.
- [ ] Because the history file is written before `latest.json`, a crash between
      the two leaves a history file newer than `latest.json`. `session restore`
      (053) must therefore fall back to the newest valid history file when it is
      newer than `latest.json`, rather than silently reading a `latest.json` it
      can see is stale. Recorded here because it is this plan's write order that
      creates the case.
- [ ] **Empty-fleet guard.** If the capture yields zero sessions and the
      existing `latest.json` has more than zero, `latest.json` is left alone and
      the run exits 0 with a one-line note. `--allow-empty` overrides. This is
      the single most important safety rule here: a snapshot taken at boot, or
      while the tmux server is down, would otherwise overwrite the only record of
      the fleet you are trying to restore with `[]`.
      **Known consequence: the guard has no expiry, so a preserved `latest.json`
      is immortal.** Deliberately closing every session leaves the file frozen at
      the last non-empty state forever, and a restore months later would
      resurrect dead work with no signal that it is doing so. The guard is still
      correct — the failure it prevents (losing the fleet record at exactly the
      moment you need it) is far worse than the one it creates — but the
      mitigation lives in 053, which must surface the snapshot's `generated_at`
      age on every run and gate past a threshold. Restated here so the two plans
      cannot drift apart: **052 freezes, 053 must notice.** The `generated_at`
      header field exists for this and is not decorative.
      When the guard fires, the one-line note states the age of the `latest.json`
      being preserved, so `--allow-empty` is a visible choice rather than a
      thing you have to know about.
- [ ] If the capture yields zero sessions and there is **no** existing
      `latest.json` at all (first run on an empty fleet), write the empty
      snapshot normally. There is nothing to clobber, and refusing would leave
      the install with no snapshot file and no explanation.
- [ ] No tmux mutation on the snapshot path. Asserted structurally: the snapshot
      function contains no `send-keys`, `paste-buffer`, `load-buffer`, or
      `set-option`. Read-only tmux calls (`list-sessions`, `list-panes`,
      `display-message`, `show-option -qv`) are fine.
- [ ] Built on `_session_list --json`. **The full emitted object (cctrl:6119) is
      17 keys**, not the 12 an earlier draft of this plan listed: `name`,
      `managed`, `agent`, `claude`, `model`, `dir`, `state`, `attached`,
      `remote_control`, `bridge`, `session_id`, `transcript`, `last_active`,
      `purpose`, `created_at`, `peer`, `display_label` (plus `recap` under
      `--recap`). The omission mattered: `managed` and `attached` are both
      required snapshot fields, and `managed` in particular is *not* a simple
      record read — `_session_list` computes it as a three-way OR at cctrl:6058
      (record `cctrl_managed`, the tmux `@cctrl_managed` option, or a
      `--name TMUX--` argv shape), because sessions predating the metadata field
      satisfy only one of the three. Taking `cctrl_managed` from the record
      instead would mark sessions unmanaged that `session ls` shows with ✦, and
      053's cap counts that field.
- [ ] **Per-field source table** — every snapshot field names its origin, so no
      field's provenance is left to inference:

      | Snapshot field | Source |
      |---|---|
      | `name`, `state`, `attached`, `managed`, `remote_control`, `agent`, `last_active`, `purpose`, `created_at`, `peer`, `display_label` | `_session_list --json`, same key |
      | `conversation_id` | `_session_list --json` key `session_id` (renamed) |
      | `transcript_path` | `_session_list --json` key `transcript` (renamed — the JSON key is `transcript`, do not assume the names match) |
      | `model` | `_session_list --json`, same key |
      | `transcript_bytes` | `stat -f %z` on `transcript_path`; `null` when the path is empty or unreadable |
      | `cwd`, `target`, `target_kind`, `host` | session record (`data/sessions/<name>.json`) |
      | `launch_flags` | parsed from the record's `launch_command` (see below) |

- [ ] **Capture the launch configuration, not just `agent`.** A snapshot that
      records what was running but not *how* it was running does not support
      restoration: 053 would bring every session back on whatever the defaults
      are after reboot. This is live on the current fleet — five records carry an
      explicit `--model` (`claude-fable-5` ×2, `fable`, `claude-opus-5`,
      `claude-opus-4-6`) and `session ls --json` reports a populated `model` for
      10 of 11 live sessions, so a restore today would silently downgrade or
      switch the model on a third of the fleet. Capture `model` from the JSON,
      and a `launch_flags` object parsed from the record's `launch_command`
      (cctrl:1258) covering the agent-level passthrough: `--model`, `--profile`,
      `--permission-mode`, `--sandbox`, `--ask-for-approval`, `--no-bridge`,
      `--peer`. **Parse to a structured object; never store the raw
      `launch_command` for replay** — it embeds the old tmux session name,
      `CCTRL_SESSION_NAME`, and a full env prefix, none of which survive a
      restore under a re-derived name. Flags that cannot be parsed are omitted,
      not guessed, and 053 reports which ones it could not restore.
- [ ] `--recap` is **not** used — it adds an unbounded-ish per-session recap
      parse. But do not claim the snapshot performs no transcript reads: it
      does. `_session_list` always computes rich state, and
      `_session_rich_state` (cctrl:5898) is documented as costing up to one
      `tmux display` + one `capture-pane` + **one bounded transcript tail read**
      per session. The correct cost statement is "bounded per session", not
      "none", and the 5-minute interval is justified against that.
- [ ] `transcript` is resolved via `_session_transcript_path`, which globs the
      **Claude** `sessionId`; codex sessions have no Claude transcript, so their
      `transcript_path`/`transcript_bytes` are `null`. The snapshot records that
      honestly rather than substituting the codex rollout path, and plan 053
      keys its picker/compaction decisions off `transcript_bytes` only when
      non-null.
- [ ] Because `_session_list` carries 051's refresh, every timer tick also
      self-heals `conversation_id` on the live fleet. Say so in the notes — it
      is a real property, and it is the reason this plan is blocked by 051.
- [ ] Runs when tmux is down or absent — but these are **two different paths**
      and the empty-fleet guard only covers one of them:
      - *tmux installed, no server running*: `tmux list-sessions` yields
        nothing, `_session_list` echoes `[]` and returns 0. The empty guard
        catches this, `latest.json` is preserved, exit 0.
      - *tmux binary absent*: `_session_list` calls `_session_require_tmux`,
        which prints `tmux not found.` to stderr and **returns 1**
        (cctrl:5542). `_session_list` propagates that non-zero before any JSON
        is produced, so the guard never sees `[]`. Snapshot must check the
        return code explicitly, write nothing, and exit 0 with a one-line note.
        Treating a non-zero `_session_list` as "empty fleet" would be the exact
        clobber the guard exists to prevent.
- [ ] A launchd **LaunchAgent** template ships at
      `contrib/launchd/com.cctrl.session-snapshot.plist.template` with
      `@CCTRL_BIN@` / `@HOME@` placeholders, and README documents installation to
      `~/Library/LaunchAgents/` + `launchctl bootstrap gui/$UID <plist>`.
      **The honest trade-off (corrected 2026-08-05):** a LaunchDaemon with a
      `UserName` key runs as the user without root and reaches the tmux socket
      fine — `/private/tmp/tmux-<uid>/default` is plain per-uid filesystem
      state with no GUI dependency (SSH-launched fleets exist with nobody
      logged into the GUI at all). The real axis is: LaunchAgent = no sudo to
      install, per-user, but stops entirely when the user has no GUI session —
      including the window right after a reboot before anyone logs in, and any
      headless-SSH usage; LaunchDaemon+UserName = covers those windows but
      needs sudo to install. On this machine (auto-login Studio) the coverage
      gap is small and the no-sudo install wins, so LaunchAgent it is — but
      the choice is ergonomics, not capability, and plan 053's staleness gate
      exists precisely because the logged-out gap is real. Do not repeat the
      "a daemon cannot reach the tmux socket" claim; it is false and will be
      trusted by the next launchd job built here.
- [ ] `RunAtLoad` is **false** in the template, with a comment saying why: at
      boot the fleet is empty, so a load-time run is precisely the case the
      empty-fleet guard exists to catch. Belt and braces — both must hold.
- [ ] `StartInterval` is 300 seconds (5 minutes). Justification in Design.
- [ ] Retention pruning runs at the end of each snapshot: keep every history file
      younger than 7 days; older than that keep only the first file of each UTC
      day, up to 90 days; delete the rest. Deletions are restricted to files in
      the snapshot dir matching the timestamped name pattern — never `latest.json`,
      never a glob that could reach outside the dir.
- [ ] Installation is a documented manual step, but **shipping this plan
      protects nothing until the user actually installs the LaunchAgent**, and
      nothing currently reports that. Add a snapshot-automation check to
      `session doctor`: if `~/Library/LaunchAgents/com.cctrl.session-snapshot.plist`
      is absent, or `launchctl print gui/$UID/com.cctrl.session-snapshot` fails,
      or `latest.json` is older than ~3 intervals, report it as a finding with
      the install command. This keeps the "a package installer should not
      silently install a launchd job" principle (still no `install.sh` hook)
      while removing the silent-no-op failure mode.
- [ ] Tests: header + per-session shape; `initial_prompt` absent; empty-fleet
      guard preserves a non-empty `latest.json`; `--allow-empty` overrides;
      history + latest agree; retention keeps/prunes the right files against a
      fixture dir of dated files; the no-send-keys structural assert. Plus the
      gaps found in eng review:
      - **tmux binary absent → `_session_list` returns 1 → write nothing,
        exit 0.** This plan argues at length that conflating this with `[]` is
        "the exact clobber the guard exists to prevent", then specified no test
        for it. Drive it by putting a `_session_require_tmux`-failing stub on
        `PATH` and asserting `latest.json` is byte-identical afterwards.
      - **First run on an empty fleet with no existing `latest.json`** writes the
        empty snapshot rather than refusing.
      - **`transcript_bytes` is `null`** when the transcript path is empty or the
        file is unreadable, rather than `0` or an error.
      - **A codex session yields `transcript_path: null` and
        `transcript_bytes: null`**, not the rollout path substituted in.
      - **`managed` matches `session ls`** for a session that satisfies only the
        tmux-option arm of the cctrl:6058 OR, not the record arm.
      - **`launch_flags` round-trip**: a record whose `launch_command` carries
        `--model claude-fable-5` produces `launch_flags.model = claude-fable-5`,
        and a record with no recognisable flags produces an empty object, not a
        raw command string.
- [ ] Full suite passes.

## Design

**Why 5 minutes.** The interval is the worst-case staleness window, so the
question is what a stale snapshot actually costs. `conversation_id` is fixed for
a session's lifetime and `cwd`/`purpose` rarely change, so a stale snapshot is
wrong in three ways, not the two an earlier draft claimed: sessions **spawned**
since the last tick are missing, purpose edits since the last tick are lost, and
— the one that was omitted — sessions **closed or killed** since the last tick
are still present, so a restore resurrects them. That third case is the more
annoying one in practice: a missing session is visible (you notice it did not
come back), whereas a resurrected one looks like a successful restore and
quietly consumes a slot under the cap. 053's dry-run is the mitigation — it
lists every candidate with its `last_active`, so a session you closed on purpose
is visible before you confirm, and `--only` excludes it.

**Cost, measured.** An earlier draft of this plan estimated "~30 tmux queries
plus a `stat` per session, well under a second". That was wrong by about 3x.
Measured on `ms-128g-bln` 2026-08-05: `session ls --json` takes **1.06s for 10
sessions** (~106ms/session; three runs at 1.07/1.05/1.06). The row loop spawns
~18 subprocesses per session, including six separate `_session_metadata_field`
calls — six `jq` invocations against the same file. At the 20-30 sessions this
fleet routinely holds, a snapshot run is ~2-3.2s, not sub-second.
The interval conclusion survives unchanged: 3.2s of work every 300s is a ~1%
duty cycle, and plan 051 collapses the six `jq` reads into one, which should cut
it materially. But the number is corrected here because it is the number the
interval was chosen against, and because the same loop is on the launch hot path
via `_active_session_count` (cctrl:1440) — every `cctrl start` already pays it.
Output is ~12 KB (≈30 sessions × ~400 bytes). One minute buys almost nothing and
generates 1440 files a day; fifteen minutes risks losing a session that was
spawned, given an hour of real work, and then lost. Five is 288 files/day,
~3.5 MB/day before pruning, and caps the loss at one just-spawned session.
Overridable via the plist for anyone who disagrees.

**Retention math.** 7 days at 5-minute granularity is 2016 files ≈ 24 MB — the
window where you might want to see the fleet as it was during a specific
incident. Beyond that the useful question is "what was running that week", which
one file per day answers, so 90 daily files ≈ 1 MB. Total steady state well under
30 MB.

**What this is not.** It is not a replacement for the session records — those
remain the source of truth for a single session. The snapshot is a point-in-time
view of the *fleet*, which is the thing nothing currently persists.

**Files expected to change:**

- `cctrl`: `_session_snapshot` + `cmd_session` dispatch + help lines
- `contrib/launchd/com.cctrl.session-snapshot.plist.template`: new
- `README.md`: snapshot section, timer install, retention policy
- `tests/run-tests.sh`: snapshot shape, empty guard, retention, structural assert
- `CHANGELOG.md`: Added entry

**Testing approach: E2E** — real binary, isolated fixture dirs, fake tmux, with
`--dir` pointing at a temp snapshot directory.

**Out of scope:** restore (053); remote/multi-host snapshots (`--host` fan-out);
pushing snapshots off-box; any token-based context measurement; installing the
timer from `install.sh` (documented manual step — installing a launchd job is not
something a package installer should do silently).

## Tasks

1. Implement `_session_snapshot`: build from `_session_list --json`, join the
   record fields, add `transcript_bytes`, emit the header.
2. Add the atomic same-dir write (history first, then `latest.json`) and the
   empty-fleet guard with `--allow-empty`.
3. Implement retention pruning, scoped to the timestamped-name pattern in the
   snapshot dir.
4. Wire `cctrl session snapshot` dispatch, flags, `--help`, and top-level help.
5. Write the LaunchAgent template (`RunAtLoad` false, `StartInterval` 300,
   placeholders) and the README install/retention section.
6. Tests including the structural no-mutation assert; run the full suite.

## Verification

Checks:

Check format note: tag outside the backticks — see the same note in plan 051.

- [cmd] `bash tests/run-tests.sh`
- [cmd] `grep -q "_session_snapshot" cctrl`
- [cmd] `grep -q "allow-empty" cctrl`
- [cmd] `grep -q "RunAtLoad" contrib/launchd/com.cctrl.session-snapshot.plist.template`
- [cmd] `grep -q "StartInterval" contrib/launchd/com.cctrl.session-snapshot.plist.template`
- [assert] `cat contrib/launchd/com.cctrl.session-snapshot.plist.template` contains 300
- [assert] `cat README.md` contains session snapshot
- [assert] `./cctrl session snapshot --help 2>&1` contains --allow-empty
- [cmd] `bash -c '! sed -n "/_session_snapshot()/,/^}/p" cctrl | grep -Eq "send-keys|paste-buffer|load-buffer"'` — no tmux mutation on the snapshot path (shell-dependent, not probeable at authoring time)
- [cmd] `bash -c '! sed -n "/_session_snapshot()/,/^}/p" cctrl | grep -q "initial_prompt"'` — the snapshot never captures initial_prompt (same)

`RunAtLoad` must be present **and** `false`, and `StartInterval` must be `300`;
a bare `grep` cannot assert the key/value pairing across lines, so the plist
test in `tests/run-tests.sh` owns that assertion and these greps only guard
against the keys disappearing entirely.

<!-- mstack:seam
produced:
- kind: command; name: session snapshot; file: cctrl
- kind: schema; name: data/snapshots/latest.json; file: cctrl
assumed:
- from: 051; kind: schema; name: conversation_id; file: data/sessions/*.json
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

**Changes folded into this plan:** the `_session_list --json` field inventory is corrected
from 12 keys to the actual 17 (cctrl:6119) and gains a per-field source table — the omitted
`managed` is a three-way OR at cctrl:6058, materially stronger than the record field an
implementer would otherwise reach for, and 053's cap reads it. The snapshot now captures
`model` and a parsed `launch_flags` object, because five live records carry an explicit
`--model` and restore without them returns a third of the fleet on post-reboot defaults.
The cost model is corrected to measured figures (1.06s for 10 sessions, ~18 subprocesses
per session — the earlier "well under a second" was off ~3x); the 5-minute interval survives
unchanged at a ~1% duty cycle. The staleness argument now includes resurrected
closed sessions. The atomicity claim is scoped to crash-*consistent* rather than
crash-*durable*, with the history-newer-than-`latest` case handed to 053. A
`session doctor` finding is added for uninstalled snapshot automation. Six test gaps added,
including the tmux-binary-absent clobber path this plan argued for at length and never tested.

**CODEX:** Six of the eleven outside-voice findings landed here — launch configuration,
the immortal empty-fleet guard, the false staleness model, fsync durability, the
history/latest ordering, and manual LaunchAgent installation. All accepted.

**CROSS-MODEL:** No tension. Codex's "empty-fleet guard makes stale snapshots immortal"
is the mirror of the review's independent finding that restore never validates
`generated_at`; both resolve to the same mitigation, recorded in both plans so they
cannot drift apart.

**VERDICT:** ENG CLEARED — ready to implement (blocked on 051 by design).

**FABLE AUDIT AMENDMENTS (2026-08-05, post-clearance):** from the independent
cross-model audit (`docs/reviews/2026-08-05-fable-architecture-audit.md`,
findings F5/F7/F9): (1) the LaunchAgent-over-LaunchDaemon rationale is
rewritten — the old "a daemon cannot reach the user's tmux socket" claim was
technically false (a `UserName` daemon can); the choice stands but now on the
honest sudo-vs-logged-out-coverage trade-off; (2) the header must not call
`_res_health_line`, which would run a second full fleet enumeration per tick
(doubling the measured cost this plan corrected once already) — count and
resource line are built from parts already in hand; (3) `transcript_bytes`
gains the `stat -c %s` Linux fallback. No behavioural AC was weakened.

NO UNRESOLVED DECISIONS
