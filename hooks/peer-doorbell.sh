#!/usr/bin/env bash
# Peer-message doorbell (plan 108): a thin wrapper around
# `cctrl peer doorbell --hook <mode>`. All logic lives in cctrl.
#
# claude (default): Stop-hook semantics. Exit 2 with the bell on stderr only
#   when NEW queued mail waits for this pane's own session and the doorbell is
#   enabled in $CCTRL_DATA_DIR/doorbell.json; otherwise silent exit 0. The
#   global `cctrl hooks run stop` dispatcher already runs the same check, so do
#   not register this script next to it (it would ring twice).
# codex: notification-only. Prints the notice for $CCTRL_PEER, exit 0.
# Stdin passes through to cctrl unchanged.

mode="${1:-claude}"

if [ -n "${CCTRL_BIN:-}" ]; then
    cctrl_bin="$CCTRL_BIN"
else
    script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
    if [ -x "$script_dir/../cctrl" ]; then
        cctrl_bin="$script_dir/../cctrl"
    else
        cctrl_bin="cctrl"
    fi
fi

"$cctrl_bin" peer doorbell --hook "$mode"
rc=$?
# Fail open: only a deliberate ring (2, Claude mode) may block.
if [ "$rc" -eq 2 ] && [ "$mode" != "codex" ]; then exit 2; fi
exit 0
