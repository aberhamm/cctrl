---
id: 051
title: Persist conversation_id on the session record
status: done
blocked-by: []
priority: 5
goal: fleet-restore-after-power-loss
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-08-03
completed: 2026-08-07
---

## Requirements

A session's Claude conversation UUID is computed on demand from the running
process and therefore dies with it. `_session_id` (cctrl:5747) resolves it via
`_session_claude_field <sess> sessionId`, which reads
`$CLAUDE_SESSIONS_DIR/<pid>.json` — a per-PID file for a live process. Nothing
ever writes that value into the session record, so when the machine loses power
the mapping from "session that was doing X" to "conversation UUID to resume" is
gone. It was reconstructed by hand three times on 2026-08-02/03 (two reboots of
`ms-128g-bln`, one 28-session fleet), each time by reading transcript files
under `~/.claude/projects/` and guessing from the first user message. That is
the entire problem this plan removes.

What already survives (verified, 2026-08-03): `data/sessions/*.json` records
persist across session death — 105 exist right now — and `purpose` is already
one of the 13 persisted keys, so labels were never the missing piece. The record
schema is exactly `agent, cctrl_managed, created_at, cwd, display_label, host,
initial_prompt, launch_command, name, peer, purpose, target, target_kind`.
`conversation_id` appears in zero records.

Two findings from the brief needed adjusting, and the plan is built on the
corrected versions:

1. **"Populate from `_session_id` at start" is not possible for fresh
   launches.** `_session_write_metadata` is called at cctrl:1824, *before*
   `tmux new-session` at cctrl:1831. At write time the agent process does not
   exist, so there is no per-PID Claude session file and `_session_id` returns
   empty. The value IS known at launch time for `--resume` launches (it is the
   argv the caller passed). So: write it directly on the resume path, poll for
   it briefly after the tmux session comes up on the fresh path, and rely on the
   `ls`/`doctor` refresh as the durable self-heal.
2. **38 records are backfillable, but a bare UUID regex finds 39 and one of them
   is wrong.** `grep -lE '<uuid>' data/sessions/*.json` matches 39 files;
   `--resume`/`-r` in `launch_command` matches 38. The extra file,
   `TMUX--ms--spawndryrun.json`, carries its UUID in the **`cwd`** field — a
   scratchpad path, `/private/tmp/claude-501/…/d05246e7-686a-4697-ab53-064ad3e85bcc/scratchpad/…`
   — and its `launch_command` contains no UUID at all. So backfill must (a) read
   only `launch_command`, never the whole record, and (b) anchor on
   `(--resume|-r)` immediately preceding the UUID. Either guard alone is
   insufficient: session-scoped scratchpad paths embed UUIDs routinely, and a
   whole-file regex would hand that record a fabricated conversation link.

`_session_write_metadata` rebuilds the whole record with `jq -n`, so there is no
existing way to update one field without clobbering the rest. A merge helper is
part of this plan.

**Acceptance criteria:**

- [ ] The session record gains a nullable `conversation_id` field (Claude
      `sessionId` / transcript UUID) and a nullable `transcript_path`. Both are
      `null` for records that predate the field and for sessions whose value
      cannot be resolved. `_session_write_metadata` emits both keys on every new
      record so the schema is uniform.
- [ ] New `_session_update_metadata_field <name> <field> <value>`: read-modify-write
      of a single key via `jq --arg`, into a `mktemp` **created in
      `$SESSION_METADATA_DIR`** (not `$TMPDIR` — `mv` is only atomic within one
      filesystem) then `mv`. If the existing record is missing or `jq` fails to
      parse it, the helper leaves the file untouched and returns non-zero; it
      never creates a partial record.
