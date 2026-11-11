---
id: 116
title: Overhaul A - data store safety and moving live state out of the git checkout
status: blocked
blocked-by: []
priority: 11
allows-migrations: true
needs-review: eng
review-required: eng
created: 2026-11-11
approval: "mdec-1111-fable-findings-plans: PLAN ONLY. Waits for Matthew's prioritisation from plan 115. The migration on each Mac, every install and the launchd plist each need their own yes."
approved-by: pending (Matthew, via plan 115)
reviews: []
related: 115, 117, 118, 120, 121, 049, 070, 071, 078, 079
---

Workstream A of the overhaul (umbrella: plan 115). It covers Fable's plan (a), audit option 9 and
findings F2, F3, F9, F10, F13, L1, L2, L3. It is revised for the independent review's
MF-M1 to MF-M5 and SH-S1 to SH-S4. Sizes are the reviewer's where they differ from Fable's.
Baseline is `main` at `8c249fc`.

## Problem

- Every data path defaults to `$SCRIPT_DIR/data`. An installed release's `data`, `costs`,
  `profiles` and `.active-profile` are symlinks into `~/dev/cctrl/` (`install/self-install.sh`).
  `git clean -fdx`, a re-clone or a careless `rm -rf` destroys the fleet's mailbox, session
  registry, peers, doorbell config, host id and `native-sends.key`.
- Paths are resolved five ways. `SHORTCUTS_FILE`, `CONFIG_FILE`, `SPENDING_LOG` and
  `ACTIVE_FILE` have no override, `cmd_usage` hard-codes its rate-limit files,
  `SESSION_METADATA_DIR` ignores `CCTRL_DATA_DIR`, and `hooks/statusline.sh`,
  `hooks/session-log.py`, `plugins/cctrl-ports` and `completions/_cctrl` compute their own paths.
- Some files are world-readable: `messages-archive.jsonl`, `app-delivery/*.body`,
  `rate-limits*`, `hosts.json` and `costs/spending.jsonl` are 0644, and the directories are 0755.
- The mailbox. Mutating verbs (recv, ack, deliver, nudge, gc) rewrite the whole file through a
  `mktemp` in `$TMPDIR` and a `mv`, with no fsync and no backup. Pure reads (inbox, show, check)
  only slurp it (SH-S1: Fable overstated this). One bad line makes every reader exit 65
  `mailbox-corrupt`, and there is no repair. The live macOS lock is `shlock`; the racy mkdir
  path is only the fallback, used on Linux or with `CCTRL_MAILBOX_LOCK_KIND=dir` (SH-S1). The
  only concurrency test is SKIPped with a stale "flock" reason (cctrl never uses flock).
  `peers.json` and `shortcuts.json` are rewritten with no lock.
- Unbounded growth: `rate-limits-history.jsonl` is about 23 MB (one line per statusline render
  of every session), `doorbell/debug.log` is on, and `app-delivery/` is never cleaned.
  `hooks/session-log.py` rewrites all of `costs/spending.jsonl` on every Stop, with no lock.
- `data/config.json` is tracked inside the ignored `data/` (MF-M1).

## Target

- State root: `${CCTRL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/cctrl}`, mode 0700.
  `data/` and `costs/` live under it, with directories at 0700 and files at 0600.
  `~/.local/state/cctrl` already exists at 0700 and holds only `peer-seal.key`. The key path
  stays pinned where it is (`lib/peer_seal.py` ignores XDG and requires a 0700 directory).
- Profiles go to `~/.config/cctrl/profiles` (Q3 in plan 115; that directory exists and is
  already `PROFILES_USER_DIR`).
- An installed release reads the state root. A checkout run directly keeps its own
  `$SCRIPT_DIR/data` (Q2), so development never touches the live store once A4 removes the
  compat symlink.
- **Pure relocation:** the internal layout of `data/` does not change in this plan.

## Phases

### A0. One path resolver, private modes, config default out of `data/` (step 1)

