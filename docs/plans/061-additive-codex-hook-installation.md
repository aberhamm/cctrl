---
id: 061
title: Make Codex hook installation additive and observable
status: done
blocked-by: [057]
priority: 61
goal: codex-task-ownership-surfaces
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-15
completed: 2026-09-16
reviewed: false
qa: automated
reviews:
  - type=eng verdict=approved date=2026-09-16 by=mstack-review
  - type=code verdict=pass date=2026-09-16 by=mstack-code-review
---

## Plain-English Summary

The current cctrl installer replaces the entire Codex hook file, which can erase unrelated user and tool hooks. This plan makes installation ownership-aware: cctrl changes only its own entries, preserves everything else byte-for-meaning where possible, and reports whether Codex trusts and can execute them.

**What changes in the code:** The installer performs a validated atomic merge and adds a Codex observer entry point that only validates payloads and exits safely. Actual lifecycle registration is deferred to the next plan so configuration safety and event interpretation can be reviewed separately.

## Requirements

Native app tasks cannot be observed safely until cctrl can install lifecycle hooks without damaging the user's existing Codex setup. The installer must also work repeatedly as Codex or other tools add hooks of their own.

**Acceptance criteria:**

- [ ] Given a valid Codex configuration, `cctrl hooks install` preserves every non-cctrl top-level key, event, matcher, wrapper attribute, and hook leaf. Preservation means semantic deep equality for every unowned value; whitespace and object-key order may normalize.
- [ ] Owned Codex leaves are exactly JSON objects `{type:"command",command:"cctrl hooks run pre-tool-use"}`, `{type:"command",command:"cctrl hooks run stop"}`, `{type:"command",command:"cctrl hooks run notify"}`, and `{type:"command",command:"cctrl hooks run codex-observe"}` under their plan-057 events; no pre-53994fb Codex hooks.json signature is migratable. Replacement removes only these exact leaves. An empty wrapper is removed only when its remaining keys exactly equal the event-specific canonical cctrl wrapper metadata (including the exact PreToolUse matcher); mixed/extended wrappers remain. Loose substring matching is forbidden.
- [ ] Installation is idempotent and does not duplicate cctrl entries when run twice.
- [ ] Invalid JSON fails closed and leaves the original file untouched; the installer prints a recovery path rather than replacing it with an empty object.
- [ ] Writes use a destination-directory `mkstemp` file with mode `0600`, candidate reparse, flush/fsync, and `os.replace`, with cleanup on every failure. A symlinked destination is rejected with actionable output.
- [ ] The documented guarantee is semantic preservation of the source version read when no external non-cooperating writer races the final replacement. cctrl uses a cooperative config lock plus a SHA-256 content comparison immediately before replace (including an absent-file sentinel), bounded retry on detected change, and a same-directory timestamped backup of the exact pre-replace bytes. A non-cooperating writer can still race after comparison; this residual limitation is documented, recovery names the backup, and doctor detects missing owned entries.
- [ ] The installed Codex lifecycle events match plan 057's validated event set and route to `cctrl hooks run codex-observe`.
- [ ] `codex-observe` uses Python `signal.setitimer` for a 2-second whole-process deadline and reads at most 1,048,577 stdin bytes; byte 1,048,577 marks oversized input. Empty, malformed, non-object, oversized, unsupported, missing-id, and timeout cases return zero, perform no registry mutation, and never wait indefinitely for EOF.
- [ ] cctrl PreToolUse and Stop hooks remain installed, and the Claude Code merge behavior does not regress.
- [ ] `cctrl hooks doctor` reports missing lifecycle entries, command resolution under a minimal GUI PATH, hook trust/hash state as `trusted`, `untrusted`, or `unknown`, and unrelated hooks without treating them as errors. It never approves trust automatically.
- [ ] Tests use temporary home/config paths; the plan does not install into the user's real `~/.codex/hooks.json`.

## Design

