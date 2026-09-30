---
id: 096
title: Wire the fleet approvals contract into cctrl-spawn and cctrl-fleet-manager skill docs
status: done
completed: 2026-09-30
blocked-by: []
priority: 96
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-30
tui-fixture: n/a  # docs-only, no TUI surface touched
approved-by: matthew (mdec-0930-cctrl item 4 design + mdec-0930b-cctrl-approvals-rollout, via fleet-primary/fm-cctrl)
reviews:
  - type=eng verdict=approved date=2026-09-30 by=sonnet-subagent
---

## Plain-English Summary

Matthew approved a fleet-wide "approvals" design (mdec-0930-cctrl item 4,
13:45Z 2026-09-30): a shared, append-only, orchestrator-only-written file
(`~/.local/state/fleet/approvals.md`) that lets a worker verify a
scope-widening pasted follow-up before acting on it, instead of trusting the
pasted text on its own. The rollout for cctrl specifically
(`mdec-0930b-cctrl-approvals-rollout`) is: wire the doctrine into the two
skill docs that already govern how briefs are written and how fleet managers
operate, so every future seed brief carries the contract by default.

## Authorization

This work (and the push below) is covered by grant
`mdec-0930b-cctrl-approvals-rollout` in `~/.local/state/fleet/approvals.md`:
scope `repo: ~/dev/cctrl`, `session: TMUX--ms--fm-cctrl (epoch 1790538167)
and one worker it spawns for this`, action = exactly this doc change via
plan/review/suite/one push/gated install, limit = no other cctrl changes in
the same push. Verified before implementing and again before pushing:
`grep -Fx -A12 'id: mdec-0930b-cctrl-approvals-rollout'
~/.local/state/fleet/approvals.md` — type `grant`, no matching `revokes:`
entry anywhere in the file, `expires_utc: 2026-10-01T13:52:00Z` (not
expired). This session (`TMUX--ms--cctrl--2`, epoch 1790769631 per
`cctrl session current --json` and `tmux display -p`) matches the grant's
"one worker it spawns for this" scope, and was assigned this task directly
by `fm-cctrl`.

## Change

- `skills/cctrl-spawn/SKILL.md`: added a bullet under the brief-writing
  guidance (step 3, "A good brief states...") requiring every seed brief to
  include the APPROVALS block verbatim.
- `skills/cctrl-fleet-manager/SKILL.md`: added an "Approvals file" paragraph
  right after "Briefs are the only guardrail" (before the Autonomy model
  section), covering: orchestrator is the sole writer; FMs cite ids, never
  write the file; default/required 24h expiry; session scope = name +
  `session_created` epoch; narrowing/stopping follow-ups need no id.
- Both edits are generic doctrine only — no hostnames, no session names
  beyond the pattern examples already in each file, matching both files'
  existing "generic doctrine, no environment specifics" framing. The
  `~/.local/state/fleet/approvals.md` path is a convention path, not an
  environment specific (same category as the existing
  `~/.local/bin/cctrl`-style paths already in these docs).

## Verification

- `test_peer_contract_docs` and the other doc-presence lints in
  `tests/run-tests.sh` (~line 13251-13258) check `README.md`, `AGENTS.md`,
  and specific pre-existing strings in these same two SKILL.md files for
  unrelated content (`--app-owned`, the provider-neutral task-ls mention,
  the app-task peer-messaging deferral) — none of those strings were
  touched, and none of them scan for new content, so this addition can't
  regress them. Ran the full suite anyway per the brief (doc changes can
  still break a content lint elsewhere).
- Full suite, one run (`LANG=en_US.UTF-8 bash tests/run-tests.sh`): RC=0,
  171 `ok:`, no `FAIL`, plus `python3 -m unittest discover` 100 tests OK.

## Eng review (Sonnet — usage-throttle directive substituted Sonnet for Opus
on this docs-only change)

**Approved.** Genericness clean (no hostnames/IPs/real session names;
`~/.local/state/fleet/approvals.md` is a convention path like the existing
`~/.local/bin/cctrl` references). Placement/flow correct in both files
(list-item nesting in cctrl-spawn confirmed correct — the blockquote
continuation indents as part of the same list item). No lint currently
touches either changed region. Two non-blocking polish suggestions, filed
as follow-ups below rather than fixed, per the usage-throttle directive to
keep this change minimal.

## Follow-ups (not blocking, filed here)

- `cctrl-fleet-manager/SKILL.md`: the pre-existing "Briefs are the only
  guardrail" header now sits directly above a paragraph introducing a
  second, different guardrail (approvals.md authenticity vs. brief-written
  authorization) — consider a one-word tweak so the header doesn't read as
  contradicted.
- `cctrl-spawn/SKILL.md`: `<\pasted_content>` in the APPROVALS block is
  non-standard Markdown escaping (works today only incidentally). Consider
  wrapping it in backticks: `` `<pasted_content>` ``.
