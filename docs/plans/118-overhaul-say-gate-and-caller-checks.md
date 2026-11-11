---
id: 118
title: Overhaul O3/O4 - gate and log say, caller checks on roles, doorbell and mail, sealed role grants
status: blocked
blocked-by: [115]
priority: 13
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-11-11
approval: "Operator approval on record (plan-only grant): PLAN ONLY. Run per phase under the orchestrator; never flip this plan to pending as a whole. Waits for Matthew's prioritisation from plan 115. Installs, the hook-rule settings changes, --regrant-live on each Mac and every enforce flip each need their own yes."
approved-by: pending (Matthew, via plan 115)
reviews: []
related: 115, 116, 119, 120, 121, 122, 077, 108, 110, 111, 114
---

The security track for audit findings **H1** (option 3), and **H2** and **H4** (option 4).
Umbrella: plan 115. This plan merges the two drafts `plan-audit-opt3-say-gate.md` and
`plan-audit-opt4-caller-checks.md` and revises them for the independent review:
- **MF-M6:** the operator class was reachable through a detached tmux or `script`.
- **MF-M7:** the design must use plan 116's resolver paths and plan 120's interface list.
- **SH-S15:** sizes rescaled to 40 h and 35 h.
- **The plan 115 review (second round):** MUST-FIX 1 (the classifier uses `proc_pidpath` and a
  tty rule, the `open … .command` residual is named, iTerm2 and SSH are handled, and the
  `operator-tty` grant path gets an out-of-band confirmation), S3 (no A2 dependency), S4
  (`--operator` parsed in O3.1) and S14 (grants after a power cycle).

It is written against the post-plan-116 layout. Baseline is `main` at `8c249fc`, where option
2 is in (an unknown attestation mode fails closed) and option 1 is in (the kill guard).

## Problem

- **H1.** `_session_say` pastes text into any exact-named session and presses Enter, with no
  caller check and no log. CLI `peer say` runs its caller and doorbell gate only when
  `CCTRL_SAY_REQUIRE_DOORBELL=1`, which only the MCP bridge sets. The body comes first on the
  line, so a leading `/` runs a slash command. A worker cannot tell a real fleet-manager
  follow-up from a forged one.
- **H2.** `session set-role` and `cctrl start --role orchestrator` have no caller check, and
  the record role is copied into the sealed attest. `CCTRL_ALLOW_SECOND_FLEET_MANAGER=1` skips
  the one-FM check. The doorbell mutators (`enable`, `disable`, `move`, `allow-sender`,
  `deny-sender`, `reset-senders`) have no caller check.
- **H4.** `_mailbox_resolve_identity_for_mode` trusts `--as`, then `CCTRL_PEER`. Then
  `recv --all --as B` plus `ack --all --as B` silently drain B, and history blames B.
  `peer gc --older-than 0 --status queued` removes everyone's unread mail into a 0644 archive.
- Without these fixes an `attestation` enforce flip adds little (audit summary 2). The plan
  115 rule stands: no enforce flip before this plan's warn phases have run a week.

## Threat model and the honest ceiling

- Every session is the same macOS user with bypassPermissions. These are **misuse barriers
  for cooperative or confused agents**, not authentication.
- A same-uid process can edit any state file, read the seal key, or drive tmux directly.
  This plan does three things within that limit:
  - makes the sanctioned path the only clean one;
  - logs every privileged act in sealed logs;
  - raises role forgery from "edit one JSON field" to "read the key, or open a real Terminal
    window and pass an out-of-band confirmation" (see below).
