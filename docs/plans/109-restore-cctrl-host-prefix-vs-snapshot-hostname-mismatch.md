---
id: 109
title: "restore: CCTRL_HOST_PREFIX vs snapshot hostname mismatch makes plain restore exit 64 on the Studio"
status: blocked
blocked-by: []
priority:
goal: restore-cctrl-host-prefix-vs-snapshot-hostname-mismatch
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-10-27
---

## Plain-English Summary

<!-- Evidence captured 2026-10-27 by TMUX--ms--cctrl (wrap-up of the restore RAM-gate work), for the author to turn into the summary:
- On the Studio, `cctrl session restore --dry-run --json` exits 64: {"error":"snapshot hostname mismatch","snapshot_hostname":"ms-128g-bln","local_hostname":"ms"}.
- restore takes local_hostname from ${CCTRL_HOST_PREFIX:-$(hostname -s)}; the session shell has CCTRL_HOST_PREFIX=ms, while the snapshot records `hostname -s`.
- Same result on the previous release (0ce27fa), so it is older than 7566c4f. `--force-host` works around it (481 rows, ok:true).
- Matters after a Studio power cycle: the fleet manager's restore runbook would hit exit 64.
-->

In 2–4 sentences, explain the problem this plan solves and the outcome a
non-technical reader should expect. Avoid file paths, symbols, and framework
jargon here; those belong in Design.

**What changes in the code:** Explain in plain English which parts of the
application need to be added, changed, or removed and how those changes produce
the outcome above. This is an explanation of the implementation, not a list of
tasks or file paths.

## Requirements

What user-visible problem does this solve? One paragraph. Be concrete: which
endpoint, which screen, which user. If you can't name a user, the plan is too
abstract to run unattended. Break it down further.

**Acceptance criteria** (the autonomous worker treats these as the test
oracle, so be specific):

- [ ] ...
- [ ] ...
- [ ] ...

## Design

How will it work? Files expected to change. Schemas, types, contracts. Edge
cases the agent must handle. Anything that requires judgment goes here, not
in Tasks. Tasks is for execution; Design is for decisions.

**Files expected to change:**

- `path/to/file.ts`: what changes
- `path/to/other.ts`: what changes

**Out of scope:** name anything a sloppy agent might be tempted to also fix
but shouldn't.

## Tasks

Concrete, ordered execution steps. Each should be small enough to verify.

1. ...
2. ...
3. ...

## Verification

**Mandatory.** Every plan must have at least one executable check (`[cmd]`,
`[assert]`, or `[status]`). If you can't describe how to verify this plan
programmatically, it's not ready for autonomous execution. For purely visual
plans with no testable endpoints or commands, add `verification: health-only`
to the frontmatter.

Use the format `[type] description` where type is one of:
- `[cmd]`: run a shell command, assert exit code 0
- `[assert]`: run a command, assert output contains a string
- `[status]`: hit a URL, assert HTTP status code
- `[browse]`: browser-based check via gstack's /browse skill (requires gstack).
  Format: `[browse] <url-or-path> <assertion>`. The assertion is a natural
  language description of what to verify in the browser.
  Examples:
    - `[browse] /settings/billing verify 'Current Plan' heading is visible and shows a plan name`
    - `[browse] /dashboard verify the chart renders with at least one data point`
    - `[browse] /login verify the login form has email and password fields`
  If gstack is not installed, `[browse]` checks are skipped with a warning
  (they do not cause failures). Use `[browse]` for web-facing plans that
  need browser-level verification beyond API or file-existence checks.
- `[manual]`: note for human review (skipped in automation, does not count
  toward the mandatory executable check requirement)

Checks:
- ...

<!--
## Implementation Notes

Appended automatically by mstack-run on completion. Do not write this
section manually — it is generated from the subagent's result block.

Contains: summary of what was implemented, files changed (modified vs
created), and the implementation commit hash with message.
-->
