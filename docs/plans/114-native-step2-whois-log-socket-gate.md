---
id: 114
title: Native messaging step 2 - read-only peer whois, a native-send log, and a gate on cctrl's own socket push
status: in-progress
blocked-by: []
priority: 25
allows-migrations: false
review-required: eng
created: 2026-11-02
approval: mdec-1102-cctrl-native-step2 (build, all 8 recommendations accepted by Matthew 2026-11-02; verify by a different subagent, hash to the FM before each push; install on the hosts needs its own approvals record; the `hooks install` settings change in (b) is part of that install record, not this one)
reviews: []
related: 108, 110, 111, 113
---

## Problem

Step 1 (c25bc4f, origin/main) made it doctrine that the built-in `SendMessage`
carries pings and low-stakes notes, and the cctrl mailbox is the record. Three
gaps remain, all from native-messaging-vs-mailbox.md section 4, items 2, 3 and 5:

1. A receiver gets `<cross-session-message from="uds:/tmp/cc-socks/<pid>.sock"
   from-name="..." from-mode="bypass">`. Nothing helps it check that address against
   what cctrl knows about the fleet. `from-name` is a free label (`/rename` changes
   it) and `from-mode` is self-asserted.
2. Native sends leave no fleet-level trail. They show up only in per-session
   transcripts, which are unindexed and get pruned.
3. cctrl writes its own raw frames to Claude Code messaging sockets. Every cctrl
   spawn runs `bypassPermissions`, and a raw frame claims no permission class, so a
   bypass receiver HOLDS the frame behind an approval dialog (5 min, then dropped).
   cctrl meanwhile records the push as delivered.

## What "cctrl's raw socket push" is in the code (found, it exists)

- `_peer_socket_deliver <socket_path> <payload>` (cctrl ~8213). It wraps the payload
  as `{"type":"user","message":{"role":"user","content":<payload>}}` and writes one
  line to the socket with `socat -t2`, or with `node -e net.createConnection` (bounded
  to 2 s) when socat is missing. The Studio has no socat, so node is the live path.
- Its socket comes from `_peer_claude_socket_for <pid>` (~8146). That reads
  `$CLAUDE_SESSIONS_DIR/<pid>.json .messagingSocketPath` for the pid that
  `_peer_claude_push_ready` checked (~8155, sets `PEER_PUSH_PID`).
- It has exactly one caller: `_peer_deliver_one_locked` (~8533), at ~8718-8737
  ("Socket adapter first"). That branch runs only after the 110 push gate
  (`_peer_push_allowed` -> `_peer_doorbell_enabled_for`, ~10501) and the readiness
  check. It runs only when `submit=true`, i.e. the non-inline nudge path, not
  `--no-submit` and not `--inline`. On success it records `status: nudged`, history
  `via: "socket"` (`_peer_record_nudge_json ... true "socket"`). On failure it falls
  through to the tmux paste.
- The payload on that path is always `_peer_nudge_line` (~7988), a cctrl-authored
  line: "[cctrl] N new peer message(s) for X. Read them all: cctrl peer recv ...".
  It carries no sender-controlled text.
- No other writer exists. A grep of cctrl, hooks/, lib/, plugins/, contrib/ and
  skills/ for socat|createConnection|AF_UNIX|messagingSocketPath|cc-socks finds
  nothing else outside tests. `peer say`, `session say` and the doorbell (Stop hook,
  exit 2) never touch the socket.

So after 110, the remaining harm is narrow. A doorbell-enabled, idle, ready Claude
recipient in bypass mode, which today means the pilot, gets a held dialog that the FM
clicks under its exact-body grant (or that expires), and cctrl logs it as delivered.
(c) closes exactly that.

## Design

### (a) `cctrl peer whois` (read-only)

**What it does.** You give it a native sender address. It tells you which live
process owns that socket and which cctrl session, peer name, role and host that
process maps to. It also says whether the claimed name and mode fit the facts. The
result is a consistency check. It is never proof of identity.

**CLI.**

