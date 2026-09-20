# Recovering a provisional terminal receipt

Fresh launches initially have a provisional launch ID and no provider task ID.
They cannot use a stable-task registry event to save their terminal anchor. cctrl
now saves all six anchor fields in one atomic receipt transaction, using the
same launch lock as promotion. Stable records use one registry event. Launch
reports an anchor failure; disabling title polling does not disable capture.
Provisional updates cannot change provider identity, origin, owner, or runtime.

## Inspect and prove identity

Select the exact provisional launch ID, never the newest same-name record:

```bash
cctrl session recover-terminal-identity --launch-id <launch-id> --dry-run --json
```

Proof requires a same-host cctrl/Codex launch, one exact managed pane, the recorded
bootstrap command, matching session-creation and process-start times, and exactly
one native Codex process in the pane's process tree. It also requires one writable
root rollout with native CLI provenance and no parent/fork identity. Subagent and
launcher-inherited descriptors are excluded.

The probe compares the numeric file descriptor, access mode, device and inode
against a no-follow opened file, then resamples process, pane, and descriptor
identity after its bounded header read. Incomplete, changed, duplicate, or
ambiguous evidence is rejected. A cwd, title, prompt, or recent inventory entry
cannot establish this identity.

This proves a local terminal binding, not App Server ownership or app-openability.
A transport that keeps no local root rollout open cannot satisfy this proof.

## Lossy historical commands

Older Bash quoting could serialize multibyte prompt text as mixed raw bytes and
octal escapes, then lose those bytes when storing JSON. New detached launches
use locale-stable argument quoting. Historical receipts containing replacement
characters fail with `lossy-launch-command-no-exact-binding`; intact prompt text
alone cannot repair the missing binding.

If a lossless original completed launch event was independently preserved, use:

```bash
cctrl session recover-terminal-identity --launch-id <launch-id> \
  --launch-event-file <original-launch-log> --launch-event-id <event-id> \
  --dry-run --json
```

This branch checks the selected event's source/header, unique ID, successful
completion, complete launch invocation, time interval, and exact detached-session
output. It matches the undamaged bootstrap prefix and compares the full prompt
argument with a restricted, nonexecuting literal parser. Operators, substitutions,
extra arguments, malformed or lossy events, and mismatched generations are
rejected. All live process and root-descriptor checks still apply.

The proof retains event fingerprints and file identity, and rereads the selected
evidence after live verification. Logs may grow, but selected evidence must remain
identical. This is historical execution evidence, not a provider lifecycle signal.
Keep these proof artifacts private: they may contain local paths and task IDs.

## Apply, attest, and preview handoff

After reviewing a successful proof and authorizing the target-specific repair,
repeat the same recovery command with `--apply` in place of `--dry-run`. Then run:

```bash
cctrl session attest <exact-session-name> --json
cctrl session release-to-app <exact-session-name> --dry-run --json
```

Apply locks the provisional receipt, repeats proof, checks its digest, and
promotes through the registry with an absent-destination guard. Existing canonical
tasks reject recovery rather than merge ownership. The new record retains
`cctrl`/`tmux`, adds verified identity/anchors, and stores structured proof. Failure
preserves the source receipt. Recovery does not change provider databases or
locks, stop processes, or transfer a writer.

A successful release preview still requires a separately authorized
`release-to-app <name> --yes` to hand off the writer. Do not bypass failed checks
with manual IDs, borrowed anchors, receipt edits, forced closure, or lock removal.

## Transport and snapshot diagnostics

The Codex proxy can relay WebSocket traffic to its Unix control socket. The
adapter validates the HTTP upgrade, masks client frames, handles fragmented text
and control frames, and caps input. Upgrade and initialization share a deadline.
Known legacy endpoints may explicitly use
`CCTRL_CODEX_APP_SERVER_TRANSPORT=jsonl`; there is no automatic replay or
version-based protocol guess. Cleanup only reaps the adapter's own proxy.

Read-only inventory can test connectivity, but an empty or successful snapshot
is not ownership proof. See the upstream [CLI proxy](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/cli/src/main.rs)
and [Unix transport](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/app-server-transport/src/transport/unix_socket.rs)
for the verified transport implementation.

Tmux probes request UTF-8 output and use fixed identity fields with an opaque
command/name tail. Malformed snapshots are unavailable, never confirmed absence.
An app claim plus ambiguous terminal evidence remains unknown. Standalone
reconciliation still does not compare `pane_started`, and its descendant command
matching is broader than executable attestation; it is not sufficient proof
against PID reuse. Release separately checks fresh pane/PID/process-start identity.

## Validation limits

Focused fixtures cover atomic receipt writes, digest checks, immutable ownership,
existing-destination refusal, FD/inode substitution, native-root provenance,
Unicode serialization, original-event/literal validation, proxy framing, and
malformed snapshot rejection. Focused integration groups and independent Codex
review passed at the checkpoint. Read-only pilots confirmed the relevant proof,
inventory, and release-preview paths without granting general mutation authority.
Final verification details are recorded in the
[provider-neutral audit](provider-neutral-incident.md). Recheck every target live;
a previous proof or successful preview is not permission to transfer it later.
