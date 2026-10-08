#!/usr/bin/env bash

# Compound Codex terminal bootstrap -> exact identity -> app handoff workflow.
# This module is sourced by cctrl after its paths are initialized. It deliberately
# composes the existing detached-launch, identity-recovery, attestation, and
# release state machines instead of reimplementing any ownership transition.

_codex_launch_to_app_result() {
    local ok="$1" status="$2" session="$3" launch_id="$4" provider_task_id="$5"
    local keep_terminal="$6" recovery_applied="$7" owner="$8" runtime="$9"
    local error="${10}" required_action="${11}" release_json="${12:-null}"
    jq -nc \
        --argjson ok "$ok" \
        --arg status "$status" \
        --arg session "$session" \
        --arg launch_id "$launch_id" \
        --arg provider_task_id "$provider_task_id" \
        --argjson keep_terminal_owned "$keep_terminal" \
        --argjson recovery_applied "$recovery_applied" \
        --arg owner "$owner" \
        --arg runtime "$runtime" \
        --arg error "$error" \
        --arg required_action "$required_action" \
        --argjson release "$release_json" '
      {schema_version:1,kind:"codex_launch_to_app_result_v1",ok:$ok,status:$status,
       session:(if $session=="" then null else $session end),
       launch_id:(if $launch_id=="" then null else $launch_id end),
       provider_task_id:(if $provider_task_id=="" then null else $provider_task_id end),
       requested_finalization:(if $keep_terminal_owned then "keep-terminal-owned" else "release-to-app" end),
       identity:{verified:($provider_task_id!=""),recovery_applied:$recovery_applied},
       resulting_state:{control_owner:(if $owner=="" then null else $owner end),
                        execution_runtime:(if $runtime=="" then null else $runtime end)},
       release:(if $release == null then null else $release end),
       error:(if $error=="" then null else $error end),
       required_action:(if $required_action=="" then null else $required_action end)}'
}

_codex_launch_to_app_emit() {
    local json="$1" result="$2"
    if [[ "$json" == true ]]; then
        printf '%s\n' "$result" | jq .
    else
        jq -r '
          if .ok then
            "\(.session): \(.status) — provider \(.provider_task_id) (\(.resulting_state.control_owner)/\(.resulting_state.execution_runtime))" +
            (if .required_action then "\nNext: \(.required_action)" else "" end)
          else
            "\(.session // "launch"): \(.status)" +
            (if .error then " — \(.error)" else "" end) +
            (if .required_action then "\nNext: \(.required_action)" else "" end)
          end
        ' <<< "$result"
    fi
}

_codex_launch_to_app_usage() {
    cat <<'EOF'
Usage: cctrl launch-to-app <dir|@shortcut> [start options] [compound options]

Launch one detached cctrl-managed Codex terminal task, prove its exact provider
identity, attest the anchored terminal owner, then safely release that same task
to the Codex app. Existing cctrl start and session attach behavior is unchanged.

Compound options:
  --keep-terminal-owned     Verify identity but do not release the terminal owner
  --identity-timeout SEC    Wait for exact identity proof (default: 30)
  --release-wait SEC        Wait for the anchored owner to exit (default: 10)
  --json                    Emit codex_launch_to_app_result_v1 JSON

Detached/app-owned/foreground/resume flags are rejected because this command
owns those lifecycle choices. Peer identity and health-check bypass are also
rejected; other normal Codex start flags are forwarded.
EOF
}