```
cctrl peer whois <address> [--name "<from-name>"] [--mode <from-mode>] [--no-tmux] [--json]
  <address>: uds:/abs/path.sock | /abs/path.sock | pid:<n> | <n>
```

Text output, one short line per item:

```
ADDRESS   uds:/tmp/cc-socks/93036.sock
VERDICT   consistent          (consistency check, not authentication)
PROCESS   pid 93036 live, procStart matches session file, argv mode bypassPermissions
SESSION   TMUX--ms--fleet-claude pane %12 (pane pid 93036)
PEER      TMUX--ms--fleet-claude role fleet-manager kind fleet host studio doorbell off
NAME      claimed matches session file name; tmux id in name matches pane session
MODE      claimed bypass, argv bypassPermissions: consistent
NOTES     -
```

JSON (`--json`), stable keys:

```json
{"ok":true,"address":"uds:/tmp/cc-socks/93036.sock","verdict":"consistent",
 "authenticated":false,"reasons":[],
 "socket":{"path":"...","exists":true,"is_socket":true,"symlink":false,"owner_is_me":true,"dir_private":true},
 "process":{"pid":93036,"alive":true,"proc_start_match":true,"argv_mode":"bypassPermissions"},
 "claude_session":{"file":"93036.json","session_id":"<uuid>","name":"...","name_source":"user",
                   "entrypoint":"cli","kind":"interactive","tmux_claim":"S:@w.%p","bridge_connected":true},
 "tmux":{"checked":true,"session":"TMUX--ms--fleet-claude","pane":"%12","pane_pid":93036,"bound":true},
 "peer":{"name":"...","aliases":[],"role":"fleet-manager","kind":"fleet","host":"studio","doorbell_enabled":false},
 "claims":{"name":{"given":"...","matches":true},"mode":{"given":"bypass","consistent":true}}}
```

Verdicts: `consistent` (every check that ran passed), `inconsistent` (`reasons[]`
names each mismatch), `dead` (pid gone, or procStart differs, i.e. pid reuse),
`unknown` (no session file names this socket, or more than one does), `not-local`
(an address that is not a local uds path or pid, e.g. a Remote Control/cloud
sender). Exit codes: 0 `consistent`; 3 every other verdict; 64 usage. A Remote
Control sender reports `not-local` plus the hint "check via the mailbox; native
cannot be verified cross-host".

**Checks, in order (all read-only).**

1. Parse and normalise the address. The path must be absolute with no `..`. With a
   pid form, the socket comes from the session file.
2. `lstat` (no follow) of the socket path. It must exist, be a socket and not be a
   symlink. Owner uid must equal the caller's uid. The parent dir must be owned by
   the caller with no group/other write. The socket is never opened.
3. Scan `$CLAUDE_SESSIONS_DIR/*.json` (`*.json` only; never open `*.key`) for
   `.messagingSocketPath == path`. Exactly one hit is required, with `.pid` equal to
   the pid in the socket filename. Zero or several hits give `unknown`.
4. Run `ps -o lstart= -p <pid>` and compare with `.procStart` (a pid-reuse guard).
   Then `ps -o command= -p <pid>` gives the argv permission mode:
   `--permission-mode X` / `--permission-mode=X`; `--dangerously-skip-permissions`
   counts as bypass; anything else is `unknown`, because settings `defaultMode` and
   shift-tab changes are invisible.
5. Pane binding (skipped with `--no-tmux`). Parse the self-reported `.tmux` field
   (`S:@w.%p`). Run one read-only `_tmux_run_with_timeout list-panes -a -F
   '#{session_name}\t#{pane_id}\t#{pane_pid}'`. Require pane `%p` in session `S`,
   with `pane_pid == pid` or pid a descendant of `pane_pid` (an upward `ps -o ppid=`
   walk, at most 8 levels).
6. Registry. Read `peers.json` entries whose `tmux_target`/`session` is `S`, plus
   `$SESSION_METADATA_DIR/S.json` (role/kind/purpose/host), plus
   `_peer_doorbell_enabled_for` (pure jq). Reads take no mailbox lock.
