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

set -uo pipefail

_agent="$1"; shift
_marker="$1"; shift
_flags=("$@")

_resume_flag=""
_child_pid=""
_killed=false
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
            wait $_child_pid 2>/dev/null || true
        else
            # Codex: options must precede SESSION_ID.
            echo -e "\033[2mRestarting: codex resume ${_flags[*]} $_resume_flag\033[0m"
            codex resume "${_flags[@]}" "$_resume_flag"
        fi
    else
        if [[ "$_agent" == "claude" ]]; then
            echo -e "\033[2mclaude ${_flags[*]}\033[0m"
            claude "${_flags[@]}" &
            _child_pid=$!
            wait $_child_pid 2>/dev/null || true
        else
            echo -e "\033[2mcodex ${_flags[*]}\033[0m"
            codex "${_flags[@]}"
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

        # Strip resume flags from _flags so they don't conflict with
        # the wrapper's own --resume on subsequent launches.
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

        echo ""
        echo -e "\033[32m✓\033[0m Restart requested — relaunching with fresh config..."
        echo ""
        sleep 1
        continue
    fi

    break
done
