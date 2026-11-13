---
id: 116
title: Overhaul A - data store safety and moving live state out of the git checkout
status: blocked
blocked-by: [115]
priority: 11
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-11-11
approval: "Operator approval on record (plan-only grant): PLAN ONLY. Run per phase under the orchestrator; never flip this plan to pending as a whole. Waits for Matthew's prioritisation from plan 115. The migration on each Mac, every install and the launchd plist each need their own yes."
approved-by: pending (Matthew, via plan 115)
reviews: []
related: 115, 117, 118, 120, 121, 049, 070, 071, 078, 079
---

Workstream A of the overhaul (umbrella: plan 115). It covers Fable's plan (a), audit option 9 and
findings F2, F3, F9, F10, F13, L1, L2, L3. It is revised for the independent review's
MF-M1 to MF-M5 and SH-S1 to SH-S4, and again for the second review of plans 115-122
(MUST-FIX 2, S2, S5-S10), and a third time for the re-check of that revision (cited
R3-MF1, R3-MF2 and R3-S4 to R3-S8). Sizes are the reviewer's where they differ from Fable's, plus the
revision hours named in each phase. Baseline is `main` at `8c249fc`.

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
  - **The layout-2 rule ships here, dormant** (review S7). In installed mode the resolver uses
    `<state root>/data` when `<state root>/data/LAYOUT` says 2 (and `costs` likewise), and
    falls back to the release's `data` link otherwise. No marker exists until A2, so nothing
    changes now. This makes every release from A0 on (so every release that C2 marks
    `layout_max: 2`) able to read layout 2 **without** the compat symlink, so the layout ids
    stay honest after A4.
  - **The migration sentinel rule ships here too** (MUST-FIX 2): while
    `<state root>/.migrating` exists, the resolver reports `migrating` and the writers (A1's
    helper) wait instead of creating directories. Dormant until A2.
  - **The test-mode gate ships here** (moved from plan 119's O5; review S10), so A1's
    fault-injection variable is gated from its first release. `_cctrl_test_mode` (shell) and
    `paths.test_mode()` (Python) are true only when **all** of these hold:
    - `CCTRL_TEST_MODE=1`;
    - **every** resolved state path (data, costs, state root, audit, config, session
      metadata, snapshots, `TMUX_TMPDIR`) resolves by realpath inside one directory that
      holds a `.cctrl-test-sandbox` file;
    - **the seal key path resolves inside that sandbox too.** The live key's path is derived
      from `pwd.getpwuid(os.getuid()).pw_dir`, not from `HOME`, and test mode refuses to run
      (exit 64) when the effective key path equals it.

    The real property is "overrides only bite when nothing live is reachable". The marker is
    not a secret: an agent can make its own sandbox, and that is fine, because a sandbox
    without the live store and without the live seal key cannot mint anything the live
    store would accept. Without the seal-key rule, test mode plus the login-root override
    would be a grant oracle MAC'd with the live key (review S10).
  - `hooks/statusline.sh`, `hooks/session-log.py`, `plugins/cctrl-ports` and
    `completions/_cctrl` source or import the resolver. They never spawn `cctrl` per call
    (SH-S2: statusline renders constantly).
  - `cctrl paths [--json]` prints the resolved paths, modes and mode (installed or checkout),
    for humans and tests only.
  - **MF-M1:** move the shipped default to the tracked `share/config.default.json`, read as the
    lowest config layer under user config and `config.local.json`, then
    `git rm --cached data/config.json`.
  - **The untracking deletes the file in every other checkout (review S5).** `git rm --cached`
    keeps the file only in the clone where it runs. Every other checkout that fast-forwards
    past that commit **deletes** an unmodified `data/config.json` (and refuses the pull if it
    is modified). That includes `~/dev/cctrl` itself (commits are made in worktrees), the
    second Mac's checkout and every worktree. The live file in `~/dev/cctrl/data` is
    unmodified today, so the merge would delete it. New code falls back to
    `share/config.default.json` (same content), so new releases lose nothing, but a rollback
    to any pre-A0 release would run without the file. **A0's runbook, on each checkout:**
    copy `data/config.json` aside before the fast-forward, fast-forward, restore it (now
    untracked and ignored), and confirm with `git status --ignored data/config.json`. The
    install preflight warns when the file is missing from the live data dir. Preferred form,
    with no window in which the file is absent: `install/data-config-runbook.sh ff
    [--any-branch] <checkout> <ref>` (refuses a dirty tree, a path that is not the work
    tree's top level, and a branch other than main unless `--any-branch`; save, `git rm
    --cached data/config.json`, `merge --ff-only --no-autostash`, verify; idempotent). Git
    never refuses a later move: the untracked file is ignored, so a move of a checkout back
    across the untracking commit (a checkout of an older commit, a bisect, a branch switch,
    including one made by a sync tool) silently overwrites it with the old shipped content,
    and the next move forward deletes it. Run `save` before any move back, and `check` /
    `restore` after every move.
  - **SH-S3 installed-mode signal:** `self-install.sh` writes `.installed` into the release as
    its last step before activation, after the gate. VERSION is no longer the signal. Mode is
    "installed" only when `.installed` sits next to the **resolved** (realpath) script.
    **There is no env signal** (review S6): an exported `CCTRL_RUNTIME_MODE=installed` would
    be inherited by every tmux session and agent shell an installed cctrl spawns, and a
    hand-run `./cctrl` from a checkout in such a pane would then use the live store. If any
    `CCTRL_RUNTIME_MODE` is found in the environment it is ignored and unset before children
    are spawned. A checkout and the gate's scratch tree are both "checkout".
  - `umask 077` at entry. Explicit 0600 and 0700 on every create, including the files listed
    above that use the ambient umask today. (As built: the umask carries most creates; the
    peer registry, mailbox, session-record dirs, seal key and doorbell state set the mode
    explicitly; existing wide files are tightened once by `state fix-modes` at install.) `cctrl state fix-modes [--dry-run]` tightens
    existing files once; it runs as part of the install.
  - The location does not change in A0.
- **Closes.** F10, L1 (modes), MF-M1, SH-S2, SH-S3; review S5, S6, S10 (gate half); prepares
  F2 and MUST-FIX 2 (sentinel rule). Also fixes the zsh completions that broke with the
  checked install (evidence B §2).
- **Size.** 14 h (reviewer 12; Fable 8; plus 1 for the S5 runbook and rollback test, plus 1
  for the test-mode gate moved here from plan 119's O5 with the seal-key rule).
- **Risk.** Low. Behaviour-preserving. The only state changes are the chmod and the untracked
  config file, which the runbook above preserves on every checkout (the earlier note that
  "git leaves the file in place" was wrong: that holds only in the clone that ran
  `git rm --cached`).
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
  - **Untracking (S5):** a fixture clone fast-forwards past the untracking commit and loses
    the file; the runbook steps restore it; a **pre-A0 release run with `data/config.json`
    absent** is recorded (works on defaults, or fails, in which case the runbook step is
    mandatory and C2's rollback warns when the file is missing).
  - **Mode (S6):** a checkout run with `CCTRL_RUNTIME_MODE=installed` inherited in its env
    still resolves "checkout"; children of an installed run do not carry the variable.
  - **Layout rule:** a fixture state root with `data/LAYOUT` = 2 and **no** compat symlink is
    read by an installed fixture release.
  - **Test-mode gate (S10):** each part missing gives "not test mode"; one state path outside
    the sandbox gives "not test mode"; an effective seal key path equal to the live user's
    key path is refused (exit 64) even with every other part present.
- **Rollback.** Previous release plus `git revert`. Modes stay tightened (harmless). Restore
  tracking with `git add -f data/config.json` if needed; the runbook copy is the backup.
- **Blocked by.** None (first phase). Runs alongside E0 (plan 121) and D6a (plan 122).
- **Needs Matthew's yes:** the install on each Mac (it chmods live files), with the
  `data/config.json` runbook run on each checkout in the same window.

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
      bash and in `lib/locks.py`. `CCTRL_MAILBOX_LOCK_KIND=dir` stays one release as an
      alias.
    - **Stale steal, spelled out (review S9).** Our stealers serialise on a short-lived steal
      guard (`<lock>.steal`, same link protocol, 5 s cap). Under it:
      1. read the pid and `stat` the lock (inode, mtime); judge stale **only** if the pid is
         dead, **or** the process with that pid started after the lock's mtime (pid reuse,
         judged by pid plus start time). Nothing else makes a lock stale: age never does
         (re-check R3-MF2, below);
      2. rename the lock to a unique aside name, then `stat` the aside file;
      3. **same inode:** unlink the aside file and `link(2)` our temp file to the lock path.
         If that link fails with EEXIST, someone else acquired legitimately; we go back to
         waiting;
      4. **different inode (found live):** we moved a lock that someone took after our check.
         This can only happen next to macOS `shlock`'s own stale handling, which unlinks and
         re-links outside our steal guard. We try `link(aside, lock)` to put it back. If
         that succeeds, we unlink the aside name and go back to waiting. If it fails with
         EEXIST, a third process now holds the path: we do **not** acquire, we leave the
         aside file in place for doctor, write a `lock-steal-collision` record, and go back
         to waiting. The collision is reported, not prevented.
    - **What this fixes.** It fixes the fallback race (plan 049 item 1) for the non-shlock
      path and makes Linux safe. Next to the system `shlock` binary a narrow race remains,
      which step 4 detects and reports. It is removed when no retained release calls
      `shlock` any more (after A4, the bash side can use the portable implementation only).
    - **No hold timeout; lock age is a doctor warning only** (re-check R3-MF2). A
      live holder can be SIGSTOPped (Ctrl-Z), swapped out under memory pressure or frozen by
      a MacBook sleeping mid-operation. If age made its lock stale, a waiter would take the
      lock, the holder would resume and rename its temp file over `messages.jsonl`, and
      every write made meanwhile would be lost; the release-time pid check comes too late to
      help. So a lock whose holder is alive (same pid, same start time) is never taken, however
      old. A lock held longer than 120 s (mailbox operations take well under a second) is a
      `peer doctor` **warning** with its pid, the holder's command and its age, for the
      operator to look at. This keeps plan 049 items 3-4 (what to do about long holds) out of
      scope, as the Out of scope section says.
    - Bash shlock users, the portable fallback and Python must exclude each other. They do,
      because all three are one protocol on one path, apart from the reported race above.
  - **Migration sentinel (MUST-FIX 2), so A1 releases are safe writers during A2.** The lock
    helper and every A1+ writer:
    - check `<state root>/.migrating` (a fixed path that does not move) **before** resolving
      the data dir; while it exists they wait (poll every 0.2 s, up to 120 s for CLI
      writers, then exit 75 `state-migrating`) and resolve again afterwards. **Hooks wait at
      most 5 s and then skip their write**, failing open as every hook does (plan 079), so
      no session's Stop is held for long;
    - **never `mkdir -p` the data or costs dir.** If the resolved dir is missing, they check
      the sentinel again and wait; with no sentinel they create only the leaf with a plain
      `mkdir`, and only in checkout mode or when no marker exists anywhere;
    - **re-validate after taking the lock:** if the sentinel now exists, or the realpath of
      the resolved dir has changed since resolution, they release the lock, remove the
      directory they created (only if they created it and it is empty), wait and retry.
      This closes the resolve-then-rename window for new-release writers.
    - **Both modes check it** (re-check R3-S8). Until A4, hooks and hand runs from
      `~/dev/cctrl` are live **checkout-mode** writers to the very directory that moves (for
      example the second Mac's Codex hooks before C4, or a statusline still pointing into
      the checkout). So the sentinel check is in the resolver's shared write path and runs
      in installed **and** checkout mode, always at the fixed default state root (or the
      sandbox's state root under test mode). A hand run from some other worktree, whose
      `data/` is not moving, also waits; that costs seconds once per Mac and keeps the rule
      simple.
    - **A sentinel left by a crash is visible** (re-check R3-S5). The sentinel file
      holds `{pid, pid_start, host, step, created_at}` from the `--apply` or `--rollback` run
      that made it. If that run crashes, the sentinel stays on purpose (the data is
      half-moved, so writers must keep waiting), but:
      - the exit-75 message names the sentinel's pid, its age and step, says whether that
        pid is still alive, and gives the two ways out: `cctrl state migrate --apply`
        (resume) or `--rollback`;
      - `peer doctor` shows a row for it: **info** while the owning pid is alive and the
        sentinel is younger than 2 minutes, an **issue** once the owner is dead or the age
        passes 2 minutes;
      - `cctrl state migrate --status` prints the same fields and the resume or rollback
        command.
  - The same lock helper (`_cctrl_lock_acquire <file>`) guards `peers.json` and
    `shortcuts.json` rewrites (L2, plan 049 item 2), and later the plan 118 log rotation
    (MF-M7).
  - **SH-S1.** Fix and un-skip `test_peer_mailbox_concurrency_and_stale_lock`, with the skip
    reason replaced rather than just removed.
  - Stays in bash on purpose: a small diff under the existing mailbox tests.
- **Closes.** F3 (read, rewrite, corruption, backup, version), L2, MF-M4, SH-S1, plan 049 items
  1-2; review S9; the writer half of MUST-FIX 2; re-check items R3-MF2, R3-S5
  (reporting half), R3-S7 and R3-S8.
- **Size.** 24 h (reviewer 20; Fable 12; plus 2 for the sentinel and post-lock re-validation,
  plus 1 for the stale-steal specification and its tests, plus 1 in the re-check for the
  crash-left sentinel's doctor, status and exit-75 reporting, the checkout-mode coverage and
  the live-holder test).
- **Risk.** Medium. This is the hottest path in the fleet. An old release under rollback must
  still exclude new writers, which is what the compatibility test proves.
- **Tests.**
  - Truncated last line, NUL byte, duplicate id, a 1 MB line, an invalid UTF-8 line.
  - 50 concurrent senders with ack and gc.
  - kill -9 between the temp write and the rename (fault-injection variable, honoured only
    under A0's test-mode gate, which ships before this phase).
  - Backup restore; `peer repair` idempotence.
  - **An old-release writer against a new-release writer:** run the `7742883` blob's `cctrl`
    from a scratch tree and the new code on the same fixture mailbox concurrently, and check
    no message is lost.
  - A bash shlock holder against the Python locker; stale steal with two waiters; release
    refused when the pid does not match.
  - **Three-party steal (S9):** a stale lock, two waiters and a third process that acquires
    legitimately between a waiter's check and its rename (forced with a test-mode hook).
    Pass when either the found-live path puts the lock back and the waiter goes back to
    waiting, **or** step 4's EEXIST branch fires and the run is **detected and reported as
    `lock-steal-collision`** (record written, aside file left for doctor, the waiter does
    not acquire). In that branch two holders can briefly both have acquired through our
    code; that is the narrow race step 4 reports, so the test asserts the report, not its
    absence (re-check R3-S7).
  - PID reuse: a lock whose pid now belongs to a process started after the lock's mtime is
    stale.
  - **A live holder is never stolen (R3-MF2):** a holder that is SIGSTOPped while
    holding the lock past the warning age (a test-mode override shortens the 120 s
    threshold to 2 s; the mtime is not backdated, which would look like pid reuse) is
    **not** taken by a waiter; the waiter keeps waiting, `peer doctor` shows the age warning, and
    after SIGCONT the holder's rewrite and the waiter's write both land.
  - **Sentinel:** with `<state root>/.migrating` present a writer waits and creates nothing;
    a writer that resolved the old path, then finds the sentinel after taking the lock,
    releases, removes only its own empty dir, and retries; the 120 s cap exits 75.
  - **Sentinel in checkout mode (R3-S8):** a fixture checkout-mode run (no `.installed`)
    with the sandbox sentinel present waits and creates nothing, like an installed run.
  - **Crash-left sentinel (R3-S5):** a sentinel whose recorded pid is dead gives exit 75
    with the pid, age, step and the `--apply`/`--rollback` hint; the doctor row is an issue;
    a sentinel with a live owner under 2 minutes old is info only.
  - Both lock kinds on both bashes.
  - An old-release reader on a file with `v` and a quarantine present.
- **Rollback.** Previous release. The file stays plain JSONL, and old code tolerates `v` and
  ignores the quarantine and backups. The lock protocol is unchanged for old code in the default
  (shlock) mode. **Two exceptions, found by the A1 verifier (S4):** an old release must not run
  with `CCTRL_MAILBOX_LOCK_KIND=dir`, nor on a host without `shlock` (Linux), alongside a new
  one: the old dir code `mkdir`s the lock path, finds no `pid` file inside a new link-protocol
  lock, `rm -rf`s our live lock file and proceeds, which gives two holders. New code cannot fix
  old code, so before a rollback check the launchd plists and env on every host for that
  variable. Verifier probe 2 (macOS): `/usr/bin/shlock` never steals a stale lock itself (for a
  dead pid it reports the process dead and returns 1), so the old release just waits out its
  timeout on a stale lock, and the "shlock's own stale handling unlinks and re-links" race that
  the steal-guard inode check was written for does not occur with this macOS build. The check
  stays as defence against the dir-mode old code and other implementations.
- **Blocked by.** A0 (paths and modes).
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
     - **Writer inventory (review MUST-FIX 2).** cctrl loops are not the only writers. The
       preflight lists, and the report records:
       - every process with a file open under `data/` or `costs/`, from `lsof +D` on both
         (a point-in-time view; most writers open files briefly, hence the named list);
       - **per-session MCP bridges** (`peer_mcp.py` processes, found by `proc_pidpath` of
         the interpreter plus argv, with the release each one runs from). They are
         long-lived, often pinned to old releases, and they send and receive mail;
       - **live session hooks**: statusline, Stop/doorbell and session-log fire
         continuously across every live session. The count of live sessions and the
         release each session's hooks resolve to are listed;
       - **Codex hooks** (`hooks.json` entries and their target paths);
       - **external launchd jobs** that call cctrl (for example a job that calls
         `session say` or touches the mailbox): every plist under `~/Library/LaunchAgents`,
         `/Library/LaunchAgents` and `/Library/LaunchDaemons` whose program arguments
         mention cctrl, its launcher or the data dir.
       - The operator unloads the external jobs for the window (named in the report). MCP
         bridges and hooks cannot be stopped without stopping sessions, so the run relies
         on the sentinel for A1+ code and on the bounded merge for older code. The preflight
         **refuses** when any writer runs a release older than A1, unless
         `--accept-old-writers` is given, and then lists them in the report as "covered only
         by the merge".
     - `--apply` asks for the host name to be typed as confirmation, and runs only in the
       supervised session. The plan 118 classifier does not exist yet at step 4, so this is
       doctrine plus the confirmation, not a caller check.
  2. **Sentinel first.** Create `<state root>/.migrating` (a fixed path, holding
     `{pid, pid_start, host, step, created_at}`, see A1) at the very start of `--apply`.
     From then on every A1+ writer, in installed or checkout mode, waits instead of
     resolving or creating directories, and re-validates after taking a lock (A1). Hooks
     that only sample (the statusline history) skip their write while the sentinel exists
     instead of waiting; other hooks wait at most 5 s and then skip (see the losable list).
  3. **Locks, then backup, then marker** (re-check R3-S6). Take the mailbox,
     `peers.json` and `shortcuts.json` locks and **hold them until step 6's relinks are
     done**, so no writer that honours them is inside a write during the backup or the
     renames. Old releases already use the mailbox lock path (MF-M4), so they are excluded
     from the mailbox too; they do not lock `peers.json` or `shortcuts.json` (L2). Then the
     **backup**: a 0600 tarball of `data/`, `costs/` and `profiles/` beside the state root,
     with a manifest of per-file sizes and hashes. Then write `data/LAYOUT`
     (`{"layout":2,…}`) **before** the rename. The A0 resolver in installed mode uses the
     state dir when `<state>/data/LAYOUT` says 2.
     - **Corrected claim (review MUST-FIX 2).** The earlier text said the marker makes
       new-release writers "switch at the same instant and never recreate the old `data/`".
       That is false on its own: a new-release writer that resolved the old path just
       before the rename would then run the lock helper's `mkdir -p` and recreate `data/`.
       The sentinel (A1: no `mkdir -p`, wait while the sentinel exists, re-validate after
       the lock) is what closes that window for A1+ writers. Old-release writers (pre-A1:
       pinned MCP bridges, old hooks) can still recreate `data/`; the bounded merge
       catches them.
  4. `rename(data, <state>/data)`, still under the locks.
  5. Create a symlink at `data.tmp` and `rename` it to `data`. A symlink cannot be renamed
     onto a directory. If an old-release writer recreated `data/` in the window, the tool
     merges the stray directory into the state dir under the held locks, removes it and
     retries. This is **bounded to 5 attempts, then abort and `--rollback`** (MF-M5).
     **The merge rule (re-check R3-MF1).** A stray `data/` exists only because an
     old-release writer created an empty directory after the rename, so any whole-file store
     it wrote there was most likely built from an **empty base** (it read the now-missing
     file as absent) and holds only that writer's own change. The stray copy is therefore
     never allowed to replace the live state copy:
     - **mailbox:** merged by message id, the newest status winning by `updated_at`;
     - **append-only logs** (statusline history, spending, debug): merged by line;
     - **keyed whole-file stores, merged per key:** `peers.json` per peer name and
       `shortcuts.json` per key. A key only in the stray copy is added. A key in both with
       different values keeps the **state copy's** value, and the stray value is written to
       `<file>.migrate-stray-<ts>` (0600). Keys missing from the stray copy are **not**
       treated as deletions (an empty base cannot be told from a delete);
     - **every other whole-file store** (ring and doorbell state, each `sessions/<name>`
       record, `hosts.json`, and anything not named above): **the state copy wins**. The
       stray copy is kept aside as `<file>.migrate-stray-<ts>` (0600). A file that exists
       only in the stray directory (for example a session record created in the window) is
       moved in, since there is nothing to lose;
     - every kept-aside file is listed in the report for the operator, who can apply a
       stray change by hand. Nothing is discarded silently, and nothing near-empty replaces
       a full store.
  6. Repeat for `costs/` (its own marker). Then `profiles/`, per Q3: copy it into
     `~/.config/cctrl/profiles` and refuse on a name clash with a differing file. The old
     directory is renamed to `profiles.migrated-<ts>`, never deleted.
  7. **Release the locks, remove the sentinel, then verify.** Both go as soon as step 6's
     renames and relinks are done (the window, including the backup, is seconds; the target
     is under 30 s, measured in the rehearsal), before the hashing verify, which is
     read-only. `--rollback` sets the sentinel and takes the locks again for its own window.
     **Verify (re-check R3-S6), per file class against the backup manifest:**
     - files every writer locks (the mailbox, since old releases share its lock path), and
       every file no merge touched: **exact** match of size and hash;
     - `peers.json` and `shortcuts.json`: exact match, or the difference is exactly the
       keys the report lists as added from a stray copy;
     - append-only logs: the backed-up content is a **prefix** of the moved file (an
       accepted old-release writer can append between the backup and the rename, and the
       merge appends stray lines);
     - other whole-file stores: exact match (the state copy wins the merge), with any stray
       copy listed as kept aside;
     - file counts: the manifest's files are all present; extra files are only those the
       report lists as moved in from a stray directory;
     - and the mailbox parses, and `peer doctor` and `session list` agree before and after
       (read-only).
  8. Write a report: what moved, the writer inventory, the merges and their kept-aside
     files, the data the operator should review (`shortcuts.json.bak*`, the hand notes,
     `snapshots/restore-*.json`), and which writes can be affected in the window.
     - **Corrected losable-writes list (review MUST-FIX 2; R3-MF1 and
       SHOULD 4).** What the window can affect:
       - mailbox messages: **not lost** (merged by id; the newest status wins by
         `updated_at`). An old-release sender that waits on the held mailbox lock longer
         than its own lock wait fails with today's lock error, and its sender sees it and
         can retry;
       - append-only logs written by a running writer: **not lost** (merged by line);
       - **writes that hooks skip are dropped, not queued.** While the sentinel exists,
         A1+ hooks wait at most 5 s and then skip. So, for any Stop that fires more than
         5 s into the window: the **session-log Stop hook's spending and session-log
         lines**, and the **Stop/doorbell hook's ring and bell writes**, are not written.
         A missed ring means a waiting message is noticed at the next Stop or poll instead.
         Statusline history samples are simply not taken;
       - **whole-file stores written by an old-release writer in the window**
         (`peers.json`, `shortcuts.json`, ring and doorbell state, `sessions/*`,
         `hosts.json`): the live state copy is **kept**. A new peer name or shortcut key
         from the stray copy is added; any other change that writer made (an update to an
         existing key, a ring or doorbell change, a session record update, a deletion) is
         **not applied** and is kept aside as `<file>.migrate-stray-<ts>`, listed for the
         operator to apply by hand if it matters;
       - Matthew approves the migration on this list, not on the earlier ones.
- **The sync gate (MF-M3).** It runs on both Macs:
  - (a) Matthew reads the scope (includes and excludes) of any file-sync tool that covers the
    checkout. An agent never opens that tool's configuration.
  - (b) A canary: write `data/.sync-canary-<host>-<nonce>` on each Mac, wait for the sync
    interval (default 15 min), and look for the other Mac's canary.
  - (c) Add excludes for `data/`, `costs/`, `profiles/` and `.active-profile` to that tool
    **regardless** of anything else (review S11: closing a to-do item does not stop a
    reload), and close or scope the related item in Matthew's private notes, where D6a
    (plan 122) moves it out of `TODOS.md`.
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
- **Split-brain guard (review S2).** Between A2 and A4, a `git clean -fdx` in `~/dev/cctrl`
  deletes the compat symlink, and an old-code writer then `mkdir -p`s a fresh, empty real
  `data/`. So:
  - `peer doctor` gains a row that is an **issue** when the layout is 2 and
    `~/dev/cctrl/data` (or `costs`) is a real directory, or missing;
  - installed A0+ releases never resolve there once the marker exists (they read the state
    dir directly), so only old-code writers are exposed; the A2 report and the stop-1 text
    (plan 115) tell the operator not to `git clean` `~/dev/cctrl` before A4;
  - the fix is `cctrl state migrate --relink`, which merges any stray directory with the
    same bounded merge and restores the symlink.
- **Closes.** F2, L1, F13 (decided by the canary, and D1 fixes the docs), MF-M3, MF-M5, SH-S3
  (the gate and checkout resolution test), SH-S4; review MUST-FIX 2 (migration half), S2;
  re-check items R3-MF1, R3-S4 and R3-S6.
- **Size.** 25 h build (reviewer 20; Fable 12; plus 3 for the writer inventory, the
  kept-aside merge, the split-brain row and guard, and their tests; plus 2 in the
  re-check for the state-copy-wins and per-key merge with its fixtures, locks held across the backup, and the
  per-class verify), plus about 1 h supervised per Mac.
- **Risk.** Medium-high. It is a one-time live change. The window is two renames. A1+ writers
  wait on the sentinel; old-release writers can still recreate `data/`, the bounded merge
  catches them, and the inventory names them in advance.
- **Tests (fixtures only).**
  - The happy path.
  - Cross-volume refusal; a tracked `data/` file refused.
  - A lock held; loops running, which is refused; `--stop-loops`.
  - **A sender during the window**, with an injected writer between the two renames that
    recreates `data/`, is merged, and the merge loop exhausts and aborts cleanly.
  - **A new-release writer that resolves before the rename and writes after it** (MUST-FIX 2):
    it waits on the sentinel or re-validates after the lock, creates no stray `data/`, and
    its message lands in the state dir.
  - An old-release writer in the window: its stray `data/` is merged by the rules above.
  - **Empty-base stray store (R3-MF1):** after the rename, an old-release
    writer reads `peers.json` as missing, recreates `data/`, and writes a `peers.json`
    holding only its own one entry. After the merge the full state copy survives with every
    original peer, the writer's entry is added if its name was new (or kept aside in
    `peers.json.migrate-stray-<ts>` if the name existed with another value), and no original
    peer is deleted. The same for `shortcuts.json` by key. For a `sessions/<name>` record
    and for doorbell state, the state copy is kept byte for byte, the stray copy is kept
    aside, and both appear in the report.
  - **Locks across the backup (R3-S6):** a new-release sender started during the backup
    waits on the held lock and lands after the relink; an accepted old-release writer that
    appends to a log between the backup and the rename passes the prefix verify; a forced
    mismatch in the mailbox fails the exact verify.
  - The writer inventory on a fixture: a fake MCP bridge, a fake launchd plist naming the
    launcher, an open file under `data/`; a pre-A1 writer refuses without
    `--accept-old-writers`.
  - The split-brain row and guard: a real `~/dev/cctrl/data` under layout 2 is an issue;
    `--relink` merges and restores the symlink.
  - A crash after each step, then a resumable `--apply`.
  - `--rollback` after each step. A second `--apply` is a no-op.
  - The canary logic with a fake sync.
  - The profiles clash.
  - The previous release's `cctrl` runs against the migrated layout through the symlink.
  - Gate and checkout resolve the same paths under the harness (SH-S3).
  - A post-move check list built only from read-only status commands.
- **Rollback.** `cctrl state migrate --rollback`: under the sentinel and the same locks, reverse the rename,
  remove the symlink and the marker, and restore `profiles/` from `profiles.migrated-<ts>`.
  If that fails, restore the tarball. The previous release keeps working either way, because
  it follows the symlink.
- **Blocked by.** A0, A1, C1, and C2 with its layout guard (plan 117, MF-M2); the Q1 canary
  and the Q3 decision.
- **Needs Matthew's yes:**
  - reading the file-sync scope himself, and adding the four excludes;
  - the writer inventory and the corrected losable-writes list, read before each run;
  - unloading the external launchd jobs for the window;
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
- **Blocked by.** A0, A1. It should land after A2, so the plist is written against the final
  paths.
- **Needs Matthew's yes:** loading the plist on each Mac (an install on the live machine), and
  the install.

### A4. Remove the scaffolding (step 9, after a quiet period)

- **Scope.**
  - **Guards.** Runs only when all of these show nothing using the working tree, and at
    least two weeks after A2 on both Macs:
    - `release prune --dry-run`: no retained release, and no live process, using the old
      path;
    - **configuration that points into a working tree (review S8):**
      `~/.claude/settings.json` hooks and statusline, Codex `hooks.json`, launchd plists
      (user and system), and MCP server configs (Claude and Codex). Any entry whose path
      resolves into `~/dev/cctrl` or a worktree blocks A4, because such a hook would run in
      checkout mode and write to the checkout's own private `data/` or `costs/` after the
      symlink goes.
  - **MF-M2, made unambiguous (review S7).** Repoint **every** retained release's `data` and
    `costs` links from `~/dev/cctrl/…` to the state dir, without exception, including the
    releases from A0 to A1 that already resolve the state dir themselves. Nothing is pruned
    instead of repointed unless Matthew asks. A test lists every retained release after the
    run and asserts none links into a working tree. With C2's guard, a forced rollback to a
    pre-C2 release then still reads the right store, and every release that declares
    `layout_max: 2` can read the store with or without the link (A0's dormant rule).
  - Remove the `~/dev/cctrl/data` and `costs` symlinks; a checkout then uses its own private
    `data/` (Q2).
  - Stop `self-install.sh` creating the four symlinks.
  - Delete the legacy `.active-profile` reader.
  - Update README and docs (with D1/D2, plan 122).
- **Closes.** F2 (complete), MF-M2 (second half); review S7, S8.
- **Size.** 7 h (reviewer 6; Fable 4; plus 1 for the configuration scan).
- **Risk.** Low, given the guards.
- **Tests.**
  - The install test asserts that no release links into a working tree (E7).
  - A checkout run uses its own `data/`.
  - The repoint tool on fixture releases: every retained release is repointed, none skipped.
  - A rollback to a repointed old release reads the state dir.
  - The configuration scan: a fixture `settings.json` hook, Codex `hooks.json` entry,
    launchd plist and MCP config pointing into a working tree each block A4.
- **Rollback.** Recreate the symlinks (`cctrl state migrate --relink`). Releases are only
  repointed, so they can be pointed back.
- **Blocked by.** A2 on both Macs, C2, **C4 (stale Codex hooks removed) and C5
  (`statusline install` writes the `current/` path)** (S8), and a quiet period.
- **Needs Matthew's yes:** the install, and the repoint or prune of old releases on each Mac.

## Size summary

| Phase | h | Source |
|---|---|---|
| A0 | 14 | reviewer 12, + 2 (S5 runbook and test; test-mode gate moved from O5) |
| A1 | 24 | reviewer 20, + 3 (sentinel; stale-steal spec), + 1 re-check (crash-left sentinel reporting, checkout mode, live-holder test) |
| A2 | 25 + 2 supervised | reviewer 20, + 3 (writer inventory, kept-aside merge, split-brain guard), + 2 re-check (state-copy-wins and per-key merge, locks across the backup, per-class verify) |
| A3 | 8 | Fable |
| A4 | 7 | reviewer 6, + 1 (configuration scan) |
| **Total** | **78** (+2 supervised) | was 66; 75 after the second review; + 3 in the re-check |

## Execution and acceptance criteria

- **Execution.** Run per phase under the orchestrator, in step order (A0, A1, then A2 after
  C1/C2, A3, A4 last). Never flip this plan to `pending` as a whole: `mstack-run` would then
  run every phase, including the live migration, in one go. The frontmatter
  `blocked-by: [115]` is a guard (115 stays `split`).
- [ ] A0: the shell and Python resolvers agree on every row of the path matrix; `git ls-files
  data` is empty; the `data/config.json` runbook ran on every checkout and the file is
  present and untracked; the test-mode gate refuses the live seal key.
- [ ] A1: a bad mailbox line is quarantined and the rest stays readable; the old-vs-new writer
  test and the three-party steal test pass; writers honour `.migrating` and never
  `mkdir -p` the data dir.
- [ ] A2: the writer inventory and the corrected losable-writes list were in front of Matthew
  before each Mac's run; the new-release-writer-in-the-window test passes; the post-move
  read-only checks agree before and after; the empty-base stray-store fixture keeps the full
  state copy; no `migrate-stray` file is left unreviewed.
- [ ] A3: queued and unread mail never move; `session-log.py` loses no line under 10
  concurrent Stops.
- [ ] A4: no retained release, live process or configuration entry points into a working
  tree; every retained release is repointed.

## Interaction with other workstreams

- Plan 117: C2's layout guard is a hard prerequisite of A2. C1 runs before A2, so the release
  that carries A2 was installed from a pushed main.
- Plan 119: the test-mode gate it used to own now ships in A0; O5 uses it.
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
- Plan 049 items 3-4 (what to do about a long lock hold, nudge dedupe). A1 never steals a
  lock from a live holder and only reports a long hold as a `peer doctor` warning.
- Any change to the seal key path.
- Syncing state between the Macs. Each Mac keeps its own store.