- [ ] Launch-time population: on a `--resume <id>` launch the record is written
      with `conversation_id` already set from the resume argv. **This needs new
      capture code, not just a read**: `_launch_detached`'s `--resume|-r` arm
      (cctrl:1590) pushes the flag and its value straight into `passthrough` and
      keeps no variable, so the id is currently unavailable at
      `_session_write_metadata` time. Add an explicit `resume_id` capture in that
      arm and thread it to the metadata write. On a fresh launch
      `_launch_detached` makes a bounded best-effort poll after `tmux
      new-session` succeeds (`_session_id`, up to ~20s, ~2s apart) and writes
      the value if it resolves. A failed or timed-out poll is silent and never
      fails the launch.
      **The poll runs in a detached background subshell, never inline — and it
      MUST drop its inherited stdio: `( … ) </dev/null >/dev/null 2>&1 &`
      (plus `disown` where job control applies).** The fd redirection is not
      hygiene, it is the point: `_remote_exec`'s detach-and-attach path
      collects the launch output via command substitution over ssh
      (`launch_out="$(ssh …)"`, cctrl:7824), and command substitution returns
      on EOF of the pipe, not on process exit. A background subshell that
      inherits stdout keeps that pipe open until the poll exits — up to the
      full ~20s — so without the redirect, backgrounding fixes nothing on
      exactly the remote path this AC cites as motivation. The same applies to
      any local scripted caller using `$(cctrl start -d …)`, including the
      cctrl-spawn skill's verify step.
      `_launch_detached` today returns in well under a second: `tmux
      new-session` at cctrl:1831, four hint lines, then `_prompt_attach_session`
      which returns immediately on a non-TTY (cctrl:1869). A synchronous 20s
      poll would make every scripted spawn 20x slower, delay the machine-readable
      `CCTRL_SESSION=` line (cctrl:1855) that a remote `--host` launch parses,
      and add up to 20s per session to plan 053's restore waves — to populate a
      field the `ls`/`doctor` refresh fills for free. Backgrounding keeps the
      launch path instant. The background write MUST go through
      `_session_update_metadata_field`, never a whole-record rewrite.
      **Concurrency claim, scoped honestly:** the same-dir `mktemp` + `mv`
      makes a concurrent `session ls` refresh a benign last-writer-wins *only
      because every planned writer of these fields (the poll, the `ls` refresh,
      the `doctor` refresh) derives the same value from the same live source*,
      so a lost update self-heals on the next refresh tick. The helper is
      read-modify-write without a lock: two concurrent writers of *different*
      fields can interleave read/read/write/write and silently drop one field.
      Do not reuse the helper for divergent-value fields (e.g. a purpose edit)
      on the strength of this paragraph — that case is not covered by it.
- [ ] **Fix `_active_session_count` (cctrl:1401) to count only managed sessions.**
      Its comment already claims "Count of live cctrl-managed tmux sessions on
      THIS machine", but the body is `_session_list --json | jq 'length'` and
      `_session_list` enumerates every tmux session including plain shells
      (`kind: shell (zsh)`, cctrl:6067). Change the filter to
      `jq '[.[] | select(.managed)] | length'` so the guardrail, `_res_health_line`
      / `cctrl fleet`, and plan 053's restore cap all report one number instead of
      two. On the 2026-08-05 fleet the gap is currently zero (10 rows, 10 managed),
      so this is a latent divergence, not an active bug — it appears the first time
      a plain tmux shell is open. Regression test asserts a plain (unmanaged) tmux
      session is excluded from the count. Doing it here rather than in 053 avoids
      053 carrying a duplicate private jq expression that would drift.
- [ ] **Collapse the six per-session `_session_metadata_field` calls in
      `_session_list` into one `jq` read.** The row loop (cctrl:6034-6119) calls
      it six times — `purpose`, `created_at`, `peer`, `display_label`,
      `cctrl_managed`, and one more — each a separate `jq` subprocess against the
      *same* file. Measured 2026-08-05: `session ls --json` costs 1.06s for 10
      sessions (~106ms/session, three runs: 1.07/1.05/1.06). That loop is on the
      launch hot path via `_active_session_count` (guardrail, cctrl:1440), so
      every `cctrl start` pays it. This plan is already editing the loop to add
      the refresh guard; one `jq` emitting all six fields is the DRY fix while
      it is open. Not a behavioural change — no new test beyond the suite passing.
- [ ] Refresh-on-read: `_session_list` (`session ls`) and `_session_doctor`
      write `conversation_id`/`transcript_path` back to the record whenever the
      live value is non-empty **and differs from the stored value**. Unchanged
      values produce zero writes — `_session_list --json` is on the hot path
      (`_active_session_count` calls it from the launch guardrail at cctrl:1423),
      so an unconditional write per row per launch is not acceptable.
- [ ] `session ls --json` already emits `session_id` and `transcript` per row
      (cctrl:6112) — those stay as-is and are not renamed. The new record field
      is the persisted mirror of them, and the JSON gains nothing.
