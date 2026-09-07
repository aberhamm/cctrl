#!/usr/bin/env bash
# health-check-patterns.sh — shared pattern table for post-spawn health check,
# _session_pane_has_dialog, and _peer_pane_ready_for_delivery.
#
# Parallel indexed arrays per agent type. Index i across all four arrays forms
# one entry:
#   PATTERN  — extended regex anchored on modal chrome (❯ selector, dialog text)
#   LABEL    — human-readable label for logging
#   ACTION   — auto-dismiss | needs-human | info-only
#   KEYS     — tmux send-keys sequence for auto-dismiss, or regex for extraction

# Guard against double-source
[[ -n "${_HC_PATTERNS_LOADED:-}" ]] && return 0
_HC_PATTERNS_LOADED=1

# --- Claude patterns ---
CLAUDE_HC_PATTERN=(
    'Do you trust the files|❯ 1\. Yes'
    'Continue from a previous|❯ 1\.'
    '❯ 1\..*(login|sign.in|authenticate)'
    'login isn.t available|auth.* required'
    'Do you want to (proceed|create|make)'
)
CLAUDE_HC_LABEL=(
    "workspace-trust"
    "conversation-picker"
    "auth-login"
    "login-unavailable"
    "proceed-confirm"
)
CLAUDE_HC_ACTION=(
    "auto-dismiss"
    "auto-dismiss"
    "needs-human"
    "needs-human"
    "auto-dismiss"
)
CLAUDE_HC_KEYS=(
    "Enter"
    "Enter"
    'https://[^ ]*'
    ""
    "Enter"
)

# --- Codex patterns ---
CODEX_HC_PATTERN=(
    'Allow Codex to |approve network access|tell Codex what to do differently'
    'Hooks need review|PreToolUse hooks|Press t to trust|Trust all and continue'
)
CODEX_HC_LABEL=(
    "codex-approval-modal"
    "codex-hooks-trust"
)
CODEX_HC_ACTION=(
    "needs-human"
    "needs-human"
)
CODEX_HC_KEYS=(
    ""
    ""
)

# _hc_patterns_for_agent <agent_type>
# Sets HC_PATTERN, HC_LABEL, HC_ACTION, HC_KEYS arrays for the given agent.
# shellcheck disable=SC2034  # Arrays are used by callers
_hc_patterns_for_agent() {
    local agent="${1:-claude}"
    case "$agent" in
        codex)
            HC_PATTERN=("${CODEX_HC_PATTERN[@]}")
            HC_LABEL=("${CODEX_HC_LABEL[@]}")
            HC_ACTION=("${CODEX_HC_ACTION[@]}")
            HC_KEYS=("${CODEX_HC_KEYS[@]}")
            ;;
        *)
            HC_PATTERN=("${CLAUDE_HC_PATTERN[@]}")
            HC_LABEL=("${CLAUDE_HC_LABEL[@]}")
            HC_ACTION=("${CLAUDE_HC_ACTION[@]}")
            HC_KEYS=("${CLAUDE_HC_KEYS[@]}")
            ;;
    esac
}
