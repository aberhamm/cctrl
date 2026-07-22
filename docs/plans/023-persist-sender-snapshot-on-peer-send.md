---
id: 023
title: Persist a sender snapshot on peer send
status: done
completed: 2026-07-22
blocked-by: []
priority: 23
goal: cctrl-peer-messaging-discoverable-models
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-19
reviews:
  - type=eng verdict=approved date=2026-07-19 by=mstack-review
---

## Requirements

A cctrl session that receives a peer message cannot reliably tell **which**
session sent it. `_peer_cmd_send` resolves the sender to a full peer object —
containing `session`, `tmux_target`, `agent`, `host`, `dir`, `purpose` — uses it
only to canonicalize `from` down to a bare name string, and then throws the
object away (`cctrl:2635-2653`). The stored message keeps `from: "<name>"` and
nothing else (`cctrl:2663-2686`).

Because derived peer names *are* tmux session names (`_peer_derived_json`,
`cctrl:1948`), that bare name is an ephemeral address. When the sender's session
closes, the only identity the receiver has becomes unresolvable — this is the
observed failure where a session reported that its earlier reply had gone to a
session id that no longer existed.

This plan captures a durable sender snapshot at send time so every new message
carries unambiguous sender identity, and makes the human-facing readers display
it. It is purely additive: no migration, no rewrite of existing
`data/messages.jsonl` lines.

**Acceptance criteria:**

- [ ] `cctrl peer send` writes an additive `sender` object on newly-created messages containing `name`, `label`, `tmux_target`, `agent`, and `host`.
- [ ] `sender.name` equals the canonical `from` value; the top-level `from` field is still written exactly as it is today (no field removed, no field renamed).
- [ ] `sender.label` resolves as `display_label // purpose // name`, so a receiver sees a human-meaningful label such as `@homelab` rather than only `TMUX--ms--homelab`.
- [ ] `_session_list --json` exposes an additive `display_label` field, and `_peer_derived_json` carries it through to derived peer objects.
- [ ] `_peer_all_json`'s manual-peer merge block also carries `display_label` through, so a peer that is **both** manually registered and has a live tmux session still resolves a real label instead of silently falling back to `purpose // name`.
- [ ] Messages sent with `--from user` (the human sender) still succeed and carry `sender: {name: "user", label: "user"}` with no invented tmux/agent fields.
- [ ] Messages sent with `--allow-unknown` where the sender does not resolve still succeed and carry a minimal `sender: {name: "<from>"}` rather than failing or omitting the object.
- [ ] `cctrl peer show`, `inbox`, `outbox`, and `recv` human output render sender identity readably; a nested `sender` object never renders as a flattened `tostring` blob.
- [ ] All reader paths fall back to bare `from` when `sender` is absent, so the ~existing messages in `data/messages.jsonl` keep displaying correctly.
- [ ] `cctrl peer show <id>` no longer emits `jq: error ... string ("") and object cannot be added` before its output. `_peer_print_human`'s `value` helper must handle an array of **objects** (`.history`) instead of calling `join(", ")` on it.
- [ ] `cctrl peer send --json` output includes the `sender` object.
- [ ] `data/messages.jsonl` and `data/peers.json` are not edited in place by this plan; only newly-appended messages carry the new field.

## Design

`_peer_cmd_send` already computes `from_peer_json` via `_peer_resolve_json`
(`cctrl:2635` in the strict branch, `cctrl:2646` in the `--allow-unknown`
branch). The fix is to stop discarding it: build a `sender` object from that
JSON and add it to the `jq -cn` message construction at `cctrl:2663-2686`.

**Sender object shape** (all fields optional except `name`, so unresolvable
senders degrade gracefully):

```json
"from": "TMUX--ms--homelab",
"sender": {
  "name": "TMUX--ms--homelab",
  "label": "@homelab",
  "tmux_target": "TMUX--ms--homelab",
  "agent": "claude",
  "host": "local"
}
```

Use `with_entries(select(.value != null))` so absent fields are omitted rather
than written as `null`, matching the existing peer-object convention in
`_peer_derived_json`.

**The label problem.** Session metadata already stores a human `display_label`
(e.g. `@homelab`, written by `_session_write_metadata` at `cctrl:1189-1220`),
but `_session_list --json` does not emit it, so `_peer_derived_json` — which is
built from `_session_list --json` — cannot see it. Add `display_label` as an
additive field to the `_session_list --json` item construction (`cctrl:4880`
region) and pass it through `_peer_derived_json` (`cctrl:1943-1960`). Adding a
field to `_session_list --json` is backward compatible; existing consumers
select the keys they need. If that surface proves riskier than expected, the
fallback is to read the value directly in `_peer_derived_json` via
`_session_metadata_field "$name" display_label`.

