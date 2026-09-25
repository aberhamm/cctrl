---
id: 072
title: Never report ready while a startup selector is waiting
status: done
completed: 2026-09-25
blocked-by: []
priority: 72
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-25
tui-fixture: required  # tests replay the real Claude and Codex dialog screens through the fake-tmux readiness harness
approved-by: matthew (chat, 2026-09-25): queued after plan 070 step C
reviews:
  - type=eng verdict=approved date=2026-09-25 by=mstack-review
---

## Plain-English Summary

`cctrl start -d --agent claude` printed "✓ session ready" three times on 2026-09-24 while Claude Code was actually stuck on an unnumbered startup dialog:
- the new folder-trust prompt, on first launch in `~/dev/tiktok-remotion`
- "Allow external CLAUDE.md file imports?", twice, in obsidian-vault subfolders

The readiness check took the dialog's `❯ No, …` option line for the composer prompt. Nothing typed into the session would arrive. Worse, the default option in the folder-trust dialog is `No, exit`, which kills the session.

## Cause (confirmed by reading the code)

- `_hc_prompt_visible` (lib/health-check.sh:48-52) only treats a numbered selector (`❯ 1.`) as a modal. So the "any `❯` or `›` line" rule matches `❯ No, exit` and `❯ No, disable external imports`.
- The pattern table (lib/health-check-patterns.sh) knows only the older numbered forms (`Do you trust the files`, `❯ 1. Yes`, `Continue from a previous`). It has no entry for either dialog.
- The same table drives `_session_pane_has_dialog` and peer-delivery readiness. A peer message could therefore be pasted into one of these dialogs.
- **Codex.** 0.153.4 shows "Do you trust the contents of this directory? … Yes, continue" as a numbered `›` selector with a "Press enter to continue" footer. The numbered rule keeps it from counting as ready, but nothing names it, so the check only times out instead of reporting needs-human.

## Requirements

- [x] A pane showing a known startup dialog, or a selector footer, is never ready. The footers are Claude's "Enter to confirm · Esc to cancel" and Codex's "Press enter to continue".
- [x] Each known dialog is reported as `needs-human` with the dialog named in `health_reason`:
  - `folder-trust`
  - `external-imports`
  - `codex-directory-trust`
  - `startup-selector` for an unrecognised selector
- [x] The needs-human message and `health_info` say which option keeps the session, because the default choice is the destructive or deny one.
- [x] Import dialogs and Codex directory trust are never auto-answered.
- [x] Claude's folder-trust dialog is answered "Yes, I trust this folder". Matthew decided this on 2026-09-25. The check moves the selection down and presses Enter only once the screen shows "Yes" selected; otherwise it reports needs-human.
- [x] `_session_pane_has_dialog` and peer-delivery readiness see the same dialogs, because they share the table.
- [x] Tests replay the real screen text from the three incidents, plus the Codex trust screen.

## Tasks

1. `lib/health-check-patterns.sh`:
   - Add needs-human entries for the Claude folder-trust dialog, the Claude external-imports dialog, and the Codex directory trust dialog.
   - Add a generic `startup-selector` entry for each agent's selector footer.
   - Add a parallel `HC_HINT` array holding the option that keeps the session.
   - Specific entries go before the generic ones.
2. `lib/health-check.sh`:
   - `_hc_prompt_visible` also returns "not ready" when a selector footer is on screen.
   - The needs-human path prints the hint and records it in `health_info` when there is no extracted URL.
3. Tests in `tests/run-tests.sh`: the real screens for all three incidents, the Codex trust screen, and checks that the pattern table reaches `_session_pane_has_dialog`.

## Not in scope

- `session ls` showing rc `dead` while the dialog is up. The bridge is not registered until the dialog is answered, so this is a symptom, not a separate bug.
- The existing `workspace-trust` auto-dismiss entry for the old numbered dialog (`Do you trust the files`, `❯ 1. Yes`). It presses Enter, and that dialog's default is "Yes". Whether cctrl should keep auto-answering even that is Matthew's call.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 2 issues, 0 critical gaps |
| Outside voice | Claude subagent (Codex out of credits) | Independent 2nd opinion | 1 | issues_found | 2 findings on 072, both confirmed; neither blocks |

Reviewed on 2026-09-25, at bd95d5b: the plan, 7344ad4, and bd95d5b (folder-trust auto-select). The `health-check` focused group passes, and it replays the real incident screens. The auto-select presses Enter only after the screen shows "❯ Yes, I trust this folder" selected. There is a test for that, and a test that nothing is pressed when the selection never lands. None of the new dialogs is auto-answered with Enter blindly.

Follow-ups (not blocking):
- **[P2] The patterns also match text above the visible screen.** The health check captures `-S -40` (`lib/health-check.sh:119`) and peer delivery `-S -15` (`cctrl:5701`). The new generic patterns (`Enter to confirm|Esc to cancel`, `Press enter to continue`, `Yes, I trust this folder`) are ordinary phrases, so a transcript that quotes them can:
  - block peer delivery;
  - mark the session `blocked-dialog`;
  - after bd95d5b, send up to 6 `Down` keys into a resumed composer. Enter is never pressed.
  Anchor the footer matches to the dialog chrome, or match against the visible screen only. Add a test with prose that must not match.
- **[P3] An unrecognised numbered selector is answered with Enter instead of being reported.** The old `Continue from a previous|❯ 1\.` auto-dismiss entry (`lib/health-check-patterns.sh:27`) catches any numbered selector first, so it never reaches the `startup-selector` entry. This behaviour predates the plan, which put it out of scope under "Not in scope".

VERDICT: ENG CLEARED.

NO UNRESOLVED DECISIONS