- **Scope.**
  - One resolver in two forms with identical rules:
    - a sourced `lib/paths.sh` (bash 3.2 subset, no subprocesses);
    - `lib/paths.py` (stdlib).
  - Every data, costs, usage, snapshot, audit and config path in `cctrl` derives from it.
    `CCTRL_DATA_DIR` governs all data paths; `SESSION_METADATA_DIR` is now derived from it
    unless explicitly set. The resolver gains `audit_dir` (state root/`audit`) for plan 118's logs.
  - `hooks/statusline.sh`, `hooks/session-log.py`, `plugins/cctrl-ports` and
    `completions/_cctrl` source or import the resolver. They never spawn `cctrl` per call
    (SH-S2: statusline renders constantly).
  - `cctrl paths [--json]` prints the resolved paths, modes and mode (installed or checkout),
    for humans and tests only.
  - **MF-M1:** move the shipped default to the tracked `share/config.default.json`, read as the
    lowest config layer under user config and `config.local.json`, then
    `git rm --cached data/config.json`. The live `data/config.json` stays on disk as user data.
  - **SH-S3 installed-mode signal:** `self-install.sh` writes `.installed` into the release as
    its last step before activation, after the gate, and the launcher exports
    `CCTRL_RUNTIME_MODE=installed`. VERSION is no longer the signal. Mode is "installed" only
    when one of these is present; a checkout and the gate's scratch tree are both "checkout".
  - `umask 077` at entry. Explicit 0600 and 0700 on every create, including the files listed
    above that use the ambient umask today. `cctrl state fix-modes [--dry-run]` tightens
    existing files once; it runs as part of the install.
  - The location does not change in A0.
- **Closes.** F10, L1 (modes), MF-M1, SH-S2, SH-S3; prepares F2. Also fixes the zsh completions
  that broke with the checked install (evidence B §2).
- **Size.** 12 h (reviewer; Fable 8).
- **Risk.** Low. Behaviour-preserving. The only state changes are the chmod and the untracked
  config file. Untracking `config.json` needs a note for the MacBook and the 24
  `.worktrees/*/data` copies: after the pull, git leaves the file in place as untracked, and
  `self-install`'s clean-tree check passes.
- **Tests.**
  - A path matrix: each override × installed vs checkout × bash 3.2 and 5. The shell and
    Python resolvers must agree on every row (one table-driven test runs both).
  - Mode assertions for every file the suite creates.
  - The config layer order (default < user < local).
  - `git ls-files data` is empty.
  - Statusline and session-log resolve without spawning cctrl (count process spawns with a
    PATH stub).
  - A completions smoke test under zsh.
  - The 89 rootcopy tests still pass unchanged.
- **Rollback.** Previous release plus `git revert`. Modes stay tightened (harmless). Restore
  tracking with `git add -f data/config.json` if needed.
- **Depends on.** Nothing. Runs alongside E0 (plan 121).
- **Needs Matthew's yes:** the install on each Mac (it chmods live files).

### A1. Mailbox hardening in place, lock-compatible (step 2)

- **Scope.**
  - **Tolerant read.** Bad lines (unparseable, NUL, wrong type) are copied to
    `messages.quarantine.jsonl` (0600) with a reason and the source line number, and good lines
    stay readable. `--strict` or `CCTRL_MAILBOX_STRICT=1` keeps today's exit 65 for scripts.
    `peer doctor` reports the quarantine count.
  - **Safe rewrite.** A temp file in the **same directory**, fsync, rename, then fsync the
    directory. This replaces `mktemp` in `$TMPDIR` plus `mv`.
  - **Backups.** `messages.jsonl.bak` is refreshed before each rewrite, plus one dated copy per
    day, kept 7 days, all 0600.
  - **`peer repair [--dry-run]`.** Rebuilds the mailbox from the backup plus the quarantine,
    with no duplicate ids and the newest status winning by `updated_at`.
  - **`v: 1`** on new messages. Old code ignores unknown keys.
  - **Lock (MF-M4).**
    - Keep the path `messages.jsonl.lock` and shlock's protocol: a temp file holding the pid,
      `link(2)` to the lock path, stale only when that pid is dead.
    - Release checks that the file still holds our pid before unlinking.
    - Replace the mkdir fallback with a portable implementation of the same link protocol, in
      bash and in `lib/locks.py`. Stale steal = rename the stale file to a unique name,
      re-check its pid, then link. This fixes the fallback race (plan 049 item 1) and makes
      Linux safe. `CCTRL_MAILBOX_LOCK_KIND=dir` stays one release as an alias.
    - Bash shlock users, the portable fallback and Python must exclude each other. They do,
      because all three are one protocol on one path.
  - The same lock helper (`_cctrl_lock_acquire <file>`) guards `peers.json` and
    `shortcuts.json` rewrites (L2, plan 049 item 2), and later the plan 118 log rotation
    (MF-M7).
  - **SH-S1.** Fix and un-skip `test_peer_mailbox_concurrency_and_stale_lock`, with the skip
    reason replaced rather than just removed.
  - Stays in bash on purpose: a small diff under the existing mailbox tests.