- **Accepted residual risk (stated in SECURITY.md by plan 122's D2), revised for the plan 115
  review's MUST-FIX 1:**
  - (1) **Any agent can open a genuine login-rooted Terminal window.** `open -a Terminal
    x.command` (or `open x.command`, or a `.terminal` file) runs a file the agent wrote in a
    new Terminal window under a real `login`. The process chain is genuine, so no ancestry
    check, including the `proc_pidpath` walk below, can tell it from Matthew typing. It
    needs no Automation/TCC consent. This is a one-call barrier, not "drive Terminal.app".
    The class check alone is therefore **not** a barrier against a hostile agent. The
    barrier for the grant set is the out-of-band confirmation (Q10 in plan 115, built in
    O4.1): an agent in a fresh `.command` window has no sudo ticket, no password and no
    finger on Touch ID.
  - (2) An agent that drives Terminal.app or iTerm2 through osascript or System Events can
    also type into an existing window. That needs an Automation consent prompt the first
    time (to be confirmed by O3.1's supervised check), and the out-of-band confirmation
    still stops it unless the window already holds a sudo ticket (the confirmation runs
    `sudo -k` first, so it never reuses one).
  - (3) Reading the seal key or editing state files directly. A hook rule narrows this but
    only matches command text.
  - (4) A prompt-injected fleet manager has the FM's rights.
  - (5) Raw `tmux send-keys`/`paste-buffer` and the native socket bypass `say` entirely, so
    the sanctioned path is made the visible one.
  - Without the out-of-band confirmation (if Q10 rejects it), (1) means `operator-tty` is a
    label for honest callers only, and SECURITY.md says so in those words.

## Design

### Caller classes (one classifier; MF-M6 applied)

New module `lib/caller_class.py`: stdlib only, called from bash as
`python3 -I lib/caller_class.py --json`, so plan 120's B4 adopts it rather than ports it (Q9
in plan 115). It wraps plan 111's process-tree walk (`_peer_caller_attest … no-claim`) and
adds an agent-ancestor check, a tty check and a **login-root** check. It returns one class.

| class | how it is known |
|---|---|
| `fleet-manager` | level session, role orchestrator, orch_kind fleet, **and `role_grant: ok`** (record role only, and `grant: missing` logged, until O4.2 lands) |
| `orchestrator` | as above with orch_kind repo |
| `worker` | level session, role worker or none |
| `agent-unattested` | an agent is on the ancestor chain, but the walk is not level session |
| `app-claimed` | no pane, and `CODEX_THREAD_ID`/`CODEX_SESSION_ID` is set |
| `operator-tty` | no agent ancestor; stdin and stderr are TTYs; no `SSH_CONNECTION`; **the `proc_pidpath` walk reaches a login root**: a `/usr/bin/login` process whose parent's real executable is the Terminal.app binary, and the caller's controlling tty **is that `login`'s tty** (so no pty creator of any kind sits between the window and the caller) |
| `operator-flag` | no agent ancestor, and `--operator` given |
| `script` | no agent ancestor, and none of the above; this includes every pane of a daemonised tmux server and every reparented (`ppid 1`) process, TTY or not |
| `remote` | arrived over SSH from the other Mac with `CCTRL_ORIGIN_ATTEST` claims |

- **What changed for MF-M6.** The draft's `operator-tty` accepted any TTY with no agent
  ancestor. Both bypasses the reviewer found now land in `script`:
  - `tmux -L x new-session -d '…'`: the tmux server daemonises to `ppid 1`, so the walk never
    reaches a login root;
  - a double fork into `script -q /dev/null …`: reparented, and `script` is on the chain.

  Matthew's own plain tmux shells also classify as `script`. He uses a plain Terminal tab, or
  `--operator` for the operations that allow it.
- **Executables come from `proc_pidpath`, never from `ps comm` or argv[0]** (plan 115 review,
  MUST-FIX 1). On macOS `ps -o comm=` reports argv[0], which any process can set with
  `exec -a`; the reviewer reproduced a `/bin/sleep` that `ps` reported as the Terminal binary.
  - The walk takes pid and ppid from one `/bin/ps -axo pid=,ppid=,tty=` snapshot (the kernel
    sets those; a process cannot forge them), and resolves **every** chain element's real
    executable with `proc_pidpath()` from libproc, through `ctypes` (stdlib only).
  - A pid that exits mid-walk, or whose `proc_pidpath` fails, ends the walk as `script`.
  - Optional hardening, decided at build time: check that the root binary is the
    Apple-signed platform Terminal (`codesign --verify -R 'anchor apple'`, cached per pid
    and start time). It is cheap insurance against a copied, re-signed binary, but it does
    not touch the `open` residual.
- **The tty rule replaces the name list of pty creators.** The draft denied `script` and tmux
  by name, and the review showed that other pty creators (Python `pty.fork`, `expect`,
  `screen`, any small C stub) were not named. The rule is now positive: the caller's
  controlling tty must equal the tty of the `login` process found under the root. Any pty
  created below the window gives a different tty and the class is `script`.
- **The login roots are hard-coded.** Terminal.app's binary path and `/usr/bin/login`, both
  matched by `proc_pidpath`, not configurable. A test-mode-only override exists for the
  harness, gated by plan 116's test-mode gate (A0), and the override can only name binaries
  inside the test sandbox.
- **iTerm2 is unverified, so it is not a login root yet.** With session restoration on,
  iTerm2 runs shells under `iTermServer` helper processes that are probably daemonised
  (ppid 1), and the helper binary is copied into a user-writable Application Support
  directory. Until O3.1's supervised check records the real chain on the MacBook (with and
  without session restoration), iTerm2 shells classify as `script`, and Matthew uses a
  Terminal.app window for grant acts. If the check shows a stable chain whose root is the
  signed iTerm2 app binary under `/Applications`, a follow-up adds it with the same tty
  rule.
- **Over SSH Matthew is never `operator-tty`.** `SSH_CONNECTION` set means `script` (or
  `operator-flag` with `--operator`). So grant-set acts on one Mac cannot be done from the
  other over SSH; Matthew must be at that Mac's screen, or in Screen Sharing to a Terminal
  window on it. Plan 115 Q10 states this.
