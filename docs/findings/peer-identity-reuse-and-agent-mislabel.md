# Findings: session-id reuse reroutes peer messages; agent mislabelled as codex

Investigation only — no fixes applied. Two defects found in live fleet use on
2026-07-20. Both are confirmed against the running fleet and reproduced.

**Scope note.** `TMUX--ms--cctrl--3` owns plans 023–030 (peer-messaging
attribution / stable identity) and is mid-flight in this same working tree.
This document deliberately lives outside `docs/plans/` and edits none of its
files. Findings that belong in that plan set are marked → **029**.

---

## Defect 1 — a freed tmux index is handed to the next session, and messages follow the name

### Where identity is assigned

`_launch_detached` derives the tmux session name from the *target*, then runs it
through a live-aware picker:

- `cctrl:1691-1712` — `context_name="$(_tmux_session_slug "$dir")"`; the name is a
  pure function of the directory/shortcut. Nothing about the conversation.
- `cctrl:1722-1727` — `_pick_safe_session_index "$base_name"` chooses the final name.
- `cctrl:1258-1283` — the picker: *"An index is `taken` ONLY if `tmux has-session`
  reports it live … A stale metadata record for a DEAD session does not reserve
  the index, so freed indices are reused (no `--N` sprawl)."*

That comment is the defect, stated as intent. Index reuse was a deliberate
anti-sprawl choice made before the name became a message address.

**Reproduced** (throwaway tmux sessions, no cctrl data touched): with
`base`, `base--2`, `base--3` live, the next pick is `base--4`; kill `base--2`
and the next pick is immediately `base--2`.

### Why `--resume` does not reclaim its id

`-r/--resume` is passed straight through to the agent as a launch flag
(`cctrl:510-512`, `LAUNCH_FLAGS+=("--resume" "$resume_val")`). It never reaches
the naming logic. The name is derived from the directory, so a resumed session
lands in whatever slot is lowest-free at that moment — typically the bare base
name, not the suffixed one it had before. That is exactly the reported sequence:
`--5` resumed as the unsuffixed name, freeing `--5` for an unrelated session.

Nothing records which tmux name a conversation previously held, so there is
nothing to reclaim *from*. Session metadata (`cctrl:1189-1220`) stores
`name, created_at, cwd, target_kind, target, display_label, purpose,
initial_prompt, peer, launch_command, host, cctrl_managed` — **no session UUID**.

### How identity is keyed, and why reuse misroutes

`data/peers.json` is `{}` on this machine. The registry is **not** persisted —
it is derived live from tmux on every call:

- `cctrl:1948-1958` — `_peer_derived_json` sets `name: (.peer // .name)` and
  `tmux_target: .name`. For a session started without `--peer`, **the mailbox
  address is literally the tmux session name.**
- `cctrl:2018-2043` — `_peer_resolve_json` matches purely on that name/alias string.
- `data/messages.jsonl` stores `to` as a bare name string (verified: keys are
  `acked_at, body, created_at, delivered_at, from, history, id, last_nudge_at,
  last_nudge_error, nudge_count, status, subject, to, updated_at`). **No
  recipient fingerprint, no session UUID, no addressee birth time.**
- Delivery is late-bound: queued messages are selected by `.to == $peer`
  (`cctrl:3298`) and the target is re-resolved at delivery time
  (`_peer_tmux_target_for_delivery`, `cctrl:3068-3095`).

The critical asymmetry is in that last function. It fails only when the name has
**no** live session:

```bash
if ! _tmux_run_with_timeout has-session -t "$target"; then
    PEER_DELIVER_STATUS="failed"
```

If the name has been recycled, `has-session` **succeeds** and delivery proceeds
normally. So an addressee that is *gone* fails loudly, while an addressee that
has been *replaced* is silently misdelivered. The dangerous case is the quiet one.

A message queued to `--5` before its occupant closed will be delivered, verbatim
and unmarked, to whichever unrelated session next claims `--5`. Given tonight's
traffic included hard-holds and retractions, that is a safety issue, not a
routing nuisance.

### Register / unregister on close

Neither runs. `_session_close` (`cctrl:5610-5721`) validates the target and then
kills tmux — that is all. No metadata removal, no peer deregistration, no
notification to senders holding queued mail. Because the registry is derived, a
closed session vanishes from `peer ls` immediately (so there are no stale
*registry* entries), but its **metadata file persists** and its **queued messages
persist**, addressed to a name that is now free for anyone to take.

### Is a stable UUID available?

Yes, and cctrl already resolves it:

- `cctrl:4508-4513` — `_session_bridge_field <pid> <field>` reads Claude's
  per-PID session file.
- `_session_id "$sess"` (`cctrl:4525`) → the Claude conversation `sessionId`
  (transcript UUID).
- `_session_transcript_path` globs `$CLAUDE_PROJECTS_DIR/*/<sid>.jsonl`.
- Codex has a parallel resolver, `_session_codex_rollout_path`.

`session doctor` already relies on this to relaunch with `--resume <sid>`
(`cctrl:4953`). **Caveat for design:** the UUID is not known at spawn time for a
*fresh* session — Claude mints it after boot — so a UUID-keyed identity needs a
post-boot adoption step. On the `--resume` path it *is* known upfront. This is
the same chicken/egg plan 029 flags.

---

## Defect 2 — NOT cosmetic; it corrupts modal detection during delivery

### Root cause

Agent type is never recorded. It is sniffed at display time from the pane
process's **entire argv** (`_session_agent_cmd` → `ps -o command= -p <pane_pid>`),
at `cctrl:4818-4819`:

