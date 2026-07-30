---
id: 044
title: peer doctor --fix installs the doorbell hook idempotently
status: pending
blocked-by: []
priority: 16
goal: revised-cctrl-audit-backlog
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-30
reviews:
  - type=eng verdict=approved date=2026-07-30 by=mstack-review
---

<!-- status: blocked encodes the un-run eng review gate (repo convention), not a dependency block — blocked-by is intentionally empty. -->

## Requirements

`hooks/peer-doorbell.sh` is the designed wake-up path for peer mail (as a
Claude Stop/Notification hook it exits 2 with the recv instruction when queued
mail exists), but **nothing installs it**: it is registered in no
`settings.json` on this fleet, `cctrl start` doesn't wire it, and `peer
doctor` only *reports* it missing. Net effect: idle agents never learn they
have mail, which is a root cause of the fleet's silent-non-delivery pain
(plan 027 fixed the sender leg; this fixes the receiver leg). Additionally,
the current registration check greps the settings file for the hook's
*filename*, so a commented-out or disabled entry passes the doctor check.

**Acceptance criteria:**

- [ ] `cctrl peer doctor --fix` idempotently registers `hooks/peer-doorbell.sh` as a Stop AND Notification hook in the user's Claude settings file, preserving all existing hooks and settings via a jq merge. Settings path: cctrl hardcodes `CLAUDE_DIR="$HOME/.claude"` and `SETTINGS` does NOT honor `CLAUDE_CONFIG_DIR` (re-plumbing `CLAUDE_DIR` would drag in the profile machinery) — so introduce a `CCTRL_CLAUDE_SETTINGS` env override for the settings path (mirroring the existing `CCTRL_CLAUDE_SESSIONS_DIR` test-override pattern), used by `--fix` and the registration check. Real-user behavior is unchanged: `$HOME/.claude/settings.json`.
- [ ] Before writing, the current settings file is backed up alongside itself (timestamped suffix); the MERGED output is validated (`jq empty`) before `mv`; the temp file is created alongside the target (same filesystem) so `mv` stays atomic; the command aborts with a clear error if the input file is not valid JSON. Doctor/`--fix` output names the settings file inspected and prints the restore path (`cp <backup> settings.json`).
- [ ] Running `--fix` twice produces zero changes on the second run (idempotence test compares file hashes).
- [ ] The registration check's CLAUDE branch (`_peer_doorbell_registered` is agent-aware) is rewritten from a filename grep to a jq structural check: an *active* entry whose command resolves to the doorbell script — a commented/absent/mangled entry fails the check.
- [ ] Codex doctor behavior is untouched: the codex branch of `_peer_doorbell_registered` (which checks `$CODEX_DIR/config.toml` via `_peer_codex_notify_references_hook`) stays as-is and its existing tests (~tests/run-tests.sh:3673) stay green.
- [ ] `peer doctor` (no `--fix`) reports doorbell state accurately using the new check and prints the exact `--fix` invocation as the remedy.
- [ ] `cctrl start --peer NAME` warns once at spawn when the doorbell is unregistered, pointing at `peer doctor --fix` (warning only — no auto-install at spawn). Placement: `cmd_start`'s `--peer` parsing is bypassed on the dominant detached path, so the warning must live where both the foreground and `_launch_detached` flows pass — or in both.
- [ ] The doorbell hook remains a no-op for sessions without `CCTRL_PEER` (already its behavior — regression-test it, since `--fix` makes the hook global for every Claude session on the machine).
- [ ] Tests set `CCTRL_CLAUDE_SETTINGS` to a fixture file — never the real `~/.claude/settings.json`.

## Design

Scope discipline (reviewer finding): `peer doctor` exists — this plan adds
only the `--fix` install behavior and the honest registration check. No new
subcommands, no watch daemon, no launchd unit (a resident `peer watch` is
future work and explicitly out of scope).

Target hook shape: Claude Code's settings hooks schema is nested —

```json
"hooks": {
  "Stop":         [{"matcher": "...", "hooks": [{"type": "command", "command": "<path>"}]}],
  "Notification": [{"matcher": "...", "hooks": [{"type": "command", "command": "<path>"}]}]
}
```

— and real files already carry Stop/Notification/PreToolUse groups.
Idempotence rule: registered = structural presence of a command entry
resolving to `peer-doorbell.sh` anywhere within the event's matcher groups
(never blind-append); the merge adds a group only when absent.

**Three implementation decisions, made here so the worker doesn't improvise:**
(a) the current CLAUDE check also greps `$HOME/.claude.json` — the rewrite
DROPS that leg (Claude Code does not honor hooks there; keeping it preserves a
grep false-positive path beside the honest check). (b) An absent settings file
on a fresh machine is treated as `{}` — the abort-on-invalid-JSON rule applies
only to a present-but-malformed file; the fresh-install test pins this.
(c) "Command resolves to the doorbell script" means realpath-equivalence, not
exact string match — otherwise an existing equivalent-path entry makes `--fix`
double-install.

The hook is machine-global once installed, so the no-op-without-`CCTRL_PEER`
property is the safety invariant; test it directly.

Spawn-time behavior is a *warning*, not an install: mutating a user's global
settings should only happen from the explicit `--fix` verb.

**Files expected to change:**

- `cctrl`: `_peer_doorbell_registered` CLAUDE-branch rewrite (codex branch untouched); `--fix` branch in the peer doctor command; spawn-time warning covering both the foreground path and `_launch_detached`
- `tests/run-tests.sh`: settings-fixture install/idempotence/malformed-JSON/inactive-entry tests

**Testing approach: E2E** — real binary, isolated `CCTRL_CLAUDE_SETTINGS` and
`CCTRL_DATA_DIR` fixtures.

**Out of scope:** a `peer watch` daemon/launchd unit; auto-install at spawn;
Codex-agent hook equivalents; changing the doorbell script's message text.

## Tasks

1. Rewrite `_peer_doorbell_registered`'s CLAUDE branch as a jq structural check (active Stop + Notification command entries resolving to the script); leave the codex branch (`_peer_codex_notify_references_hook`) untouched.
2. Implement `--fix`: validate input JSON → backup → jq merge of both hook events (add a group only when absent) → validate merged output (`jq empty`) → atomic write via a temp file alongside the target; second-run no-op.
3. Add the unregistered-doorbell spawn warning where both the foreground and `_launch_detached` flows pass (or in both).
4. Update `peer doctor` output and `peer help`.
5. Tests: fresh install, idempotence (hash-equal), preservation of unrelated hooks, malformed JSON abort, inactive-entry detection, no-`CCTRL_PEER` no-op.
6. Run the full suite.

## Verification

Checks:

- `[cmd] bash tests/run-tests.sh`
- `[assert] ./cctrl peer help 2>&1` contains `--fix` (note: `peer doctor` rejects unknown flags today, so `peer doctor --help` is not a usable probe; the task updates `peer help`)
- `[cmd] bash -c 'h1=$(shasum ~/.claude/settings.json); bash tests/run-tests.sh >/dev/null 2>&1; h2=$(shasum ~/.claude/settings.json); [ "$h1" = "$h2" ]'`
- `[manual] On this machine, run "cctrl peer doctor --fix" once, start a scratch --peer session, send it mail, and confirm the doorbell fires at turn end.`

<!-- mstack:seam
produced:
- kind: flag; name: --fix; file: cctrl
- kind: flag; name: CCTRL_CLAUDE_SETTINGS; file: cctrl
assumed:
-->
