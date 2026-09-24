#!/usr/bin/env bash
# session-wrapper.sh — long-lived tmux pane process that runs claude/codex
# as a child and supports restart-in-place. On exit, if a restart marker
# exists, the agent is re-launched with --resume (fresh process = fresh
# MCP/config, same conversation context). Without a marker the pane exits
# normally; lifecycle actions such as Codex task archival belong to cctrl's
# explicit session commands so release-to-app can preserve the app task.
#
# Usage (called by _launch_exec_agent, not directly):
#   session-wrapper.sh <agent> <marker-path> [flags...]
#   session-wrapper.sh codex <marker-path> [options...] --cctrl-initial [resume] [args...]
#
# For codex, everything after --cctrl-initial is used for the first launch
# only (`codex resume <options> <id> [prompt]` or `codex <options> [prompt]`).
# Restarts reuse just the options, so Codex's own `-c key=value` flags and
# positional arguments never collide with the restart's `resume <id>`.

set -uo pipefail

# One brace group ending in `exit`: this process lives as long as the
# session, so bash must never read past the loop from a file that may have
# been rewritten in place since launch. A partially written file fails to
# parse instead of running half a wrapper.
{

_agent="$1"; shift
_marker="$1"; shift
_flags=("$@")
_initial=()
if [[ "$_agent" == "codex" ]]; then
    for (( _i = 0; _i < ${#_flags[@]}; _i++ )); do
        if [[ "${_flags[_i]}" == "--cctrl-initial" ]]; then
            _initial=("${_flags[@]:_i+1}")
            _flags=("${_flags[@]:0:_i}")
            break
        fi
    done
fi

_resume_flag=""
_child_pid=""
_killed=false
_rc=0
# An agent that exits this soon after its first launch died during startup
# (bad flag, auth, crash). Report it and keep the pane briefly so the launch
# health check, or an attached human, can still read the error output.
_early_window="${CCTRL_EARLY_EXIT_WINDOW_SECONDS:-15}"
_early_hold="${CCTRL_EARLY_EXIT_HOLD_SECONDS:-10}"
_started_at="$(date +%s)"
_cleanup() {
    _killed=true
    if [[ -n "$_child_pid" ]]; then
        kill -TERM "$_child_pid" 2>/dev/null || true
        wait "$_child_pid" 2>/dev/null || true
        _child_pid=""
    fi
    rm -f "$_marker"
}
trap _cleanup SIGTERM SIGINT SIGHUP

while true; do
    if [[ -n "$_resume_flag" ]]; then
        if [[ "$_agent" == "claude" ]]; then
            echo -e "\033[2mRestarting: claude --resume $_resume_flag ${_flags[*]}\033[0m"
            claude --resume "$_resume_flag" "${_flags[@]}" &
            _child_pid=$!
            wait $_child_pid 2>/dev/null; _rc=$?
        else
            # Codex: options must precede SESSION_ID.
            echo -e "\033[2mRestarting: codex resume ${_flags[*]} $_resume_flag\033[0m"
            codex resume "${_flags[@]}" "$_resume_flag"; _rc=$?
        fi
    else
        if [[ "$_agent" == "claude" ]]; then
            echo -e "\033[2mclaude ${_flags[*]}\033[0m"
            claude "${_flags[@]}" &
            _child_pid=$!
            wait $_child_pid 2>/dev/null; _rc=$?
        elif [[ ${#_initial[@]} -gt 0 && "${_initial[0]}" == "resume" ]]; then
            echo -e "\033[2mcodex resume ${_flags[*]} ${_initial[*]:1}\033[0m"
            codex resume "${_flags[@]}" "${_initial[@]:1}"; _rc=$?
        else
            echo -e "\033[2mcodex ${_flags[*]} ${_initial[*]:-}\033[0m"
            codex "${_flags[@]}" ${_initial[@]+"${_initial[@]}"}; _rc=$?
        fi
    fi

    _child_pid=""

    # If we were killed by a signal (cctrl close / tmux kill), exit
    # immediately — do not restart.
    if $_killed; then
        break
    fi

    if [[ -f "$_marker" ]]; then
        _resume_flag="$(cat "$_marker")"
        rm -f "$_marker"

        # Strip Claude's resume flags from _flags so they don't conflict
        # with the wrapper's own --resume on subsequent launches. Codex
        # options carry no resume arguments (see --cctrl-initial), and its
        # `-c` means `--config`, not `--continue`.
        if [[ "$_agent" == "claude" ]]; then
            _clean_flags=()
            _skip_next=false
            for _f in "${_flags[@]}"; do
                if $_skip_next; then _skip_next=false; continue; fi
                case "$_f" in
                    --resume|-r) _skip_next=true; continue ;;
                    --continue|-c|--last) continue ;;
                esac
                _clean_flags+=("$_f")
            done
            _flags=("${_clean_flags[@]}")
        fi

        echo ""
        echo -e "\033[32m✓\033[0m Restart requested — relaunching with fresh config..."
        echo ""
        sleep 1
        continue
    fi

    if [[ -z "$_resume_flag" ]] && (( $(date +%s) - _started_at < _early_window )); then
        echo ""
        echo "cctrl: $_agent exited with status $_rc after $(( $(date +%s) - _started_at ))s during startup"
        echo "cctrl: this pane closes in ${_early_hold}s (Enter closes now)"
        read -r -t "$_early_hold" _ 2>/dev/null || true
    fi
    break
done
exit "$_rc"
}
