---
id: 055
title: Session name reconciliation and cctrl rename
status: pending
blocked-by: []
priority: 55
allows-migrations: false
needs-review: none
review-required: eng
reviews:
  - type=eng verdict=approved date=2026-08-23 by=agent
created: 2026-08-23
---

## Requirements

Session display names drift between cctrl metadata, tmux options, and
Claude Code's UI. A user can rename in Claude's desktop/iOS app (stored
as a `custom-title` line in the transcript JSONL), but cctrl never sees
it. Conversely, cctrl has no way to push a rename to Claude Code.

This plan adds:
1. A `cctrl rename` command that updates the display label everywhere
2. A reconciliation primitive the fleet manager calls on each sweep
3. Creation-time naming defaults so most sessions start with good names

Identity model: the tmux session name (`TMUX--ms--cctrl`) is an immutable
internal key. The display label (`.purpose` / Claude `custom-title`) is
the mutable human-facing name. This plan only touches the display label.

**Acceptance criteria:**

- [ ] `cctrl rename <session> "new label"` updates cctrl metadata `.purpose`, tmux `@cctrl_purpose`, and appends `custom-title` to the Claude Code transcript
- [ ] Transcript append is isolated behind a single function with verify-after-write
- [ ] `cctrl session reconcile-names` reads each Claude Code session's last `custom-title`, compares to `.purpose`, and corrects drift (Claude wins by default)
- [ ] `cctrl session ls` shows the reconciled display label, not just the original purpose
- [ ] Sessions created without `-n` get a sensible default label from the directory basename
- [ ] Codex sessions: rename updates cctrl metadata only (no naming surface)
- [ ] Fleet manager doctrine updated: name reconciliation runs as part of the existing sweep

## Design

### Two-layer identity

| Layer | Mutable? | Used for |
|-------|----------|----------|
| tmux session name | Immutable | Internal key: metadata files, peer addresses, remote-control prefix |
| Display label | Mutable | User-facing: `cctrl session ls`, Claude UI, fleet dashboard |

### `cctrl rename <session> "new label"`

1. Update `.purpose` in `data/sessions/<name>.json`
2. `tmux set-option -t <name> @cctrl_purpose "new label"`
3. For Claude Code: `_claude_set_display_name <session_id> "new label"`
   - Resolves transcript via `_session_transcript_path`
   - Appends `{"type":"custom-title","customTitle":"<label>","sessionId":"<uuid>"}`
   - Reads back last `custom-title` to verify the write took
   - Warns if verification fails (transcript may be locked or format changed)
4. For Codex: metadata only (step 1-2)

### `cctrl session reconcile-names`

For each live Claude Code session:
1. Read the last `custom-title` from the transcript (tail scan, not full parse)
2. Compare to cctrl metadata `.purpose`
3. If different: update `.purpose` and `@cctrl_purpose` to match Claude
4. Log corrections: `"Synced: TMUX--ms--obsidian purpose → 'Job: Vercel TAM'"`

Direction: **Claude wins silently; `cctrl rename` wins explicitly.** If the
user renames in Claude's UI, the next reconciliation pulls it into cctrl.
If `cctrl rename` pushed a name and the user later renames again in Claude,
the next reconciliation respects the user's most recent action.

### Creation-time naming

When `cctrl start` is called without `-n`, derive a default label from the
target directory basename (e.g. `cctrl` from `~/dev/cctrl`, not the full
`TMUX--ms--cctrl` slug). Pass this as both `.purpose` in metadata and the
display component of `--name`. Users can override with `-n "custom label"`.

### Fleet manager integration

Add to the fleet manager skill doctrine: on each sweep, call
`cctrl session reconcile-names --json` and include corrections in the
status report. No separate cron or daemon — rides the existing activity
cycle.

**Files expected to change:**

- `cctrl`: add `cmd_rename`, `_claude_set_display_name`, `_session_reconcile_names`, update `_session_ls` to show reconciled labels, update default purpose derivation in `cmd_start`
- `skills/cctrl-fleet-manager/SKILL.md`: add name reconciliation to sweep doctrine

**Out of scope:** renaming the tmux session name itself (immutable key),
Codex naming API (doesn't exist), bidirectional last-write-wins conflict
resolution.

## Tasks

1. Add `_claude_set_display_name` function — append `custom-title` to transcript, verify after write
2. Add `_claude_get_display_name` function — tail-scan transcript for last `custom-title`
3. Add `cmd_rename` — update metadata, tmux option, and Claude display name
4. Add `_session_reconcile_names` — iterate sessions, compare, correct drift
5. Wire `reconcile-names` into `cctrl session` subcommand dispatch
6. Update `_session_ls` to prefer reconciled display label over raw purpose
7. Update `cmd_start` to derive default purpose from directory basename when `-n` is not provided
8. Add `rename` to main `_dispatch()`
9. Update fleet manager skill doctrine with name reconciliation sweep step

## Verification

- [cmd] `cctrl rename --help` exits 0
- [cmd] `cctrl session reconcile-names --json` exits 0 and outputs valid JSON
- [assert] After `cctrl rename TMUX--ms--test "New Label"`, metadata `.purpose` contains "New Label"
- [assert] After rename of a Claude Code session, the transcript's last `custom-title` matches "New Label"
- [assert] After appending a custom-title to a transcript manually, `cctrl session reconcile-names` updates metadata `.purpose` to match
- [manual] Verify rename propagates to Claude desktop/iOS app via transcript sync

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 3 decisions resolved, 0 critical gaps |

**VERDICT:** ENG CLEARED — ready to implement.

NO UNRESOLVED DECISIONS
