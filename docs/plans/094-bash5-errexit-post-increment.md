---
id: 094
title: cctrl exits silently under bash 5 on `((x++))` from 0; install gate hid it with no FAIL line
status: done
completed: 2026-09-29
blocked-by: []
priority: 94
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-09-29
tui-fixture: n/a
approved-by: matthew (C-15 step 0, via cctrl-fleet-manager), 2026-09-29
reviews:
  - type=eng verdict=approved date=2026-09-29 by=opus-level-subagent
---

## Plain-English Summary

`bash install/self-install.sh` failed twice for 0cda192 with no `FAIL:`
line. The previous worker called it host load. It was not load. Homebrew
bash 5.3.20 was installed at 2026-09-29 18:21 CEST
(`/opt/homebrew/bin/bash`, first on PATH ahead of `/bin/bash` 3.2.57).
`cctrl`'s shebang is `#!/usr/bin/env bash`, so from then on cctrl ran under
bash 5.

Under bash >= 4.1 with `set -e`, a standalone `((i++))` whose old value is
0 evaluates to 0, returns status 1, and exits the script. bash 3.2 never
exited on it. `cctrl` had 16 such post-increments, several starting at 0:

- `_remote_exec` purpose scan (`cctrl --host H @shortcut`, `--host H start`)
- remote peer send flag scan (`--as`/`--from` and the `--subject` requote)
- `_peer_send_and_deliver_remote_checked` sender-binding scan
- `session sync-titles` corrections counter, Chrome relaunch wait loops

## Why the gate was silent

`test_remote_shortcut_injects_purpose` runs
`"$rootcopy/cctrl" --host ms @homelab ... >/dev/null 2>&1` as a bare
statement. cctrl exited 1, `set -e` killed the suite, and all output had
been sent to /dev/null. The last visible line was the previous test's `ok:`,
followed by the usual launch-receipt warnings from the three tests in
between. The "fails around `test_start_defaults_to_tmux`" location was an
artefact: that test and the next two print no `ok:` line.

## Evidence

- Install run on this host: RC=1, last line `ok: live-aware index picker`.
- Full suite from a `git archive` copy in scratch (not the releases dir):
  same RC=1 at the same spot, so the release path/symlinks don't matter.
- A temporary ERR trap named the command:
  `test_remote_shortcut_injects_purpose`, the `--host ms @homelab` call.
- `bash -x` on that call: last traced command `(( i++ ))` with i=0.
- Same isolated call against the live tree also returns 1 under bash 5.
- `/bin/bash -c 'set -e; i=0; ((i++)); echo survived'` prints `survived`;
  `/opt/homebrew/bin/bash` exits 1.
- Timeline: live release ec4ddf9 built 16:19 CEST (bash 3.2 era); brew bash
  18:21; 0cda192 committed 18:33; both install failures after that.

## Fix

- Replace every standalone `((x++))` in `cctrl` with `x=$((x + 1))`.
  Identical under bash 3.2; errexit-safe under bash 5. `for ((...; i++))`
  headers are unaffected and kept.
- New lint test `test_no_errexit_unsafe_post_increment` fails if
  `((x++))`/`((x--))` reappears in `cctrl`, `lib/*.sh`, `hooks/*.sh` or
  `install/*.sh`. It catches the pattern whatever bash runs the suite.
- The suite's EXIT trap now prints
  `FAIL: test suite aborted (exit N) in [<function stack>] ... at: <cmd>`
  on any non-zero exit, so a silent `set -e` abort names its test.

## Verification

- Unfixed 0cda192 release copy, full suite under `/bin/bash` 3.2 first on
  PATH: RC=0, 168 ok. Same copy under bash 5.3: RC=1 at the test above.
- Fixed tree, full suite under bash 5.3: RC=0, 169 ok.
- The first bash-5 run of the fix then failed loudly in
  `test_detached_arg_parsing` (`new-session -d -s TMUX--project--2` missing
  from the fake tmux log). Cause: the conversation-id poller left by an
  earlier `start -d` in the same test appends `list-panes` lines to the
  same `TMUX_LOG`, and the fake wrote each line with one `printf` per arg,
  so the lines interleaved. Proved by adding `sleep 0.02` between the fake's
  per-arg writes: 6/6 runs failed with a spliced
  `TMUX new-session -dTMUX list-panes -s -t ...` line. With the one-write
  fake and the same sleep: 6/6 pass. This predates this plan; the fake now
  writes each line in a single `printf`.

## Eng review (Opus, approved)

No required changes. It found no other errexit-unsafe arithmetic and no
other concrete bash-5 regression in `cctrl`/`lib`/`hooks`/`install`
(`((i+=2))` sites never start negative; only `cctrl` and
`install/self-install.sh` run `set -e`).

## Out of scope / follow-ups

- Other bash-3.2-vs-5 behaviour differences were not audited beyond what
  the full suite exercises under bash 5.
- Lint regex could also cover `((++x))`, `((a[k]++))`, `let`, and
  `((x-=n))`; none exist today. It also flags the safe `$((x++))`.
- `_suite_exit`'s "call lines" first entry reads `1` under bash 5; drop or
  label it.
- Live sessions still exec the old release under bash 5 until this
  installs; remote `--host` launches and remote peer sends are broken there.
