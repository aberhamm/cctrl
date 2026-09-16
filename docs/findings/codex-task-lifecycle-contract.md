# Codex task lifecycle and ownership signal contract

Status: version 1, observed 2026-09-16

This contract is the source of truth for later cctrl attribution policy. It
describes what Codex exposes, what cctrl itself can know because it initiated a
transition, and what remains only a hint. It does not grant or simulate
concurrent access.

The single-writer limitation is fundamental: cctrl can report or transfer
ownership, but it cannot make one Codex task concurrently writable from tmux
and the app. A transfer succeeds only after the old writer exits. A lock file,
working directory, title, process argv, timestamp, or similar name is never
enough by itself to identify the writer.

## Evidence baseline

The baseline used for the checked-in fixtures is:

- Codex CLI `0.153.4` (`codex --version`)
- ChatGPT/Codex native app `26.908.40834`, build `8881`
- schemas generated with `codex app-server generate-json-schema
  --experimental --out <TEMP_SCHEMA_DIR>`
- read-only inspection of the local `threads` SQLite schema, rollout
  `session_meta` records, writer-lock paths, and the cctrl functions named
  below

The generated `Thread` shape exposes `id`, `forkedFromId`, and
`parentThreadId`. Its descriptions distinguish the fields precisely:
`forkedFromId` is the source task when a task was created by a fork, while
`parentThreadId` is set for a subagent. It exposes no provider root-task id.
Any `derivedRootId` in cctrl is therefore derived by walking one ancestry kind
at a time to its terminal ancestor; it must never be labeled provider-exposed.
Fork ancestry and subagent ancestry are separate graphs and must not be folded
into a single ambiguous `parent` field.

The implementation anchors for refreshing this contract are function names,
not line numbers:

- `_launch_exec_agent` establishes the process/control surface cctrl launched.
- `_session_write_metadata` persists host, conversation id, rollout path, and
  control surface.
- `_session_codex_rollout_path` correlates cctrl records to rollouts, with cwd
  only as an ambiguous final fallback.
- `_codex_rollout_thread_id` reads `payload.id` or `payload.session_id` from
  rollout `session_meta`.
- `_codex_app_threads_json` joins cctrl metadata with the SQLite task
  inventory.
- `_codex_thread_writer_lock_path` locates a task's lock, while
  `_codex_writer_lock_is_stale` deliberately requires the absence of a live
  tmux or matching Codex process before treating it as stale.
- `_session_release_to_app` stops the tmux owner, waits, handles only a stale
  lock, and then records `control_surface: app` as the requested destination.
  It does not observe the app acquiring the task.

## Canonical lifecycle matrix

The machine-readable schema is
`tests/fixtures/codex-lifecycle/lifecycle-matrix.schema.json`; the canonical
data is `matrix.json` beside it. `observed` means the named source exposes the
field. `derived` means cctrl computed it. `unsupported` means the source does
not expose it at this boundary.

| Scenario | Provider task id | Lineage | Strongest useful evidence | Result at the boundary |
|---|---|---|---|---|
| Native app `+` (empty composer) | unsupported; no id yet | unsupported | Visible empty composer is diagnostic-only | `unknown`; record nothing and never mint a fake identity |
| Native app first prompt | observed from `thread/start` | `forkedFromId=null`, `parentThreadId=null`; root derived as self | The response on the app-owned connection is authoritative; hook/rollout are corroborating | `app` |
| cctrl tmux launch | observed and persisted after launch | provider fields read from App Server when available; root derived | Successful cctrl launch transaction plus its session metadata is authoritative | `terminal` |
| `--remote unix://` | observed from the connected App Server | provider fields observed; root derived | Successful cctrl launch of the app-server-backed TUI is authoritative for the terminal surface; client argv alone is diagnostic-only | `terminal`; the task runtime is on the connected host, not the client device |
| Direct CLI resume outside cctrl | id may be observed in the resume request/rollout | unsupported unless read from App Server | argv is diagnostic-only; rollout is corroborating | `unknown` without an observed launch/ownership transaction |
| cctrl app-owned launch | observed from the response | provider fields observed; root derived | Successful cctrl App Server transaction plus recorded connected host is authoritative | `app` |
| App restart | same id observed after reconnect | unchanged when re-read | New App Server connection is authoritative; durable store is corroborating | `app` after successful reconnect; otherwise `unknown` |
| Host reboot | durable id remains in SQLite/rollout | may be unavailable until re-read | Durable store is corroborating; residual lock is diagnostic-only | `unknown` until a new owner transaction succeeds |
| Clear | same id | unchanged | Existing live owner remains authoritative; `SessionStart` source `clear` corroborates | unchanged owner |
| Compact | same id | unchanged | Existing live owner remains authoritative; `PreCompact`/`PostCompact` corroborate | unchanged owner |
| Fork | new id | `forkedFromId` is the immediate fork source; `parentThreadId` is not reused | `thread/fork` response is authoritative | owner of the connection that created the fork |
| Fork-of-fork | new id | `forkedFromId` is the immediate fork; root is derived by traversal | Repeated `thread/read` responses are authoritative for each edge | owner of the connection that created the fork |
| Subagent task | new id | `parentThreadId` is the subagent parent; `forkedFromId` is not reused | App Server thread response is authoritative | owner hosting the subagent task |
| `release-to-app` | unchanged | not changed by transfer | Verified tmux exit is authoritative only for ending terminal ownership; the metadata receipt records intent and lock handling corroborates cleanup | `unknown` until an app-side acquisition succeeds |

