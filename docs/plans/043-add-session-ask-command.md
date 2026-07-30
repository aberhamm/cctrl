---
id: 043
title: Add session ask — nonce-correlated send, wait, and read-back
status: pending
blocked-by: [041]
priority: 15
goal: revised-cctrl-audit-backlog
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-30
reviews:
  - type=eng verdict=approved date=2026-07-30 by=mstack-review
---

## Requirements

There is no packaged way for one session (or the fleet manager) to ask a
running Claude session something and read the answer. Today the caller must:
`session say`, poll `session ls --json` state — which races (immediately after
send, the target's pid.json still says `idle` and the transcript's last turn is
the *previous* answer, so a poller reads a stale `idle-done` and the wrong
reply) — then hand-parse the transcript JSONL. `session ask` packages
send → wait → read as one verb with **nonce correlation** so it can never
attribute the wrong turn (reviewer finding: transcript-flush lag, concurrent
human typing, and prompt paraphrasing all break echo-matching; a nonce
doesn't).

**Acceptance criteria:**

- [ ] `cctrl session ask <name> [--timeout SECS] [--json] -- <question>` sends the question via the hardened say path with an embedded marker line (e.g. `[cctrl-ask <8-hex-nonce>]`), waits, and prints the assistant's answer text.
- [ ] Correlation is nonce-based: the command locates the transcript **user** turn containing the nonce (this doubles as delivery confirmation), then waits until the idle-gated turn-completion predicate holds (finished assistant message AND bridge status idle), and extracts the **LAST finished assistant text after the nonce turn** — NOT the literal "next assistant entry": a single logical turn produces multiple assistant JSONL entries interleaved with tool_result lines (this is why `_session_transcript_last_turn` has an `assistant-empty` class), so a next-entry reading would return the tool-use preamble ("Let me check that.") instead of the answer. A within-turn tool-use interleave fixture (assistant preamble → tool_use → tool_result → final assistant answer) is mandatory in the tests. The nonce is matched against user-turn TEXT content only — transcript lines with role `user` include tool_result entries, and those must never match.
- [ ] Transcript path comes from the existing per-session resolution (`_session_transcript_path`), **re-resolved on every poll**; if the sessionId/path changes mid-ask (a `/clear` or restart mints a new sessionId), fail with a distinct `transcript-replaced` status rather than a misleading timeout. (Compaction appends to the same file and is fine.) Polling tails from the pre-send file offset — never re-reads the whole file per poll.
- [ ] Claude sessions only in v1: a non-Claude target fails fast with `unsupported agent` (Codex transcripts differ; noted as future work).
- [ ] Failure modes are distinct, non-zero, and named: `send-failed` (say refused/unverified), `not-echoed` (nonce never appeared before timeout — delivery uncertain, do NOT blindly resend), `no-answer` (echoed but no completed assistant turn in time; report elapsed and that the target may still be working), `transcript-replaced` (see above). `not-echoed` and `no-answer` error text tells the caller what to do next: inspect the pane, use `session key` if a dialog appeared, or deliberately re-run the ask — never an automatic resend ("retry delivery" is mailbox vocabulary that does not apply here; nothing is queued). Timeout output includes the target's current rich-state so "still working" is distinguishable from "stuck on a dialog". If the transcript file does not exist yet at send time (fresh session), the pre-send offset is 0 and the poll waits for the file to appear within the deadline; a file that never appears reports `not-echoed`.
- [ ] `--timeout` defaults to 300s, enforced by a deadline loop computed via `date +%s` — macOS has NO `timeout(1)` binary (repo learning; cctrl's own `_tmux_run_with_timeout` is a hand-rolled loop). The poll pipeline is pipefail-safe: jq/grep nonzero exits and SIGPIPE are guarded under `set -euo pipefail`. `--json` returns `{status, answer, nonce, elapsed_s, transcript}`.
- [ ] Concurrent-noise test: a user turn WITHOUT the nonce plus an unrelated assistant turn appear after send; `ask` must skip them and bind to the nonce-bearing exchange.
- [ ] A `no-answer` timeout leaves the target session untouched (no interrupt, no retry).

## Reviewer note

The marker line rides inside the prompt body, so the asked agent sees it.
That is acceptable (agents already see `[cctrl]` nudge lines); the marker must
be short, on its own line, and documented in the command help so briefs can
tell agents to ignore it.

## Design

Implementation is a poll loop (0.5s interval) over the transcript file from a
recorded byte offset, parsing only appended lines as JSONL. Note there is NO
reusable turn-completion predicate in rich-state today: `_session_rich_state`
classifies only the last turn of the whole file via
`_session_transcript_last_turn` (`tail -n 50 | jq`). And no byte-offset tail
pattern exists anywhere in cctrl (all transcript reads are `tail -n N`) — the
offset mechanism is new. So this plan BUILDS a turn-completion predicate over
appended JSONL lines, reusing `_session_transcript_last_turn`'s jq
classification logic as raw material (finished assistant message + pid.json
`status == idle`), and may optionally re-point rich-state's idle-done
detection at it afterwards.

`ask` composes existing pieces: 039 pinning, 040 verification (send leg), 041
readiness (refuses to ask a session showing a modal — the refusal surfaces
041's readiness vocabulary; note today `session say` returns status `busy`
with a modal reason, and the `blocked-dialog` surface only arrives with plan
041). Either way the caller learns to use `session key` first.

**Files expected to change:**

- `cctrl`: new `_session_ask` + dispatcher + help; new turn-completion predicate built from `_session_transcript_last_turn`'s classification logic (optionally reused by rich-state)
- `tests/run-tests.sh`: fixture transcripts (nonce echo, interleaved noise, timeout paths)

**Testing approach: E2E** — fake-tmux harness + synthetic transcript JSONL
fixtures appended during the test to simulate the live session, placed under a
`CCTRL_CLAUDE_PROJECTS_DIR` fixture override (the existing, test-proven
transcript-fixture override).

**Out of scope:** Codex-target support, multi-turn conversations, automatic
retry/resend, `peer` mailbox integration (asks are synchronous by design;
the mailbox remains the async channel).

## Tasks

1. Build a turn-completion predicate over appended JSONL lines, reusing `_session_transcript_last_turn`'s jq classification logic as raw material (there is no existing reusable predicate to extract, and no byte-offset tail pattern in the codebase — the offset mechanism is new); optionally re-point rich-state's idle-done detection at it.
2. Implement `_session_ask`: nonce generation, offset snapshot, hardened send, poll loop with the three-phase wait (nonce user turn → completed assistant turn → idle), re-resolving `_session_transcript_path` each poll.
3. Implement the named failure modes (`send-failed`, `not-echoed`, `no-answer`, `transcript-replaced`) + `--json`.
4. Dispatcher + help entries (document the marker line).
5. Tests: happy path, noise interleave, within-turn tool-use interleave (preamble → tool_use → tool_result → final answer; ask must return the final answer), `not-echoed`, `no-answer`, `transcript-replaced`, fresh-session missing-transcript offset-0, non-Claude refusal, modal refusal.
6. Run the full suite.

## Verification

Checks:

- `[cmd] bash tests/run-tests.sh`
- `[assert] ./cctrl session 2>&1 || true` contains `ask`
- `[assert] ./cctrl session ask 2>&1 || true` contains `Usage`

<!-- mstack:seam
produced:
- kind: symbol; name: _session_ask; file: cctrl
assumed:
- from: 041; kind: symbol; name: _peer_pane_ready_for_delivery; file: cctrl
-->
