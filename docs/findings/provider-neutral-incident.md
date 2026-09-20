# Provider-neutral launch and discovery

cctrl honors explicit provider selection and its existing environment, profile,
and configuration precedence. The bundled spawn and fleet skills follow that
selection for workers and reviewers. They no longer select Claude implicitly
for general work. This does not change an operator's configured default.

## Launch and profile behavior

Agent-aware profiles take their model from the selected agent's settings. Legacy
model/environment overlays remain Claude-only, and explicit CLI model flags win.
Provider-specific model names are passed through without substring-based guesses.
The existing launch adapters and normalized sandbox/approval flags remain intact.

The resource guard counts managed tmux markers directly, so a launch does not
wait for transcript inventory. Unmarked legacy sessions are omitted from this
contextual count; memory availability remains the resource gate.

## Bounded discovery and honest telemetry

Codex rollout discovery uses one Python process and one read-only SQLite
connection. It filters historical timestamps before reading prompts, preserves
explicit resume identity, and leaves ambiguous or incomplete results unknown.
Each lookup is limited to two seconds, 10,000 files, 16 MiB total input, and
1 MiB per line. A prompted fresh-launch match also requires the recorded launch
directory. Unresolved prompts cannot fall back to stale IDs for title/archive
operations. Title polling counts lookup time, and provider database lock waits
are bounded.

Session listing only interprets known leading model flags. Prompt text and
free-text configuration arguments stop model observation because process listings
lose argument boundaries. Codex sessions do not inherit Claude bridge, recency,
recap, or state evidence. Displayed models are command observations, not a claim
to track model changes made inside a running TUI.

The task inventory, fleet/peer adapters, lifecycle reducer, and terminal/app
ownership paths are retained. Claude bridge repair remains a Claude capability;
Codex app ownership requires authoritative app evidence. Discovery never creates
an additional writer or grants ownership by itself.

## Verification and limits

The focused `provider-neutral` test group covers historical rollout volume,
SQLite contention, ambiguous and cross-repository identity, resume behavior,
large prompt budgets, stale telemetry, profile isolation, Unicode launch quoting,
receipt recovery, and elapsed polling. Related task-record, fleet, app-owned
launch, attestation, reconciliation, and handoff groups passed at the incident
checkpoint. Syntax and diff checks passed; independent Codex review verified the
corrected discovery and ownership boundaries.

The ownership matrix passed after correcting the detached-title fixture to
preserve subsecond file timestamps. The shell suite passed in two segments: the
initial run reached an outdated prune fixture, then the corrected prune tests and
all remaining tests passed. The prune fixtures now provide exact rollout IDs and
verify that cwd alone cannot authorize pruning. Independent Codex review approved
the fixture correction. All 85 Python tests passed separately. ShellCheck retains
its existing findings; a clean ShellCheck result is not claimed.

Budgets apply per lookup, not to the complete fleet command. A write already in
progress can finish after a polling deadline, and incomplete discovery can leave
a title or provider ID temporarily unresolved.

See [terminal receipt recovery](terminal-receipt-recovery.md) for the separate,
explicitly applied recovery procedure and its single-writer safeguards.
