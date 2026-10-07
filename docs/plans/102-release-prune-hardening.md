---
id: 102
title: Harden `cctrl release prune` (fail closed on bad current, implausible scans, missing dirs, abbreviations)
status: done
completed: 2026-10-07
blocked-by: []
priority: 102
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-10-07
tui-fixture: n/a  # release-prune CLI only
approved-by: Matthew ("Go with what you feel is right and is the best long-term decision.", 2026-10-07 12:54 UTC, via fm-cctrl; mdec-1007-cctrl-prune-harden part a)
reviews:
  - type=eng verdict=approved date=2026-10-07 by=opus-subagent
---

## Plain-English Summary

Plan 089 added `cctrl release prune`. Two independent validators found it sound
but not fully fail-closed. This plan closes the gaps so that any doubt about
what is still in use means nothing is deleted (exit 69, a clear message), in
dry run and in `--apply`.

## Fix (lib/release_prune.py)

a. `current` must exist, resolve to a real directory, and be a DIRECT child of
   `releases/`. Dangling, pointing elsewhere, or resolving to a non-child is a
   scan error. A completely absent `current` stays a scan error (unchanged,
   not more permissive). The apply-time re-check applies the same rule.
b. The `ps` and `lsof` scans must each contain the tool's own pid, else scan
   error (rc 0 with empty/implausible output is no longer trusted). Matching
   is exact: first whitespace field of a ps line, or a whole `p<pid>` lsof
   line, never a substring (pid 12 vs 123).
c. A missing data (session registry) dir or bin dir is a scan error. The
   settings-overlay dir stays optional: it is created lazily by the first
   profile launch, so on a fresh machine absence means "no overlays" and no
   live process can reference one. Default everywhere else is fail closed.
d. `argparse.ArgumentParser(allow_abbrev=False)`, so `--app` / `--kee` fail
   even when the module is called directly.

The `cctrl` wrapper needs no change (it already rejects abbreviations).

## Tests (tests/run-tests.sh, test_release_prune)
Per item, dry run and `--apply`, sandbox dirs only: dangling, outside-pointing,
non-direct-child and absent `current`; ps/lsof without own pid and with a
`<ownpid>9` line (substring accident); missing bin dir and registry dir;
module abbreviations rejected (exit 2); absent overlay dir still OK. The ps/lsof
stubs now emit the tool's own pid (`$PPID`). Each test was shown to fail with
its fix reverted.

Review follow-ups applied: an overlay path that exists but is not a directory is
a scan error; a vanished `current` mid-apply refuses every remaining release.
Not applied: requiring pid 1 in ps (recommended hardening, follow-up).

## NOT in scope
- The real `--apply` (separate grant part b).
- Atomic scan-to-delete, ps substring over-pinning, lsof timeout.