- [ ] New maintenance verb `cctrl session backfill-ids [--dry-run] [--json]`
      operating on **records, not live sessions**: for every record with a null
      `conversation_id`, parse `launch_command` for `(--resume|-r)` followed by a
      UUID and write it. Anchored on the flag, per finding 2. Idempotent;
      `--dry-run` is the default-safe preview and writes nothing. It lives here
      and not on `session doctor --fix` because doctor requires tmux and only
      iterates live sessions, while most of the 105 records are dead.
- [ ] Backfill reports three counts: filled, already-set, unrecoverable.
      **The acceptance test asserts invariants against a committed fixture
      directory, never counts against `data/sessions/`.** That directory is the
      live fleet store (gitignored, rewritten on every launch), so any census of
      it is stale before the plan is implemented: the 2026-08-03 measurement of
      38 / 0 / 67 already read 35 / 0 / 70 on 2026-08-05. A count baked into a
      test fails on day one for reasons unrelated to the code. The fixture dir
      must contain, at minimum: a record with `(--resume|-r) <uuid>` in
      `launch_command` (expect filled); a copy of the `TMUX--ms--spawndryrun`
      shape with a UUID in `cwd` and none in `launch_command` (expect refused);
      a record with `conversation_id` already set (expect already-set); and a
      record with no UUID anywhere (expect unrecoverable). Invariants asserted:
      flag-anchored parse fills, UUID-in-`cwd` is refused, a second run fills
      zero.
      *Dated observation (not a criterion):* on 2026-08-05, 105 records, 36
      carrying a UUID anywhere, 35 of those flag-anchored in `launch_command`,
      1 (`TMUX--ms--spawndryrun`) UUID-in-`cwd` only. That ~2/3-unrecoverable
      ratio is what justifies the documented null limitation below.
- [ ] The 67 unrecoverable records keep `conversation_id: null` and that is the
      documented, deliberate answer — see Design for why no fuzzy matcher.
      README documents the field, the backfill verb, and the limitation.
- [ ] Codex sessions: `conversation_id` may be populated from the UUID in the
      rollout filename resolved by `_session_codex_rollout_path` (cctrl:6984),
      since `codex resume <id>` is a supported launch path (cctrl:580-587) —
      but **only when the match is unambiguous**. That resolver correlates on
      `session_meta.cwd` alone and returns the newest match by reverse lexical
      filename sort; it does no filename-UUID extraction and no per-session
      disambiguation. Two codex sessions in one cwd therefore both resolve to
      the newer rollout, and the older one would be stamped with the other's
      conversation. Required behavior: when more than one rollout matches the
      cwd, write `null`, not a guess. This is the same rule the 67 get, and for
      the same reason — a wrong id is worse than a missing one. If unambiguous
      attribution proves impractical, drop codex to `null` entirely; nothing
      else in this plan depends on it.
- [ ] Tests cover: the merge helper preserves every other key; a malformed
      record is left untouched; backfill fills the `-r` case and **refuses** the
      UUID-in-`cwd` false positive (use `TMUX--ms--spawndryrun.json`'s shape as
      the fixture); the refresh path writes once on change and not at all when
      unchanged. Plus the gaps found in eng review:
      - **`_session_update_metadata_field` on a missing record does not create
        it** and returns non-zero (stated in the AC above, previously untested).
      - **Ambiguous codex rollout writes `null`, not a guess** — two rollout
        files matching one `cwd` must yield `null`. This is the case the AC
        above argues is a wrong-id hazard, and it was specified without a test.
        A wrong id here is resumed faithfully by 053 under the right label.
      - **`--resume` with no UUID value** (`--resume @shortcut`, `--resume`
        followed by a flag — the guard at cctrl:1593) writes no
        `conversation_id` rather than garbage.
      - **`backfill-ids --dry-run` writes nothing** (it is the default-safe
        preview; previously asserted only in prose).
      - **Backfill is idempotent** — a second run reports 0 filled.
      - **`backfill-ids --json`** emits the three counts in the documented shape.
      - **`_active_session_count` excludes a plain unmanaged tmux session.**
      - The backgrounded fresh-launch poll: on timeout the record keeps
        `conversation_id: null` and the launch still succeeds; `_launch_detached`
        returns without waiting for it.
      - **The launch's stdout CLOSES promptly, not merely "the function
        returns"** — assert that `out="$(cctrl start -d …)"` (command
        substitution, the `_remote_exec` shape) completes in well under the
        poll window while the poll is still pending. A test that only times
        the function call passes even when the poll inherits stdout and
        stalls every `$( )` caller for 20s; capturing through a pipe is the
        only shape that exercises the actual failure mode.