“Native app `+`” and “native app first prompt” are deliberately separate
states. The former is UI state without provider identity. Only the latter can
produce a provider task id. cctrl must not persist an empty-composer record or
guess an id from cwd, title, recency, or a later task.

## Signal classification

### Authoritative

An authoritative signal proves a specific fact at a specific boundary; it
does not make every field in the same payload authoritative.

- A successful App Server method response is authoritative for its returned
  provider task `id`, `forkedFromId`, and `parentThreadId`.
- A successful cctrl launch transaction is authoritative for the control
  surface and connected host that cctrl itself selected while that launched
  writer remains live. A release transaction is authoritative only for the
  old writer having ended; it cannot prove that the destination acquired the
  task.
- A cctrl metadata receipt written by that same transaction is authoritative
  for cctrl's declared intent and recorded task/host association. It is not a
  perpetual proof that the same process remains alive.

### Corroborating

Corroborating evidence can confirm an identity or transition but cannot select
an owner on its own:

- A rollout `session_meta` `payload.id`/`payload.session_id` is strong durable
  evidence for provider identity.
- A SQLite `threads.id` row is durable task-inventory evidence.
- A `SessionStart`, `PreCompact`, or related hook can associate an event with a
  task id and source.
- A writer-lock path can associate a lock with a provider id.
- tmux/process liveness can support a cctrl-owned launch or stale-lock decision.

### Diagnostic-only

These are useful for explaining a state, never for choosing an owner:

- cwd, title, purpose, timestamps, recency, or name similarity
- process argv, including a provider id that happens to appear in it
- writer-lock presence or absence by itself
- a visible app composer/window without a provider response
- a hook source without a matching provider id and transaction

In particular, `_session_codex_rollout_path` retains cwd fallbacks for
operational recovery, but attribution policy must not promote those fallbacks
to ownership evidence.

## Precedence and ambiguity truth table

Evaluate evidence for one exact provider id on one connected host. Evidence
for different ids must not be merged because cwd or titles match.

| App authoritative claim | Terminal authoritative claim | Corroboration | Outcome |
|---|---|---|---|
| yes | no | any | `app` |
| no | yes | any | `terminal` |
| no | no | any or none | `unknown` |
| yes | yes | any | `conflict` |
| claim refers to id A | claim refers to id B | cwd/title/name match | two separate tasks; never merge |
| one claim is stale/expired | no current claim | lock/argv/SQLite remain | `unknown` |

`conflict` is not a tie to break. It means two otherwise authoritative records
claim the same provider id at the same time or their ordering cannot be proven.
cctrl reports the conflict and requires an explicit release/reconciliation
flow. It never resolves `unknown` or `conflict` by cwd, title, recency, name
similarity, process argv, or lock presence.

Authoritative transaction evidence should carry its observation time and host.
Once the process/connection lifetime ends, it becomes historical evidence and
does not silently retain current-owner status. Durable records preserve task
identity, not live ownership.

## Hooks and lifecycle sources

Codex `0.153.4` advertises configuration for `SessionStart`, `SessionEnd`,
`PreCompact`, `PostCompact`, `UserPromptSubmit`, `Stop`, subagent, tool-use,
and permission hooks. The sanitized payload fixture records lifecycle source
values for startup, resume, clear, compact, fork, app-server, and CLI cases.
The contract treats them as follows:

- startup/resume/clear/fork: a `SessionStart` event can corroborate the
  provider id and transition source;
- compact: `PreCompact`/`PostCompact` are events within the same task, not a
  new identity or owner;
- app-server/CLI: the source describes how the runtime was entered, not who
  currently owns the writer forever;
- user-level hooks may run for more than one surface, including CLI and GUI/
  App Server paths, so “the hook ran” never means “terminal-owned.”

GUI processes may have a reduced PATH and do not necessarily inherit an
interactive shell environment. Hook commands must use stable executable paths
or arrange PATH explicitly. Project or user hook trust can also prevent or
pause execution; no attribution rule may treat a missing hook as proof that a
surface was absent. Never bypass hook trust merely to improve lifecycle
attribution.

