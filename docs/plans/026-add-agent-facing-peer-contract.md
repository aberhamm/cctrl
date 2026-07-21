---
id: 026
title: Put the peer operating contract where agents read
status: pending
blocked-by: [024, 025]
priority: 26
goal: cctrl-peer-messaging-discoverable-models
allows-migrations: false
needs-review: none
review-required: none
created: 2026-07-19
---

## Requirements

Peer messaging is documented only in `README.md:232-322`. `CLAUDE.md` mentions
peer **zero** times; `AGENTS.md` mentions it once, parenthetically, in a
sentence about what cctrl is. Both of those files are loaded into agent context
automatically; the README is not. So the fleet's own operating manual for
inter-session coordination lives in the one place an agent is least likely to
read.

This plan puts a compact operating contract where agents already look, and
records the known limitation that peer addresses are tmux session names.

**Acceptance criteria:**

- [ ] `AGENTS.md` gains a section headed exactly `## Peer messaging` stating the identity model, the send → check → recv → ack lifecycle, and how to reply using a received message's sender identity.
- [ ] `README.md` documents the `cctrl peer overview` subcommand and the `peer_overview` MCP tool added by plan 025, so the entry point is discoverable from the docs and not only from `tools/list`.
- [ ] The contract states that `peer send` only **queues** and that delivery requires `peer deliver` (no watcher runs by default), so an agent following it does not believe a send-only reply succeeded.
- [ ] The contract is compact — target ≤ 30 lines in `AGENTS.md` — because it is loaded into every agent's context.
- [ ] `CLAUDE.md` gains a routing entry pointing peer/inter-session-messaging requests at the `AGENTS.md` contract. Note that every existing routing rule uses the form `X → invoke /skill-name`, but peer messaging is prose in `AGENTS.md`, not a skill — so use a pointer form such as `Peer / inter-session messaging → see the peer contract in AGENTS.md` rather than inventing a nonexistent skill name.
- [ ] The contract names concrete commands with real flags (`cctrl peer check --json`, `cctrl peer recv --json`, `cctrl peer ack <id> --json`, `cctrl peer send <peer> --json -- "<body>"`), not paraphrases.
- [ ] The contract states that received messages carry a `sender` object and that replying means sending to `sender.name` (from plan 023).
- [ ] The contract states that a message must be acked after it is handled, and that unacked messages are re-nudged.
- [ ] `README.md` documents the `sender` field and the inline-delivery envelope, and notes that messages predating the change carry only `from`.
- [ ] The tmux-name-addressing limitation is recorded explicitly: peer names for derived peers *are* tmux session names, so an address can dangle once that session closes; a receiver should treat a `sender` snapshot as historical and verify liveness via `cctrl peer ls` before relying on it.
- [ ] `AGENTS.md` follows the repo's stated public-repo rule: no hostnames, URLs, IPs, tokens, ports, or private repo names in any added text.
- [ ] No skill file under `skills/` is modified by this plan.

## Design

`AGENTS.md` is the natural home — it already carries the fleet-role doctrine and
explicitly positions itself as agent instructions. Add a peer messaging section
alongside the existing "Fleet roles" and "Skill routing" sections. `CLAUDE.md`
holds routing rules only, so it gets a routing line, not a duplicate of the
contract.

**Contract content**, in priority order (a model reads the top first):

1. **Orientation** — run `cctrl peer overview --json` (plan 025) as the single first call: it answers who you are, who you can reach, and whether you have unread mail.
2. **Receiving** — `cctrl peer check --json` for counts, `cctrl peer recv --json` to take the next message, `cctrl peer ack <id> --json` when handled. Unacked messages get re-nudged, so ack is not optional.
3. **Replying** — `cctrl peer reply <message-id> --as <you> --json -- "<body>"` (plan 027). It resolves the recipient from the message itself and both sends and delivers, so you never need to know the sender's address. Never reply with a bare `cctrl peer send`: send alone only **queues** and nothing arrives until a deliver runs. Always pass `--as` — a non-interactive shell may not have `CCTRL_PEER` exported.
4. **Sending** — `cctrl peer overview` (or `cctrl peer ls`) to find a peer, then send **and** deliver.
5. **Limitation** — addresses are session-derived and can dangle; verify liveness before relying on an older snapshot.