- **Agent ancestor.** A real executable (by `proc_pidpath`) whose basename is `claude` or
  `codex`, or `$CLAUDE_SESSIONS_DIR/<pid>.json` exists for it. It uses the same single
  snapshot, and the walk is capped at 16 levels.
- **Env markers** (`CLAUDECODE`, `CODEX_THREAD_ID`, `CCTRL_PEER`) may only lower a class,
  never raise one (plan 111 rule).
- **M5 hardening in this path.**
  - Tools are called by absolute path (`/bin/ps`, the pinned tmux binary).
  - When `CCTRL_SESSION_METADATA_DIR`, `TMUX_TMPDIR`, `CCTRL_TMUX_EXTRA_SERVERS` or
    `CCTRL_DATA_DIR` differ from the resolver's defaults, the log records `env_override` and
    the class is capped at `worker`/`script`.
  - Plan 119's O5 makes those overrides test-mode-only for the attest path.

### The privileged sets

- **Grant set:**
  - `set-role … orchestrator` (repo or fleet), and clearing an orchestrator;
  - `cctrl start --role orchestrator`;
  - honouring `CCTRL_ALLOW_SECOND_FLEET_MANAGER`;
  - the doorbell mutators;
  - `set-role --regrant-live`.

  Allowed **only** for `fleet-manager` with a good grant (plus handover rules) and for
  `operator-tty` **with the out-of-band confirmation below**. **Never** for `operator-flag`,
  `script`, `remote` or `app-claimed`. Remote grant acts are refused, because origin claims
  can be forged by raw ssh. This is the MF-M6 fix for options 3/4.
- **Out-of-band confirmation on the `operator-tty` grant path** (recommended in plan 115 Q10;
  built in O4.1):
  - Before a grant-set act by `operator-tty`, cctrl runs `sudo -k` and then `sudo -v` on the
    caller's tty. `sudo -v` only validates credentials: **no command runs as root**. With
    `pam_tid` enabled in `/etc/pam.d/sudo_local`, the prompt is Touch ID; otherwise the
    login password.
  - An agent in a fresh `open … .command` window has no password and no finger, and `sudo -k`
    removes any ticket an existing window held.
  - If `sudo -k; sudo -n -v` succeeds (a NOPASSWD rule), the confirmation is unavailable.
    cctrl says so, logs `confirm: unavailable`, and treats it as failed in enforce.
  - The FM-with-grant path needs no confirmation, so normal fleet operation is unchanged.
    Only Matthew's own grant acts (`--regrant-live`, starting an orchestrator himself,
    doorbell edits by hand) prompt.
  - Logged in `admin.jsonl` as `confirm: ok | failed | unavailable`. In warn a failure is
    logged `would-refuse` and the act proceeds; in enforce it is refused with exit 77.
  - If Q10 rejects the confirmation, the row stays `operator-tty` alone and SECURITY.md
    states residual (1) without a barrier.
- **Operator-flag set** (allowed for `operator-flag` as well as FM and `operator-tty`):
  - `say`;
  - `set-role X worker`, and clearing a non-orchestrator;
  - `peer gc` of **acked** mail only (the plan 116 A3 plist).
- Everything else follows the tables below.

### Who may say (option 3)

| caller | say text | one-line `/command` (raw) | `--raw`, `--force-busy` into a non-agent pane |
|---|---|---|---|
| fleet-manager | yes | yes | yes |
| orchestrator | yes, any target (plan 115 Q11) | yes | yes |
| operator-tty, operator-flag | yes | yes | yes |
| worker | refused, hint `peer send` | refused | refused |
| agent-unattested, script | refused, hint `peer send` or `--operator` | refused | refused |
| app-claimed | refused unless named in the recipient's `push_senders.peers` (one answer with option 4, Q11) | refused | refused |
| remote | by origin claims (FM, orchestrator or operator), labelled unverified | same | refused |

- "Refused" applies only in enforce. In warn every row is allowed and logged `would-refuse`.
- A refusal exits **77** (sysexits `EX_NOPERM`): `say-not-allowed` in JSON. Nothing is pasted.
- MCP `say_peer` keeps its plan 110/111 checks, and this gate runs after them.
  `--operator` is never available through MCP.

### Provenance line (option 3)

- One line, pasted before the body in the same `load-buffer`/`paste-buffer -p -r`:
  `[cctrl say] from: <who> · <how> · id: say_<UTC>_<6hex>`.
- Examples:
  - `from: TMUX--hostA--fm (fleet-manager) · verified session`
  - `from: operator · terminal on hostA`
  - `from: operator · --operator, no terminal on hostA`
  - `from: unverified caller (worker TMUX--hostA--w1) · warn mode`
  - `from: TMUX--hostB--fm (fleet-manager) · remote from hostB, claims not verified here`
