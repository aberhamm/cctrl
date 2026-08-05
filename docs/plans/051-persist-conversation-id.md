---
id: 051
title: Persist conversation_id on the session record
status: blocked
blocked-by: []
priority: 5
goal: fleet-restore-after-power-loss
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-08-03
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
   `tmux new-session` at cctrl:1835. At write time the agent process does not
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
- [ ] Backfill reports three counts: filled, already-set, unrecoverable. The
      expected first run on the current data set is 38 filled / 0 already-set /
      67 unrecoverable.
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
      unchanged.
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
   for the fresh-launch path.
4. Add the change-guarded refresh to `_session_list` and `_session_doctor`
   (write only when the live value is non-empty and differs).
5. Add codex `conversation_id` derivation from `_session_codex_rollout_path`'s
   filename UUID.
6. Implement `cctrl session backfill-ids [--dry-run] [--json]` with
   flag-anchored parsing and the three-count report; wire help + README.
7. Tests: merge helper preserves keys / skips malformed; backfill fills `-r`
   and rejects the `-m` false positive; refresh writes once on change, never on
   no-change. Run the full suite.

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
