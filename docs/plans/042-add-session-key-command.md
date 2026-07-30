---
id: 042
title: Add session key — safe keystroke driving for dialogs and pickers
status: pending
blocked-by: [041]
priority: 14
goal: revised-cctrl-audit-backlog
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-30
reviews:
  - type=eng verdict=approved date=2026-07-30 by=mstack-review
---

## Requirements

The fleet-manager doctrine makes "drive tmux pickers, choose build/plan
options" a manager job, but cctrl has no verb for it — operators hand-roll
`tmux send-keys`, inheriting prefix-matching, wrong-pane, and no-verification
hazards. `session say` correctly *refuses* when a modal is up (041); there is
no sanctioned way to answer that modal. `session key` is the complement with
the opposite gate: it acts **only** when a modal/picker is positively present.

**Acceptance criteria:**

- [ ] `cctrl session key <name> [--expect STRING] [--force] [--json] -- <key>` sends exactly one allowlisted key: `Enter`, `Esc`, `Up`, `Down`, `Tab`, or a single digit `1`-`9`.
- [ ] Keys outside the allowlist are rejected; `--raw <keyspec> --force` is the only escape hatch, and its help text names the risks (`C-u` erases drafts, `C-c` interrupts a working agent).
- [ ] Modal gate: the command refuses (non-zero) unless the pinned pane's **bottom region** positively matches a known dialog/picker shape (041's detector). `--force` overrides the modal-presence gate ONLY — it NEVER waives `--expect`: when `--expect` is given it must always be satisfied, `--force` or not. Requiring `--expect` whenever `--force` is used is the recommended (and implemented) posture.
- [ ] `--expect STRING` adds a precondition: the bottom region must contain STRING or the command refuses without sending — scrollback above the bottom region must NOT satisfy it (stale-text defense). The match runs against a `capture-pane -J` capture (wrapped lines joined) so an expect string can't be split by a soft wrap.
- [ ] Audit trail: every keystroke send (including refusals after the gate, and `--force`/`--raw` uses) appends one line — who/target/key/expect/result — via the existing `_autoheal_log` pattern to a predictable log, so post-incident "who pressed Enter on which dialog" is answerable.
- [ ] The pane is captured before and after the keystroke; `--json` returns `{before, after, changed}` excerpts so the caller can confirm the dialog advanced. A human-readable diff summary prints in the non-JSON path.
- [ ] Uses the 039 substrate: exact-match session, pinned pane, copy-mode refusal.
- [ ] Tests cover: allowlist rejection, modal-gate refusal on an idle composer, `--expect` mismatch, `--expect` matched only in scrollback (refused), `--force` with a failing `--expect` (refused — force does not waive expect), successful Enter on the resume-modal fixture with before/after diff, and the audit-log line for a send.

## Design

Three verbs, three intents, mutually exclusive gates: `say` = text into an
idle composer (refuses modals), `key` = one keystroke into a present modal
(refuses idle composers), `ask` (043) = composed request/response. Keep `key`
strictly a keystroke tool — no text argument, ever; text belongs to `say`.

Bottom-region scoping for `--expect` is the load-bearing safety property
(reviewer finding): a matching string in scrollback must not arm the command,
and the gate + capture + send should reuse one capture where possible to keep
the TOCTOU window at one round trip. Captures for the `--expect` match use
`capture-pane -J` (join wrapped lines) as the primary defense against expect
strings spanning a soft wrap; short expect strings remain good practice but
are not the mechanism. The `changed` comparison is bottom-region-only, and
spinner/clock redraws can false-positive it — the JSON carries both excerpts
precisely so the caller judges, not the flag alone.

Pressing dialog buttons can equal granting permissions. That policy lives in
the fleet-manager doctrine (plan 047), not in this command — but the help text
must say so.

**Files expected to change:**

- `cctrl`: new `_session_key` (session-verb convention, like `_session_say` / `_session_doctor`) + dispatcher case + help lines + audit logging via the `_autoheal_log` pattern
- `tests/run-tests.sh`: the gate/expect/diff tests against the 041 fixtures

**Testing approach: E2E** — fake-tmux harness with pane fixtures.

**Out of scope:** multi-key sequences/macros, text input, any auto-answer
policy, driving pickers by label (future sugar).

## Tasks

1. Implement `_session_key`: pin pane (039), capture with `-J`, evaluate modal gate + `--expect` against the bottom region, validate key against the allowlist; `--force` bypasses only the modal gate, never `--expect` (and require `--expect` alongside `--force`).
2. Send via `send-keys` to the pinned pane; capture again; emit before/after/changed (bottom-region comparison).
3. Add `--raw --force` path with explicit warning text.
4. Append the audit line (who/target/key/expect/result) per send via the `_autoheal_log` pattern.
5. Dispatcher + `cctrl session --help` + top-level help entries.
6. Tests as listed in acceptance criteria.
7. Run the full suite.

## Verification

Checks:

- `[cmd] bash tests/run-tests.sh`
- `[assert] ./cctrl session --help 2>&1` contains `key`
- `[assert] ./cctrl session key 2>&1 || true` contains `Usage`

<!-- mstack:seam
produced:
- kind: symbol; name: _session_key; file: cctrl
assumed:
- from: 041; kind: symbol; name: _pane_bottom_region; file: cctrl
- from: 041; kind: symbol; name: _peer_pane_ready_for_delivery; file: cctrl
-->