- **Closes.** F3 (read, rewrite, corruption, backup, version), L2, MF-M4, SH-S1, plan 049 items
  1-2.
- **Size.** 20 h (reviewer; Fable 12).
- **Risk.** Medium. This is the hottest path in the fleet. An old release under rollback must
  still exclude new writers, which is what the compatibility test proves.
- **Tests.**
  - Truncated last line, NUL byte, duplicate id, a 1 MB line, an invalid UTF-8 line.
  - 50 concurrent senders with ack and gc.
  - kill -9 between the temp write and the rename (fault-injection variable, honoured in test
    mode only).
  - Backup restore; `peer repair` idempotence.
  - **An old-release writer against a new-release writer:** run the `7742883` blob's `cctrl`
    from a scratch tree and the new code on the same fixture mailbox concurrently, and check
    no message is lost.
  - A bash shlock holder against the Python locker; stale steal with two waiters; release
    refused when the pid does not match.
  - Both lock kinds on both bashes.
  - An old-release reader on a file with `v` and a quarantine present.
- **Rollback.** Previous release. The file stays plain JSONL, and old code tolerates `v` and
  ignores the quarantine and backups. The lock protocol is unchanged for old code.
- **Depends on.** A0 (paths and modes).
- **Needs Matthew's yes:** the install on each Mac.

### A2. Move the live data (step 4; MacBook first, then the Studio)

- **Scope.** `cctrl state migrate --dry-run | --apply | --rollback | --status`, in Python
  (stdlib), using the A1 lock protocol.
  1. **Preflight. It refuses unless all of these hold:**
     - `git ls-files data` is empty (MF-M1).
     - The source and the target are on one volume.
     - The running release declares layout 2 support (the C2 guard, plan 117).
     - The **sync gate** passes (MF-M3), see below.
     - No `peer watch`, `session watch`, needs-me or doorbell loop is running, by the ps argv
       of cctrl processes. `--stop-loops` stops them and lists what it stopped.
     - The snapshot agent `com.cctrl.session-snapshot` is unloaded. `--apply` asks the
       operator to unload it, or does it with `--unload-agents` and reloads it at the end
       (MF-M5).
     - `--apply` asks for the host name to be typed as confirmation, and runs only in the
       supervised session. The plan 118 classifier does not exist yet at step 4, so this is
       doctrine plus the confirmation, not a caller check.
  2. **Backup.** A 0600 tarball of `data/`, `costs/` and `profiles/` beside the state root,
     with its hash recorded.
  3. **Marker inside the moving directory.** Write `data/LAYOUT` (`{"layout":2,…}`) **before**
     the rename. The A0 resolver in installed mode uses the state dir when
     `<state>/data/LAYOUT` says 2. Because the marker moves with the directory in one
     `rename(2)`, new-release writers switch at the same instant and never recreate the old
     `data/` (MF-M5).
  4. Take the mailbox and peers locks. `rename(data, <state>/data)`.
  5. Create a symlink at `data.tmp` and `rename` it to `data`. A symlink cannot be renamed
     onto a directory. If an old-release writer recreated `data/` in the window, the tool
     takes the lock, merges the stray directory into the state dir (mailbox by message id,
     appends by line, everything else newest wins, with a conflict list), removes it and
     retries. This is **bounded to 5 attempts, then abort and `--rollback`** (MF-M5).
  6. Repeat for `costs/` (its own marker). Then `profiles/`, per Q3: copy it into
     `~/.config/cctrl/profiles` and refuse on a name clash with a differing file. The old
     directory is renamed to `profiles.migrated-<ts>`, never deleted.
  7. **Verify.** File counts and hashes match the backup manifest, the mailbox parses, and
     `peer doctor` and `session list` agree before and after (read-only).
  8. Write a report: what moved, the conflicts, the data the operator should review
     (`shortcuts.json.bak*`, the hand notes, `snapshots/restore-*.json`), and which writes
     can be lost in the window (statusline samples only; listed).
