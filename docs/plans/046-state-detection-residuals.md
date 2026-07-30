---
id: 046
title: State-detection residuals — draft region, resume modal, pid trust, safe repair
status: pending
blocked-by: [041]
priority: 18
goal: revised-cctrl-audit-backlog
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-30
reviews:
  - type=eng verdict=approved date=2026-07-30 by=mstack-review
---

## Requirements

Plans 030/031 shipped but left residuals that keep fleet state untrustworthy —
verified live this week: 19 of 27 sessions reported `unsent-draft`, including
two sessions actually stuck on the session-resume modal (invisible to
`needs-me`, which watches `blocked-dialog`) and one empty-composer session
fooled by stale scrollback. Root causes, each in scope here:

1. `_session_pane_has_draft` matches `>`/`❯`-prefixed lines anywhere in the
   last 40 captured rows with a hint blocklist — echoed prompts, blockquotes,
   and dialog selector lines all match. (030 added `❯` support; the ASCII-`>`
   acceptance and whole-capture scan are the residual.)
2. The resume modal ("Resuming the full session will consume … Enter to
   confirm") has no `blocked-dialog` signature.
3. `_session_claude_pid` trusts the existence of `~/.claude/sessions/<pid>.json`
   with no liveness/argv check → PID reuse mis-binds, and a `kill -9`'d agent
   leaves `status: busy` frozen so the session reads `working` forever. No GC
   for orphaned pid files.
4. `doctor --fix`'s dead-bridge repair (`_session_repair_bridge`) sends `C-u`
   (erases a typed draft) then `/rc`, gated only on `busy` — autoheal's
   copy-mode + unsent-draft gates were never ported to it.
5. Five call sites still classify agents by full-argv substring
   (`[[ "$cmd" == *claude* ]]`) — in `_session_rc_state`, `_session_list`,
   doctor, and autoheal — the exact misfire class `_agent_from_cmd` (plan 031)
   was built to end: a prompt *mentioning* codex flips the classification.
   (The session-LISTING misfire already has a regression test — a claude
   command mentioning codex stays `"agent": "claude"` — the sweep targets the
   five remaining full-argv sites; keep that test green.)
6. `needs-me` unconditionally rewrites its snapshot baseline on every read, so
   any casual invocation silently resets the fleet manager's diff.

**Acceptance criteria:**

- [ ] Draft detection accepts only the `❯` glyph, only in the bottom input region of the capture (structure over blocklist: the hint blocklist is deleted); echoed `> text` prompts, markdown blockquotes, and `❯ 1.` selector lines no longer flag. The existing fixture set is extended: `tests/fixtures/pane-draft.txt` (real draft, exercised by the glyph test) already exists; new fixtures cover the three false-positive classes.
- [ ] Draft detection is scoped per-agent: `❯`-structure applies to claude panes only. Codex panes (whose composer doesn't use Claude's `❯`) either get their own composer signature (capture a codex fixture) or explicitly retain current behavior with a documented limitation — no silent blinding of codex draft detection.
- [ ] The resume modal classifies as `blocked-dialog` (new signature), so `needs-me` surfaces it. Fixture included.
- [ ] `_session_claude_pid` requires `kill -0 $pid` AND argv[0] basename ∈ known agents before trusting a bridge file; `session doctor` gains GC for orphaned pid files (dead pid or failed argv check) — report by default, remove under `--fix`.
- [ ] A pid.json `status: busy` with stale `updatedAt` (> configurable threshold, default 10 min) AND no transcript growth reads as unknown — mapped onto the EXISTING `-`/unknown rendering (base-state vocabulary today is working/idle/shell/`-`; no new state string is introduced, consistent with Out of scope).
- [ ] `doctor --fix` repair adopts autoheal's gates: skip on copy-mode, skip on (now-trustworthy) unsent-draft, skip on unverifiable capture. A draft is never erased by repair.
- [ ] The five substring classification sites route through `_agent_from_cmd` / token-wise `--remote-control` detection; a function-scoped sweep (awk over the bodies of `_session_rc_state`, `_session_list`, `_session_doctor`, `_session_autoheal`) finds no remaining `== *claude*` / `== *codex*` substring tests inside them. `_profile_model_for_agent` is explicitly excluded (legitimate model-name matching). The existing prompt-mentions-codex listing regression test stays green.
- [ ] `needs-me --peek` reads without writing the snapshot; default behavior unchanged; help documents it.
- [ ] Full suite passes; autoheal behavior unchanged (it only lends its gates).

## Design

One plan because these are six small fixes to a single detection layer with
shared fixtures — but tasks are strictly ordered so each lands independently
green. The draft-region rewrite (task 1) is the base: repair gating (task 5)
depends on drafts being trustworthy.

Bottom-region definition: the composer box is the last non-empty block of the
capture; scan only it. Adopt 041's `_pane_bottom_region` helper
unconditionally — 041 is a hard dependency (blocked-by) and owns that helper;
do not duplicate the region logic here.

**Files expected to change:**

- `cctrl`: `_session_pane_has_draft`, blocked-dialog signatures, `_session_claude_pid`, `_session_rich_state` staleness, `_session_repair_bridge` + doctor `--fix` gating, doctor pid-file GC, the five classification call sites, `cmd_needs_me` `--peek`
- `tests/run-tests.sh` + `tests/fixtures/`: extend the existing fixture set (`pane-draft.txt` already covers a real draft) with new echoed-prompt / blockquote / selector / resume-modal / codex-composer pane fixtures; pid-reuse and frozen-busy fixtures

**Testing approach: E2E** — fake-tmux + fixture panes + synthetic pid.json
files in an isolated sessions dir (`CCTRL_CLAUDE_SESSIONS_DIR`).

**Out of scope:** readiness inversion (041), new states, `fleet` header
metrics, any autoheal change.

## Tasks

1. Rewrite `_session_pane_has_draft`: `❯`-only for claude panes, bottom-region-only (adopt 041's `_pane_bottom_region`), delete the blocklist; scope detection per-agent — codex panes get their own composer signature (codex-composer fixture) or a documented retained-behavior limitation. Extend the existing fixture set (`pane-draft.txt` real draft exists) with the new echoed-prompt, blockquote, selector, and codex-composer fixtures.
2. Add the resume-modal `blocked-dialog` signature + fixture; confirm `needs-me` surfaces it.
3. Harden `_session_claude_pid` (kill -0 + argv check); add doctor pid-file GC (report / `--fix` remove).
4. Add frozen-busy staleness → `unknown` with threshold env override for tests.
5. Port autoheal's gates into the doctor `--fix` repair branch. Resolve the copy-mode contradiction explicitly: the gate wins — repair SKIPS on copy-mode, and the `tmux send-keys -X cancel` line (which force-exits copy-mode) is REMOVED from the `_session_repair_bridge` sequence.
6. Sweep the five remaining full-argv substring sites onto `_agent_from_cmd` (the session-listing misfire already has a regression test — a claude command mentioning codex stays `"agent": "claude"` — keep it green).
7. Add `needs-me --peek`; run the full suite.

## Verification

Checks:

- `[cmd] bash tests/run-tests.sh`
- `[cmd] bash -c 'body=$(awk "/^_session_(rc_state|list|doctor|autoheal)\\(\\) \\{/,/^\\}/" cctrl); ! grep -qE "== \\*(claude|codex)\\*" <<<"$body"'` — function-scoped sweep: only the bodies of `_session_rc_state`, `_session_list`, `_session_doctor`, `_session_autoheal` are searched, so `_profile_model_for_agent` (legitimate model-name matching) is excluded by construction
- `[assert] ./cctrl needs-me --help 2>&1 || ./cctrl help 2>&1` contains `peek`
- `[cmd] bash -c 'grep -q "Resuming the full session" tests/fixtures/*.txt'`
- `[cmd] bash -c 'fn=$(mktemp); awk "/^_session_pane_has_dialog\\(\\) \\{/,/^\\}/" cctrl > "$fn"; source "$fn"; _session_pane_has_dialog "$(cat tests/fixtures/pane-resume-modal.txt)"'` — functional check: the detector itself classifies the resume-modal fixture as a dialog (the fixture grep alone can pass without the detector working); running the new blocked-dialog test by name is an acceptable substitute

<!-- mstack:seam
produced:
- kind: flag; name: --peek; file: cctrl
assumed:
- from: 041; kind: symbol; name: _pane_bottom_region; file: cctrl
-->
