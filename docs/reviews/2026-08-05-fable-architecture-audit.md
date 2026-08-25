# Independent architecture audit — cctrl + plans 051–053

- **Reviewer:** Fable 5, deliberately a different model from the session that authored and eng-reviewed the plans. Mandate: hunt for what both prior reviewers missed; agreement is only reported where independently re-derived.
- **Date:** 2026-08-05, working tree at commit `1339aa2` (dirty on purpose: plan amendments uncommitted).
- **Method:** read the three plans in full; read ~2,500 lines of `cctrl` directly (launch path, metadata, state detection, list/doctor/prune/close, peer delivery, fleet, dispatch); sampled the test suite; delegated the 50-plan/CHANGELOG history read to a sub-agent and verified its load-bearing claims against source; re-measured the live-data claims read-only. Everything quoted below was read from source in this session; findings I could not verify are labelled unverified.
- **Constraint honored:** no source edits, no commits, no state-mutating cctrl verbs, no writes under `data/`. The only mutations this review made: this file, and a scratchpad copy of one `session ls --json` output.

Severity scale: **P1** would break the feature or cause real harm in its first serious use · **P2** materially wrong but survivable · **P3** worth fixing while the file is open · **INFO** context. Confidence is my probability the finding is real as stated.

---

## Part 1 — Plan review findings

The GSTACK review reports were read first and are not re-litigated. The 18 folded-in findings are genuinely good — the `already-live` record-join, the readiness allow-list, the exit-code three-way, and the fixture-based backfill counts all fix real bugs the original drafts carried. What follows is what **both** prior reviewers missed.

### F1 · P1 · Plan 053: the picker's "corroborating signal" cannot fire — the resume picker does not match `_session_pane_has_dialog` (confidence 0.85)

Plan 053 specifies (picker AC, lines ~130–135):

> "The picker is a modal, so `_session_rich_state` should report `blocked-dialog` while it is up: use that as the corroborating signal and the literal string as the identifying one. If the two disagree (blocked-dialog with no picker string), treat it as some *other* modal … That distinction is the whole reason this is conditional on pane content."

That premise is false against the current code. `blocked-dialog` is produced solely by `_session_pane_has_dialog`, whose signature list is deliberately tight (cctrl:5877–5879):

```bash
printf '%s\n' "$capture" \
    | grep -E 'Do you want to (proceed|create|make)|Do you trust the files|❯ 1\. Yes' \
```

The resume picker's pane text is "Resume from summary" — confirmed empirically, because the *manual* procedure used during the actual Aug 2–3 restores greps exactly that string (`~/dev/homelab/fleet/restore-manifest.md:14`: `capture-pane … | grep -q "Resume from summary" && … send-keys … Enter`). It contains no "Do you want to proceed/create/make", no "Do you trust the files", and its option line is "❯ 1. Resume from summary (recommended)", not "❯ 1. Yes". None of the three signatures match, so `_session_rich_state` will **never** report `blocked-dialog` for the picker.

Consequences, depending on how an implementer reads the spec:

- If Enter requires the corroboration (string **and** blocked-dialog): the Enter is never sent, every large-transcript session ends `picker-stuck`/`timeout`, the run exits 1. The plan's central automation is dead on arrival.
- If Enter requires only the string: the corroboration clause is dead code, and the modal-vs-picker disambiguation the plan calls "the whole reason this is conditional" does not exist as described. The safety property the eng review's highest-severity test ("blocked-dialog with NO picker string must NOT get Enter") is meant to protect still holds — but the *inverse* case that will actually occur on every single restore (picker string with no blocked-dialog) is unspecified.

The irony: the codebase already contains a detector that *would* fire on the picker — `_peer_pane_ready_for_delivery`'s claude arm anchors on any highlighted numbered option (cctrl:3791):

```bash
if printf '%s\n' "$capture" | grep -E '❯ 1\.' >/dev/null 2>&1; then
```

Two modal detectors for one concept, with different regexes, and 053 picked the one that can't see its target (see finding A4).

**Fix before implementation:** either (a) extend `_session_pane_has_dialog`'s signature list with the resume-picker string — a global change to `session ls`/needs-me/autoheal semantics that 053 must own explicitly (it's arguably an improvement: a picker-blocked session *should* show `blocked-dialog` in `ls`), or (b) drop the rich-state corroboration requirement and specify the picker purely on stable pane text with the two-consecutive-capture rule, using the `❯ 1\.`-style anchor as the second signal. Either way the AC and its tests need rewriting; a test with a fixture pane carrying the real picker text against the *unmodified* dialog detector would have caught this.

### F2 · P1 · Plan 053: the readiness allow-list is unsatisfiable for codex sessions — every codex restore times out and fails the run (confidence 0.9)

