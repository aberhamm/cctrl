---
id: 025
title: Teach the peer MCP surface and add an entry point
status: pending
blocked-by: [023, 027]
priority: 25
goal: cctrl-peer-messaging-discoverable-models
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-19
reviews:
  - type=eng verdict=approved date=2026-07-19 by=mstack-review
---

## Requirements

A model that has never used peer messaging has to work far too hard to discover
that it exists, what the surface is, and how to use it correctly. `lib/peer_mcp.py`
advertises 8 tools with one-line descriptions and no entry point. `send_message`
is described as *"Queue a message from this server's identity to another peer"* —
which never tells the model how to find a peer to address, that `list_peers`
exists, that messages must be acked, or how to reply to something it received.

There is also no single call that orients a model: answering "who am I, who else
is out there, do I have mail?" currently takes three separate tool calls that a
model has to know to make in the first place.

This plan makes the existing surface teach itself and adds one obvious entry
point. **Every existing tool name is preserved** — roughly 16 sessions are live
right now with the current tool list already loaded, and renaming a tool would
make their calls fail with `unknown-tool` until each is restarted.

**Acceptance criteria:**

- [ ] All 8 existing tool names (`whoami`, `list_peers`, `resolve_peer`, `send_message`, `check_messages`, `recv_message`, `show_message`, `ack_message`) are present and behave exactly as before.
- [ ] Each of the 8 descriptions explains what the tool does *and* how it fits the workflow, so a model reading only `tools/list` can operate the mailbox correctly without external docs.
- [ ] `send_message`'s description states how to address a peer (a name from `list_peers`) and that replying means sending to the received message's sender identity.
- [ ] `recv_message`'s description states that received messages carry a `sender` object identifying who to reply to, and that messages must be acked after handling.
- [ ] A new entry-point tool is added that returns this peer's identity, the list of reachable peers, and an unread mailbox summary in a **single** call.
- [ ] A new `cctrl peer overview [--as NAME] [--json]` subcommand returns identity + peers + mailbox summary from a **single** session enumeration, and the MCP entry-point tool is a thin passthrough to it.
- [ ] `cctrl peer overview --json` completes in roughly the cost of one existing peer command (~1.4s on a 15-session fleet), not three. Composing three separate CLI calls measured ~4.3s, because `peer whoami`, `peer ls`, **and** `peer check` each independently resolve identity through `_peer_all_json` → `_session_list`.
- [ ] `cctrl peer overview` is usable directly from the CLI (not only via MCP), so plan 026's agent contract can point at one orientation command.
- [ ] When peer discovery is **skipped** (`derived_skipped: true`), the entry point still returns identity and mailbox counts with an empty peer list and the skip reason. It does **not** claim to survive a failure that prevents the MCP server from starting at all — identity is resolved before stdin is read (`lib/peer_mcp.py:300`), so that case is unreachable by construction.
- [ ] Its description marks it as the tool to call first when a model has not used peer messaging before.
- [ ] The MCP bridge continues to pass its existing stdio contract test (`test_peer_mcp_bridge_stdio`), including `initialize`, `tools/list`, and `tools/call`.
- [ ] `tools/list` contains all 8 original tool names plus `peer_overview`. Assert by **name membership**, never by an exact total count — pending plan 011 independently adds a 9th tool (`say_peer`) to the same `TOOLS` list and carries no review gate, so it may land before this plan and would break any hardcoded count.

## Design

`lib/peer_mcp.py` is a dependency-free stdio JSON-RPC bridge. Tools are declared
in the module-level `TOOLS` list and dispatched in `Bridge.call_tool`. Both need
touching; nothing else in the file should change.

**Descriptions are the product here.** These strings are the entire discovery
surface for a model. Write them as operating instructions, not labels. Each
should answer: what does this do, when do I reach for it, and what do I do next.
Cross-reference sibling tools by name so the model can navigate — the workflow
to teach is:

```
peer_overview  →  send_message                (start a conversation)
peer_overview  →  recv_message  →  ack_message  (handle incoming)
                  recv_message  →  send_message(to sender.name)  (reply)
```

