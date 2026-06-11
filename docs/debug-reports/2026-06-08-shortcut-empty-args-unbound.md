# Debug Report: Shortcut Empty Args Unbound Variable

Date: 2026-06-08
Status: DONE

## Symptom

Running a shortcut with no extra arguments failed immediately:

```text
cctrl @mstack
/Users/matthew/.local/bin/cctrl: line 2112: original_args[@]: unbound variable
```

## Root Cause

The tmux-default shortcut change captured shortcut arguments in a bash array:

```bash
local original_args=("$@")
```

On the system bash used by macOS, with `set -u`, expanding an empty array with
`"${original_args[@]}"` can raise `unbound variable`. The `@mstack` shortcut had
no additional arguments, so the shortcut path failed before it could launch the
tmux-backed session.

## Fix

Guard empty-array expansions in the shortcut path:

```bash
${original_args[@]+"${original_args[@]}"}
```

This preserves quoted arguments when present and expands to nothing when the
array is empty.

## Evidence

Reproduced the shell behavior directly:

```bash
bash -lc 'set -u; original_args=(); for a in "${original_args[@]}"; do echo "$a"; done'
```

Then confirmed the guarded form works with both empty and spaced arguments.

Confirmed the original user scenario with a fake tmux binary:

```text
cctrl @mstack
...
CCTRL_SESSION=TMUX--mstack
```

## Regression Test

Added `test_shortcut_no_args_defaults_to_tmux` in `tests/run-tests.sh`. It creates
a temporary `@mstack` shortcut with no extra args and verifies that it creates a
`TMUX--mstack` session command instead of failing under `set -u`.

## Verification

```bash
tests/run-tests.sh
```

Result:

```text
ok
```
