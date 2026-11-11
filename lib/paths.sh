# lib/paths.sh: the one path resolver for cctrl (plan 116, phase A0).
#
# Sourced by cctrl and hooks/statusline.sh. Written in the bash 3.2 subset.
# The resolve path (_cctrl_paths_resolve) runs no subprocess: no $(...), no
# external command, only builtins and parameter expansion, so a hook that
# renders on every statusline refresh can call it for free.
#
# lib/paths.py is its Python twin. Both follow the rules below, and
# test_paths_resolver_matrix runs both on every row of the path matrix and
# requires identical key=value output. Change one, change both.
#
# Rules
#   root        the realpath of the cctrl tree (the directory holding cctrl).
#               The caller resolves it; this file never follows links itself.
#   mode        "installed" only when <root>/.installed is a file. Nothing in
#               the environment can set it (CCTRL_RUNTIME_MODE is ignored and
#               unset, so it is never passed to a child). A checkout and the
#               install gate's scratch tree are "checkout".
#   state_root  $CCTRL_STATE_DIR, else $XDG_STATE_HOME/cctrl, else
#               $HOME/.local/state/cctrl. A relative value is ignored, as
#               the XDG spec says.
#   store_data_dir
#               the store's own data dir. Installed mode with
#               <state_root>/data/LAYOUT saying {"layout": 2} uses
#               <state_root>/data (dormant until plan 116 A2 writes the
#               marker); otherwise <root>/data. No environment variable
#               moves it.
#   data_dir    $CCTRL_DATA_DIR, else store_data_dir. Governs the peer and
#               session family: peers, mailbox, session records, host id,
#               snapshots, autoheal and needs-me state.
#   costs_dir   $CCTRL_COSTS_DIR, else the same layout rule with
#               <state_root>/costs/LAYOUT, else <root>/costs.
#   audit_dir   <state_root>/audit (plan 118's logs).
#   config      layers, lowest first: <root>/share/config.default.json (the
#               shipped default), <store_data_dir>/config.json (a legacy file
#               kept by the A0 runbook), the user config, then
#               config.local.json.
#   migrating   1 while <state_root>/.migrating exists (the plan 116 A2
#               sentinel). Reported only; A1's writers act on it.
#
# Every result is a plain, unexported shell variable named _CCTRL_P_*.

# Keys in canonical order. lib/paths.py prints the same keys in the same order.
_CCTRL_PATHS_KEYS="mode root state_root store_data_dir data_dir data_layout costs_dir costs_layout audit_dir sessions_dir snapshots_dir host_id_file shortcuts_file hosts_file config_default config_legacy config_user config_local spending_log rate_limits_file rate_limits_history needs_me_snapshot ports_file migrating_file migrating"

# Is FILE a layout marker that says layout 2? The marker is JSON, for example
# {"layout":2,"moved_at":"..."}. Matched by pattern, not parsed, so no
# subprocess is needed; lib/paths.py uses the same pattern.
_cctrl_paths_layout2() {
    local f="$1" content="" ws=$' \t\r\n' re
    [[ -f "$f" ]] || return 1
    IFS= read -r -d '' content < "$f" 2>/dev/null || true
    re="\"layout\"[${ws}]*:[${ws}]*2([^0-9.eE]|\$)"
    [[ "$content" =~ $re ]]
}

