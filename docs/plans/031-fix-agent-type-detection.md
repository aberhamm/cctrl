---
id: 031
title: Record agent type at spawn and stop sniffing it from the whole argv
status: pending
blocked-by: []
priority: 31
goal: cctrl-peer-identity-integrity
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-20
---

## Requirements

Agent type is never recorded. It is inferred at display time from the pane
process's **entire argv**, with `codex` tested first (`cctrl:4818-4819`):

```bash
if [[ "$cmd" == *claude* || "$cmd" == *codex* ]]; then
    [[ "$cmd" == *codex* ]] && agent="codex" || agent="claude"
```

`$cmd` is `ps -o command= -p <pane_pid>` (`_session_agent_cmd`, `cctrl:4477`) —
the full argv including the seed prompt, which is passed as a trailing
positional argument. So **any Claude session whose prompt contains the string
`codex` is labelled `codex`**, including `~/.codex/...` paths and prose.

**Second sniff site, same defect.** `_session_agent_cmd` itself (`cctrl:4485`)
decides whether to fall back to the pane's child process using the *same*
`*claude*`/`*codex*` substring test on the parent argv. A wrapper whose parent
argv contains `codex` in a non-binary token satisfies the test and suppresses
the child lookup. This plan must fix that site too, not only the display-time
classifier at `cctrl:4818`.

Confirmed live on two sessions. `TMUX--ms--cctrl` was spawned with an explicit
`--agent claude` and registered as `codex`, because its briefing text contained
the word `codex`. `TMUX--ms--obsidian-vault--5` matches because its prompt cites
`~/.codex/config.toml`; both are Claude sessions running Opus 4.8.

**This is not cosmetic.** `_peer_derived_json` lifts the same field
(`cctrl:1952`) and it selects the modal-detection regex during delivery:
`_peer_deliver_one_locked` reads `agent` (`cctrl:3263`) and passes it to
`_peer_pane_ready_for_delivery` (`cctrl:3099`), which branches — claude checks
for the `❯ 1.` marker (`cctrl:3110-3118`), codex checks for
`Allow Codex to |approve network access|…` (`cctrl:3120-3134`). A Claude pane
scanned for Codex markers never matches, so the pane reports **ready** while a
Claude approval modal is open, and `_peer_tmux_paste` (`cctrl:3147-3164`) pastes
the nudge and presses Enter — answering the modal. This defeats commits
`3a148c7` and `64bc712` exactly where they were meant to help.

**Acceptance criteria:**

- [ ] `_session_write_metadata` persists an `agent` field. This is a
      **signature change** to a function with one call site (`cctrl:1760`); the
      implementer must add the parameter to the `jq -n` object at
      `cctrl:1188-1220` and pass `$detach_agent` at the call site. The value is
      available at launch: `CCTRL_AGENT` is exported at `cctrl:444` and
      `cctrl:1619` (`$detach_agent`), and `--agent` is parsed at `cctrl:1480`.
- [ ] `_session_list` prefers the recorded metadata `agent` over any sniff.
- [ ] The sniff **fallback** matches on `argv[0]`'s basename, not a substring of
      the full command string, and does not privilege `codex` over `claude`.
      **Both** sniff sites are fixed: the display classifier (`cctrl:4818`) and
      the child-fallback gate inside `_session_agent_cmd` (`cctrl:4485`). Route
      both through one shared helper so they cannot diverge.
- [ ] A Claude session whose prompt/argv contains the string `codex` (including
      `~/.codex/...`) reports `agent=claude`. Regression-test this literal case.
- [ ] A real Codex session still reports `agent=codex`.
- [ ] `_session_prune`'s duplicate `*codex*`-first test (`cctrl:5863-5869`) is
      fixed via the same shared helper, not patched independently. (This is a
      hard ordering dependency for plan 033, which routes name-release through
      prune.)
- [ ] `cctrl peer doctor`'s hook routing (`cctrl:4254`, gated on
      `[[ -z "$agent" || "$agent" == "codex" ]]`) resolves correctly for a
      mislabelled-today Claude session.
- [ ] The ~15 sessions **currently running** have no `agent` in their metadata
      and will not gain one without a restart. They must classify correctly from
      the corrected fallback alone. Verify against real live panes, not fixtures.
- [ ] `data/peers.json` and `data/messages.jsonl` are not edited by this plan.

## Design

Two independent defects compound at `cctrl:4818-4819`: an unanchored substring
test, and codex-first precedence. Fixing only the precedence still mislabels a
Claude session whose prompt says `codex` but not `claude`; fixing only the
anchoring leaves the ordering bug latent. Fix both, in one helper.

**Why metadata alone is insufficient.** `_session_write_metadata` has a single
call site — `cctrl:1760`, detached creation only. Nothing rewrites metadata for
a running session. So every session alive right now would keep classifying via
the fallback. The corrected sniff is therefore the load-bearing fix for the
live fleet, and the metadata field is the durable fix for sessions spawned
after this lands. Do not let the metadata path mask an under-tested fallback.

**Extracting argv[0].** `_session_agent_cmd` returns the full command string.
Take the first whitespace-delimited token and its basename:

```bash
_agent_from_cmd() {
    local cmd="$1" bin
    bin="${cmd%% *}"; bin="${bin##*/}"
    case "$bin" in
        claude) printf 'claude' ;;
        codex)  printf 'codex' ;;
        *)      ;;   # unknown → empty, caller decides
    esac
}
```

**Gotcha — interpreter and wrapper prefixes.** `argv[0]` is not guaranteed to be
the agent binary. If either CLI is invoked via `node /path/to/codex.js`, argv[0]
is `node` and the basename test returns empty. Verify what `ps -o command=`
actually reports for a **real codex pane on this machine** before settling the
matcher; if a wrapper is in play, scan argv *tokens* for an exact basename match
of `claude`/`codex` while skipping the trailing prompt argument — never a
substring test over the joined string. The current live evidence
(`claude --permission-mode … --model …`) shows argv[0] is the bare binary for
Claude; confirm the codex side rather than assuming symmetry.

**Gotcha — empty result must not silently mean claude.** The existing code only
enters the branch when the string matches at all, so a non-agent pane gets no
agent. Preserve that: an unresolvable binary yields empty, and callers keep
their current empty-handling. Do not default to `claude`, or every shell pane
becomes a peer with a claude modal-detector.

**Ordering.** With an exact basename match, precedence stops mattering — but
write the matcher as an exhaustive `case` rather than two sequential `[[ ]]`
tests, so a future third agent cannot reintroduce the ordering bug.

**Metadata shape.** Add `agent` to the `jq -n` object literal at
`cctrl:1189-1220`, normalized through `_normalize_agent` (defined at
`cctrl:98`; the call sites at `cctrl:129`/`cctrl:235` show its use) so the
stored value matches the vocabulary `_session_list` and `_peer_derived_json`
already expect. Follow the existing empty→null convention in that block so an
unset agent stores `null`, not `""` — `_peer_derived_json`'s
`with_entries(select(.value != null))` prunes null but keeps `""`, and a stored
empty string would shadow the fallback with a falsy-but-present value.

**Verification.** The bug is reproducible on demand: spawn a Claude session
whose `-m` text contains the word `codex` and assert `cctrl session ls` reports
`claude`. That is exactly how it was found.