Clear and compact do not change the provider id. Resume reopens an existing
id. Fork creates a new id and records `forkedFromId`. A subagent uses
`parentThreadId`; this is not evidence of a fork. Neither hooks, SQLite nor
rollout metadata in this baseline provides a provider-exposed root id.

## Store-specific field contract

| Source | Stable provider id | `forkedFromId` | `parentThreadId` | Root id | Ownership value |
|---|---|---|---|---|---|
| App Server v2 thread methods | observed `Thread.id` | observed nullable | observed nullable, subagent only | unsupported | initiating/connected surface only at the transaction boundary |
| Hook payload | observed `session_id` | unsupported in baseline payload | unsupported in baseline payload | unsupported | unsupported |
| SQLite `threads` | observed `id` | unsupported in inspected projection/schema contract | unsupported in inspected projection/schema contract | unsupported | unsupported |
| Rollout `session_meta` | observed `payload.id` or `payload.session_id` | unsupported | unsupported | unsupported | unsupported |
| cctrl session metadata | observed `conversation_id` after correlation | unsupported | unsupported | unsupported | cctrl transaction receipt in `control_surface`, not a provider field; after release it records intended destination, not observed acquisition |
| Writer lock | id derived from filename | unsupported | unsupported | unsupported | unsupported; presence is corroborating only |
| Process argv | sometimes observed as an argument | unsupported | unsupported | unsupported | unsupported; diagnostic-only |

The SQLite and rollout formats are internal persistence formats. Even when
stable across several versions, they are not promoted above documented/
generated App Server fields. Their use must fail to `unknown` when missing or
unreadable.

## Host and device boundary

Every cctrl ownership record is scoped to the connected host that owns the
task. A laptop controlling an App Server over `unix://` or another transport is
not itself the task owner; the server host is. Another device can open that
host only when the Codex remote connection is configured, reachable, and the
host is awake. cctrl does not infer reachability or duplicate an owner record
onto the viewing device.

After a host reboot, persisted identity may remain while live ownership is
`unknown`. After a successful reconnect/resume, a new authoritative boundary
can establish the current surface again. Cross-device availability and
single-writer ownership are separate questions.

## Fixture manifest and refresh policy

Fixtures live in `tests/fixtures/codex-lifecycle/`. `manifest.json` uses the
canonical `fixture-manifest.schema.json` shape. Every fixture has exactly one
entry with:

- Codex CLI and app versions;
- source and capture method;
- observation time and lifecycle scenario;
- per-field `observed`, `derived`, or `unsupported` status;
- approved sanitization placeholders; and
- a refresh/invalidation rule.

Run the validator directly with:

```sh
python3 tests/fixtures/codex-lifecycle/validate.py
```

It checks fixture-manifest completeness, lifecycle scenario coverage,
provenance, fork/subagent lineage separation, root derivation labeling, probe
safety fields, and privacy. Its allowlist-based privacy scan rejects tokens,
email/account identifiers, UUID-like live identifiers, home-directory paths,
and unapproved absolute paths. New placeholders must be explicitly listed in
the manifest rather than silently accepted.

Refresh this contract whenever the CLI or app version changes in a way that
touches App Server thread methods, hook payloads/sources, SQLite columns,
rollout `session_meta`, writer locks, or the named cctrl anchors. Regenerate the
official schema, re-run read-only inspection, update only changed fixtures,
and move every changed field status deliberately. Version change alone asks
for a comparison; a schema/persistence/behavior change invalidates the affected
fixture.

## Disposable live-probe protocol

No live probe is required to validate these sanitized fixtures. When a future
version needs one, use a clearly named disposable task and never mutate an
existing user task.

1. Create a temporary root with `mktemp -d` and set both `CCTRL_DATA_DIR` and
   `CCTRL_SESSION_METADATA_DIR` to children of that root before invoking cctrl.
   Confirm both variables in the probe log.
2. Record a deterministic before digest of the real Codex store inventory
   using file paths, sizes, and content hashes. Do not copy store contents into
   the repository.
3. Declare the expected Codex-owned delta before launch: normally one task row,
   one disposable rollout, and a transient writer lock for the named test task.
4. Launch only `cctrl-codex-lifecycle-probe`, record the returned provider id
   as `<THREAD_ID>`, exercise the one requested boundary, and record the after
   digest.
5. Compare the inventories. Any undeclared delta makes the probe invalid and
   requires investigation before a fixture is refreshed.
6. Close/archive only the disposable task, verify its writer lock is gone, and
   remove only the two temporary cctrl directories. Keep the sanitized digest
   and declared delta, not private state.

`probe-protocol.json` makes those environment variables, before/after digests,
expected Codex delta, and cleanup requirements testable. A probe that omits any
one of them cannot be used as contract evidence.

## Non-goals

This contract does not implement a task registry, change global hooks, create
production app-owned tasks, alter peer identity, or attempt multi-writer
access. It supplies the conservative evidence rules those later changes must
obey.
