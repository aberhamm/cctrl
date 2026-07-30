---
id: 039
title: Harden tmux pane targeting with exact-match sessions and pinned panes
status: pending
blocked-by: []
priority: 11
goal: revised-cctrl-audit-backlog
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-30
reviews:
  - type=eng verdict=approved date=2026-07-30 by=mstack-review
---

## Requirements

Every tmux operation in cctrl addresses sessions by bare name (`-t "$sess"`),
which tmux resolves by **prefix match**: once `TMUX--ms--homelab` is dead,
`-t TMUX--ms--homelab` silently resolves to `TMUX--ms--homelab--2`. That means
`session say` can paste into the wrong session and `session kill`/`close` can
kill the wrong session. Two of those kill sites are hidden from a naive grep:
`session close` schedules its delayed kill via
`tmux run-shell -b "sleep $grace; tmux kill-session -t $target_q"`
(string-embedded), and `_session_realign` runs its own
`tmux kill-session -t "$name"`. Separately, `capture-pane -t "$sess"` and
`paste-buffer -t "$sess"` both resolve to the session's *active* pane — those
two already agree. What diverges is first-pane inference: `_session_agent_cmd`
and `_session_claude_pid` read `tmux list-panes -t "$sess" ... | head -1`
(the **first** pane), as do the `pane_current_path` reads — so in a split
session, the agent/PID that feeds readiness policy comes from the first pane
while the paste lands in the active pane. Finally, neither `_session_say` nor
`_peer_pane_ready_for_delivery`
checks `#{pane_in_mode}`, so text pasted into a copy-mode pane is silently
swallowed while the command reports `ok` (the codebase knows this hazard:
rich-state skips capture in copy-mode, autoheal gates on it, repair sends
`-X cancel` first — only the primary send paths lack the gate).

**Acceptance criteria:**

- [ ] A single helper (e.g. `_tmux_pin_pane <session>`) resolves a session by exact match (`-t "=$sess"`) and returns the active pane's `%pane_id`; it fails non-zero with a clear error when the exact name does not exist.
- [ ] The say/deliver/capture paths — `_session_say`, the peer nudge paste path (`_peer_deliver_one_locked` / `_peer_pane_ready_for_delivery`), and the state-detection capture helpers — address tmux through that helper: one pinned `%pane_id` per command invocation, used for BOTH the readiness capture and the paste/send-keys. `session kill`, `session close`, and `has-session` checks need only `=`-exact session names (`kill-session` takes a session name, not a pane) — do not force pane-pinning there.
- [ ] All remaining `has-session` / `kill-session` / `send-keys` / `paste-buffer` / `capture-pane` call sites use `=`-exact session targeting — including the `_tmux_run_with_timeout has-session`/`kill-session` wrapped forms, `session close`'s string-embedded delayed kill (`tmux run-shell -b "sleep ...; tmux kill-session -t ..."`), and `_session_realign`'s `kill-session -t "$name"` (audit with `grep -n 'tmux .*-t "' cctrl` plus `grep -nE '_tmux_run_with_timeout (has-session|kill-session)' cctrl`).
- [ ] With sessions `foo--2` live and `foo` dead, `cctrl session say foo -- hi` and `cctrl session kill foo` both fail with "no such session" instead of acting on `foo--2` (regression test with the fake-tmux harness).
- [ ] `_session_say` refuses (non-zero, distinct `copy-mode` error naming the fix) when the pinned pane has `#{pane_in_mode}` = 1; `peer deliver` classifies the same condition as `deferred` rather than pasting.
- [ ] A pane-split fixture (two panes, first pane inactive and running a different agent command) shows readiness policy following the pinned (active) pane's agent, not the first pane's — i.e. the wrong-agent-inference bug (`_session_agent_cmd`/`_session_claude_pid` reading pane 1 while pasting into the active pane) is closed.
- [ ] Full test suite passes; `peer send` without delivery remains byte-identical.

## Design

This is the substrate plan for the driving-reliability wave: plans 040
(paste verification), 041 (readiness inversion), 042 (`session key`), and 043
(`session ask`) all build on the pinned-pane helper, so its contract comes
first and stays minimal: *resolve exactly, pin once, gate copy-mode*.