Retain the portable `cctrl hooks run ...` surface delivered by commit `53994fb`, but replace the Codex whole-document assignment in `_hooks_install` with the exact owned-leaf/wrapper rules above. The cooperative lock protects cctrl-vs-cctrl installers; SHA-256 retry and recoverable backup mitigate, but cannot eliminate, a non-cooperating external writer's final TOCTOU race. Guard Python subprocesses with `if ...; then ... else ... fi` because `cctrl` uses `set -euo pipefail`; do not inspect `$?` after an unguarded failing command. Consume the exact lifecycle contract at `docs/findings/codex-task-lifecycle-contract.md` and fixtures under `tests/fixtures/codex-lifecycle/`.

**Files expected to change:**

- `cctrl`: additive `_hooks_install`, lifecycle entry-point dispatch, and expanded `_hooks_doctor`.
- `hooks/codex-session-observer.py`: validation-only observer entry point for this plan.
- `tests/run-tests.sh`: preservation, idempotence, invalid-JSON, minimal-PATH, and no-mutation tests.
- `README.md`: safe installation and trust instructions.

Testing approach: E2E

**Out of scope:** interpreting lifecycle ownership, writing task records, automatically approving hook trust, or editing the real user configuration during tests.

## Tasks

1. Implement the four exact owned leaves and event-specific empty-wrapper predicate; consume the exact plan-057 lifecycle contract/fixture set.
2. Replace the Codex overwrite with leaf-level merge, cooperative locking, SHA-256/absent-sentinel conflict detection, bounded retry, recoverable backup, and validated atomic replacement; document the residual non-cooperating-writer race.
3. Add the validation-only `codex-observe` entry point with the exact byte cap, `setitimer` deadline, and fail-open behavior.
4. Expand hook doctor for lifecycle coverage, GUI PATH, trust visibility, and unrelated-hook preservation.
5. Add isolated before/after config fixtures for mixed/extended wrappers, exact-signature false positives, cctrl-vs-cctrl locking, detected external modification/retry, absent-file race, backup recovery, residual-race documentation, symlinks, permissions, temp cleanup, idempotence, invalid JSON/checksum preservation, and semantic unowned-value equality.
6. Test observer empty/null/array/malformed/oversized/missing-id/timeout cases with before/after checksums proving no registry or live-store mutation; exercise doctor under `env -i` with all trust states.
7. Update user documentation without installing hooks on either machine.

## Verification

Checks:

- [cmd] `python3 -m py_compile hooks/codex-session-observer.py`
- [cmd] `bash -n cctrl`
- [cmd] `bash tests/run-tests.sh`
- [cmd] `./cctrl hooks run --help | rg -q "codex-observe"`

<!-- mstack:seam
produced:
- kind: file; name: hooks/codex-session-observer.py; file: hooks/codex-session-observer.py
- kind: symbol; name: _hooks_doctor; file: cctrl
- kind: symbol; name: _hooks_install; file: cctrl
assumed:
- from: 057; kind: file; name: docs/findings/codex-task-lifecycle-contract.md; file: docs/findings/codex-task-lifecycle-contract.md
- from: 057; kind: schema; name: codex_lifecycle_fixture_manifest; file: tests/fixtures/codex-lifecycle/manifest.json
-->


## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | Not required for this implementation plan |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | SKIPPED | Running under Codex; nested pass suppressed |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 0 open issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | No visual UI scope |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | Not required |

**VERDICT:** ENG CLEARED — ready to implement.

NO UNRESOLVED DECISIONS

## Implementation Notes

Implemented additive, race-aware Codex hook installation with exact owned-leaf matching, cooperative locking, content-change retries, recoverable backups, validated mode-0600 atomic replacement, symlink refusal, and preservation of unrelated configuration. Added a validation-only bounded observer, expanded doctor reporting for lifecycle coverage, minimal-PATH resolution and trust state, isolated regression coverage, and documentation. A dedicated `hooks/codex-hook-config.py` helper was added beyond the expected file list to keep atomic merge logic testable. Health scored 10.0, all four verification checks passed, and the complete repository suite ended in `ok`; real hook/trust configuration and task records were not mutated.

**Files changed:**

- `README.md` (modified)
- `cctrl` (modified)
- `docs/plans/061-additive-codex-hook-installation.md` (modified)
- `hooks/codex-hook-config.py` (created)
- `hooks/codex-session-observer.py` (created)
- `tests/run-tests.sh` (modified)

**Commit:** `892116b` — `feat(hooks): install Codex observers additively`