```bash
if [[ "$cmd" == *claude* || "$cmd" == *codex* ]]; then
    [[ "$cmd" == *codex* ]] && agent="codex" || agent="claude"
```

Two compounding flaws: the test is an **unanchored substring over the whole argv**
rather than the binary name, and **`codex` is tested first**, so any occurrence of
the string anywhere in argv beats an actual `claude` binary.

Model, extracted one line down (`cctrl:4820-4822`), uses an **anchored flag**
pattern (`--model(=| )[^ ]+`). That is precisely why the two fields disagree —
model reads the real flag, agent reads free text.

Because the seed prompt is passed as a trailing positional argument, **any Claude
session whose prompt mentions codex is labelled codex.**

### Verified, self-referentially

This investigation session was spawned with an explicit `--agent claude` and is
registered as `codex`. Its argv contains the string `codex` twice — the first
occurrence being `DEFECT 2 — AGENT MISLABELED AS codex` from its own briefing.
The bug report reproduced the bug. `TMUX--ms--obsidian-vault--5` matches for the
same reason (its prompt references `~/.codex/config.toml`); it is a Claude
session, consistent with its pane showing Opus 4.8.

### Why it is functional

`peer ls` lifts the same field (`cctrl:1952`), and it drives delivery.
`_peer_deliver_one_locked` reads `agent` (`cctrl:3263`) and passes it to
`_peer_pane_ready_for_delivery` (`cctrl:3099`), which selects the **modal-detection
regex**:

- claude branch (`cctrl:3110-3118`): `grep -E '❯ 1\.'`
- codex branch (`cctrl:3120-3134`): `grep -E 'Allow Codex to |approve network access|…'`

A Claude pane checked for Codex modal strings never matches, so the pane reports
*ready* while a Claude approval modal is open. Delivery then pastes and presses
Enter (`_peer_tmux_paste`, `cctrl:3147-3164`) — **answering the open modal with
the nudge text.** This defeats commits `3a148c7` / `64bc712`, which exist
specifically to prevent that. The inverse holds for real Codex sessions.

Secondary consumers of the same bad value: `cctrl:4254` routes `peer doctor` hook
validation on `agent == codex`; `_session_prune` (`cctrl:5863-5869`) repeats the
`*codex*`-first substring test and picks the wrong log source for staleness.

### Fix direction (small, low-risk)

Stop inferring what is already known. `CCTRL_AGENT` is set at launch and
`--agent` is explicit, but `_session_write_metadata` does not persist it. Record
`agent` in metadata at spawn and prefer it; fall back to a sniff that matches
**argv[0]'s basename**, not the whole command string, and does not privilege
codex. Fixing only the substring test leaves the prune/doctor sites to drift
again.

---

## Design options for Defect 1

| Option | Fixes | Cost | Gap |
|---|---|---|---|
| **A. Resume reclaims its original id** | The specific reported sequence | Must persist sessionId→name; reclaim can fail if slot re-taken | Doesn't stop a *fresh* session taking a freed slot; doesn't protect already-queued mail |
| **B. Key identity on stable UUID, tmux name = display alias** | Root cause, durably | Largest: adoption path for running sessions, post-boot UUID, codex parity, message back-compat | Chicken/egg at spawn; this is plan **029**'s scope |
| **C. Recipient fingerprint validated at delivery** | Converts silent misroute → loud failure | Small, additive, back-compatible | Doesn't preserve continuity — message fails rather than arriving |
| **D. Never recycle indices** | Removes the collision source for new spawns | Small; needs a persisted high-water mark | Index sprawl (`--47`); doesn't protect mail already queued |

### Recommendation: C first, then D, feed B into 029

**C is the safety fix and should land first**, because the failure mode that
matters is silence. It is also cheaper than it looks — the detector already
exists in the data:

`created_at` is already carried into every derived peer record (`cctrl:1958`,
sourced from metadata) and is confirmed live in `peer ls --json`. Metadata is
written once, at detached creation (`cctrl:1760` is the sole call site), so for a
live session `created_at` is stable; a recycled name gets a **fresh** one. Hence:

> If `message.created_at < peer.created_at`, the current occupant of that name was
> born after the message was sent, and is therefore **not** the addressee.

That check needs **no new field, no migration, and no rewrite of stored
messages** — it is sound for every message already sitting in the queue tonight.
A live addressee always predates mail sent to it, so it cannot false-positive.
Stamping an explicit fingerprint at send time (peer `created_at`, plus
`sessionId` where resolvable) is the more robust follow-on; messages lacking the
stamp fall back to the `created_at` comparison, and older ones to today's
behaviour.

On detection, **do not deliver.** Mark the message failed with an explicit reason
(`addressee replaced`) so the sender learns, rather than delivering to a session
that cannot know the instruction was not meant for it. Misrouting is worse than
failing — plan 029 already states this principle for replies; it applies equally
to forward delivery, and 029 does not currently cover the recycled-occupant case.

**D** then removes the collision source cheaply. Note the sprawl the `cctrl:1258`
comment was avoiding is real but cosmetic, and it can be bounded by a per-base
high-water mark rather than an unbounded counter.

**A** is not worth doing on its own — it fixes one path into a general problem.
It becomes free once B lands, since B must persist the UUID anyway.

### → 029

Plans 028/029 cover an addressee being **closed or renamed** (address stranded →
`Unknown recipient`, a loud failure). They do **not** cover an addressee being
**replaced** by a different session at the same address, which fails *silently* and
is the more dangerous half. Recommend 028's proposal explicitly adds:
occupant-identity validation at delivery time, and a statement that index reuse
(`cctrl:1258`) is part of the identity design rather than an unrelated naming
detail. Routing this via the fleet manager rather than editing 028/029 directly.