- Every field is a validated name or a fixed word. C0 characters are stripped and the line is
  capped at 240 characters. warn and off carry no "untrusted" wording (plan 111 §3).
- **Raw exemption:** a one-line body starting with `/`, and `--raw` bodies, are sent without
  the line. They are logged `raw: slash|flag`. In enforce they are allowed only for FM,
  orchestrator and operator classes.
- `--no-submit` drafts get the line too. A `[` at the start of a non-agent shell line fails
  harmlessly.

### Logs (both options; MF-M7)

- Directory: the resolver's `audit_dir` (`<state root>/audit`, 0700). Files: `say.jsonl` and
  `admin.jsonl`, 0600, per host, never synced.
- A `say.jsonl` line: `{v:1, id, at, host_id, host_label, mode, via, outcome, target,
  target_agent, submit, raw, force_busy, body_sha256, body_len, caller:{class, level,
  session, role, orch_kind, role_grant, tty, login_root, operator_flag, env_override,
  ssh_client?, origin_host?, origin_claims?}, mac}`. **The body is never stored.**
- An `admin.jsonl` line: `{v:1, at, host_id, mode, verb, args_summary, target, outcome,
  caller:{…}, mac}`, with names and flags only. recv and ack log only when the caller is not
  bound to the identity.
- **Seal.** `mac` is HMAC-SHA256 from `lib/peer_seal.py` with the existing per-host key and
  the domain prefixes `cctrl-say-log-v1` and `cctrl-admin-log-v1`, with the same key checks
  and 5 s bound as plan 111. If the seal fails, the line is written unsealed and verify says
  so.
- **Rotation.** At 4 MiB, keeping `.1` to `.3`. It is built on plan 116's A1 lock helper
  (`_cctrl_lock_acquire`), **not** a new lock (MF-M7).
- **Write failure.** warn proceeds with a stderr note. Enforce refuses non-operator callers;
  an operator is allowed, with a warning.
- **`peer doctor` rows.**
  - `say_log`: size, last write, `would-refuse` counts by class over 7 days.
  - `caller_checks`: mode, `would-refuse` by verb and class.
  - `role_grant`: live orchestrators whose grant is not `ok`.
- **Grant notice.** Every grant-set action also mails a one-line notice to the current FM
  (and to the operator log), so an unexpected grant is visible.

### `cctrl session say-verify <id> [--json]`

- Read-only. It finds the line, checks the mac, and prints the caller, target, host, time and
  body hash/length, plus whether the target is the verifier's own session.
- A forged `[cctrl say]` line typed with raw tmux has no entry, or a bad mac. A replay shows
  the wrong target.

### Who may call what (option 4; MF-M6 applied)

| command | FM | repo orch | worker | operator-tty | operator-flag | script | app-claimed | remote |
|---|---|---|---|---|---|---|---|---|
| `set-role X worker`, clear a non-orchestrator | yes | yes | no | yes | yes | no | no | claims FM/operator |
| `set-role X orchestrator --orch-kind repo`, clear an orchestrator | yes | no | no | yes | **no** | no | no | **no** |
| `set-role X orchestrator --orch-kind fleet` | handover only (X `succeeds` the caller) | no | no | yes | **no** | no | no | no |
| `start --role orchestrator` | yes | no | no | yes | **no** | no | no | **no** |
| `start --role worker` or no role | yes | yes | yes | yes | yes | yes | yes | yes |
| `CCTRL_ALLOW_SECOND_FLEET_MANAGER` honoured | no | no | no | yes | **no** | no | no | no |
| doorbell `enable/disable/move/allow-sender/deny-sender/reset-senders` | yes | no | no | yes | **no** | no | no | **no** |
| doorbell `status`, any `--dry-run` | all | all | all | all | all | all | all | all |
| `peer recv/ack/reply --as X` (mutating) | any X | X bound to own session | same | any X | **X only if X has no session binding** | X only if X has no session binding | own app peer (existing check) | no (local only) |
| `peer gc`, acked only | yes | yes | no | yes | yes | no | no | no |
| `peer gc`, queued or delivered | yes | no | no | yes | **no** | no | no | no |
| `set-role --regrant-live` | yes | no | no | yes | **no** | no | no | no |

- "no" means exit 77 (`caller-not-allowed`) in enforce, and `would-refuse` in warn.
  **Bold** marks the cells changed from the option 4 draft (MF-M6).
- "Bound to own session" reuses plan 077's `_peer_sender_binding_mismatch`: aliases
  re-pointed at handover still bind. The Stop bell's `peer recv --all --as <self>` always
  passes.
- When the FM or operator acts for another identity, history records
  `{by: X, caller: {class, session}}`. History is outside the seal; it is an audit trail.
- The gc archive is created 0600.

### Sealed role grants (option 4)

- set-role, start and restore write `role_grant: {v:1, role, orch_kind, session,
  pane_started, granted_by:{class, session}, at, mac}` into the session record. The mac uses
  domain `cctrl-role-grant-v1`, with the same key and helper.
