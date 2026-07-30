---
id: 049
title: Fix mailbox locking races and delivery lock starvation
status: blocked
blocked-by: [040, 045]
priority: 21
goal: revised-cctrl-audit-backlog
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-30
reviews:
  - type=eng verdict=changes-requested date=2026-07-30 by=mstack-review
---

## Requirements

Four concurrency defects in the peer layer, all currently latent but each a
data-corruption or double-action risk as fleet size grows:

1. **Dir-lock TOCTOU:** in `_mailbox_lock_acquire`'s mkdir-fallback path,
   process A `mkdir`s the lock and — before A writes its `pid` file — process
   B fails `mkdir`, finds no pid file, treats the lock as stale, `rm -rf`s A's
   *live* lock, and acquires it: two writers inside `messages.jsonl`. Same
   pattern in `_watch_lock_acquire`. (The shlock fast path is safe; the
   documented fallback is not.)
2. **`peers.json` has no locking at all:** register/alias/unregister do
   unlocked read-modify-write (`jq > tmp && mv`); concurrent registrations
   lose entries.
3. **Lock-hold vs lock-timeout mismatch:** `deliver --all`/`watch` hold the
   mailbox lock across per-peer tmux operations (each with its own 5s
   timeout) while `send` gives up after 10s (`CCTRL_MAILBOX_LOCK_TIMEOUT`) —
   a slow pass over a few unreachable peers makes concurrent sends fail
   "Timed out waiting for mailbox lock."
4. **Nudge dedupe is one second wide (deliver path only):** the deliver-path
   recently-nudged check compares `last_nudge_at` string-equal to the current
   second (`== $now`); two deliver invocations 2s apart double-paste the nudge
   into the pane. The watch-path renudge check is ALREADY epoch-window based
   (`fromdateiso8601` + `>= $older`) — it is correct and must not be touched.

**Acceptance criteria:**

- [ ] Dir-lock acquisition is race-free: preferred approach (see Design) is a mandatory shlock fast path with an atomic `ln -s $$ lockfile` fallback, retiring the mkdir+pid-file dance entirely; if the worker instead keeps the mkdir path, the grace-window repair applies (a breaker must re-verify staleness after a grace window and must never remove a lock younger than the grace period). Applied to both `_mailbox_lock_acquire` and `_watch_lock_acquire`.
- [ ] A stress test (N concurrent senders via the harness) loses no messages and never observes two concurrent lock holders (assert via a lock-held marker file the test injects). The race fires deterministically, not by timing luck: an env hook (e.g. `CCTRL_LOCK_TEST_DELAY`) injects a sleep between lock acquisition and pid visibility so the two-holder window is held open on demand.
- [ ] `peers.json` writes go through the mailbox lock (or a dedicated `peers` lock with the same discipline); a concurrent register/alias test loses no entries.
- [ ] Delivery no longer holds the mailbox lock across tmux I/O: the pass snapshots deliverable rows under the lock, releases, performs tmux work, then re-acquires per-row to record state transitions — with the row re-checked on re-acquire (it may have been recv'd/bounced meanwhile). A row whose state changed between snapshot and re-acquire is reported in the `skipped` outcome bucket with a row-changed reason — NEVER `failed` (plan 027's five-outcome consumers would wrongly retry a message that was actually handled). A test asserts `deliver --all --json`'s result-array shape is unchanged by the restructure. Concurrent `send` during a slow deliver pass succeeds within its timeout (test with an artificially slow fake tmux).
- [ ] Deliver-path nudge dedupe compares timestamps within a configurable window (default 30s), not string equality of the same second. The watch-path renudge check (already epoch-window based) is left untouched.
- [ ] A wedged lock is diagnosable after the aggressive self-heal is removed: lock age and holder pid are surfaced in `peer status` (or `peer doctor`), and the lock-timeout error text documents the manual-clear path.
- [ ] Full suite passes; the ~375 peer assertions unchanged except lock-behavior tests.

## Design

**Lock fix — preferred approach (simplest):** make the shlock fast path
mandatory, with an atomic symlink fallback — `ln -s $$ lockfile` is a single
atomic operation that embeds the holder pid in the link target (macOS has no
flock(1) binary, but shlock ships with the OS and `ln` is universal). This
RETIRES the mkdir+pid-file dance instead of hardening it: no pid-file write
window means no TOCTOU to repair. The grace-window repair described in
criterion 1 remains the documented alternative only if the worker finds
shlock/`ln -s` unsuitable in practice.

The deliver-pass restructure (criterion 4) is the judgment-heavy piece: the
current code records transitions inline while holding the lock. The
snapshot-release-reacquire pattern trades a small re-check cost for bounded
lock hold; the re-check on re-acquire is mandatory because the row can change
state while unlocked (this is the same discipline plan 027's classifier
established: classify at action time, not snapshot time).

Keep `set -euo pipefail` interactions in mind for any parallel/stress test
helpers (see `.mstack/learnings.jsonl`: xargs -P pools under set -e kill the
parent on worker failure — guard whole pipelines, not just the last command).

**Files expected to change:**

- `cctrl`: `_mailbox_lock_acquire`, `_watch_lock_acquire`, peers.json write sites (register/alias/unregister), the deliver-pass loop, the deliver-path nudge dedupe check, lock-status surfacing in `peer status`/`peer doctor` + timeout error text
- `tests/run-tests.sh`: concurrent-sender stress, concurrent-register, slow-deliver + concurrent-send, dedupe-window tests

**Testing approach: E2E** — isolated `CCTRL_DATA_DIR`, fake tmux with an
injectable delay.

**Out of scope:** replacing the JSONL store, per-message file sharding, the
whole-mailbox-scan performance item (defer until row counts hurt), watch
daemonization.

## Tasks

1. Fix both dir-lock acquire paths (preferred: mandatory shlock + atomic `ln -s` fallback, retiring mkdir+pid-file; alternative: atomic pid visibility + breaker grace re-verify); add the two-holder stress test with the `CCTRL_LOCK_TEST_DELAY` env hook.
2. Route peers.json mutations through the lock; add the concurrent-register test.
3. Restructure the deliver pass to snapshot-release-reacquire with per-row re-check (changed rows → `skipped` with row-changed reason); add the slow-deliver/concurrent-send test and the `deliver --all --json` shape test.
4. Widen the deliver-path nudge dedupe to a timestamp window (watch-path renudge untouched); add its test.
5. Surface lock age + holder pid in `peer status` (or `peer doctor`) and document the manual-clear path in the lock-timeout error text.
6. Run the full suite.

## Verification

Checks:

- `[cmd] bash tests/run-tests.sh`
- `[cmd] bash -c 'h1=$(shasum data/messages.jsonl 2>/dev/null || echo absent); bash tests/run-tests.sh >/dev/null 2>&1; h2=$(shasum data/messages.jsonl 2>/dev/null || echo absent); [ "$h1" = "$h2" ]'`
- `[assert] grep -n 'CCTRL_MAILBOX_LOCK_TIMEOUT' cctrl` contains `CCTRL_MAILBOX_LOCK_TIMEOUT`

<!-- mstack:seam
produced:
assumed:
- from: 045; kind: schema; name: bounced; file: cctrl
-->