7. Claims. `--name` must equal `.name` exactly. It must also contain `(S)`, the
   cctrl `--name "<purpose> (<tmux id>)"` convention (cctrl ~1382-1393). `--mode
   bypass` is compared with the argv mode; `unknown` argv gives
   `consistent: null`, not a pass.

**Code.** New `_peer_cmd_whois` next to `_peer_cmd_whoami` (cctrl ~6615). Add
`whois)` to `cmd_peer` (~10901) and its help block. Add a zsh completion entry in
`completions/_cctrl` (the peer `whoami` entry is at ~400/474). Factor the
pid -> session-file -> pane -> peer resolution into
`_peer_record_for_pid <pid> [--no-tmux]`, a pure read with globals out, so plan 111
Design 3 ("verify against cctrl's own records") reuses it rather than duplicating
it. The `tmux` field and procStart come from the session file. Use no
`_session_claude_pid` scan.

**Must NOT.** It must not connect to, write to or `stat`-follow any messaging
socket, and must not use socat, node net, nc -U or python socket. It must not run
any tmux command other than the one `list-panes` (no send-keys, paste-buffer,
display-message with `-t` on a guessed target). It must not write any file: no
registry backfill, no mailbox lock, no temp files. It must not signal (`ps`, never
`kill -0`), read `*.key` files, or print `bridgeSessionId` (it reports a boolean
only). It must never say "verified" or "authenticated" (`authenticated` is always
false).

**Failure.** Any unreadable input (sessions dir, ps, tmux, jq) gives `unknown` or
`inconsistent` with a reason, never `consistent` (fail closed). Without tmux the
check runs as if `--no-tmux` had been given, and `reasons` gets "pane binding not
checked".

### (b) Native-send log (sender side)

**What it does.** Every built-in `SendMessage` call by any Claude session on the host
appends one line to a host-local, private log: who sent, to whom, when, the outcome
and a keyed hash of the body. The body is never stored. It never blocks a send.

**Hook.** A new `cctrl hooks run native-send-log`, registered by `_hooks_install`
(cctrl ~18079) as two new entries: `PreToolUse` with `matcher: "SendMessage"`
(intent, always fires) and `PostToolUse` with `matcher: "SendMessage"` (outcome). It
is a separate entry, not a change to the existing `matcher: "Bash"` entry, so the
107 tmux guard path and its fast pre-check are untouched. The script is
`hooks/native-send-log.py` (python3, stdlib only). `_hooks_run` (~18019) gets
`native-send-log) exec python3 "$SCRIPT_DIR/hooks/native-send-log.py"`, the hook
script list in doctor (~18286) gets the file, and the portable check (~18337) gets
`native-send-log`.

**Line format** (JSONL, one per phase, joined by `tool_use_id`):

```json
{"v":1,"ts":"2026-11-02T18:00:00Z","phase":"pre","tool_use_id":"toolu_...",
 "host":"<host-id>","sender":{"pid":93036,"session_id":"<uuid>","tmux":"S:@w.%p","socket":"/tmp/cc-socks/93036.sock"},
 "to":"worker [3fa9c1]","to_kind":"session|teammate|main|agent-id",
 "notify_when_idle":false,"body":{"chars":57,"lines":1,"hmac":"<hex>"},
 "msg_ids":["msg_20261102_180000_ab12cd"],"kind":"bell|note|subscription"}
{"v":1,"ts":"...","phase":"post","tool_use_id":"toolu_...","outcome":"sent|held|refused|offline|error|unknown"}
```

- Sender: the hook payload's `session_id`, plus an upward `ps -o ppid=` walk from the
  hook process (at most 8 levels, 1 s budget) to the first pid with
  `$CLAUDE_SESSIONS_DIR/<pid>.json`. The `tmux` and `messagingSocketPath` fields
  come from that file. No tmux call.
- `to` is logged verbatim. It is a name of at most 300 chars and one line (tool
  schema). `to_kind` is a heuristic: `main`; `a…-…` = agent id; else session or
  teammate.