"Ready" is defined as `_session_rich_state` returning `idle-done`, `waiting-input`, `unsent-draft`, or bare `idle`. Every one of those requires an `idle` base (the pane detectors refine idle only; `blocked-dialog` is the sole exception and is not in the list). Base state comes from the per-PID **Claude** session file (cctrl:5814–5825):

```bash
status="$(_session_claude_field "$sess" status)"
case "$status" in
    busy)  printf '%s' 'working' ;;
    idle)  printf '%s' 'idle' ;;
    shell) printf '%s' 'shell' ;;
    *)     printf '%s' '-' ;;
esac
```

Codex writes no `$CLAUDE_SESSIONS_DIR/<pid>.json` — plan 053 itself states this in the already-live section ("a codex session never populates at all"). So a codex session's rich state is permanently `-`, which is exactly the "unknown base" the allow-list correctly refuses. Net behaviour of the plan as written: a restored codex session waits the full 60s picker window (no picker string, no "normal ready prompt" detectable), then the full 180s ready timeout, is recorded `ready: timeout`, **and `ready: timeout` is enumerated under exit 1's failure dispositions**. One codex session in the snapshot ⇒ a 4-minute stall in its wave and a guaranteed non-zero exit on an otherwise clean restore — which also poisons the plan's "re-run the same command" idempotency story, since the re-run repeats the stall.

The plan says "No codex-specific branch beyond passing `--agent` through" — but the readiness machinery *is* claude-specific, so that sentence bakes the failure in. **Fix:** specify codex readiness explicitly — simplest honest option is `ready: unverifiable (codex)` recorded immediately after spawn succeeds, counted benign for exit purposes, with the wave gate relying on the resource check alone for codex members.

### F3 · P2 · Plan 053: the picker pane plausibly matches the *unsent-draft* detector, an allow-listed "settled" state (confidence 0.55 — flagged as plausible, not confirmed)

`_session_pane_has_draft` (cctrl:5893) matches:

```bash
| grep -E '^[[:space:]│|]*[>❯][[:space:]]+[^[:space:]]' \
| grep -Eiv 'Try "|for shortcuts|for commands|for newline|esc to (interrupt|cancel)|/ for' \
```

The picker's selection line `❯ 1. Resume from summary (recommended)` satisfies the first regex and none of the exclusions. The draft detector only fires on an `idle` base, and I could not verify what the per-PID `status` field reads while the picker is up (the process is live; if it reports `idle` before the first turn, the chain completes). If it does fire, a session still sitting at the picker classifies as `unsent-draft` → allow-listed → *ready*, and `_restore_wait_ready` releases the wave over a session that is actually blocked — the exact failure the allow-list was introduced to prevent. The window matters most when the picker renders late (huge transcript, slow boot) and the 60s picker phase has already recorded `picker: timeout`. Cheap insurance regardless of the base-state question: exclude the known picker string in `_restore_wait_ready`, or add it to the dialog signatures per F1(a), which makes the state `blocked-dialog` and closes both findings at once.

### F4 · P2 · Plan 051: the backgrounded poll must drop its inherited stdout/stderr or it re-creates the 20s stall on exactly the path the plan cites as motivation (confidence 0.85)

051's AC argues the poll must be backgrounded so it cannot "delay the machine-readable `CCTRL_SESSION=` line (cctrl:1855) that a remote `--host` launch parses". But the remote path collects that line via command substitution over ssh (cctrl:7823–7824):

```bash
local launch_out rc
launch_out="$(ssh "$ssh_target" "source ~/.zprofile 2>/dev/null; CCTRL_EMIT_SESSION=1 $env_prefix cctrl$quoted_args")"
```

