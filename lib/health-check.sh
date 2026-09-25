#!/usr/bin/env bash
# health-check.sh — post-spawn health check for cctrl detached sessions.
#
# Polls the tmux pane, matches against known blocking prompts from the shared
# pattern table, auto-dismisses safe prompts, and reports the session's actual
# readiness via session metadata.
#
# Exports: _health_check_run <session_name> <agent_type> <timeout_seconds>
#
# Returns 0, except 1 when the agent exited during startup (health_status
# "exited"). Status is also recorded in session metadata (health_status).
#
# "ready" needs positive evidence: the agent's input prompt visible, with no
# blocking modal, on consecutive polls. A blank or still-booting pane is not
# ready; the old "no modal seen for 3s" rule reported ready before Claude
# had drawn its composer, so a brief sent right after start was lost.
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

# The agent's input line: Claude Code draws "❯", Codex "›". Callers pass the
# visible screen only (scrollback keeps dismissed dialogs). Any numbered
# selector on screen ("❯ 1. Yes", Codex's "› 1. Update now") is a modal that
# would swallow input, even when a composer line is drawn behind it. So is an
# unnumbered one: its selected option ("❯ No, exit") looks exactly like a
# composer line, and only the selector footer tells them apart.
_hc_prompt_visible() {
    local screen="$1"
    printf '%s\n' "$screen" | grep -E '^[[:space:]│|]*[❯›][[:space:]]+[0-9]+\.' >/dev/null 2>&1 && return 1
    printf '%s\n' "$screen" | grep -E 'Enter to confirm|Esc to cancel|Press [Ee]nter to continue' >/dev/null 2>&1 && return 1
    printf '%s\n' "$screen" | grep -E '^[[:space:]│|]*[❯›]([[:space:]]|$)' >/dev/null 2>&1
}

_hc_report_exit() {
    local session_name="$1" reason="$2" capture="$3"
    _session_update_metadata_field "$session_name" health_status "exited" 2>/dev/null || true
    _session_update_metadata_field "$session_name" health_reason "$reason" 2>/dev/null || true
    echo -e "${RED}✗${RESET}  Health check: agent exited during startup — $reason" >&2
    if [[ -n "$capture" ]]; then
        echo -e "${DIM}  Last 20 lines of pane:${RESET}" >&2
        printf '%s\n' "$capture" | grep -v '^[[:space:]]*$' | tail -20 >&2
    fi
}

_health_check_run() {
    local session_name="$1"
    local agent_type="${2:-claude}"
    local timeout_seconds="${3:-30}"
    local poll_interval="${CCTRL_HC_POLL_INTERVAL:-1}"
    local stable_threshold="${CCTRL_HC_STABLE_THRESHOLD:-2}"
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
        # A session that is gone died during startup; nothing will become ready.
        if ! _tmux_run_with_timeout has-session -t "$session_name" 2>/dev/null; then
            _hc_report_exit "$session_name" "tmux session ended during startup" "$last_capture"
            return 1
        fi
        # Capture the last 40 lines of pane output
        if ! _tmux_run_with_timeout capture-pane -p -S -40 -t "$session_name" 2>/dev/null; then
            # Pane not ready yet — keep trying
            sleep "$poll_interval"
            elapsed=$((elapsed + elapsed_incr))
            continue
        fi
        capture="$TMUX_RUN_OUTPUT"

        # session-wrapper.sh prints this line and holds the pane open when the
        # agent exits during startup, so its error output can be reported.
        local exit_line
        exit_line="$(printf '%s\n' "$capture" | grep -E '^cctrl: (claude|codex) exited with status' | tail -1)" || true
        if [[ -n "$exit_line" ]]; then
            _hc_report_exit "$session_name" "$exit_line" "$capture"
            return 1
        fi

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
                        if [[ -z "$extracted" && -n "${HC_HINT[$i]:-}" ]]; then
                            extracted="${HC_HINT[$i]}"
                        fi
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

        local screen=""
        if ! $matched && _tmux_run_with_timeout capture-pane -p -t "$session_name" 2>/dev/null; then
            screen="$TMUX_RUN_OUTPUT"
        fi
        if ! $matched && ! _hc_prompt_visible "$screen"; then
            stable_count=0
        elif ! $matched; then
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
