---
id: 052
title: cctrl session snapshot — periodic, atomic, side-effect-free fleet capture
status: blocked
blocked-by: [051]
priority: 6
goal: fleet-restore-after-power-loss
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-08-03
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
      `hostname`, `session_count`, and the `_res_health_line` string
      (cctrl:1408) as `resource_line`.
- [ ] "Context size" is recorded as `transcript_bytes` (`stat -f %z` on the
      transcript path), not tokens. cctrl has no token-context probe — verified,
      nothing in the script measures one. Bytes is the signal restore decisions
      actually key off: whether the resume picker is worth answering and whether
      the session will self-compact. Naming it `transcript_bytes` keeps that
      honest.
- [ ] Atomic write: `mktemp` **inside the target directory** then `mv`. A
      `mktemp` in `$TMPDIR` can land on a different filesystem, where `mv` is a
      copy and a power cut mid-write leaves a truncated `latest.json`. The
      history file is written first, then `latest.json`, so a crash between them
      loses nothing.
- [ ] **Empty-fleet guard.** If the capture yields zero sessions and the
      existing `latest.json` has more than zero, `latest.json` is left alone and
      the run exits 0 with a one-line note. `--allow-empty` overrides. This is
      the single most important safety rule here: a snapshot taken at boot, or
      while the tmux server is down, would otherwise overwrite the only record of
      the fleet you are trying to restore with `[]`.
- [ ] No tmux mutation on the snapshot path. Asserted structurally: the snapshot
      function contains no `send-keys`, `paste-buffer`, `load-buffer`, or
      `set-option`. Read-only tmux calls (`list-sessions`, `list-panes`,
      `display-message`, `show-option -qv`) are fine.
- [ ] Built on `_session_list --json`, which already emits `name`, `dir`,
      `state`, `session_id`, `transcript`, `last_active`, `purpose`,
      `created_at`, `peer`, `agent`, `remote_control`, `display_label`
      (cctrl:6112). Snapshot maps `session_id` → `conversation_id` and
      `transcript` → `transcript_path` (the JSON key is `transcript`, not
      `transcript_path` — do not assume the names match), and adds
      `transcript_bytes`, `cwd`/`target` from the record, and the header.
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
      `~/Library/LaunchAgents/` + `launchctl bootstrap gui/$UID <plist>`. It must
      be a LaunchAgent, not a LaunchDaemon: a daemon runs as root outside the
      user's GUI session and cannot reach the user's tmux socket, so it would
      capture an empty fleet forever.
- [ ] `RunAtLoad` is **false** in the template, with a comment saying why: at
      boot the fleet is empty, so a load-time run is precisely the case the
      empty-fleet guard exists to catch. Belt and braces — both must hold.
- [ ] `StartInterval` is 300 seconds (5 minutes). Justification in Design.
- [ ] Retention pruning runs at the end of each snapshot: keep every history file
      younger than 7 days; older than that keep only the first file of each UTC
      day, up to 90 days; delete the rest. Deletions are restricted to files in
      the snapshot dir matching the timestamped name pattern — never `latest.json`,
      never a glob that could reach outside the dir.
- [ ] Tests: header + per-session shape; `initial_prompt` absent; empty-fleet
      guard preserves a non-empty `latest.json`; `--allow-empty` overrides;
      history + latest agree; retention keeps/prunes the right files against a
      fixture dir of dated files; the no-send-keys structural assert.
- [ ] Full suite passes.

## Design

**Why 5 minutes.** The interval is the worst-case data loss on a hard power-off,
so the question is what a stale snapshot actually costs. `conversation_id` is
fixed for a session's lifetime and `cwd`/`purpose` rarely change, so a stale
snapshot loses exactly two things: sessions spawned since the last tick, and
purpose edits since the last tick. A session spawned and killed inside five
minutes has no conversation worth restoring. Against that: each run is ~30 tmux
queries plus a `stat` per session, well under a second, and produces ~12 KB
(≈30 sessions × ~400 bytes). One minute buys almost nothing and generates 1440
files a day; fifteen minutes risks losing a session that was spawned, given an
hour of real work, and then lost. Five is 288 files/day, ~3.5 MB/day before
pruning, and caps the loss at one just-spawned session. Overridable via the
plist for anyone who disagrees.

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