- `_peer_caller_attest` verifies the grant: the mac is good, `session` matches, `pane_started`
  equals the anchor, and role and kind equal the record. It adds `role_grant: ok | missing |
  bad | stale` to the attest, which is sealed with the message.
- Under `attestation` enforce, a push role counts only with `role_grant: ok`. In warn it is
  shown in doctor only.
- **Restore.** The restoring FM, or Matthew in Terminal, issues fresh grants. A restore by
  anyone else leaves `missing`.
- **Migration.** On each Mac, Matthew runs `cctrl session set-role --regrant-live --dry-run`
  in Terminal, reads the list, then runs it for real. Roles nobody vouches for stay `missing`.
- **After a power cycle or reboot (plan 115 review S14).** Every pane anchor changes, so every
  grant reads `stale`, **including the new FM's own**. Doctrine has the new FM run the
  restore, but an FM with a stale grant cannot issue grants, and the FM is normally not
  started from a plain Terminal tab. So after each power cycle every orchestrator is
  `missing`/`stale` until Matthew runs `--regrant-live` (with the confirmation) at that Mac's
  screen. Under `attestation` enforce, orchestrator mail is not push-eligible until then;
  in warn nothing changes except the doctor row. Plan 115 Q10 offers a re-anchor option,
  decided before O4.2 is built: `session restore` re-anchors a grant only when its mac
  verifies, its agent session id matches the pre-restore snapshot entry, **and its old pane
  anchor predates the current boot time** (`kern.boottime`), so only panes that really died
  with the reboot qualify. Each re-anchor is logged in `admin.jsonl` as `re-anchored` and
  mailed to the FM like any grant notice. If chosen, it is built in O4.2 (inside its 13 h,
  replacing the "restore by the FM issues grants" path for this case) with tests for each of
  the three conditions.

### Modes

- `doorbell.json` keys `say_gate` and `caller_checks`: `off | warn | enforce`. Absent or null
  means warn; any other value means enforce (fail closed, like option 2). `attestation` stays
  separate.
- There is no CLI to set them; a hand edit is the operator path. The doorbell verbs that
  could edit the file are themselves grant-set.
- `doorbell status` and `peer doctor` show both modes.

### Remote (the other Mac)

- The origin classifies and gates first. The class and the plan 111 claims ride in the
  existing `CCTRL_ORIGIN_ATTEST` env channel, so older receivers ignore them.
- The receiver uses class `remote`. Say and the operator-flag set are allowed on claimed FM,
  orchestrator or operator. **Grant-set acts are refused remotely**: run them on the target
  Mac.

### Hook rules (O3.5, O4.4; MF-M7)

- These extend the PreToolUse guard (merged with plan 111 phase 7). They deny agent Bash
  commands that:
  - contain `--operator` or `CCTRL_ORIGIN_ATTEST=`, including inside `ssh '…'` strings;
  - write to `doorbell.json`, `sessions/`, `audit/` or the seal key.
- **Paths are matched by resolved real path.** The hook imports plan 116's `paths.py` and
  realpath-normalises every path-like token, so the state dir, the
  `~/dev/cctrl/data` symlink and every release's `data` symlink all match. A rule written
  for today's `data/doorbell.json` would stop working the day A2 lands.
- The rules are text heuristics on the command line. Obfuscation defeats them, which is the
  stated residual. They fail open on bad input, like every hook (plan 079).

## Phases

All in warn. Each phase is installed separately. Sizes are the option drafts' phases
rescaled to the reviewer's totals (SH-S15), plus 6 h for MF-M6.

### O3.1. Classifier, say gate in warn, `say.jsonl`, `--operator` parsed (step 5)

- **Scope.**
  - `lib/caller_class.py` with the MF-M6 login-root rule as revised above: `proc_pidpath`
    for every chain element, the tty-equality rule, Terminal.app only (iTerm2 pending the
    check below).
  - The gate inside `_session_say`, so all three entry points are covered.
  - The `say_gate` mode, `say.jsonl` with seal and rotation, and the doctor rows.
  - **`--operator` is parsed here** and logged as the class `operator-flag` (plan 115 review
    S4). It is used in step 5 by O4.1's tests and in step 6 by A3's plist, so it must exist
    before them. O3.3 only adds the enforce refusals.
  - **A supervised check on the MacBook, in Terminal.app and in iTerm2** (result goes into
    SECURITY.md and decides the iTerm2 row):
    - `open -a Terminal x.command` and `open x.command` from a fleet pane: record the chain
      and the class (expected: `operator-tty`, which is the stated residual);
    - osascript/System Events driving Terminal and iTerm2 from a fleet pane: is there a
      consent prompt?
    - a plain iTerm2 tab with and without session restoration: record the real chain
      (`iTermServer`, its ppid and its `proc_pidpath`).