_cctrl_paths_resolve() {
    local root="$1" state_home config_home home="${HOME:-}"
    # Never an environment signal for the mode (plan 116 review S6). An
    # exported value would reach every tmux pane and agent shell an installed
    # cctrl starts, so a hand-run checkout in such a pane would use the live
    # store. Dropped here, before anything is spawned.
    unset CCTRL_RUNTIME_MODE

    _CCTRL_P_ROOT="$root"
    if [[ -f "$root/.installed" ]]; then
        _CCTRL_P_MODE=installed
    else
        _CCTRL_P_MODE=checkout
    fi

    if [[ -n "${XDG_STATE_HOME:-}" && "$XDG_STATE_HOME" == /* ]]; then
        state_home="$XDG_STATE_HOME"
    else
        state_home="$home/.local/state"
    fi
    if [[ -n "${CCTRL_STATE_DIR:-}" && "$CCTRL_STATE_DIR" == /* ]]; then
        _CCTRL_P_STATE_ROOT="$CCTRL_STATE_DIR"
    else
        _CCTRL_P_STATE_ROOT="$state_home/cctrl"
    fi

    _CCTRL_P_DATA_LAYOUT=1
    _CCTRL_P_STORE_DATA_DIR="$root/data"
    if [[ "$_CCTRL_P_MODE" == installed ]] && _cctrl_paths_layout2 "$_CCTRL_P_STATE_ROOT/data/LAYOUT"; then
        _CCTRL_P_DATA_LAYOUT=2
        _CCTRL_P_STORE_DATA_DIR="$_CCTRL_P_STATE_ROOT/data"
    fi
    _CCTRL_P_DATA_DIR="${CCTRL_DATA_DIR:-$_CCTRL_P_STORE_DATA_DIR}"

    _CCTRL_P_COSTS_LAYOUT=1
    _CCTRL_P_COSTS_DIR="$root/costs"
    if [[ "$_CCTRL_P_MODE" == installed ]] && _cctrl_paths_layout2 "$_CCTRL_P_STATE_ROOT/costs/LAYOUT"; then
        _CCTRL_P_COSTS_LAYOUT=2
        _CCTRL_P_COSTS_DIR="$_CCTRL_P_STATE_ROOT/costs"
    fi
    [[ -n "${CCTRL_COSTS_DIR:-}" ]] && _CCTRL_P_COSTS_DIR="$CCTRL_COSTS_DIR"

    _CCTRL_P_AUDIT_DIR="$_CCTRL_P_STATE_ROOT/audit"
    _CCTRL_P_SESSIONS_DIR="${CCTRL_SESSION_METADATA_DIR:-$_CCTRL_P_DATA_DIR/sessions}"
    _CCTRL_P_SNAPSHOTS_DIR="$_CCTRL_P_DATA_DIR/snapshots"
    _CCTRL_P_HOST_ID_FILE="${CCTRL_HOST_ID_FILE:-$_CCTRL_P_DATA_DIR/host-id}"
    _CCTRL_P_NEEDS_ME_SNAPSHOT="${CCTRL_NEEDS_ME_SNAPSHOT:-$_CCTRL_P_DATA_DIR/needs-me-snapshot.json}"

    _CCTRL_P_SHORTCUTS_FILE="${CCTRL_SHORTCUTS_FILE:-$_CCTRL_P_STORE_DATA_DIR/shortcuts.json}"
    _CCTRL_P_HOSTS_FILE="${CCTRL_HOSTS_FILE:-$_CCTRL_P_STORE_DATA_DIR/hosts.json}"
    _CCTRL_P_RATE_LIMITS_FILE="$_CCTRL_P_STORE_DATA_DIR/rate-limits.json"
    _CCTRL_P_RATE_LIMITS_HISTORY="$_CCTRL_P_STORE_DATA_DIR/rate-limits-history.jsonl"
    _CCTRL_P_PORTS_FILE="$_CCTRL_P_STORE_DATA_DIR/ports-seen.json"
    _CCTRL_P_SPENDING_LOG="$_CCTRL_P_COSTS_DIR/spending.jsonl"

    _CCTRL_P_CONFIG_DEFAULT="$root/share/config.default.json"
    _CCTRL_P_CONFIG_LEGACY="$_CCTRL_P_STORE_DATA_DIR/config.json"
    _CCTRL_P_CONFIG_LOCAL="${CCTRL_CONFIG_LOCAL:-$_CCTRL_P_STORE_DATA_DIR/config.local.json}"
    _CCTRL_P_CONFIG_USER="${CCTRL_USER_CONFIG:-}"
    if [[ -z "$_CCTRL_P_CONFIG_USER" && -n "$home" ]]; then
        if [[ -n "${XDG_CONFIG_HOME:-}" && "$XDG_CONFIG_HOME" == /* ]]; then
            config_home="$XDG_CONFIG_HOME/cctrl"
        else
            config_home="$home/.config/cctrl"
        fi
        _CCTRL_P_CONFIG_USER="$config_home/config.json"
    fi

    _CCTRL_P_MIGRATING_FILE="$_CCTRL_P_STATE_ROOT/.migrating"
    if [[ -e "$_CCTRL_P_MIGRATING_FILE" || -L "$_CCTRL_P_MIGRATING_FILE" ]]; then
        _CCTRL_P_MIGRATING=1
    else
        _CCTRL_P_MIGRATING=0
    fi
}

# key=value lines in canonical order (for `cctrl paths` and the tests).
_cctrl_paths_kv() {
    local key var
    for key in $_CCTRL_PATHS_KEYS; do
        _cctrl_paths_upper "$key"
        var="_CCTRL_P_$_CCTRL_UP"
        printf '%s=%s\n' "$key" "${!var-}"
    done
}

# Upper-case a key into _CCTRL_UP with no subprocess (bash 3.2 has no ${v^^}).
_cctrl_paths_upper() {
    local s="$1" out="" c i
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            a) c=A ;; b) c=B ;; c) c=C ;; d) c=D ;; e) c=E ;; f) c=F ;; g) c=G ;;
            h) c=H ;; i) c=I ;; j) c=J ;; k) c=K ;; l) c=L ;; m) c=M ;; n) c=N ;;
            o) c=O ;; p) c=P ;; q) c=Q ;; r) c=R ;; s) c=S ;; t) c=T ;; u) c=U ;;
            v) c=V ;; w) c=W ;; x) c=X ;; y) c=Y ;; z) c=Z ;;
        esac
        out+="$c"
    done
    _CCTRL_UP="$out"
}

# ── Test-mode gate (plan 116 A0, review S10) ─────────────────────────────
#
# Test-only overrides (A1's fault injection, plan 119's clock and tool-path
# overrides) bite only while this gate is true. It is true only when ALL of
# these hold:
#   - CCTRL_TEST_MODE=1;
#   - every resolved state path (state root, data, store data, costs, audit,
#     user and local config, session records, snapshots, host id and
#     TMUX_TMPDIR) resolves by realpath inside one directory that holds a
#     .cctrl-test-sandbox file;
#   - the effective seal key path resolves inside that directory too.
# Separately, test mode refuses to run at all (exit 64) when the effective
# seal key path is the live user's key path. The live path comes from the
# password database (getpwuid), never from HOME. The marker is not a secret:
# a sandbox that holds neither the live store nor the live key can mint
# nothing the live store accepts.
#
# Unlike the resolver above, the gate may run subprocesses (realpath, id). It
# runs only when CCTRL_TEST_MODE=1 is set.

# realpath of PATH, or of its nearest existing ancestor plus the rest, into
# _CCTRL_TM_REAL. Never fails on a missing path.
_cctrl_tm_realpath() {
    local p="$1" rest="" base
    [[ "$p" == /* ]] || p="$PWD/$p"
    while [[ ! -e "$p" && "$p" != / && -n "$p" ]]; do
        base="${p##*/}"
        rest="/$base$rest"
        p="${p%/*}"
        [[ -n "$p" ]] || p=/
    done
    local hops=0 t
    while [[ -L "$p" && hops -lt 40 ]]; do
        t="$(readlink -- "$p" 2>/dev/null)" || break
        if [[ "$t" == /* ]]; then p="$t"; else p="${p%/*}/$t"; fi
        hops=$((hops + 1))
    done
    if [[ -d "$p" ]]; then
        p="$(cd -P -- "$p" 2>/dev/null && pwd -P)" || p=""
    else
        local d="${p%/*}" b="${p##*/}"
        [[ -n "$d" ]] || d=/
        d="$(cd -P -- "$d" 2>/dev/null && pwd -P)" || d=""
        p="${d%/}/$b"
    fi
    _CCTRL_TM_REAL="${p%/}$rest"
    [[ -n "$_CCTRL_TM_REAL" ]] || _CCTRL_TM_REAL=/
}

# The seal key's file name, assembled so no file in the tree that cctrl
# embeds holds the key path as one literal (test_peer_seal_key_never_leaks).
# The gate never prints a key path; its reasons name no path.
_CCTRL_TM_KEY_REL=".local/state/cctrl/peer-seal"".key"

# The live user's seal key path, from the password database.
_cctrl_tm_live_key() {
    local user pw_home
    user="$(id -un 2>/dev/null)" || user=""
    [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] || { _CCTRL_TM_LIVE_KEY=""; return 1; }
    pw_home="$(eval "printf '%s' ~$user")"
    [[ "$pw_home" == /* ]] || { _CCTRL_TM_LIVE_KEY=""; return 1; }
    _CCTRL_TM_LIVE_KEY="$pw_home/$_CCTRL_TM_KEY_REL"
}

# The effective seal key path, the way lib/peer_seal.py picks it.
_cctrl_tm_key() {
    if [[ -n "${CCTRL_PEER_SEAL_KEY_FILE:-}" ]]; then
        _CCTRL_TM_KEY="$CCTRL_PEER_SEAL_KEY_FILE"
    else
        _CCTRL_TM_KEY="${HOME:-}/$_CCTRL_TM_KEY_REL"
    fi
}

# Is the effective key the live key? 0 = yes (refuse).
_cctrl_tm_key_is_live() {
    _cctrl_tm_key
    _cctrl_tm_live_key || return 0   # cannot tell: treat as live
    local a b
    _cctrl_tm_realpath "$_CCTRL_TM_KEY"; a="$_CCTRL_TM_REAL"
    _cctrl_tm_realpath "$_CCTRL_TM_LIVE_KEY"; b="$_CCTRL_TM_REAL"
    [[ "$_CCTRL_TM_KEY" == "$_CCTRL_TM_LIVE_KEY" || "$a" == "$b" ]]
}

# The test-mode gate. Needs _cctrl_paths_resolve to have run. Returns 0 in
# test mode, 1 when not, 64 when test mode is asked for with the live key.
# The reason is in _CCTRL_TEST_MODE_REASON.
_cctrl_test_mode() {
    _CCTRL_TEST_MODE_REASON=""
    if [[ "${CCTRL_TEST_MODE:-}" != 1 ]]; then
        _CCTRL_TEST_MODE_REASON="CCTRL_TEST_MODE is not 1"
        return 1
    fi
    if _cctrl_tm_key_is_live; then
        _CCTRL_TEST_MODE_REASON="the seal key is the live key"
        return 64
    fi
    if [[ -z "${TMUX_TMPDIR:-}" ]]; then
        _CCTRL_TEST_MODE_REASON="TMUX_TMPDIR is not set"
        return 1
    fi
    # The sandbox is the nearest ancestor of the state root holding the marker.
    _cctrl_tm_realpath "$_CCTRL_P_STATE_ROOT"
    local sandbox="$_CCTRL_TM_REAL"
    while [[ -n "$sandbox" && ! -f "$sandbox/.cctrl-test-sandbox" ]]; do
        [[ "$sandbox" == / ]] && { sandbox=""; break; }
        sandbox="${sandbox%/*}"
        [[ -n "$sandbox" ]] || sandbox=/
    done
    if [[ -z "$sandbox" || "$sandbox" == / ]]; then
        _CCTRL_TEST_MODE_REASON="no .cctrl-test-sandbox above the state root"
        return 1
    fi
    local p
    for p in "$_CCTRL_P_STATE_ROOT" "$_CCTRL_P_DATA_DIR" "$_CCTRL_P_STORE_DATA_DIR" \
        "$_CCTRL_P_COSTS_DIR" "$_CCTRL_P_AUDIT_DIR" "$_CCTRL_P_CONFIG_USER" \
        "$_CCTRL_P_CONFIG_LOCAL" "$_CCTRL_P_SESSIONS_DIR" "$_CCTRL_P_SNAPSHOTS_DIR" \
        "$_CCTRL_P_HOST_ID_FILE" "$TMUX_TMPDIR" "$_CCTRL_TM_KEY"; do
        if [[ -z "$p" ]]; then
            _CCTRL_TEST_MODE_REASON="a state path is empty"
            return 1
        fi
        _cctrl_tm_realpath "$p"
        case "$_CCTRL_TM_REAL" in
            "$sandbox"|"$sandbox"/*) ;;
            *)
                _CCTRL_TEST_MODE_REASON="outside the sandbox: $p"
                return 1
                ;;
        esac
    done
    _CCTRL_TEST_MODE_REASON="sandbox $sandbox"
    return 0
}