- [ ] **A failed `_session_write_metadata` warns on EVERY launch, not just
      `--peer` launches.** Today the write at cctrl:1824 is `2>/dev/null` and
      its failure is surfaced only when a peer identity was requested — a
      non-peer launch prints the green success line with no record written,
      and everything that trusts records (purpose in `ls`, prune's
      `created_at` floor) silently degrades. This plan makes the record the
      recovery source of truth, so a silent no-record launch graduates from
      cosmetic to a restore gap. Scope deliberately minimal: print a one-line
      warning with the metadata path; the launch still proceeds (a missing
      record must not abort a working session). Found in the 2026-08-05
      architecture audit (finding A5); this plan is the right vehicle because
      it is the plan that raises the stakes.
- [ ] Full suite passes.

## Design

First of three (051 → 052 → 053) and the enabler for both: a snapshot with no
conversation_id is just a prettier version of the manifest that has to be
rebuilt by hand. Priority 5 puts the wave ahead of the audit backlog
(038-050, priorities 10-22) because each additional power event costs hours and
the machine is being moved.

**Why no fuzzy matcher for the 67.** Transcripts can only be re-matched by
cwd + timestamp, and that is not a key. In the 2026-08-03 manifest, 15 of the 39
live conversations shared one cwd (`~/dev/obsidian-vault`) and 8 of those had
last-active timestamps inside the same two-minute window. cwd+time cannot
separate them. A wrong `conversation_id` is strictly worse than a null one:
plan 053 would resume the wrong conversation under the right purpose label, and
nothing downstream would flag it. `null` + a documented limitation is the answer.
The 67 are also mostly historical records for sessions that are already dead;
the field starts being useful for everything launched after this ships.

**Refresh placement.** `_session_list` already computes `session_id`,
`transcript`, and `last_active_ms` for every row (cctrl:6086-6088), so the
refresh is a guarded write inside a loop that already has the values in hand —
no extra tmux calls, no extra process spawns. `_session_doctor` gets the same
guard so a `doctor` pass on a fleet that was never `ls`-ed still heals.

**Ordering trap.** `_session_write_metadata` is the only writer today and it
runs once per launch. Relaunching an existing session *name* rewrites the record
whole, which correctly resets `conversation_id` for the new conversation. The new
merge helper must not be used on the launch path for that reason.

**Files expected to change:**

- `cctrl`: `_session_write_metadata` (two new keys); new
  `_session_update_metadata_field`; `_launch_detached` post-launch poll and the
  resume-path write; refresh guards in `_session_list` and `_session_doctor`;
  new `_session_backfill_ids` + its `cmd_session` dispatch and help lines
- `README.md`: record field, `session backfill-ids`, the null limitation
- `tests/run-tests.sh`: merge-helper, backfill, and refresh tests
- `CHANGELOG.md`: Added entry

**Testing approach: E2E** — real binary, isolated fixture dirs, using the
existing fake-tmux/fake-ps technique. `CCTRL_CLAUDE_SESSIONS_DIR` (cctrl:52)
already overrides the per-PID Claude session directory, so `_session_id` can be
driven from a fixture file without a real agent.

**Out of scope:** any snapshot file (052); any restore (053); renaming the
existing `session_id` key in `ls --json`; fixing `_session_write_metadata`'s
bare `mktemp` (same cross-filesystem concern, pre-existing, separate change);
recovering the 67.

## Tasks

1. Add `conversation_id` and `transcript_path` to `_session_write_metadata`'s
   `jq -n` object (both nullable, `null` when empty).
2. Write `_session_update_metadata_field` with same-dir `mktemp` + `mv`, a
   parse-failure guard, and no-create-on-missing semantics.
3. Populate at launch: capture the resume id in `_launch_detached`'s
   `--resume|-r` arm (today it is pushed into `passthrough` and discarded),
   thread it to the metadata write, and add the bounded post-`new-session` poll
   for the fresh-launch path — **in a detached background subshell with stdio
   dropped (`</dev/null >/dev/null 2>&1 &`)**, so `_launch_detached` returns as
   fast as it does today AND its stdout closes immediately for command-
   substitution callers (`_remote_exec`, scripted spawns).