Resolve `label` as `display_label // purpose // name` — but **`//` alone is not
enough**. jq's `//` only falls through `null` and `false`, not empty strings
(`"" // "x"` returns `""`, verified). And `_session_write_metadata` writes
`display_label: $display_label` at `cctrl:1213` **without** the empty→null
conversion that `purpose` gets on the very next line, so a session launched
without a display label stores `""`. A naive `//` chain would therefore emit
blank labels — the headline feature silently producing nothing. Normalize empty
to null first, e.g. `(.display_label | select(. != "")) // (.purpose | select(. != "")) // .name`,
and apply the same treatment anywhere `with_entries(select(.value != null))` is
used to prune the `sender` object: it drops nulls but keeps `""`, so extract
with `// empty` semantics rather than passing `""` through `--arg`.

**Sender field presence is per sender class, not uniformly optional.** State it
explicitly so tests do not encode a lie:

| sender class | name | label | tmux_target | agent | host |
|---|---|---|---|---|---|
| live derived tmux peer | yes | yes | yes | yes | yes |
| manual / polling-only peer | yes | yes | **absent** | if known | yes |
| `--from user` | yes | `user` | absent | absent | absent |
| unresolved `--allow-unknown` | yes | absent | absent | absent | absent |

**Use the session's recorded host, not the ambient one.** `_peer_derived_json`
stamps `host` from `${CCTRL_HOST_PREFIX:-local}` (`cctrl:1924`), which is the
host of whoever is *running the command*, not necessarily the host the sender's
session was created on — session metadata already records the real value
(`cctrl:1217`). For a durable snapshot, prefer the metadata `host` and fall back
to the ambient label only when metadata has none.

**`_peer_derived_json` is not the only place that needs the passthrough.**
`_peer_all_json` (`cctrl:1978-2001`) rebuilds a peer object field-by-field for
any peer that is *both* manually registered *and* has a live derived tmux
session. That merge block explicitly copies `dir`, `agent`, `session`,
`purpose`, and `capabilities` from `$derived_merge` but would drop
`display_label` unless it is added there too. This is the common,
test-exercised case — not an edge case — so an implementation that only
touches `_peer_derived_json` will satisfy the label requirement for
unregistered derived peers and silently fall back to `purpose // name` for
registered ones. Add the field in both places.

