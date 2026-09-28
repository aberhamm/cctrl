---
id: 089
title: Release pruning under ~/.local/lib/cctrl/releases (design question, not approved)
status: blocked
blocked-by: []
priority: 89
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-28
tui-fixture: n/a
approved-by: none  # design question for Matthew; do not implement until he decides the approach
---

## Plain-English Summary

Split from plan 075. This is a design question, not a fix — noted during
the 2026-09-28 review pass, not implemented. Do not pick this up as part
of the general 075-split-out queue; it needs Matthew's decision on
approach before any code is written. See memory
[[cctrl-checked-install-design]] for how releases and `current` work
today.

## The question

Old releases under `~/.local/lib/cctrl/releases` are never auto-pruned by
`install/self-install.sh` today, by design: a long-lived session bakes its
release's literal path into its MCP config for the session's life, so
deleting an older release out from under it would break that session. As
of 2026-09-28 there are 4 releases (~3.9M each, ~16M total) — no
disk-pressure urgency, so this is a design note, not a bug.

A real `--keep-last-N` (or similar) is not just "delete everything older
than the last N by timestamp" — it needs to first cross-reference which
release paths any currently-live session's MCP config still points at
(via the session registry, not just wall-clock recency) and exclude those
from deletion regardless of age, or a long-running session could still
get its release pulled out from under it even under a generous N. That
cross-reference design (and how to query it without a live-registry
write, consistent with plan 081's read-only-investigation pattern) is the
open question — decide it before implementing, don't just add a naive
count-based prune.

## Out of scope for this filing

Implementation. Nothing under `~/.local/lib/cctrl/releases` should be
deleted in the course of resolving this plan — live sessions may still
reference old release paths.

## Rules

This plan stays `blocked` / `approved-by: none` until Matthew makes a
call on the cross-reference design. Do not implement speculatively.
