# Device tag session names

## Symptom

Direct `cctrl` launches on the MacBook Pro created untagged tmux sessions such
as `TMUX--project`. Mac Studio sessions had the expected `ms` segment.

## Root Cause

Session naming only read `CCTRL_HOST_PREFIX`, which is set for `--host` remote
execution. Direct local launches had no host prefix, so `_context_slug` emitted
historic untagged names even on known personal machines.

## Fix

Added `_device_tag` in `cctrl`:

- `CCTRL_HOST_PREFIX` still wins for remote aliases.
- `CCTRL_DEVICE_TAG` can explicitly override local detection.
- Known local hostnames map to stable tags: `ms-*` -> `ms`, `mattbook-pro` /
  MacBook variants -> `mbp`.
- Unknown hostnames keep the old untagged behavior.

## Evidence

- `tests/run-tests.sh`: passed on Mac Studio.
- Mac Studio fake-tmux smoke with real hostname emitted
  `CCTRL_SESSION=TMUX--ms--project`.
- MacBook fake-tmux smoke with real hostname emitted
  `CCTRL_SESSION=TMUX--mbp--project`.

The MacBook full test suite was not completed because its dirty checkout has an
unrelated hang in `cctrl peer deliver comet --json`.