- **The sync gate (MF-M3).** It runs on both Macs:
  - (a) Matthew reads livesync-cli's include and exclude scope. An agent never opens that
    config, because it may hold credentials.
  - (b) A canary: write `data/.sync-canary-<host>-<nonce>` on each Mac, wait for the sync
    interval (default 15 min), and look for the other Mac's canary.
  - (c) Close the `TODOS.md` reload-livesync item, or scope it with `data/`, `costs/`,
    `profiles/` and `.active-profile` excluded.
  - If a canary crosses, A2 stops, and so does any further migration on either Mac. The
    branch for that case: stop the sync first, rename on the Mac with the larger mailbox only,
    replay the other Mac's unique messages into it with `peer repair --merge`, and add the
    excludes before restarting the sync.
- **Order.** A rehearsal on a fixture copy of each Mac's `data/` (taken by the operator, never
  read by agents beyond counts). Then the **MacBook** (small mailbox, no doorbell config), then
  **one day of soak**, then the **Studio** at a quiet time.
- **Compatibility.** After A2, `~/dev/cctrl/data` is a symlink to the state dir. Old releases
  and processes still running old code (runtime MCP, the session wrapper, tmux-server jobs,
  long-running loops) keep working through that chain without restarts (evidence B §12).
- **Closes.** F2, L1, F13 (decided by the canary, and D1 fixes the docs), MF-M3, MF-M5, SH-S3
  (the gate and checkout resolution test), SH-S4.
- **Size.** 20 h build (reviewer; Fable 12), plus about 1 h supervised per Mac.
- **Risk.** Medium-high. It is a one-time live change. The window is two renames. Only
  old-release writers can recreate `data/`, and quiesce removes the known ones.
- **Tests (fixtures only).**
  - The happy path.
  - Cross-volume refusal; a tracked `data/` file refused.
  - A lock held; loops running, which is refused; `--stop-loops`.
  - **A sender during the window**, with an injected writer between the two renames that
    recreates `data/`, is merged, and the merge loop exhausts and aborts cleanly.
  - A crash after each step, then a resumable `--apply`.
  - `--rollback` after each step. A second `--apply` is a no-op.
  - The canary logic with a fake sync.
  - The profiles clash.
  - The previous release's `cctrl` runs against the migrated layout through the symlink.
  - Gate and checkout resolve the same paths under the harness (SH-S3).
  - A post-move check list built only from read-only status commands.
- **Rollback.** `cctrl state migrate --rollback`: under the same locks, reverse the rename,
  remove the symlink and the marker, and restore `profiles/` from `profiles.migrated-<ts>`.
  If that fails, restore the tarball. The previous release keeps working either way, because
  it follows the symlink.
- **Depends on.** A0, A1, C1, and C2 with its layout guard (plan 117, MF-M2); the Q1 canary
  and the Q3 decision.
- **Needs Matthew's yes:**
  - reading the livesync scope himself;
  - **the migration on the MacBook, then separately on the Studio** (each a supervised
    session);
  - the install of the release that carries A2.

### A3. Scheduled gc and retention (step 6)

