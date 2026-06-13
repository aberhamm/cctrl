#!/usr/bin/env bash
# Peer-message doorbell for agent idle/notification hooks.
#
# Claude Code Stop/Notification hooks can block with exit 2, so the default
# mode returns 2 only when queued mail exists. Codex notify is notification-only;
# pass "codex" as the first arg to print the same doorbell and exit 0.

mode="${1:-claude}"
peer="${CCTRL_PEER:-}"

[ -n "$peer" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

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

check_json="$("$cctrl_bin" peer check --as "$peer" --json --exit-on-empty 2>/dev/null)"
check_rc=$?
[ "$check_rc" -eq 0 ] || exit 0

queued="$(printf '%s\n' "$check_json" | jq -r '.queued // 0' 2>/dev/null)"
case "$queued" in
    ''|*[!0-9]*) exit 0 ;;
esac

if [ "$queued" -gt 0 ]; then
    message="[cctrl] $queued new peer message(s) for $peer. Run: cctrl peer recv --as $peer --json"
    if [ "$mode" = "codex" ]; then
        printf '%s\n' "$message"
        exit 0
    fi
    printf '%s\n' "$message" >&2
    exit 2
fi

exit 0