**Public-repo constraint.** `AGENTS.md:23-26` states that cctrl is public and
that skills and docs must contain no environment specifics. Every example must
use placeholder peer names, never real fleet session names such as those in
`data/messages.jsonl`.

**Depends on 024 and 025** because it documents the inline envelope (024) and
the `peer_overview` MCP entry point (025) — see the README acceptance criterion
covering the latter. Writing it earlier would document behavior that does not
exist yet.

**Files expected to change:**

- `AGENTS.md`: new peer messaging contract section
- `CLAUDE.md`: one skill-routing entry
- `README.md`: `sender` field, inline envelope, known limitation

**Testing approach: unit-only** — documentation changes verified by content
assertions; there is no executable behavior in this plan.

**Out of scope:** any code change whatsoever. If writing the contract reveals a
behavior gap, record it as a follow-up plan rather than fixing it here. Do not
modify anything under `skills/`. Do not implement `peer help-agent` — that
belongs to unimplemented plan 011 and is not a dependency of this work.

## Tasks

1. Draft the contract against the five-point structure above, keeping it within ~30 lines.
2. Add it to `AGENTS.md` as a new section, matching the file's existing heading style and cross-link conventions.
3. Add a peer/inter-session-messaging routing line to `CLAUDE.md`'s skill-routing list.
4. Update the `README.md` peer section: document the `sender` object, the inline-delivery envelope, the `peer_overview` MCP entry point, and that older messages carry only `from`.
5. Add the tmux-name-addressing limitation to `README.md` as an explicit known limitation.
6. Re-read every added line for environment specifics (hostnames, IPs, ports, private repo names, real session names) and replace them with placeholders.
7. Add content assertions to `tests/run-tests.sh` pinning that the contract exists in `AGENTS.md` and the routing line exists in `CLAUDE.md`.

## Verification

Checks:

- `[cmd] bash tests/run-tests.sh`
- `[assert] bash -c "grep -qi 'peer' ~/dev/cctrl/CLAUDE.md && echo yes"` contains `yes`
- `[assert] bash -c "grep -q 'cctrl peer ack' ~/dev/cctrl/AGENTS.md && echo yes"` contains `yes`
- `[assert] bash -c "grep -q 'sender' ~/dev/cctrl/AGENTS.md && echo yes"` contains `yes`
- `[assert] bash -c "grep -q 'peer_overview' ~/dev/cctrl/README.md && echo yes"` contains `yes`
- `[assert] bash -c "grep -qi 'an address can dangle' ~/dev/cctrl/README.md && echo yes"` contains `yes` — pins the **new** limitation text (verified absent from README today). Do **not** grep for `limitation` (already at `README.md:448`) or `tmux session name` (already at `README.md:165`) — both match existing unrelated prose and would pass with zero work done.
- `[cmd] bash -c 'awk "/^## Peer messaging/{f=1;next}/^## /{if(f)exit}f" ~/dev/cctrl/AGENTS.md | wc -l | xargs -I{} test {} -le 30'` — excludes both boundary headings; requires the exact `## Peer messaging` heading mandated in Requirements
- `[cmd] git -C ~/dev/cctrl diff --unified=0 -- AGENTS.md CLAUDE.md README.md | grep "^+" | grep -Eiv "^\+\+\+" | grep -Eq "TMUX--|100\.[0-9]+\.|:[0-9]{4}\b|home\.matthew|homelab" && exit 1 || exit 0`

**Note on check form:** use existence checks (`grep -q … && echo yes`), never
`grep -c … contains N`. `grep -c` counts matching *lines* and the runner does a
*substring* match, so `contains 1` also matches `11`, and any correctly
implemented section that mentions a term twice returns `2` and fails.
- `[manual] Read the AGENTS.md contract cold and confirm a session that has never used peer messaging could receive, handle, ack, and reply from it alone.`
