#!/usr/bin/env bash
# Tiny, stable launcher installed at ~/.local/bin/cctrl by
# install/self-install.sh. Its content never needs to change between
# installs -- only $CCTRL_HOME/current's target changes. Deliberately no
# `set -e`: the `"$CCTRL_REAL" "$@"; rc=$?` pattern below depends on running
# past a nonzero exit to capture it.

CCTRL_HOME="${CCTRL_HOME:-$HOME/.local/lib/cctrl}"
CCTRL_REAL="$CCTRL_HOME/current/cctrl"

if [[ "${1:-}" == "hooks" && "${2:-}" == "run" ]]; then
    if [[ -x "$CCTRL_REAL" ]]; then
        "$CCTRL_REAL" "$@"
        rc=$?
        case $rc in
            0|1)
                # 0 = allow. 1 passes through unchanged; nothing dispatched
                # via `hooks run` today deliberately exits 2 (Claude Code's
                # actual "block" code), so this is not itself a block
                # guarantee -- see docs/plans/079's "Hook exit-code
                # convention" note.
                exit "$rc"
                ;;
            *)
                echo "cctrl: hooks entrypoint exited $rc unexpectedly -- failing open" >&2
                exit 0
                ;;
        esac
    else
        echo "cctrl: hooks entrypoint missing ($CCTRL_REAL) -- failing open, allowing the tool call" >&2
        exit 0
    fi
fi

exec "$CCTRL_REAL" "$@"
