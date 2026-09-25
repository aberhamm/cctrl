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
#   HINT     — needs-human only: what to choose to keep the session (the
#              default option of several startup dialogs quits or denies)
#
# Order matters: the first matching entry wins, so named dialogs come before
# the generic selector-footer entry.

# Guard against double-source
[[ -n "${_HC_PATTERNS_LOADED:-}" ]] && return 0
_HC_PATTERNS_LOADED=1

# --- Claude patterns ---
CLAUDE_HC_PATTERN=(
    'Is this a project you created or one you trust|Yes, I trust this folder'
    'Allow external CLAUDE\.md file imports|Yes, allow external imports'
    'Do you trust the files|❯ 1\. Yes'
    'Continue from a previous|❯ 1\.'
    '❯ 1\..*(login|sign.in|authenticate)'
    'login isn.t available|auth.* required'
    'Enter to confirm|Esc to cancel'
)
CLAUDE_HC_LABEL=(
    "folder-trust"
    "external-imports"
    "workspace-trust"
    "conversation-picker"
    "auth-login"
    "login-unavailable"
    "startup-selector"
)
CLAUDE_HC_ACTION=(
    "needs-human"
    "needs-human"
    "auto-dismiss"
    "auto-dismiss"
    "needs-human"
    "needs-human"
    "needs-human"
)
CLAUDE_HC_KEYS=(
    ""
    ""
    "Enter"
    "Enter"
    'https://[^ ]*'
    ""
    ""
)
CLAUDE_HC_HINT=(
    'choose "Yes, I trust this folder" to keep the session; the default "No, exit" quits Claude'
    'both options keep the session: "Yes, allow external imports" loads them, the default "No, disable external imports" continues without them'
    ""
    ""
    ""
    ""
    "an unrecognized startup selector is waiting; attach and pick an option (check which one keeps the session)"
)

# --- Codex patterns ---
CODEX_HC_PATTERN=(
    'Do you trust the contents of this directory'
    'Allow Codex to |approve network access|tell Codex what to do differently'
    'Hooks need review|PreToolUse hooks|Press t to trust|Trust all and continue'
    'Press enter to continue|Press Enter to continue'
)
CODEX_HC_LABEL=(
    "codex-directory-trust"
    "codex-approval-modal"
    "codex-hooks-trust"
    "startup-selector"
)
CODEX_HC_ACTION=(
    "needs-human"
    "needs-human"
    "needs-human"
    "needs-human"
)
CODEX_HC_KEYS=(
    ""
    ""
    ""
    ""
)
CODEX_HC_HINT=(
    'choose "Yes, continue" to keep the session; declining quits Codex'
    ""
    ""
    "an unrecognized startup selector is waiting; attach and pick an option (check which one keeps the session)"
)

# _hc_patterns_for_agent <agent_type>
# Sets HC_PATTERN, HC_LABEL, HC_ACTION, HC_KEYS, HC_HINT arrays for the given agent.
# shellcheck disable=SC2034  # Arrays are used by callers
_hc_patterns_for_agent() {
    local agent="${1:-claude}"
    case "$agent" in
        codex)
            HC_PATTERN=("${CODEX_HC_PATTERN[@]}")
            HC_LABEL=("${CODEX_HC_LABEL[@]}")
            HC_ACTION=("${CODEX_HC_ACTION[@]}")
            HC_KEYS=("${CODEX_HC_KEYS[@]}")
            HC_HINT=("${CODEX_HC_HINT[@]}")
            ;;
        *)
            HC_PATTERN=("${CLAUDE_HC_PATTERN[@]}")
            HC_LABEL=("${CLAUDE_HC_LABEL[@]}")
            HC_ACTION=("${CLAUDE_HC_ACTION[@]}")
            HC_KEYS=("${CLAUDE_HC_KEYS[@]}")
            HC_HINT=("${CLAUDE_HC_HINT[@]}")
            ;;
    esac
}
