# Codex bridge auto-enable spike

Date 2026-11-20. Codex CLI 0.167.0. A read-only spike: no repo changes. All runs
used a temporary `CODEX_HOME` with a hand-trusted `hooks.json`, never the real one,
and no credentials, so no model turn completed (turns failed with 401 after the
hooks had already fired).

Question: can cctrl start a Codex session's bridge endpoint automatically
(`cctrl bridge enable` on start, `cctrl bridge stop` on end) from a Codex hook?

## Verdict

Safe to build as an opt-in, off by default, with two conditions: the hook must
pass the thread ID explicitly, and cleanup must not rely on SessionEnd alone. A
hook-started bridge daemon works and outlives the hook. The risk is orphan
daemons after a Codex crash.

## 1. Is the hook's session_id the ID the bridge uses? Yes, with catches

- The SessionStart payload `session_id` equals the `thread.id` that
  `thread/start` returned, and it is the UUID in the rollout filename (three runs).
  The bridge names the actor `codex:<thread id>` with that same UUID.
- **Catch 1.** `CODEX_THREAD_ID` and `CODEX_SESSION_ID` are not set in the hook's
  environment. The bridge reads identity only from the environment
  (`own_identity()` in `lib/native_bridge.py`), so the hook must
  `export CODEX_THREAD_ID=<session_id from the stdin JSON>` before
  `bridge enable`. Done that way, it worked.
- **Catch 2.** `bridge enable` refuses when Claude identity variables are also
  present ("both Claude and Codex session identities are present"). A hook
  launched by Codex has none, but a test run from a Claude session leaks them.
- SessionStart fires on the first turn, not at `thread/start`. A thread that never
  gets a turn is never enabled, which is fine: nobody sends to it.

## 2. Does a daemon started from a hook survive the hook? Yes

- The start hook ran `bridge enable`; the daemon was started with
  `start_new_session=True` (`ensure_daemon` in `lib/native_bridge.py`). The hook
  returned 0 and the daemon stayed up. Eight seconds later the SessionEnd hook's
  `stop` reached it over its control socket and got `{"stopping": true}`.
- After a hard kill of Codex, the daemon was still alive 40 seconds later. Each
  daemon is about 32 MB resident.
- SessionStart hooks list `timeoutSec` 600; `enable` takes well under a second.

## 3. Does it work with untrusted hooks? No

- With `hooks.json` present but untrusted, `hooks/list` reports
  `"trustStatus": "untrusted"` and the hook never ran. Adding a matching
  `[hooks.state."<path>/hooks.json:session_start:0:0"] trusted_hash` entry to
  `config.toml` made it run.
- Trust is per hook and per command hash. Any change to the command text
  re-untrusts it. Auto-enable through hooks therefore depends on
  `cctrl hooks install --agent codex` plus the user's review in Codex, the same
  trust the existing session-observer hook needs. A doctor check on hook trust is
  the right gate.
- A fallback through the session wrapper (no hook) was not tested; it would need
  the thread ID from the rollout.

## Other facts

| Question | Answer |
|---|---|
| Does SessionEnd fire? | On a graceful shutdown (SIGTERM of the app server): yes, and it stopped the daemon cleanly. On SIGKILL or a crash: no, and the daemon is orphaned. |
| SessionEnd timeout | `timeoutSec` is 1. `bridge stop` took under a second here, but under load it could be cut off. |
| Daemon cleanup on its own | None. The daemon has no owner-liveness check and runs until `bridge stop` or SIGTERM. |
| Daemons per session | One `_serve <actor>` process per enabled actor, so auto-enable multiplies daemons by Codex sessions. A fleet already shows this pattern for Claude and Codex. |
| A Codex inbound-approval setting | None found. `codex --help` lists only outbound approvals. `codex queue --thread ID --message TEXT` injects input into a thread with no approval step. |
| Isolation | Worked. Pointing `CCTRL_NATIVE_BRIDGE_DIR` (or `--root`), `CCTRL_NATIVE_BRIDGE_SOCKET_DIR`, `CLAUDE_CONFIG_DIR`, `CCTRL_CODEX_APP_SERVER_SOCKET` and `CODEX_HOME` at a temp directory kept the live daemon and endpoints untouched. The bridge and socket directories must be mode 0700. |

## Risks if auto-enable is built

1. **Orphan daemons on crash or kill.** SessionEnd does not fire on a hard kill.
   Each orphan keeps a live socket, about 32 MB, and a Claude-compatible endpoint
   in `${CLAUDE_CONFIG_DIR}/sessions` that peers can still discover. Mitigation: a
   reaper in the daemon (exit when the Codex process or thread is gone), or a
   sweep of daemons whose thread is dead. `cctrl peer doctor` already reports
   orphans for archived or missing threads, read-only.
2. **Daemon per session.** Name this in the opt-in text.
3. **Endpoint exposure.** An enabled endpoint is reachable by any process of the
   same user, as with Claude. Steer policy stays `off`; auto-enable must not pass
   `--accept-steer`.
4. **Hook trust.** Auto-enable silently does nothing for untrusted hooks. Doctor
   should show that, not fail.
5. **SessionEnd one-second budget.** Keep the stop path fast and idempotent.
6. **Identity environment.** The hook sets `CODEX_THREAD_ID` itself and must unset
   any Claude identity variables.

## Status

Findings only. Auto-enable is not implemented; `cctrl peer setup` does not start
bridge endpoints. See [peer-messaging.md](../peer-messaging.md#cross-session-messaging-setup).
