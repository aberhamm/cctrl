---
id: 029
title: Implement stable peer identity per the approved migration proposal
status: blocked
blocked-by: [028]
priority: 29
goal: cctrl-peer-messaging-discoverable-models
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-19
---

## Requirements

Implement the stable-peer-identity design that plan 028 produced and the
operator approved. **Do not start until `docs/proposals/stable-peer-identity.md`
exists and carries a recorded approval** — 028 being `done` is the structural
gate, and this plan's first task re-checks it rather than assuming.

The problem is unchanged from 028: `_peer_derived_json` (`cctrl:1948`) makes an
unaliased derived peer's mailbox address its tmux session name, so closing or
renaming that session strands every stored address referencing it. Plans 023 and
024 make attribution unambiguous and warn a receiver when a sender is gone, but
warning is not continuity — a conversation still cannot survive a session being
replaced, which happens routinely here through handoffs, restarts, and the
context-limit respawn pattern.

**Acceptance criteria:**

- [ ] `docs/proposals/stable-peer-identity.md` exists and records operator approval; the implementation follows it. Any deviation is documented in the plan's Implementation Notes with its reason.
- [ ] Every cctrl-managed session carries a stable peer id, generated once and persisted in session metadata, independent of its tmux session name.
- [ ] Already-running sessions acquire an id via the adoption path the proposal specifies, **without restart**. Note `_session_write_metadata` has one call site (`cctrl:1760`, detached creation only), so this requires the new write path 028 designed — it does not come for free.
- [ ] The stable id survives a tmux session rename.
- [ ] A peer resolves by stable id, by canonical name, and by alias; all three continue to work, and existing ambiguity-error behavior is preserved.
- [ ] `sender` (plan 023) carries the stable id alongside `name`, so newly stored messages record a durable address.
- [ ] Replying to a message whose sender's session was **replaced** resolves to the successor when one has explicitly claimed that stable id.
- [ ] Replying to a message whose sender is genuinely gone (no claim) fails clearly and actionably. Misrouting is worse than failing: a reply delivered to an unrelated session gives work to someone with no context while the real recipient never learns. There is **no heuristic fallback** — no name-similarity, no directory match.
- [ ] Messages predating this plan, carrying only `from` or only `sender.name`, keep resolving by name exactly as today. No stored message is rewritten.
- [ ] `data/peers.json` and `data/messages.jsonl` are **never edited in place**.
- [ ] `cctrl peer ls` and `peer resolve` surface the stable id so a human can see the mapping.
- [ ] Plan 024's reachability classifier is updated so a sender resolvable by stable id is no longer reported `SENDER IS NO LONGER LIVE`. 024 deliberately does not depend on this plan, so closing that loop belongs here.

## Design

Follow the approved proposal. This section records only the constraints that
hold regardless of which option the proposal selected.

**Backward compatibility is mandatory.** Every message already in the store has
`from` and, post-023, `sender.name`. Both must keep resolving by name. The
stable id is additive on the session-metadata side and on the `sender` side.

**Resolution becomes a union** in `_peer_resolve_json`: stable id, canonical
name, or alias all resolve to the same peer object. Keep the existing ambiguous-
match error rather than silently preferring one form.

**Fail closed on successor claiming.** An unclaimed predecessor id resolves to a
clean failure, never a guess.

**Files expected to change:**

- `cctrl`: `_session_write_metadata` (persist the id), the adoption write path the proposal specifies, `_peer_derived_json` and `_peer_all_json` (carry it), `_peer_resolve_json` (resolve by it), `_peer_cmd_ls` / `_peer_cmd_resolve` (surface it), `_peer_cmd_send` (record it in `sender`), and plan 024's reachability classifier
- `tests/run-tests.sh`: identity persistence, rename survival, adoption without restart, successor resolution, legacy fallback

**Testing approach: E2E** — real `cctrl` against an isolated `CCTRL_DATA_DIR`
with the fake-tmux harness, covering rename and replace scenarios.

**Out of scope:** cross-host identity — a stable id is local to a host, and the
`--host` forwarding layer remains the only cross-host path. Also out of scope:
any change to the nudge or doorbell strings.

**Note on shared functions:** plans 023 and 027 also modify `_peer_cmd_send`,
and both land before this one. Re-locate by function name at execution time
rather than by any line number cited here — those will have drifted.

## Tasks

1. Verify the gate: `docs/proposals/stable-peer-identity.md` exists and records approval. If it does not, stop and report rather than proceeding.
2. Generate and persist a stable id in `_session_write_metadata`, idempotently, so rewriting metadata never mints a second id.
3. Implement the adoption path from the proposal so already-running sessions acquire an id without restart.
4. Carry the id through `_peer_derived_json` and `_peer_all_json` into resolved peer objects.
5. Extend `_peer_resolve_json` to resolve by stable id alongside name and alias, preserving ambiguity errors.
6. Record the id in the `sender` object written by `_peer_cmd_send`.
7. Implement explicit successor claiming with no heuristic fallback; an unclaimed predecessor fails cleanly.
8. Surface the id in `peer ls` and `peer resolve`.
9. Update plan 024's reachability classifier so stable-id-resolvable senders are not marked unreachable.
10. Add tests: id persists across metadata rewrite; survives rename; a running session adopts without restart; resolves by id/name/alias; successor claim routes correctly; unclaimed predecessor fails cleanly rather than misrouting; a legacy message with only `from` still resolves.
11. Run the full suite and confirm no existing peer assertion regressed.

## Verification

Checks:

- `[cmd] bash tests/run-tests.sh`
- `[cmd] test -f docs/proposals/stable-peer-identity.md`
- `[assert] bash -c "cd \$(mktemp -d) && CCTRL_DATA_DIR=\$PWD ~/dev/cctrl/cctrl peer ls --json"` contains `[`
- `[cmd] bash -c 'h1=$(shasum data/messages.jsonl 2>/dev/null || echo absent); h2=$(shasum data/peers.json 2>/dev/null || echo absent); bash tests/run-tests.sh >/dev/null 2>&1; [ "$h1" = "$(shasum data/messages.jsonl 2>/dev/null || echo absent)" ] && [ "$h2" = "$(shasum data/peers.json 2>/dev/null || echo absent)" ]'` — neither live store may be touched
- `[manual] Rename a scratch tmux session and confirm its peer still resolves by stable id.`
- `[manual] Replace a scratch session, have the successor claim the predecessor id, and confirm a reply routes to it.`
