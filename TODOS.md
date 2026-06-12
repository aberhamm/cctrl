# TODOS

## peer register-self — identity bootstrap for already-running sessions

**What:** A `cctrl peer register-self` command that infers the current tmux session
(via `$TMUX`/`tmux display-message`) and registers it as a peer in one step, so an
agent that is already running can claim an identity and start using the mailbox and
MCP bridge without a human running `peer register` on its behalf.

**Why:** Plan 008's `cctrl start --peer NAME` only covers sessions launched with
identity; the original motivating scenario (two *already-running* sessions wanting
to collaborate) has a cold-start gap. Surfaced by the Codex outside-voice review of
plans 002–008 (2026-06-11, coverage gap G2).

**Pros:** Closes the cold-start gap for the feature's core use case; small surface
(reuses plan 002 registration + session-name detection).
**Cons:** Identity inference from inside a session needs care (nested tmux, remote
hosts); cooperative trust model means self-registration is unauthenticated by design.

**Context:** Peer registry ships in plan 002 (`data/peers.json`, manual-wins
shadowing, reserved name `user`); ambient identity via `CCTRL_PEER` ships in plan
008. Start from `_session_metadata_file()` and the plan 002 resolver. The command
should set `CCTRL_PEER` guidance in its output since the env var can't be exported
into an already-running agent process.

**Depends on / blocked by:** plans 002 and 008 shipped.