- **Closes.** H1 (logging and the decision point), M5 (part), MF-M6, MF-M7, plan 115 review
  MUST-FIX 1 (classifier half; O4.1 has the confirmation half), S4.
- **Size.** 22 h (12 rescaled from the draft's 8, plus 6 for MF-M6, plus 3 for the
  `proc_pidpath` walk, the tty rule and their tests, plus 1 moved from O3.3 for
  `--operator`).
- **Risk.** Low. warn only; adds about 0.3 s per say.
- **Tests.**
  - Every class. A real pty under `script -q /dev/null` with **no** login root gives
    `script`.
  - **A detached tmux on a private socket running cctrl gives `script`; a double-forked
    `script` gives `script`** (the MF-M6 cases).
  - **argv[0] spoof:** a double-forked stub run with `exec -a <Terminal binary path>` (ppid
    1), with a pty under it and cctrl inside, gives `script`; `ps comm` shows the Terminal
    path and the classifier still says `script`.
  - **Other pty creators:** Python `pty.fork` under a reparented stub gives `script`; a pty
    opened below a genuine (test-mode) login root also gives `script` by the tty rule.
  - `login` is matched by `proc_pidpath` (`/usr/bin/login`), not by the bare `ps` name.
  - A pid that exits mid-walk gives `script`.
  - A login-rooted chain via the test-mode root override gives `operator-tty`. The override
    is ignored outside test mode, and cannot name a binary outside the sandbox.
  - `SSH_CONNECTION` set gives `script` even under a login root.
  - An env override caps the class. `--operator` inside an agent's chain is still `agent`;
    `--operator` with no agent ancestor is `operator-flag`.
  - The log: one line per attempt, no body bytes (canary body), 0600/0700, the mac verifies,
    a tampered line fails, a missing key writes the line unsealed, rotation under
    concurrency.
  - Performance at most 0.4 s per say.
- **Rollback.** `say_gate: off` (logging continues), or the previous release.
- **Blocked by.** Plan 116's A0 (`audit_dir`, `paths.py`, the test-mode gate) and A1 (lock
  helper). **Not A2** (plan 115 review S3): the classifier, `say.jsonl` and the caller gates
  use the state root's `audit/`, which exists before the move. Only the O3.5/O4.4 hook rules
  need post-A2 paths. Plan 121's E4 should land first (its expected-failure cases flip to
  passing).
- **Needs Matthew's yes:** the install on each Mac, and the supervised check on the MacBook
  (Terminal.app and iTerm2).

### O3.2. Provenance line, raw exemptions, `say-verify` (step 5)

- **Scope.**
  - The `[cctrl say]` line, the slash and `--raw` exemptions, and `session say-verify`.
  - **Same window, doctrine:**
    - the FM and orchestrator skills move from raw `tmux send-keys`/`paste-buffer` to
      `cctrl session say` for text (raw keys only for dialogs);
    - the APPROVALS block in `skills/cctrl-spawn` says that a follow-up carrying the line can
      be checked with `say-verify`, and that **a missing line means "unverified, as today",
      never "reject"** (the worker-briefs incident).
- **Closes.** H1 (provenance).
- **Size.** 9 h.
- **Risk.** Medium. The pasted bytes change.
- **Tests.**
  - The exact pasted bytes (update `test_session_say_long_body_bracketed_exact`).
  - A one-line `/effort` is raw; a multi-line `/` body is not raw; `--raw` is raw.
  - Field sanitising; no "untrusted" wording in warn.
  - `say-verify`: found, unknown, bad mac, target mismatch.
- **Rollback.** `say_gate: off` removes the line without an uninstall; or the previous
  release.
- **Blocked by.** O3.1.
- **Needs Matthew's yes:**
  - the install on each Mac;
  - the skills and APPROVALS wording change, which reaches every new worker;
  - any external runbooks or briefs outside this repo that paste follow-ups or call
    `session say` (for example an external launchd job), updated by their owners in the
    same window.

### O4.1. Caller checks on roles, start and doorbell; `admin.jsonl` (step 5)

- **Scope.** Gates on set-role, `start --role orchestrator`, the second-FM override and the
  doorbell mutators, with the MF-M6 table. The `caller_checks` mode, `admin.jsonl` and the
  doctor row. The enforce code path is built; the live mode stays warn.
  - **The out-of-band confirmation** (`sudo -k; sudo -v`, Touch ID where enabled) on the
    `operator-tty` grant path, as designed above, if plan 115 Q10 accepts it.