- **Scope.**
  - **`cctrl state gc [--dry-run|--apply]`.**
    - Archive acked mail older than 30 days into monthly 0600 files. Unread mail is never
      touched (gc of queued or delivered mail stays operator/FM-only under plan 118's O4.3).
    - Statusline appends a history line only when a value changes, or at most once a minute,
      keeping 30 days.
    - Rotate `doorbell/debug.log` and turn debug off by default (L3).
    - Delete `app-delivery/` attempts older than 7 days, and doorbell state for sessions that
      no longer exist.
  - **Restore.** `peer gc --restore <month>`.
  - **Launchd template.** `contrib/launchd/com.cctrl.gc.plist.template` runs daily with
    `--apply --operator` (SH-S10: the job classifies as `script`, so under `caller_checks` it
    needs `--operator`, and it only gc's acked mail).
  - `hooks/session-log.py` appends under the A1 lock instead of rewriting the whole file (the
    lost-update race, F9).
  - The Linux cron/systemd line is documented only if Q5 = supported.
- **Closes.** F9, L3, the F3 "nothing schedules gc" part, SH-S10.
- **Size.** 8 h (Fable; the reviewer did not change it).
- **Risk.** Low-medium. Moves to an archive, never deletes unread mail.
- **Tests.**
  - An injected clock.
  - Queued and unread mail never move.
  - Archive plus remainder equals the input; idempotent.
  - Rotation under concurrent append.
  - Statusline append throttling.
  - `session-log.py` under 10 concurrent Stops loses no line.
  - The plist lints with `plutil -lint`.
  - Restore round-trip.
- **Rollback.** Unload the plist; previous release. Archived mail returns with
  `peer gc --restore`. Statusline throttling goes back to every-render with the previous
  release (nothing to undo).
- **Depends on.** A0, A1. It should land after A2, so the plist is written against the final
  paths.
- **Needs Matthew's yes:** loading the plist on each Mac (an install on the live machine), and
  the install.

### A4. Remove the scaffolding (step 9, after a quiet period)

- **Scope.**
  - **Guards.** Runs only when `release prune --dry-run` shows no retained release, and no
    live process, using the old path, and at least two weeks after A2 on both Macs.
  - **MF-M2.** Repoint each retained release's `data` and `costs` links from `~/dev/cctrl/…`
    to the state dir, or prune the releases that predate layout 2. With C2's guard, a forced
    rollback to such a release then still reads the right store.
  - Remove the `~/dev/cctrl/data` and `costs` symlinks; a checkout then uses its own private
    `data/` (Q2).
  - Stop `self-install.sh` creating the four symlinks.
  - Delete the legacy `.active-profile` reader.
  - Update README and docs (with D1/D2, plan 122).
- **Closes.** F2 (complete), MF-M2 (second half).
- **Size.** 6 h (reviewer; Fable 4).
- **Risk.** Low, given the guards.
- **Tests.**
  - The install test asserts that no release links into a working tree (E7).
  - A checkout run uses its own `data/`.
  - The repoint tool on fixture releases.
  - A rollback to a repointed old release reads the state dir.
- **Rollback.** Recreate the symlinks (`cctrl state migrate --relink`). Releases are only
  repointed, so they can be pointed back.
- **Depends on.** A2 on both Macs, C2, and a quiet period.
- **Needs Matthew's yes:** the install, and the repoint or prune of old releases on each Mac.

## Size summary

| Phase | h | Source |
|---|---|---|
| A0 | 12 | reviewer |
| A1 | 20 | reviewer |
| A2 | 20 + 2 supervised | reviewer |
| A3 | 8 | Fable |
| A4 | 6 | reviewer |
| **Total** | **66** (+2 supervised) | |

## Interaction with other workstreams

- Plan 117: C2's layout guard is a hard prerequisite of A2. C1 runs before A2, so the release
  that carries A2 was installed from a pushed main.
- Plan 118: its logs live in `audit_dir` and its hook rules match resolved paths, both from A0
  (MF-M7). A3's plist uses `--operator`.
- Plan 120: B0 moves `lib/paths.py` and `lib/locks.py` into the package unchanged. B3's Python
  mailbox store uses the A1 protocol. The data format does not change in plan 120.
- Plan 121: E5 keeps the A1 corruption and concurrency set as a named suite. E12 adds crash
  consistency for the other stores. E7 holds the "no release links into a working tree"
  assertion.

## Out of scope

- Reshuffling files inside `data/`, or moving `shortcuts.json` and `hosts.json` to
  `~/.config`.
- Plan 049 items 3-4 (lock hold vs timeout, nudge dedupe).
- Any change to the seal key path.
- Syncing state between the Macs. Each Mac keeps its own store.
