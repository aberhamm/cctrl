# TODOS

## `_active_session_count` needs a cheap path — it runs the full row loop to get a number

**What:** Give `_active_session_count` (cctrl:1401) a lightweight implementation that
counts managed tmux sessions without running `_session_list`'s full per-row enumeration.

**Why:** It is on the launch hot path — `_launch_resource_guardrail` calls it on every
`cctrl start` (cctrl:1440), and `_res_health_line` calls it for every `cctrl fleet`
(cctrl:1412, 7950). To produce a single integer it currently runs `_session_list --json`,
whose row loop spawns ~18 subprocesses per session: six `_session_metadata_field` jq
calls, several tmux round-trips, `_session_id`, `_session_transcript_path`,
`_session_last_active_ms`, and `_session_rich_state` (which itself costs a tmux display,
a capture-pane, and a bounded transcript tail read). Measured on ms-128g-bln 2026-08-05:
1.06s for 10 sessions (~106ms/session, three runs 1.07/1.05/1.06). At the 20-30 sessions
this fleet routinely holds that is 2-3.2s of work on every single launch, purely to
compute a count that needs two fields.

Plan 053 makes it hotter still: restore calls it before every wave, so a 20-session
restore in waves of 2 pays it ten times.

**Pros:** Takes the guardrail from seconds to milliseconds on every launch; removes the
pane-capture and transcript-read side cost from a path that only wants a number.
**Cons:** A second enumeration path to keep consistent with `_session_list`'s `managed`
determination — which is a three-way OR at cctrl:6058, not a single field, so the cheap
path must replicate that logic or it will disagree with the ✦ column.

**Context:** Surfaced by the eng review of plans 051-053 (2026-08-05, Performance section).
Plan 051 does two things that reduce but do not remove the cost: it collapses the six
`_session_metadata_field` calls into one jq read, and it corrects the function to
`select(.managed)`. Neither avoids the rich-state and transcript work, which is the
expensive part. Start from `_session_list`'s name enumeration (cctrl:6021-6022) and the
managed determination at cctrl:6058-6065; everything between is skippable for a count.

**Depends on / blocked by:** plan 051 (which fixes the filter and the jq collapse — do
this after, so the cheap path is written against the corrected semantics).

## 053 full automation — picker Enter + readiness-released waves (deferred, gated)

**What:** Revive the automation cut from plan 053 in its 2026-08-05 re-scope: the
conditional resume-picker Enter (`_restore_wait_picker`) and readiness-inferred
wave release (`_restore_wait_ready`), as a NEW plan with a fresh eng review.

**Why:** The cleared spec carried two P1 defects in exactly this layer (audit
findings F1/F2: the picker matches none of `_session_pane_has_dialog`'s
signatures, so the specified corroboration could never fire; codex sessions can
never satisfy the readiness allow-list). The value it automates — pressing Enter
a handful of times a year with the operator already present — did not justify
shipping mis-specified keystroke injection into `bypassPermissions` sessions.

**Pros:** Fully unattended restore, if the premises are fixed first.
**Cons:** Pane-scraping against an unversioned TUI; the event is too rare for
live-fire iteration; highest-blast-radius code in the backlog.

**Context:** Gates are listed in plan 053's Design ("Deferred: full automation"):
(1) a real power event showing the human-in-the-loop flow is the bottleneck;
(2) unified modal detectors + deliberate picker signature + dated capture-pane
fixture (see the detector-unification and fixture-provenance entries below);
(3) codex readiness defined, draft-detector picker overlap excluded;
(4) plan 038 landed. Start from `docs/reviews/2026-08-05-fable-architecture-audit.md`
findings F1-F3 and the removed sections in 053's git history.

**Depends on / blocked by:** all four gates above; plans 051-053 shipped.

## Split the cctrl source; keep the single-file artifact via concatenation

**What:** Move the script's source into `src/*.sh` along its existing seams
(prelude / profiles+costs / launch / peer+mailbox / session / hosts+fleet /
shortcuts+dispatch — the seam table with line ranges is in the 2026-08-05 audit,
finding A1) and produce the shipped `cctrl` by dumb concatenation. The generated
file can stay checked in so the scp/livesync distribution story is unchanged.

**Why:** The repo already documents the single source file fighting the work:
plan 035 had to ban line-number citations after a 13-line commit moved
`_dispatch` by 7 lines; plans 023/027/029/034 are explicitly serialized to avoid
textual conflicts inside single functions; plan 036 added a hidden re-entrant
subcommand rather than "fork the single-file distribution". The unit of editing,
review, and merge becomes the subsystem while the artifact stays one file.