- **Closes.** H2 (CLI half); plan 115 review MUST-FIX 1 (confirmation half).
- **Size.** 12 h (10 rescaled from the draft's 7, plus 2 for the confirmation).
- **Risk.** Low (warn).
- **Tests.**
  - Each table row × class, in warn and in enforce (exit 77, nothing written).
  - A worker self-promoting is refused in enforce.
  - `--orch-kind fleet` only for the `succeeds` session or `operator-tty`.
  - `operator-flag` is refused for the grant set (`--operator` exists since O3.1).
  - Doorbell `move` by either FM at handover.
  - The confirmation, with a stubbed `sudo` on a test-mode PATH: ok proceeds; failed is
    `would-refuse` in warn and exit 77 in enforce; a NOPASSWD stub (`sudo -n -v` succeeds
    after `-k`) reads `unavailable`; `sudo -k` is always called first; the FM-with-grant
    path never prompts. The stub is honoured only in test mode.
- **Rollback.** `caller_checks: off`, or the previous release.
- **Blocked by.** O3.1.
- **Needs Matthew's yes:** the install on each Mac.

### O4.2. Sealed role grants and `--regrant-live` (step 5)

- **Scope.**
  - `role_grant` is written by set-role, start and restore, and verified in the attest.
  - `role_grant` appears in the attest and in eligibility (warn: doctor only).
  - `--regrant-live [--dry-run]`.
- **Closes.** H2 (grant half: a hand-edited record no longer yields an orchestrator).
- **Size.** 13 h.
- **Risk.** Medium. It touches start, restore and attest.
- **Tests.**
  - A hand-edited record reads `bad`; a grant copied to another session, or kept across a
    relaunch, reads `stale`; a missing key reads `missing`.
  - `--regrant-live --dry-run` writes nothing.
  - A sealed message keeps `role_grant`.
  - Plan 111 eligibility under enforce needs `ok`.
  - Restore by the FM issues grants.
- **Rollback.** The previous release. Grants are extra record fields that old code ignores.
- **Blocked by.** O4.1.
- **Needs Matthew's yes:** the install on each Mac; then **Matthew runs `--regrant-live`
  himself in a Terminal.app window at each Mac's screen** (not over SSH, and not in iTerm2
  until O3.1's check clears it), after reading the dry run. **He must do this again after
  every power cycle or reboot of a Mac**, because every grant goes `stale` (S14), unless the
  Q10 re-anchor option is chosen.

### O4.3. Mailbox binding and gc limits (step 5)

- **Scope.**
  - recv, ack and reply `--as` are bound to the caller's own session, with FM and
    `operator-tty` exceptions recorded in history.
  - gc of queued or delivered mail is limited to FM and `operator-tty`.
  - The archive is 0600.
- **Closes.** H4.
- **Size.** 9 h.
- **Risk.** Low (warn).
- **Tests.**
  - `recv --all --as B` from A's pane is refused in enforce and logged in warn.
  - The FM or operator doing it records `caller`.
  - A handover alias still binds; the Stop bell's own recv passes; a Codex app peer is
    unchanged.
  - gc rows per class; `--dry-run` is open.
- **Rollback.** `caller_checks: off`, or the previous release.
- **Blocked by.** O4.1.
- **Needs Matthew's yes:** the install on each Mac.

### O3.3. Say-gate enforce code path (step 7)

- **Scope.** The refusal table, exit 77, the enforce refusals for `--operator` (the flag
  itself is parsed since O3.1), the Codex app opt-in, and the `--force-busy` limit. The live
  mode stays warn.
- **Closes.** H1 (enforce readiness).
- **Size.** 7 h (8 rescaled, minus 1 moved to O3.1).
- **Risk.** Low (code only).
- **Tests.** The enforce table row by row; an unknown mode is treated as enforce; the JSON
  shape.
- **Rollback.** The previous release.
- **Blocked by.** O3.2.
- **Needs Matthew's yes:** the install on each Mac.

### O3.4. Remote say (step 7)

- **Scope.** The origin-side gate, the class carried in `CCTRL_ORIGIN_ATTEST`, and the
  receiver's `remote` rule. Grant-set acts are refused remotely.
- **Closes.** H1 (cross-host).
- **Size.** 6 h.
- **Risk.** Low.
- **Tests.** A stubbed ssh (plan 121's E8 harness): claims carried, an old receiver ignores
  them, a forged-claims fixture is logged as `remote`, and a remote grant act is refused.
- **Rollback.** The previous release.
- **Blocked by.** O3.3.
- **Needs Matthew's yes:** the install on each Mac.

### O3.5 and O4.4. Hook rules, docs and skills (step 7)

- **Scope.**
  - The PreToolUse rules above, matching resolved paths.
  - README (the say, doorbell, set-role and recv/ack/gc sections, and the attestation
    table).
  - `--help` text and the `AGENTS.md` peer contract (`--as` must be you; workers never say
    into another session).
  - Skills:
    - `cctrl-fleet-manager`: handover and restore issue grants; who runs `doorbell move`;
      the restore runbook says that after a power cycle every grant is `stale` and Matthew
      runs `--regrant-live` at each Mac's screen (or the Q10 re-anchor applies);
    - `cctrl-repo-orchestrator`: ask the FM for role and doorbell changes;
    - `cctrl-spawn`: only the FM or Matthew starts orchestrators; exit 77.
  - Plan 111's out-of-scope and Risks lines.
- **Closes.** H1, H2, MF-M7 (hook paths).
- **Size.** 5 h + 3 h.
- **Risk.** Medium. A hook change on every session.
- **Tests.**
  - The rules deny the forms (including inside `ssh '…'`) and match **after A2** through the
    repo symlink, a release symlink and the state dir.
  - The hook fails open on bad input and when python3 is missing.
- **Rollback.** `cctrl hooks install` from the previous release; plan 117's C3 backup.
- **Blocked by.** O3.4 and O4.3; plan 117's C3 (settings writer).
- **Needs Matthew's yes:** the install, **and the change to `~/.claude/settings.json` and
  Codex `hooks.json` on each Mac**.

### Enforce flips (decisions, not phases)

- **Order:** `say_gate`, then `caller_checks`, then `attestation`.
- **Each needs:**
  - one week in warn with zero unexplained `would-refuse` in doctor;
  - the skills changes live;
  - every external script that calls `session say` (for example an external launchd job)
    moved to `--operator` or to the mailbox only;
  - for `attestation`, every live orchestrator at `role_grant: ok`.
- **Rollback:** set the key back to `warn` (a hand edit).
- **Needs Matthew's yes:** each flip, separately.

## Size summary

| Phase | h | Source |
|---|---|---|
| O3.1 | 22 | draft 8 → reviewer scale 12, + 6 for MF-M6, + 3 for `proc_pidpath`/tty rule (plan 115 review MUST-FIX 1), + 1 from O3.3 (`--operator`, S4) |
| O3.2 | 9 | draft 6 → reviewer scale |
| O3.3 | 7 | draft 5 → reviewer scale 8, − 1 to O3.1 |
| O3.4 | 6 | draft 4 → reviewer scale |
| O3.5 | 5 | draft 3 → reviewer scale |
| O4.1 | 12 | draft 7 → reviewer scale 10, + 2 for the out-of-band confirmation |
| O4.2 | 13 | draft 9 → reviewer scale |
| O4.3 | 9 | draft 6 → reviewer scale |
| O4.4 | 3 | draft 2 → reviewer scale |
| **Total** | **86** | reviewer 40 + 35, plus 6 (MF-M6), plus 5 (this revision) |

## Execution and acceptance criteria

- **Execution.** Run per phase under the orchestrator, in the order and with the "Blocked by"
  lines above. Never flip this plan to `pending` as a whole: `mstack-run` would then run every
  phase, including the settings changes, in one go. The frontmatter `blocked-by: [115]` is a
  guard (115 stays `split`).
- [ ] The classifier resolves every chain element with `proc_pidpath`; the argv[0]-spoof,
  `pty.fork`, detached-tmux and double-forked `script` tests all give `script`.
- [ ] `--operator` parses and logs `operator-flag` from O3.1 on.
- [ ] Every grant-set act by `operator-tty` runs the confirmation (if Q10 accepts it), and its
  result is in `admin.jsonl`.
- [ ] Every table row × class has a warn and an enforce test (exit 77, nothing written).
- [ ] `say.jsonl` and `admin.jsonl` never hold a body, are 0600 in a 0700 dir, verify, and
  rotate under the A1 lock.
- [ ] The supervised check's results (`open … .command`, osascript, iTerm2 chain) are written
  into SECURITY.md (plan 122's D2), and the iTerm2 row is decided from them.
- [ ] The hook rules match after A2 through every symlink form.
- [ ] No enforce flip happens inside this plan; each is its own yes.

## Interfaces frozen for plan 120 (MF-M7)

These stay byte-compatible through B3-B7 and are added to plan 120's list:
- exit code 77 in B0's `exitcodes.py`;
- the `say_gate`, `caller_checks` and `role_grant` field names and values;
- `--operator` and `--raw`;
- `session say-verify` and its `--json` shape;
- the `say.jsonl` and `admin.jsonl` record shapes and mac domains;
- the `[cctrl say]` line format;
- the class field in `CCTRL_ORIGIN_ATTEST`.

B4 (26 h) moves `lib/caller_class.py` into `cctrl/peer/caller.py` and absorbs grant
verification. Its differential test covers the classifier.

## Out of scope

- Caller checks on `session close/kill/rename/reconcile-names` and `peer register/unregister`
  of other sessions (opt4 Q4, audit L5): a later plan.
- A logged `session key` command (plan 042).
- Out-of-band confirmation for the FM-with-grant path, and for the operator-flag set
  (`say`, worker roles, acked gc). Only the `operator-tty` grant path prompts.
- Pane targeting and paste verification (plan 119), and envelope hardening for mailbox
  messages (plan 119).