**Rendering.** The two renderers fail differently and need different fixes.
`_peer_print_human` (`cctrl:2045-2054`) flattens every top-level key with
`tostring`, so a nested `sender` object renders as an unreadable inline JSON
blob — special-case `sender` there to emit a single readable line such as
`  from: @homelab (TMUX--ms--homelab, claude)` and suppress the raw nested
dump. `_mailbox_print_messages_human` (`cctrl:2466-2471`, used by
**`_peer_print_human` is shared — do not let message changes leak into peer
output.** It renders message envelopes (`peer show`) *and* peer identity objects
(`_peer_cmd_whoami` at `cctrl:2284`, `peer resolve`). A sender-specific or
history-omitting change made naively will alter `whoami` / `resolve` output too.
Either make the renderer generically object-safe (preferred — it also fixes the
`join` bug below for every caller) or split message rendering into its own
function. Do not special-case by key name in a way that silently reshapes peer
output.

**Fix the pre-existing `join` bug while you are in there.** `_peer_print_human`'s
`value` helper does `if type == "array" then join(", ")`, but `.history` is an
array of *objects*, which jq cannot join — so `cctrl peer show <id>` already
prints `jq: error (at <stdin>:34): string ("") and object cannot be added`
before its output today (reproduced against a live message). It is cosmetic but
it is emitted on every `show`, it lands in the exact helper this plan rewrites,
and the same helper is where the `sender` special-case goes. Make `value`
render arrays of objects readably (or omit `history` from the human view)
rather than leaving the error in place.

`_mailbox_print_messages_human` (`cctrl:2466-2471`, used by
`inbox`/`outbox`) is by contrast a hand-written fixed template
(`"\(.id)  \(.status)  \(.from) -> \(.to)  \(.subject // "")"`) that ignores
unlisted fields entirely — it would not produce a blob, it would simply omit
sender. There the fix is to add the label to the template. Every reader must
fall back to the bare `from` string when `sender` is absent.

**Backward compatibility is the whole point of this plan.** ~16 concurrent
sessions are reading and writing this store right now. Adding a key to
newly-appended JSONL lines cannot break a reader that does not select it, and
every reader added here tolerates the key's absence. Do not add a migration, do
not rewrite existing lines, do not change `from`.

**Files expected to change:**

- `cctrl`: `_peer_cmd_send` (build + persist `sender`), `_session_list` (emit `display_label`), `_peer_derived_json` **and** `_peer_all_json` (carry `display_label` through both paths), `_peer_print_human` (special-case nested `sender`) and `_mailbox_print_messages_human` (add label to the fixed template)
- `tests/run-tests.sh`: new assertions in the peer mailbox test group

**Testing approach: E2E** — the peer tests invoke the real `cctrl` binary
against an isolated `CCTRL_DATA_DIR`, exercising send/read end to end.

**Out of scope:** the inline-delivery envelope (plan 024), any MCP surface
change (plan 025), any documentation (plan 026), and any change to how peer
names are derived from tmux session names. Do not attempt to make peer addresses
stable across session close — that is a deliberately deferred limitation.

## Tasks

1. Add an additive `display_label` field to the `_session_list --json` item construction, and carry it through **both** `_peer_derived_json` and the `_peer_all_json` manual-peer merge block into resolved peer objects.
2. In `_peer_cmd_send`, retain `from_peer_json` and build a `sender` object (`name`, `label`, `tmux_target`, `agent`, `host`), dropping null fields.
3. Handle the three sender cases: resolved peer (full object), `from == "user"` (name + label only), and unresolved `--allow-unknown` (name only).
4. Add `sender` to the `jq -cn` message construction, leaving `from` and every other existing field byte-identical.
5. Special-case `sender` rendering in `_peer_print_human`, and add the sender label to `_mailbox_print_messages_human`'s fixed template, with fallback to bare `from` when absent.
6. Add tests: `sender` present and correct on send; `from` unchanged; legacy message without `sender` still renders; `user` and `--allow-unknown` sender cases; `display_label` surfaces in `_session_list --json`; a registered-peer-with-live-session resolves a real `label` (covers the `_peer_all_json` path).
7. Add a test asserting `cctrl peer show <id>` emits **nothing on stderr** (guards the `join` fix — the current jq error is printed to stderr, so an empty-stderr assertion is the regression pin).
8. Add a test for the label fallback when `display_label` is the **empty string** (not merely absent) and `purpose` is unset: `sender.label` must equal `sender.name`, never `""`. This is the jq `//` trap — assert it explicitly.
8a. Add a test asserting `cctrl peer whoami --json` and `peer resolve` output are unchanged by the renderer edits.
9. Run the full suite and confirm no existing peer assertion regressed.

## Verification

Checks:

- `[cmd] bash tests/run-tests.sh`
- `[assert] cd "$(mktemp -d)" && CCTRL_DATA_DIR="$PWD" ~/dev/cctrl/cctrl peer send x --from y --allow-unknown --json -- "hi" | jq -r '.sender.name'` contains `y`
- `[assert] cd "$(mktemp -d)" && CCTRL_DATA_DIR="$PWD" ~/dev/cctrl/cctrl peer send x --from y --allow-unknown --json -- "hi" | jq -r '.from'` contains `y`
- `[cmd] bash -c 'h1=$(shasum data/messages.jsonl 2>/dev/null || echo absent); bash tests/run-tests.sh >/dev/null 2>&1; h2=$(shasum data/messages.jsonl 2>/dev/null || echo absent); [ "$h1" = "$h2" ]'` — the live store must be byte-identical before and after the suite runs. **Do not** use `git status --porcelain data/...`: `data/` is gitignored (`.gitignore:39`) and untracked, so that form returns empty regardless of content and verifies nothing.
- `[assert] bash -c 'jq -r ".sender // \"absent\"" <<< "{\"from\":\"a\",\"to\":\"b\"}"'` contains `absent` (legacy-shape message parses without error)
- `[manual] Confirm human output of `cctrl peer show <id>` renders sender on one readable line, not as a raw nested JSON blob.`

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | issues_found | 11 findings, 9 folded, 1 tension resolved, 1 promoted to plan 028 |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 15 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

**CODEX:** found 11 defects the review missed, including two that would have shipped broken — jq `//` not falling through empty strings (blank labels) and `_peer_tmux_target_for_delivery` mutating the in-flight delivery target. Both reproduced and folded.

**CROSS-MODEL:** one tension (reply via nudge vs `deliver --inline`); resolved in favour of the atomic `peer reply` introduced by plan 027, which supersedes both. Everything else was additive, not contradictory.

**VERDICT:** ENG CLEARED — ready to implement. Batch expanded 4 → 6 plans; 027 and 028 were promoted from deferred TODOs on review evidence.

NO UNRESOLVED DECISIONS
