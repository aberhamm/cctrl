---
id: 082
title: Launch a Codex terminal bootstrap and release the exact task to the app
status: done
blocked-by: [067, 069, 080]
priority: 82
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-28
completed: 2026-09-28
tui-fixture: n/a
approved-by: matthew (option 3, via cctrl-fleet-manager plan082go-fm0928)
reviews:
  - type=eng verdict=approved date=2026-09-28 by=opus-level-subagent
---

## Plain-English Summary

Add a new opt-in compound workflow for the common “bootstrap on the managed
terminal host, then continue from the Codex app” path. Existing `cctrl start`
and `cctrl session attach` behavior remains unchanged.

`cctrl launch-to-app <target>` creates one detached cctrl-managed Codex terminal
session, waits for boot, proves the exact provider identity, attests the anchored
terminal owner, and then delegates the writer transition to the existing safe
`release-to-app` state machine. `--keep-terminal-owned` performs the same launch
and exact identity verification but deliberately stops before handoff.

## Requirements

- [x] The feature is a new top-level compound workflow. Existing `start` and
      `session attach` commands have no changed defaults, output, timing, or
      ownership behavior.
- [x] The workflow launches exactly one detached Codex terminal session through
      the existing launch path. It never creates a replacement provider task.
- [x] The workflow suppresses heuristic rollout/title polling while identity is
      provisional. Cwd, title, prompt, and recency are never accepted as
      provider identity proof.
- [x] It retains the exact provisional launch ID returned by its own launch. If
      the receipt remains provisional, it runs the existing
      `recover-terminal-identity --launch-id` proof and guarded apply path.
- [x] A canonical record must preserve that launch ID, exact provider task ID,
      cctrl origin, cctrl/tmux ownership, and the launch's exact tmux session.
- [x] It runs `session attest` after identity promotion and requires the attested
      `thread_id` to equal the canonical provider task ID.
- [x] Default finalization calls the existing `release-to-app` implementation,
      preserving its App Server preflight, confirmation-free compound-command
      authorization, anchored tmux/PID exit, same-provider-task preservation,
      postflight, digest-guarded event, and failure behavior.
- [x] `--keep-terminal-owned` is an explicit opt-out after successful identity
      verification. It never calls the release state machine.
- [x] Any boot, proof, promotion, attestation, preflight, owner-exit, postflight,
      or registry failure leaves the terminal task in the safest state reached
      and returns an actionable attach/retry hint.
- [x] JSON output identifies the launched tmux session, exact launch ID and
      provider task ID when known, whether recovery was applied, requested
      finalization, resulting owner/runtime, release result, and failure.
- [x] Tests use function fixtures and isolated tmux/App Server fixtures only;
      they never inspect or mutate the live fleet.

## Design

Put orchestration in `lib/codex-launch-to-app.sh`; keep `cctrl` changes to module
loading, dispatch/help, and exposing the exact launch receipt produced by the
existing detached-launch function. The module:

1. validates and strips compound-only arguments;
2. calls `_launch_detached` with forced Codex, detached mode, no attach prompt,
   and both heuristic identity/title polls disabled;
3. uses only the exact launch ID returned by that call; the detached child also
   inherits that token so a delayed lifecycle hook from a reused tmux name
   cannot be mistaken for the new generation;
4. proves/applies provisional identity recovery when necessary;
5. validates the canonical record and independent session attestation; and
6. either returns terminal-owned success for `--keep-terminal-owned` or calls
   `_session_release_to_app_one` with compound-command authorization and the
   verified provider/launch/pane tuple as a final race guard.

The existing handoff state machine remains the sole implementation of provider
preflight, writer exit, postflight, and the ownership registry transition.

## Files expected to change

- `lib/codex-launch-to-app.sh`: compound workflow and result contract.
- `cctrl`: thin load/dispatch/help hooks and exact launch receipt exposure.
- `tests/run-tests.sh`: isolated orchestration and failure regression tests.
- `README.md`, `CHANGELOG.md`, `completions/_cctrl`: user-facing command contract.
- `skills/cctrl-spawn/SKILL.md`: prefer the compound workflow for app viewing,
  with explicit terminal-owned opt-out.

## Verification

- [cmd] `bash -n cctrl lib/codex-launch-to-app.sh`
- [cmd] `CCTRL_TEST_ONLY=codex-launch-to-app LANG=en_US.UTF-8 bash tests/run-tests.sh`
- [cmd] `LANG=en_US.UTF-8 bash tests/run-tests.sh`
- [assert] existing start/attach regression tests remain unchanged and green

## Implementation Notes

- Added the opt-in `launch-to-app` command; `start` and `session attach` retain
  their existing dispatch, defaults, and output paths.
- Exact identity is accepted only from native root-rollout recovery proof or a
  lifecycle proof carrying the independently inherited launch token. Bare
  canonical records, heuristic promotion, cwd/title/recency, and stale hooks
  are rejected.
- The existing handoff state machine remains responsible for provider
  preflight, anchored single-writer exit, postflight, and registry mutation.
- Engineering review: approved after fixes; no remaining P1/P2 findings.
- Verification: focused launch/lifecycle/attest/handoff suites and the complete
  `LANG=en_US.UTF-8 bash tests/run-tests.sh` suite passed (100 Python tests).