3b. Add the launch-time warning for a failed `_session_write_metadata` (all
   launches, not just `--peer`), per the AC above.
4. Add the change-guarded refresh to `_session_list` and `_session_doctor`
   (write only when the live value is non-empty and differs). In the same pass,
   collapse the six `_session_metadata_field` calls in the row loop into one
   `jq` read.
5. Fix `_active_session_count` (cctrl:1401) to `select(.managed)`, matching its
   own comment, and add the unmanaged-session regression test.
6. Add codex `conversation_id` derivation from `_session_codex_rollout_path`'s
   filename UUID — writing `null` whenever more than one rollout matches the cwd.
7. Implement `cctrl session backfill-ids [--dry-run] [--json]` with
   flag-anchored parsing and the three-count report; wire help + README.
8. Build the backfill fixture directory (filled / refused / already-set /
   unrecoverable records) so the counts are asserted against fixtures rather
   than the live `data/sessions/`.
9. Tests: the full list under the tests AC above. Run the full suite.

## Verification

Checks:

Check format note: the `[cmd]`/`[assert]` tag sits OUTSIDE the backticks. The
house style of wrapping the whole line (`` `[cmd] …` ``) leaves a stray backtick
in the parsed body, and `verify-lint.sh probe` then refuses every check as
`redirect-or-backtick` — verified: the entire existing backlog probes 0-of-N.
Tag-outside checks probe; expected strings in `[assert]` are left unbackticked
for the same reason.

- [cmd] `bash tests/run-tests.sh`
- [cmd] `grep -q "conversation_id:" cctrl`
- [cmd] `grep -q "_session_update_metadata_field" cctrl`
- [cmd] `grep -q "backfill-ids" cctrl`
- [assert] `cat README.md` contains conversation_id
- [assert] `./cctrl session backfill-ids --help 2>&1` contains --dry-run
- [cmd] `bash -c "grep -Eq '(--resume|-r)' <(sed -n '/_session_backfill_ids()/,/^}/p' cctrl)"` — backfill parses the flag, not a bare UUID (shell-dependent, so not probeable at authoring time)

<!-- mstack:seam
produced:
- kind: schema; name: conversation_id; file: data/sessions/*.json
- kind: symbol; name: _session_update_metadata_field; file: cctrl
- kind: command; name: session backfill-ids; file: cctrl
assumed:
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

**Changes folded into this plan:** the fresh-launch `_session_id` poll is backgrounded
(a synchronous 20s wait would have made every scripted spawn 20x slower and delayed the
`CCTRL_SESSION=` line at cctrl:1855); `_active_session_count` (cctrl:1401) is corrected to
`select(.managed)` so the guardrail, `cctrl fleet`, and 053's cap share one number; the
`38 / 0 / 67` acceptance count is replaced with fixture-based invariants after measuring
`35 / 0 / 70` on live data two days after the plan was written; the six per-session
`_session_metadata_field` jq calls in `_session_list` are collapsed into one (measured
1.06s for 10 sessions, and that loop is on the launch hot path); eight test gaps added,
including the ambiguous-codex-rollout case the plan argued for and never tested.

**CODEX:** Outside voice raised no finding specific to 051 beyond the launch-configuration
gap, which lands in 052/053.

**CROSS-MODEL:** No tension — Codex found what the review missed rather than contradicting
it. Both agree the flag-anchored backfill parse is correct and the `TMUX--ms--spawndryrun`
UUID-in-`cwd` false positive is real (re-verified 2026-08-05).

**VERDICT:** ENG CLEARED — ready to implement.

**FABLE AUDIT AMENDMENTS (2026-08-05, post-clearance):** an independent
cross-model audit (`docs/reviews/2026-08-05-fable-architecture-audit.md`,
findings F4/F6/A5) added three things after the eng verdict: (1) the
background poll must drop its inherited stdio or `_remote_exec`'s
`$(ssh …)` capture blocks on the open pipe for the full poll window —
the fd-redirect spec and a stdout-closes test are now ACs; (2) the
"benign last-writer-wins" concurrency claim is scoped to same-source
writers only, so the merge helper is not later reused for divergent
fields on an argument that doesn't cover them; (3) a failed metadata
write now warns on every launch instead of only `--peer` launches. No
prior AC was weakened. The `tmux new-session` citation in Requirements
was corrected 1835→1831 to match the AC's (already-correct) reference.

NO UNRESOLVED DECISIONS
