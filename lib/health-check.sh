#!/usr/bin/env bash
# health-check.sh — post-spawn health check for cctrl detached sessions.
#
# Polls the tmux pane, matches against known blocking prompts from the shared
# pattern table, auto-dismisses safe prompts, and reports the session's actual
# readiness via session metadata.
#
# Exports: _health_check_run <session_name> <agent_type> <timeout_seconds>
#
# Always returns 0. Status is communicated through session metadata
# (health_status field), not exit codes.
#
# Compatible with bash 3.2 (macOS default) — no associative arrays.

# Source the shared pattern table (guard prevents double-source)
_HC_SCRIPT_DIR="${_HC_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=lib/health-check-patterns.sh
source "$_HC_SCRIPT_DIR/health-check-patterns.sh"

# Transition guard helpers — uses a delimiter-separated string instead of
# associative arrays for bash 3.2 compatibility.
_hc_is_dismissed() {
    local idx="$1" dismissed="$2"
    case ",$dismissed," in
        *,"$idx",*) return 0 ;;
        *) return 1 ;;
    esac
}

_hc_mark_dismissed() {
    local idx="$1" dismissed="$2"
    if [[ -z "$dismissed" ]]; then
        printf '%s' "$idx"
    else
        printf '%s,%s' "$dismissed" "$idx"
    fi
}

_health_check_run() {
    local session_name="$1"
    local agent_type="${2:-claude}"
    local timeout_seconds="${3:-30}"
    local poll_interval="${CCTRL_HC_POLL_INTERVAL:-1}"
    local stable_threshold="${CCTRL_HC_STABLE_THRESHOLD:-3}"
    # elapsed_incr: always at least 1 to prevent infinite loops when poll_interval=0
    local elapsed_incr="$poll_interval"
    (( elapsed_incr < 1 )) && elapsed_incr=1

    # Load patterns for this agent type
    _hc_patterns_for_agent "$agent_type"
    local pattern_count="${#HC_PATTERN[@]}"

    # Transition guard: comma-separated list of dismissed pattern indices
    local dismissed=""

    local elapsed=0
    local stable_count=0
    local capture="" last_capture=""

    echo -e "${DIM}  Health check: polling $session_name (${timeout_seconds}s timeout)...${RESET}" >&2

    while (( elapsed < timeout_seconds )); do
        # Capture the last 40 lines of pane output
        if ! _tmux_run_with_timeout capture-pane -p -S -40 -t "$session_name" 2>/dev/null; then
            # Pane not ready yet — keep trying
            sleep "$poll_interval"
            elapsed=$((elapsed + elapsed_incr))
            continue
        fi
        capture="$TMUX_RUN_OUTPUT"

        # Match against pattern table
        local matched=false
        local i
        for (( i = 0; i < pattern_count; i++ )); do
            if printf '%s\n' "$capture" | grep -E "${HC_PATTERN[$i]}" >/dev/null 2>&1; then
                matched=true
                case "${HC_ACTION[$i]}" in
                    auto-dismiss)
                        if ! _hc_is_dismissed "$i" "$dismissed"; then
                            # First match — auto-dismiss
                            dismissed="$(_hc_mark_dismissed "$i" "$dismissed")"
                            echo -e "${DIM}  Health check: auto-dismissing ${HC_LABEL[$i]}${RESET}" >&2
                            _tmux_run_with_timeout send-keys -t "$session_name" "${HC_KEYS[$i]}" 2>/dev/null || true
                        fi
                        # Already dismissed — wait for prompt to clear
                        ;;
                    needs-human)
                        # Extract info if regex provided
                        local extracted=""
                        if [[ -n "${HC_KEYS[$i]}" ]]; then
                            extracted="$(printf '%s\n' "$capture" | grep -oE "${HC_KEYS[$i]}" | head -1)" || true
                        fi
                        _session_update_metadata_field "$session_name" health_status "needs-human" 2>/dev/null || true
                        _session_update_metadata_field "$session_name" health_reason "${HC_LABEL[$i]}" 2>/dev/null || true
                        echo -e "${YELLOW}⚠${RESET}  Health check: ${HC_LABEL[$i]} — requires human intervention" >&2
                        if [[ -n "$extracted" ]]; then
                            _session_update_metadata_field "$session_name" health_info "$extracted" 2>/dev/null || true
                            echo -e "${DIM}  Info: $extracted${RESET}" >&2
                        fi
                        return 0
                        ;;
                    info-only)
                        # Log and continue
                        ;;
                esac
                stable_count=0
                break
            fi
        done

        if ! $matched; then
            stable_count=$((stable_count + 1))
            if (( stable_count >= stable_threshold )); then
                _session_update_metadata_field "$session_name" health_status "ready" 2>/dev/null || true
                echo -e "${GREEN}✓${RESET}  Health check: session ready" >&2
                return 0
            fi
        fi

        last_capture="$capture"
        sleep "$poll_interval"
        elapsed=$((elapsed + elapsed_incr))
    done

    # Timeout
    _session_update_metadata_field "$session_name" health_status "timeout" 2>/dev/null || true
    echo -e "${YELLOW}⚠${RESET}  Health check: timed out after ${timeout_seconds}s" >&2
    if [[ -n "$last_capture" ]]; then
        echo -e "${DIM}  Last 20 lines of pane:${RESET}" >&2
        printf '%s\n' "$last_capture" | tail -20 >&2
    fi
    return 0
}