Resolution order inside the helper: `tmux display-message -p -t "=$sess"
'#{pane_id} #{pane_in_mode}'` scoped to the session's active pane gets both
facts in one round trip. Callers receive the pane id and the mode flag;
policy (refuse vs defer) stays in the caller since `say` and `deliver` need
different failure vocabularies.

Failure-reporting contract: the helper's not-ready / no-session outcomes flow
through the existing reason variables — `PEER_DELIVER_READY_REASON` on the
deliver path, and the say path's `SESSION_SAY_REASON` / `_session_say_json`
status-word + distinct-exit-code convention. No new error channel.

Do NOT change readiness *semantics* here (what counts as a modal) — that is
plan 041. This plan only guarantees we look at and type into the same, correct
pane, and never type into copy-mode.

**Files expected to change:**

- `cctrl`: new `_tmux_pin_pane` helper; call-site updates in `_session_say`, `_peer_pane_ready_for_delivery`, `_peer_deliver_one_locked`, `_session_kill` / `cmd_session` close paths (incl. the `run-shell -b` delayed kill), `_session_realign`, `_session_agent_cmd` / `_session_claude_pid`, `_session_pane_has_draft` and sibling capture helpers
- `tests/run-tests.sh`: fake-tmux harness upgrade (name resolution + pane model), prefix-match regression test, copy-mode refusal/deferral tests, split-pane wrong-agent fixture

**Testing approach: E2E** — real `cctrl` binary against the fake-tmux harness
in an isolated `CCTRL_DATA_DIR`.

**Out of scope:** modal-signature changes (plan 041), post-paste verification
and buffer naming (plan 040), any change to what `deliver` pastes.

## Tasks

1. Extend `make_fake_tmux` in `tests/run-tests.sh` first: tmux-like name resolution (bare names prefix-match, `=name` is exact) and a minimal pane model (`%pane_id`, `pane_in_mode`). Update existing tests that set `TMUX_FAKE_HAS_SESSION` to accept `=`-prefixed targets once cctrl emits them. Without this the promised prefix-match regression test passes before the fix (false green — today's fake does exact word-matching, so `foo` never resolves to `foo--2`).
2. Implement `_tmux_pin_pane` (exact-match resolve → active `%pane_id` + `pane_in_mode`, non-zero on no exact session).
3. Convert `_session_say` to pin once and reuse the pane id for readiness capture and paste; add the copy-mode refusal.
4. Convert the peer delivery path (`_peer_pane_ready_for_delivery`, `_peer_deliver_one_locked`) the same way; copy-mode → `deferred`.
5. Sweep remaining `-t "$sess"` call sites to `=`-exact targeting: `session kill`, `has-session` (including every `_tmux_run_with_timeout has-session` site), state helpers, `session close`'s string-embedded `run-shell -b "sleep ...; tmux kill-session -t ..."` delayed kill, and `_session_realign`'s `kill-session -t "$name"`.
6. Add the fake-tmux tests: prefix-match regression, copy-mode paths, split-pane wrong-agent-inference fixture.
7. Run the full suite.

## Verification

Checks:

- `[cmd] bash tests/run-tests.sh`
- `[assert] grep -c 'tmux kill-session -t "=' cctrl` contains `1` (at least the kill path is exact)
- `[cmd] bash -c '! grep -nE "(has-session|kill-session) -t \"?\\$" cctrl'` — matcher keys on the subcommand, not the `tmux` prefix, so it also catches `_tmux_run_with_timeout has-session`/`kill-session` wrapped sites and the string-embedded `run-shell` delayed kill (`-t $target_q`, no quote)
- `[cmd] bash -c 'h1=$(shasum data/messages.jsonl 2>/dev/null || echo absent); bash tests/run-tests.sh >/dev/null 2>&1; h2=$(shasum data/messages.jsonl 2>/dev/null || echo absent); [ "$h1" = "$h2" ]'`

<!-- mstack:seam
produced:
- kind: symbol; name: _tmux_pin_pane; file: cctrl
assumed:
-->