- `msg_ids` are regex matches of the cctrl id shape. They link a bell to the mailbox
  record. `kind: bell` when the body is only a "you have mail" line plus ids;
  `subscription` when `message` is empty and `notify_when_idle` is set.
- `outcome` is classified from `tool_response` by keyword. The raw response is not
  stored. A held or refused send therefore shows up even though no receiver report
  exists.

**Body decision: never store the body, the first line or `summary`.** The doctrine
lets native carry low-stakes notes, and nothing stops an agent pasting a token,
path or customer text into one, so no line of the body is safe to keep. `summary`
is "not transmitted" but is free text from the same model, so it gets the same
rule. What is kept is enough for audit: who, to whom, when, outcome, size, mailbox
ids, and an HMAC-SHA256 of the exact body under a per-host key. An auditor holding
the receiver's transcript can prove "this is the message" by recomputing the HMAC,
but a short secret cannot be brute-forced from a plain sha256. The key lives at
`$PEER_DATA_DIR/native-sends.key` (0600, 32 random bytes, created on first use).

**Files.**
- Log: `$PEER_DATA_DIR/native-sends.<host-id>.jsonl` (PEER_DATA_DIR =
  `${CCTRL_DATA_DIR:-$SCRIPT_DIR/data}`; installed releases symlink data/ to the
  repo's data/). It is per host because `~/dev/cctrl/data` is livesync'd between the
  Studio and the MacBook, and two hosts appending one file would conflict. The host
  id comes from `$CCTRL_HOST_ID_FILE`. data/ is gitignored.
- Mode 0600 (umask 077 at create). Writes are `O_APPEND`, single `write()` of at
  most 2 KB per line, plus `fcntl.flock` on the file.
- Rotation: past `CCTRL_NATIVE_LOG_MAX_BYTES` (default 10 MB) rename to `.1` (one
  generation) under the same flock.
- Reader (small, read-only): `cctrl peer native-log [--since ISO] [--to NAME]
  [--limit N] [--json]` prints the last N joined pre/post pairs. Optional; see open
  question 5.

**Failure: fail open, always.** Malformed stdin, a non-SendMessage `tool_name`, an
unwritable dir, a missing key or any exception exits 0 with no stdout or stderr.
Hook stdout/stderr can reach the model, and a logging hook must never inject text
or block a send. A total wall-clock budget of 1 s is enforced inside the script.
The checked-install launcher's existing fail-open for `hooks run` covers a broken
release (tests at run-tests.sh ~2937-3044).

**Must NOT.** It must not store body, first line, summary or raw tool_response; not
block or alter the call (no `decision`, no exit 2, no output); not call tmux, the
network or any socket; not read `*.key` session files; not run `env`/`printenv`.
Receiving sessions are not logged, since their transcripts already hold the record.

### (c) Gate on cctrl's raw socket push

**What it does.** cctrl stops writing raw frames into the socket of a session that
is, or may be, in bypass mode. That covers every cctrl spawn and every session whose
mode cctrl cannot prove. Those sessions get the existing readiness-gated tmux paste
of the same cctrl-authored nudge line instead. The socket path stays only for a
recipient whose argv proves a prompting mode (default, acceptEdits, auto, plan,
dontAsk), where a classless frame is not held [U: to confirm in the spike]. A socket
handoff is also no longer reported as more than it is.

**Code.**
- New `_peer_socket_push_allowed <pid>` next to `_peer_claude_socket_for` (~8146). It
  reads `ps -o command= -p <pid>` once and returns 0 only when the argv holds an
  explicit `--permission-mode` (or `=`) with a non-bypass value and no
  `--dangerously-skip-permissions`. It returns 1 for bypass, a missing flag (settings
  `defaultMode` may be bypass), ps failure or an unparseable argv, and sets
  `PEER_SOCKET_SKIP_REASON` (`recipient-bypass`, `recipient-mode-unknown`).
  The parse is the shared pure helper `_peer_argv_permission_mode` (whois uses
  it too). Because `ps` joins argv with spaces, a prompt can carry flag-like
  text, so two different `--permission-mode` values give `unknown`, and
  `--allow-dangerously-skip-permissions` (bypass one shift-tab away) gives
  `unknown` unless the mode is already bypass.
- In `_peer_deliver_one_locked` (~8718) the condition becomes `[[ "$submit" ==
  "true" ]] && _peer_socket_push_allowed "$PEER_PUSH_PID" && _sock_path="$(...)"`.
  When it is skipped, control falls through to the existing tmux paste. That paste is
  already behind `_peer_push_allowed` (doorbell) and `_peer_claude_push_ready`
  (idle, no modal, no draft, fail closed), so no new push target is opened.
- Result JSON gains `socket_skipped_reason` when set. History keeps
  `adapter: "tmux"` for those pushes (the nudge history field is `adapter`,
  not `via`), so the record says how the bell actually went in.
- The gate sits after `_peer_claude_push_ready`, not in `_peer_push_allowed`. That
  function is reserved for plan 111's sender checks ("needs no other call site"), so
  111 and this plan touch different lines.
- No new doorbell.json key, so nothing collides with feat/doorbell-ring-cap, which
  rewrites `_peer_doorbell_enable/status/doctor` and the doorbell.json schema.

**Failure.** Fail closed for the socket: any doubt means no socket. Once the socket
is skipped, the pane path makes its own fail-closed decision (deferred, rc 0, Stop
bell rings).

**Must NOT.** It must never add a `from-mode`, permission-class, auth-token or any
other claim to cctrl's frame to slip past the hold. That would forge the class Claude
Code uses as its gate, and the test asserts the frame shape is unchanged. It must not
widen pushes to non-doorbell recipients, add an override flag or env switch, or touch
`crossSessionInbound`.

## Interaction with plan 111 and feat/doorbell-ring-cap

- 111 Design 3 needs "resolve the sending session from cctrl's own records". (a)'s
  `_peer_record_for_pid` is that resolver. Land it here as a pure read and have 111
  call it. whois stays "not proof", and 111 decides whether a 0600 token or
  LOCAL_PEERPID broker is added on top.
- 111 Design 4 says Claude Code's hold is the last line of defence and the FM's
  exact-body grant relies on it. (c) removes the hold from cctrl's own nudge to
  bypass recipients by switching them to tmux paste. The nudge is fixed cctrl text
  with no sender content, it goes only to doorbell-enabled recipients, and the mail it
  points at is still gated by 111 at read/deliver time. 111's text must be updated in
  the same PR to say the hold now guards only native and foreign writers, not cctrl
  nudges. Matthew decides this (open question 1).
- (b) gives 111 a sender-side record of native traffic, but 111 still governs only
  the mailbox. Nothing in (b) is an attestation input.
- feat/doorbell-ring-cap (62dc31c..16232db, now merged: this branch starts from origin/main 16232db) changes cctrl
  ~10117-10969 (doorbell eval/enable/status/move, peer doctor), its tests (~9995-10600
  plus new `test_doorbell_ring_cap*`, `test_doorbell_move*`), README, CHANGELOG and
  both skills. This plan touches ~6615 (new fn), ~8146-8737 (deliver), ~10901
  (`cmd_peer`), ~18019-18400 (hooks), hooks/, completions/. Order: merge ring-cap
  first, branch 114 from that main, append new tests after the ring-cap tests, and
  leave doorbell.json and the doorbell functions alone. The ring cap applies to Stop
  rings only. (c) does not change push frequency (same deliver calls, different
  transport), so no cap interaction.
- Plan 112 (peer CLI polish, `--as` consistency): whois takes no `--as`, so no
  overlap.

## Acceptance criteria

- `peer whois` returns `consistent`/exit 0 only when socket, session file, procStart,
  pane binding (unless `--no-tmux`) and any given claims all agree. Every other case
  exits 3 with reasons. JSON always has `authenticated: false`.
- whois opens no socket, writes no file and runs no tmux command other than one
  `list-panes` (zero with `--no-tmux`).
- A SendMessage call writes one `pre` and one `post` line with the fields above. The
  log never contains any substring of the body or summary. The file is 0600. Every
  failure exits 0 silently.
- `hooks install` adds both SendMessage entries idempotently and preserves foreign
  entries. `hooks doctor` reports them.
- A doorbell-enabled ready recipient with bypass or unknown argv mode gets zero socket
  frames and one tmux paste (`via: tmux`, `socket_skipped_reason`). One with an
  explicit prompting mode gets one socket frame, byte-identical in shape to today.
- AGENTS.md peer section stays within its 30-line cap (`test_peer_contract_docs`).
  It is at 30 lines, so it gets no new line unless one is removed; preferred is no
  change, with `peer whois` documented in README and the peer help.

## Tests (tests/run-tests.sh; hermetic)

Shared rules: scratch `HOME`, `CCTRL_DATA_DIR`, `CCTRL_CLAUDE_SESSIONS_DIR`,
`CCTRL_CLAUDE_SETTINGS`/`CLAUDE_CONFIG_DIR`, `CCTRL_SESSION_METADATA_DIR`. No live
tmux: any tmux runs on a private `-S` socket via `_private_tmux_install`, with
`TMUX`/`TMUX_PANE` unset. No live sockets: only AF_UNIX sockets bound by a test
python in `mktemp -d`. Never `~/.claude` or `/tmp/cc-socks`.
`test_tmux_sockets_left_behind` and `test_no_unsafe_tmux_isolation` must stay green.

(a) whois
- `test_peer_whois_usage`: no arg, bad form, `..` path give 64; `bridge:x` gives
  `not-local`, 3.
- `test_peer_whois_consistent_no_tmux`: a real `sleep 600` child, the session file
  keyed by its pid with procStart from real `ps -o lstart=`, a socket bound by a
  python listener that counts accepts, and `--no-tmux`. Expect exit 0, and the
  listener saw zero connections.
- `test_peer_whois_dead_and_reused`: a killed pid gives `dead`; a procStart off by one
  second gives `dead`.
- `test_peer_whois_unknown_ambiguous`: no matching file gives `unknown`; two files
  naming the socket give `unknown` with reason `ambiguous`.
- `test_peer_whois_socket_shape`: a symlink to the socket, a regular file and a dir
  with mode 0777 each give `inconsistent` with a reason.
- `test_peer_whois_claims`: a child started as `bash -c 'exec -a "claude
  --permission-mode default" sleep 600'` (real ps argv). `--mode bypass` gives
  inconsistent; `--name` mismatch gives inconsistent; an argv without a flag gives
  `consistent: null`.
- `test_peer_whois_pane_binding_real_tmux`: a private `-S` server whose pane runs the
  sleep, with the session file's `tmux` field right (consistent), naming the wrong
  pane (inconsistent), or naming a non-descendant pid (inconsistent). A tmux shim
  count shows exactly one `list-panes` call, and zero with `--no-tmux`.
- `test_peer_whois_static_readonly` (lint, like `test_no_unreferenced_functions`):
  the bodies of `_peer_cmd_whois` and `_peer_record_for_pid` contain none of
  socat|createConnection|nc -U|socket.socket|send-keys|paste-buffer|kill
  |mktemp|>>|_mailbox_lock|\.key.

(b) native-send log
- `test_native_send_log_lines`: pre and post fixtures piped to `cctrl hooks run
  native-send-log` give two lines with the right fields, the msg_ids extracted and
  `kind: bell`.
- `test_native_send_log_never_stores_body`: canaries in `message`, `summary` and
  `tool_response`. A grep of the log and the `.1` rotation shows none of them. The
  HMAC matches a recomputation with the key; the key and log are 0600.
- `test_native_send_log_fail_open`: malformed JSON, a Bash `tool_name`, a read-only
  data dir and a missing python module each exit 0 with empty stdout/stderr, and
  nothing is written for the Bash case.
- `test_native_send_log_rotation_and_lock`: a small `CCTRL_NATIVE_LOG_MAX_BYTES`
  gives exactly one `.1`; 20 parallel writers give 20 whole lines.
- `test_native_send_log_sender_walk`: a fixture session file for an ancestor pid
  (the test shell's own pid) fills `sender`. With none it becomes `sender.pid: null`,
  still exit 0.
- `test_hooks_install_adds_sendmessage_entries`: fixture settings with foreign hooks.
  Install twice and get one entry each, with foreign entries kept. Doctor shows OK,
  and MISSING after deleting one.
- Reuse the launcher fail-open tests for the new hook name.

(c) socket gate
- Extend `test_peer_push_gate_real_tmux_socket_mcp` (~14758) and the stubbed T2
  tests. With the recipient pid's argv set to bypass (`--permission-mode
  bypassPermissions` via `exec -a`), expect zero listener frames, one tmux paste,
  history `via: tmux` and `socket_skipped_reason: recipient-bypass`. With no flag,
  expect the same with `recipient-mode-unknown`. With `--permission-mode default`,
  expect one frame, whose JSON keys are exactly `type`, `message.role` and
  `message.content` (no mode/auth claim), and no paste.
- `test_peer_socket_gate_ps_failure`: a ps shim exits 1 and gives no socket.
- `test_peer_socket_deliver_payload_exact` and `_node_bounded` stay unchanged and
  green.

## Size (agent-hours, Claude subagents; verify by a different subagent)

| item | build | tests | docs | total |
|---|---|---|---|---|
| (a) whois + shared resolver + completion | 3.0 | 2.0 | 0.25 | 5.25 |
| (b) hook script, install/doctor, optional reader | 3.5 | 2.0 | 0.5 | 6.0 |
| (c) socket gate + 111 text update | 1.0 | 1.5 | 0.5 | 3.0 |
| independent verify + full suite (bash 3.2 and 5 legs) | | | | 2.5 |
| **total** | | | | **~17 agent-hours (~2 agent-days)** |

Split per the two-worker rule: worker 1 does (a)+(c), worker 2 does (b), and a
different subagent verifies each. Ship as three commits on one branch, in the order
(c), (a), (b). (c) is the only behaviour change to an existing path.

## Rollout

- R1. Merge ring-cap first, then branch. Done: feat/native-step2 branches from origin/main 16232db.
- R2. Hash to the FM before each push (grant limit).
- R3. Install on each host needs its own approvals record. For (b) that record must
  name the `cctrl hooks install` change to `~/.claude/settings.json` (two new hook
  entries) on the Studio and the MacBook.
- R4. After install: one FM-approved harmless self-test. The pilot gets a cctrl send
  while idle; check its pane shows the tmux nudge, not a held dialog, and the history
  says `via: tmux`.
- R5. Rollback: the existing release rollback. (b)'s entries are removed by
  reinstalling the previous release's `hooks install`. They fail open even if left
  behind.

## Out of scope

Receiver-side native logging; sending native messages from cctrl (cctrl cannot call
SendMessage); `peer send --json` adding the recipient's native address (report item
4, a later plan); `crossSessionInbound`/`isolatePeerMachines` changes; the spike in
the report's open items (it needs its own click); plan 113 wake work.

## Tasks

1. `_peer_socket_push_allowed` + deliver gate + result field + 111 wording.
2. `_peer_record_for_pid`, `_peer_cmd_whois`, dispatcher/help/completion.
3. `hooks/native-send-log.py`, `_hooks_run`/`_hooks_install`/doctor entries, optional
   `peer native-log`.
4. Tests as above. 5. README/CHANGELOG/AGENTS.md (one line, 30-line cap).

## Decisions (Matthew, 2026-11-02, mdec-1102-cctrl-native-step2)

All eight recommendations accepted:

1. cctrl's own new-mail notice goes to bypass sessions by tmux paste, through the
   existing idle/dialog/draft readiness checks, doorbell-enabled sessions only. The
   socket path stays only for non-bypass sessions. Unknown mode is treated as bypass
   (fail closed to the checked paste path). cctrl's frame never claims a permission
   mode.
2. `cctrl peer whois` is read-only. It may run one read-only `tmux list-panes`;
   `--no-tmux` skips it. It never opens or writes a socket.
3. The native-send log stores no body, first line or summary: a keyed hash, the
   size and cctrl message ids only.
4. One log file per host (`data/` is livesynced): `native-sends.<host-id>.jsonl`,
   mode 0600.
5. A read-only reader, `cctrl peer native-log`, ships now.
6. Subagent and teammate sends are logged too, tagged `to_kind`, no bodies. The
   hook is fail-open.
7. No whois MCP tool.
8. The delivery spike is NOT run in this plan. Its procedure is written below
   (Spike procedure) for a later, separately approved run.

## Spike procedure (not run; needs its own approval)

Question: does a classless frame (cctrl's `{"type":"user","message":{...}}`) reach
a session started with an explicit prompting mode without an approval hold? (c)
keeps the socket path only for such sessions, so this decides whether that path
is useful or should be dropped too. (c) is safe either way: a held frame only
means a notice that expires while the mail stays queued.

1. With Matthew's click, start one scratch receiver in a throwaway dir and a
   scratch tmux session: `claude --permission-mode default`. No sender session is
   needed (cctrl writes the frame). Enable the doorbell for that scratch peer only;
   touch no other peer.
2. Leave the receiver idle at its composer. Run `cctrl peer send <scratch> --from
   <scratch-sender> --deliver -- "spike"`.
3. Read the result JSON: `status: nudged`, `target` = the receiver's
   `messagingSocketPath`, no `socket_skipped_reason`.
4. Watch the receiver pane for 30 s. Pass: the nudge line appears as a user turn
   with no approval dialog. Fail: an approval dialog appears (do not click it; let
   it expire) or nothing appears.
5. Repeat once with `--permission-mode acceptEdits`. Then disable the scratch
   doorbell, close the scratch session and record the outcome in this plan.
6. On fail: a follow-up plan makes `_peer_socket_push_allowed` always return 1
   (tmux paste for every recipient); nothing else changes.

## Open questions (as put to Matthew; answered above)

1. **Should cctrl's nudge to a bypass session go in by tmux paste instead of the held
   socket dialog?** This removes the FM's click on cctrl's own "N new messages" notice
   to the pilot. The notice is fixed cctrl text and goes only to doorbell-enabled
   sessions. Recommend: yes. The alternative is to defer and wait for the Stop bell,
   which loses idle wake for the pilot.
2. **May whois run one read-only `tmux list-panes` by default to tie the socket to a
   pane?** Recommend: yes, with `--no-tmux` to skip it. Without it, the tmux id is
   only what the session file claims.
3. **Should the log keep the body?** Recommend: no body, no first line, no summary;
   keep only a keyed hash, the size and any cctrl message ids. A secret pasted into a
   "low-stakes" note would otherwise sit in a synced file.
4. **Should the log be per host?** `data/` is livesynced between the Studio and the
   MacBook. Recommend: one file per host (`native-sends.<host-id>.jsonl`), so the two
   machines never write the same file.
5. **Do we want a reader command (`cctrl peer native-log`) now, or is `jq` on the
   file enough?** Recommend: add the small read-only reader now (about 1 h). The FM
   will use it in ticks.
6. **Do we log subagent and teammate SendMessage traffic too, or only cross-session
   sends?** The hook cannot always tell them apart. Recommend: log all with a
   `to_kind` tag. The volume is small and the lines carry no body.
7. **Should whois also be an MCP tool for agents?** Recommend: not in this plan. Add
   it after 111, so agents do not treat it as proof.
8. **Run the report's harmless spike (does a classless frame reach a prompting-mode
   session without a hold?) before (c) keeps the socket path for those sessions?**
   Recommend: yes, one scratch pair, with its own click. Until then (c) is safe either
   way, because a wrongly held frame only means a notice that expires while the mail
   stays queued.
