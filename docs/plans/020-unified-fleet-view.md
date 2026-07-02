---
id: 020
title: cctrl fleet — unified cross-host session view
status: in-progress
blocked-by: [013, 014]
priority: 20
goal: cctrl-fleet-staleness
allows-migrations: false
needs-review: none
created: 2026-06-30
---

## Requirements

The user runs sessions on multiple hosts (Mac Studio + MacBook Pro) and today
queries each host separately (`--host ms` and local) every single time. This
plan adds `cctrl fleet`: one command that aggregates the enriched `session ls`
(last-active from plan 013, state from plan 014) across all registered hosts
into a single host-labeled view, sorted by recency.

**Acceptance criteria:**

- [ ] `cctrl fleet` lists sessions from every registered host (from
      `data/hosts.json`) plus local, each row labeled with its host.
- [ ] Each row carries the enriched fields (`last-active`, `state`) produced by
      plans 013/014, sourced per host.
- [ ] Rows are sorted by accurate last-active, most recent first, across hosts.
- [ ] A host that is unreachable is reported inline (e.g. an error/`offline`
      marker for that host) without failing the whole command.
- [ ] Version-skew tolerant: a remote host running an older cctrl whose
      `session ls --json` lacks `last_active`/`state` renders those cells as `-`
      (missing fields never crash the merge or the sort).
- [ ] `cctrl fleet --json` returns a combined array with a `host` field per
      session.
- [ ] Re-running for a single host still works via existing `--host`
      plumbing (no regression).

## Design

Add a `fleet` top-level command (dispatch near `session|sess` ~line 6293).
Enumerate hosts from `data/hosts.json` plus local; for each, invoke
`cctrl session ls --json` (locally for the local host, over the existing remote
plumbing — the same mechanism `--host` already uses — for others), tag each
returned object with `host`, merge, sort by `last_active` desc, and render a
combined table (or `--json`). Wrap per-host invocation so a failure yields an
`offline` row rather than aborting.

**Files expected to change:**

- `cctrl`: add `cmd_fleet` + dispatch + help/usage; reuse host resolution and
  the remote-invocation path already used by `--host`.
- `tests/run-tests.sh`: stub multiple hosts returning fixture `session ls
  --json`, assert merge + host labels + recency sort; assert an unreachable host
  yields an offline marker without failing.

**Testing approach:** unit-only — host invocation is stubbed; no live SSH in
tests.

**Out of scope:** cross-host pruning or repair (prune is host-local in plan 019;
doctor stays per-host). `fleet` is read-only aggregation.

## Tasks

1. Add `fleet` dispatch + usage text.
2. Resolve hosts (`data/hosts.json` + local); invoke `session ls --json` per
   host via existing remote plumbing.
3. Tag rows with `host`, merge, sort by `last_active` desc.
4. Handle unreachable hosts gracefully (offline marker); treat missing
   `last_active`/`state` from an older remote cctrl as `-` (version-skew).
5. Add tests for merge/labels/sort, the offline-host path, and a stubbed remote
   host returning rows without `last_active`/`state` (rendered `-`, no crash).

## Verification

- [cmd] `bash -n cctrl`
- [cmd] `tests/run-tests.sh < /dev/null`
- [assert] a multi-host stub test asserts `fleet --json` contains rows from more
  than one distinct `host`
- [assert] an unreachable-host test asserts the command still exits 0 and marks
  that host offline