Command substitution returns on **EOF of the pipe**, not on process exit. A background subshell forked by `_launch_detached` inherits the write end of that pipe (and keeps sshd's channel open); the substitution then blocks until the poll exits — up to the full ~20s — even though `_launch_detached` itself returned instantly. The same applies to any local scripted caller using `$(cctrl start -d …)`, including the cctrl-spawn skill's verify step. The plan says "detached background subshell" but never specifies the mechanics. **Fix:** one line in the AC — the poll runs as `( … ) </dev/null >/dev/null 2>&1 &` (optionally `disown`) — and one test asserting a launch's *stdout closes* promptly, not merely that the function returns (the existing planned test, "`_launch_detached` returns without waiting", passes even with the bug present).

### F5 · P2 · Plan 052: the LaunchAgent-over-LaunchDaemon argument is technically wrong, even if the choice is defensible (confidence 0.75)

The AC asserts: "It must be a LaunchAgent, not a LaunchDaemon: a daemon runs as root outside the user's GUI session and cannot reach the user's tmux socket." A LaunchDaemon with a `UserName` key runs as that user without root, and the tmux socket (`/private/tmp/tmux-<uid>/default`) is plain per-uid filesystem state with no GUI-session dependency — SSH-launched tmux fleets exist with nobody logged into the GUI at all. The real trade-off is: LaunchAgent = no sudo to install, per-user, but stops entirely when the user is not in a GUI session (053 itself names this as one of the two staleness causes); LaunchDaemon+UserName = sudo install, but covers the headless/SSH window — which includes the period right after a reboot before anyone logs in, i.e. the exact window in which a freshly restored fleet runs unsnapshotted. On this specific machine (Studio, presumably auto-login) the practical gap is small and the LaunchAgent is a reasonable call; the plan should just stop justifying it with a false technical claim, because that claim will be trusted the next time someone builds a launchd job here. One-paragraph wording fix.

### F6 · P3 · Plan 051: "benign last-writer-wins" is only true same-field, same-value — the merge helper has a classic lost-update window across fields (confidence 0.8)

`_session_update_metadata_field` is read-modify-write with atomicity only at the rename. Two concurrent writers of *different* fields (the background poll writing `conversation_id`; an `ls` refresh writing `conversation_id` + `transcript_path`; a future caller writing anything else) can interleave read-A/read-B/write-A/write-B and silently drop A's field. Today every planned writer derives the same values from the same live source, so lost updates self-heal on the next refresh tick and the risk is genuinely low — but the AC's concurrency claim ("a concurrent `session ls` refresh a benign last-writer-wins on an identical value") should be scoped to say *why* it is benign (all writers converge on identical values) so the helper is not later reused for divergent fields (e.g. a purpose edit) on the strength of a safety claim that doesn't cover that case.

### F7 · P3 · Plan 052: each snapshot tick pays the fleet enumeration twice (confidence 0.9)

The snapshot body is built from `_session_list --json`, and the header's `resource_line` comes from `_res_health_line` (cctrl:1408–1412), which calls `_active_session_count`, which runs **another** full `_session_list --json` (cctrl:1404). At the measured ~106ms/session that is ~6s per tick at 30 sessions, not ~3s — still a fine duty cycle, but the plan's carefully corrected cost model (its own "off by ~3x" mea culpa) is itself off by 2x. Fix in implementation: derive `session_count` from the rows already in hand and build the resource line from the three `_res_*` probes directly.

### F8 · P3 · `_active_session_count` collapses failure to `0`, and 053's cap will read a tmux hiccup as an empty fleet (confidence 0.8)

cctrl:1404–1405:

```bash
n="$(_session_list --json 2>/dev/null | jq 'length' 2>/dev/null)"
[[ "$n" =~ ^[0-9]+$ ]] && printf '%d' "$n" || printf '0'
```

051 fixes the *filter* (`select(.managed)`) but not the failure semantics: any `_session_list` error still yields `0`. For the launch guardrail that bias is acceptable (fail-open on one launch). For 053's `CCTRL_RESTORE_MAX_ACTIVE` cap it means a transient tmux failure mid-restore reports zero live sessions and admits a full wave over the cap — during exactly the kind of degraded post-outage conditions restores run in. 053 should treat a non-numeric/failed count as "gate closed", not "gate wide open".

### F9 · P3 · Plan 052: `stat -f %z` is Darwin-only (confidence 0.9)

Every other probe in the file branches on `uname` (`_res_mem_free_pct` cctrl:1340, `_res_swap_used_mb` cctrl:1376); `transcript_bytes` as specified would silently be `null` for every session on a Linux host. Cross-host snapshots are out of scope so this is latent, but the fix is one `stat -f %z || stat -c %s` fallback and the plan's own "bytes is the signal restore keys off" argument makes silent-null on a future platform worth the line.

### F10 · INFO · Line-number drift: sampled and mostly exact, with three slips — but the plans violate the repo's own citation convention

Verified exact: 1255, 1258, 1337, 1401, 1423, 1440, 1590, 1593, 1824, 1855, 1869, 5542(-5545), 5747, 5898, 6058, 6067, 6119, 6206(±3), 580–587, 1548–1556, 5996. Drifted: 051's Requirements says `tmux new-session` at cctrl:1835 while its own AC correctly says 1831 (actual: 1831); the no-TTY guardrail refuse is cited 1462, actual 1464; `_session_codex_rollout_path` cited 6984, actual 6983. Nothing misleading today — but plan 035 established, with receipts (a 13-line commit moved `_dispatch` by 7 lines), the convention "refer to cctrl internals by function name, never by line number", and 051–053 cite ~40 raw offsets. The first commit that lands ahead of them re-rots every citation. Cheap fix at implementation time: treat every `cctrl:NNNN` in these plans as "function name + hint", per the 029/035 rule.

### F11 · INFO · Live-data claims re-verified (and they drifted again, which is the point)

Re-measured tonight, read-only: 105 records; 35 carry a UUID anywhere (plan, 08-05: 36); 34 are flag-anchored in `launch_command` by my regex (plan: 35); `TMUX--ms--spawndryrun.json` confirmed — UUID only in `cwd` (a scratchpad path), zero UUIDs in `launch_command`. `session ls --json`: 1.16s for 11 sessions ≈ 106ms/session, matching the measured claim; 11 of 11 rows managed, so the `_active_session_count` gap is currently zero as stated. The counts moving a third time in three days is the strongest possible endorsement of the eng review's fixture-based-invariants decision.

### F12 · INFO · The two `--resume` parsers guard differently

`_launch_detached` refuses `@*` as a resume value (cctrl:1593: `"$2" != -* && "$2" != @*`); `cmd_start` does not (cctrl:1089: `"$2" != -*`). Restore drives the detached path, so 053 is unaffected; recorded as an instance of A4's duplication drift, and 051's "no-UUID-value" test should pin the detached arm specifically.

---

## Part 2 — Architecture audit

### A1 · The shape question: keep the single *artifact*, split the *source* — the file is already a concatenation in denial

**The case that the structure is now fighting the work is not speculative; the repo documents it:**

- Plan 035 had to establish a project-wide convention against citing line numbers, with measured receipts (one 13-line commit shifted `_dispatch` by 7 lines). A codebase that needs a convention to survive its own line churn is telling you its unit of reference (the single file) is too big.
- Plans are explicitly serialized to avoid textual conflicts *within one function*: 034 is sequenced after 023 because both edit the same `jq -cn` block in `_peer_cmd_send`; 029 carries the same warning for 023+027. That is merge pain functioning as a scheduler.
- Plan 036 rejected a `lib/` helper because it "would fork cctrl's single-file distribution for no measurable gain" — and then added a hidden re-entrant subcommand (`cctrl repo _probe`) as the workaround. Contorting the CLI surface to preserve a packaging property is the structure taxing the design.
- The single-file principle is already breached where it had to be: `lib/peer_mcp.py` exists because the MCP bridge couldn't be bash.
- The interior is held together by 40 distinct `CCTRL_*` environment knobs and ~35 mutable-global return channels (counted; see A2) — bash's substitute for module boundaries.

**The case for the current shape is also real:** the `_peer_`/`_session_`/`_res_`/`_shortcut_` prefix discipline is consistently applied; section banners exist; bash offers no namespacing, so a source split buys isolation only at the review/merge/navigation level, not at runtime; and a single copyable file is a genuinely good distribution property for a personal fleet tool that gets `scp`'d between machines.

**Verdict: do not rewrite, do not even change the artifact — change what's checked in.** Split the source along the seams below into `src/*.sh` and produce the shipped `cctrl` by dumb concatenation (a 10-line `make`/build script; the generated file can even stay checked in for the scp workflow). This keeps single-file distribution *exactly* while making the unit of editing, review, and merge the subsystem. Two properties make the migration unusually cheap here, which is why I'm comfortable recommending it despite the prompt's correct suspicion of reflexive restructuring: (1) the seams are already contiguous line ranges, so the first cut is `sed`, not surgery; (2) the test suite is black-box E2E against the built binary (391 invocations of `$ROOT/cctrl`), so "concatenated output is byte-identical to today's file" is a checkable migration invariant, and after that the full suite gates every subsequent move. Estimated cost: an afternoon for the mechanical split + build script if the concatenation is kept dumb; the risk is confined to whatever tooling assumes `cctrl` is hand-edited (livesync, the deploy path, `install.sh` — audit those first).

The seams, by current line ranges (all already contiguous):

| Seam | Range (approx) | Contents | Coupling to the rest |
|---|---|---|---|
| prelude/config | 1–68 | paths, env, colors | everything (fine — it's the header) |
| profiles + costs + usage | 69–1005 | profile CRUD, overlay, spending log | launch reads overlay; else isolated |
| launch | 1017–1891 | `cmd_start`, `_launch_*`, guardrail, `_res_*` | writes metadata; calls `_session_list` (count) |
| peer + mailbox | 1895–5485 | registry, mailbox, delivery, watch, MCP | ~4 session helpers + `_tmux_run_*`; largest cohesive block (~3,600 lines) |
| session | 5486–7167 | ls/doctor/say/prune/close/autoheal/state | metadata dir, `_tmux_run_*` |
| help/statusline/chrome | 7168–7612 | leafs | none |
| hosts + fleet + needs-me | 7613–8115 | `_remote_exec`, `cmd_fleet` | calls `session ls --json` |
| shortcuts + dispatch | 8395–8968 | `@` verbs, plugin fallback, `main` | dispatch touches all |

If only one extraction ever happens, make it peer+mailbox: 40% of the file, one concept, and the subsystem where plans keep colliding.

### A2 · Coupling: the queries are honest; the *setup* functions are not

The prompt asked about functions that mutate globals while looking like pure queries. The read-side is actually clean — `_session_rich_state`, `_session_list`, `_peer_reachability_class` (which a test explicitly pins as pure) do not write state. The coupling problems sit one layer down:

- **`_apply_profile_overlay` mutates the path globals out from under every subsystem**, and callers must know to perform the ritual re-derivation afterwards: `_apply_profile_overlay …; _peer_refresh_paths; _session_refresh_paths` appears verbatim at cctrl:1673–1675 and cctrl:1172–1174. Forgetting the pair of refresh calls after any future overlay call site means peer/session state silently reads the *pre-overlay* directories. The refresh functions exist precisely because this burned once; the fix (overlay returns values, or overlay itself calls the refreshes) is small.
- **The launch protocol is an implicit global contract:** `cmd_start` sets `LAUNCH_FULL_BYPASS`, `LAUNCH_ACCESS_EXPLICIT`, `LAUNCH_PERMISSION_MODE`, `LAUNCH_PASSTHROUGH` (cctrl:1199–1203) and then calls `_launch_exec_agent`, which also *reads and rewrites* `LAUNCH_FLAGS` built by `_launch_apply_profile_args`. Nothing declares which globals are input, output, or scratch; 31 references to `LAUNCH_FLAGS` alone.
- **The delivery layer speaks through ~14 `PEER_DELIVER_*` globals** (37 references to `PEER_DELIVER_REASON` alone), plus `PEER_ORCH_*`, `MAILBOX_*`, `TMUX_RUN_OUTPUT/ERROR`, `SESSION_SAY_REASON`, `WATCH_LOCK_*`. This is idiomatic bash for multi-value returns and it's used *consistently*, which is the saving grace — but it means no function in the delivery path can be understood, or safely called re-entrantly, without knowing the whole channel set. Worth documenting as a named convention (one comment block listing the channels per subsystem) even if nothing is restructured.
- **The known liar:** `_active_session_count`'s comment says "cctrl-managed" while the body counts every tmux session (cctrl:1401–1406) — confirmed, and 051 fixes it. The general lesson it carries: in a file this size, a comment is the only interface documentation a function has, so a wrong comment *is* a wrong API.

### A3 · Vocabulary: one session, six names — mapped

The prompt's suspicion is correct and it's worse than name-vs-label-vs-purpose. The same runtime object is addressed through all of these:

| Term | Where it lives | What it actually is |
|---|---|---|
| tmux session name / "session id" / `session_name` / `context_name` | `TMUX--<host>--<alias>[--N]`, derived at cctrl:1739–1791 | the real primary key — and also the *mailbox address* for derived peers |
| `launch_name` → `launch_display_name` | cctrl:493–501 | claude's `--name` becomes `"<purpose> (<tmux id>)"` — a third, composite identity visible in the app |
| `display_label` | metadata + `ls --json` | `@shortcut` or the dir path (cctrl:1744/1770/1775) |
| `purpose` | metadata; **set by `-n/--name`** unless `--purpose` given (cctrl:1565–1567) | the human description — via a flag literally called *name* |
| `peer` | registry or derived | for unaliased sessions, *is* the tmux name (the 023/028/029 defect line) |
| `session_id` / `sessionId` / `conversation_id` / "transcript uuid" | per-PID file, `ls --json`, plan 051's new field | the Claude conversation UUID — four spellings for one value |

Two structural traps inside this, beyond the known tangle:

- **`state` means different things at different layers.** In `_session_list`'s *variables*, `state` holds attached/detached (cctrl:6069) and `base_state` holds the rich state (cctrl:6101); in the JSON output, `state` is the rich state and `attached` is a separate boolean (cctrl:6119). The internal naming is inverted relative to the external contract — harmless until someone edits the loop trusting the variable names.
- **"label" is triply overloaded across plans:** `display_label` (023's field), 023's *derived* `label` (`display_label // purpose // name`, with the jq-`//`-empty-string caveat), and 010's "host label"/"requested label". Plan 051's schema list uses `display_label`; 053's `--only` matches "name, display_label, purpose, cwd". Anyone implementing 053's matcher from 023's vocabulary gets a different field set.

Recommendation: a 30-line `docs/GLOSSARY.md` naming the six identities and the one blessed term for each, referenced from AGENTS.md; rename only opportunistically (in functions already being edited — 051 touches the `_session_list` loop, which is the right moment to rename its `state`/`base_state` locals). The full fix is plans 028/029 (stable peer identity), which are blocked; nothing here should preempt them.

### A4 · Duplication that should not be (and some that should stay)

- **Two modal detectors, divergent, and now consequential:** `_peer_pane_ready_for_delivery`'s claude arm anchors on `'❯ 1\.'` (cctrl:3791); `_session_pane_has_dialog` anchors on `'Do you want to (proceed|create|make)|Do you trust the files|❯ 1\. Yes'` (cctrl:5878). Same concept — "is a Claude modal up" — different answers for the same pane (the resume picker: peer delivery says modal, rich state says no). This split is what makes F1 possible. These two should share one signature source even if the callers keep different sensitivities.
- **The session row loop is re-implemented four-plus times:** `_session_list` (cctrl:6034–6137), `_session_doctor` (cctrl:6271–6393 plus its pre-pass at 6258–6264), `_session_prune` (cctrl:7089–7138), `_session_autoheal` (same shape), each re-deriving `tmux list-sessions` → `_session_agent_cmd` → per-field metadata jq calls → state. This is the single biggest duplication cost in the file: 051's six-jq-calls-into-one fix applies to *one* of these loops. A `_session_row_json <name>` used by all enumerators would fix the cost and the drift at once — a natural follow-up to 051's collapse, and a prerequisite worth naming in the TODOS entry about `_active_session_count`.
- **Two paste implementations** (`_peer_tmux_paste` cctrl:3823, `_session_tmux_paste` cctrl:5565) — near-identical, but the duplication is *deliberate and documented* (comment at 5566–5570; plan 024 explicitly forbade de-duplicating mid-feature). Fine to leave; the comment carries the reason.
- **Two lock implementations** (`_mailbox_lock_acquire` cctrl:2863 — blocking with timeout, shlock-or-dir; `_watch_lock_acquire` cctrl:4949 — non-blocking dir-only). Different semantics, ~60% shared mechanics (pid file, stale-lock reaping). Middle-priority.
- Small change: `hint_prefix` derivation duplicated at cctrl:1841–1844 and 1886–1887; ISO↔epoch conversions scattered (cctrl:6091, 7129, 7956); the `--resume` arm parsed differently in two places (F12); `tmux list-sessions` name-collection boilerplate at cctrl:6021, 6250, 7084.

### A5 · Where the error handling lies

The systemic pattern: under `set -euo pipefail`, every query helper is written to `return 0` unconditionally and signal failure with empty output (`_session_metadata_field` cctrl:1216, `_session_transcript_path` cctrl:5761, `_session_codex_rollout_path` cctrl:6998, …). That is a *coherent* convention — a non-zero return from a helper inside `$( )` would nuke the script — but it means "absent", "unreadable", and "empty" are indistinguishable downstream, and the specific lies grow from there:

- **`_try_plugin` swallows the plugin's exit code** (cctrl:8850–8853): `"$PLUGINS_DIR/cctrl-$cmd" "$@"` then unconditional `return 0`, called from `if ! _try_plugin …` (errexit disabled in condition context). A plugin that fails with any code still makes `cctrl <plugin-cmd>` exit 0. Scripted callers of any plugin get success unconditionally. Confirmed from source; severity limited only by how few plugins exist.
- **A failed metadata write on a non-peer launch is completely silent** (cctrl:1824–1830): `_session_write_metadata … 2>/dev/null` failure only errors when `--peer` was given; otherwise the launch prints its green success line with no record written. Everything downstream that trusts records — `ls` purpose/label, prune's created_at floor, and now the whole 051–053 chain, whose durability story *is* the record — silently degrades. This should be at least a warning on every launch, and 051 (which makes records load-bearing for recovery) is the right vehicle.
- **Failure collapses to a benign-looking value** in `_active_session_count` (→ `0`, F8) and `cmd_fleet`'s local row (`_session_list --json 2>/dev/null || host_json="[]"`, cctrl:7907): a broken local tmux renders as "no local sessions" in the fleet view, indistinguishable from an idle machine — while *remote* failures get an honest `offline` marker (cctrl:7920–7925). The remote path shows the local path how it should behave.
- **The counterexamples worth copying:** `session say` and the peer delivery layer return typed reason codes on every failure path (`SESSION_SAY_REASON`, distinct exit codes 64/66/69/75, cctrl:5606–5714), and `_session_update_metadata_field` (051) is specified with no-create-on-missing + non-zero. The repo knows how to do this; the lies are the older code.

### A6 · The test suite: behaviour-first and earning its keep, with one epistemic hole

5,139 lines / 119 test functions / ~787 assertions, and the structure is right: 391 invocations of the real `$ROOT/cctrl` binary with fake `tmux`/`ps`/`ssh`/`hostname` on PATH and every data dir overridden via env seams; assertions are on JSON and human output, not internals (`CCTRL_NO_MAIN` sourcing is used exactly once). Regression tests encode real shipped bugs with their history in comments (the `❯` vs ASCII-`>` draft detector, the `. 1\.` modal regex, codex-in-prompt mislabelling, the codex never-prompted false positive). Mutation-style seams (`CCTRL_DOCTOR_RELAUNCH_LOG`, `CCTRL_AUTOHEAL_REPAIR_LOG`) let destructive paths be asserted without touching live sessions — the pattern 053 correctly copies. This suite is testing behaviour, and it is the main reason the A1 source-split is cheap. It earns its 5k lines.

Three real weaknesses:

1. **The fixture-reality gap on pane detectors.** Every pane fixture is hand-modeled text ("MODELED ON real `tmux capture-pane` output"). The suite can prove a detector matches its fixture; it cannot prove the fixture matches Claude Code's actual TUI — and the shipped-bug history (`❯` glyph; "Allow command" never matching a real codex modal) plus F1 (a picker no detector can see) are all exactly this gap. Cheap mitigation: a `tests/fixtures/` provenance rule — pane fixtures must be dated `capture-pane` dumps, refreshed when the agent CLI is upgraded — and a doctor check that flags a detector matching zero live panes for N days would catch silent decay in production.
2. **Monolithic fail-fast:** one file, sequential, first `fail()` exits 1 — a mid-suite failure hides everything after it, and there is no way to run a single test (the runner is a bare list of 119 calls at the bottom). A `for t in "${@:-all}"` filter is a 5-line fix with outsized DX payoff given the suite gates every plan.
3. **Runtime is unmeasured and growing** (051–053 add ~28 more tests). Not yet a complaint anywhere in the repo, but at this trajectory the first "skip the suite just this once" is predictable. Worth timing and putting a number in the README.

### A7 · The debt ledger cross-check

TODOS.md's `_active_session_count` cheap-path entry is correct and I'd add F8's failure→0 collapse to it. The larger priority observation: **plan 038 — per-session policy at the tool boundary, i.e. the mitigation for every session running `bypassPermissions` — is approved and unimplemented, while 053 proposes injecting keystrokes into those same bypassed sessions.** The 039–050 audit backlog (12 approved plans, zero execution since 07-30) plus 051–053 jumping the queue at priority 5–7 is a legitimate call for a recovery capability, but 038 is the one plan in the backlog that reduces the blast radius of everything else, 053 included.

---

## Part 3 — Verdict on the 053 scope question

**I agree with the cut, and my findings sharpen it: as currently specified, full 053 would likely fail its first real run — so "ship it later" is also "ship it wrong today."** But I'd draw the cut line slightly differently than "dry-run only."

**The rate argument holds.** Verified from `last reboot shutdown`: two unclean reboots (Aug 2 20:36, Aug 3 16:48 — no matching shutdown records, i.e. power loss), and nothing between a *clean* Jun 4 shutdown and Aug 2. That is a 48-hour cluster, not a rate, and the plans were written on Aug 3 — inside the cluster, which is exactly when recency bias prices a twice-a-year event as weekly. One counterweight the prior session didn't weigh: 051's own design note says "the machine is being moved," and a physical move is a scheduled elevated-risk window — but a *scheduled* move is precisely when a human is present and a dry-run manifest suffices.

**The value-concentration argument also holds, and 052 deserves more credit than "capture."** 051 removes the archaeology (the UUID mapping was the hours-long part — verified: three manual reconstructions across two reboots). 052 turns recovery into reading one file — and its every-5-minutes `ls` tick is also the self-heal that populates 051's field fleet-wide, so 052 is not optional garnish; it's how 051 reaches the already-running fleet. After 051+052, manual recovery for a 10-session fleet is ~20–30 minutes of semi-attended copy-paste (the Aug 2–3 events were run from a hand-built manifest whose picker step was a one-line grep-and-Enter — the exact loop 053 automates).

**What full 053 buys over that is automation of the watch-and-wait, and that is precisely the code my findings show is mis-specified:** the picker corroboration cannot fire (F1), codex sessions cannot pass readiness (F2), a stuck picker can read as ready (F3), and the cap fails open on a tmux hiccup (F8). Four independent defects, all in the automated-detection layer, all missed by two prior reviewers — that is not bad luck; it is the base rate for code that infers TUI state from pane text, and it argues the detection layer needs live-fire iteration you cannot get for an event that happens twice a year.

**My recommendation:**

1. **Ship 051 in full**, adding F4's fd-redirect specification and (opportunistically) the silent-metadata-write warning from A5.
2. **Ship 052 in full**, with the F5 wording fix, F7's single-enumeration note, and the F9 stat fallback.
3. **Re-scope 053 to: snapshot reader + candidate/disposition logic + `--dry-run`/`--json` plan rendering with exact per-wave argvs, plus at most a waved spawner that requires interactive confirmation between waves and performs no keystroke injection and no readiness inference.** The human answers pickers by attaching (or the manifest's existing one-liner). This keeps roughly the front half of the plan — the half whose logic two reviews have now actually hardened (freshness/hostname gates, already-live record join, cap, exit codes) — and drops `_restore_wait_picker`/`_restore_wait_ready` entirely, which is where all four of my P1/P2 findings live. A human is present during every real restore anyway (someone rebooted the machine); "press Enter for the next wave" costs them seconds and deletes the two most defect-dense functions in the batch.
4. **Gate any future full-automation 053 on:** (a) a second power event demonstrating the dry-run+manual flow is actually the bottleneck, (b) F1/F2/F3 resolved in the spec — unifying the modal detectors per A4 is the right vehicle, and (c) preferably plan 038 landed first, so a misfired keystroke no longer lands in a `bypassPermissions` session by default.

The one place I'd push back on the prior session: framing this as "051 captures most of the value" undersells the *pair*. 051 without 052's timer only covers sessions launched or `ls`-refreshed after it ships; the timer is what guarantees the field is populated when the power actually fails. Ship them as the unit they are; trim the third.

---

## Summary table

| ID | Sev | Plan/Area | Finding | Conf |
|---|---|---|---|---|
| F1 | P1 | 053 | Picker corroboration can't fire: resume picker matches no `_session_pane_has_dialog` signature (cctrl:5878) | 0.85 |
| F2 | P1 | 053 | Readiness allow-list unsatisfiable for codex → guaranteed 4-min stall + exit 1 (cctrl:5814–5825) | 0.90 |
| F3 | P2 | 053 | Picker line matches draft regex (cctrl:5893) → stuck picker can classify as allow-listed "ready" | 0.55 |
| F4 | P2 | 051 | Backgrounded poll's inherited stdout blocks `$(ssh …)` capture (cctrl:7824) up to 20s — must redirect fds | 0.85 |
| F5 | P2 | 052 | LaunchAgent justification technically false (UserName daemon reaches tmux fine); trade-off is coverage vs sudo | 0.75 |
| F6 | P3 | 051 | Merge-helper lost-update window across fields; "benign" claim needs scoping | 0.80 |
| F7 | P3 | 052 | Snapshot double-pays enumeration via `_res_health_line`→`_active_session_count` (cctrl:1408–1412) | 0.90 |
| F8 | P3 | 051/053 | `_active_session_count` failure→`0` (cctrl:1404–1405); 053's cap fails open | 0.80 |
| F9 | P3 | 052 | `stat -f %z` Darwin-only, no Linux fallback | 0.90 |
| F10–F12 | INFO | 051–053 | Minor line drift; convention violation (035); counts drifted again; `--resume` parser asymmetry | — |
| A1 | P2 | arch | Split source, keep concatenated artifact; seams tabled; E2E suite makes it cheap | 0.80 |
| A2 | P2 | arch | `_apply_profile_overlay` + refresh ritual; LAUNCH_*/PEER_DELIVER_* implicit contracts | 0.85 |
| A3 | P3 | arch | Identity vocabulary mapped: six names per session; `state` inverted internal-vs-external; glossary rec | 0.90 |
| A4 | P2 | arch | Divergent modal detectors (cctrl:3791 vs 5878) — root enabler of F1; row loop ×4; lock ×2 | 0.90 |
| A5 | P2 | arch | `_try_plugin` swallows exit (cctrl:8850–8853); silent metadata-write failure (cctrl:1824–1830); failure→benign-value collapses | 0.85 |
| A6 | P3 | tests | Behaviour-first and worth its size; fixture-provenance gap, fail-fast monolith, no single-test filter | 0.85 |
| A7 | INFO | debt | 038 (bypass mitigation) unimplemented while 053 proposes keystroke automation — priority inversion | — |

---

## Addendum: disposition (2026-08-05, same day — read-only mandate lifted by Matthew)

Findings were folded into the working tree as follows. Nothing is committed;
the tree awaits Matthew's review and typed commit approval.

- **F4, F6, A5(metadata-write)** → amended into plan 051 (fd-redirect AC +
  stdout-closes test; scoped concurrency claim; launch-time warning).
- **F5, F7, F9** → amended into plan 052 (honest LaunchAgent trade-off;
  single-enumeration header; `stat -c %s` fallback).
- **F1, F2, F3, F8** → plan 053 re-scoped to human-in-the-loop (Option A):
  picker/readiness automation removed and deferred behind four gates recorded
  in the plan's Design section and a TODOS.md entry; cap fails closed; the
  no-pane-inference structural assert added. Full automation requires a new
  plan and fresh eng review.
- **A1, A4(row loop), A4(modal detectors), A6(fixtures), A6(harness DX)** →
  five TODOS.md entries in the house promotable format, plus the deferred-053
  entry (six total).
- **Process rules (Part 3 §4 / the "how didn't mstack catch this" analysis)** →
  proposal doc at `~/dev/mstack/docs/review-hardening-proposal.md` + a TODO.md
  pointer in the mstack repo. Not wired into any skill; each rule independently
  adoptable.
- **Not acted on:** A2 (coupling channels — documentation-convention material,
  no vehicle chosen), A3 (glossary — deferred to any 028/029 revival),
  A5(`_try_plugin` exit swallow — noted for plan 050's hygiene pass), the 038
  priority bump (left for backlog grooming, since the re-scoped 053 no longer
  ships keystroke automation), and F10-F12 beyond the 051 citation fix.