**Pros:** Kills the drift/merge-serialization tax; migration invariant is
checkable ("concatenated output byte-identical to today's file") and the E2E
suite black-boxes the binary, so every subsequent move is gated by the full
suite. ~An afternoon for the mechanical split if the concatenation stays dumb.
**Cons:** A build step where there was none; anything that assumes `cctrl` is
hand-edited (livesync flow, install docs) must be audited first; bash gains no
runtime isolation from this — the win is review/merge/navigation only.

**Context:** Audit finding A1. If only one extraction ever happens, take
peer+mailbox (~40% of the file, one concept, where the plan collisions cluster).

**Depends on / blocked by:** nothing hard; best sequenced at a quiet moment in
the backlog, not mid-feature-wave.

## Unify the session row loop — one `_session_row_json` for all enumerators

**What:** Extract the per-session derivation (tmux queries, `_session_agent_cmd`,
metadata reads, state) into one `_session_row_json <name>` consumed by
`_session_list`, `_session_doctor`, `_session_prune`, `_session_autoheal`, and
the needs-me path, instead of the four-plus hand-rolled variants of the same
loop that exist today.

**Why:** The row loop is the file's single biggest duplication cost: plan 051's
six-jq-calls-into-one collapse fixes ONE copy of a pattern that exists in at
least four. Every copy drifts (doctor's pre-pass and prune each re-derive agent
and metadata their own way), and every performance fix has to be applied N
times.