**The entry-point tool.** Name it `peer_overview` — a new name cannot collide
with the 8 preserved ones. It is a thin passthrough to a new
`cctrl peer overview --json` subcommand.

**Why a CLI subcommand rather than three composed calls.** Measured on a live
15-session fleet: `peer whoami --json` 1.426s, `peer check --json` 1.462s,
`peer ls --json` 1.438s — about 4.3s composed. Each independently resolves
identity through `_peer_all_json` → `_session_list`, which walks every tmux
session and reads every session metadata file. Paying that walk three times for
one answer is both slow and a DRY violation, and it lands on the one tool the
descriptions tell every model to call first. A single subcommand does one
enumeration and serves all three answers (~1.4s). It also gives CLI-side agents
and plan 026's contract a single orientation command instead of a three-step
recipe.

Shape returned by `cctrl peer overview --json`, which `peer_overview` passes
through unchanged:

```json
{
  "identity": { ...resolved peer object... },
  "peers":    [ ...reachable peers... ],
  "mailbox":  { "queued": N, "delivered_unacked": N, "oldest_queued_age_seconds": N }
}
```

Build it by resolving `_peer_all_json` **once** and deriving all three sections
from that single result, rather than calling the three existing `_peer_cmd_*`
helpers (each of which would re-enumerate). Reuse their output shapes verbatim
so the JSON contract stays consistent with the commands agents already know.

Degrade gracefully **within the reachable envelope**: if peer discovery is
skipped, still return identity and mailbox counts with an empty peer list plus
the `derived_skipped` reason, rather than failing the whole call.

Be honest about the limit of that promise. The MCP server cannot degrade past
its own startup: `cctrl peer mcp` resolves identity before launching Python
(`cctrl:4358`) and `main()` resolves `whoami` before reading stdin
(`lib/peer_mcp.py:300`). If peer resolution is broken badly enough, the server
never starts and `peer_overview` is unreachable by construction. Do not write an
acceptance criterion promising graceful degradation for that case, and do not
write a test that claims to cover it.

**Do not frame this as "tmux unavailable."** `_peer_derived_json`
(`cctrl:1923-1937`) already handles a missing tmux at the bash layer, returning
`{skipped: true, reason: "tmux unavailable", peers: []}` and **exiting 0**. So
`cctrl peer ls --json` never raises a nonzero exit for that case and
`Bridge.cli()` never throws — a test that removes tmux would take the normal
success path and pass without exercising the fault-tolerant branch at all. The
degradation requirement is a genuine defensive `try/except` with no
CLI-observable trigger today. If a test must exercise it, corrupt the peers data
file so `_peer_all_json`'s `jq -n --argjson` fails; otherwise assert the
`derived_skipped` passthrough instead and do not claim coverage of a failure
path that cannot currently fire.

Its description should say plainly that it is the first call to make, and that
it answers who am I / who can I reach / do I have unread messages.

**Depends on plan 023** because the `recv_message` and `show_message`
descriptions promise a `sender` object on received messages. Those descriptions
would be wrong if written before 023 persists it.

**No renames, no removals, no signature changes.** Adding a tool to `tools/list`
is safe for running sessions: they simply do not know about it until they
restart. Changing or removing an existing name is not.

**Files expected to change:**

- `cctrl`: new `_peer_cmd_overview` (single-enumeration identity + peers + mailbox), its dispatcher case, and its `peer help` line
- `lib/peer_mcp.py`: `TOOLS` (8 rewritten descriptions + 1 new entry), `Bridge.call_tool` (dispatch `peer_overview` as a passthrough)
- `tests/run-tests.sh`: extend `test_peer_mcp_bridge_stdio`, add CLI coverage for `peer overview`

**Note on file overlap:** this plan now touches `cctrl`, as does plan 024. They
are siblings (both blocked by 023) with no edge between them. The functions are
disjoint — 024 works in `_peer_deliver_one_locked` / `_peer_record_inline_json`,
this plan adds a new `_peer_cmd_overview` plus a dispatcher case — and mstack
executes plans serially with a commit between, so the conflict risk is low.
Whichever lands second should re-read the dispatcher region before editing.

