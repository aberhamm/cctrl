---
id: 009
title: Add direct tmux session say command
status: pending
blocked-by: []
priority: 9
goal: tmux-peer-direct-chat
allows-migrations: false
needs-review: none
created: 2026-06-14
---

## Requirements

Users often want to talk to a live agent that is already running in tmux.
Today the peer mailbox is documented as the main communication path, even
though a direct tmux chat message is simpler for active sessions. Add a
concrete session-level command that pastes a message into a named tmux session
and optionally submits it, without creating mailbox state.

**Acceptance criteria:**

- [ ] `cctrl session say <session> -- "message"` pastes the exact message into the target tmux session and submits it with Enter by default.
- [ ] `cctrl session say <session> --no-submit -- "message"` pastes the message but does not press Enter.
- [ ] `cctrl session say <session> --body-file PATH` and `--body-file -` preserve multi-line message bodies, including trailing newlines.
- [ ] `cctrl session say <session> --json -- "message"` returns machine-readable success/failure data with at least `ok`, `session`, `submitted`, and `status`.
- [ ] Missing tmux, unknown sessions, empty bodies, body-file read failures, tmux load/paste/send failures, and known Claude/Codex modal prompts produce clear errors and non-zero exits.
- [ ] JSON failures use explicit statuses; a known modal prompt returns `ok:false` with `status:"busy"` and a non-zero exit.
- [ ] Known modal prompts are never overridden by `--force-busy`; `--force-busy` only permits pasting when readiness is unknown or cannot be inferred.
- [ ] The command does not read or write peer mailbox files and does not mutate message nudge metadata.

## Design

Add a `say` subcommand under `cctrl session`, backed by the existing tmux
timeout and paste helpers used by peer delivery. Keep the command session-first:
it accepts a tmux session name, validates that tmux can see it, reads the body
from either `-- <message>` or `--body-file PATH|-`, then uses a tmux buffer to
paste into the target. Enter is sent unless `--no-submit` is present.

The implementation should preserve the current fail-fast behavior of tmux
helpers. It may extract a generic helper from `_peer_tmux_paste` rather than
duplicating buffer load/paste/delete logic. Body reading should follow the
sentinel pattern already used for mailbox bodies so trailing newlines survive
Bash command substitution.

Pane-readiness should reuse the existing capture-pane checks where possible.
If the agent type cannot be inferred from the session command or metadata, the
safe default is to refuse unless `--force-busy` is set. Known approval,
permission, and trust prompts remain hard stops even with `--force-busy`.

Testing approach: unit-only.

**Files expected to change:**

- `cctrl`: add `session say`, body parsing, JSON output, and shared tmux paste helper if needed
- `tests/run-tests.sh`: add fake-tmux coverage for submit, no-submit, stdin/file body, modal deferral, and failure paths
- `README.md`: document `session say` as direct live tmux chat
- `completions/_cctrl`: complete `session say` flags and tmux session names

**Out of scope:** peer resolution, mailbox send/recv behavior, MCP tools, automatic agent prompts, and renaming existing peer mailbox commands.

## Tasks

1. Add body parsing for `session say` with `--body-file PATH|-`, `--json`, `--no-submit`, and `--force-busy`.
2. Add a reusable tmux paste/submit helper or adapt `_peer_tmux_paste` without changing current peer delivery behavior.
3. Implement live-session validation and pane-readiness checks before pasting.
4. Wire `say` into `cmd_session`, top-level help, and zsh completions.
5. Add shell tests using the fake tmux fixture for success, no-submit, stdin/file body preservation, modal deferral, unknown session, and tmux failure cases.
6. Update README to position `session say` as the direct way to talk to a known live tmux session.

## Verification

Checks:
- [cmd] `bash -n cctrl && bash -n tests/run-tests.sh && zsh -n completions/_cctrl`
- [cmd] `tests/run-tests.sh`
- [assert] the test suite shows `cctrl session say TMUX--demo -- "hello"` calls `load-buffer`, `paste-buffer`, and `send-keys ... Enter`
- [assert] the test suite shows `--no-submit` omits the Enter send-key
- [assert] the test suite proves `--body-file -` preserves a trailing newline in the tmux buffer payload
- [assert] the test suite proves a known modal prompt returns `status:"busy"` and does not paste even with `--force-busy`
- [assert] the test suite proves unknown readiness refuses by default and succeeds only when `--force-busy` is present