_codex_launch_to_app_record_has_exact_identity() {
    local record_file="$1" launch_id="$2" session="$3" provider_task_id="${4:-}"
    jq -e --arg launch "$launch_id" --arg session "$session" --arg task "$provider_task_id" '
      .provisional_launch_id==$launch and (.tmux_session // .name)==$session and
      .provider=="codex" and (.provider_task_id // "")!="" and
      ($task=="" or .provider_task_id==$task) and
      .origin=="cctrl" and .launched_by_cctrl==true and
      .control_owner=="cctrl" and .execution_runtime=="tmux" and
      (.terminal_identity_proof.verified==true and
       .terminal_identity_proof.provider_task_id==.provider_task_id and
       ((.terminal_identity_proof.evidence_kind=="live-native-codex-writable-root-rollout" and
         .terminal_identity_proof.receipt.tmux_session==$session and
         .terminal_identity_proof.receipt.pane_id==.pane_id and
         .terminal_identity_proof.receipt.pane_pid==.pane_pid and
         .terminal_identity_proof.receipt.wrapper_pid==.wrapper_pid and
         .terminal_identity_proof.receipt.pane_started==.pane_started) or
        (.terminal_identity_proof.evidence_kind=="codex-lifecycle-hook-launch-binding" and
         (.terminal_identity_proof.lifecycle_event_id // "")!="" and
         .terminal_identity_proof.provisional_launch_id==$launch and
         .terminal_identity_proof.tmux_session==$session and
         (.terminal_identity_proof.expected_source_digest // "")!="")))
    ' "$record_file" >/dev/null 2>&1
}

_codex_launch_to_app() {
    local json=false keep_terminal=false identity_timeout="${CCTRL_LAUNCH_TO_APP_IDENTITY_TIMEOUT:-30}"
    local release_wait="${CCTRL_RELEASE_WAIT_SECONDS:-10}" arg
    local -a launch_args=()
    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --keep-terminal-owned) keep_terminal=true; shift ;;
            --json) json=true; shift ;;
            --identity-timeout)
                [[ $# -ge 2 ]] || { echo "--identity-timeout needs seconds" >&2; return 64; }
                identity_timeout="$2"; shift 2 ;;
            --release-wait)
                [[ $# -ge 2 ]] || { echo "--release-wait needs seconds" >&2; return 64; }
                release_wait="$2"; shift 2 ;;
            -h|--help|help) _codex_launch_to_app_usage; return 0 ;;
            --agent)
                [[ $# -ge 2 ]] || { echo "--agent needs a value" >&2; return 64; }
                [[ "$(_normalize_agent "$2" 2>/dev/null || true)" == codex ]] || {
                    echo "launch-to-app supports only Codex." >&2; return 64;
                }
                shift 2 ;;
            --profile|--model|--reasoning-effort|--permission-mode|--sandbox|-s|--ask-for-approval|-a|--remote|--remote-auth-token-env|--name|-n|--purpose|--message|--prompt|-m|--health-check-timeout|-c|--config|--mcp)
                [[ $# -ge 2 ]] || { echo "$arg needs a value" >&2; return 64; }
                launch_args+=("$arg" "$2")
                shift 2 ;;
            --)
                launch_args+=("--")
                shift
                launch_args+=("$@")
                break ;;
            --no-input) shift ;;
            --peer|--no-health-check|--skip-health-check|--role|--orch-kind|--succeeds)
                echo "$arg is incompatible with launch-to-app." >&2
                return 64 ;;
            -d|--detach|--foreground|--no-tmux|--tmux|--app-owned|--resume|-r)
                echo "$arg is incompatible with launch-to-app." >&2
                return 64 ;;
            *) launch_args+=("$arg"); shift ;;
        esac
    done
    [[ "$identity_timeout" =~ ^[0-9]+$ ]] || { echo "--identity-timeout must be a non-negative integer." >&2; return 64; }
    [[ "$release_wait" =~ ^[0-9]+$ ]] || { echo "--release-wait must be a non-negative integer." >&2; return 64; }

    local scratch launch_log session="" launch_id="" provider_task_id="" record_file="" health_status=""
    local proof="" proof_rc=1 apply_result="" apply_rc=1 recovery_applied=false attest="" release=""
    local result error="" required_action="" status="launch-failed" rc=0 elapsed=0 hint_prefix="cctrl"
    local CCTRL_ATTACH_PROMPT=never CCTRL_ATTACH_AFTER_START=0 CCTRL_NO_HEALTH_CHECK=0
    local CCTRL_RESUME_POLL_TIMEOUT=0 CCTRL_CODEX_TITLE_POLL_TIMEOUT=0
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/cctrl-launch-to-app.XXXXXX")" || return 74
    launch_log="$scratch/launch.log"
    local CCTRL_LAUNCH_RECEIPT_FILE="$scratch/launch-receipt.json"
    [[ -n "${CCTRL_HOST_PREFIX:-}" ]] && hint_prefix="cctrl --host $CCTRL_HOST_PREFIX"

    CCTRL_LAST_LAUNCH_ID=""
    CCTRL_LAST_LAUNCH_RECORD=""
    # Exact recovery, not rollout/title correlation, owns identity assignment in
    # this workflow. Suppress both existing best-effort heuristic pollers.
    # Plan 106 P2: lean MCP applies to the terminal phase only.
    local _l2a_i _l2a_mcp="${CCTRL_MCP_MODE:-}"
    for (( _l2a_i = 0; _l2a_i < ${#launch_args[@]}; _l2a_i++ )); do
        [[ "${launch_args[$_l2a_i]}" == -- ]] && break
        [[ "${launch_args[$_l2a_i]}" == --mcp ]] && _l2a_mcp="${launch_args[$((_l2a_i + 1))]:-}"
    done
    if [[ -n "$_l2a_mcp" && "$_l2a_mcp" != inherit && "$json" != true ]]; then
        echo "mcp: ${_l2a_mcp} applies to the terminal phase only; the app-server owns MCP after release." >&2
    fi
    if ! _launch_detached -d --agent codex "${launch_args[@]}" >"$launch_log" 2>&1; then
        if [[ -f "$CCTRL_LAUNCH_RECEIPT_FILE" ]]; then
            session="$(jq -r '.session // empty' "$CCTRL_LAUNCH_RECEIPT_FILE" 2>/dev/null || true)"
            launch_id="$(jq -r '.launch_id // empty' "$CCTRL_LAUNCH_RECEIPT_FILE" 2>/dev/null || true)"
        fi
        error="launch-failed"
        if [[ -n "$session" && -n "$launch_id" ]]; then
            required_action="The terminal was created but boot did not complete. Inspect it with: $hint_prefix session attach $session"
            result="$(_codex_launch_to_app_result false "$status" "$session" "$launch_id" "" "$keep_terminal" false cctrl tmux "$error" "$required_action" null)"
        else
            required_action="Inspect the launch error; no app handoff was attempted."
            result="$(_codex_launch_to_app_result false "$status" "" "" "" "$keep_terminal" false "" "" "$error" "$required_action" null)"
        fi
        [[ "$json" == true ]] || cat "$launch_log" >&2
        _codex_launch_to_app_emit "$json" "$result"
        rm -rf "$scratch"
        return 1
    fi
    if [[ -f "$CCTRL_LAUNCH_RECEIPT_FILE" ]]; then
        session="$(jq -r '.session // empty' "$CCTRL_LAUNCH_RECEIPT_FILE" 2>/dev/null || true)"
        launch_id="$(jq -r '.launch_id // empty' "$CCTRL_LAUNCH_RECEIPT_FILE" 2>/dev/null || true)"
    fi
    if [[ -z "$session" || ! "$launch_id" =~ ^[0-9a-f-]{16,64}$ ]]; then
        error="launch-receipt-missing"
        required_action="The terminal may still be running; inspect cctrl session ls and do not infer its provider identity."
        result="$(_codex_launch_to_app_result false identity-unverified "$session" "$launch_id" "" "$keep_terminal" false cctrl tmux "$error" "$required_action" null)"
        _codex_launch_to_app_emit "$json" "$result"
        rm -rf "$scratch"
        return 65
    fi
    record_file="$(_session_metadata_file "$session" 2>/dev/null || true)"
    health_status="$(jq -r '.health_status // empty' "$record_file" 2>/dev/null || true)"
    if [[ "$health_status" != ready ]]; then
        error="boot-not-ready"
        required_action="Keep the terminal owner and inspect its startup state with: $hint_prefix session attach $session"
        result="$(_codex_launch_to_app_result false boot-not-ready "$session" "$launch_id" "" "$keep_terminal" false cctrl tmux "$error" "$required_action" null)"
        _codex_launch_to_app_emit "$json" "$result"
        rm -rf "$scratch"
        return 65
    fi

    # A provider lifecycle hook may have promoted the exact receipt already.
    # Otherwise repeatedly run the exact launch-ID proof until the native root
    # rollout exists, then repeat that proof under the guarded apply lock.
    while (( elapsed <= identity_timeout )); do
        record_file="$(_session_metadata_file "$session" 2>/dev/null || true)"
        if [[ -f "$record_file" ]]; then
            if _codex_launch_to_app_record_has_exact_identity "$record_file" "$launch_id" "$session"; then
                provider_task_id="$(jq -r '.provider_task_id' "$record_file")"
            fi
            [[ -n "$provider_task_id" ]] && break
        fi
        proof_rc=0
        proof="$(_session_recover_terminal_identity --launch-id "$launch_id" --dry-run --json 2>/dev/null)" || proof_rc=$?
        if (( proof_rc == 0 )) && [[ "$(jq -r '.verified // false' <<< "$proof" 2>/dev/null)" == true ]]; then
            apply_rc=0
            apply_result="$(_session_recover_terminal_identity --launch-id "$launch_id" --apply --json 2>/dev/null)" || apply_rc=$?
            if (( apply_rc == 0 )) && [[ "$(jq -r '.verified and .applied' <<< "$apply_result" 2>/dev/null)" == true ]]; then
                recovery_applied=true
                provider_task_id="$(jq -r '.provider_task_id // empty' <<< "$apply_result")"
                record_file="$(_session_metadata_file "$session" 2>/dev/null || true)"
                break
            fi
            error="identity-recovery-apply-failed"
            break
        fi
        (( elapsed == identity_timeout )) && break
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [[ -z "$provider_task_id" ]]; then
        [[ -n "$error" ]] || error="exact-provider-identity-unavailable"
        required_action="Keep using the terminal owner. Retry exact recovery with: $hint_prefix session recover-terminal-identity --launch-id $launch_id --dry-run --json"
        result="$(_codex_launch_to_app_result false identity-unverified "$session" "$launch_id" "" "$keep_terminal" "$recovery_applied" cctrl tmux "$error" "$required_action" null)"
        _codex_launch_to_app_emit "$json" "$result"
        rm -rf "$scratch"
        return 65
    fi

    # Re-read after promotion and bind all subsequent steps to the same launch,
    # session, and provider identity before trusting attestation.
    record_file="$(_session_metadata_file "$session" 2>/dev/null || true)"
    if [[ ! -f "$record_file" ]] ||
        ! _codex_launch_to_app_record_has_exact_identity "$record_file" "$launch_id" "$session" "$provider_task_id"; then
        error="canonical-identity-mismatch"
        required_action="The launch receipt no longer maps uniquely to the terminal owner; reconcile without opening a second writer."
        result="$(_codex_launch_to_app_result false identity-conflict "$session" "$launch_id" "$provider_task_id" "$keep_terminal" "$recovery_applied" cctrl tmux "$error" "$required_action" null)"
        _codex_launch_to_app_emit "$json" "$result"
        rm -rf "$scratch"
        return 75
    fi

    local expected_guard
    expected_guard="$(jq -c --arg task "$provider_task_id" --arg launch "$launch_id" '
      {provider_task_id:$task,provisional_launch_id:$launch,tmux_session:(.tmux_session // .name),
       pane_id,pane_pid,pane_started}
    ' "$record_file")" || {
        rm -rf "$scratch"
        return 65
    }
    rc=0
    attest="$(_session_attest "$session" --json 2>/dev/null)" || rc=$?
    if (( rc != 0 )) || [[ "$(jq -r '.verified // false' <<< "$attest" 2>/dev/null)" != true ]] \
        || [[ "$(jq -r '.thread_id // empty' <<< "$attest" 2>/dev/null)" != "$provider_task_id" ]]; then
        error="owner-attestation-failed"
        required_action="Keep the terminal owner and inspect: $hint_prefix session attest $session --json"
        result="$(_codex_launch_to_app_result false attestation-failed "$session" "$launch_id" "$provider_task_id" "$keep_terminal" "$recovery_applied" cctrl tmux "$error" "$required_action" null)"
        _codex_launch_to_app_emit "$json" "$result"
        rm -rf "$scratch"
        return 65
    fi

    if [[ "$keep_terminal" == true ]]; then
        required_action="Attach with: $hint_prefix session attach $session"
        result="$(_codex_launch_to_app_result true terminal-owned "$session" "$launch_id" "$provider_task_id" true "$recovery_applied" cctrl tmux "" "$required_action" null)"
        _codex_launch_to_app_emit "$json" "$result"
        rm -rf "$scratch"
        return 0
    fi

    rc=0
    release="$(_session_release_to_app_one "$session" false true "$release_wait" "$expected_guard")" || rc=$?
    if (( rc != 0 )) || [[ "$(jq -r '.ok // false' <<< "$release" 2>/dev/null)" != true ]]; then
        local release_owner release_runtime
        error="$(jq -r '.error // "release-to-app-failed"' <<< "$release" 2>/dev/null || printf release-to-app-failed)"
        required_action="$(jq -r '.required_action // empty' <<< "$release" 2>/dev/null || true)"
        [[ -n "$required_action" ]] || required_action="The terminal remains the safest available owner; inspect the exact release result before retrying."
        release_owner="$(jq -r '.resulting_state.control_owner // "unknown"' <<< "$release" 2>/dev/null || printf unknown)"
        release_runtime="$(jq -r '.resulting_state.execution_runtime // "unknown"' <<< "$release" 2>/dev/null || printf unknown)"
        result="$(_codex_launch_to_app_result false release-failed "$session" "$launch_id" "$provider_task_id" false "$recovery_applied" "$release_owner" "$release_runtime" "$error" "$required_action" "${release:-null}")"
        _codex_launch_to_app_emit "$json" "$result"
        rm -rf "$scratch"
        (( rc != 0 )) || rc=75
        return "$rc"
    fi

    if [[ "$(jq -r '.provider_task_id // empty' <<< "$release" 2>/dev/null)" != "$provider_task_id" ]]; then
        error="release-identity-mismatch"
        required_action="The release result did not preserve the verified provider identity; reconcile before opening any app writer."
        result="$(_codex_launch_to_app_result false identity-conflict "$session" "$launch_id" "$provider_task_id" false "$recovery_applied" conflict conflict "$error" "$required_action" "$release")"
        _codex_launch_to_app_emit "$json" "$result"
        rm -rf "$scratch"
        return 75
    fi
    result="$(_codex_launch_to_app_result true released-to-app "$session" "$launch_id" "$provider_task_id" false "$recovery_applied" app app-server "" "Open provider task $provider_task_id in the Codex app." "$release")"
    _codex_launch_to_app_emit "$json" "$result"
    rm -rf "$scratch"
    return 0
}