**Testing approach: E2E** — the bridge test drives real JSON-RPC over stdio
against the real `cctrl` binary.

**Out of scope:** the tmux delivery path (plan 024) and repo documentation
(plan 026). Note that the earlier "no new CLI subcommand" boundary was
**deliberately overridden** in eng review on measured evidence (4.3s vs 1.4s);
`cctrl peer overview` is now in scope. Do not reintroduce the three-composed-call
approach. Do not rename or remove any existing tool. Do not add a `say_peer`
tool or any direct-chat surface: plans 010/011 are unimplemented and this plan
must not depend on or anticipate them.

## Tasks

1. Rewrite all 8 tool descriptions in `TOOLS` as workflow-aware operating instructions that cross-reference sibling tools by name.
2. Add a `peer_overview` entry to `TOOLS` with an empty-object input schema and a description marking it as the first call to make.
3. Implement `_peer_cmd_overview` in `cctrl`: resolve `_peer_all_json` once, derive identity + peers + mailbox from that single result, add the dispatcher case and the `peer help` line.
4. Implement the `peer_overview` branch in `Bridge.call_tool` as a thin passthrough to `cctrl peer overview --json`, and make it fault-tolerant so identity and mailbox counts survive a peer-discovery failure.
4a. Add a CLI test for `cctrl peer overview --json` asserting all three sections, and assert single-enumeration by **counting tmux invocations via the fake-tmux harness** — not by timing. A wall-clock assertion is unreliable under load and proves nothing about the code path.
4b. Ensure `_peer_cmd_overview` does not call `_mailbox_resolve_identity_for_mode`, `_peer_cmd_whoami`, or `_peer_cmd_check` — each re-enters peer resolution and re-enumerates sessions (`cctrl:2307`, `cctrl:2895`), silently defeating the single-enumeration requirement. Resolve identity locally from the one `_peer_all_json` result.
5. Extend `test_peer_mcp_bridge_stdio`: assert all 8 original names still present **by name**, assert `peer_overview` present, assert a `peer_overview` call returns all three sections. Do not assert an exact tool count.
6. Assert `peer_overview` passes through `derived_skipped` when peer discovery is skipped; only write a hard failure-path test if you first make `peer ls --json` genuinely fail (corrupt peers data), otherwise omit it rather than writing a vacuous test.
7. Run the full suite and confirm no existing MCP assertion regressed.

## Verification

Checks:

- `[cmd] bash tests/run-tests.sh`
- `[cmd] python3 -c "import ast,sys; ast.parse(open('lib/peer_mcp.py').read())"`
- `[assert] python3 -c "import re;src=open('lib/peer_mcp.py').read();names=re.findall(r'\"name\": \"(\w+)\"',src);print(' '.join(names))"` contains `whoami list_peers resolve_peer send_message check_messages recv_message show_message ack_message`
- `[assert] python3 -c "import re;src=open('lib/peer_mcp.py').read();print('peer_overview' in src)"` contains `True`
- `[cmd] bash -c 'tmp=$(mktemp -d) && mkdir -p "$tmp/comet" && CCTRL_DATA_DIR="$tmp/data" ./cctrl peer register comet --dir "$tmp/comet" --agent codex >/dev/null && printf "%s\n" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}" | CCTRL_DATA_DIR="$tmp/data" ./cctrl peer mcp --as comet | python3 -c "import sys,json;d=json.load(sys.stdin);n=[t[\"name\"] for t in d[\"result\"][\"tools\"]];assert \"peer_overview\" in n, n;assert all(x in n for x in [\"whoami\",\"list_peers\",\"resolve_peer\",\"send_message\",\"check_messages\",\"recv_message\",\"show_message\",\"ack_message\"]), n"'` — registers a real peer in an isolated data dir and asserts tool names by membership. **Do not** invoke `python3 lib/peer_mcp.py --as x` directly with an unregistered peer: `main()` calls `cctrl peer whoami` at startup and exits 66 before reading stdin, so the check would fail on a correct implementation.
- `[manual] Read the 9 descriptions cold and confirm a model with no prior context could run send → recv → ack → reply from them alone.`

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