**Pros:** One place for the enumeration cost and the `managed` three-way OR;
makes the `_active_session_count` cheap-path entry above easier (it becomes "a
row subset", not "a fifth loop").
**Cons:** The consumers want different field subsets, so the shared row needs a
cheap/full split or it re-imports the full cost everywhere; touching four
verbs at once needs the suite green before and after.

**Context:** Audit finding A4. Sequence AFTER plan 051 lands (051 already edits
the `_session_list` loop; doing both at once muddies its review).

**Depends on / blocked by:** plan 051; pairs naturally with the
`_active_session_count` entry above.

## Unify the two Claude-modal detectors

**What:** `_peer_pane_ready_for_delivery`'s claude arm anchors on `'❯ 1\.'`
(any highlighted numbered option) while `_session_pane_has_dialog` requires
`'Do you want to (proceed|create|make)|Do you trust the files|❯ 1\. Yes'`.
Same question — "is a Claude modal up" — two regexes, different answers for the
same pane. Extract one shared signature source; callers may keep different
sensitivities, but the signatures live in one place.

**Why:** The divergence is what made plan 053's picker premise wrong: the resume
picker IS a modal to peer delivery and NOT a modal to rich-state, and the plan
reasoned from the wrong one. Any future signature fix (new Claude Code prompt
text) currently has to be discovered and applied twice.

**Pros:** One signature list to keep current; closes the class of bug behind
audit finding F1; prerequisite for the deferred 053 automation.
**Cons:** Changing `_session_pane_has_dialog`'s sensitivity changes
`blocked-dialog` semantics for `session ls` / needs-me / autoheal — needs its
own small review, not a drive-by.

**Context:** Audit findings F1/A4. CHECK FIRST whether one of the pending
039-050 audit-backlog plans (the modal-inversion item) already owns this — if
so, fold this in there rather than opening a new plan.

**Depends on / blocked by:** none; wants the fixture-provenance entry below so
the unified signatures are pinned to captured reality.

## Fixture provenance for pane detectors — captured, dated, not hand-typed

**What:** A rule plus a mechanical pass: every pane fixture under
`tests/fixtures/` that a detector regex is tested against must be a dated,
unedited `tmux capture-pane -p` dump from a real session (filename carries the
date and the agent CLI version), and detector-dependent plans must attach such
a capture for any screen state their logic keys on. Re-capture on agent CLI
upgrades. Replace the existing hand-typed pane fixtures as they are touched.

**Why:** The suite can prove a detector matches its fixture; it cannot prove
the fixture matches Claude Code's actual TUI. Every shipped detector bug in the
CHANGELOG is exactly this gap: the draft detector anchored on ASCII `>` while
the real screen renders `❯`; the codex modal matcher looked for "Allow command"
which no real codex modal says; and plan 053's cleared spec keyed on a
`blocked-dialog` state the real picker can never produce. The real picker
string sat in the homelab restore manifest the whole time — capture-as-fixture
makes that check mechanical instead of forensic.

**Pros:** Cheapest fix in the audit (one command per screen state); converts
"modeled on real output" into "is real output"; enables a doctor check for
detectors matching zero live panes for N days (silent-decay alarm).
**Cons:** Captures go stale and need the re-capture discipline; some states are
awkward to reproduce on demand (that friction is information — it is the same
friction the detector will face in production).

**Context:** Audit finding A6; the suite's own comments already say "MODELED ON
real capture-pane output", which is the right instinct stopping one step short.

**Depends on / blocked by:** nothing. The mstack-side twin (requiring captures
at PLAN time for TUI-dependent plans) is proposed separately in the mstack repo.

## Test harness DX — single-test filter and fail-to-end reporting

**What:** Let `tests/run-tests.sh` take test-function names as arguments
(`bash tests/run-tests.sh test_peer_reply_core …`) instead of always running
all 119; and make `fail()` record-and-continue (or at least print which tests
never ran) instead of exiting the whole suite on first failure.

**Why:** The runner is a bare list of 119 sequential calls with fail-fast
`exit 1`: a mid-suite failure hides everything after it, and iterating on one
test means re-running the world. The suite gates every plan, so this friction
taxes every single change; plans 051-053 add ~28 more tests on top.

**Pros:** ~5-line change for the filter; large payoff per plan iteration; a
full-failure report instead of first-failure-only.
**Cons:** Record-and-continue must not let a red suite look green — the exit
code must still be non-zero if anything failed; some tests share fixture state
by position and need checking before reordering/filtering is safe.

**Context:** Audit finding A6. While in there: time the full suite and put the
number in the README (runtime is currently unmeasured and growing).

**Depends on / blocked by:** nothing.

## peer register-self — identity bootstrap for already-running sessions

**What:** A `cctrl peer register-self` command that infers the current tmux session
(via `$TMUX`/`tmux display-message`) and registers it as a peer in one step, so an
agent that is already running can claim an identity and start using the mailbox and
MCP bridge without a human running `peer register` on its behalf.

**Why:** Plan 008's `cctrl start --peer NAME` only covers sessions launched with
identity; the original motivating scenario (two *already-running* sessions wanting
to collaborate) has a cold-start gap. Surfaced by the Codex outside-voice review of
plans 002–008 (2026-06-11, coverage gap G2).

**Pros:** Closes the cold-start gap for the feature's core use case; small surface
(reuses plan 002 registration + session-name detection).
**Cons:** Identity inference from inside a session needs care (nested tmux, remote
hosts); cooperative trust model means self-registration is unauthenticated by design.

**Context:** Peer registry ships in plan 002 (`data/peers.json`, manual-wins
shadowing, reserved name `user`); ambient identity via `CCTRL_PEER` ships in plan
008. Start from `_session_metadata_file()` and the plan 002 resolver. The command
should set `CCTRL_PEER` guidance in its output since the env var can't be exported
into an already-running agent process.

**Depends on / blocked by:** plans 002 and 008 shipped.

## livesync-cli launchd service not loaded after power cycle

**What:** The `com.livesync-cli` daemon plist exists at `/Library/LaunchDaemons/com.livesync-cli.plist`
but is not loaded. `sudo launchctl bootstrap system <path>` fails with `Input/output error` (exit 5).
The service was cleanly shut down (SIGTERM in logs) and never restarted.

**Why:** Without livesync, changes to cctrl (and other synced repos) don't propagate from the
Mac Studio to the MacBook Pro automatically. The cross-machine peer messaging feature depends
on both machines having the same cctrl script. Currently requires manual `scp` after edits.

**Impact:** Low urgency (manual scp works), but silently degrades the fleet workflow — edits
to cctrl, homelab, or obsidian-vault on the Studio don't reach the MacBook until noticed.

**Fix:** Run in a GUI terminal (launchctl bootstrap needs interactive context):
```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/com.livesync-cli.plist
# If that still fails, check the wrapper script and node version:
bash /Users/matthew/scripts/livesync-cli-wrapper.sh  # manual test
```
If the I/O error persists, the plist may need re-signing or the service identity may be
stale after a macOS update. Check `log show --predicate 'subsystem == "com.apple.xpc.launchd"' --last 5m`.

**Wrapper:** `/Users/matthew/scripts/livesync-cli-wrapper.sh`
**Logs:** `/Users/matthew/apps/livesync-cli/logs/livesync-cli.{stdout,stderr}.log`
**Last log entry:** clean SIGTERM shutdown, CouchDB target at `http://100.67.240.85:5984/obsidian`

**Depends on / blocked by:** nothing; fix requires Matthew in a GUI terminal on ms-128g-bln.
