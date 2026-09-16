#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
export CCTRL_DATA_DIR="$TMPDIR/data"
export CCTRL_SESSION_METADATA_DIR="$TMPDIR/session-metadata"
export CCTRL_HOST_ID_FILE="$CCTRL_DATA_DIR/host-id"
# Keep discovery tests isolated from large, live Codex/Claude stores. Individual
# persistence tests override these roots with their own fixtures.
export CODEX_HOME="$TMPDIR/no-codex-home"
export CLAUDE_CONFIG_DIR="$TMPDIR/no-claude-config"
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/hostname" <<'SH'
#!/usr/bin/env bash
host="${CCTRL_TEST_HOSTNAME:-test-host.local}"
if [[ "${1:-}" == "-s" ]]; then
    printf '%s
' "${host%%.*}"
else
    printf '%s
' "$host"
fi
SH
chmod +x "$TMPDIR/hostname"

# Tests may be run from inside a cctrl tmux session; don't let its context
# leak in (CCTRL_TMUX_CONTEXT flips `cctrl start` into foreground mode).
unset CCTRL_TMUX_CONTEXT TMUX TMUX_PANE CCTRL_AGENT CCTRL_HOST_PREFIX CCTRL_PEER CCTRL_DEVICE_TAG CCTRL_TEST_HOSTNAME CCTRL_ATTACH_AFTER_START
unset CCTRL_USER_CONFIG CCTRL_CONFIG_LOCAL
unset CCTRL_SESSION_KIND CCTRL_SESSION_NAME CCTRL_SESSION_TARGET CCTRL_SESSION_PURPOSE
# Skip post-spawn health check by default in tests — it would sleep through
# poll loops with the fake tmux. Individual health check tests override this.
export CCTRL_NO_HEALTH_CHECK=1
export CCTRL_TITLE_MODE=heuristic
export CCTRL_USER_CONFIG="$TMPDIR/no-user-config.json"
export CCTRL_CONFIG_LOCAL="$TMPDIR/no-local-config.json"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local haystack="$1" needle="$2"
    [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
    local haystack="$1" needle="$2"
    [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: $needle"
}

session_record_path() {
    local name="$1" dir="${2:-$CCTRL_SESSION_METADATA_DIR}" file legacy match=""
    for file in "$dir"/task-*.json "$dir"/launch-*.json; do
        [[ -f "$file" ]] || continue
        if jq -e --arg name "$name" '(.tmux_session // .name // "") == $name' "$file" >/dev/null 2>&1; then
            if [[ -z "$match" || "$file" -nt "$match" ]]; then match="$file"; fi
        fi
    done
    [[ -n "$match" ]] && { printf '%s' "$match"; return 0; }
    legacy="$dir/$(printf '%s' "$name" | tr '/:' '__').json"
    [[ -f "$legacy" ]] && { printf '%s' "$legacy"; return 0; }
    return 1
}

session_record_json() {
    local path
    path="$(session_record_path "$1" "${2:-$CCTRL_SESSION_METADATA_DIR}")" || return 1
    cat "$path"
}

cctrl_source_eval() {
    local code="$1"
    shift
    CCTRL_NO_MAIN=1 bash -c 'code="$1"; shift; source "$0"; eval "$code"' "$ROOT/cctrl" "$code" "$@"
}

run_with_pty_input() {
    local input="$1"
    shift
    PTY_INPUT="$input" python3 - "$@" <<'PY'
import errno
import os
import pty
import select
import signal
import sys

argv = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.execvpe(argv[0], argv, os.environ)

pending = os.environ["PTY_INPUT"].encode()
sent = False
while True:
    readable, _, _ = select.select([fd], [], [], 10)
    if not readable:
        os.kill(pid, signal.SIGTERM)
        os.waitpid(pid, 0)
        raise SystemExit(124)
    try:
        chunk = os.read(fd, 4096)
    except OSError as exc:
        if exc.errno == errno.EIO:
            break
        raise
    if not chunk:
        break
    sys.stdout.buffer.write(chunk)
    sys.stdout.buffer.flush()
    if not sent and b"> " in chunk:
        os.write(fd, pending)
        sent = True

_, status = os.waitpid(pid, 0)
raise SystemExit(os.waitstatus_to_exitcode(status))
PY
}

make_fake_agent() {
    local path="$1" name="$2"
    cat > "$path" <<SH
#!/usr/bin/env bash
echo "CMD=$name"
if [[ -n "\${CCTRL_PEER:-}" ]]; then
    printf 'ENV_CCTRL_PEER=%s\n' "\$CCTRL_PEER"
fi
i=0
for arg in "\$@"; do
    printf 'ARG[%d]=%s\n' "\$i" "\$arg"
    i=\$((i + 1))
done
SH
    chmod +x "$path"
}

make_fake_tmux() {
    local path="$1"
    cat > "$path" <<'SH'
#!/usr/bin/env bash
if [[ -n "${TMUX_LOG:-}" ]]; then
    {
        printf 'TMUX'
        for arg in "$@"; do
            printf ' %q' "$arg"
        done
        printf '\n'
    } >> "$TMUX_LOG"
fi
if [[ "${1:-}" == "new-session" ]]; then
    printf 'SHELL_CMD=%s\n' "${@: -1}" >> "${TMUX_LOG:?}"
fi

case "${1:-}" in
    capture-pane)
        if [[ "${TMUX_FAKE_CAPTURE_FAIL:-}" == "1" ]]; then
            echo "capture failed" >&2
            exit 1
        fi
        printf '%s' "${TMUX_FAKE_CAPTURE_PANE:-}"
        exit 0
        ;;
    load-buffer)
        if [[ "${TMUX_FAKE_LOAD_FAIL:-}" == "1" ]]; then
            echo "load failed" >&2
            exit 1
        fi
        sentinel=$'\037'
        input="$(cat; printf '%s' "$sentinel")"
        input="${input%$sentinel}"
        printf 'BUFFER %s\n' "$input" >> "${TMUX_LOG:?}"
        # Raw-byte capture (plan 024): the `BUFFER %s\n` log line cannot prove
        # trailing-newline fidelity, so when asked, dump the exact load-buffer
        # payload bytes to a file for a byte-for-byte comparison.
        [[ -n "${TMUX_BUFFER_FILE:-}" ]] && printf '%s' "$input" > "$TMUX_BUFFER_FILE"
        exit 0
        ;;
    paste-buffer)
        if [[ "${TMUX_FAKE_PASTE_FAIL:-}" == "1" ]]; then
            echo "paste failed" >&2
            exit 1
        fi
        exit 0
        ;;
    send-keys)
        if [[ "${TMUX_FAKE_SEND_FAIL:-}" == "1" ]]; then
            echo "send failed" >&2
            exit 1
        fi
        exit 0
        ;;
    delete-buffer)
        exit 0
        ;;
    has-session)
        if [[ "${TMUX_FAKE_HAS_SESSION:-}" == "1" ]]; then
            exit 0
        fi
        if [[ -n "${TMUX_FAKE_HAS_SESSION:-}" ]]; then
            target=""
            for ((i = 1; i <= $#; i++)); do
                if [[ "${!i}" == "-t" ]]; then
                    j=$((i + 1))
                    target="${!j:-}"
                    break
                fi
            done
            [[ " ${TMUX_FAKE_HAS_SESSION} " == *" ${target} "* ]] && exit 0
        fi
        exit 1
        ;;
    list-sessions)
        if [[ -n "${TMUX_FAKE_SESSIONS:-}" ]]; then
            for session in $TMUX_FAKE_SESSIONS; do
                printf '%s\n' "$session"
            done
        else
            printf 'demo\n'
        fi
        exit 0
        ;;
    list-panes)
        if [[ "$*" == *pane_current_path* ]]; then
            printf '/tmp/demo\n'
        elif [[ "$*" == *pane_id* ]]; then
            printf '%s:%s\n' "${TMUX_FAKE_PANE_ID:-%0}" "${TMUX_FAKE_PANE_PID:-12345}"
        elif [[ "${TMUX_FAKE_PANE_PID:-}" == "__current__" ]]; then
            printf '%s\n' "${CCTRL_CURRENT_PID:?}"
        elif [[ -n "${TMUX_FAKE_PANE_PID:-}" ]]; then
            printf '%s\n' "$TMUX_FAKE_PANE_PID"
        else
            printf '12345\n'
        fi
        exit 0
        ;;
    display-message)
        if [[ "$*" == *session_name* ]]; then
            printf '%s\n' "${TMUX_FAKE_SESSION_NAME:-demo}"
        else
            printf '0\n'
        fi
        exit 0
        ;;
    display)
        if [[ "$*" == *pane_in_mode* ]]; then
            printf '%s\n' "${TMUX_FAKE_PANE_IN_MODE:-0}"
        else
            printf '0\n'
        fi
        exit 0
        ;;
    show-option)
        printf '1\n'
        exit 0
        ;;
    *) exit 0 ;;
esac
SH
    chmod +x "$path"
}

make_fake_ps() {
    local path="$1"
    cat > "$path" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *12345* ]]; then
    printf 'codex --yolo\n'
    exit 0
fi
exec /bin/ps "$@"
SH
    chmod +x "$path"
}

make_fake_ssh() {
    local path="$1"
    cat > "$path" <<'SH'
#!/usr/bin/env bash
{
    printf 'SSH'
    for arg in "$@"; do
        printf ' %q' "$arg"
    done
    printf '\n'
} >> "${SSH_LOG:?}"
exit 0
SH
    chmod +x "$path"
}

test_syntax() {
    bash -n "$ROOT/cctrl"
    bash -n "$ROOT/tests/run-tests.sh"
    bash -n "$ROOT/hooks/notify.sh"
    bash -n "$ROOT/hooks/peer-doorbell.sh"
    bash -n "$ROOT/hooks/statusline.sh"
    bash -n "$ROOT/install.sh"
    zsh -n "$ROOT/completions/_cctrl"
    python3 -m py_compile "$ROOT/lib/usage_costs.py" "$ROOT/lib/peer_mcp.py" "$ROOT/lib/runtime_mcp.py" "$ROOT/hooks/session-log.py" "$ROOT/hooks/block-git-commit.py"
    # Plugin entry scripts are dispatched by `cctrl <cmd>` exactly like a core
    # command, so a syntax error in one is a user-visible break. Both are
    # python3 (#!/usr/bin/env python3), same as lib/*.py above. py_compile needs
    # a .py name, so compile a suffixed copy rather than skipping them.
    local plugin dest
    mkdir -p "$TMPDIR/plugin-syntax"
    for plugin in "$ROOT"/plugins/cctrl-*; do
        [[ -f "$plugin" ]] || continue
        dest="$TMPDIR/plugin-syntax/$(basename "$plugin" | tr - _).py"
        cp "$plugin" "$dest"
        python3 -m py_compile "$dest"
    done
}

test_launch_args() {
    make_fake_agent "$TMPDIR/codex" codex
    make_fake_agent "$TMPDIR/claude" claude

    local out rc
    out="$(PATH="$TMPDIR:$PATH" "$ROOT/cctrl" start --foreground --agent codex --model gpt-5.5 --sandbox workspace-write --ask-for-approval on-request -m "fix bug")"
    assert_contains "$out" "CMD=codex"
    assert_contains "$out" "ARG[0]=--model"
    assert_contains "$out" "ARG[1]=gpt-5.5"
    assert_contains "$out" "ARG[2]=--sandbox"
    assert_contains "$out" "ARG[3]=workspace-write"
    assert_contains "$out" "ARG[4]=--ask-for-approval"
    assert_contains "$out" "ARG[5]=on-request"
    assert_contains "$out" "ARG[6]=fix bug"

    out="$(PATH="$TMPDIR:$PATH" "$ROOT/cctrl" start --foreground --agent codex --resume -m "continue bug")"
    assert_contains "$out" "CMD=codex"
    assert_contains "$out" "ARG[0]=resume"
    assert_contains "$out" "ARG[1]=--yolo"
    assert_contains "$out" "ARG[2]=--last"
    assert_contains "$out" "ARG[3]=continue bug"

    out="$(PATH="$TMPDIR:$PATH" "$ROOT/cctrl" start --foreground --agent claude --model sonnet --yolo --no-bridge -m "fix bug")"
    assert_contains "$out" "CMD=claude"
    assert_contains "$out" "ARG[0]=--permission-mode"
    assert_contains "$out" "ARG[1]=bypassPermissions"
    assert_contains "$out" "ARG[2]=--model"
    assert_contains "$out" "ARG[3]=sonnet"
    assert_contains "$out" "ARG[4]=--chrome"
    assert_contains "$out" "ARG[5]=fix bug"

    out="$(PATH="$TMPDIR:$PATH" CCTRL_AGENT=codex "$ROOT/cctrl" start --foreground -m "default agent")"
    assert_contains "$out" "CMD=codex"
    assert_contains "$out" "ARG[0]=--yolo"
    assert_contains "$out" "ARG[1]=default agent"

    out="$(PATH="$TMPDIR:$PATH" "$ROOT/cctrl" start --foreground --agent codex --remote unix:// -m "remote prompt")"
    assert_contains "$out" "CMD=codex"
    assert_contains "$out" "ARG[0]=--yolo"
    assert_contains "$out" "ARG[1]=--remote"
    assert_contains "$out" "ARG[2]=unix://"
    assert_contains "$out" "ARG[3]=remote prompt"

    local codex_home="$TMPDIR/codex-remote-home"
    mkdir -p "$codex_home/app-server-daemon"
    printf '{"remoteControlEnabled":true}\n' > "$codex_home/app-server-daemon/settings.json"
    out="$(PATH="$TMPDIR:$PATH" CODEX_HOME="$codex_home" CCTRL_SESSION_KIND=tmux CCTRL_SESSION_NAME=TMUX--project "$ROOT/cctrl" start --foreground --agent codex -m "tmux default")"
    assert_contains "$out" "CMD=codex"
    assert_contains "$out" "ARG[0]=--yolo"
    assert_contains "$out" "ARG[1]=--cd"
    assert_contains "$out" "ARG[3]=-c"
    assert_contains "$out" "mcp_servers.cctrl_runtime.command"
    assert_contains "$out" "ARG[7]=tmux default"
    assert_not_contains "$out" "--remote"

    out="$(PATH="$TMPDIR:$PATH" CODEX_HOME="$codex_home" CCTRL_CODEX_REMOTE_DEFAULT=unix:// CCTRL_SESSION_KIND=tmux CCTRL_SESSION_NAME=TMUX--project "$ROOT/cctrl" start --foreground --agent codex -m "remote default")"
    assert_contains "$out" "CMD=codex"
    assert_contains "$out" "ARG[0]=--yolo"
    assert_contains "$out" "ARG[1]=--remote"
    assert_contains "$out" "ARG[2]=unix://"
    assert_contains "$out" "ARG[3]=--cd"
    assert_contains "$out" "mcp_servers.cctrl_runtime.args"
    assert_contains "$out" "ARG[9]=remote default"

    out="$(PATH="$TMPDIR:$PATH" CODEX_HOME="$codex_home" CCTRL_SESSION_KIND=tmux CCTRL_SESSION_NAME=TMUX--project "$ROOT/cctrl" start --foreground --agent codex --no-bridge -m "remote suppressed")"
    assert_contains "$out" "CMD=codex"
    assert_contains "$out" "ARG[0]=--yolo"
    assert_contains "$out" "ARG[1]=--cd"
    assert_contains "$out" "mcp_servers.cctrl_runtime.command"
    assert_contains "$out" "ARG[7]=remote suppressed"
    assert_not_contains "$out" "--remote"
}

test_agent_prompt_without_default() {
    make_fake_agent "$TMPDIR/codex" codex
    make_fake_agent "$TMPDIR/claude" claude

    local rootcopy="$TMPDIR/cctrl-agent-prompt-copy"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"

    local out rc=0
    out="$(PATH="$TMPDIR:$PATH" "$rootcopy/cctrl" start --foreground -m "needs agent" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected missing default agent to fail without a TTY"
    assert_contains "$out" "No agent selected and prompting is unavailable"
    assert_contains "$out" "Pass --agent <agent>"

    local out_file="$TMPDIR/agent-prompt-output.log"
    if ! run_with_pty_input $'2\n' env PATH="$TMPDIR:$PATH" \
        "$rootcopy/cctrl" start --foreground -m "prompted agent" \
        > "$out_file" 2>&1; then
        fail "agent prompt pseudo-TTY invocation failed: $(cat "$out_file")"
    fi

    out="$(cat "$out_file")"
    assert_contains "$out" "Choose agent runtime:"
    assert_contains "$out" "1) claude"
    assert_contains "$out" "2) codex"
    assert_contains "$out" "CMD=codex"
    assert_contains "$out" "ARG[0]=--yolo"
    assert_contains "$out" "ARG[1]=prompted agent"
}

test_profile_writes_are_owner_only() {
    # Profiles hold credentials, so every write path must land at mode 600 —
    # a plain redirect or `mv` would otherwise inherit the ambient umask.
    local rootcopy="$TMPDIR/cctrl-profile-perms-copy"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"

    local settings="$rootcopy/settings.json"
    printf '{"model":"claude-opus-5","env":{"PORTKEY_API_KEY":"secret-value"}}\n' > "$settings"

    # save: the umask is deliberately permissive so an unfixed write shows as 644
    ( umask 022; CCTRL_SETTINGS="$settings" CCTRL_ROOT="$rootcopy" \
        "$rootcopy/cctrl" save permtest >/dev/null 2>&1 ) || true
    [[ -f "$rootcopy/profiles/permtest.json" ]] || return 0   # save unsupported in this harness

    local mode
    mode="$(stat -f '%Lp' "$rootcopy/profiles/permtest.json" 2>/dev/null \
            || stat -c '%a' "$rootcopy/profiles/permtest.json")"
    [[ "$mode" == "600" ]] || fail "saved profile is mode $mode, expected 600"

    # rename must not carry a permissive mode across
    chmod 644 "$rootcopy/profiles/permtest.json"
    ( CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" rename permtest permtest2 >/dev/null 2>&1 ) || true
    if [[ -f "$rootcopy/profiles/permtest2.json" ]]; then
        mode="$(stat -f '%Lp' "$rootcopy/profiles/permtest2.json" 2>/dev/null \
                || stat -c '%a' "$rootcopy/profiles/permtest2.json")"
        [[ "$mode" == "600" ]] || fail "renamed profile is mode $mode, expected 600"
    fi

    echo "ok: profile writes land at mode 600 (credentials are not world-readable)"
}

test_host_registry_crud() {
    # `cctrl host add|list|rm` had zero direct coverage: hosts.json was only ever
    # written by hand as a fixture for the fleet/remote tests, so the CRUD verbs
    # that produce it were never exercised. CCTRL_ROOT isolates the registry
    # (<root>/data/hosts.json) from the developer's real one.
    local rootcopy="$TMPDIR/cctrl-host-crud-copy"
    mkdir -p "$rootcopy/data"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"

    local out rc

    # add: with and without an explicit user.
    CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" host add box box.invalid tester >/dev/null
    CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" host add plain plain.invalid >/dev/null
    jq -e '.box.hostname == "box.invalid" and .box.user == "tester"' "$rootcopy/data/hosts.json" >/dev/null \
        || fail "host add did not persist hostname+user"
    jq -e '.plain.hostname == "plain.invalid" and (.plain.user == "" or .plain.user == null)' "$rootcopy/data/hosts.json" >/dev/null \
        || fail "host add without a user should leave user empty"

    # list: shows both registered hosts and the built-in local aliases.
    out="$(CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" host list)"
    assert_contains "$out" "box"
    assert_contains "$out" "tester@box.invalid"
    assert_contains "$out" "plain.invalid"
    assert_contains "$out" "local"

    # rm: removes only the named host.
    CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" host rm box >/dev/null
    jq -e 'has("box") | not' "$rootcopy/data/hosts.json" >/dev/null || fail "host rm did not remove the host"
    jq -e 'has("plain")' "$rootcopy/data/hosts.json" >/dev/null || fail "host rm removed an unrelated host"

    # Failure paths exit non-zero rather than silently succeeding.
    rc=0
    CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" host rm ghost >/dev/null 2>&1 || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit removing an unregistered host"
    rc=0
    CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" host add incomplete >/dev/null 2>&1 || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for host add missing a hostname"

    echo "ok: host registry add/list/rm round-trips and fails loudly on bad input"
}

test_profile_use_current_diff() {
    # `use`, `current`, and `diff` had no direct coverage (only `save`/`rename`
    # were touched, by the profile-perms test). All three read and WRITE
    # $HOME/.claude/settings.json — CLAUDE_DIR is derived from HOME with no
    # override — so HOME is redirected at a fixture dir. Without that, running
    # this suite would merge a test profile into the developer's real Claude
    # settings. (CCTRL_SETTINGS is not a variable cctrl reads; HOME is the seam.)
    local rootcopy="$TMPDIR/cctrl-profile-verbs-copy"
    local fakehome="$rootcopy/home"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$fakehome/.claude"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"

    printf '{"model":"claude-sonnet-5","env":{"KEEP":"yes"}}\n' > "$fakehome/.claude/settings.json"
    printf '{"model":"claude-opus-5","env":{"PROFILE_ONLY":"1"}}\n' > "$rootcopy/profiles/work.json"
    printf '{"model":"claude-sonnet-5","env":{"KEEP":"yes"}}\n' > "$rootcopy/profiles/home.json"

    local out rc

    # ls lists both profiles.
    out="$(HOME="$fakehome" CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" ls)"
    assert_contains "$out" "work"
    assert_contains "$out" "home"

    # use sets the active default AND merges the profile's Claude model+env into
    # settings.json for legacy compatibility. The merge is additive: a key the
    # profile does not mention survives.
    HOME="$fakehome" CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" use work >/dev/null
    [[ "$(cat "$rootcopy/.active-profile")" == "work" ]] || fail "use did not write .active-profile"
    jq -e '.model == "claude-opus-5" and .env.PROFILE_ONLY == "1" and .env.KEEP == "yes"' \
        "$fakehome/.claude/settings.json" >/dev/null \
        || fail "use should merge the profile's model+env without dropping existing keys"

    # current names the active profile.
    out="$(HOME="$fakehome" CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" current)"
    assert_contains "$out" "work"
    assert_contains "$out" "claude-opus-5"

    # diff reports the delta against another profile; the differing model shows
    # on both sides and the profile-only env key shows as removed.
    out="$(HOME="$fakehome" CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" diff home)"
    assert_contains "$out" "claude-sonnet-5"
    assert_contains "$out" "PROFILE_ONLY"

    # Unknown profile names fail loudly on both verbs.
    rc=0
    HOME="$fakehome" CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" use ghost >/dev/null 2>&1 || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for 'use' with an unknown profile"
    rc=0
    HOME="$fakehome" CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" diff ghost >/dev/null 2>&1 || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for 'diff' with an unknown profile"
    # The failed switch must not have moved the active default.
    [[ "$(cat "$rootcopy/.active-profile")" == "work" ]] || fail "a failed 'use' changed the active profile"

    echo "ok: profile use/current/diff resolve, merge additively, and reject unknown names"
}

test_profile_prompt_overrides_global_default() {
    make_fake_agent "$TMPDIR/codex" codex
    make_fake_agent "$TMPDIR/claude" claude

    local rootcopy="$TMPDIR/cctrl-profile-agent-prompt-copy"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    printf '{"defaultAgent":"codex"}\n' > "$rootcopy/data/config.json"
    printf 'personal\n' > "$rootcopy/.active-profile"
    printf '{"defaultAgent":null,"env":{}}\n' > "$rootcopy/profiles/personal.json"

    local out rc=0
    out="$(PATH="$TMPDIR:$PATH" "$rootcopy/cctrl" start --foreground --no-bridge -m "personal prompt" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected profile prompt override to fail without a TTY"
    assert_contains "$out" "No agent selected and prompting is unavailable"

    local out_file="$TMPDIR/profile-agent-prompt-output.log"
    if ! run_with_pty_input $'1\n' env PATH="$TMPDIR:$PATH" \
        "$rootcopy/cctrl" start --foreground --no-bridge -m "profile picked claude" \
        > "$out_file" 2>&1; then
        fail "profile prompt pseudo-TTY invocation failed: $(cat "$out_file")"
    fi

    out="$(cat "$out_file")"
    assert_contains "$out" "Choose agent runtime:"
    assert_contains "$out" "CMD=claude"
    assert_contains "$out" "ARG[0]=--permission-mode"
    assert_contains "$out" "ARG[2]=--chrome"
    assert_contains "$out" "ARG[3]=profile picked claude"
}

test_local_config_overrides_shared_defaults() {
    make_fake_tmux "$TMPDIR/tmux"

    local rootcopy="$TMPDIR/cctrl-local-config-copy"
    local project="$TMPDIR/config-local-project"
    local log="$TMPDIR/local-config-tmux.log"
    local curl_log="$TMPDIR/local-config-curl.log"
    local user_config="$TMPDIR/user-config/config.json"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$project" "$(dirname "$user_config")"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"

    printf '{"defaultAgent":"claude","titleEndpoint":"http://shared.invalid/v1","titleModel":"shared-model"}\n' > "$rootcopy/data/config.json"
    printf '{"defaultAgent":"codex","titleEndpoint":"http://user.invalid/v1","titleModel":"user-model"}\n' > "$user_config"
    printf '{"titleEndpoint":"http://local.invalid/v1","titleModel":"local-model"}\n' > "$rootcopy/data/config.local.json"

    cat > "$TMPDIR/curl" <<'SH'
#!/usr/bin/env bash
{
    printf 'CURL'
    for arg in "$@"; do
        printf ' %q' "$arg"
    done
    printf '\n'
} >> "${CURL_LOG:?}"
printf '{"choices":[{"message":{"content":"Local Override Title"}}]}\n'
SH
    chmod +x "$TMPDIR/curl"

    : > "$log"
    : > "$curl_log"
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CURL_LOG="$curl_log" \
        CCTRL_TITLE_MODE=auto CCTRL_USER_CONFIG="$user_config" CCTRL_CONFIG_LOCAL="$rootcopy/data/config.local.json" \
        CCTRL_PURPOSE_PROMPT=never CCTRL_ATTACH_PROMPT=never CCTRL_EMIT_SESSION=1 \
        "$rootcopy/cctrl" start -d -m "generate a title from local config" "$project")"
    assert_contains "$out" "detached session started"
    assert_contains "$out" "CCTRL_SESSION=TMUX--config-local-project"
    assert_contains "$(cat "$log")" "CCTRL_AGENT=codex"
    assert_contains "$(cat "$curl_log")" "http://local.invalid/v1/chat/completions"
    assert_contains "$(session_record_json "TMUX--config-local-project")" '"purpose": "Local Override Title"'

    echo "ok: local config overlays shared and user config for defaults and title generation"
}

test_detached_agent_prompt_exports_selection() {
    make_fake_agent "$TMPDIR/codex" codex
    make_fake_agent "$TMPDIR/claude" claude
    make_fake_tmux "$TMPDIR/tmux"

    local rootcopy="$TMPDIR/cctrl-detached-agent-prompt-copy"
    local project="$TMPDIR/detached-agent-prompt-project"
    local log="$TMPDIR/detached-agent-prompt-tmux.log"
    local out_file="$TMPDIR/detached-agent-prompt-output.log"
    mkdir -p "$rootcopy/data" "$project"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"

    : > "$log"
    if ! run_with_pty_input $'2\n' env PATH="$TMPDIR:$PATH" TMUX_LOG="$log" \
        CCTRL_PURPOSE_PROMPT=never CCTRL_ATTACH_PROMPT=never CCTRL_EMIT_SESSION=1 \
        "$rootcopy/cctrl" start -d "$project" \
        > "$out_file" 2>&1; then
        fail "detached agent prompt pseudo-TTY invocation failed: $(cat "$out_file")"
    fi

    out="$(cat "$out_file")"
    assert_contains "$out" "Choose agent runtime:"
    assert_contains "$out" "detached session started"
    assert_contains "$out" "CCTRL_SESSION=TMUX--detached-agent-prompt-project"
    assert_contains "$(cat "$log")" "CCTRL_AGENT=codex"
}

test_detached_arg_parsing() {
    make_fake_tmux "$TMPDIR/tmux"
    local project="$TMPDIR/project"
    local log="$TMPDIR/tmux.log"
    mkdir -p "$project"

    : > "$log"
    local out rc
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 "$ROOT/cctrl" start -d --agent codex -m "line one" "$project")"
    assert_contains "$out" "detached session started"
    assert_contains "$out" "CCTRL_SESSION=TMUX--project"
    assert_contains "$(cat "$log")" "new-session"
    assert_contains "$(cat "$log")" "--name TMUX--project"
    assert_contains "$(cat "$log")" "start --foreground"
    assert_contains "$(cat "$log")" "CCTRL_TMUX_CONTEXT=1"
    assert_contains "$(cat "$log")" "--agent\\ codex"
    assert_contains "$(cat "$log")" "-m line\\ one"
    assert_contains "$(session_record_json "TMUX--project")" '"purpose": "project: line one"'
    assert_contains "$(session_record_json "TMUX--project")" '"initial_prompt": "line one"'
    # Plan 031: the resolved agent is persisted so display/registry read it back
    # instead of re-sniffing the pane argv.
    assert_contains "$(session_record_json "TMUX--project")" '"agent": "codex"'

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_AGENT=codex CCTRL_EMIT_SESSION=1 "$ROOT/cctrl" start -d "$project" -- "literal prompt words")"
    assert_contains "$out" "detached session started"
    assert_contains "$(cat "$log")" "-- literal\\ prompt\\ words"
    assert_contains "$(cat "$log")" "start --foreground"
    assert_contains "$(session_record_json "TMUX--project")" '"purpose": "project: literal prompt words"'

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_AGENT=codex CCTRL_EMIT_SESSION=1 "$ROOT/cctrl" start -d --purpose "cleanup context" "$project")"
    assert_contains "$out" "detached session started"
    assert_contains "$(cat "$log")" "start --foreground"
    assert_not_contains "$(cat "$log")" "--purpose"
    assert_contains "$(session_record_json "TMUX--project")" '"purpose": "cleanup context"'

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 "$ROOT/cctrl" start -d --agent codex --remote unix:// -m "remote line" "$project")"
    assert_contains "$out" "detached session started"
    assert_contains "$(cat "$log")" "--remote unix://"
    assert_contains "$(cat "$log")" "-m remote\\ line"
    assert_contains "$(cat "$log")" "start --foreground"

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_HOST_PREFIX=ms CCTRL_EMIT_SESSION=1 "$ROOT/cctrl" start -d --agent codex "$project")"
    assert_contains "$out" "detached session started"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--project"
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--ms--project"
    assert_contains "$(cat "$log")" "--name TMUX--ms--project"
    assert_contains "$(cat "$log")" "start --foreground"

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_TEST_HOSTNAME=mattbook-pro.local CCTRL_EMIT_SESSION=1 "$ROOT/cctrl" start -d --agent codex "$project")"
    assert_contains "$out" "detached session started"
    assert_contains "$out" "CCTRL_SESSION=TMUX--mbp--project"
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--mbp--project"
    assert_contains "$(cat "$log")" "--name TMUX--mbp--project"
    assert_contains "$(cat "$log")" "start --foreground"

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_AGENT=codex CCTRL_EMIT_SESSION=1 \
        TMUX_FAKE_HAS_SESSION="TMUX--project" "$ROOT/cctrl" start -d "$project")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--project--2"
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--project--2"
    assert_contains "$(cat "$log")" "CCTRL_SESSION_NAME=TMUX--project--2"
    assert_contains "$(cat "$log")" "--name TMUX--project--2"
}

test_live_aware_index_picker() {
    # Plan 017: a detached launch must NEVER assign a name whose tmux session is
    # currently live (that clobbers the running session's metadata). The picker
    # is tmux-live-only: dead sessions with stale metadata do NOT reserve an
    # index, so freed indices are reused instead of sprawling --N.
    make_fake_tmux "$TMPDIR/tmux"

    # (a) REGRESSION — reproduce the `@shortcut` reuse-clobber path: the base
    # index AND --2 are both live tmux sessions, so the picker must skip both
    # and land on --3, never colliding with a live session.
    local rootcopy="$TMPDIR/cctrl-picker-copy"
    local obs_project="$TMPDIR/obsproj"
    local log="$TMPDIR/picker-tmux.log"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$obs_project"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    printf '{"obs":{"dir":"%s","agent":"codex"}}\n' "$obs_project" > "$rootcopy/data/shortcuts.json"
    printf '{"defaultAgent":"codex"}\n' > "$rootcopy/data/config.json"

    : > "$log"
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 \
        TMUX_FAKE_HAS_SESSION="TMUX--obs TMUX--obs--2" "$rootcopy/cctrl" @obs)"
    assert_contains "$out" "CCTRL_SESSION=TMUX--obs--3"
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--obs--3"
    # The chosen name differs from every live session — no clobber.
    assert_not_contains "$out" "CCTRL_SESSION=TMUX--obs
"
    assert_not_contains "$(cat "$log")" "new-session -d -s TMUX--obs--2 "

    # (b) normal increment — only the bare base is live → picker chooses --2.
    local incr_project="$TMPDIR/incrproj"
    mkdir -p "$incr_project"
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_AGENT=codex CCTRL_EMIT_SESSION=1 \
        TMUX_FAKE_HAS_SESSION="TMUX--incrproj" "$rootcopy/cctrl" start -d -m "incr" "$incr_project")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--incrproj--2"
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--incrproj--2"

    # (c) freed-index reuse — the bare base is live and --2 has leftover metadata
    # for a DEAD session (no live tmux). Metadata must NOT reserve the index, so
    # the picker REUSES --2 (no sprawl to --3) and the stale record is refreshed.
    local reuse_project="$TMPDIR/reuseproj"
    mkdir -p "$reuse_project" "$CCTRL_SESSION_METADATA_DIR"
    cat > "$CCTRL_SESSION_METADATA_DIR/TMUX--reuseproj--2.json" <<'JSON'
{"name":"TMUX--reuseproj--2","purpose":"stale dead session","cctrl_managed":true}
JSON
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_AGENT=codex CCTRL_EMIT_SESSION=1 \
        TMUX_FAKE_HAS_SESSION="TMUX--reuseproj" "$rootcopy/cctrl" start -d -m "fresh" "$reuse_project")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--reuseproj--2"
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--reuseproj--2"
    assert_not_contains "$out" "CCTRL_SESSION=TMUX--reuseproj--3"
    # Stale metadata was refreshed for the new session, not preserved.
    assert_contains "$(session_record_json "TMUX--reuseproj--2")" '"purpose": "reuseproj: fresh"'

    echo "ok: live-aware index picker skips live sessions, reuses freed indices"
}

test_start_defaults_to_tmux() {
    make_fake_tmux "$TMPDIR/tmux"
    local project="$TMPDIR/default-project"
    local log="$TMPDIR/default-tmux.log"
    mkdir -p "$project"

    : > "$log"
    local out
    out="$(cd "$project" && PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 "$ROOT/cctrl" start --agent codex -m "default tmux")"
    assert_contains "$out" "detached session started"
    assert_contains "$out" "CCTRL_SESSION=TMUX--default-project"
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--default-project"
    assert_contains "$(cat "$log")" "start --foreground --name TMUX--default-project"
    assert_contains "$(cat "$log")" "--agent\\ codex"
    assert_contains "$(cat "$log")" "-m default\\ tmux"

    local input_dir="$TMPDIR/agent-input-dir"
    mkdir -p "$input_dir"
    : > "$log"
    out="$(cd "$project" && PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 "$ROOT/cctrl" start --agent codex --some-agent-flag "$input_dir")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--default-project"
    assert_contains "$(cat "$log")" "SHELL_CMD=cd $project &&"
    assert_contains "$(cat "$log")" "--some-agent-flag $input_dir"
    assert_not_contains "$(cat "$log")" "new-session -d -s TMUX--agent-input-dir"
}

test_start_peer_env_and_metadata() {
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_agent "$TMPDIR/codex" codex
    make_fake_ps "$TMPDIR/ps"
    local data="$TMPDIR/start-peer-data"
    local project="$TMPDIR/start-peer-project"
    local log="$TMPDIR/start-peer-tmux.log"
    mkdir -p "$project" "$TMPDIR/comet"
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register comet --dir "$TMPDIR/comet" --agent codex >/dev/null

    local out rc
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" start --foreground --agent codex --peer comet -m "peer launch")"
    assert_contains "$out" "ENV_CCTRL_PEER=comet"

    local profile_root="$TMPDIR/cctrl-profile-peer-copy"
    local profile_data="$TMPDIR/profile-peer-data"
    local profile_meta="$TMPDIR/profile-peer-meta"
    mkdir -p "$profile_root/profiles" "$profile_root/data" "$profile_data" "$profile_meta"
    cp "$ROOT/cctrl" "$profile_root/cctrl"
    chmod +x "$profile_root/cctrl"
    printf '{"comet":{"name":"comet","aliases":["c"],"agent":"codex"}}\n' > "$profile_data/peers.json"
    cat > "$profile_root/profiles/team.json" <<JSON
{"agents":{"codex":{"env":{"CCTRL_PEER":"wrong","CCTRL_DATA_DIR":"$profile_data"}}}}
JSON
    cat > "$profile_root/profiles/team-live.json" <<JSON
{"agents":{"codex":{"env":{"CCTRL_DATA_DIR":"$profile_data","CCTRL_SESSION_METADATA_DIR":"$profile_meta"}}}}
JSON
    out="$(PATH="$TMPDIR:$PATH" "$profile_root/cctrl" start --foreground --agent codex --profile team --peer c -m "profile peer")"
    assert_contains "$out" "ENV_CCTRL_PEER=comet"
    assert_not_contains "$out" "ENV_CCTRL_PEER=wrong"
    cat > "$profile_meta/TMUX--profile-live.json" <<'JSON'
{"purpose":"profile live peer","created_at":"2026-06-11T10:00:00Z","peer":"comet","cctrl_managed":true}
JSON
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_FAKE_SESSIONS="TMUX--profile-live" "$profile_root/cctrl" start --foreground --agent codex --profile team-live --peer c -m "profile live duplicate" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected foreground profile metadata --peer duplicate to fail"
    assert_contains "$out" "already has a live tmux session"

    local profile_project="$TMPDIR/profile-detached-project"
    local profile_log="$TMPDIR/profile-detached-tmux.log"
    mkdir -p "$profile_project"
    : > "$profile_log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$profile_log" CCTRL_EMIT_SESSION=1 "$profile_root/cctrl" start -d --profile team --peer c --agent codex "$profile_project")"
    assert_contains "$out" "detached session started"
    assert_contains "$(cat "$profile_log")" "--profile\\ team"
    assert_contains "$(cat "$profile_log")" "--peer\\ comet"
    assert_contains "$(cat "$profile_log")" "CCTRL_PEER=comet"
    assert_contains "$(session_record_json "TMUX--profile-detached-project")" '"peer": "comet"'

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 CCTRL_DATA_DIR="$data" "$ROOT/cctrl" start -d --peer comet --agent codex "$project")"
    assert_contains "$out" "detached session started"
    assert_contains "$(cat "$log")" "CCTRL_PEER=comet"
    assert_contains "$(cat "$log")" "CCTRL_DATA_DIR=$data"
    assert_contains "$(cat "$log")" "CCTRL_SESSION_METADATA_DIR=$CCTRL_SESSION_METADATA_DIR"
    assert_contains "$(cat "$log")" "--peer\\ comet"
    assert_contains "$(session_record_json "TMUX--start-peer-project")" '"peer": "comet"'

    local ordered_project="$TMPDIR/start-peer-ordered-project"
    mkdir -p "$ordered_project"
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 CCTRL_DATA_DIR="$data" "$ROOT/cctrl" start --peer comet --agent codex "$ordered_project")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--start-peer-ordered-project"
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--start-peer-ordered-project"
    assert_contains "$(cat "$log")" "SHELL_CMD=cd $ordered_project &&"
    assert_contains "$(cat "$log")" "--peer\\ comet"
    assert_contains "$(session_record_json "TMUX--start-peer-ordered-project")" '"target": "'"$ordered_project"'"'

    rc=0
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" TMUX_FAKE_SESSIONS="TMUX--start-peer-project" "$ROOT/cctrl" start --foreground --agent codex --peer comet -m "duplicate foreground" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected foreground duplicate live --peer launch to fail"
    assert_contains "$out" "already has a live tmux session"

    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" CCTRL_SESSION_KIND=tmux CCTRL_SESSION_NAME=TMUX--start-peer-project TMUX_FAKE_SESSIONS="TMUX--start-peer-project" "$ROOT/cctrl" start --foreground --agent codex --peer comet -m "same tmux peer")"
    assert_contains "$out" "ENV_CCTRL_PEER=comet"

    local prompt_project="$TMPDIR/start-peer-prompt-project"
    mkdir -p "$prompt_project"
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 CCTRL_DATA_DIR="$data" CCTRL_DEVICE_TAG=peerhost "$ROOT/cctrl" start -d --peer comet --agent codex "$prompt_project" -- "do task")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--peerhost--start-peer-prompt-project"
    assert_contains "$(cat "$log")" "CCTRL_DEVICE_TAG=peerhost"
    assert_contains "$(cat "$log")" "--peer comet -- do\\ task"

    local registered_duplicate_project="$TMPDIR/start-peer-registered-duplicate-project"
    rc=0
    mkdir -p "$registered_duplicate_project"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 CCTRL_DATA_DIR="$data" TMUX_FAKE_SESSIONS="TMUX--start-peer-project" "$ROOT/cctrl" start -d --peer comet --agent codex "$registered_duplicate_project" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected registered duplicate live --peer launch to fail"
    assert_contains "$out" "already has a live tmux session"

    local manual_session_data="$TMPDIR/start-peer-manual-session-data"
    local manual_session_project="$TMPDIR/start-peer-manual-session-project"
    mkdir -p "$manual_session_project"
    CCTRL_DATA_DIR="$manual_session_data" "$ROOT/cctrl" peer register comet --agent codex --session TMUX--comet >/dev/null
    rc=0
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$manual_session_data" TMUX_FAKE_HAS_SESSION="TMUX--comet" "$ROOT/cctrl" start --foreground --agent codex --peer comet -m "manual session duplicate" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected foreground manual-session --peer launch to fail"
    assert_contains "$out" "already has a live tmux session"
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 CCTRL_DATA_DIR="$manual_session_data" TMUX_FAKE_HAS_SESSION="TMUX--comet" "$ROOT/cctrl" start -d --peer comet --agent codex "$manual_session_project" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected detached manual-session --peer launch to fail"
    assert_contains "$out" "already has a live tmux session"

    local stale_session_data="$TMPDIR/start-peer-stale-session-data"
    local stale_session_project="$TMPDIR/start-peer-stale-session-project"
    mkdir -p "$stale_session_project"
    CCTRL_DATA_DIR="$stale_session_data" "$ROOT/cctrl" peer register comet --agent codex --session TMUX--old >/dev/null
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 CCTRL_DATA_DIR="$stale_session_data" "$ROOT/cctrl" start -d --peer comet --agent codex "$stale_session_project")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--start-peer-stale-session-project"
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$stale_session_data" TMUX_FAKE_SESSIONS="TMUX--start-peer-stale-session-project" "$ROOT/cctrl" peer resolve comet --json)"
    assert_contains "$out" '"session": "TMUX--start-peer-stale-session-project"'
    assert_contains "$out" '"tmux_target": "TMUX--start-peer-stale-session-project"'
    assert_not_contains "$out" 'TMUX--old'

    local bad_meta="$TMPDIR/start-peer-bad-meta"
    local bad_meta_data="$TMPDIR/start-peer-bad-meta-data"
    local bad_meta_project="$TMPDIR/start-peer-bad-meta-project"
    mkdir -p "$bad_meta_project"
    printf 'not a directory\n' > "$bad_meta"
    : > "$log"
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 CCTRL_DATA_DIR="$bad_meta_data" CCTRL_SESSION_METADATA_DIR="$bad_meta" "$ROOT/cctrl" start -d --peer scout --agent codex "$bad_meta_project" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected --peer launch with bad metadata path to fail"
    assert_contains "$out" "Failed to write session metadata for peer 'scout'"
    assert_not_contains "$(cat "$log")" "new-session"

    local new_data="$TMPDIR/start-peer-new-data"
    local new_project="$TMPDIR/start-peer-new-project"
    mkdir -p "$new_project"
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 CCTRL_DATA_DIR="$new_data" "$ROOT/cctrl" start -d --peer rover --agent codex "$new_project")"
    assert_contains "$out" "detached session started"
    assert_contains "$out" "CCTRL_SESSION=TMUX--start-peer-new-project"
    assert_contains "$(cat "$log")" "CCTRL_PEER=rover"
    assert_contains "$(session_record_json "TMUX--start-peer-new-project")" '"peer": "rover"'

    local duplicate_project="$TMPDIR/start-peer-duplicate-project"
    rc=0
    mkdir -p "$duplicate_project"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 CCTRL_DATA_DIR="$new_data" TMUX_FAKE_SESSIONS="TMUX--start-peer-new-project" "$ROOT/cctrl" start -d --peer rover --agent codex "$duplicate_project" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected duplicate live --peer launch to fail"
    assert_contains "$out" "already has a live tmux session"
}

test_shortcut_no_args_defaults_to_tmux() {
    make_fake_tmux "$TMPDIR/tmux"
    local rootcopy="$TMPDIR/cctrl-shortcut-copy"
    local project="$TMPDIR/mstack"
    local peer_project="$TMPDIR/shortcut-peer-project"
    local peer_live_project="$TMPDIR/shortcut-peer-live-project"
    local profile_data="$TMPDIR/shortcut-profile-peer-data"
    local profile_meta="$TMPDIR/shortcut-profile-peer-meta"
    local log="$TMPDIR/shortcut-tmux.log"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$project" "$peer_project" "$peer_live_project" "$profile_data" "$profile_meta"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    printf '{"mstack":{"dir":"%s","agent":"codex"},"peerproj":{"dir":"%s","profile":"team","agent":"codex"},"peerlive":{"dir":"%s","profile":"live","agent":"codex"}}\n' "$project" "$peer_project" "$peer_live_project" > "$rootcopy/data/shortcuts.json"
    printf '{"defaultAgent":"codex"}\n' > "$rootcopy/data/config.json"
    printf '{"comet":{"name":"comet","aliases":["c"],"agent":"codex"}}\n' > "$profile_data/peers.json"
    cat > "$rootcopy/profiles/team.json" <<JSON
{"agents":{"codex":{"env":{"CCTRL_DATA_DIR":"$profile_data"}}}}
JSON
    cat > "$rootcopy/profiles/live.json" <<JSON
{"agents":{"codex":{"env":{"CCTRL_DATA_DIR":"$profile_data","CCTRL_SESSION_METADATA_DIR":"$profile_meta"}}}}
JSON

    : > "$log"
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 "$rootcopy/cctrl" @mstack)"
    assert_contains "$out" "detached session started"
    assert_contains "$out" "CCTRL_SESSION=TMUX--mstack"
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--mstack"
    assert_contains "$(cat "$log")" "@mstack --foreground --name TMUX--mstack"

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 "$rootcopy/cctrl" @peerproj --peer c)"
    assert_contains "$out" "CCTRL_SESSION=TMUX--peerproj"
    assert_contains "$(cat "$log")" "CCTRL_PEER=comet"
    assert_contains "$(cat "$log")" "--peer\\ comet"
    assert_contains "$(session_record_json "TMUX--peerproj")" '"peer": "comet"'

    cat > "$profile_meta/TMUX--shortcut-live.json" <<'JSON'
{"purpose":"shortcut live peer","created_at":"2026-06-11T10:00:00Z","peer":"comet","cctrl_managed":true}
JSON
    local rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_FAKE_SESSIONS="TMUX--shortcut-live" "$rootcopy/cctrl" @peerlive --foreground --peer c 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected shortcut foreground profile metadata --peer duplicate to fail"
    assert_contains "$out" "already has a live tmux session"
}

test_purpose_prompt_uses_controlling_tty() {
    make_fake_tmux "$TMPDIR/tmux"
    local rootcopy="$TMPDIR/cctrl-devtty-copy"
    local project="$TMPDIR/devtty-project"
    local log="$TMPDIR/devtty-tmux.log"
    local out_file="$TMPDIR/devtty-output.log"
    mkdir -p "$rootcopy/data" "$project"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    printf '{"cctrl":{"dir":"%s","agent":"codex"}}\n' "$project" > "$rootcopy/data/shortcuts.json"
    printf '{"defaultAgent":"codex"}\n' > "$rootcopy/data/config.json"

    : > "$log"
    if ! run_with_pty_input $'\n' env PATH="$TMPDIR:$PATH" TMUX_LOG="$log" \
        CCTRL_ATTACH_PROMPT=never "$rootcopy/cctrl" @cctrl \
        > "$out_file" 2>&1; then
        fail "purpose prompt pseudo-TTY invocation failed: $(cat "$out_file")"
    fi

    local out
    out="$(cat "$out_file")"
    assert_contains "$out" "Session purpose? [@cctrl]"
}

test_remote_shortcut_injects_purpose() {
    make_fake_ssh "$TMPDIR/ssh"
    local rootcopy="$TMPDIR/cctrl-remote-copy"
    local log="$TMPDIR/ssh.log"
    mkdir -p "$rootcopy/data"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    printf '{"ms":{"hostname":"example.invalid","user":"tester"}}\n' > "$rootcopy/data/hosts.json"

    : > "$log"
    PATH="$TMPDIR:$PATH" SSH_LOG="$log" CCTRL_PURPOSE_PROMPT=never \
        "$rootcopy/cctrl" --host ms @homelab --agent claude >/dev/null 2>&1

    local ssh_log
    ssh_log="$(cat "$log")"
    assert_contains "$ssh_log" "SSH -t tester@example.invalid"
    assert_contains "$ssh_log" "CCTRL_HOST_PREFIX=ms\\ cctrl\\ @homelab"
    assert_contains "$ssh_log" "--agent\\ claude"
    assert_contains "$ssh_log" "--purpose\\ @homelab"

    local remote_project="$TMPDIR/remote-peer-project"
    mkdir -p "$remote_project"
    : > "$log"
    PATH="$TMPDIR:$PATH" SSH_LOG="$log" CCTRL_PURPOSE_PROMPT=never \
        "$rootcopy/cctrl" --host ms start -d --peer comet "$remote_project" >/dev/null 2>&1 || true

    ssh_log="$(cat "$log")"
    assert_contains "$ssh_log" "--peer\\ comet"
    assert_contains "$ssh_log" "--purpose\\ remote-peer-project"
    assert_not_contains "$ssh_log" "--purpose\\ comet"
}

test_attach_prompt_after_start() {
    make_fake_tmux "$TMPDIR/tmux"
    local project="$TMPDIR/prompt-project"
    local log="$TMPDIR/prompt-tmux.log"
    mkdir -p "$project"

    : > "$log"
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_AGENT=codex CCTRL_ATTACH_PROMPT=always "$ROOT/cctrl" start -d "$project" <<< "")"
    assert_contains "$out" "Connect to session TMUX--prompt-project now? [y/N]"
    assert_contains "$out" "Not connected. Attach later: cctrl session attach TMUX--prompt-project"
    assert_not_contains "$(cat "$log")" "attach-session"

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_AGENT=codex CCTRL_ATTACH_PROMPT=always "$ROOT/cctrl" start -d "$project" <<< "y")"
    assert_contains "$out" "Connect to session TMUX--prompt-project now? [y/N]"
    assert_contains "$(cat "$log")" "attach-session -t TMUX--prompt-project"

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_AGENT=codex CCTRL_ATTACH_PROMPT=always "$ROOT/cctrl" start "$project" <<< "")"
    assert_contains "$out" "Connect to session TMUX--prompt-project now? [Y/n]"
    assert_contains "$(cat "$log")" "attach-session -t TMUX--prompt-project"
}

test_codex_statusline_tui_config() {
    local codex_home="$TMPDIR/codex-home"
    local expected='status_line = ["model-with-reasoning", "current-dir", "context-used", "git-branch", "run-state"]'
    mkdir -p "$codex_home"
    cat > "$codex_home/config.toml" <<'TOML'
model = "gpt-5.5"
status_line = ["current-dir"]

[tui.model_availability_nux]
"gpt-5.5" = 4
TOML

    local out config
    out="$(CODEX_HOME="$codex_home" "$ROOT/cctrl" statusline codex install)"
    assert_contains "$out" "Installed Codex statusline"

    config="$(cat "$codex_home/config.toml")"
    assert_contains "$config" "$expected"
    assert_contains "$config" '[tui]'
    assert_contains "$config" '[tui.model_availability_nux]'
    assert_not_contains "$config" $'\nstatus_line = ["current-dir"]\n'

    out="$(CODEX_HOME="$codex_home" "$ROOT/cctrl" statusline codex show)"
    assert_contains "$out" "$expected"
}

test_context_names() {
    make_fake_agent "$TMPDIR/claude" claude
    local project="$TMPDIR/context project"
    mkdir -p "$project"

    local out
    out="$(cd "$project" && PATH="$TMPDIR:$PATH" CCTRL_HOST_PREFIX=ms CCTRL_TMUX_CONTEXT=1 "$ROOT/cctrl" start --agent claude -m "bridge prompt")"
    assert_contains "$out" "CMD=claude"
    assert_contains "$out" "--remote-control"
    assert_contains "$out" "--remote-control-session-name-prefix"
    assert_contains "$out" "TMUX--ms--context-project-"
}

test_bridge_prefix_matches_explicit_name() {
    # Name reconciliation: when an explicit --name is passed (as every detached
    # tmux launch does), the remote-control prefix must derive from that name,
    # NOT from the cwd/repo slug — so the Claude Code app session matches tmux.
    make_fake_agent "$TMPDIR/claude" claude
    local project="$TMPDIR/unstructured-data-portal"
    mkdir -p "$project"

    local out
    out="$(cd "$project" && PATH="$TMPDIR:$PATH" CCTRL_HOST_PREFIX=ms CCTRL_TMUX_CONTEXT=1 "$ROOT/cctrl" start --agent claude --name TMUX--ms--portal -m "hi")"
    assert_contains "$out" "--remote-control-session-name-prefix"
    assert_contains "$out" "TMUX--ms--portal-"
    # The old cwd-derived prefix must NOT appear.
    assert_not_contains "$out" "TMUX--ms--unstructured-data-portal-"
}

test_dir_launch_adopts_shortcut_alias() {
    # Plan 012: `cctrl start -d <dir>` where <dir> matches a configured shortcut
    # must name the session from the shortcut's short alias — identically to
    # `cctrl start -d @<key>` — so both launch paths yield the same
    # TMUX--<device>--<alias> name AND the same remote-control prefix (name ==
    # prefix, per fa2af76). On collision the first shortcut by sorted key wins.
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_agent "$TMPDIR/claude" claude

    local rootcopy="$TMPDIR/cctrl-alias-copy"
    # Basename differs from the alias so the two naming conventions are distinct.
    local project="$TMPDIR/unstructured-data-portal"
    local dlog="$TMPDIR/alias-dir.log"
    local slog="$TMPDIR/alias-shortcut.log"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$project"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    mkdir -p "$rootcopy/lib"
    cp "$ROOT/lib/session-wrapper.sh" "$rootcopy/lib/session-wrapper.sh"
    chmod +x "$rootcopy/cctrl"
    chmod +x "$rootcopy/lib/session-wrapper.sh"
    printf '{"portal":{"dir":"%s","agent":"codex"}}\n' "$project" > "$rootcopy/data/shortcuts.json"
    printf '{"defaultAgent":"codex"}\n' > "$rootcopy/data/config.json"

    # (a) dir launch adopts the alias — names TMUX--ms--portal, not
    # TMUX--ms--unstructured-data-portal.
    : > "$dlog"
    local dout
    dout="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$dlog" CCTRL_HOST_PREFIX=ms CCTRL_EMIT_SESSION=1 \
        "$rootcopy/cctrl" start -d --agent codex --purpose p "$project")"
    assert_contains "$dout" "CCTRL_SESSION=TMUX--ms--portal"
    assert_contains "$(cat "$dlog")" "new-session -d -s TMUX--ms--portal"
    assert_contains "$(cat "$dlog")" "--name TMUX--ms--portal"
    assert_not_contains "$(cat "$dlog")" "TMUX--ms--unstructured-data-portal"

    # (b) shortcut launch of the same repo — must match exactly.
    : > "$slog"
    local sout
    sout="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$slog" CCTRL_HOST_PREFIX=ms CCTRL_EMIT_SESSION=1 \
        "$rootcopy/cctrl" start -d --purpose p @portal)"
    assert_contains "$sout" "CCTRL_SESSION=TMUX--ms--portal"
    assert_contains "$(cat "$slog")" "new-session -d -s TMUX--ms--portal"
    assert_contains "$(cat "$slog")" "--name TMUX--ms--portal"

    # Same session name from both launch paths.
    local dname sname
    dname="$(grep -oE -- '--name TMUX--[^ ]+' "$dlog" | head -1)"
    sname="$(grep -oE -- '--name TMUX--[^ ]+' "$slog" | head -1)"
    [[ -n "$dname" && "$dname" == "$sname" ]] || \
        fail "dir-launch name ($dname) must equal shortcut-launch name ($sname)"

    # Same remote-control prefix: both --name values flow through to the bridge
    # prefix (prefix == name-). Drive the foreground child the detached launch
    # would spawn and capture the real --remote-control-session-name-prefix.
    local dpfx spfx
    dpfx="$(cd "$project" && PATH="$TMPDIR:$PATH" CCTRL_HOST_PREFIX=ms CCTRL_TMUX_CONTEXT=1 \
        CCTRL_SESSION_KIND=tmux CCTRL_SESSION_NAME=TMUX--ms--portal \
        "$rootcopy/cctrl" start --foreground --agent claude --name TMUX--ms--portal -m hi 2>&1)"
    spfx="$(PATH="$TMPDIR:$PATH" CCTRL_HOST_PREFIX=ms CCTRL_TMUX_CONTEXT=1 \
        CCTRL_SESSION_KIND=tmux CCTRL_SESSION_NAME=TMUX--ms--portal \
        "$rootcopy/cctrl" @portal --foreground --agent claude --name TMUX--ms--portal -m hi 2>&1)"
    assert_contains "$dpfx" "TMUX--ms--portal-"
    assert_contains "$spfx" "TMUX--ms--portal-"
    assert_not_contains "$dpfx" "TMUX--ms--unstructured-data-portal-"

    echo "ok: dir launch adopts matching shortcut alias (same name + bridge prefix as @shortcut)"
}

test_dir_launch_shortcut_collision_deterministic() {
    # Plan 012: when two shortcuts point at the same directory, the reverse
    # lookup is deterministic — the first key by sorted order wins.
    make_fake_tmux "$TMPDIR/tmux"

    local rootcopy="$TMPDIR/cctrl-collision-copy"
    local project="$TMPDIR/collision-project"
    local log="$TMPDIR/collision.log"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$project"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    # Insertion order zzz-before-aaa; sorted order must pick "aaa".
    printf '{"zzz":{"dir":"%s"},"aaa":{"dir":"%s"}}\n' "$project" "$project" > "$rootcopy/data/shortcuts.json"
    printf '{"defaultAgent":"codex"}\n' > "$rootcopy/data/config.json"

    : > "$log"
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_HOST_PREFIX=ms CCTRL_EMIT_SESSION=1 \
        "$rootcopy/cctrl" start -d --agent codex --purpose p "$project")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--aaa"
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--ms--aaa"
    assert_not_contains "$(cat "$log")" "TMUX--ms--zzz"

    echo "ok: dir-launch shortcut collision resolves to first sorted key"
}

test_dir_launch_no_shortcut_match_unchanged() {
    # Plan 012: a directory with no matching shortcut keeps the repo-dir slug —
    # behavior is unchanged.
    make_fake_tmux "$TMPDIR/tmux"

    local rootcopy="$TMPDIR/cctrl-nomatch-copy"
    local project="$TMPDIR/lonely-project"
    local other="$TMPDIR/some-other-repo"
    local log="$TMPDIR/nomatch.log"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$project" "$other"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    # A shortcut exists, but points elsewhere.
    printf '{"portal":{"dir":"%s"}}\n' "$other" > "$rootcopy/data/shortcuts.json"
    printf '{"defaultAgent":"codex"}\n' > "$rootcopy/data/config.json"

    : > "$log"
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_HOST_PREFIX=ms CCTRL_EMIT_SESSION=1 \
        "$rootcopy/cctrl" start -d --agent codex --purpose p "$project")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--lonely-project"
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--ms--lonely-project"
    assert_contains "$(cat "$log")" "--name TMUX--ms--lonely-project"

    echo "ok: dir launch with no matching shortcut keeps the repo-dir slug"
}

test_session_doctor_classifies_bridge() {
    # session doctor reads bridgeSessionId from the Claude session file to decide
    # live vs dead, and flags app/tmux name-prefix mismatches.
    local bin="$TMPDIR/doctorbin" sdir="$TMPDIR/claude-sessions"
    mkdir -p "$bin" "$sdir"
    make_fake_tmux "$bin/tmux"

    # live + name-aligned
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *4242* ]]; then
    echo "claude --name TMUX--ms--portal --remote-control --remote-control-session-name-prefix TMUX--ms--portal-"
    exit 0
fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    cat > "$sdir/4242.json" <<'JSON'
{"pid":4242,"name":"TMUX--ms--portal","status":"idle","bridgeSessionId":"session_live123"}
JSON

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session doctor --json)"
    assert_contains "$out" '"session": "TMUX--ms--portal"'
    assert_contains "$out" '"remote_control": "live"'
    assert_contains "$out" '"bridge": "session_live123"'
    assert_contains "$out" '"name_aligned": true'

    # dead (no bridgeSessionId) + name mismatch (old cwd-derived prefix)
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *4242* ]]; then
    echo "claude --name TMUX--ms--portal --remote-control --remote-control-session-name-prefix TMUX--ms--unstructured-data-portal-"
    exit 0
fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    cat > "$sdir/4242.json" <<'JSON'
{"pid":4242,"name":"TMUX--ms--portal","status":"idle"}
JSON
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session doctor --json)"
    assert_contains "$out" '"remote_control": "dead"'
    assert_contains "$out" '"name_aligned": false'
}

test_session_doctor_detects_collision() {
    # Two sessions reporting the same bridgeSessionId = a bridge collision from a
    # shared name prefix. Both read "live" individually; only cross-checking ids
    # reveals it.
    local bin="$TMPDIR/colbin" sdir="$TMPDIR/col-sessions"
    mkdir -p "$bin" "$sdir"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *4242* ]]; then
    echo "claude --remote-control --remote-control-session-name-prefix TMUX--ms--homelab-"
    exit 0
fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    cat > "$sdir/4242.json" <<'JSON'
{"pid":4242,"status":"idle","bridgeSessionId":"session_shared"}
JSON
    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" TMUX_FAKE_SESSIONS="TMUX--ms--homelab--3 TMUX--ms--homelab--5" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session doctor --json)"
    assert_contains "$out" '"remote_control": "collision"'
}

test_session_doctor_quarantines_orphan_codex_writer_lock() {
    # Codex can leave behind an empty thread-writer-lock for a thread id that has
    # no app DB row and no rollout JSONL. That lock makes the app think a task is
    # owned/open, but resume fails with "no rollout found". Doctor should report
    # and, under --fix --yes, quarantine only that orphan.
    local bin="$TMPDIR/orphanbin" codex_home="$TMPDIR/orphan-codex" backup="$TMPDIR/orphan-backup"
    mkdir -p "$bin" "$codex_home/thread-writer-locks" "$codex_home/sessions/2026/08/25" "$backup"
    make_fake_tmux "$bin/tmux"
    : > "$codex_home/thread-writer-locks/orphan-thread.lock"
    : > "$codex_home/thread-writer-locks/db-thread.lock"
    : > "$codex_home/thread-writer-locks/rollout-thread.lock"
    : > "$codex_home/sessions/2026/08/25/rollout-2026-08-25T10-00-00-rollout-thread.jsonl"
    python3 - "$codex_home/state_5.sqlite" <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT)")
con.execute("INSERT INTO threads (id, title) VALUES (?, ?)", ("db-thread", "Backed by DB"))
con.commit()
PY

    local out
    out="$(PATH="$bin:$PATH" CODEX_HOME="$codex_home" CCTRL_CODEX_LOCK_BACKUP_DIR="$backup" "$ROOT/cctrl" session doctor --json)"
    printf '%s\n' "$out" | jq -e '
      (map(select(.type == "codex_writer_lock" and .thread_id == "orphan-thread" and .status == "orphan" and .action == null)) | length) == 1
      and (map(select(.thread_id == "db-thread" or .thread_id == "rollout-thread")) | length) == 0
    ' >/dev/null || fail "expected doctor to report only the orphan Codex writer lock"
    [[ -e "$codex_home/thread-writer-locks/orphan-thread.lock" ]] || fail "report-only doctor must not move orphan lock"

    out="$(PATH="$bin:$PATH" CODEX_HOME="$codex_home" CCTRL_CODEX_LOCK_BACKUP_DIR="$backup" "$ROOT/cctrl" session doctor --fix --yes --json)"
    printf '%s\n' "$out" | jq -e '
      (map(select(.type == "codex_writer_lock" and .thread_id == "orphan-thread" and .action == "quarantined")) | length) == 1
    ' >/dev/null || fail "expected doctor --fix --yes to quarantine orphan Codex writer lock"
    [[ ! -e "$codex_home/thread-writer-locks/orphan-thread.lock" ]] || fail "orphan lock stayed in live lock dir"
    [[ -e "$backup/orphan-thread.lock" ]] || fail "orphan lock was not moved to backup"
    [[ -e "$codex_home/thread-writer-locks/db-thread.lock" ]] || fail "DB-backed lock must be kept"
    [[ -e "$codex_home/thread-writer-locks/rollout-thread.lock" ]] || fail "rollout-backed lock must be kept"

    echo "ok: session doctor quarantines only orphan Codex writer locks"
}

# --- plan 018: guided-relaunch realign of app/tmux name mismatches ---------
# Shared fabricator: a mismatched claude session whose tmux name is
# TMUX--ms--portal but whose app-name prefix is the old cwd-derived slug, with a
# plan-013 sessionId and metadata pointing at a real target dir so the guided
# relaunch can be built. The realign relaunch path is stubbed via
# CCTRL_DOCTOR_RELAUNCH_LOG so no real session is ever killed or launched.
_doctor_realign_fixture() {
    # args: bindir sessdir prefix status
    local bin="$1" sdir="$2" prefix="$3" status="$4"
    mkdir -p "$bin" "$sdir" "$CCTRL_SESSION_METADATA_DIR" "$TMPDIR/rl-proj"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<SH
#!/usr/bin/env bash
if [[ "\$*" == *4242* ]]; then
    echo "claude --name TMUX--ms--portal --remote-control --remote-control-session-name-prefix ${prefix}"
    exit 0
fi
exec /bin/ps "\$@"
SH
    chmod +x "$bin/ps"
    cat > "$sdir/4242.json" <<JSON
{"pid":4242,"name":"TMUX--ms--portal","status":"${status}","sessionId":"sess_uuid_1","bridgeSessionId":"session_live1"}
JSON
    cat > "$CCTRL_SESSION_METADATA_DIR/TMUX--ms--portal.json" <<JSON
{"target":"$TMPDIR/rl-proj","cwd":"$TMPDIR/rl-proj","purpose":"realign me"}
JSON
}

test_session_doctor_realign_reports_hint() {
    # Report-only (no --fix): a MISMATCH is flagged AND carries a copy-pasteable
    # relaunch hint with --resume <sessionId> and the corrected --name. Nothing
    # is mutated or relaunched.
    local bin="$TMPDIR/rl1bin" sdir="$TMPDIR/rl1-sessions"
    _doctor_realign_fixture "$bin" "$sdir" "TMUX--ms--unstructured-data-portal-" "idle"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session doctor --json)"
    assert_contains "$out" '"name_aligned": false'
    assert_contains "$out" '"realign_hint"'
    assert_contains "$out" '--resume sess_uuid_1'
    assert_contains "$out" '--name TMUX--ms--portal'
    # Report-only must never record an action.
    assert_contains "$out" '"action": null'
}

test_session_doctor_realign_fix_emits_relaunch() {
    # --fix --yes on a MISMATCH emits the correct guided-relaunch command
    # (carrying --resume <sessionId> and the corrected --name) and flips the
    # session to aligned. The relaunch is captured, not executed.
    local bin="$TMPDIR/rl2bin" sdir="$TMPDIR/rl2-sessions" relog="$TMPDIR/rl2-relaunch.log"
    _doctor_realign_fixture "$bin" "$sdir" "TMUX--ms--unstructured-data-portal-" "idle"
    : > "$relog"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_DOCTOR_RELAUNCH_LOG="$relog" TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session doctor --fix --yes --json)"
    assert_contains "$out" '"action": "realigned'
    assert_contains "$out" '"name_aligned": true'

    local cmd
    cmd="$(cat "$relog")"
    assert_contains "$cmd" 'cctrl start -d'
    assert_contains "$cmd" '--resume sess_uuid_1'
    assert_contains "$cmd" '--name TMUX--ms--portal'
}

test_session_doctor_realign_skips_busy() {
    # A BUSY MISMATCH session is never relaunched mid-work.
    local bin="$TMPDIR/rl3bin" sdir="$TMPDIR/rl3-sessions" relog="$TMPDIR/rl3-relaunch.log"
    _doctor_realign_fixture "$bin" "$sdir" "TMUX--ms--unstructured-data-portal-" "busy"
    : > "$relog"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_DOCTOR_RELAUNCH_LOG="$relog" TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session doctor --fix --yes --json)"
    assert_contains "$out" '"action": "skipped-busy"'
    assert_contains "$out" '"name_aligned": false'
    [[ ! -s "$relog" ]] || fail "busy MISMATCH session must not emit a relaunch"
}

test_session_doctor_realign_idempotent() {
    # Second --fix on an already-aligned fleet: no relaunch, no action.
    local bin="$TMPDIR/rl4bin" sdir="$TMPDIR/rl4-sessions" relog="$TMPDIR/rl4-relaunch.log"
    _doctor_realign_fixture "$bin" "$sdir" "TMUX--ms--portal-" "idle"
    : > "$relog"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_DOCTOR_RELAUNCH_LOG="$relog" TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session doctor --fix --yes --json)"
    assert_contains "$out" '"name_aligned": true'
    assert_contains "$out" '"action": null'
    assert_contains "$out" '"realign_hint": null'
    [[ ! -s "$relog" ]] || fail "aligned fleet must not relaunch"
}

test_session_doctor_realign_real_relaunch() {
    # End-to-end (no capture seam): --fix --yes actually routes the realign
    # through the detached-launch path (plan 017 picker + fake tmux), so nothing
    # real is killed but the emitted tmux new-session carries the corrected name
    # and --resume. The target dir slug (host=ms, basename=portal) equals the
    # tmux name TMUX--ms--portal, so the relaunch reproduces that exact aligned
    # name with app-prefix TMUX--ms--portal-.
    local bin="$TMPDIR/rl5bin" sdir="$TMPDIR/rl5-sessions" log="$TMPDIR/rl5-tmux.log"
    local proj="$TMPDIR/portal"
    mkdir -p "$bin" "$sdir" "$CCTRL_SESSION_METADATA_DIR" "$proj"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *4242* ]]; then
    echo "claude --name TMUX--ms--portal --remote-control --remote-control-session-name-prefix TMUX--ms--unstructured-data-portal-"
    exit 0
fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    cat > "$sdir/4242.json" <<'JSON'
{"pid":4242,"name":"TMUX--ms--portal","status":"idle","sessionId":"sess_uuid_1","bridgeSessionId":"session_live1"}
JSON
    cat > "$CCTRL_SESSION_METADATA_DIR/TMUX--ms--portal.json" <<JSON
{"target":"$proj","cwd":"$proj","purpose":"realign me"}
JSON

    : > "$log"
    local out
    out="$(PATH="$bin:$PATH" TMUX_LOG="$log" CCTRL_HOST_PREFIX=ms CCTRL_TMUX_CONTEXT=1 CCTRL_CLAUDE_SESSIONS_DIR="$sdir" TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session doctor --fix --yes --json)"
    assert_contains "$out" '"action": "realigned'

    # The real detached-launch fired through the picker with the corrected name.
    local tmuxlog
    tmuxlog="$(cat "$log")"
    assert_contains "$tmuxlog" "new-session -d -s TMUX--ms--portal"
    assert_contains "$tmuxlog" "--name TMUX--ms--portal"
    assert_contains "$tmuxlog" "--resume sess_uuid_1"
    # It relaunches as claude (only claude carries the app-name prefix).
    assert_contains "$tmuxlog" "--agent claude"
}

# --- plan 021: opt-in autoheal of DEAD remote-control bridges ---------------
# All autoheal tests stub the repair path (CCTRL_AUTOHEAL_REPAIR_LOG captures
# whether a repair fired, instead of injecting real keystrokes) and stub
# launchctl + the LaunchAgents dir (CCTRL_LAUNCH_AGENTS_DIR), so no real bridge,
# keystroke, or system agent is ever touched.
_autoheal_fixture() {
    # args: bindir sessdir status  -> a DEAD-bridge claude session (argv carries
    # --remote-control but the session file has no bridgeSessionId), named
    # TMUX--ms--portal and backed by pane pid 4242. Also drops a launchctl stub.
    local bin="$1" sdir="$2" status="$3"
    mkdir -p "$bin" "$sdir"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *4242* ]]; then
    echo "claude --name TMUX--ms--portal --remote-control --remote-control-session-name-prefix TMUX--ms--portal-"
    exit 0
fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    cat > "$sdir/4242.json" <<JSON
{"pid":4242,"name":"TMUX--ms--portal","status":"${status}"}
JSON
    cat > "$bin/launchctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$bin/launchctl"
}

test_session_autoheal_dry_run_selects_dead_and_no_repair() {
    # --dry-run selects the dead bridge (reports would-heal) but fires NO repair
    # and writes NO heal log: it acts on nothing.
    local bin="$TMPDIR/ah-dry-bin" sdir="$TMPDIR/ah-dry-sessions"
    local rlog="$TMPDIR/ah-dry-repair.log" hlog="$TMPDIR/ah-dry-heal.log"
    _autoheal_fixture "$bin" "$sdir" "idle"
    : > "$rlog"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 \
        TMUX_FAKE_CAPTURE_PANE='⏺ Done. Ready for next task.' \
        CCTRL_AUTOHEAL_LOG="$hlog" CCTRL_AUTOHEAL_REPAIR_LOG="$rlog" \
        "$ROOT/cctrl" session autoheal --dry-run --json)"
    assert_contains "$out" '"session": "TMUX--ms--portal"'
    assert_contains "$out" '"remote_control": "dead"'
    assert_contains "$out" '"action": "would-heal"'
    # No repair fired and no heal log written — dry-run acts on none.
    [[ -s "$rlog" ]] && fail "dry-run must NOT fire a repair (repair log non-empty)"
    [[ -e "$hlog" ]] && fail "dry-run must NOT write the heal log"
    echo "ok: autoheal --dry-run selects dead bridge, fires no repair"
}

test_session_autoheal_skips_unsent_draft() {
    # SAFETY GATE: a dead bridge whose input line holds an unsent draft is
    # SKIPPED (never repaired) — /rc begins with C-u, which would erase the draft.
    local bin="$TMPDIR/ah-draft-bin" sdir="$TMPDIR/ah-draft-sessions"
    local rlog="$TMPDIR/ah-draft-repair.log" hlog="$TMPDIR/ah-draft-heal.log"
    _autoheal_fixture "$bin" "$sdir" "idle"
    : > "$rlog"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 \
        TMUX_FAKE_CAPTURE_PANE='> explain the autoheal plan in detail' \
        CCTRL_AUTOHEAL_LOG="$hlog" CCTRL_AUTOHEAL_REPAIR_LOG="$rlog" \
        "$ROOT/cctrl" session autoheal --json)"
    assert_contains "$out" '"action": "skipped"'
    assert_contains "$out" '"reason": "unsent-draft"'
    # The repair must NOT have fired, and the skip is logged.
    [[ -s "$rlog" ]] && fail "unsent-draft session must NOT be repaired (repair log non-empty)"
    assert_contains "$(cat "$hlog")" "skipped TMUX--ms--portal (unsent-draft)"
    echo "ok: autoheal skips (never repairs) a dead bridge with an unsent draft"
}

test_session_autoheal_skips_busy() {
    # A busy dead-bridge session is skipped — never inject into a working agent.
    local bin="$TMPDIR/ah-busy-bin" sdir="$TMPDIR/ah-busy-sessions"
    local rlog="$TMPDIR/ah-busy-repair.log" hlog="$TMPDIR/ah-busy-heal.log"
    _autoheal_fixture "$bin" "$sdir" "busy"
    : > "$rlog"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 \
        TMUX_FAKE_CAPTURE_PANE='⏺ working...' \
        CCTRL_AUTOHEAL_LOG="$hlog" CCTRL_AUTOHEAL_REPAIR_LOG="$rlog" \
        "$ROOT/cctrl" session autoheal --json)"
    assert_contains "$out" '"reason": "busy"'
    [[ -s "$rlog" ]] && fail "busy session must NOT be repaired"
    echo "ok: autoheal skips a busy dead bridge"
}

test_session_autoheal_skips_copy_mode() {
    # A dead-bridge session in copy-mode is skipped — keystrokes are swallowed.
    local bin="$TMPDIR/ah-copy-bin" sdir="$TMPDIR/ah-copy-sessions"
    local rlog="$TMPDIR/ah-copy-repair.log" hlog="$TMPDIR/ah-copy-heal.log"
    _autoheal_fixture "$bin" "$sdir" "idle"
    : > "$rlog"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 \
        TMUX_FAKE_PANE_IN_MODE=1 TMUX_FAKE_CAPTURE_PANE='⏺ Done.' \
        CCTRL_AUTOHEAL_LOG="$hlog" CCTRL_AUTOHEAL_REPAIR_LOG="$rlog" \
        "$ROOT/cctrl" session autoheal --json)"
    assert_contains "$out" '"reason": "copy-mode"'
    [[ -s "$rlog" ]] && fail "copy-mode session must NOT be repaired"
    echo "ok: autoheal skips a copy-mode dead bridge"
}

test_session_autoheal_heals_clean_dead_bridge() {
    # A dead bridge that passes every gate (idle, not copy-mode, empty input) is
    # healed via the (stubbed) repair path, and the action is logged.
    local bin="$TMPDIR/ah-heal-bin" sdir="$TMPDIR/ah-heal-sessions"
    local rlog="$TMPDIR/ah-heal-repair.log" hlog="$TMPDIR/ah-heal-heal.log"
    _autoheal_fixture "$bin" "$sdir" "idle"
    : > "$rlog"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 \
        TMUX_FAKE_CAPTURE_PANE='⏺ Done. Ready for next task.' \
        CCTRL_AUTOHEAL_LOG="$hlog" CCTRL_AUTOHEAL_REPAIR_LOG="$rlog" \
        "$ROOT/cctrl" session autoheal --json)"
    assert_contains "$out" '"action": "healed"'
    # The repair fired (session name captured in the stub log) and was logged.
    assert_contains "$(cat "$rlog")" "TMUX--ms--portal"
    assert_contains "$(cat "$hlog")" "healed TMUX--ms--portal"
    echo "ok: autoheal repairs a clean dead bridge and logs it"
}

test_session_autoheal_ignores_live_bridge() {
    # Only DEAD bridges are touched: a live bridge is never selected or repaired
    # (idempotency — re-running over healthy sessions is a no-op).
    local bin="$TMPDIR/ah-live-bin" sdir="$TMPDIR/ah-live-sessions"
    local rlog="$TMPDIR/ah-live-repair.log" hlog="$TMPDIR/ah-live-heal.log"
    _autoheal_fixture "$bin" "$sdir" "idle"
    # Promote to a live bridge.
    cat > "$sdir/4242.json" <<'JSON'
{"pid":4242,"name":"TMUX--ms--portal","status":"idle","bridgeSessionId":"session_live999"}
JSON
    : > "$rlog"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 \
        TMUX_FAKE_CAPTURE_PANE='⏺ Done.' \
        CCTRL_AUTOHEAL_LOG="$hlog" CCTRL_AUTOHEAL_REPAIR_LOG="$rlog" \
        "$ROOT/cctrl" session autoheal --json)"
    # No dead bridges -> empty selection, no repair.
    [[ "$out" == "[]" ]] || fail "live bridge must not be selected (got: $out)"
    [[ -s "$rlog" ]] && fail "live bridge must NOT be repaired"
    echo "ok: autoheal never touches a live bridge"
}

test_session_autoheal_install_uninstall_plist() {
    # install writes a launchd plist to the (test-overridable) LaunchAgents dir;
    # uninstall removes it. launchctl is stubbed, so no real agent is loaded.
    local bin="$TMPDIR/ah-inst-bin" pdir="$TMPDIR/ah-launch-agents"
    local hlog="$TMPDIR/ah-inst-heal.log"
    local plist="$pdir/com.cctrl.session-autoheal.plist"
    mkdir -p "$bin"
    cat > "$bin/launchctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$bin/launchctl"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_LAUNCH_AGENTS_DIR="$pdir" CCTRL_AUTOHEAL_LOG="$hlog" \
        "$ROOT/cctrl" session autoheal install --interval 600)"
    [[ -f "$plist" ]] || fail "install must write the plist to $plist"
    local plist_body
    plist_body="$(cat "$plist")"
    assert_contains "$plist_body" "<string>session</string>"
    assert_contains "$plist_body" "<string>autoheal</string>"
    assert_contains "$plist_body" "<integer>600</integer>"
    assert_contains "$plist_body" "com.cctrl.session-autoheal"

    out="$(PATH="$bin:$PATH" CCTRL_LAUNCH_AGENTS_DIR="$pdir" CCTRL_AUTOHEAL_LOG="$hlog" \
        "$ROOT/cctrl" session autoheal uninstall)"
    [[ -e "$plist" ]] && fail "uninstall must remove the plist"
    assert_contains "$out" "Uninstalled autoheal timer"
    echo "ok: autoheal install writes plist to test dir; uninstall removes it"
}

test_session_list_codex_default_model() {
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_ps "$TMPDIR/ps"
    mkdir -p "$CCTRL_SESSION_METADATA_DIR"
    cat > "$CCTRL_SESSION_METADATA_DIR/demo.json" <<'JSON'
{"purpose":"review stale session cleanup","created_at":"2026-06-11T10:00:00Z"}
JSON

    local out
    out="$(PATH="$TMPDIR:$PATH" "$ROOT/cctrl" session ls --json)"
    assert_contains "$out" '"name": "demo"'
    assert_contains "$out" '"agent": "codex"'
    assert_contains "$out" '"model": "?"'
    assert_contains "$out" '"purpose": "review stale session cleanup"'
    assert_contains "$out" '"created_at": "2026-06-11T10:00:00Z"'
}

test_session_list_agent_not_mislabelled_by_prompt() {
    # Regression (plan 031): a Claude session whose seed prompt mentions "codex"
    # or a ~/.codex path must still classify as claude. The old whole-argv
    # substring test tagged it codex, which then selected the Codex
    # modal-detection regex at delivery and pasted into an open Claude modal.
    # Detection now keys on argv[0]'s basename, not the trailing prompt text.
    local bin="$TMPDIR/agbin"
    mkdir -p "$bin"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *7777* ]]; then
    echo "claude --model claude-opus-4-8[1m] -m DEFECT 2 AGENT MISLABELED AS codex see ~/.codex/config.toml"
    exit 0
fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    local out
    out="$(PATH="$bin:$PATH" TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_PANE_PID=7777 "$ROOT/cctrl" session ls --json)"
    assert_contains "$out" '"agent": "claude"'
    assert_not_contains "$out" '"agent": "codex"'
    assert_contains "$out" '"model": "opus-4-8"'
    echo "ok: claude session with 'codex' in its prompt is not mislabelled codex"
}

test_session_list_agent_prefers_recorded_metadata() {
    # Plan 031: when session metadata records the agent (written at spawn from
    # the explicit --agent flag), the display prefers it over the pane sniff.
    local bin="$TMPDIR/agmetabin"
    mkdir -p "$bin"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *8888* ]]; then echo "claude --model claude-opus-4-8[1m]"; exit 0; fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    mkdir -p "$CCTRL_SESSION_METADATA_DIR"
    cat > "$CCTRL_SESSION_METADATA_DIR/TMUX--metademo.json" <<'JSON'
{"name":"TMUX--metademo","agent":"claude","created_at":"2026-07-20T10:00:00Z","cctrl_managed":true}
JSON
    local out
    out="$(PATH="$bin:$PATH" TMUX_FAKE_SESSIONS="TMUX--metademo" TMUX_FAKE_PANE_PID=8888 "$ROOT/cctrl" session ls --json)"
    assert_contains "$out" '"agent": "claude"'
    echo "ok: session ls prefers the agent recorded in metadata"
}

test_session_list_malformed_metadata_uses_unknown_defaults() {
    # A malformed record must not make an otherwise-live tmux session vanish
    # from JSON output or feed empty strings to jq --argjson.
    local bin="$TMPDIR/agbadmetabin" meta="$TMPDIR/agbadmeta"
    mkdir -p "$bin" "$meta"
    make_fake_tmux "$bin/tmux"
    make_fake_ps "$bin/ps"
    printf 'not json {{{\n' > "$meta/TMUX--badmeta.json"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_SESSIONS="TMUX--badmeta" TMUX_FAKE_PANE_PID=8888 \
        "$ROOT/cctrl" session ls --json)"
    assert_contains "$out" '"name": "TMUX--badmeta"'
    assert_contains "$out" '"execution_runtime": "unknown"'
    assert_contains "$out" '"control_owner": "unknown"'
    echo "ok: session ls preserves live sessions when metadata is malformed"
}

test_session_list_last_active_from_updated_at() {
    # A claude session whose per-pid file carries sessionId + updatedAt reports
    # both session_id and last_active (ISO-8601 derived from updatedAt epoch-ms).
    local bin="$TMPDIR/labin" sdir="$TMPDIR/la-sessions" pdir="$TMPDIR/la-projects"
    mkdir -p "$bin" "$sdir" "$pdir"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *5555* ]]; then echo "claude --remote-control"; exit 0; fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    cat > "$sdir/5555.json" <<'JSON'
{"pid":5555,"sessionId":"abc-123-uuid","updatedAt":1700000000000,"bridgeSessionId":"session_live"}
JSON

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_PANE_PID=5555 "$ROOT/cctrl" session ls --json)"
    assert_contains "$out" '"session_id": "abc-123-uuid"'
    assert_contains "$out" '"last_active": "2023-11-14T22:13:20Z"'
    echo "ok: session ls --json exposes session_id + last_active"
}

test_session_list_last_active_from_transcript_mtime() {
    # No updatedAt in the per-pid file: last_active falls back to the transcript
    # file's mtime (resolved by globbing the sessionId across project dirs).
    local bin="$TMPDIR/mtbin" sdir="$TMPDIR/mt-sessions" pdir="$TMPDIR/mt-projects"
    mkdir -p "$bin" "$sdir" "$pdir/some-proj"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *6666* ]]; then echo "claude"; exit 0; fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    cat > "$sdir/6666.json" <<'JSON'
{"pid":6666,"sessionId":"mtime-uuid-999"}
JSON
    local tfile="$pdir/some-proj/mtime-uuid-999.jsonl"
    : > "$tfile"
    touch -t 202306301200.00 "$tfile"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        TMUX_FAKE_SESSIONS="TMUX--mt" TMUX_FAKE_PANE_PID=6666 "$ROOT/cctrl" session ls --json)"
    assert_contains "$out" '"session_id": "mtime-uuid-999"'
    assert_contains "$out" 'mtime-uuid-999.jsonl'
    # updatedAt absent, but mtime fallback resolves -> last_active is not null.
    assert_not_contains "$out" '"last_active": null'
}

test_session_list_unresolvable_session() {
    # A session with no per-pid Claude file still lists, with null session_id /
    # last_active, and never errors.
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_ps "$TMPDIR/ps"
    local out rc=0
    out="$(PATH="$TMPDIR:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$TMPDIR/empty-sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$TMPDIR/empty-projects" \
        TMUX_FAKE_SESSIONS="TMUX--unresolved" "$ROOT/cctrl" session ls --json)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "session ls must not error on an unresolvable session"
    assert_contains "$out" '"name": "TMUX--unresolved"'
    assert_contains "$out" '"session_id": null'
    assert_contains "$out" '"last_active": null'
}

test_session_list_sorts_by_last_active() {
    # Rows sort most-recently-active first; unknown last_active sorts last.
    local bin="$TMPDIR/sortbin" sdir="$TMPDIR/sort-sessions" pdir="$TMPDIR/sort-projects"
    mkdir -p "$bin" "$sdir" "$pdir"
    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
target=""
for ((i=1;i<=$#;i++)); do
    if [[ "${!i}" == "-t" ]]; then j=$((i+1)); target="${!j:-}"; break; fi
done
case "${1:-}" in
    list-sessions) for s in $TMUX_FAKE_SESSIONS; do printf '%s\n' "$s"; done; exit 0;;
    list-panes)
        if [[ "$*" == *pane_current_path* ]]; then echo /tmp/demo; exit 0; fi
        case "$target" in
            TMUX--recent) echo 7001;;
            TMUX--older) echo 7002;;
            *) echo 79999;;
        esac
        exit 0;;
    display-message) echo 0; exit 0;;
    show-option) echo 1; exit 0;;
    *) exit 0;;
esac
SH
    chmod +x "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
    *7001*|*7002*) echo "claude"; exit 0;;
    *79999*) echo "-zsh"; exit 0;;
esac
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    cat > "$sdir/7001.json" <<'JSON'
{"pid":7001,"sessionId":"recent-uuid","updatedAt":1751000000000}
JSON
    cat > "$sdir/7002.json" <<'JSON'
{"pid":7002,"sessionId":"older-uuid","updatedAt":1700000000000}
JSON

    local out order
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        TMUX_FAKE_SESSIONS="TMUX--older TMUX--noresolve TMUX--recent" "$ROOT/cctrl" session ls --json)"
    order="$(printf '%s' "$out" | jq -r '.[].name' | tr '\n' ',')"
    [[ "$order" == "TMUX--recent,TMUX--older,TMUX--noresolve," ]] \
        || fail "expected sort order recent,older,noresolve; got: $order"
}

test_session_list_base_state() {
    # Base STATE column derives from the per-pid `status` field:
    # busy→working, idle→idle, shell→shell, unresolvable→'-'. The attached/
    # detached fact is retained separately (attached boolean in --json).
    local bin="$TMPDIR/statebin" sdir="$TMPDIR/state-sessions" pdir="$TMPDIR/state-projects"
    mkdir -p "$bin" "$sdir" "$pdir"
    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
target=""
for ((i=1;i<=$#;i++)); do
    if [[ "${!i}" == "-t" ]]; then j=$((i+1)); target="${!j:-}"; break; fi
done
case "${1:-}" in
    list-sessions) for s in $TMUX_FAKE_SESSIONS; do printf '%s\n' "$s"; done; exit 0;;
    list-panes)
        if [[ "$*" == *pane_current_path* ]]; then echo /tmp/demo; exit 0; fi
        case "$target" in
            TMUX--busy)  echo 8001;;
            TMUX--idle)  echo 8002;;
            TMUX--shell) echo 8003;;
            *) echo 89999;;
        esac
        exit 0;;
    display-message) echo 0; exit 0;;
    show-option) echo 1; exit 0;;
    *) exit 0;;
esac
SH
    chmod +x "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
    *8001*|*8002*|*8003*) echo "claude"; exit 0;;
    *89999*) echo "-zsh"; exit 0;;
esac
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    cat > "$sdir/8001.json" <<'JSON'
{"pid":8001,"sessionId":"busy-uuid","status":"busy"}
JSON
    cat > "$sdir/8002.json" <<'JSON'
{"pid":8002,"sessionId":"idle-uuid","status":"idle"}
JSON
    cat > "$sdir/8003.json" <<'JSON'
{"pid":8003,"sessionId":"shell-uuid","status":"shell"}
JSON

    local sessions="TMUX--busy TMUX--idle TMUX--shell TMUX--noresolve"
    local out human
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        TMUX_FAKE_SESSIONS="$sessions" "$ROOT/cctrl" session ls --json)"
    # Per-pid status maps to the base state in --json.
    assert_contains "$(printf '%s' "$out" | jq -r '.[] | select(.name=="TMUX--busy")  | .state')" "working"
    assert_contains "$(printf '%s' "$out" | jq -r '.[] | select(.name=="TMUX--idle")  | .state')" "idle"
    assert_contains "$(printf '%s' "$out" | jq -r '.[] | select(.name=="TMUX--shell") | .state')" "shell"
    # Unresolvable session renders '-' and never errors.
    [[ "$(printf '%s' "$out" | jq -r '.[] | select(.name=="TMUX--noresolve") | .state')" == "-" ]] \
        || fail "expected unresolvable session state to be '-'"
    # attached boolean retained alongside the new base state field.
    assert_contains "$out" '"attached": false'

    # Human output carries the base state column (e.g. 'working').
    human="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        TMUX_FAKE_SESSIONS="$sessions" "$ROOT/cctrl" session ls)"
    assert_contains "$human" "working"
    echo "ok: session ls exposes base state (working/idle/shell/-)"
}

test_session_list_recap() {
    # --recap (opt-in) surfaces a one-line recap per session, sourced from the
    # transcript's compact-summary entry (isCompactSummary). Sessions with no
    # transcript / no summary render null under --recap and never error.
    # Without --recap the recap key is absent (output byte-for-byte unchanged).
    local bin="$TMPDIR/recapbin" sdir="$TMPDIR/recap-sessions" pdir="$TMPDIR/recap-projects"
    mkdir -p "$bin" "$sdir" "$pdir/some-proj"
    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
target=""
for ((i=1;i<=$#;i++)); do
    if [[ "${!i}" == "-t" ]]; then j=$((i+1)); target="${!j:-}"; break; fi
done
case "${1:-}" in
    list-sessions) for s in $TMUX_FAKE_SESSIONS; do printf '%s\n' "$s"; done; exit 0;;
    list-panes)
        if [[ "$*" == *pane_current_path* ]]; then echo /tmp/demo; exit 0; fi
        case "$target" in
            TMUX--recap)   echo 9101;;
            TMUX--norecap) echo 9102;;
            *) echo 91999;;
        esac
        exit 0;;
    display-message) echo 0; exit 0;;
    show-option) echo 1; exit 0;;
    *) exit 0;;
esac
SH
    chmod +x "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
    *9101*|*9102*) echo "claude"; exit 0;;
esac
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    cat > "$sdir/9101.json" <<'JSON'
{"pid":9101,"sessionId":"recap-uuid"}
JSON
    cat > "$sdir/9102.json" <<'JSON'
{"pid":9102,"sessionId":"norecap-uuid"}
JSON

    # Transcript for the recap session: an assistant preamble, the dedicated
    # compact-summary entry, then a later assistant line. The recap must come
    # from the summary entry — never the last assistant text line.
    local tfile="$pdir/some-proj/recap-uuid.jsonl"
    local content='This session is being continued from a previous conversation that ran out of context.
Summary:
1. Primary Request and Intent: Build the widget dashboard for acceptance.'
    {
        jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"Let me check that first."}]}}'
        jq -cn --arg c "$content" '{type:"user",isCompactSummary:true,message:{role:"user",content:$c}}'
        jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"On it now."}]}}'
    } > "$tfile"
    # The norecap session's sessionId resolves no transcript at all.

    local sessions="TMUX--recap TMUX--norecap"
    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        TMUX_FAKE_SESSIONS="$sessions" "$ROOT/cctrl" session ls --recap --json)"
    # (a) recap extracted from the compact-summary entry (not the last line).
    [[ "$(printf '%s' "$out" | jq -r '.[] | select(.name=="TMUX--recap") | .recap')" \
        == "1. Primary Request and Intent: Build the widget dashboard for acceptance." ]] \
        || fail "expected recap from compact-summary; got: $(printf '%s' "$out" | jq -r '.[] | select(.name=="TMUX--recap") | .recap')"
    assert_not_contains "$(printf '%s' "$out" | jq -r '.[] | select(.name=="TMUX--recap") | .recap')" "On it now"
    # (b) transcript-less session yields recap null, no error.
    [[ "$(printf '%s' "$out" | jq -r '.[] | select(.name=="TMUX--norecap") | .recap')" == "null" ]] \
        || fail "expected null recap for transcript-less session"

    # (c) Without --recap the recap key is absent (default output unchanged).
    local out_default
    out_default="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        TMUX_FAKE_SESSIONS="$sessions" "$ROOT/cctrl" session ls --json)"
    [[ "$(printf '%s' "$out_default" | jq '[.[] | has("recap")] | any')" == "false" ]] \
        || fail "default session ls --json must not include a recap key"

    # Human --recap output carries the recap text.
    local human
    human="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        TMUX_FAKE_SESSIONS="$sessions" "$ROOT/cctrl" session ls --recap)"
    assert_contains "$human" "Primary Request and Intent"
    echo "ok: session ls --recap surfaces compact-summary recap; null/absent otherwise"
}

test_session_list_rich_state() {
    # Rich STATE (plan 016) layers detectors onto the base state (plan 014) in a
    # documented precedence: blocked-dialog > unsent-draft > waiting-input >
    # idle-done > base. Every detector is fail-safe: an ambiguous/unavailable
    # signal falls back to the base state, never a guess. The fake tmux returns
    # REALISTIC captured-pane fixtures (a permission dialog; an unsent input
    # line) and per-target #{pane_in_mode}, so the fragile pane signatures are
    # exercised against real-shaped output rather than empty stubs.
    local bin="$TMPDIR/richbin" sdir="$TMPDIR/rich-sessions" pdir="$TMPDIR/rich-projects"
    mkdir -p "$bin" "$sdir" "$pdir/some-proj"

    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
target=""
for ((i=1;i<=$#;i++)); do
    if [[ "${!i}" == "-t" ]]; then j=$((i+1)); target="${!j:-}"; break; fi
done
case "${1:-}" in
    list-sessions) for s in $TMUX_FAKE_SESSIONS; do printf '%s\n' "$s"; done; exit 0;;
    list-panes)
        if [[ "$*" == *pane_current_path* ]]; then echo /tmp/demo; exit 0; fi
        case "$target" in
            TMUX--waiting)  echo 9201;;
            TMUX--done)     echo 9202;;
            TMUX--bareidle) echo 9203;;
            TMUX--ambig)    echo 9204;;
            TMUX--dialog)   echo 9205;;
            TMUX--draft)    echo 9206;;
            TMUX--copymode) echo 9207;;
            *) echo 92999;;
        esac
        exit 0;;
    display-message) echo 0; exit 0;;
    display)
        # #{pane_in_mode}: only the copy-mode session reports 1.
        if [[ "$*" == *pane_in_mode* ]]; then
            [[ "$target" == "TMUX--copymode" ]] && echo 1 || echo 0
        else
            echo 0
        fi
        exit 0;;
    capture-pane)
        # Realistic captured-pane fixtures per target. Others render empty.
        case "$target" in
            TMUX--dialog)
                cat <<'PANE'
● I'll remove the old build artifacts now.

╭──────────────────────────────────────────────────╮
│ Do you want to proceed?                          │
│ ❯ 1. Yes                                         │
│   2. No, and tell Claude what to do differently  │
╰──────────────────────────────────────────────────╯
PANE
                ;;
            TMUX--draft)
                cat <<'PANE'
● All done — the refactor is complete.

╭──────────────────────────────────────────────────╮
│ > wait, use the other approach instead           │
╰──────────────────────────────────────────────────╯
  ? for shortcuts
PANE
                ;;
            TMUX--copymode)
                # Same draft-shaped line, but this pane is in copy-mode, so the
                # detector must skip it and fall back to base (idle).
                cat <<'PANE'
╭──────────────────────────────────────────────────╮
│ > half-typed reply that should be ignored        │
╰──────────────────────────────────────────────────╯
PANE
                ;;
        esac
        exit 0;;
    show-option) echo 1; exit 0;;
    *) exit 0;;
esac
SH
    chmod +x "$bin/tmux"

    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
    *9201*|*9202*|*9203*|*9204*|*9205*|*9206*|*9207*) echo "claude"; exit 0;;
esac
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"

    # Per-pid session files (status drives the base state).
    cat > "$sdir/9201.json" <<'JSON'
{"pid":9201,"sessionId":"waiting-uuid","status":"idle"}
JSON
    cat > "$sdir/9202.json" <<'JSON'
{"pid":9202,"sessionId":"done-uuid","status":"idle"}
JSON
    cat > "$sdir/9203.json" <<'JSON'
{"pid":9203,"sessionId":"bareidle-uuid","status":"idle"}
JSON
    cat > "$sdir/9204.json" <<'JSON'
{"pid":9204,"sessionId":"ambig-uuid","status":"idle"}
JSON
    # The dialog session is busy: proves blocked-dialog overrides a confident
    # non-idle base (a live modal blocks regardless of the status field).
    cat > "$sdir/9205.json" <<'JSON'
{"pid":9205,"sessionId":"dialog-uuid","status":"busy"}
JSON
    cat > "$sdir/9206.json" <<'JSON'
{"pid":9206,"sessionId":"draft-uuid","status":"idle"}
JSON
    cat > "$sdir/9207.json" <<'JSON'
{"pid":9207,"sessionId":"copymode-uuid","status":"idle"}
JSON

    # Transcript tails. waiting: last turn is an assistant question (awaiting a
    # user answer). done: last turn is a finished assistant message. ambig: last
    # turn is a user message (tool_result) — indeterminate → must fall back.
    {
        jq -cn '{type:"user",message:{role:"user",content:"run the migration"}}'
        jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"The migration touches production data. Do you want me to run it now?"}]}}'
    } > "$pdir/some-proj/waiting-uuid.jsonl"
    {
        jq -cn '{type:"user",message:{role:"user",content:"run the migration"}}'
        jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"Done. The migration applied cleanly and all checks passed."}]}}'
    } > "$pdir/some-proj/done-uuid.jsonl"
    {
        jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"Let me inspect the schema."}]}}'
        jq -cn '{type:"user",message:{role:"user",content:[{type:"tool_result",content:"3 tables"}]}}'
    } > "$pdir/some-proj/ambig-uuid.jsonl"
    # bareidle/dialog/draft/copymode sessions resolve no transcript.

    local sessions="TMUX--waiting TMUX--done TMUX--bareidle TMUX--ambig TMUX--dialog TMUX--draft TMUX--copymode"
    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        TMUX_FAKE_SESSIONS="$sessions" "$ROOT/cctrl" session ls --json)"
    st() { printf '%s' "$out" | jq -r --arg n "$1" '.[] | select(.name==$n) | .state'; }

    # (a) transcript: last turn = assistant question → waiting-input.
    [[ "$(st TMUX--waiting)" == "waiting-input" ]] \
        || fail "expected waiting-input; got: $(st TMUX--waiting)"
    # idle-done: idle base + finished assistant turn (distinct from bare idle).
    [[ "$(st TMUX--done)" == "idle-done" ]] \
        || fail "expected idle-done; got: $(st TMUX--done)"
    # bare idle: idle base, no transcript signal → stays idle.
    [[ "$(st TMUX--bareidle)" == "idle" ]] \
        || fail "expected bare idle; got: $(st TMUX--bareidle)"
    # (b) ambiguous transcript (last turn = user) → falls back to base (idle),
    # never a misclassification.
    [[ "$(st TMUX--ambig)" == "idle" ]] \
        || fail "expected ambiguous fixture to fall back to base idle; got: $(st TMUX--ambig)"
    # pane: known dialog signature → blocked-dialog (overrides busy base).
    [[ "$(st TMUX--dialog)" == "blocked-dialog" ]] \
        || fail "expected blocked-dialog; got: $(st TMUX--dialog)"
    # pane: non-empty input line → unsent-draft.
    [[ "$(st TMUX--draft)" == "unsent-draft" ]] \
        || fail "expected unsent-draft; got: $(st TMUX--draft)"
    # copy-mode guard: pane in copy-mode is not inspected → falls back to idle.
    [[ "$(st TMUX--copymode)" == "idle" ]] \
        || fail "expected copy-mode session to fall back to idle; got: $(st TMUX--copymode)"

    # Precedence: with the blocked-dialog detector disabled, the dialog pane no
    # longer overrides — proving detectors are individually disableable and the
    # column degrades gracefully to the base state.
    local out2
    out2="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        CCTRL_STATE_DETECT_BLOCKED_DIALOG=0 TMUX_FAKE_SESSIONS="TMUX--dialog" \
        "$ROOT/cctrl" session ls --json)"
    [[ "$(printf '%s' "$out2" | jq -r '.[0].state')" == "working" ]] \
        || fail "expected disabled blocked-dialog detector to fall back to base working"

    # Human output carries the refined STATE value.
    local human
    human="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        TMUX_FAKE_SESSIONS="$sessions" "$ROOT/cctrl" session ls)"
    assert_contains "$human" "blocked-dialog"
    assert_contains "$human" "waiting-input"
    echo "ok: session ls STATE surfaces rich states with fail-safe fallback to base"
}

# --- plan 030: unsent-draft detector must fire on the real ❯ (U+276F) glyph ---
# The detector anchored on ASCII '>' but Claude Code's input line begins with
# '❯', so it never fired on a real pane. These tests exercise the fixed detector
# against fixtures MODELED ON real `tmux capture-pane` output (committed under
# tests/fixtures/), through the pure function, the rich-state path, and the
# autoheal safety gate.
test_session_pane_has_draft_glyph_fixtures() {
    # Unit test: source the pure detector out of cctrl and assert it against the
    # committed real-pane fixtures. A draft line beginning with '❯' (and the
    # legacy ASCII '>') must be detected; an empty box showing only placeholder /
    # hint text must NOT be — the glyph-independent exclusion filter still holds.
    local fn="$TMPDIR/pane-draft-fn.sh"
    awk '/^_session_pane_has_draft\(\) \{/,/^}/' "$ROOT/cctrl" > "$fn"
    # shellcheck source=/dev/null
    source "$fn"

    local fx="$ROOT/tests/fixtures"
    # (a) real ❯ draft pane → detected.
    _session_pane_has_draft "$(cat "$fx/pane-draft.txt")" \
        || fail "expected ❯ (U+276F) draft fixture to be detected as a draft"
    # legacy ASCII '>' form → still detected (no regression).
    _session_pane_has_draft "> commit the plans" \
        || fail "expected ASCII '>' draft to remain detected"
    # (b) empty box with placeholder/hint text → NOT a draft.
    ! _session_pane_has_draft "$(cat "$fx/pane-empty-hint.txt")" \
        || fail "expected empty/hint fixture to NOT read as a draft"
    # A bare placeholder line under the ❯ glyph is excluded too.
    ! _session_pane_has_draft '❯ Try "write a test for the parser"' \
        || fail "expected ❯ placeholder 'Try ...' line to be excluded"
    echo "ok: _session_pane_has_draft fires on ❯ and > drafts, ignores hint text"
}

test_session_rich_state_detects_glyph_draft() {
    # A pane holding a real ❯ (U+276F) input line must surface as unsent-draft
    # through the full `session ls` rich-state path — proving the glyph fix
    # reaches the fleet view, not just the unit detector.
    local bin="$TMPDIR/glyphdraft-bin" sdir="$TMPDIR/glyphdraft-sessions"
    mkdir -p "$bin" "$sdir"

    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
target=""
for ((i=1;i<=$#;i++)); do
    if [[ "${!i}" == "-t" ]]; then j=$((i+1)); target="${!j:-}"; break; fi
done
case "${1:-}" in
    list-sessions) for s in $TMUX_FAKE_SESSIONS; do printf '%s\n' "$s"; done; exit 0;;
    list-panes)
        if [[ "$*" == *pane_current_path* ]]; then echo /tmp/demo; exit 0; fi
        echo 9310; exit 0;;
    display-message) echo 0; exit 0;;
    display) echo 0; exit 0;;
    capture-pane) cat "$DRAFT_FIXTURE"; exit 0;;
    show-option) echo 1; exit 0;;
    *) exit 0;;
esac
SH
    chmod +x "$bin/tmux"

    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
    *9310*) echo "claude"; exit 0;;
esac
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"

    cat > "$sdir/9310.json" <<'JSON'
{"pid":9310,"sessionId":"glyphdraft-uuid","status":"idle"}
JSON

    local out state
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        DRAFT_FIXTURE="$ROOT/tests/fixtures/pane-draft.txt" \
        TMUX_FAKE_SESSIONS="TMUX--glyphdraft" "$ROOT/cctrl" session ls --json)"
    state="$(printf '%s' "$out" | jq -r '.[0].state')"
    [[ "$state" == "unsent-draft" ]] \
        || fail "expected ❯ draft pane to surface as unsent-draft; got: $state"
    echo "ok: rich-state surfaces a ❯ (U+276F) input line as unsent-draft"
}

test_session_autoheal_skips_glyph_draft() {
    # SAFETY GATE (plan 030): a dead bridge whose input line holds a real ❯
    # (U+276F) draft must be SKIPPED — /rc begins with C-u, which would erase it.
    # Before the glyph fix this gate never fired against a real pane, so the
    # scheduled C-u ran unguarded. Proven here against the real-pane fixture.
    local bin="$TMPDIR/ah-glyph-bin" sdir="$TMPDIR/ah-glyph-sessions"
    local rlog="$TMPDIR/ah-glyph-repair.log" hlog="$TMPDIR/ah-glyph-heal.log"
    _autoheal_fixture "$bin" "$sdir" "idle"
    : > "$rlog"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 \
        TMUX_FAKE_CAPTURE_PANE="$(cat "$ROOT/tests/fixtures/pane-draft.txt")" \
        CCTRL_AUTOHEAL_LOG="$hlog" CCTRL_AUTOHEAL_REPAIR_LOG="$rlog" \
        "$ROOT/cctrl" session autoheal --json)"
    assert_contains "$out" '"action": "skipped"'
    assert_contains "$out" '"reason": "unsent-draft"'
    [[ -s "$rlog" ]] && fail "❯ draft session must NOT be repaired (repair log non-empty)"
    assert_contains "$(cat "$hlog")" "skipped TMUX--ms--portal (unsent-draft)"
    echo "ok: autoheal safety gate skips a ❯ (U+276F) real-pane draft"
}

test_needs_me_digest() {
    # needs-me (plan 022) diffs each session's rich STATE (plan 016) against a
    # snapshot from the previous run and reports only sessions that NEWLY entered
    # an attention state. Reuses the plan 016 fixture machinery (fake tmux +
    # per-pid session files + transcript tails). Snapshot path is test-overridden.
    local bin="$TMPDIR/needbin" sdir="$TMPDIR/need-sessions" pdir="$TMPDIR/need-projects"
    local snap="$TMPDIR/need-snapshot.json"
    mkdir -p "$bin" "$sdir" "$pdir/some-proj"
    rm -f "$snap"

    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
target=""
for ((i=1;i<=$#;i++)); do
    if [[ "${!i}" == "-t" ]]; then j=$((i+1)); target="${!j:-}"; break; fi
done
case "${1:-}" in
    list-sessions) for s in $TMUX_FAKE_SESSIONS; do printf '%s\n' "$s"; done; exit 0;;
    list-panes)
        if [[ "$*" == *pane_current_path* ]]; then echo /tmp/demo; exit 0; fi
        case "$target" in
            TMUX--needwait) echo 9301;;
            TMUX--trans)    echo 9302;;
            *) echo 93999;;
        esac
        exit 0;;
    display-message) echo 0; exit 0;;
    display) echo 0; exit 0;;
    capture-pane) exit 0;;
    show-option) echo 1; exit 0;;
    *) exit 0;;
esac
SH
    chmod +x "$bin/tmux"

    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in *9301*|*9302*) echo "claude"; exit 0;; esac
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"

    # Both sessions idle at the status level; the rich state is refined by the
    # transcript tail. needwait always resolves to waiting-input; trans starts
    # with no transcript (bare idle) and gains an assistant-question before run 2.
    cat > "$sdir/9301.json" <<'JSON'
{"pid":9301,"sessionId":"needwait-uuid","status":"idle"}
JSON
    cat > "$sdir/9302.json" <<'JSON'
{"pid":9302,"sessionId":"trans-uuid","status":"idle"}
JSON
    {
        jq -cn '{type:"user",message:{role:"user",content:"run the migration"}}'
        jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"Do you want me to proceed now?"}]}}'
    } > "$pdir/some-proj/needwait-uuid.jsonl"

    local sessions="TMUX--needwait TMUX--trans"
    run_needs_me() {
        PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
            CCTRL_NEEDS_ME_SNAPSHOT="$snap" TMUX_FAKE_SESSIONS="$sessions" "$ROOT/cctrl" needs-me "$@"
    }

    # (c) First run, no prior snapshot: reports current attention-state sessions
    # (needwait) as new, without error. (d) writes the snapshot file.
    local run1
    run1="$(run_needs_me)"
    assert_contains "$run1" "TMUX--needwait"
    assert_contains "$run1" "waiting-input"
    [[ -f "$snap" ]] || fail "expected needs-me to write a snapshot file"
    # trans (bare idle) is not an attention state, so it is not flagged.
    assert_not_contains "$run1" "TMUX--trans"
    # Snapshot records the full current state of every session for the next diff.
    [[ "$(jq -r '."TMUX--needwait"' "$snap")" == "waiting-input" ]] \
        || fail "snapshot should record needwait=waiting-input; got: $(cat "$snap")"
    [[ "$(jq -r '."TMUX--trans"' "$snap")" == "idle" ]] \
        || fail "snapshot should record trans=idle; got: $(cat "$snap")"

    # Now flip trans idle→waiting-input by giving it an assistant-question tail.
    {
        jq -cn '{type:"user",message:{role:"user",content:"which option?"}}'
        jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"Which approach do you prefer?"}]}}'
    } > "$pdir/some-proj/trans-uuid.jsonl"

    # (a) needwait was already waiting-input in the snapshot → NOT re-flagged.
    # (b) trans transitioned idle→waiting-input → reported with from/to states.
    local run2
    run2="$(run_needs_me --json)"
    local names
    names="$(printf '%s' "$run2" | jq -c 'map(.name) | sort')"
    [[ "$names" == '["TMUX--trans"]' ]] \
        || fail "expected only the newly-transitioned session; got: $names"
    [[ "$(printf '%s' "$run2" | jq -r '.[0].from_state')" == "idle" ]] \
        || fail "expected from_state idle; got: $(printf '%s' "$run2" | jq -r '.[0].from_state')"
    [[ "$(printf '%s' "$run2" | jq -r '.[0].to_state')" == "waiting-input" ]] \
        || fail "expected to_state waiting-input; got: $(printf '%s' "$run2" | jq -r '.[0].to_state')"
    printf '%s' "$run2" | jq -e '.[0] | has("last_active")' >/dev/null \
        || fail "expected --json entry to carry last_active"

    # (a, continued) A third run with no further changes flags nothing — both
    # sessions are already waiting-input in the snapshot.
    local run3
    run3="$(run_needs_me --json)"
    [[ "$(printf '%s' "$run3" | jq 'length')" == "0" ]] \
        || fail "expected no new attention transitions on a stable run; got: $run3"

    echo "ok: needs-me flags only newly-attention sessions, diffs a snapshot, first-run safe"
}

test_peer_registry_manual_alias_and_identity() {
    local data="$TMPDIR/peer-manual-data"
    local project="$TMPDIR/comet-automation"
    mkdir -p "$project"

    local out
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register comet \
        --dir "$project" --agent codex --purpose "PiKVM automation work" \
        --capability polling)"
    assert_contains "$out" "Registered peer"
    assert_contains "$(cat "$data/peers.json")" '"comet"'
    assert_contains "$(cat "$data/peers.json")" '"dir": "'"$project"'"'

    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer alias comet comet-agent)"
    assert_contains "$out" "Added alias"

    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer ls --json)"
    assert_contains "$out" '"name": "comet"'
    assert_contains "$out" '"purpose": "PiKVM automation work"'
    assert_contains "$out" '"polling"'

    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer resolve comet-agent --json)"
    assert_contains "$out" '"name": "comet"'
    assert_contains "$out" '"source": "manual"'

    out="$(CCTRL_DATA_DIR="$data" CCTRL_PEER=comet "$ROOT/cctrl" peer whoami --json)"
    assert_contains "$out" '"name": "comet"'

    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer unregister comet)"
    assert_contains "$out" "Unregistered peer"
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer ls --json)"
    assert_not_contains "$out" '"name": "comet"'
}

test_peer_derived_tmux_and_shadowing() {
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_ps "$TMPDIR/ps"
    local data="$TMPDIR/peer-derived-data"
    mkdir -p "$CCTRL_SESSION_METADATA_DIR"
    cat > "$CCTRL_SESSION_METADATA_DIR/demo.json" <<'JSON'
{"purpose":"review stale session cleanup","created_at":"2026-06-11T10:00:00Z"}
JSON

    local out
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer ls --json)"
    assert_contains "$out" '"name": "demo"'
    assert_contains "$out" '"source": "derived"'
    assert_contains "$out" '"session": "demo"'
    assert_contains "$out" '"tmux_target": "demo"'
    assert_contains "$out" '"purpose": "review stale session cleanup"'

    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer resolve demo --json)"
    assert_contains "$out" '"capabilities": ['
    assert_contains "$out" '"tmux"'

    cat > "$CCTRL_SESSION_METADATA_DIR/bootstrap.json" <<'JSON'
{"purpose":"bootstrapping peer","created_at":"2026-06-11T10:00:00Z","peer":"rover","cctrl_managed":true}
JSON
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" TMUX_FAKE_SESSIONS="bootstrap" TMUX_FAKE_PANE_PID=99999 "$ROOT/cctrl" peer resolve rover --json)"
    assert_contains "$out" '"name": "rover"'
    assert_contains "$out" '"source": "derived"'

    local rc=0
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register comet --alias demo 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected alias collision with derived peer to fail"
    assert_contains "$out" "collides with a live tmux peer"

    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register demo --dir /manual/demo --agent other)"
    assert_contains "$out" "Registered peer"
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer ls --json)"
    assert_contains "$out" '"name": "demo"'
    assert_contains "$out" '"source": "manual"'
    assert_contains "$out" '"shadows": "demo"'
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer resolve demo --json)"
    assert_contains "$out" '"dir": "/manual/demo"'
    assert_contains "$out" '"source": "manual"'

    local peer_data="$TMPDIR/peer-derived-metadata-data"
    cat > "$CCTRL_SESSION_METADATA_DIR/demo.json" <<'JSON'
{"purpose":"peer session","created_at":"2026-06-11T10:00:00Z","peer":"comet"}
JSON
    CCTRL_DATA_DIR="$peer_data" "$ROOT/cctrl" peer register comet --dir /manual/comet --agent codex --capability polling >/dev/null
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$peer_data" "$ROOT/cctrl" peer resolve comet --json)"
    assert_contains "$out" '"name": "comet"'
    assert_contains "$out" '"source": "manual"'
    assert_contains "$out" '"session": "demo"'
    assert_contains "$out" '"tmux_target": "demo"'
    assert_contains "$out" '"tmux"'
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$peer_data" "$ROOT/cctrl" peer resolve demo --json)"
    assert_contains "$out" '"name": "comet"'

    local backfill_data="$TMPDIR/peer-derived-agent-backfill-data"
    CCTRL_DATA_DIR="$backfill_data" "$ROOT/cctrl" peer register comet --dir /manual/comet >/dev/null
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$backfill_data" "$ROOT/cctrl" peer resolve comet --json)"
    assert_contains "$out" '"name": "comet"'
    assert_contains "$out" '"source": "manual"'
    assert_contains "$out" '"agent": "codex"'

    CCTRL_DATA_DIR="$peer_data" "$ROOT/cctrl" peer register demo --dir /manual/demo --agent other >/dev/null
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$peer_data" "$ROOT/cctrl" peer resolve demo --json)"
    assert_contains "$out" '"name": "demo"'
    assert_contains "$out" '"dir": "/manual/demo"'
    assert_contains "$out" '"source": "manual"'
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$peer_data" "$ROOT/cctrl" peer resolve comet --json)"
    assert_contains "$out" '"name": "comet"'
    printf '%s\n' "$out" | jq -e '(.aliases // []) | index("demo") | not' >/dev/null || fail "expected manual demo to shadow derived demo alias"

    local alias_data="$TMPDIR/peer-derived-manual-alias-data"
    local quiet_tmux_dir="$TMPDIR/quiet-tmux-bin"
    mkdir -p "$quiet_tmux_dir"
    cat > "$quiet_tmux_dir/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions) exit 0 ;;
    *) exit 1 ;;
esac
SH
    chmod +x "$quiet_tmux_dir/tmux"
    PATH="$quiet_tmux_dir:$PATH" CCTRL_DATA_DIR="$alias_data" "$ROOT/cctrl" peer register reviewer --alias demo --agent codex >/dev/null
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$alias_data" "$ROOT/cctrl" peer resolve demo --json)"
    assert_contains "$out" '"name": "reviewer"'
    assert_contains "$out" '"source": "manual"'
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$alias_data" "$ROOT/cctrl" peer resolve comet --json)"
    assert_contains "$out" '"name": "comet"'
    printf '%s\n' "$out" | jq -e '(.aliases // []) | index("demo") | not' >/dev/null || fail "expected manual demo alias to shadow derived demo alias"

    local alias_name_data="$TMPDIR/peer-derived-manual-alias-name-data"
    PATH="$quiet_tmux_dir:$PATH" CCTRL_DATA_DIR="$alias_name_data" "$ROOT/cctrl" peer register comet --alias c --agent codex >/dev/null
    cat > "$CCTRL_SESSION_METADATA_DIR/demo.json" <<'JSON'
{"purpose":"alias-name session","created_at":"2026-06-11T10:00:00Z","peer":"c"}
JSON
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$alias_name_data" "$ROOT/cctrl" peer resolve c --json)"
    assert_contains "$out" '"name": "comet"'
    assert_contains "$out" '"source": "manual"'
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$alias_name_data" "$ROOT/cctrl" peer ls --json)"
    printf '%s\n' "$out" | jq -e '[.peers[] | select(.source == "derived" and .name == "c")] | length == 0' >/dev/null || fail "expected manual alias c to shadow derived peer name c"
}

test_peer_validation_and_errors() {
    local data="$TMPDIR/peer-validation-data"
    local out rc

    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register bad/name 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected invalid peer name to fail"
    assert_contains "$out" "Invalid peer name"
    assert_contains "$out" "no whitespace or shell metacharacters"

    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register comet >/dev/null
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer alias comet comet-agent >/dev/null

    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register other --alias comet-agent 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected alias collision to fail"
    assert_contains "$out" "collides"

    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer resolve missing --json 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected missing peer resolve to fail"
    assert_contains "$out" "Unknown peer"
}

test_peer_alias_derived_requires_manual_registration() {
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_ps "$TMPDIR/ps"
    local data="$TMPDIR/peer-derived-alias-data"
    local out rc=0
    mkdir -p "$CCTRL_SESSION_METADATA_DIR"
    cat > "$CCTRL_SESSION_METADATA_DIR/demo.json" <<'JSON'
{"purpose":"review stale session cleanup","created_at":"2026-06-11T10:00:00Z"}
JSON

    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer alias demo demo-agent 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected derived-only alias to fail"
    assert_contains "$out" "register this peer first"
}

test_peer_tmux_missing_still_resolves_manual() {
    local data="$TMPDIR/peer-no-tmux-data"

    local out
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register offline --agent codex --capability polling)"
    assert_contains "$out" "Registered peer"

    out="$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer ls --json)"
    assert_contains "$out" '"derived_skipped": true'
    assert_contains "$out" '"derived_skip_reason": "tmux unavailable"'
    assert_contains "$out" '"name": "offline"'

    out="$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer resolve offline --json)"
    assert_contains "$out" '"name": "offline"'
    assert_contains "$out" '"polling"'
}

setup_mailbox_peers() {
    local data="$1"
    mkdir -p "$TMPDIR/comet" "$TMPDIR/orchestrator" "$TMPDIR/wrong-peer"
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register comet --dir "$TMPDIR/comet" --agent codex >/dev/null
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register orchestrator --dir "$TMPDIR/orchestrator" --agent codex >/dev/null
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register wrong-peer --dir "$TMPDIR/wrong-peer" --agent codex >/dev/null
}

setup_delivery_peers() {
    local data="$1"
    mkdir -p "$TMPDIR/comet" "$TMPDIR/orchestrator" "$TMPDIR/offline"
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register comet --dir "$TMPDIR/comet" --agent codex --session TMUX--comet >/dev/null
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register orchestrator --dir "$TMPDIR/orchestrator" --agent codex >/dev/null
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register offline --dir "$TMPDIR/offline" --agent codex >/dev/null
}

# Shared body for the per-agent modal-detector regression tests. Asserts that a
# real approval modal DEFERS delivery (no paste) while benign output that merely
# resembles one still NUDGES (pastes + submits). The two callers differ only in
# peer/session and the modal/benign pane fixtures.
assert_modal_detection() {
    local data="$1" log="$2" peer="$3" session="$4" modal_pane="$5" benign_pane="$6"
    local out
    # (a) A real modal must DEFER: message stays queued, nothing is pasted.
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send "$peer" --from orchestrator --json -- "hold for modal" >/dev/null
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="$session" TMUX_FAKE_CAPTURE_PANE="$modal_pane" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver "$peer" --json)"
    printf '%s\n' "$out" | jq -e '.results[0].status == "deferred" and .results[0].reason == "modal prompt visible"' >/dev/null || fail "expected real $peer modal to defer"
    assert_not_contains "$(cat "$log")" "paste-buffer"

    # (b) Benign output with no real modal marker must NOT defer — it nudges.
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="$session" TMUX_FAKE_CAPTURE_PANE="$benign_pane" CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-13T00:00:05Z" "$ROOT/cctrl" peer deliver "$peer" --json)"
    printf '%s\n' "$out" | jq -e '.results[0].status == "nudged" and .results[0].submitted == true' >/dev/null || fail "expected benign $peer output (no modal marker) to nudge, not defer"
    assert_contains "$(cat "$log")" "paste-buffer -b cctrl-nudge-$peer-"
    assert_contains "$(cat "$log")" "send-keys -t $session Enter"
}

mark_message_delivered() {
    local file="$1" id="$2"
    jq -c --arg id "$id" '
        if .id == $id then
            .status = "delivered"
            | .updated_at = "2026-06-13T00:00:00Z"
            | .delivered_at = "2026-06-13T00:00:00Z"
            | .history = ((.history // []) + [{at:"2026-06-13T00:00:00Z", status:"delivered", by:"comet"}])
        else . end
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

test_peer_mailbox_send_list_show() {
    local data="$TMPDIR/mailbox-send-data"
    setup_mailbox_peers "$data"
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer alias comet halley >/dev/null

    local out id alias_id inbox outbox shown
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --subject "Check" --json -- "Please check XYZ")"
    assert_contains "$out" '"status": "queued"'
    assert_contains "$out" '"body": "Please check XYZ"'
    id="$(printf '%s\n' "$out" | jq -r '.id')"
    [[ "$id" == msg_* ]] || fail "expected stable msg_ id, got $id"
    assert_contains "$(cat "$data/messages.jsonl")" '"status":"queued"'

    inbox="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer inbox --as comet --json)"
    assert_contains "$inbox" '"to": "comet"'
    assert_contains "$inbox" '"status": "queued"'

    outbox="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer outbox --as orchestrator --json)"
    assert_contains "$outbox" '"from": "orchestrator"'
    assert_contains "$outbox" "$id"

    shown="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer show "$id" --json)"
    assert_contains "$shown" '"subject": "Check"'
    assert_contains "$shown" '"nudge_count": 0'
    assert_contains "$shown" '"last_nudge_error": null'

    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send halley --from orchestrator --json -- "via alias")"
    printf '%s\n' "$out" | jq -e '.to == "comet"' >/dev/null || fail "expected peer send to canonicalize recipient aliases"
    alias_id="$(printf '%s\n' "$out" | jq -r '.id')"
    inbox="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer inbox --as comet --json)"
    assert_contains "$inbox" "$alias_id"
    assert_contains "$inbox" '"body": "via alias"'
}

test_peer_sender_snapshot() {
    # Plan 023: peer send persists an additive `sender` snapshot so a receiver
    # keeps unambiguous identity after the sender's ephemeral tmux session closes.
    local data="$TMPDIR/sender-snapshot-data"
    local quiet="$TMPDIR/quiet-tmux-bin"
    mkdir -p "$TMPDIR/comet" "$TMPDIR/orchestrator" "$quiet"
    cat > "$quiet/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions) exit 0 ;;
    *) exit 1 ;;
esac
SH
    chmod +x "$quiet/tmux"
    PATH="$quiet:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register comet --dir "$TMPDIR/comet" --agent codex >/dev/null
    PATH="$quiet:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register orchestrator --dir "$TMPDIR/orchestrator" --agent codex --purpose "fleet orchestration" >/dev/null

    local out
    # (1) resolved manual sender: full object, label from purpose, no invented tmux_target.
    out="$(PATH="$quiet:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "hi")"
    printf '%s\n' "$out" | jq -e '.sender.name == "orchestrator"' >/dev/null || fail "expected sender.name == orchestrator"
    printf '%s\n' "$out" | jq -e '.sender.label == "fleet orchestration"' >/dev/null || fail "expected sender.label from purpose"
    printf '%s\n' "$out" | jq -e '.sender.agent == "codex"' >/dev/null || fail "expected sender.agent codex"
    printf '%s\n' "$out" | jq -e '.sender.host == "local"' >/dev/null || fail "expected sender.host local"
    printf '%s\n' "$out" | jq -e '(.sender | has("tmux_target")) | not' >/dev/null || fail "manual-only sender must not invent tmux_target"
    # (2) top-level `from` byte-identical (no field removed/renamed).
    printf '%s\n' "$out" | jq -e '.from == "orchestrator"' >/dev/null || fail "top-level from must be unchanged"
    printf '%s\n' "$out" | jq -e '.sender.name == .from' >/dev/null || fail "sender.name must equal canonical from"

    # (3) --from user: name + label only, no invented tmux/agent/host.
    out="$(PATH="$quiet:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from user --allow-unknown --json -- "hi")"
    printf '%s\n' "$out" | jq -e '.sender == {name:"user",label:"user"}' >/dev/null || fail "user sender must be name+label only"

    # (4) unresolved --allow-unknown sender: name only, still succeeds.
    out="$(PATH="$quiet:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send ghost --from phantom --allow-unknown --json -- "hi")"
    printf '%s\n' "$out" | jq -e '.sender == {name:"phantom"}' >/dev/null || fail "unresolved sender must carry name only"
    printf '%s\n' "$out" | jq -e '.from == "phantom"' >/dev/null || fail "from preserved for unresolved sender"

    # (5)+(7guard) legacy message without `sender` still renders, and `peer show`
    # emits NOTHING on stderr (regression pin for the .history jq join bug).
    printf '%s\n' '{"id":"msg_legacy_no_sender","from":"orchestrator","to":"comet","status":"queued","subject":"legacy","body":"old body","created_at":"2026-06-13T00:00:00Z","updated_at":"2026-06-13T00:00:00Z","delivered_at":null,"acked_at":null,"nudge_count":0,"last_nudge_at":null,"last_nudge_error":null,"history":[{"at":"2026-06-13T00:00:00Z","status":"queued","by":"orchestrator"}]}' >> "$data/messages.jsonl"
    PATH="$quiet:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer show msg_legacy_no_sender 1>"$TMPDIR/legacy-show.out" 2>"$TMPDIR/legacy-show.err"
    assert_contains "$(cat "$TMPDIR/legacy-show.out")" "from: orchestrator"
    assert_contains "$(cat "$TMPDIR/legacy-show.out")" "body: old body"
    [[ -s "$TMPDIR/legacy-show.err" ]] && fail "peer show must emit nothing on stderr (join bug), got: $(cat "$TMPDIR/legacy-show.err")"

    # legacy-shape message parses without error via the sender fallback.
    printf '%s\n' '{"from":"a","to":"b"}' | jq -e '(.sender // "absent") == "absent"' >/dev/null || fail "legacy message without sender must parse"

    # (6) `sender` renders on ONE readable line in human `peer show` (not a blob).
    local sid
    sid="$(PATH="$quiet:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "render me" | jq -r '.id')"
    out="$(PATH="$quiet:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer show "$sid")"
    assert_contains "$out" "sender: fleet orchestration (codex)"
    assert_not_contains "$out" '"tmux_target"'

    # inbox/outbox human template shows the sender label, falling back to bare from.
    out="$(PATH="$quiet:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer inbox --as comet)"
    assert_contains "$out" "fleet orchestration -> comet"

    # (8a) renderer edits do not reshape whoami / resolve output.
    PATH="$quiet:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register cap --dir "$TMPDIR/comet" --agent codex --capability polling --capability review >/dev/null
    out="$(PATH="$quiet:$PATH" CCTRL_DATA_DIR="$data" CCTRL_PEER=cap "$ROOT/cctrl" peer whoami --json)"
    printf '%s\n' "$out" | jq -e '.name == "cap"' >/dev/null || fail "whoami --json must be unchanged"
    printf '%s\n' "$out" | jq -e '(has("sender")) | not' >/dev/null || fail "peer identity must not gain a sender key"
    out="$(PATH="$quiet:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer resolve cap)"
    assert_contains "$out" "  name: cap"
    assert_contains "$out" "  capabilities: mailbox, polling, review"
    assert_not_contains "$out" "  sender:"

    # (8) empty display_label + no purpose must fall through to name, never "".
    local empty_data="$TMPDIR/sender-empty-label-data"
    mkdir -p "$CCTRL_SESSION_METADATA_DIR"
    cat > "$CCTRL_SESSION_METADATA_DIR/demo.json" <<'JSON'
{"peer":"rover","display_label":"","created_at":"2026-06-11T10:00:00Z","cctrl_managed":true}
JSON
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_ps "$TMPDIR/ps"
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$empty_data" "$ROOT/cctrl" peer send rover --from rover --allow-unknown --json -- "hi")"
    printf '%s\n' "$out" | jq -e '.sender.label == "rover"' >/dev/null || fail "empty display_label must fall through to name"
    printf '%s\n' "$out" | jq -e '.sender.label != ""' >/dev/null || fail "sender.label must never be empty string"

    # display_label surfaces additively in `_session_list --json`.
    cat > "$CCTRL_SESSION_METADATA_DIR/demo.json" <<'JSON'
{"purpose":"demo work","display_label":"@demo","created_at":"2026-06-11T10:00:00Z","cctrl_managed":true}
JSON
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$empty_data" "$ROOT/cctrl" session ls --json)"
    assert_contains "$out" '"display_label": "@demo"'

    # (7) a peer that is BOTH manually registered AND has a live session resolves a
    # real label via the _peer_all_json merge block (not purpose//name fallback).
    local live_data="$TMPDIR/sender-live-session-data"
    cat > "$CCTRL_SESSION_METADATA_DIR/demo.json" <<'JSON'
{"peer":"comet","display_label":"@comet","created_at":"2026-06-11T10:00:00Z","cctrl_managed":true}
JSON
    PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$live_data" "$ROOT/cctrl" peer register comet --dir /manual/comet --agent codex >/dev/null
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$live_data" "$ROOT/cctrl" peer resolve comet --json)"
    printf '%s\n' "$out" | jq -e '.source == "manual"' >/dev/null || fail "expected registered comet to merge with live demo session"
    printf '%s\n' "$out" | jq -e '.display_label == "@comet"' >/dev/null || fail "expected _peer_all_json to carry display_label from live session"
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$live_data" "$ROOT/cctrl" peer send comet --from comet --json -- "self")"
    printf '%s\n' "$out" | jq -e '.sender.label == "@comet"' >/dev/null || fail "expected sender.label to resolve display_label via _peer_all_json merge"
    printf '%s\n' "$out" | jq -e '.sender.tmux_target == "demo"' >/dev/null || fail "expected tmux_target for live-session sender"

    # Restore the SHARED session-metadata dir to a benign state. This test
    # overwrote demo.json with peer=comet; left in place, a later test whose
    # fake tmux surfaces the default "demo" session would derive a peer named
    # "comet" that merges with the manual "comet" and rewrites its session to
    # "demo" — breaking `peer deliver comet` in test_peer_deliver_tmux_nudge_lifecycle.
    # Matches the benign content the prior derived-peer tests leave behind.
    cat > "$CCTRL_SESSION_METADATA_DIR/demo.json" <<'JSON'
{"purpose":"review stale session cleanup","created_at":"2026-06-11T10:00:00Z"}
JSON
}

test_peer_mailbox_ack_authorization_and_states() {
    local data="$TMPDIR/mailbox-ack-data"
    setup_mailbox_peers "$data"

    local id out rc status
    id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "queued message" | jq -r '.id')"

    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer ack "$id" --as comet 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected ack of queued message to fail"
    assert_contains "$out" "receive it first (cctrl peer recv)"
    status="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer show "$id" --json | jq -r '.status')"
    [[ "$status" == "queued" ]] || fail "expected queued status to remain queued"

    mark_message_delivered "$data/messages.jsonl" "$id"

    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer ack "$id" --as wrong-peer 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected wrong-peer ack to fail"
    assert_contains "$out" "not addressed to 'wrong-peer'"
    status="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer show "$id" --json | jq -r '.status')"
    [[ "$status" == "delivered" ]] || fail "expected wrong-peer ack to leave delivered state unchanged"

    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer ack "$id" --as comet)"
    assert_contains "$out" "Acked message"
    status="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer show "$id" --json | jq -r '.status')"
    [[ "$status" == "acked" ]] || fail "expected message to be acked"
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer ack "$id" --as comet)"
    assert_contains "$out" "Acked message"
}

test_peer_mailbox_unknowns_and_identity() {
    local data="$TMPDIR/mailbox-unknown-data"
    mkdir -p "$TMPDIR/comet" "$TMPDIR/orchestrator"
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register comet --dir "$TMPDIR/comet" --agent codex >/dev/null
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register orchestrator --dir "$TMPDIR/orchestrator" --agent codex >/dev/null

    local out rc
    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send missing --from orchestrator -- "hello" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected unknown recipient to fail"
    assert_contains "$out" "Unknown recipient"

    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from missing -- "hello" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected unknown sender to fail"
    assert_contains "$out" "Unknown sender"

    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --json -- "hello" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected JSON send without sender to fail"
    assert_contains "$out" '"code": "missing-identity"'

    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send missing --from missing --allow-unknown --json -- "hello")"
    assert_contains "$out" '"unknown_peer": true'

    out="$(CCTRL_DATA_DIR="$data" CCTRL_PEER=orchestrator "$ROOT/cctrl" peer send comet --json -- "from env")"
    assert_contains "$out" '"from": "orchestrator"'
}

test_peer_mailbox_concurrency_and_stale_lock() {
    local data="$TMPDIR/mailbox-concurrency-data"
    setup_mailbox_peers "$data"

    local delivered_id
    delivered_id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "to ack" | jq -r '.id')"
    mark_message_delivered "$data/messages.jsonl" "$delivered_id"

    local -a pids=()
    local i pid failed=0
    for i in 1 2 3 4 5 6 7 8 9 10; do
        CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "parallel $i" >/dev/null &
        pids+=("$!")
    done
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer ack "$delivered_id" --as comet >/dev/null &
    pids+=("$!")

    for pid in "${pids[@]}"; do
        wait "$pid" || failed=1
    done
    [[ "$failed" -eq 0 ]] || fail "parallel mailbox operations failed"

    jq empty "$data/messages.jsonl" >/dev/null
    local count acked_count
    count="$(jq -s 'length' "$data/messages.jsonl")"
    [[ "$count" -eq 11 ]] || fail "expected 11 mailbox records after parallel operations, got $count"
    acked_count="$(jq -s --arg id "$delivered_id" '[.[] | select(.id == $id and .status == "acked")] | length' "$data/messages.jsonl")"
    [[ "$acked_count" -eq 1 ]] || fail "expected delivered message to be acked after parallel operations"

    local stale_data="$TMPDIR/mailbox-stale-lock-data"
    mkdir -p "$stale_data/messages.jsonl.lock"
    printf '999999\n' > "$stale_data/messages.jsonl.lock/pid"
    out="$(CCTRL_MAILBOX_LOCK_KIND=dir CCTRL_DATA_DIR="$stale_data" "$ROOT/cctrl" peer send ghost --from phantom --allow-unknown --json -- "stale lock")"
    assert_contains "$out" '"status": "queued"'
    [[ ! -d "$stale_data/messages.jsonl.lock" ]] || fail "expected stale lock directory to be reclaimed and released"
}

test_peer_polling_json_contracts() {
    local data="$TMPDIR/polling-json-data"
    setup_mailbox_peers "$data"

    local out id check recv shown acked rc body_file
    out="$(printf 'hello from stdin\n' | CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --body-file - --json)"
    printf '%s\n' "$out" | jq -e '.body == "hello from stdin\n"' >/dev/null || fail "expected stdin body to preserve trailing newline"
    assert_contains "$out" '"status": "queued"'
    assert_not_contains "$out" $'\033['
    id="$(printf '%s\n' "$out" | jq -r '.id')"

    check="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer check --as comet --json)"
    assert_contains "$check" '"peer": "comet"'
    assert_contains "$check" '"queued": 1'
    assert_contains "$check" '"delivered_unacked": 0'
    assert_contains "$check" '"oldest_queued_age_seconds":'
    assert_not_contains "$check" $'\033['
    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer check --as comet --json --exit-on-empty 2>&1)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected check --exit-on-empty to return 0 while messages are available, got $rc"

    recv="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer recv --as comet --json)"
    assert_contains "$recv" '"empty": false'
    printf '%s\n' "$recv" | jq -e '.message.body == "hello from stdin\n"' >/dev/null || fail "expected recv to preserve stdin body"
    assert_contains "$recv" '"status": "delivered"'
    assert_not_contains "$recv" '"status": "acked"'
    shown="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer show "$id" --json)"
    assert_contains "$shown" '"status": "delivered"'
    assert_contains "$shown" '"delivered_at": "'
    assert_not_contains "$shown" '"acked_at": "'

    check="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer check --as comet --json)"
    assert_contains "$check" '"queued": 0'
    assert_contains "$check" '"delivered_unacked": 1'

    acked="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer ack "$id" --as comet --json)"
    assert_contains "$acked" '"status": "acked"'
    assert_contains "$acked" '"message": {'
    assert_not_contains "$acked" $'\033['

    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer check --as comet --json --exit-on-empty 2>&1)" || rc=$?
    [[ "$rc" -eq 2 ]] || fail "expected check --exit-on-empty to return 2 for empty mailbox, got $rc"
    assert_contains "$out" '"queued": 0'
    assert_contains "$out" '"delivered_unacked": 0'

    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer recv --as comet --json)"
    assert_contains "$out" '"empty": true'
    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer recv --as comet --json --exit-on-empty 2>&1)" || rc=$?
    [[ "$rc" -eq 2 ]] || fail "expected recv --exit-on-empty to return 2 for empty mailbox, got $rc"
    assert_contains "$out" '"empty": true'

    body_file="$data/body.txt"
    printf 'file body\nsecond line\n' > "$body_file"
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --body-file "$body_file" --json)"
    printf '%s\n' "$out" | jq -e '.body == "file body\nsecond line\n"' >/dev/null || fail "expected file body to preserve content"
}

test_peer_polling_identity_and_errors() {
    local data="$TMPDIR/polling-identity-data"
    setup_mailbox_peers "$data"

    local out rc
    out="$(printf 'from env' | CCTRL_DATA_DIR="$data" CCTRL_PEER=orchestrator "$ROOT/cctrl" peer send comet --body-file - --json)"
    assert_contains "$out" '"from": "orchestrator"'
    out="$(CCTRL_DATA_DIR="$data" CCTRL_PEER=comet "$ROOT/cctrl" peer recv --json)"
    assert_contains "$out" '"body": "from env"'
    assert_contains "$out" '"status": "delivered"'

    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer check --as missing --json 2>&1)" || rc=$?
    [[ "$rc" -eq 66 ]] || fail "expected unknown peer to exit 66, got $rc"
    assert_contains "$out" '"code": "unknown-peer"'
    assert_not_contains "$out" $'\033['

    printf '{not-json\n' > "$data/messages.jsonl"
    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer check --as comet --json 2>&1)" || rc=$?
    [[ "$rc" -eq 65 ]] || fail "expected corrupt mailbox to exit 65, got $rc"
    assert_contains "$out" '"code": "mailbox-corrupt"'
    assert_not_contains "$out" $'\033['

    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer recv --as comet --json 2>&1)" || rc=$?
    [[ "$rc" -eq 65 ]] || fail "expected corrupt mailbox recv to exit 65, got $rc"
    assert_contains "$out" '"code": "mailbox-corrupt"'
}

test_peer_mcp_bridge_stdio() {
    local data="$TMPDIR/mcp-bridge-data"
    setup_mailbox_peers "$data"
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer alias comet halley >/dev/null

    local out rc send_req recv_req show_req bad_req extra_req alias_req message_id shown
    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp 2>&1 </dev/null)" || rc=$?
    [[ "$rc" -eq 66 ]] || fail "expected peer mcp without identity to exit 66, got $rc"
    assert_contains "$out" "needs --as <peer> or CCTRL_PEER"

    out="$(
        {
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
            printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
            printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
        } | CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as comet
    )"
    # Assert tool names by MEMBERSHIP, never an exact count/set: plan 025 adds
    # `peer_overview` and pending plan 011 may independently add `say_peer` to the
    # same TOOLS list, so a hardcoded total would be brittle. All 8 original names
    # must remain present (renaming breaks the ~16 live sessions with the current
    # list loaded), plus the new `peer_overview` entry point.
    printf '%s\n' "$out" | jq -s -e '
      length == 2
      and .[0].id == 1
      and .[1].id == 2
      and ([.[1].result.tools[].name]) as $names
      | (["whoami","list_peers","resolve_peer","send_message","check_messages","recv_message","show_message","ack_message","peer_overview"] | all(. as $n | $names | index($n) != null))
    ' >/dev/null || fail "expected MCP tools/list to advertise all 8 original tools plus peer_overview by name"

    local overview_req
    overview_req="$(jq -cn '{jsonrpc:"2.0",id:9,method:"tools/call",params:{name:"peer_overview",arguments:{}}}')"
    out="$(printf '%s\n' "$overview_req" | CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as comet)"
    printf '%s\n' "$out" | jq -e '
      .result.structuredContent.ok == true
      and .result.structuredContent.data.identity.name == "comet"
      and (.result.structuredContent.data.peers | type == "array")
      and (.result.structuredContent.data.mailbox | has("queued") and has("delivered_unacked") and has("oldest_queued_age_seconds"))
    ' >/dev/null || fail "expected MCP peer_overview to return identity + peers + mailbox sections"

    send_req="$(jq -cn --arg to comet --arg subject "MCP" --arg body $'hello from mcp\n' '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"send_message",arguments:{to:$to,subject:$subject,body:$body}}}')"
    out="$(printf '%s\n' "$send_req" | CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as orchestrator)"
    printf '%s\n' "$out" | jq -e '.result.structuredContent.ok == true and .result.structuredContent.data.from == "orchestrator" and .result.structuredContent.data.to == "comet" and .result.structuredContent.data.body == "hello from mcp\n"' >/dev/null || fail "expected MCP send_message to queue body from server identity"
    message_id="$(printf '%s\n' "$out" | jq -r '.result.structuredContent.data.id')"

    show_req="$(jq -cn --arg id "$message_id" '{jsonrpc:"2.0",id:8,method:"tools/call",params:{name:"show_message",arguments:{id:$id}}}')"
    out="$(printf '%s\n' "$show_req" | CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as comet)"
    printf '%s\n' "$out" | jq -e --arg id "$message_id" '.result.structuredContent.ok == true and .result.structuredContent.data.id == $id' >/dev/null || fail "expected MCP show_message to allow addressed peer"
    out="$(printf '%s\n' "$show_req" | CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as wrong-peer)"
    printf '%s\n' "$out" | jq -e '.result.isError == true and .result.structuredContent.error.code == "forbidden"' >/dev/null || fail "expected MCP show_message to reject unrelated peer"

    recv_req="$(jq -cn '{jsonrpc:"2.0",id:4,method:"tools/call",params:{name:"recv_message",arguments:{}}}')"
    out="$(printf '%s\n' "$recv_req" | CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as comet)"
    printf '%s\n' "$out" | jq -e '.result.structuredContent.ok == true and .result.structuredContent.data.empty == false and .result.structuredContent.data.message.body == "hello from mcp\n" and .result.structuredContent.data.message.status == "delivered"' >/dev/null || fail "expected MCP recv_message to deliver queued message"
    shown="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer show "$message_id" --json)"
    printf '%s\n' "$shown" | jq -e '.status == "delivered" and .acked_at == null' >/dev/null || fail "expected MCP recv side effect to match CLI delivered state"

    bad_req="$(jq -cn '{jsonrpc:"2.0",id:5,method:"tools/call",params:{name:"send_message",arguments:{to:"comet",from:"wrong",body:"bad"}}}')"
    out="$(printf '%s\n' "$bad_req" | CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as orchestrator)"
    printf '%s\n' "$out" | jq -e '.result.isError == true and .result.structuredContent.ok == false and .result.structuredContent.error.code == "validation"' >/dev/null || fail "expected MCP tools to reject from/as arguments"

    extra_req="$(jq -cn '{jsonrpc:"2.0",id:6,method:"tools/call",params:{name:"whoami",arguments:{unexpected:"value"}}}')"
    out="$(printf '%s\n' "$extra_req" | CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as orchestrator)"
    printf '%s\n' "$out" | jq -e '.result.isError == true and .result.structuredContent.ok == false and .result.structuredContent.error.message == "Unexpected argument: unexpected"' >/dev/null || fail "expected MCP tools to reject unexpected arguments"

    alias_req="$(jq -cn --arg to halley --arg body "via alias" '{jsonrpc:"2.0",id:7,method:"tools/call",params:{name:"send_message",arguments:{to:$to,body:$body}}}')"
    out="$(printf '%s\n' "$alias_req" | CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as orchestrator)"
    printf '%s\n' "$out" | jq -e '.result.structuredContent.ok == true and .result.structuredContent.data.to == "comet"' >/dev/null || fail "expected MCP send_message to canonicalize recipient aliases through CLI"
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer check --as comet --json)"
    printf '%s\n' "$out" | jq -e '.queued == 1 and .delivered_unacked == 1' >/dev/null || fail "expected alias-addressed MCP message to be visible to canonical peer"
}

test_peer_overview() {
    # plan 025: `cctrl peer overview` answers who-am-I / who-can-I-reach /
    # do-I-have-mail from a SINGLE session enumeration. Assert all three sections,
    # single enumeration via the fake-tmux list-sessions COUNTER (never timing),
    # and the derived_skipped passthrough when tmux is unavailable.
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/overview-data"
    local log="$TMPDIR/overview-enum.log"
    setup_delivery_peers "$data"   # comet(session TMUX--comet), orchestrator(none), offline(none)

    # Queue a message to comet so the mailbox summary is non-trivial.
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "orient me" >/dev/null

    # (1) All three sections present, correct identity + mailbox counts.
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_FAKE_SESSIONS="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer overview --as comet --json)"
    printf '%s\n' "$out" | jq -e '
        .identity.name == "comet"
        and (.peers | type == "array")
        and .mailbox.queued == 1
        and .mailbox.delivered_unacked == 0
        and (.mailbox | has("oldest_queued_age_seconds"))
    ' >/dev/null || fail "expected peer overview to return identity + peers + mailbox in one call"

    # (2) SINGLE enumeration: exactly one tmux list-sessions for the whole command.
    # Counting the enumeration proves the code path; timing would prove nothing.
    : > "$log"
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_SESSIONS="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer overview --as comet --json >/dev/null
    local count
    count="$(grep -c 'TMUX list-sessions' "$log" || true)"
    [[ "$count" -eq 1 ]] || fail "expected exactly 1 session enumeration for peer overview, got $count"

    # (3) derived_skipped passthrough: with tmux unavailable the manual identity and
    # mailbox counts still resolve, no derived peers appear, and the skip reason is
    # surfaced instead of failing the whole call.
    out="$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer overview --as comet --json)"
    printf '%s\n' "$out" | jq -e '
        .derived_skipped == true
        and .derived_skip_reason == "tmux unavailable"
        and .identity.name == "comet"
        and .mailbox.queued == 1
        and ([.peers[] | select(.source == "derived")] | length) == 0
    ' >/dev/null || fail "expected peer overview to pass through derived_skipped with identity + mailbox intact"

    echo "ok: peer overview — one enumeration, three sections, derived_skipped passthrough"
}

test_peer_send_deliver_outcomes() {
    # plan 027: `peer send --deliver` classifies into five named outcomes with the
    # exact exit codes the plan specifies.
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/send-deliver-outcomes-data"
    local log="$TMPDIR/send-deliver-outcomes.log"; : > "$log"
    setup_delivery_peers "$data"   # comet(session TMUX--comet), orchestrator(none), offline(none)
    local out rc

    # (1) live tmux peer -> sent-and-nudged, exit 0.
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --deliver --json -- "live one")" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected live nudge to exit 0, got $rc"
    printf '%s\n' "$out" | jq -e '.ok == true and .outcome == "sent-and-nudged" and .delivered == true and .to == "comet" and (.message_id | startswith("msg_"))' >/dev/null || fail "expected sent-and-nudged outcome"

    # (2) mailbox-only peer -> sent-and-queued, exit 0.
    rc=0
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send orchestrator --from comet --deliver --json -- "queue one")" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected mailbox-only send-deliver to exit 0, got $rc"
    printf '%s\n' "$out" | jq -e '.ok == true and .outcome == "sent-and-queued" and .delivered == false and (.message_id | startswith("msg_"))' >/dev/null || fail "expected sent-and-queued outcome"

    # (3) busy/modal pane -> sent-but-deferred, exit non-zero, retry hint (deliver only).
    local codex_modal
    codex_modal="$(printf '%s\n' '● working' $'│ Allow Codex to run `npm test`? │' '│ No, and tell Codex what to do differently │')"
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_FAKE_HAS_SESSION="TMUX--comet" TMUX_FAKE_CAPTURE_PANE="$codex_modal" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --deliver --json -- "busy one")" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected sent-but-deferred to exit non-zero"
    printf '%s\n' "$out" | jq -e '.ok == false and .outcome == "sent-but-deferred" and (.message_id | startswith("msg_"))' >/dev/null || fail "expected sent-but-deferred outcome"
    printf '%s\n' "$out" | jq -e '.hint | contains("cctrl peer deliver comet")' >/dev/null || fail "expected deferred hint to retry delivery only"

    # (4) paste failure -> sent-but-undelivered, message still queued, exit non-zero.
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" TMUX_FAKE_PASTE_FAIL=1 CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --deliver --json -- "paste fail one")" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected sent-but-undelivered to exit non-zero"
    printf '%s\n' "$out" | jq -e '.ok == false and .outcome == "sent-but-undelivered" and (.message_id | startswith("msg_"))' >/dev/null || fail "expected sent-but-undelivered outcome"
    printf '%s\n' "$out" | jq -e '.hint | contains("cctrl peer deliver comet")' >/dev/null || fail "expected undelivered hint to retry delivery only"
    local pf_id; pf_id="$(printf '%s\n' "$out" | jq -r '.message_id')"
    jq -s -e --arg id "$pf_id" 'any(.[]; .id == $id and .status == "queued")' "$data/messages.jsonl" >/dev/null || fail "expected paste-failed reply to stay queued"

    # (5) send failure -> send-failed, nothing queued, exit non-zero.
    local before after
    before="$(wc -l < "$data/messages.jsonl" | tr -d ' ')"
    rc=0
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send ghostnobody --from orchestrator --deliver --json -- "nope")" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected send-failed to exit non-zero"
    printf '%s\n' "$out" | jq -e '.ok == false and .outcome == "send-failed"' >/dev/null || fail "expected send-failed outcome"
    after="$(wc -l < "$data/messages.jsonl" | tr -d ' ')"
    [[ "$before" == "$after" ]] || fail "expected send-failed to queue nothing (was $before, now $after)"

    echo "ok: peer send --deliver classifies all five outcomes with correct exit codes"
}

test_peer_reply_core() {
    # plan 027: reply-by-message-id (happy, legacy, unauthorized, user, dead sender,
    # delivery failure keeps queued) plus plain `peer send` byte-identical guard.
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/reply-core-data"
    local log="$TMPDIR/reply-core.log"; : > "$log"
    setup_delivery_peers "$data"   # comet(session TMUX--comet), orchestrator(none), offline(none)
    local out rc id

    # (a) happy path: orchestrator replies to comet's message; comet is live -> nudged + acked.
    id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send orchestrator --from comet --json -- "please review" | jq -r '.id')"
    mark_message_delivered "$data/messages.jsonl" "$id"
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer reply "$id" --as orchestrator --json -- "on it")" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected happy reply to exit 0, got $rc"
    printf '%s\n' "$out" | jq -e '.ok == true and .outcome == "sent-and-nudged" and .to == "comet" and .from == "orchestrator" and .body == "on it"' >/dev/null || fail "expected happy reply nudged to comet"
    printf '%s\n' "$out" | jq -e '.ack.state == "acked"' >/dev/null || fail "expected reply to ack the original by default"
    printf '%s\n' "$out" | jq -e '.note | contains("session is gone")' >/dev/null || fail "expected reply to note the session-derived-address limitation"
    [[ "$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer show "$id" --json | jq -r '.status')" == "acked" ]] || fail "expected original acked after reply"
    jq -s -e 'any(.[]; .from == "orchestrator" and .to == "comet" and .body == "on it")' "$data/messages.jsonl" >/dev/null || fail "expected a new reply message queued"

    # (b) legacy message with no sender: recipient falls back to bare `from`.
    printf '%s\n' '{"id":"msg_legacy_reply","from":"comet","to":"orchestrator","status":"delivered","subject":"legacy","body":"old","created_at":"2026-06-13T00:00:00Z","updated_at":"2026-06-13T00:00:00Z","delivered_at":"2026-06-13T00:00:00Z","acked_at":null,"nudge_count":0,"last_nudge_at":null,"last_nudge_error":null,"history":[]}' >> "$data/messages.jsonl"
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer reply msg_legacy_reply --as orchestrator --json -- "legacy reply")" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected legacy reply to succeed, got $rc"
    printf '%s\n' "$out" | jq -e '.to == "comet" and .outcome == "sent-and-nudged"' >/dev/null || fail "expected legacy reply to derive recipient from bare from"

    # (c) unauthorized: reply from a peer the message is not addressed to.
    local id2
    id2="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send orchestrator --from comet --json -- "second" | jq -r '.id')"
    mark_message_delivered "$data/messages.jsonl" "$id2"
    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer reply "$id2" --as comet -- "nope" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected unauthorized reply to fail"
    assert_contains "$out" "not addressed to 'comet'"

    # (d) user-sender refusal.
    printf '%s\n' '{"id":"msg_from_user","from":"user","to":"orchestrator","status":"delivered","subject":"hi","body":"human note","sender":{"name":"user","label":"user"},"created_at":"2026-06-13T00:00:00Z","updated_at":"2026-06-13T00:00:00Z","delivered_at":"2026-06-13T00:00:00Z","acked_at":null,"nudge_count":0,"last_nudge_at":null,"last_nudge_error":null,"history":[]}' >> "$data/messages.jsonl"
    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer reply msg_from_user --as orchestrator -- "reply" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected user-sender reply to fail"
    assert_contains "$out" "not an addressable peer"

    # (e) dead-sender refusal: sender no longer resolves.
    printf '%s\n' '{"id":"msg_from_ghost","from":"ghost","to":"orchestrator","status":"delivered","subject":"hi","body":"gone","sender":{"name":"ghost","label":"ghost"},"created_at":"2026-06-13T00:00:00Z","updated_at":"2026-06-13T00:00:00Z","delivered_at":"2026-06-13T00:00:00Z","acked_at":null,"nudge_count":0,"last_nudge_at":null,"last_nudge_error":null,"history":[]}' >> "$data/messages.jsonl"
    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer reply msg_from_ghost --as orchestrator -- "reply" 2>&1)" || rc=$?
    [[ "$rc" -eq 66 ]] || fail "expected dead-sender reply to exit 66, got $rc"
    assert_contains "$out" "no longer resolves"

    # (f) delivery failure keeps the reply queued and exits non-zero; original still acked.
    local id3
    id3="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send orchestrator --from comet --json -- "third" | jq -r '.id')"
    mark_message_delivered "$data/messages.jsonl" "$id3"
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" TMUX_FAKE_PASTE_FAIL=1 CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer reply "$id3" --as orchestrator --json -- "will fail delivery")" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected delivery-failure reply to exit non-zero"
    printf '%s\n' "$out" | jq -e '.outcome == "sent-but-undelivered" and .ack.state == "acked"' >/dev/null || fail "expected undelivered reply to still ack the original"
    local rid; rid="$(printf '%s\n' "$out" | jq -r '.message_id')"
    jq -s -e --arg id "$rid" 'any(.[]; .id == $id and .status == "queued")' "$data/messages.jsonl" >/dev/null || fail "expected failed-delivery reply to stay queued"

    # (g) plain `peer send` (no --deliver) stays byte-identical: no outcome/delivered keys.
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "plain")"
    printf '%s\n' "$out" | jq -e '.status == "queued" and (has("outcome") | not) and (has("delivered") | not)' >/dev/null || fail "expected plain send output unchanged (no --deliver fields)"
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator -- "plain human")"
    assert_contains "$out" "Queued message:"

    echo "ok: peer reply happy/legacy/auth/user/dead/delivery-failure + plain send byte-identical"
}

test_peer_reply_ack_and_refusals() {
    # plan 027: ack default / --no-ack / ack-failure isolation, plus queued-original
    # and --allow-unknown+--deliver refusals.
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/reply-ack-data"
    local log="$TMPDIR/reply-ack.log"; : > "$log"
    setup_delivery_peers "$data"
    local out rc id

    # --no-ack leaves the original delivered.
    id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send orchestrator --from comet --json -- "a" | jq -r '.id')"
    mark_message_delivered "$data/messages.jsonl" "$id"
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer reply "$id" --as orchestrator --no-ack --json -- "no ack reply")" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected --no-ack reply to exit 0"
    printf '%s\n' "$out" | jq -e '.ack.state == "skipped"' >/dev/null || fail "expected --no-ack to skip ack"
    [[ "$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer show "$id" --json | jq -r '.status')" == "delivered" ]] || fail "expected --no-ack to leave original delivered"

    # ack failure is reported but does not fail the reply or change its exit status.
    # A non-queued, non-ackable original (status "blocked") passes reply auth but
    # cannot be acked; the reply still succeeds (nudged, exit 0).
    printf '%s\n' '{"id":"msg_blocked","from":"comet","to":"orchestrator","status":"blocked","subject":"b","body":"blocked one","sender":{"name":"comet","label":"comet"},"created_at":"2026-06-13T00:00:00Z","updated_at":"2026-06-13T00:00:00Z","delivered_at":null,"acked_at":null,"nudge_count":0,"last_nudge_at":null,"last_nudge_error":null,"history":[]}' >> "$data/messages.jsonl"
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer reply msg_blocked --as orchestrator --json -- "reply anyway")" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected ack-failure reply to still exit 0, got $rc"
    printf '%s\n' "$out" | jq -e '.outcome == "sent-and-nudged" and .ack.state == "failed" and (.ack.error | length > 0)' >/dev/null || fail "expected ack failure reported without failing the reply"

    # queued-original refusal: cannot reply to mail not yet received.
    id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send orchestrator --from comet --json -- "still queued" | jq -r '.id')"
    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer reply "$id" --as orchestrator -- "reply" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected reply to queued original to fail"
    assert_contains "$out" "receive it first (cctrl peer recv"

    # --allow-unknown + --deliver is rejected.
    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --allow-unknown --deliver --json -- "x" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected --allow-unknown + --deliver to be rejected"
    printf '%s\n' "$out" | jq -e '.error.message | contains("cannot be combined with --deliver")' >/dev/null || fail "expected explicit allow-unknown+deliver rejection"

    echo "ok: reply ack default/--no-ack/ack-failure isolation + queued & allow-unknown refusals"
}

test_peer_reply_single_enumeration() {
    # plan 027 (7d): one reply performs exactly ONE session enumeration
    # (tmux list-sessions), not one per read/send/deliver/ack step. Count
    # list-sessions specifically — has-session/capture/paste are legitimate.
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/reply-enum-data"
    local log="$TMPDIR/reply-enum.log"
    setup_delivery_peers "$data"
    local id
    id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send orchestrator --from comet --json -- "enumerate" | jq -r '.id')"
    mark_message_delivered "$data/messages.jsonl" "$id"

    : > "$log"
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer reply "$id" --as orchestrator --json -- "reply" >/dev/null
    local count
    count="$(grep -c 'TMUX list-sessions' "$log" || true)"
    [[ "$count" -eq 1 ]] || fail "expected exactly 1 session enumeration for one reply, got $count"

    echo "ok: one reply enumerates sessions exactly once (cached resolver)"
}

test_peer_mcp_send_deliver_outcomes() {
    # plan 027 (7e): the MCP send_message surface exposes the SAME five states as
    # the CLI, and its tool description no longer says "Queue a message". Only
    # send-failed maps to ok:false; every durably-queued state is ok:true with an
    # `outcome` and the message id.
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/mcp-deliver-data"
    setup_delivery_peers "$data"   # comet(session TMUX--comet), orchestrator(none), offline(none)
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register deadsess --dir "$TMPDIR/comet" --agent codex --session TMUX--gone >/dev/null

    local list_out send_req out
    # description no longer claims to only "Queue a message"; mentions delivery.
    list_out="$(printf '%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
        '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
        | CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as orchestrator)"
    printf '%s\n' "$list_out" | jq -s -e '
      (.[] | select(.id == 2) | .result.tools[] | select(.name == "send_message") | .description) as $d
      | ($d | contains("Queue a message") | not) and ($d | test("deliver"))
    ' >/dev/null || fail "expected send_message description updated to mention delivery"

    mcp_send() {
        # $1=recipient ; emits the tools/call request line
        local to="$1"
        send_req="$(jq -cn --arg to "$to" --arg body "hi $to" '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"send_message",arguments:{to:$to,body:$body}}}')"
        printf '%s\n' "$send_req"
    }

    # sent-and-nudged (live comet).
    out="$(mcp_send comet | PATH="$TMPDIR:$PATH" TMUX_LOG="$TMPDIR/mcp-deliver.log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as orchestrator)"
    printf '%s\n' "$out" | jq -e '.result.isError != true and .result.structuredContent.ok == true and .result.structuredContent.data.outcome == "sent-and-nudged" and (.result.structuredContent.data.id | startswith("msg_"))' >/dev/null || fail "expected MCP sent-and-nudged"

    # sent-and-queued (mailbox-only offline).
    out="$(mcp_send offline | PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as orchestrator)"
    printf '%s\n' "$out" | jq -e '.result.isError != true and .result.structuredContent.ok == true and .result.structuredContent.data.outcome == "sent-and-queued"' >/dev/null || fail "expected MCP sent-and-queued"

    # sent-but-deferred (busy comet pane).
    local codex_modal
    codex_modal="$(printf '%s\n' '│ Allow Codex to run x? │' '│ No, and tell Codex what to do differently │')"
    out="$(mcp_send comet | PATH="$TMPDIR:$PATH" TMUX_FAKE_HAS_SESSION="TMUX--comet" TMUX_FAKE_CAPTURE_PANE="$codex_modal" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as orchestrator)"
    printf '%s\n' "$out" | jq -e '.result.isError != true and .result.structuredContent.ok == true and .result.structuredContent.data.outcome == "sent-but-deferred" and (.result.structuredContent.data.id | startswith("msg_"))' >/dev/null || fail "expected MCP sent-but-deferred as ok:true"

    # sent-but-undelivered (tmux-capable peer, session gone).
    out="$(mcp_send deadsess | PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as orchestrator)"
    printf '%s\n' "$out" | jq -e '.result.isError != true and .result.structuredContent.ok == true and .result.structuredContent.data.outcome == "sent-but-undelivered" and (.result.structuredContent.data.id | startswith("msg_"))' >/dev/null || fail "expected MCP sent-but-undelivered as ok:true"

    # send-failed (unknown recipient) -> ok:false / isError.
    out="$(mcp_send ghostnobody | PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as orchestrator)"
    printf '%s\n' "$out" | jq -e '.result.isError == true and .result.structuredContent.ok == false' >/dev/null || fail "expected MCP send-failed as ok:false"

    echo "ok: MCP send_message exposes all five outcomes; only send-failed is ok:false"
}

test_peer_deliver_tmux_nudge_lifecycle() {
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/deliver-nudge-data"
    local log="$TMPDIR/deliver-nudge-tmux.log"
    : > "$log"
    setup_delivery_peers "$data"

    local out before after messages
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "secret body A" >/dev/null
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "secret body B" >/dev/null

    before="$(cat "$data/messages.jsonl")"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver comet --dry-run)"
    assert_contains "$out" "[cctrl] 2 new peer message(s) for comet. Run: cctrl peer recv --as comet --json"
    after="$(cat "$data/messages.jsonl")"
    [[ "$before" == "$after" ]] || fail "expected dry-run delivery to leave mailbox unchanged"
    assert_not_contains "$(cat "$log")" "load-buffer"

    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-13T00:00:01Z" "$ROOT/cctrl" peer deliver comet --json)"
    printf '%s\n' "$out" | jq -e '.results[0].status == "nudged" and .results[0].queued == 2 and .results[0].submitted == true' >/dev/null || fail "expected JSON nudged result"
    assert_contains "$(cat "$log")" "load-buffer -b cctrl-nudge-comet-"
    assert_contains "$(cat "$log")" "paste-buffer -b cctrl-nudge-comet-"
    assert_contains "$(cat "$log")" "send-keys -t TMUX--comet Enter"
    assert_contains "$(cat "$log")" "delete-buffer -b cctrl-nudge-comet-"
    assert_not_contains "$(cat "$log")" "secret body A"
    assert_not_contains "$(cat "$log")" "secret body B"

    messages="$(jq -s '.' "$data/messages.jsonl")"
    printf '%s\n' "$messages" | jq -e '
      length == 2
      and all(.[]; .status == "queued")
      and all(.[]; .nudge_count == 1)
      and all(.[]; .last_nudge_at == "2026-06-13T00:00:01Z")
      and all(.[]; .last_nudge_error == null)
      and all(.[]; any(.history[]; .event == "nudge" and .ok == true and .adapter == "tmux"))
    ' >/dev/null || fail "expected successful nudge metadata without status transition"
}

test_peer_deliver_addressee_guard_replaced_occupant() {
    # plan 032: a name's tmux slot can be recycled to a different session. Mail
    # queued for the PRIOR occupant must never reach the new one. The current
    # occupant (metadata created_at 13:00) post-dates a stale message (12:00) but
    # not a fresh one (14:00): the stale is blocked (addressee-replaced), the
    # fresh still delivers. Absence and unknown_peer fail open; ambiguity blocks.
    local bin="$TMPDIR/guardbin" data="$TMPDIR/guard-data"
    mkdir -p "$bin" "$data"
    make_fake_tmux "$bin/tmux"
    mkdir -p "$CCTRL_SESSION_METADATA_DIR"
    cat > "$CCTRL_SESSION_METADATA_DIR/TMUX--recycled.json" <<'JSON'
{"name":"TMUX--recycled","agent":"claude","created_at":"2026-07-20T13:00:00Z","cctrl_managed":true,"host":"local","cwd":"/tmp/x","target":"/tmp/x","target_kind":"dir"}
JSON
    cat > "$data/messages.jsonl" <<'JSON'
{"id":"msg_stale","from":"orchestrator","to":"TMUX--recycled","status":"queued","subject":"hold","body":"SECRET do NOT run against corp","created_at":"2026-07-20T12:00:00Z","updated_at":"2026-07-20T12:00:00Z","history":[]}
{"id":"msg_fresh","from":"orchestrator","to":"TMUX--recycled","status":"queued","subject":"ok","body":"fresh body ok","created_at":"2026-07-20T14:00:00Z","updated_at":"2026-07-20T14:00:00Z","history":[]}
JSON
    local out log="$TMPDIR/guard-tmux.log"; : > "$log"

    # Delivery: stale -> blocked (addressee-replaced), fresh -> nudged. Nudge
    # must not leak the stale body.
    out="$(PATH="$bin:$PATH" TMUX_LOG="$log" TMUX_FAKE_SESSIONS="TMUX--recycled" TMUX_FAKE_HAS_SESSION="TMUX--recycled" TMUX_FAKE_PANE_PID=9001 CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-07-20T15:00:00Z" "$ROOT/cctrl" peer deliver TMUX--recycled --json)"
    jq -s -e 'any(.[]; .id=="msg_stale" and .status=="blocked" and .blocked_reason=="addressee-replaced")' "$data/messages.jsonl" >/dev/null || fail "expected stale message blocked as addressee-replaced"
    jq -s -e 'any(.[]; .id=="msg_fresh" and .status=="queued")' "$data/messages.jsonl" >/dev/null || fail "expected fresh message to stay deliverable"
    printf '%s\n' "$out" | jq -e '.results[0].queued == 1' >/dev/null || fail "expected queued count to exclude the blocked message"
    assert_not_contains "$(cat "$log")" "SECRET do NOT run against corp"

    # recv as the current occupant returns ONLY the fresh message, never the
    # stale one meant for the previous occupant of this name.
    out="$(PATH="$bin:$PATH" TMUX_FAKE_SESSIONS="TMUX--recycled" TMUX_FAKE_HAS_SESSION="TMUX--recycled" TMUX_FAKE_PANE_PID=9001 CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer recv --as TMUX--recycled --json)"
    assert_contains "$out" '"id": "msg_fresh"'
    assert_not_contains "$out" "SECRET do NOT run against corp"

    # inbox as the occupant must not list the withheld message either.
    out="$(PATH="$bin:$PATH" TMUX_FAKE_SESSIONS="TMUX--recycled" TMUX_FAKE_HAS_SESSION="TMUX--recycled" TMUX_FAKE_PANE_PID=9001 CCTRL_DATA_DIR="$data" CCTRL_PEER=TMUX--recycled "$ROOT/cctrl" peer inbox --as TMUX--recycled --status blocked,queued,delivered --json 2>/dev/null || true)"
    assert_not_contains "$out" "msg_stale"
    echo "ok: replaced-occupant mail is blocked; fresh mail for the new occupant still flows"
}

test_peer_deliver_busy_no_submit_and_inline() {
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/deliver-busy-data"
    local log="$TMPDIR/deliver-busy-tmux.log"
    : > "$log"
    setup_delivery_peers "$data"

    local out id inline_id messages codex_modal
    # A real Codex exec-approval modal (Codex CLI TUI): the "Allow Codex to run"
    # header plus the "tell Codex what to do differently" option line. No "❯"
    # cursor — Codex renders the selection in reverse-video.
    codex_modal="$(printf '%s\n' \
        '● Running the test suite next.' \
        '' \
        '╭──────────────────────────────────────────────────╮' \
        $'│ Allow Codex to run `npm test`?                   │' \
        '│                                                  │' \
        '│ > Yes, proceed                                   │' \
        "│   Yes, and don't ask again for this command      │" \
        '│   No, and tell Codex what to do differently      │' \
        '╰──────────────────────────────────────────────────╯')"
    id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "queued for nudge" | jq -r '.id')"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" TMUX_FAKE_CAPTURE_PANE="$codex_modal" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver comet --json)"
    printf '%s\n' "$out" | jq -e '.results[0].status == "deferred" and .results[0].reason == "modal prompt visible"' >/dev/null || fail "expected busy pane deferral"
    assert_not_contains "$(cat "$log")" "paste-buffer"
    messages="$(jq -s '.' "$data/messages.jsonl")"
    printf '%s\n' "$messages" | jq -e '.[0].status == "queued" and .[0].nudge_count == 0 and .[0].last_nudge_at == null' >/dev/null || fail "expected deferred message to remain queued without nudge metadata"

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-13T00:00:02Z" "$ROOT/cctrl" peer deliver comet --json --no-submit)"
    printf '%s\n' "$out" | jq -e '.results[0].status == "nudged" and .results[0].submitted == false' >/dev/null || fail "expected --no-submit nudge"
    assert_contains "$(cat "$log")" "paste-buffer -b cctrl-nudge-comet-"
    assert_not_contains "$(cat "$log")" "send-keys -t TMUX--comet Enter"

    inline_id="$(printf 'inline body\n' | CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --body-file - --json | jq -r '.id')"
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver comet --inline "$inline_id" --json)"
    printf '%s\n' "$out" | jq -e '.results[0].status == "inline" and .results[0].inline == true and .results[0].submitted == false' >/dev/null || fail "expected inline paste result"
    # Envelope (plan 024): the pasted buffer now leads with a sender header and
    # the reply/ack commands, then the original body verbatim after `---`.
    assert_contains "$(cat "$log")" "[cctrl peer message] from: orchestrator (orchestrator)"
    assert_contains "$(cat "$log")" "inline body"
    assert_contains "$(cat "$log")" "paste-buffer -b cctrl-inline-comet-"
    assert_not_contains "$(cat "$log")" "send-keys -t TMUX--comet Enter"
}

test_peer_inline_envelope_and_ack() {
    # Plan 024, Task 6: the inline envelope carries the sender label/name/id and
    # the subject (when non-empty), the body arrives verbatim, and `peer ack` now
    # succeeds against an inline-delivered message (the queued->delivered
    # transition closes the old ack dead-end). A legacy message with no `sender`
    # object still yields a usable envelope from bare `from`; a `--from user`
    # message emits the human-operator variant and never `cctrl peer send user`.
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/env-data" log="$TMPDIR/env-tmux.log"
    setup_delivery_peers "$data"

    local id out buf
    id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --subject 'Hello there' --json -- "envelope body one" | jq -r '.id')"
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver comet --inline "$id" --json)"
    printf '%s\n' "$out" | jq -e '.results[0].status == "inline"' >/dev/null || fail "expected inline paste"
    buf="$(cat "$log")"
    assert_contains "$buf" "[cctrl peer message] from: orchestrator (orchestrator) · id: $id"
    assert_contains "$buf" "Subject: Hello there"
    assert_contains "$buf" "Reply:  cctrl peer reply $id --as comet --json"
    assert_contains "$buf" "Ack:    cctrl peer ack $id --as comet --json"
    assert_contains "$buf" "envelope body one"

    # queued -> delivered with delivered_at, and ack now succeeds.
    jq -c "select(.id==\"$id\")" "$data/messages.jsonl" | jq -e '.status == "delivered" and .delivered_at != null' >/dev/null || fail "expected inline delivery to mark message delivered"
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer ack "$id" --as comet --json | jq -e '.message.status == "acked"' >/dev/null || fail "expected ack to succeed after inline delivery"

    # Legacy message (pre-plan-023): strip .sender and confirm the envelope still
    # renders from the bare `from` string.
    local legacy_id
    legacy_id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "legacy body" | jq -r '.id')"
    jq -c "if .id==\"$legacy_id\" then del(.sender) else . end" "$data/messages.jsonl" > "$data/messages.jsonl.tmp"
    mv "$data/messages.jsonl.tmp" "$data/messages.jsonl"
    : > "$log"
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver comet --inline "$legacy_id" --json >/dev/null
    assert_contains "$(cat "$log")" "[cctrl peer message] from: orchestrator (orchestrator) · id: $legacy_id"

    # --from user: human-operator variant, no reply command, ack still emitted,
    # and never a `cctrl peer send user` line (which would fail resolution).
    local user_id
    user_id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from user --json -- "from a human" | jq -r '.id')"
    : > "$log"
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver comet --inline "$user_id" --json >/dev/null
    buf="$(cat "$log")"
    assert_contains "$buf" "Sender is the human operator"
    assert_contains "$buf" "Ack:    cctrl peer ack $user_id --as comet --json"
    assert_not_contains "$buf" "cctrl peer reply"
    assert_not_contains "$buf" "cctrl peer send"

    echo "ok: inline envelope carries sender + reply/ack, body verbatim, ack closes the loop, legacy + user variants"
}

test_peer_inline_envelope_reachability() {
    # Plan 024, Task 8: sender reachability is resolved at DELIVERY time via the
    # pure classifier (plan 027). live -> reply line; dead tmux session ->
    # SENDER IS NO LONGER LIVE and no reply command; mailbox-only (no tmux
    # capability) -> reply line (reachable); unresolvable sender -> unreachable.
    # The ack line appears in every branch, and no branch emits a bare send.
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/reach-data" log="$TMPDIR/reach-tmux.log"
    setup_delivery_peers "$data"
    mkdir -p "$TMPDIR/livesender" "$TMPDIR/deadsender" "$TMPDIR/tempsender"
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register livesender --dir "$TMPDIR/livesender" --agent codex --session TMUX--livesender >/dev/null
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register deadsender --dir "$TMPDIR/deadsender" --agent codex --session TMUX--deadsender >/dev/null
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register tempsender --dir "$TMPDIR/tempsender" --agent codex >/dev/null

    local id buf

    # live sender: its session is in the has-session set -> reply line emitted.
    id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from livesender --json -- "L" | jq -r '.id')"
    : > "$log"
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet TMUX--livesender" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver comet --inline "$id" --json >/dev/null
    buf="$(cat "$log")"
    assert_contains "$buf" "Reply:  cctrl peer reply $id --as comet --json"
    assert_contains "$buf" "Ack:    cctrl peer ack $id --as comet --json"
    assert_not_contains "$buf" "SENDER IS NO LONGER LIVE"
    assert_not_contains "$buf" "cctrl peer send"

    # dead tmux sender: has tmux capability + target but session not live.
    id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from deadsender --json -- "D" | jq -r '.id')"
    : > "$log"
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver comet --inline "$id" --json >/dev/null
    buf="$(cat "$log")"
    assert_contains "$buf" "SENDER IS NO LONGER LIVE"
    assert_contains "$buf" "Ack:    cctrl peer ack $id --as comet --json"
    assert_not_contains "$buf" "cctrl peer reply"
    assert_not_contains "$buf" "cctrl peer send"

    # mailbox-only sender (no tmux capability): reachable by mailbox -> reply line.
    id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "M" | jq -r '.id')"
    : > "$log"
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver comet --inline "$id" --json >/dev/null
    buf="$(cat "$log")"
    assert_contains "$buf" "Reply:  cctrl peer reply $id --as comet --json"
    assert_contains "$buf" "Ack:    cctrl peer ack $id --as comet --json"
    assert_not_contains "$buf" "SENDER IS NO LONGER LIVE"

    # unresolvable sender: unregister it after sending -> treated as unreachable.
    id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from tempsender --json -- "U" | jq -r '.id')"
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer unregister tempsender >/dev/null
    : > "$log"
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver comet --inline "$id" --json >/dev/null
    buf="$(cat "$log")"
    assert_contains "$buf" "SENDER IS NO LONGER LIVE"
    assert_contains "$buf" "Ack:    cctrl peer ack $id --as comet --json"
    assert_not_contains "$buf" "cctrl peer reply"

    echo "ok: inline envelope reachability branches (live/dead/mailbox-only/unresolvable) + ack in all"
}

test_peer_inline_paste_failure_keeps_queued() {
    # Plan 024, Task 9 (CRITICAL): if the tmux paste fails, the message MUST stay
    # queued with delivered_at null. A regression here silently drops fleet mail —
    # the sender believes it landed and nothing retries.
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/pf-data" log="$TMPDIR/pf-tmux.log"
    setup_delivery_peers "$data"
    local id out
    id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "will fail to paste" | jq -r '.id')"
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" TMUX_FAKE_LOAD_FAIL=1 CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver comet --inline "$id" --json)" || true
    printf '%s\n' "$out" | jq -e '.results[0].status == "failed"' >/dev/null || fail "expected failed inline result on paste failure"
    jq -c "select(.id==\"$id\")" "$data/messages.jsonl" | jq -e '.status == "queued" and .delivered_at == null' >/dev/null || fail "paste failure must leave message queued with null delivered_at"
    echo "ok: inline paste failure leaves the message queued (no silent drop)"
}

test_peer_inline_delivery_idempotent() {
    # Plan 024, Task 10: re-delivering an already-delivered message preserves its
    # original delivered_at; an already-acked message is left unchanged.
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/idem-data" log="$TMPDIR/idem-tmux.log"
    setup_delivery_peers "$data"
    local id
    id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "idempotent" | jq -r '.id')"

    : > "$log"
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-07-01T00:00:00Z" "$ROOT/cctrl" peer deliver comet --inline "$id" --json >/dev/null
    [[ "$(jq -r "select(.id==\"$id\") | .delivered_at" "$data/messages.jsonl")" == "2026-07-01T00:00:00Z" ]] || fail "expected delivered_at from first inline delivery"

    # Re-deliver with a later clock: status stays delivered, delivered_at frozen.
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-07-02T00:00:00Z" "$ROOT/cctrl" peer deliver comet --inline "$id" --json >/dev/null
    jq -c "select(.id==\"$id\")" "$data/messages.jsonl" | jq -e '.status == "delivered" and .delivered_at == "2026-07-01T00:00:00Z"' >/dev/null || fail "re-delivery must not regress status or clobber delivered_at"

    # Ack, then re-deliver: acked stays acked, delivered_at still frozen.
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer ack "$id" --as comet --json >/dev/null
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-07-03T00:00:00Z" "$ROOT/cctrl" peer deliver comet --inline "$id" --json >/dev/null
    jq -c "select(.id==\"$id\")" "$data/messages.jsonl" | jq -e '.status == "acked" and .delivered_at == "2026-07-01T00:00:00Z"' >/dev/null || fail "re-delivering an acked message must leave it unchanged"
    echo "ok: inline delivery is idempotent for delivered and acked messages"
}

test_peer_inline_pastes_into_recipient_pane() {
    # Plan 024, Task 10a: an inline delivery to peer A whose SENDER is peer B must
    # paste into A's pane, never B's — guards the global-clobber regression where
    # resolving the sender's target would overwrite the in-flight recipient target.
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/pane-data" log="$TMPDIR/pane-tmux.log"
    setup_delivery_peers "$data"
    mkdir -p "$TMPDIR/bsender"
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register bsender --dir "$TMPDIR/bsender" --agent codex --session TMUX--bsender >/dev/null
    local id buf
    id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from bsender --json -- "into A" | jq -r '.id')"
    : > "$log"
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet TMUX--bsender" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver comet --inline "$id" --json >/dev/null
    buf="$(cat "$log")"
    assert_contains "$buf" "paste-buffer -b cctrl-inline-comet-"
    assert_contains "$buf" "-t TMUX--comet"
    assert_not_contains "$buf" "cctrl-inline-bsender"
    echo "ok: inline delivery pastes into the recipient's pane, not the sender's"
}

test_peer_reachability_class_is_pure() {
    # Plan 024, Task 10a: the pure classifier (plan 027) maps a peer JSON to
    # live/mailbox-only/unreachable WITHOUT writing PEER_DELIVER_STATUS/TARGET
    # (which would clobber an in-flight recipient delivery).
    make_fake_tmux "$TMPDIR/tmux"
    local out
    out="$(CCTRL_NO_MAIN=1 PATH="$TMPDIR:$PATH" TMUX_FAKE_HAS_SESSION="TMUX--live" bash -c '
        source "'"$ROOT"'/cctrl" >/dev/null 2>&1
        PEER_DELIVER_STATUS="SENTINEL_S"; PEER_DELIVER_TARGET="SENTINEL_T"
        a="$(_peer_reachability_class "{\"name\":\"p\",\"capabilities\":[\"mailbox\",\"tmux\"],\"tmux_target\":\"TMUX--live\"}")"
        b="$(_peer_reachability_class "{\"name\":\"q\",\"capabilities\":[\"mailbox\"]}")"
        c="$(_peer_reachability_class "{\"name\":\"r\",\"capabilities\":[\"mailbox\",\"tmux\"],\"tmux_target\":\"TMUX--dead\"}")"
        printf "%s|%s|%s|%s|%s" "$a" "$b" "$c" "$PEER_DELIVER_STATUS" "$PEER_DELIVER_TARGET"
    ')"
    [[ "$out" == "live|mailbox-only|unreachable|SENTINEL_S|SENTINEL_T" ]] || fail "classifier impure or wrong: $out"
    echo "ok: pure reachability classifier maps classes without touching PEER_DELIVER_* globals"
}

test_peer_inline_body_bytes_preserved() {
    # Plan 024, Task 10b: the body must arrive byte-for-byte after the envelope,
    # trailing newline included. The `BUFFER %s\n` log line cannot prove this, so
    # capture the raw load-buffer payload and byte-compare its tail to the body.
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/bytes-data" log="$TMPDIR/bytes-tmux.log" bodyfile="$TMPDIR/bytes-body" buffile="$TMPDIR/bytes-buffer"
    setup_delivery_peers "$data"
    printf 'line one\n\nline three\ntrailing kept\n' > "$bodyfile"
    local id nbytes
    id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --body-file "$bodyfile" --json | jq -r '.id')"
    : > "$log"
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_BUFFER_FILE="$buffile" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver comet --inline "$id" --json >/dev/null
    [[ -f "$buffile" ]] || fail "expected raw buffer capture file"
    nbytes="$(wc -c < "$bodyfile")"
    tail -c "$nbytes" "$buffile" | cmp -s - "$bodyfile" || fail "inline body not preserved byte-for-byte after the envelope"
    echo "ok: inline body arrives byte-for-byte (trailing newline preserved) after the envelope"
}

test_peer_inline_delivered_appears_in_stale_sweep() {
    # Plan 024, Task 7: an inline-delivered message must fold into the
    # delivered-but-unacked stale sweep — it sets delivered_at, which
    # _peer_delivered_stale_json ages on.
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/stale-data" log="$TMPDIR/stale-tmux.log"
    setup_delivery_peers "$data"
    local id out
    id="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "stale me" | jq -r '.id')"
    : > "$log"
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-07-01T00:00:00Z" "$ROOT/cctrl" peer deliver comet --inline "$id" --json >/dev/null
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer nudge --stale --older-than 0 --json)"
    printf '%s\n' "$out" | jq -e --arg id "$id" '.delivered_unacked_stale | map(.id) | index($id) != null' >/dev/null || fail "expected inline-delivered message in delivered-stale sweep"
    echo "ok: inline-delivered messages fold into the delivered-stale sweep"
}

test_peer_deliver_claude_modal_detection() {
    # Regression: the claude) modal-detector must anchor on the real modal's
    # highlighted selection line ("❯ 1."), not on any markdown numbered list or
    # benign "Do you want ... proceed" prose. The old heuristic ('. 1\.' plus
    # bare 'Do you want'/'Do you trust') false-flagged normal Claude output and
    # silently DEFERRED peer messages forever.
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/deliver-claude-modal-data"
    local log="$TMPDIR/deliver-claude-modal-tmux.log"
    : > "$log"
    # setup_delivery_peers registers the "orchestrator" sender; add a claude
    # target peer with its own tmux session so the claude) branch is exercised.
    setup_delivery_peers "$data"
    mkdir -p "$TMPDIR/claudepeer"
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register cq --dir "$TMPDIR/claudepeer" --agent claude --session TMUX--cq >/dev/null

    # modal_pane: a real Claude proceed dialog ("❯ 1. Yes") must DEFER.
    # benign_pane: a markdown numbered list plus "Do you want ... proceed" prose
    # (no "❯ 1." selection line) must NOT defer — the old '. 1\.'/prose heuristic
    # wrongly did.
    local modal_pane benign_pane
    modal_pane="$(printf '%s\n' \
        '● Ready to remove the old build artifacts.' \
        '' \
        '╭──────────────────────────────────────────────────╮' \
        '│ Do you want to proceed?                          │' \
        '│ ❯ 1. Yes                                         │' \
        '│   2. No, and tell Claude what to do differently  │' \
        '╰──────────────────────────────────────────────────╯')"
    benign_pane="$(printf '%s\n' \
        '● Here is the fleet plan:' \
        '  1. First item' \
        '  2. Second item' \
        '' \
        'Earlier you asked: Do you want to proceed with the old approach?')"

    assert_modal_detection "$data" "$log" cq TMUX--cq "$modal_pane" "$benign_pane"

    echo "ok: claude modal-detector anchors on ❯ 1. (no false-positive deferral)"
}

test_peer_deliver_codex_modal_detection() {
    # Regression: the codex) modal-detector must anchor on real Codex
    # approval-modal text (verified against Codex CLI 0.142.5), not on bare
    # "Approve"/"y/N" prose. The old markers ('Allow command|Approve|y/N') both
    # missed real modals (the header is "Allow Codex to run", never "Allow
    # command") and false-flagged normal output containing "Approve" or a shell
    # "[y/N]" prompt — the same silent-deferral bug as the claude branch.
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/deliver-codex-modal-data"
    local log="$TMPDIR/deliver-codex-modal-tmux.log"
    : > "$log"
    # comet is registered --agent codex with session TMUX--comet.
    setup_delivery_peers "$data"

    # modal_pane: a real Codex approval modal ("Allow Codex to …" + the "tell
    # Codex what to do differently" option) must DEFER.
    # hook_pane: Codex's hook-review trust prompt must also DEFER. This prompt
    # appears before any normal input prompt, so nudging it would move the modal
    # selection instead of delivering the peer message.
    # benign_pane: prose with "Approve", a shell "[y/N]" prompt, and a markdown
    # numbered list — but no real modal marker — must NOT defer (the old
    # 'Approve'/'y/N' markers wrongly did).
    local modal_pane hook_pane benign_pane out
    modal_pane="$(printf '%s\n' \
        '● Applying the proposed patch next.' \
        '' \
        '╭──────────────────────────────────────────────────╮' \
        '│ Allow Codex to apply proposed code changes?      │' \
        '│                                                  │' \
        '│ > Yes, proceed                                   │' \
        '│   No, and tell Codex what to do differently      │' \
        '╰──────────────────────────────────────────────────╯')"
    benign_pane="$(printf '%s\n' \
        '● Next steps for the PR:' \
        '  1. Approve the upstream change' \
        '  2. Rerun CI' \
        '' \
        $'I ran `git clean -n` (the tool would normally ask y/N before deleting).')"

    assert_modal_detection "$data" "$log" comet TMUX--comet "$modal_pane" "$benign_pane"

    hook_pane="$(printf '%s\n' \
        'Hooks need review' \
        '2 hooks are new or changed.' \
        '' \
        'PreToolUse hooks' \
        '1 hook needs review before it can run.' \
        '' \
        'Press t to trust; esc to go back')"
    : > "$log"
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "hold for hook review" >/dev/null
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" TMUX_FAKE_CAPTURE_PANE="$hook_pane" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver comet --json)"
    printf '%s\n' "$out" | jq -e '.results[0].status == "deferred" and .results[0].reason == "modal prompt visible"' >/dev/null || fail "expected Codex hook-review prompt to defer"
    assert_not_contains "$(cat "$log")" "paste-buffer"

    echo "ok: codex modal-detector anchors on real Codex modal text and hook-review prompts"
}

test_peer_deliver_failures_all_and_concurrency() {
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/deliver-failure-data"
    local log="$TMPDIR/deliver-failure-tmux.log"
    : > "$log"
    setup_delivery_peers "$data"

    local out rc messages count failed=0 pid
    local -a pids=()
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "failed target" >/dev/null
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver comet --json 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected missing tmux session deliver to fail"
    printf '%s\n' "$out" | jq -e '.results[0].status == "failed" and (.results[0].reason | contains("tmux session not found"))' >/dev/null || fail "expected failed target JSON result"
    messages="$(jq -s '.' "$data/messages.jsonl")"
    printf '%s\n' "$messages" | jq -e '.[0].status == "queued" and (.[0].last_nudge_error | contains("tmux session not found"))' >/dev/null || fail "expected failed target to leave queued message with last_nudge_error"

    data="$TMPDIR/deliver-all-data"
    log="$TMPDIR/deliver-all-tmux.log"
    : > "$log"
    setup_delivery_peers "$data"
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "wake comet" >/dev/null
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send offline --from orchestrator --json -- "wake offline" >/dev/null
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver --all --json)"
    printf '%s\n' "$out" | jq -e '
      (.results | map(select(.peer == "comet" and .status == "nudged")) | length) == 1
      and (.results | map(select(.peer == "offline" and .status == "skipped" and .reason == "no-tmux-capability")) | length) == 1
    ' >/dev/null || fail "expected --all to nudge tmux peer and skip non-tmux peer"

    data="$TMPDIR/deliver-concurrency-data"
    log="$TMPDIR/deliver-concurrency-tmux.log"
    : > "$log"
    setup_delivery_peers "$data"
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "race" >/dev/null
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-13T00:00:03Z" "$ROOT/cctrl" peer deliver comet --json >/dev/null &
    pids+=("$!")
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-13T00:00:03Z" "$ROOT/cctrl" peer deliver comet --json >/dev/null &
    pids+=("$!")
    for pid in "${pids[@]}"; do
        wait "$pid" || failed=1
    done
    [[ "$failed" -eq 0 ]] || fail "expected concurrent deliver commands to complete"
    count="$(grep -c 'paste-buffer -b cctrl-nudge-comet-' "$log" || true)"
    [[ "$count" -eq 1 ]] || fail "expected concurrent deliver to paste one nudge, got $count"
    messages="$(jq -s '.' "$data/messages.jsonl")"
    printf '%s\n' "$messages" | jq -e '.[0].status == "queued" and .[0].nudge_count == 1' >/dev/null || fail "expected concurrent deliver to record one nudge"
}

test_peer_orchestrator_status_nudge_watch() {
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/orchestrator-data"
    local log="$TMPDIR/orchestrator-tmux.log"
    : > "$log"
    setup_delivery_peers "$data"

    local out messages id delivered_id count rc
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "tmux wake" >/dev/null
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send offline --from orchestrator --json -- "polling wake" >/dev/null
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer alias comet halley >/dev/null

    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer status --json)"
	    printf '%s\n' "$out" | jq -e '
	      .totals.queued == 2
	      and (.peers | map(select(.name == "comet" and .queued == 1 and (.transports | index("tmux")))) | length) == 1
	      and (.peers | map(select(.name == "offline" and .queued == 1 and ((.transports | index("tmux")) | not))) | length) == 1
	    ' >/dev/null || fail "expected peer status to summarize queued messages and transports"

    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer nudge missing --json 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected explicit nudge target typo to fail"
    printf '%s\n' "$out" | jq -e '.ok == false and .error.code == "unknown-peer"' >/dev/null || fail "expected explicit nudge typo to return JSON unknown-peer"

    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer nudge halley --dry-run --json)"
    printf '%s\n' "$out" | jq -e '
      (.results | length) == 1
      and .results[0].peer == "comet"
      and .results[0].status == "dry-run"
    ' >/dev/null || fail "expected nudge to resolve explicit alias targets"

    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer watch --once --dry-run --json)"
    printf '%s\n' "$out" | jq -e '
      .pass == 1
      and (.results | map(select(.peer == "comet" and .status == "dry-run")) | length) == 1
      and (.results | map(select(.peer == "offline" and .status == "polling")) | length) == 1
    ' >/dev/null || fail "expected watch dry-run to report tmux and polling peers"
    assert_not_contains "$(cat "$log")" "paste-buffer"
    messages="$(jq -s '.' "$data/messages.jsonl")"
    printf '%s\n' "$messages" | jq -e 'all(.[]; .status == "queued" and .last_nudge_at == null)' >/dev/null || fail "expected watch dry-run to leave queued messages unchanged"

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-13T00:20:00Z" "$ROOT/cctrl" peer nudge --stale --older-than 15m --json)"
    printf '%s\n' "$out" | jq -e '
      (.results | map(select(.peer == "comet" and .status == "nudged")) | length) == 1
      and (.results | map(select(.peer == "offline" and .status == "skipped")) | length) == 1
    ' >/dev/null || fail "expected stale nudge to nudge tmux peer and skip polling peer through adapter"
    assert_contains "$(cat "$log")" "paste-buffer -b cctrl-nudge-comet-"

    delivered_id="$(CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-13T00:00:00Z" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "delivered stale" | jq -r '.id')"
    mark_message_delivered "$data/messages.jsonl" "$delivered_id"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-13T00:20:00Z" "$ROOT/cctrl" peer nudge --stale --older-than 15m --json)"
    printf '%s\n' "$out" | jq -e --arg id "$delivered_id" '.delivered_unacked_stale | map(select(.id == $id)) | length == 1' >/dev/null || fail "expected stale nudge to surface delivered-unacked messages"

    data="$TMPDIR/watch-lock-data"
    log="$TMPDIR/watch-lock-tmux.log"
    : > "$log"
    setup_delivery_peers "$data"
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "lock" >/dev/null
    mkdir -p "$data/watch.lock.d"
    printf '%s\n' "$$" > "$data/watch.lock.d/pid"
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer watch --once --json 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected second watch to fail while lock owner is alive"
    assert_contains "$out" "already running (pid"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer watch --once --force --dry-run --json)"
    printf '%s\n' "$out" | jq -e '.pass == 1' >/dev/null || fail "expected --once --force to bypass singleton lock"
    rm -rf "$data/watch.lock.d"
    mkdir -p "$data/watch.lock.d"
    printf '999999\n' > "$data/watch.lock.d/pid"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer watch --once --dry-run --json)"
    printf '%s\n' "$out" | jq -e '.pass == 1' >/dev/null || fail "expected watch to reclaim dead PID lock"
    [[ ! -d "$data/watch.lock.d" ]] || fail "expected watch lock to be released after once pass"

    data="$TMPDIR/watch-backoff-data"
    log="$TMPDIR/watch-backoff-tmux.log"
    : > "$log"
    setup_delivery_peers "$data"
    id="$(CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-13T00:00:00Z" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "backoff" | jq -r '.id')"
    jq -c --arg id "$id" '
      if .id == $id then
        .nudge_count = 3
        | .last_nudge_at = "2026-06-13T00:05:00Z"
        | .last_nudge_error = "tmux failed"
        | .history = ((.history // []) + [
            {at:"2026-06-13T00:03:00Z", event:"nudge", ok:false, by:"cctrl", adapter:"tmux", error:"tmux failed"},
            {at:"2026-06-13T00:04:00Z", event:"nudge", ok:false, by:"cctrl", adapter:"tmux", error:"tmux failed"},
            {at:"2026-06-13T00:05:00Z", event:"nudge", ok:false, by:"cctrl", adapter:"tmux", error:"tmux failed"}
          ])
      else . end
    ' "$data/messages.jsonl" > "$data/messages.jsonl.tmp" && mv "$data/messages.jsonl.tmp" "$data/messages.jsonl"
    out="$(CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-13T00:06:00Z" "$ROOT/cctrl" peer status --json)"
    printf '%s\n' "$out" | jq -e '(.nudge_failing | index("comet")) != null' >/dev/null || fail "expected status to show backoff-active peer as nudge failing"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-13T00:06:00Z" "$ROOT/cctrl" peer watch --once --dry-run --json --renudge-after 1m --backoff 10m)"
    printf '%s\n' "$out" | jq -e '.results[0].status == "backoff"' >/dev/null || fail "expected watch to skip recipient during backoff"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-13T00:20:00Z" "$ROOT/cctrl" peer watch --once --dry-run --json --renudge-after 1m --backoff 10m)"
    printf '%s\n' "$out" | jq -e '.results[0].status == "dry-run"' >/dev/null || fail "expected watch to re-enable after backoff window"

    data="$TMPDIR/watch-interval-data"
    log="$TMPDIR/watch-interval-tmux.log"
    : > "$log"
    setup_delivery_peers "$data"
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer watch --interval 0 --json 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected watch --interval 0 to fail validation"
    printf '%s\n' "$out" | jq -e '.ok == false and .error.message == "interval must be positive"' >/dev/null || fail "expected watch --interval 0 JSON validation error"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer watch --interval 1 --max-passes 2 --dry-run --json)"
    printf '%s\n' "$out" | jq -s -e 'length == 2 and .[0].pass == 1 and .[1].pass == 2' >/dev/null || fail "expected bounded watch interval to emit two pass summaries"
}

test_peer_gc_retention_and_doctor() {
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/gc-data"
    local log="$TMPDIR/gc-tmux.log"
    : > "$log"
    setup_delivery_peers "$data"

    local old_id queued_id delivered_id out active_count archive_count codex_home wrapper
    old_id="$(CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-01T00:00:00Z" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "old acked" | jq -r '.id')"
    CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-01T00:00:01Z" "$ROOT/cctrl" peer recv --as comet --json >/dev/null
    CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-01T00:00:02Z" "$ROOT/cctrl" peer ack "$old_id" --as comet --json >/dev/null
    queued_id="$(CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-01T00:00:00Z" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "old queued" | jq -r '.id')"
    delivered_id="$(CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-01T00:00:00Z" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "old delivered" | jq -r '.id')"
    mark_message_delivered "$data/messages.jsonl" "$delivered_id"

    out="$(CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-13T00:00:00Z" "$ROOT/cctrl" peer gc --older-than 7d --status acked --dry-run --json)"
    printf '%s\n' "$out" | jq -e --arg id "$old_id" '.dry_run == true and .eligible_count == 1 and (.eligible | map(select(.id == $id)) | length == 1)' >/dev/null || fail "expected gc dry-run to report eligible acked message"
    active_count="$(jq -s 'length' "$data/messages.jsonl")"
    [[ "$active_count" -eq 3 ]] || fail "expected gc dry-run to leave active mailbox unchanged"

    : > "$data/messages-archive.jsonl"
    chmod 400 "$data/messages-archive.jsonl"
    rc=0
    out="$(CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-13T00:00:00Z" "$ROOT/cctrl" peer gc --older-than 7d --status acked --json 2>&1)" || rc=$?
    chmod 600 "$data/messages-archive.jsonl"
    [[ "$rc" -ne 0 ]] || fail "expected gc to fail when archive append fails"
    printf '%s\n' "$out" | jq -e '.ok == false and (.error | contains("failed to append archive"))' >/dev/null || fail "expected gc archive failure to return JSON error"
    active_count="$(jq -s 'length' "$data/messages.jsonl")"
    archive_count="$(jq -s 'length' "$data/messages-archive.jsonl")"
    [[ "$active_count" -eq 3 ]] || fail "expected failed gc to leave active mailbox unchanged"
    [[ "$archive_count" -eq 0 ]] || fail "expected failed gc to leave archive unchanged"
    rm -f "$data/messages-archive.jsonl"

    out="$(CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-13T00:00:00Z" "$ROOT/cctrl" peer gc --older-than 7d --status acked --json)"
    printf '%s\n' "$out" | jq -e '.eligible_count == 1' >/dev/null || fail "expected gc to archive one acked message"
    active_count="$(jq -s 'length' "$data/messages.jsonl")"
    archive_count="$(jq -s 'length' "$data/messages-archive.jsonl")"
    [[ "$active_count" -eq 2 ]] || fail "expected gc to keep queued and delivered active messages"
    [[ "$archive_count" -eq 1 ]] || fail "expected gc archive to contain one message"
    assert_contains "$(cat "$data/messages.jsonl")" "$queued_id"
    assert_contains "$(cat "$data/messages.jsonl")" "$delivered_id"

    codex_home="$TMPDIR/codex-home"
    wrapper="$TMPDIR/codex-notify-wrapper.sh"
    mkdir -p "$codex_home"
    cat > "$wrapper" <<SH
#!/usr/bin/env bash
exec "$ROOT/hooks/peer-doorbell.sh" codex "\$@"
SH
    chmod +x "$wrapper"
    printf 'notify = ["%s"]\n' "$wrapper" > "$codex_home/config.toml"

    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" CODEX_HOME="$codex_home" "$ROOT/cctrl" peer doctor comet --json)"
    printf '%s\n' "$out" | jq -e '
        .target == "comet"
        and (.checks | map(select(.name == "jq" and .ok == true)) | length) == 1
        and (.checks | map(select(.name == "mcp_bridge" and .ok == true)) | length) == 1
        and (.checks | map(select(.name == "tmux_session_live" and .ok == true)) | length) == 1
        and (.checks | map(select(.name == "doorbell_hook_present" and .ok == true)) | length) == 1
        and (.checks | map(select(.name == "doorbell_hook_executable" and .ok == true)) | length) == 1
        and (.checks | map(select(.name == "doorbell_hook_registered" and .ok == true and .agent == "codex")) | length) == 1
    ' >/dev/null || fail "expected peer doctor to check jq, tmux, MCP bridge, and Codex doorbell wrapper"
}

test_peer_doorbell_hook() {
    local fake="$TMPDIR/fake-cctrl-doorbell"
    cat > "$fake" <<'SH'
#!/usr/bin/env bash
case "${CCTRL_FAKE_CHECK:-empty}" in
    queued)
        printf '{"peer":"%s","queued":2,"delivered_unacked":0,"oldest_queued_age_seconds":1}\n' "${CCTRL_PEER:-}"
        exit 0
        ;;
    delivered)
        printf '{"peer":"%s","queued":0,"delivered_unacked":1,"oldest_queued_age_seconds":null}\n' "${CCTRL_PEER:-}"
        exit 0
        ;;
    error)
        echo "boom" >&2
        exit 65
        ;;
    *)
        printf '{"peer":"%s","queued":0,"delivered_unacked":0,"oldest_queued_age_seconds":null}\n' "${CCTRL_PEER:-}"
        exit 2
        ;;
esac
SH
    chmod +x "$fake"

    local out rc=0
    out="$(CCTRL_BIN="$fake" CCTRL_FAKE_CHECK=queued "$ROOT/hooks/peer-doorbell.sh" 2>&1)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected unset CCTRL_PEER doorbell to exit 0"
    [[ -z "$out" ]] || fail "expected unset CCTRL_PEER doorbell to be silent"

    local stdin_capture="$TMPDIR/doorbell.stdin" wrapper="$TMPDIR/doorbell-stdin-wrapper.sh"
    cat > "$wrapper" <<SH
#!/usr/bin/env bash
"$ROOT/hooks/peer-doorbell.sh" codex >/dev/null 2>&1 || true
cat > "$stdin_capture"
SH
    chmod +x "$wrapper"
    printf '{"hook":"notify"}' | CCTRL_BIN="$fake" CCTRL_PEER=comet CCTRL_FAKE_CHECK=queued "$wrapper"
    assert_contains "$(cat "$stdin_capture")" '{"hook":"notify"}'

    local stdout="$TMPDIR/doorbell.stdout" stderr="$TMPDIR/doorbell.stderr"
    rc=0
    CCTRL_BIN="$fake" CCTRL_PEER=comet CCTRL_FAKE_CHECK=queued "$ROOT/hooks/peer-doorbell.sh" >"$stdout" 2>"$stderr" || rc=$?
    [[ "$rc" -eq 2 ]] || fail "expected queued Claude doorbell to exit 2, got $rc"
    [[ -z "$(cat "$stdout")" ]] || fail "expected queued Claude doorbell stdout to be empty"
    assert_contains "$(cat "$stderr")" "[cctrl] 2 new peer message(s) for comet. Run: cctrl peer recv --as comet --json"

    rc=0
    out="$(CCTRL_BIN="$fake" CCTRL_PEER=comet CCTRL_FAKE_CHECK=delivered "$ROOT/hooks/peer-doorbell.sh" 2>&1)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected delivered-only doorbell to exit 0"
    [[ -z "$out" ]] || fail "expected delivered-only doorbell to be silent"

    rc=0
    out="$(CCTRL_BIN="$fake" CCTRL_PEER=comet CCTRL_FAKE_CHECK=error "$ROOT/hooks/peer-doorbell.sh" 2>&1)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected errored doorbell to fail open"
    [[ -z "$out" ]] || fail "expected errored doorbell to be silent"

    rc=0
    out="$(CCTRL_BIN="$fake" CCTRL_PEER=comet CCTRL_FAKE_CHECK=queued "$ROOT/hooks/peer-doorbell.sh" codex 2>&1)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected Codex notify doorbell to exit 0"
    assert_contains "$out" "cctrl peer recv --as comet --json"
}

test_session_close_self_graceful() {
    make_fake_tmux "$TMPDIR/tmux"
    local log="$TMPDIR/close-self.log"
    : > "$log"

    # Inside a tmux session (TMUX set), no name: schedule a delayed kill of
    # the current session via run-shell so the caller can finish its output.
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX="fake,1,0" \
        TMUX_FAKE_SESSION_NAME="TMUX--demo" TMUX_FAKE_HAS_SESSION=1 \
        TMUX_FAKE_PANE_PID="__current__" \
        "$ROOT/cctrl" session close)"
    assert_contains "$out" "will close in 5s"
    assert_contains "$(cat "$log")" "run-shell -b sleep\\ 5\\;\\ tmux\\ kill-session\\ -t\\ TMUX--demo"
}

test_session_close_stale_tmux_refuses_current() {
    make_fake_tmux "$TMPDIR/tmux"
    local log="$TMPDIR/close-stale.log"
    : > "$log"

    local out rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX="fake,1,0" \
        TMUX_FAKE_SESSION_NAME="TMUX--demo" TMUX_FAKE_HAS_SESSION=1 \
        TMUX_FAKE_PANE_PID="999999" \
        "$ROOT/cctrl" session close 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected stale tmux environment to refuse no-arg close"
    assert_contains "$out" "Could not verify that this process is inside a cctrl tmux session"
    assert_not_contains "$(cat "$log")" "kill-session"
}

test_session_current_identity_json() {
    make_fake_tmux "$TMPDIR/tmux"
    mkdir -p "$CCTRL_SESSION_METADATA_DIR"
    cat > "$CCTRL_SESSION_METADATA_DIR/TMUX--demo.json" <<'JSON'
{"target":"@demo","cwd":"/tmp/demo","purpose":"verify identity"}
JSON

    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX="fake,1,0" CCTRL_AGENT=codex \
        CCTRL_SESSION_KIND=tmux CCTRL_SESSION_NAME="TMUX--demo" \
        TMUX_FAKE_HAS_SESSION=1 TMUX_FAKE_PANE_PID="__current__" \
        "$ROOT/cctrl" session current --json)"
    assert_contains "$out" '"agent": "codex"'
    assert_contains "$out" '"session": "TMUX--demo"'
    assert_contains "$out" '"can_close_self": true'
    assert_contains "$out" '"close_command": "cctrl close"'
    assert_contains "$out" '"purpose": "verify identity"'
}

# --- planned session attest -------------------------------------------------

test_session_attest_live_tmux_process_matches() {
    # The attestation must prove the metadata record still maps to a live tmux
    # pane whose process is the recorded Codex owner, rather than trusting the
    # record merely because it exists.
    local bin="$TMPDIR/attest-live-bin" meta="$TMPDIR/attest-live-meta"
    mkdir -p "$bin" "$meta"
    make_fake_tmux "$bin/tmux"
    make_fake_ps "$bin/ps"
    cat > "$meta/TMUX--attest-live.json" <<'JSON'
{"name":"TMUX--attest-live","agent":"codex","control_surface":"tmux","tmux_session":"TMUX--attest-live","pane_id":"%42","pane_pid":"12345","wrapper_pid":"12345","agent_pid":"12345","created_at":"2026-08-25T12:00:00Z","cctrl_managed":true}
JSON

    local out rc=0
    out="$(PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_HAS_SESSION="TMUX--attest-live" TMUX_FAKE_PANE_ID="%42" TMUX_FAKE_PANE_PID=12345 \
        "$ROOT/cctrl" session attest TMUX--attest-live --json)" || rc=$?
    [[ $rc -eq 0 ]] || fail "live session attest exited $rc: $out"
    assert_contains "$out" '"verified": true'
    assert_contains "$out" '"control_surface": "tmux"'
    assert_contains "$out" '"tmux_session": "TMUX--attest-live"'
    assert_contains "$out" '"pane_id": "%42"'
    assert_contains "$out" '"pane_pid": 12345'
    assert_contains "$out" '"process_match": true'
    echo "ok: session attest verifies matching live tmux pane process"
}

test_session_attest_direct_metadata() {
    # A cctrl record that deliberately has no tmux owner is still a conclusive
    # result: it is a direct session, not an unverified tmux session.
    local meta="$TMPDIR/attest-direct-meta"
    mkdir -p "$meta"
    cat > "$meta/direct-attest.json" <<'JSON'
{"name":"direct-attest","agent":"codex","control_surface":"direct","created_at":"2026-08-25T12:00:00Z","cctrl_managed":true}
JSON

    local out rc=0
    out="$(CCTRL_SESSION_METADATA_DIR="$meta" "$ROOT/cctrl" session attest direct-attest --json)" || rc=$?
    [[ $rc -eq 0 ]] || fail "direct session attest exited $rc: $out"
    assert_contains "$out" '"verified": true'
    assert_contains "$out" '"control_surface": "direct"'
    assert_contains "$out" '"tmux_session": null'
    assert_contains "$out" '"process_match": null'
    echo "ok: session attest conclusively reports direct metadata"
}

test_session_attest_stale_tmux_session_missing() {
    # A record for a vanished tmux session must fail closed, while preserving
    # the declared control surface so callers can explain the failure.
    local bin="$TMPDIR/attest-stale-bin" meta="$TMPDIR/attest-stale-meta"
    mkdir -p "$bin" "$meta"
    make_fake_tmux "$bin/tmux"
    cat > "$meta/TMUX--attest-stale.json" <<'JSON'
{"name":"TMUX--attest-stale","agent":"codex","control_surface":"tmux","tmux_session":"TMUX--attest-stale","pane_id":"%7","pane_pid":"7777","wrapper_pid":"7777","agent_pid":"7777","created_at":"2026-08-25T12:00:00Z","cctrl_managed":true}
JSON

    local out rc=0
    out="$(PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_HAS_SESSION="" "$ROOT/cctrl" session attest TMUX--attest-stale --json)" || rc=$?
    [[ $rc -eq 0 ]] || fail "stale session attest exited $rc: $out"
    assert_contains "$out" '"verified": false'
    assert_contains "$out" '"control_surface": "tmux"'
    assert_contains "$out" '"tmux_session": "TMUX--attest-stale"'
    assert_contains "$out" '"reason": "tmux-session-missing"'
    echo "ok: session attest fails closed for missing tmux session"
}

test_session_attest_malformed_metadata_fails_human_mode() {
    local meta="$TMPDIR/attest-malformed-meta"
    mkdir -p "$meta"
    printf 'not json {{{\n' > "$meta/TMUX--attest-malformed.json"

    local out rc=0
    out="$(CCTRL_SESSION_METADATA_DIR="$meta" \
        "$ROOT/cctrl" session attest TMUX--attest-malformed 2>&1)" || rc=$?
    [[ $rc -ne 0 ]] || fail "malformed human attestation unexpectedly succeeded: $out"
    assert_contains "$out" "unverified: metadata-invalid"
    echo "ok: session attest reports malformed metadata and fails in human mode"
}

test_session_runtime_mcp_attests_fixed_session() {
    # The task-facing MCP server pins one session at startup and exposes only
    # the read-only runtime_context tool, never a caller-selected tmux target.
    local bin="$TMPDIR/runtime-mcp-bin" meta="$TMPDIR/runtime-mcp-meta"
    mkdir -p "$bin" "$meta"
    make_fake_tmux "$bin/tmux"
    make_fake_ps "$bin/ps"
    cat > "$meta/TMUX--runtime-mcp.json" <<'JSON'
{"name":"TMUX--runtime-mcp","agent":"codex","control_surface":"tmux","tmux_session":"TMUX--runtime-mcp","pane_id":"%9","pane_pid":"12345","wrapper_pid":"12345","created_at":"2026-08-25T12:00:00Z","cctrl_managed":true}
JSON

    local request out
    request='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"runtime_context","arguments":{}}}'
    out="$(printf '%s\n' "$request" | PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_HAS_SESSION="TMUX--runtime-mcp" TMUX_FAKE_PANE_ID="%9" TMUX_FAKE_PANE_PID=12345 \
        "$ROOT/cctrl" session mcp --session TMUX--runtime-mcp)"
    printf '%s\n' "$out" | jq -e '.result.structuredContent.ok == true and .result.structuredContent.data.verified == true and .result.structuredContent.data.session == "TMUX--runtime-mcp"' >/dev/null \
        || fail "runtime MCP did not return a verified fixed-session attestation"
    echo "ok: runtime MCP attests its fixed session"
}

test_session_close_named_immediate() {
    make_fake_tmux "$TMPDIR/tmux"
    local log="$TMPDIR/close-named.log"
    : > "$log"

    # Outside tmux with an explicit name: immediate kill.
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX='' TMUX_FAKE_HAS_SESSION=1 \
        "$ROOT/cctrl" close TMUX--demo)"
    assert_contains "$out" "Closed session: TMUX--demo"
    assert_contains "$(cat "$log")" "kill-session -t TMUX--demo"
    assert_not_contains "$(cat "$log")" "run-shell"
}

test_session_close_outside_requires_name() {
    make_fake_tmux "$TMPDIR/tmux"
    local out rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX='' "$ROOT/cctrl" session close 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected close outside tmux without a name to fail"
    assert_contains "$out" "Could not verify that this process is inside a cctrl tmux session"
}

# --- plan 019: session prune -----------------------------------------------

# Write a codex rollout-log fixture under a CODEX_HOME override. session_meta.cwd
# must match the session's tmux pane path (fake tmux reports /tmp/demo) so
# _session_codex_rollout_path correlates it. $3=yes appends a user_message event.
make_codex_rollout() {
    local codex_home="$1" cwd="$2" with_user="$3" dir f
    dir="$codex_home/sessions/2026/06/30"
    mkdir -p "$dir"
    f="$dir/rollout-2026-06-30T10-00-00-fixture-$RANDOM.jsonl"
    {
        printf '{"timestamp":"2026-06-30T10:00:00.000Z","type":"session_meta","payload":{"id":"cx-%s","cwd":"%s"}}\n' "$RANDOM" "$cwd"
        printf '{"timestamp":"2026-06-30T10:00:01.000Z","type":"turn_context","payload":{"cwd":"%s","model":"gpt-5.5"}}\n' "$cwd"
        if [[ "$with_user" == "yes" ]]; then
            printf '{"timestamp":"2026-06-30T10:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"hi"}}\n'
        fi
    } > "$f"
    touch "$f"   # recent mtime -> not stale, isolates the never-prompted signal
    printf '%s' "$f"
}

test_session_prune_never_prompted_claude() {
    # A claude session whose transcript EXISTS but has zero user turns is flagged
    # never-prompted. Recent updatedAt keeps it out of the staleness bucket, so
    # the sole reason is never-prompted.
    local bin="$TMPDIR/npc-bin" sdir="$TMPDIR/npc-sess" pdir="$TMPDIR/npc-proj"
    mkdir -p "$bin" "$sdir" "$pdir/p"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *4242* ]]; then echo "claude"; exit 0; fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    local now_ms; now_ms=$(( $(date +%s) * 1000 ))
    cat > "$sdir/4242.json" <<JSON
{"pid":4242,"sessionId":"np-uuid","updatedAt":$now_ms}
JSON
    cat > "$pdir/p/np-uuid.jsonl" <<'JSON'
{"type":"summary","summary":"New session"}
JSON

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        TMUX_FAKE_SESSIONS="TMUX--np" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session prune --json)"
    assert_contains "$out" '"name": "TMUX--np"'
    assert_contains "$out" '"reason": "never-prompted"'
    assert_not_contains "$out" 'stale'
    echo "ok: claude never-prompted flagged as prune candidate"
}

test_session_prune_fresh_active_not_candidate() {
    # A recently-active claude session with a real user turn is neither stale
    # nor never-prompted -> not a candidate.
    local bin="$TMPDIR/fa-bin" sdir="$TMPDIR/fa-sess" pdir="$TMPDIR/fa-proj"
    mkdir -p "$bin" "$sdir" "$pdir/p"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *4343* ]]; then echo "claude"; exit 0; fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    local now_ms; now_ms=$(( $(date +%s) * 1000 ))
    cat > "$sdir/4343.json" <<JSON
{"pid":4343,"sessionId":"fa-uuid","updatedAt":$now_ms}
JSON
    cat > "$pdir/p/fa-uuid.jsonl" <<'JSON'
{"type":"user","message":{"role":"user","content":"do the thing"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}
JSON

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        TMUX_FAKE_SESSIONS="TMUX--fresh" TMUX_FAKE_PANE_PID=4343 "$ROOT/cctrl" session prune --json)"
    [[ "$out" == "[]" ]] || fail "expected no candidates for a fresh active session; got: $out"
    echo "ok: fresh active session is not a prune candidate"
}

test_session_prune_codex_no_claude_transcript_bug_guard() {
    # BUG-GUARD: a busy codex session (rollout has a user_message) that simply
    # lacks a *Claude* transcript must NOT be flagged never-prompted. Recent
    # rollout mtime keeps it out of the staleness bucket too -> not a candidate.
    local bin="$TMPDIR/bg-bin" ch="$TMPDIR/bg-codex"
    mkdir -p "$bin" "$ch"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *4444* ]]; then echo "codex --yolo"; exit 0; fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    make_codex_rollout "$ch" "/tmp/demo" yes >/dev/null

    local out
    out="$(PATH="$bin:$PATH" CODEX_HOME="$ch" \
        CCTRL_CLAUDE_SESSIONS_DIR="$TMPDIR/bg-nope" CCTRL_CLAUDE_PROJECTS_DIR="$TMPDIR/bg-nope" \
        TMUX_FAKE_SESSIONS="TMUX--busycx" TMUX_FAKE_PANE_PID=4444 "$ROOT/cctrl" session prune --json)"
    [[ "$out" == "[]" ]] || fail "bug-guard: busy codex session without a Claude transcript must not be flagged; got: $out"
    echo "ok: codex session lacking a Claude transcript is not flagged never-prompted"
}

test_session_prune_codex_never_prompted() {
    # A codex session whose rollout log carries zero user_message events IS
    # flagged never-prompted (resolved via the CODEX_HOME override).
    local bin="$TMPDIR/cnp-bin" ch="$TMPDIR/cnp-codex"
    mkdir -p "$bin" "$ch"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *4545* ]]; then echo "codex --yolo"; exit 0; fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    make_codex_rollout "$ch" "/tmp/demo" no >/dev/null

    local out
    out="$(PATH="$bin:$PATH" CODEX_HOME="$ch" \
        CCTRL_CLAUDE_SESSIONS_DIR="$TMPDIR/cnp-nope" CCTRL_CLAUDE_PROJECTS_DIR="$TMPDIR/cnp-nope" \
        TMUX_FAKE_SESSIONS="TMUX--emptycx" TMUX_FAKE_PANE_PID=4545 "$ROOT/cctrl" session prune --json)"
    assert_contains "$out" '"name": "TMUX--emptycx"'
    assert_contains "$out" '"reason": "never-prompted"'
    echo "ok: codex never-prompted (rollout fixture) flagged as prune candidate"
}

test_codex_rename_updates_app_title() {
    # Codex has no --name/custom-title flag, so cctrl rename updates the local
    # Codex app state row identified from the rollout's session_meta id.
    local bin="$TMPDIR/codex-rename-bin" meta="$TMPDIR/codex-rename-meta" codex_home="$TMPDIR/codex-rename-home"
    mkdir -p "$bin" "$meta" "$codex_home/sessions/2026/08/24"
    make_fake_tmux "$bin/tmux"
    cat > "$meta/TMUX--demo.json" <<'JSON'
{"name":"TMUX--demo","cwd":"/tmp/demo","target_kind":"dir","target":"/tmp/demo","display_label":"/tmp/demo","purpose":"old label","initial_prompt":"original prompt","agent":"codex","cctrl_managed":true,"created_at":"2026-08-24T10:00:00Z","conversation_id":null,"transcript_path":null}
JSON
    cat > "$codex_home/sessions/2026/08/24/rollout-2026-08-24T10-00-00-thread-123.jsonl" <<'JSONL'
{"timestamp":"2026-08-24T10:00:00.000Z","type":"session_meta","payload":{"id":"thread-123","cwd":"/tmp/demo"}}
{"timestamp":"2026-08-24T10:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"original prompt"}}
JSONL
    python3 - "$codex_home/state_5.sqlite" <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT)")
con.execute("INSERT INTO threads (id, title, name) VALUES (?, ?, ?)", ("thread-123", "old title", "old title"))
con.commit()
PY

    local out title name purpose conv_id
    out="$(PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" CODEX_HOME="$codex_home" \
        TMUX_FAKE_HAS_SESSION="TMUX--demo" "$ROOT/cctrl" rename TMUX--demo "new label")"
    assert_contains "$out" "Codex app"
    title="$(sqlite3 "$codex_home/state_5.sqlite" "SELECT title FROM threads WHERE id='thread-123'")"
    name="$(sqlite3 "$codex_home/state_5.sqlite" "SELECT name FROM threads WHERE id='thread-123'")"
    [[ "$title" == "Demo: new label (TMUX--demo)" ]] || fail "unexpected Codex title: $title"
    [[ "$name" == "Demo: new label (TMUX--demo)" ]] || fail "unexpected Codex name: $name"
    purpose="$(session_record_json "TMUX--demo" "$meta" | jq -r '.purpose')"
    conv_id="$(session_record_json "TMUX--demo" "$meta" | jq -r '.conversation_id')"
    [[ "$purpose" == "new label" ]] || fail "metadata purpose not updated: $purpose"
    [[ "$conv_id" == "thread-123" ]] || fail "metadata conversation_id not backfilled: $conv_id"
    echo "ok: codex rename updates app title"
}

test_codex_rename_prefers_prompt_match_over_stale_id() {
    # A recycled tmux name can briefly carry a stale but unarchived Codex
    # conversation_id. The exact current prompt is a stronger identity signal.
    local bin="$TMPDIR/codex-stale-bin" meta="$TMPDIR/codex-stale-meta" codex_home="$TMPDIR/codex-stale-home"
    mkdir -p "$bin" "$meta" "$codex_home/sessions/2026/08/24"
    make_fake_tmux "$bin/tmux"
    cat > "$meta/TMUX--demo.json" <<'JSON'
{"name":"TMUX--demo","cwd":"/tmp/demo","target_kind":"dir","target":"/tmp/demo","display_label":"/tmp/demo","purpose":"old label","initial_prompt":"current prompt","agent":"codex","cctrl_managed":true,"created_at":"2026-08-24T10:00:00Z","conversation_id":"thread-old","transcript_path":null}
JSON
    cat > "$codex_home/sessions/2026/08/24/rollout-2026-08-24T10-01-00-thread-old.jsonl" <<'JSONL'
{"timestamp":"2026-08-24T10:01:00.000Z","type":"session_meta","payload":{"id":"thread-old","cwd":"/tmp/demo"}}
{"timestamp":"2026-08-24T10:01:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"old prompt"}}
JSONL
    cat > "$codex_home/sessions/2026/08/24/rollout-2026-08-24T10-02-00-thread-new.jsonl" <<'JSONL'
{"timestamp":"2026-08-24T10:02:00.000Z","type":"session_meta","payload":{"id":"thread-new","cwd":"/tmp/other-cwd"}}
{"timestamp":"2026-08-24T10:02:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"current prompt"}}
JSONL
    python3 - "$codex_home/state_5.sqlite" <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT)")
con.execute("INSERT INTO threads (id, title, name) VALUES (?, ?, ?)", ("thread-old", "old title", "old title"))
con.execute("INSERT INTO threads (id, title, name) VALUES (?, ?, ?)", ("thread-new", "new title", "new title"))
con.commit()
PY

    local out old_title new_title conv_id
    out="$(PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" CODEX_HOME="$codex_home" \
        TMUX_FAKE_HAS_SESSION="TMUX--demo" "$ROOT/cctrl" rename TMUX--demo "fleet manager")"
    assert_contains "$out" "Codex app"
    old_title="$(sqlite3 "$codex_home/state_5.sqlite" "SELECT title FROM threads WHERE id='thread-old'")"
    new_title="$(sqlite3 "$codex_home/state_5.sqlite" "SELECT title FROM threads WHERE id='thread-new'")"
    conv_id="$(session_record_json "TMUX--demo" "$meta" | jq -r '.conversation_id')"
    [[ "$old_title" == "old title" ]] || fail "stale Codex title should not change: $old_title"
    [[ "$new_title" == "Demo: fleet manager (TMUX--demo)" ]] || fail "current Codex title not updated: $new_title"
    [[ "$conv_id" == "thread-new" ]] || fail "metadata conversation_id not corrected: $conv_id"
    echo "ok: codex rename prefers prompt match over stale id"
}

test_session_app_ls_codex_records() {
    # Released Codex tasks no longer appear in `session ls` (tmux-live-only), so
    # cctrl has an app-first view over preserved metadata + Codex app state.
    local meta="$TMPDIR/app-ls-meta" codex_home="$TMPDIR/app-ls-codex"
    mkdir -p "$meta" "$codex_home"
    cat > "$meta/TMUX--appdemo.json" <<'JSON'
{"name":"TMUX--appdemo","cwd":"/tmp/demo","target_kind":"dir","target":"/tmp/demo","display_label":"/tmp/demo","purpose":"released task","agent":"codex","cctrl_managed":true,"created_at":"2026-08-24T10:00:00Z","conversation_id":"thread-app-1","transcript_path":null}
JSON
    python3 - "$codex_home/state_5.sqlite" <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT, cwd TEXT, archived INTEGER, updated_at TEXT)")
con.execute("INSERT INTO threads (id, title, name, cwd, archived, updated_at) VALUES (?, ?, ?, ?, ?, ?)", ("thread-app-1", "Demo: released task (TMUX--appdemo)", "Demo: released task (TMUX--appdemo)", "/tmp/demo", 0, "2026-08-24T10:02:00Z"))
con.commit()
PY

    local out
    out="$(CCTRL_SESSION_METADATA_DIR="$meta" CODEX_HOME="$codex_home" "$ROOT/cctrl" session app-ls --json)"
    assert_contains "$out" '"name": "TMUX--appdemo"'
    assert_contains "$out" '"state": "unknown"'
    assert_contains "$out" '"title": "Demo: released task (TMUX--appdemo)"'
    echo "ok: app-ls shows cctrl-known Codex app tasks"
}

test_codex_wrapper_exit_preserves_app_task() {
    # Wrapper exit alone must not archive: release-to-app ends the wrapper with
    # EOF and keeps the Codex app task available.
    local rootcopy="$TMPDIR/codex-preserve-wrapper" meta="$TMPDIR/codex-preserve-meta" codex_home="$TMPDIR/codex-preserve-home" bin="$TMPDIR/codex-preserve-bin"
    mkdir -p "$rootcopy/lib" "$meta" "$codex_home" "$bin"
    cp "$ROOT/lib/session-wrapper.sh" "$rootcopy/lib/session-wrapper.sh"
    chmod +x "$rootcopy/lib/session-wrapper.sh"
    cat > "$bin/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$bin/codex"
    cat > "$meta/TMUX--archive.json" <<'JSON'
{"name":"TMUX--archive","cwd":"/tmp/demo","target_kind":"dir","target":"/tmp/demo","display_label":"/tmp/demo","purpose":"archive task","agent":"codex","cctrl_managed":true,"created_at":"2026-08-25T10:00:00Z","conversation_id":"thread-archive-1","transcript_path":null}
JSON
    python3 - "$codex_home/state_5.sqlite" <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT, archived INTEGER)")
con.execute("INSERT INTO threads (id, title, name, archived) VALUES (?, ?, ?, ?)", ("thread-archive-1", "Demo", "Demo", 0))
con.commit()
PY

    PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" CODEX_HOME="$codex_home" \
        CCTRL_SESSION_NAME="TMUX--archive" "$rootcopy/lib/session-wrapper.sh" codex "$TMPDIR/archive-marker" --cd /tmp/demo
    local archived_at
    archived_at="$(sqlite3 "$codex_home/state_5.sqlite" "SELECT archived FROM threads WHERE id='thread-archive-1'")"
    [[ "$archived_at" == "0" ]] || fail "plain tmux wrapper exit archived Codex task"
    [[ -z "$(jq -r '.archived_at // empty' "$meta/TMUX--archive.json")" ]] || fail "plain wrapper exit wrote archive timestamp"

    echo "ok: plain tmux Codex exit preserves app task"
}

test_codex_close_archives_and_resolves_rollout_identity() {
    # Close must archive even when the async session-list/title sync has not
    # yet backfilled conversation_id; the matching live rollout is sufficient.
    local meta="$TMPDIR/codex-close-meta" codex_home="$TMPDIR/codex-close-home" bin="$TMPDIR/codex-close-bin"
    mkdir -p "$meta" "$codex_home/sessions/2026/08/25" "$bin"
    make_fake_tmux "$bin/tmux"
    cat > "$meta/TMUX--close.json" <<'JSON'
{"name":"TMUX--close","cwd":"/tmp/demo","target_kind":"dir","target":"/tmp/demo","display_label":"/tmp/demo","purpose":"close task","initial_prompt":"finish lifecycle","agent":"codex","cctrl_managed":true,"created_at":"2026-08-25T10:00:00Z","conversation_id":null,"transcript_path":null}
JSON
    cat > "$codex_home/sessions/2026/08/25/rollout-2026-08-25T10-01-00-thread-close.jsonl" <<'JSONL'
{"timestamp":"2026-08-25T10:01:00.000Z","type":"session_meta","payload":{"id":"thread-close","cwd":"/tmp/demo"}}
{"timestamp":"2026-08-25T10:01:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"finish lifecycle"}}
JSONL
    python3 - "$codex_home/state_5.sqlite" <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT, archived INTEGER)")
con.execute("INSERT INTO threads (id, title, name, archived) VALUES (?, ?, ?, ?)", ("thread-close", "cctrl: Codex close archives app task (TMUX--close)", "cctrl: Codex close archives app task (TMUX--close)", 0))
con.commit()
PY

    PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" CODEX_HOME="$codex_home" \
        TMUX_FAKE_HAS_SESSION=1 "$ROOT/cctrl" session close TMUX--close --now >/dev/null
    [[ "$(sqlite3 "$codex_home/state_5.sqlite" "SELECT archived FROM threads WHERE id='thread-close'")" == "1" ]] \
        || fail "cctrl close did not archive rollout-resolved Codex task"
    [[ "$(session_record_json "TMUX--close" "$meta" | jq -r '.conversation_id')" == "thread-close" ]] \
        || fail "close did not persist rollout-resolved conversation_id"
    [[ -n "$(session_record_json "TMUX--close" "$meta" | jq -r '.archived_at // empty')" ]] \
        || fail "close archive timestamp missing from metadata"
    echo "ok: Codex close archives and persists rollout identity"
}

test_session_release_to_app_quarantines_stale_codex_lock() {
    # A dead tmux-backed Codex record with a leftover writer lock can be released
    # to the app by moving the stale lock aside, preserving the metadata record.
    local bin="$TMPDIR/release-bin" meta="$TMPDIR/release-meta" codex_home="$TMPDIR/release-codex" backup="$TMPDIR/release-backup"
    mkdir -p "$bin" "$meta" "$codex_home/thread-writer-locks" "$backup"
    make_fake_tmux "$bin/tmux"
    cat > "$meta/TMUX--release.json" <<'JSON'
{"name":"TMUX--release","cwd":"/tmp/demo","target_kind":"dir","target":"/tmp/demo","display_label":"/tmp/demo","purpose":"release task","agent":"codex","cctrl_managed":true,"created_at":"2026-08-24T10:00:00Z","conversation_id":"thread-release-1","transcript_path":null}
JSON
    python3 - "$codex_home/state_5.sqlite" <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT, archived INTEGER)")
con.execute("INSERT INTO threads (id, title, name, archived) VALUES (?, ?, ?, ?)", ("thread-release-1", "Release", "Release", 0))
con.commit()
PY
    : > "$codex_home/thread-writer-locks/thread-release-1.lock"

    local out control released lock_path
    out="$(PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" CODEX_HOME="$codex_home" \
        CCTRL_CODEX_LOCK_BACKUP_DIR="$backup" "$ROOT/cctrl" session release-to-app TMUX--release --yes --json)"
    assert_contains "$out" '"status": "released"'
    assert_contains "$out" '"lock_action": "quarantined"'
    [[ ! -e "$codex_home/thread-writer-locks/thread-release-1.lock" ]] || fail "stale lock was not removed from live lock dir"
    lock_path="$backup/thread-release-1.lock"
    [[ -e "$lock_path" ]] || fail "stale lock was not quarantined to $lock_path"
    control="$(session_record_json "TMUX--release" "$meta" | jq -r '.control_surface')"
    released="$(session_record_json "TMUX--release" "$meta" | jq -r '.released_at // empty')"
    [[ "$control" == "unknown" ]] || fail "release incorrectly claimed app ownership: $control"
    [[ "$(session_record_json "TMUX--release" "$meta" | jq -r '.control_owner')" == "unknown" ]] || fail "release owner should remain unknown"
    [[ -n "$released" ]] || fail "metadata released_at not set"
    [[ "$(sqlite3 "$codex_home/state_5.sqlite" "SELECT archived FROM threads WHERE id='thread-release-1'")" == "0" ]] \
        || fail "release-to-app archived the Codex task"
    echo "ok: release-to-app quarantines stale Codex writer lock"
}

test_session_prune_dry_run_closes_nothing() {
    # Default is a dry run: candidates are listed but no kill/run-shell fires.
    # --yes routes each candidate through _session_close (tmux kill-session).
    local bin="$TMPDIR/dr-bin" sdir="$TMPDIR/dr-sess" pdir="$TMPDIR/dr-proj"
    mkdir -p "$bin" "$sdir" "$pdir/p"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *4646* ]]; then echo "claude"; exit 0; fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    local now_ms; now_ms=$(( $(date +%s) * 1000 ))
    cat > "$sdir/4646.json" <<JSON
{"pid":4646,"sessionId":"dr-uuid","updatedAt":$now_ms}
JSON
    cat > "$pdir/p/dr-uuid.jsonl" <<'JSON'
{"type":"summary","summary":"New session"}
JSON

    local log="$TMPDIR/prune-dry.log"; : > "$log"
    local out
    out="$(PATH="$bin:$PATH" TMUX_LOG="$log" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        TMUX_FAKE_SESSIONS="TMUX--drname" TMUX_FAKE_PANE_PID=4646 "$ROOT/cctrl" session prune)"
    assert_contains "$out" "TMUX--drname"
    assert_contains "$out" "dry-run"
    assert_not_contains "$(cat "$log")" "kill-session"
    assert_not_contains "$(cat "$log")" "run-shell"

    local log2="$TMPDIR/prune-yes.log"; : > "$log2"
    out="$(PATH="$bin:$PATH" TMUX_LOG="$log2" TMUX_FAKE_HAS_SESSION=1 \
        CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        TMUX_FAKE_SESSIONS="TMUX--drname" TMUX_FAKE_PANE_PID=4646 "$ROOT/cctrl" session prune --yes)"
    assert_contains "$(cat "$log2")" "kill-session -t TMUX--drname"
    echo "ok: prune dry-run closes nothing; --yes closes candidates"
}

test_session_prune_excludes_self_and_attached() {
    # Self (the current session) is never proposed; attached sessions are
    # excluded by default and only appear with --force.
    local bin="$TMPDIR/ex-bin" meta="$TMPDIR/ex-meta"
    mkdir -p "$bin" "$meta"
    # tmux stub: two sessions. TMUX--self is the current one (pane pid == our
    # pid via __current__); TMUX--attach reports session_attached=1.
    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
if [[ -n "${TMUX_LOG:-}" ]]; then printf 'TMUX %s\n' "$*" >> "$TMUX_LOG"; fi
target=""
for ((i=1;i<=$#;i++)); do
    if [[ "${!i}" == "-t" ]]; then j=$((i+1)); target="${!j:-}"; break; fi
done
case "${1:-}" in
    list-sessions) printf 'TMUX--self\nTMUX--attach\n'; exit 0;;
    list-panes)
        if [[ "$*" == *pane_current_path* ]]; then echo /tmp/demo; exit 0; fi
        if [[ "$target" == "TMUX--self" ]]; then echo "${CCTRL_CURRENT_PID:-5151}"; else echo 5252; fi
        exit 0;;
    display-message)
        if [[ "$*" == *session_name* ]]; then echo "TMUX--self"; exit 0; fi
        if [[ "$*" == *session_attached* && "$target" == "TMUX--attach" ]]; then echo 1; else echo 0; fi
        exit 0;;
    show-option) echo 1; exit 0;;
    has-session) exit 0;;
    *) exit 0;;
esac
SH
    chmod +x "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
echo "-zsh"; exit 0
SH
    chmod +x "$bin/ps"
    # Both sessions look stale via an old created_at (shell sessions, no
    # accurate last-active) so absent exclusion they WOULD be candidates.
    cat > "$meta/TMUX--self.json" <<'JSON'
{"created_at":"2023-11-14T00:00:00Z"}
JSON
    cat > "$meta/TMUX--attach.json" <<'JSON'
{"created_at":"2023-11-14T00:00:00Z"}
JSON

    local out
    out="$(PATH="$bin:$PATH" TMUX="fake,1,0" CCTRL_SESSION_METADATA_DIR="$meta" \
        CCTRL_CLAUDE_SESSIONS_DIR="$TMPDIR/ex-nope" CCTRL_CLAUDE_PROJECTS_DIR="$TMPDIR/ex-nope" \
        "$ROOT/cctrl" session prune --json)"
    assert_not_contains "$out" 'TMUX--self'
    assert_not_contains "$out" 'TMUX--attach'

    # --force lifts the attached exclusion (self stays excluded).
    out="$(PATH="$bin:$PATH" TMUX="fake,1,0" CCTRL_SESSION_METADATA_DIR="$meta" \
        CCTRL_CLAUDE_SESSIONS_DIR="$TMPDIR/ex-nope" CCTRL_CLAUDE_PROJECTS_DIR="$TMPDIR/ex-nope" \
        "$ROOT/cctrl" session prune --force --json)"
    assert_contains "$out" 'TMUX--attach'
    assert_not_contains "$out" 'TMUX--self'
    echo "ok: prune excludes self and (by default) attached sessions"
}

_snapshot_fixture() {
    # args: bindir sessdir projdir metadir [launch_command]
    local bin="$1" sdir="$2" pdir="$3" meta="$4" launch_cmd="${5:-}"
    mkdir -p "$bin" "$sdir" "$pdir/proj" "$meta"
    # tmux stub: one session TMUX--snap with a known pane pid
    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
target=""
for ((i=1;i<=$#;i++)); do
    if [[ "${!i}" == "-t" ]]; then j=$((i+1)); target="${!j:-}"; break; fi
done
case "${1:-}" in
    list-sessions) for s in $TMUX_FAKE_SESSIONS; do printf '%s\n' "$s"; done; exit 0;;
    list-panes)
        if [[ "$*" == *pane_current_path* ]]; then echo /tmp/demo; exit 0; fi
        echo 8888; exit 0;;
    display-message|display)
        if [[ "$*" == *session_name* ]]; then echo "${target:-TMUX--snap}"; exit 0; fi
        if [[ "$*" == *pane_in_mode* ]]; then echo 0; exit 0; fi
        echo 0; exit 0;;
    show-option) echo 1; exit 0;;
    capture-pane) exit 0;;
    *) exit 0;;
esac
SH
    chmod +x "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *8888* ]]; then echo "claude --model claude-fable-5 --remote-control"; exit 0; fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    local now_ms; now_ms=$(( $(date +%s) * 1000 ))
    cat > "$sdir/8888.json" <<JSON
{"pid":8888,"sessionId":"snap-conv-uuid","updatedAt":$now_ms,"status":"idle","bridgeSessionId":"bridge_snap"}
JSON
    # Transcript file for the session
    printf '{"type":"user","message":{"role":"user","content":"hello"}}\n' > "$pdir/proj/snap-conv-uuid.jsonl"
    # Session metadata record
    local lc
    lc="${launch_cmd:-claude --model claude-fable-5}"
    cat > "$meta/TMUX--snap.json" <<JSON
{"name":"TMUX--snap","cwd":"/tmp/demo","target":"/tmp/demo","target_kind":"dir","host":"test-host","display_label":"snap","purpose":"test snapshot","launch_command":"$lc","cctrl_managed":true,"created_at":"2026-08-01T00:00:00Z"}
JSON
}

test_snapshot_header_and_session_shape() {
    local bin="$TMPDIR/sh-bin" sdir="$TMPDIR/sh-sess" pdir="$TMPDIR/sh-proj" meta="$TMPDIR/sh-meta"
    local snapdir="$TMPDIR/sh-snapshots"
    mkdir -p "$snapdir"
    _snapshot_fixture "$bin" "$sdir" "$pdir" "$meta"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=100 \
        TMUX_FAKE_SESSIONS="TMUX--snap" "$ROOT/cctrl" session snapshot --dir "$snapdir" --json)"

    assert_contains "$out" '"schema_version": 1'
    assert_contains "$out" '"generated_at":'
    assert_contains "$out" '"hostname":'
    assert_contains "$out" '"session_count": 1'
    assert_contains "$out" '"resource_line":'
    assert_contains "$out" 'mem 50% free'
    assert_contains "$out" '"name": "TMUX--snap"'
    assert_contains "$out" '"state":'
    assert_contains "$out" '"attached":'
    assert_contains "$out" '"managed":'
    assert_contains "$out" '"purpose": "test snapshot"'
    assert_contains "$out" '"display_label": "snap"'
    assert_contains "$out" '"conversation_id": "snap-conv-uuid"'
    assert_contains "$out" '"cwd": "/tmp/demo"'
    assert_contains "$out" '"host": "test-host"'
    assert_contains "$out" '"launch_flags":'
    [[ -f "$snapdir/latest.json" ]] || fail "latest.json not created"
    local hcount
    hcount="$(find "$snapdir" -maxdepth 1 -type f -name '[0-9]*.json' -print | wc -l | tr -d ' ')"
    [[ "$hcount" -ge 1 ]] || fail "no history file created"
    echo "ok: snapshot header and per-session shape"
}

test_snapshot_initial_prompt_absent() {
    local bin="$TMPDIR/ip-bin" sdir="$TMPDIR/ip-sess" pdir="$TMPDIR/ip-proj" meta="$TMPDIR/ip-meta"
    local snapdir="$TMPDIR/ip-snapshots"
    mkdir -p "$snapdir"
    _snapshot_fixture "$bin" "$sdir" "$pdir" "$meta"
    cat > "$meta/TMUX--snap.json" <<'JSON'
{"name":"TMUX--snap","cwd":"/tmp/demo","target":"/tmp/demo","target_kind":"dir","host":"test-host","display_label":"snap","purpose":"test","initial_prompt":"do the thing","launch_command":"claude","cctrl_managed":true}
JSON

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=100 \
        TMUX_FAKE_SESSIONS="TMUX--snap" "$ROOT/cctrl" session snapshot --dir "$snapdir" --json)"
    assert_not_contains "$out" 'initial_prompt'
    echo "ok: initial_prompt absent from snapshot"
}

test_snapshot_empty_fleet_guard_preserves() {
    local bin="$TMPDIR/eg-bin" snapdir="$TMPDIR/eg-snapshots"
    mkdir -p "$bin" "$snapdir"
    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions) exit 0;;
    *) exit 0;;
esac
SH
    chmod +x "$bin/tmux"
    cat > "$snapdir/latest.json" <<'JSON'
{"schema_version":1,"session_count":2,"sessions":[{"name":"a"},{"name":"b"}]}
JSON
    local mtime_before
    mtime_before="$(stat -f %m "$snapdir/latest.json" 2>/dev/null || stat -c %Y "$snapdir/latest.json")"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$TMPDIR/eg-nope" CCTRL_CLAUDE_PROJECTS_DIR="$TMPDIR/eg-nope" \
        CCTRL_SESSION_METADATA_DIR="$TMPDIR/eg-nope" CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=100 \
        TMUX_FAKE_SESSIONS="" "$ROOT/cctrl" session snapshot --dir "$snapdir" 2>&1)"
    assert_contains "$out" 'preserving'
    local mtime_after
    mtime_after="$(stat -f %m "$snapdir/latest.json" 2>/dev/null || stat -c %Y "$snapdir/latest.json")"
    [[ "$mtime_before" == "$mtime_after" ]] || fail "latest.json was modified despite empty fleet guard"
    local preserved_sc
    preserved_sc="$(jq '.session_count' "$snapdir/latest.json")"
    [[ "$preserved_sc" == "2" ]] || fail "latest.json session_count changed; got: $preserved_sc"
    echo "ok: empty fleet guard preserves existing latest.json"
}

test_snapshot_allow_empty_overrides() {
    local bin="$TMPDIR/ae-bin" snapdir="$TMPDIR/ae-snapshots"
    mkdir -p "$bin" "$snapdir"
    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions) exit 0;;
    *) exit 0;;
esac
SH
    chmod +x "$bin/tmux"
    cat > "$snapdir/latest.json" <<'JSON'
{"schema_version":1,"session_count":2,"sessions":[{"name":"a"},{"name":"b"}]}
JSON

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$TMPDIR/ae-nope" CCTRL_CLAUDE_PROJECTS_DIR="$TMPDIR/ae-nope" \
        CCTRL_SESSION_METADATA_DIR="$TMPDIR/ae-nope" CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=100 \
        TMUX_FAKE_SESSIONS="" "$ROOT/cctrl" session snapshot --dir "$snapdir" --allow-empty --json 2>&1)"
    local sc
    sc="$(jq '.session_count' "$snapdir/latest.json")"
    [[ "$sc" == "0" ]] || fail "expected session_count 0 after --allow-empty; got: $sc"
    echo "ok: --allow-empty overrides the guard"
}

test_snapshot_history_and_latest_agree() {
    local bin="$TMPDIR/ha-bin" sdir="$TMPDIR/ha-sess" pdir="$TMPDIR/ha-proj" meta="$TMPDIR/ha-meta"
    local snapdir="$TMPDIR/ha-snapshots"
    mkdir -p "$snapdir"
    _snapshot_fixture "$bin" "$sdir" "$pdir" "$meta"

    PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=100 \
        TMUX_FAKE_SESSIONS="TMUX--snap" "$ROOT/cctrl" session snapshot --dir "$snapdir" --quiet

    local history_file latest_hash history_hash
    history_file="$(find "$snapdir" -maxdepth 1 -type f -name '[0-9]*.json' -print | sort | head -1)"
    [[ -n "$history_file" ]] || fail "no history file found"
    latest_hash="$(shasum "$snapdir/latest.json" | awk '{print $1}')"
    history_hash="$(shasum "$history_file" | awk '{print $1}')"
    [[ "$latest_hash" == "$history_hash" ]] || fail "history and latest.json differ"
    echo "ok: history and latest.json have identical content"
}

test_snapshot_retention_pruning() {
    local bin="$TMPDIR/rp-bin" sdir="$TMPDIR/rp-sess" pdir="$TMPDIR/rp-proj" meta="$TMPDIR/rp-meta"
    local snapdir="$TMPDIR/rp-snapshots"
    mkdir -p "$snapdir"
    _snapshot_fixture "$bin" "$sdir" "$pdir" "$meta"

    local now_epoch
    now_epoch="$(date +%s)"

    local f_recent="$snapdir/20260803T120000Z.json"
    echo '{}' > "$f_recent"
    touch -t "$(date -r $((now_epoch - 2 * 86400)) +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$((now_epoch - 2 * 86400))" +%Y%m%d%H%M.%S)" "$f_recent"

    local f_day10_first="$snapdir/20260726T080000Z.json"
    echo '{}' > "$f_day10_first"
    touch -t "$(date -r $((now_epoch - 10 * 86400)) +%Y%m%d%H%M.%S)" "$f_day10_first"

    local f_day10_second="$snapdir/20260726T120000Z.json"
    echo '{}' > "$f_day10_second"
    touch -t "$(date -r $((now_epoch - 10 * 86400)) +%Y%m%d%H%M.%S)" "$f_day10_second"

    local f_old="$snapdir/20260427T120000Z.json"
    echo '{}' > "$f_old"
    touch -t "$(date -r $((now_epoch - 100 * 86400)) +%Y%m%d%H%M.%S)" "$f_old"

    echo '{"session_count":0}' > "$snapdir/latest.json"

    PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=100 \
        TMUX_FAKE_SESSIONS="TMUX--snap" "$ROOT/cctrl" session snapshot --dir "$snapdir" --quiet

    [[ -f "$snapdir/latest.json" ]] || fail "latest.json was deleted"
    [[ -f "$f_recent" ]] || fail "recent file was pruned"
    [[ -f "$f_day10_first" ]] || fail "first-of-day file was pruned"
    [[ ! -f "$f_day10_second" ]] || fail "second-of-day file was NOT pruned"
    [[ ! -f "$f_old" ]] || fail "100-day-old file was NOT pruned"
    echo "ok: retention keeps/prunes correct files"
}

test_snapshot_no_tmux_mutation() {
    local body
    body="$(sed -n '/_session_snapshot()/,/^}/p' "$ROOT/cctrl")"
    if printf '%s' "$body" | grep -Eq 'send-keys|paste-buffer|load-buffer'; then
        fail "_session_snapshot contains tmux mutation commands"
    fi
    echo "ok: no tmux mutation in _session_snapshot"
}

test_snapshot_tmux_absent_preserves() {
    local bin="$TMPDIR/ta-bin" snapdir="$TMPDIR/ta-snapshots"
    mkdir -p "$bin" "$snapdir"
    cp "$TMPDIR/hostname" "$bin/hostname"
    cat > "$snapdir/latest.json" <<'JSON'
{"schema_version":1,"session_count":3,"sessions":[{"name":"a"},{"name":"b"},{"name":"c"}]}
JSON

    local out rc=0
    out="$(PATH="$bin:/usr/bin:/bin:/usr/local/bin" \
        CCTRL_CLAUDE_SESSIONS_DIR="$TMPDIR/ta-nope" CCTRL_CLAUDE_PROJECTS_DIR="$TMPDIR/ta-nope" \
        CCTRL_SESSION_METADATA_DIR="$TMPDIR/ta-nope" CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=100 \
        "$ROOT/cctrl" session snapshot --dir "$snapdir" 2>&1)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "snapshot with absent tmux should exit 0; got rc=$rc"
    assert_contains "$out" 'tmux'
    local sc
    sc="$(jq '.session_count' "$snapdir/latest.json")"
    [[ "$sc" == "3" ]] || fail "latest.json was modified when tmux absent; session_count=$sc"
    echo "ok: tmux absent preserves existing latest.json"
}

test_snapshot_first_run_empty_writes() {
    local bin="$TMPDIR/fr-bin" snapdir="$TMPDIR/fr-snapshots"
    mkdir -p "$bin" "$snapdir"
    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions) exit 0;;
    *) exit 0;;
esac
SH
    chmod +x "$bin/tmux"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$TMPDIR/fr-nope" CCTRL_CLAUDE_PROJECTS_DIR="$TMPDIR/fr-nope" \
        CCTRL_SESSION_METADATA_DIR="$TMPDIR/fr-nope" CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=100 \
        TMUX_FAKE_SESSIONS="" "$ROOT/cctrl" session snapshot --dir "$snapdir" --json 2>&1)"
    [[ -f "$snapdir/latest.json" ]] || fail "latest.json not created on first empty run"
    local sc
    sc="$(jq '.session_count' "$snapdir/latest.json")"
    [[ "$sc" == "0" ]] || fail "expected session_count 0 on first empty run; got: $sc"
    echo "ok: first run with empty fleet writes normally"
}

test_snapshot_transcript_bytes_null_when_missing() {
    local bin="$TMPDIR/tb-bin" sdir="$TMPDIR/tb-sess" pdir="$TMPDIR/tb-proj" meta="$TMPDIR/tb-meta"
    local snapdir="$TMPDIR/tb-snapshots"
    mkdir -p "$bin" "$sdir" "$pdir" "$meta" "$snapdir"
    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
target=""
for ((i=1;i<=$#;i++)); do
    if [[ "${!i}" == "-t" ]]; then j=$((i+1)); target="${!j:-}"; break; fi
done
case "${1:-}" in
    list-sessions) for s in $TMUX_FAKE_SESSIONS; do printf '%s\n' "$s"; done; exit 0;;
    list-panes)
        if [[ "$*" == *pane_current_path* ]]; then echo /tmp/demo; exit 0; fi
        echo 9090; exit 0;;
    display-message|display) echo 0; exit 0;;
    show-option) echo 1; exit 0;;
    capture-pane) exit 0;;
    *) exit 0;;
esac
SH
    chmod +x "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *9090* ]]; then echo "-zsh"; exit 0; fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    cat > "$meta/TMUX--notranscript.json" <<'JSON'
{"name":"TMUX--notranscript","cwd":"/tmp","target":"/tmp","target_kind":"dir","host":"test","cctrl_managed":true}
JSON

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=100 \
        TMUX_FAKE_SESSIONS="TMUX--notranscript" "$ROOT/cctrl" session snapshot --dir "$snapdir" --json)"
    local tb
    tb="$(printf '%s' "$out" | jq '.sessions[0].transcript_bytes')"
    [[ "$tb" == "null" ]] || fail "expected transcript_bytes null; got: $tb"
    echo "ok: transcript_bytes null when no transcript"
}

test_snapshot_managed_matches_session_ls() {
    local bin="$TMPDIR/mm-bin" sdir="$TMPDIR/mm-sess" pdir="$TMPDIR/mm-proj" meta="$TMPDIR/mm-meta"
    local snapdir="$TMPDIR/mm-snapshots"
    mkdir -p "$snapdir"
    _snapshot_fixture "$bin" "$sdir" "$pdir" "$meta"

    local ls_out snap_out ls_managed snap_managed
    ls_out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        CCTRL_SESSION_METADATA_DIR="$meta" TMUX_FAKE_SESSIONS="TMUX--snap" "$ROOT/cctrl" session ls --json)"
    ls_managed="$(printf '%s' "$ls_out" | jq '.[0].managed')"

    snap_out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=100 \
        TMUX_FAKE_SESSIONS="TMUX--snap" "$ROOT/cctrl" session snapshot --dir "$snapdir" --json)"
    snap_managed="$(printf '%s' "$snap_out" | jq '.sessions[0].managed')"

    [[ "$ls_managed" == "$snap_managed" ]] || fail "managed mismatch: ls=$ls_managed snapshot=$snap_managed"
    echo "ok: managed field matches session ls"
}

test_snapshot_launch_flags_round_trip() {
    local bin="$TMPDIR/lf-bin" sdir="$TMPDIR/lf-sess" pdir="$TMPDIR/lf-proj" meta="$TMPDIR/lf-meta"
    local snapdir="$TMPDIR/lf-snapshots"
    mkdir -p "$snapdir"
    _snapshot_fixture "$bin" "$sdir" "$pdir" "$meta" "claude --model claude-fable-5 --permission-mode bypassPermissions --peer fleet-mgr"

    local out lf_model lf_perm lf_peer
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=100 \
        TMUX_FAKE_SESSIONS="TMUX--snap" "$ROOT/cctrl" session snapshot --dir "$snapdir" --json)"
    lf_model="$(printf '%s' "$out" | jq -r '.sessions[0].launch_flags.model')"
    lf_perm="$(printf '%s' "$out" | jq -r '.sessions[0].launch_flags.permission_mode')"
    lf_peer="$(printf '%s' "$out" | jq -r '.sessions[0].launch_flags.peer')"
    [[ "$lf_model" == "claude-fable-5" ]] || fail "launch_flags.model should be claude-fable-5; got: $lf_model"
    [[ "$lf_perm" == "bypassPermissions" ]] || fail "launch_flags.permission_mode should be bypassPermissions; got: $lf_perm"
    [[ "$lf_peer" == "fleet-mgr" ]] || fail "launch_flags.peer should be fleet-mgr; got: $lf_peer"

    cat > "$meta/TMUX--snap.json" <<'JSON'
{"name":"TMUX--snap","cwd":"/tmp/demo","target":"/tmp/demo","target_kind":"dir","host":"test-host","cctrl_managed":true}
JSON
    local snapdir2="$TMPDIR/lf-snapshots2"
    mkdir -p "$snapdir2"
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=100 \
        TMUX_FAKE_SESSIONS="TMUX--snap" "$ROOT/cctrl" session snapshot --dir "$snapdir2" --json)"
    local lf_keys
    lf_keys="$(printf '%s' "$out" | jq '.sessions[0].launch_flags | keys | length')"
    [[ "$lf_keys" == "0" ]] || fail "empty launch_command should produce empty launch_flags; got $lf_keys keys"
    echo "ok: launch_flags round-trip"
}

test_snapshot_conversation_id_from_session_id() {
    local bin="$TMPDIR/ci-bin" sdir="$TMPDIR/ci-sess" pdir="$TMPDIR/ci-proj" meta="$TMPDIR/ci-meta"
    local snapdir="$TMPDIR/ci-snapshots"
    mkdir -p "$snapdir"
    _snapshot_fixture "$bin" "$sdir" "$pdir" "$meta"

    local ls_out snap_out ls_sid snap_cid
    ls_out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        CCTRL_SESSION_METADATA_DIR="$meta" TMUX_FAKE_SESSIONS="TMUX--snap" "$ROOT/cctrl" session ls --json)"
    ls_sid="$(printf '%s' "$ls_out" | jq -r '.[0].session_id')"

    snap_out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=100 \
        TMUX_FAKE_SESSIONS="TMUX--snap" "$ROOT/cctrl" session snapshot --dir "$snapdir" --json)"
    snap_cid="$(printf '%s' "$snap_out" | jq -r '.sessions[0].conversation_id')"

    [[ "$ls_sid" == "$snap_cid" ]] || fail "conversation_id ($snap_cid) should match session_id ($ls_sid)"
    [[ "$snap_cid" == "snap-conv-uuid" ]] || fail "conversation_id should be snap-conv-uuid; got: $snap_cid"
    echo "ok: conversation_id from session_id"
}

_restore_fixture() {
    # Build a restore test environment: fake snapshot, fake tmux, fake ps,
    # fake hostname, launch log seam.
    local dir="$1"
    mkdir -p "$dir/bin" "$dir/snapshots" "$dir/sessions" "$dir/projects" "$dir/session-metadata"

    # Fake hostname
    cat > "$dir/bin/hostname" <<'SH'
#!/usr/bin/env bash
printf 'test-host\n'
SH
    chmod +x "$dir/bin/hostname"

    # Fake tmux that reports controllable session lists
    cat > "$dir/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions)
        if [[ -n "${TMUX_FAKE_SESSIONS:-}" ]]; then
            for s in $TMUX_FAKE_SESSIONS; do printf '%s\n' "$s"; done
        fi
        exit 0 ;;
    list-panes)
        if [[ "$*" == *pane_current_path* ]]; then echo /tmp/demo; exit 0; fi
        echo 99999; exit 0 ;;
    display-message) echo 0; exit 0 ;;
    display) echo 0; exit 0 ;;
    show-option) echo 1; exit 0 ;;
    new-session) exit 0 ;;
    set-option) exit 0 ;;
    *) exit 0 ;;
esac
SH
    chmod +x "$dir/bin/tmux"

    # Fake ps
    cat > "$dir/bin/ps" <<'SH'
#!/usr/bin/env bash
exec /bin/ps "$@"
SH
    chmod +x "$dir/bin/ps"

    # Launch log
    export CCTRL_RESTORE_LAUNCH_LOG="$dir/launch.log"
    : > "$dir/launch.log"

    # Write a snapshot with diverse sessions
    local now_iso
    now_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    cat > "$dir/snapshots/latest.json" <<SNAP
{
  "schema_version": 1,
  "generated_at": "$now_iso",
  "hostname": "test-host",
  "session_count": 5,
  "resource_line": "mem 50% free / 100 MB swap",
  "sessions": [
    {
      "name": "TMUX--cctrl",
      "state": "working",
      "attached": false,
      "managed": true,
      "purpose": "session management",
      "display_label": "@cctrl",
      "conversation_id": "conv-aaa-111",
      "transcript_path": "/fake/transcripts/conv-aaa-111.jsonl",
      "transcript_bytes": 500000,
      "cwd": "/Users/test/dev/cctrl",
      "host": "test-host",
      "model": "claude-sonnet-4",
      "agent": "claude",
      "last_active": "2026-08-05T11:55:00Z",
      "created_at": "2026-08-05T10:00:00Z",
      "launch_flags": {
        "model": "claude-sonnet-4",
        "permission_mode": "bypassPermissions",
        "peer": "fleet-mgr"
      }
    },
    {
      "name": "TMUX--homelab",
      "state": "idle",
      "attached": false,
      "managed": true,
      "purpose": "homelab infra",
      "display_label": "@homelab",
      "conversation_id": "conv-bbb-222",
      "transcript_path": "/fake/transcripts/conv-bbb-222.jsonl",
      "transcript_bytes": 2000000,
      "cwd": "/Users/test/dev/homelab",
      "host": "test-host",
      "model": "claude-fable-5",
      "agent": "claude",
      "last_active": "2026-08-05T12:00:00Z",
      "created_at": "2026-08-05T09:00:00Z",
      "launch_flags": {
        "model": "claude-fable-5"
      }
    },
    {
      "name": "TMUX--nullconv",
      "state": "idle",
      "attached": false,
      "managed": true,
      "purpose": "no conversation",
      "display_label": "nullconv",
      "conversation_id": null,
      "transcript_path": "/fake/transcripts/orphan.jsonl",
      "transcript_bytes": 100,
      "cwd": "/Users/test/dev/other",
      "host": "test-host",
      "model": "claude-sonnet-4",
      "agent": "claude",
      "last_active": "2026-08-05T10:00:00Z",
      "created_at": "2026-08-05T08:00:00Z",
      "launch_flags": {}
    },
    {
      "name": "TMUX--codexproj",
      "state": "working",
      "attached": false,
      "managed": true,
      "purpose": "codex project",
      "display_label": "@codexproj",
      "conversation_id": "conv-ccc-333",
      "transcript_path": null,
      "transcript_bytes": 50000,
      "cwd": "/Users/test/dev/codexproj",
      "host": "test-host",
      "model": "o3",
      "agent": "codex",
      "last_active": "2026-08-05T11:00:00Z",
      "created_at": "2026-08-05T07:00:00Z",
      "launch_flags": {
        "agent": "codex"
      }
    },
    {
      "name": "TMUX--bigone",
      "state": "working",
      "attached": false,
      "managed": true,
      "purpose": "big transcript test",
      "display_label": "@bigone",
      "conversation_id": "conv-ddd-444",
      "transcript_path": "/fake/transcripts/conv-ddd-444.jsonl",
      "transcript_bytes": 5000000,
      "cwd": "/Users/test/dev/bigone",
      "host": "test-host",
      "model": "claude-opus-4",
      "agent": "claude",
      "last_active": "2026-08-05T11:30:00Z",
      "created_at": "2026-08-05T06:00:00Z",
      "launch_flags": {
        "model": "claude-opus-4",
        "no_bridge": true,
        "profile": "deep-work"
      }
    }
  ]
}
SNAP
}

test_restore_ordering_by_last_active() {
    local dir="$TMPDIR/restore-order"
    _restore_fixture "$dir"
    local out
    out="$(PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        TMUX_FAKE_SESSIONS="" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        CCTRL_RESTORE_MAX_ACTIVE=10 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/latest.json" \
        --dry-run --json 2>&1)"
    # last_active order: homelab (12:00) > cctrl (11:55) > bigone (11:30) > codex (11:00) > nullconv (10:00)
    local order
    order="$(printf '%s' "$out" | jq -r '.plan[] | select(.disposition=="restore") | .name' | tr '\n' ',')"
    assert_contains "$order" "TMUX--homelab"
    # homelab should come before cctrl
    local pos_homelab pos_cctrl
    pos_homelab="$(printf '%s' "$out" | jq '[.plan[] | select(.disposition=="restore") | .name] | to_entries[] | select(.value=="TMUX--homelab") | .key')"
    pos_cctrl="$(printf '%s' "$out" | jq '[.plan[] | select(.disposition=="restore") | .name] | to_entries[] | select(.value=="TMUX--cctrl") | .key')"
    [[ "$pos_homelab" -lt "$pos_cctrl" ]] || fail "homelab (12:00) should sort before cctrl (11:55), got homelab=$pos_homelab cctrl=$pos_cctrl"
    echo "ok: restore ordering by last_active"
}

test_restore_only_filter() {
    local dir="$TMPDIR/restore-only"
    _restore_fixture "$dir"
    local out
    out="$(PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        TMUX_FAKE_SESSIONS="" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        CCTRL_RESTORE_MAX_ACTIVE=10 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/latest.json" \
        --only cctrl --only homelab --dry-run --json 2>&1)"
    local restore_count
    restore_count="$(printf '%s' "$out" | jq '[.plan[] | select(.disposition=="restore")] | length')"
    [[ "$restore_count" -eq 2 ]] || fail "expected 2 restore candidates with --only cctrl --only homelab, got $restore_count"
    local filtered_count
    filtered_count="$(printf '%s' "$out" | jq '[.plan[] | select(.disposition=="filtered")] | length')"
    [[ "$filtered_count" -gt 0 ]] || fail "expected some filtered candidates"
    echo "ok: restore --only filter"
}

test_restore_cap_on_total() {
    local dir="$TMPDIR/restore-cap"
    _restore_fixture "$dir"
    # Pre-existing live sessions: set TMUX_FAKE_SESSIONS to simulate 6 live managed sessions
    # plus set up fake session data to make them look managed
    mkdir -p "$dir/cap-sessions"
    for pid_n in 30001 30002 30003 30004 30005 30006; do
        cat > "$dir/cap-sessions/$pid_n.json" <<JSON
{"pid":$pid_n,"sessionId":"live-$pid_n"}
JSON
    done
    cat > "$dir/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions)
        for s in TMUX--live1 TMUX--live2 TMUX--live3 TMUX--live4 TMUX--live5 TMUX--live6; do
            printf '%s\n' "$s"
        done
        exit 0 ;;
    list-panes)
        if [[ "$*" == *pane_current_path* ]]; then echo /tmp/demo; exit 0; fi
        target=""
        for ((i=1;i<=$#;i++)); do
            if [[ "${!i}" == "-t" ]]; then j=$((i+1)); target="${!j:-}"; break; fi
        done
        case "$target" in
            TMUX--live1) echo 30001 ;; TMUX--live2) echo 30002 ;;
            TMUX--live3) echo 30003 ;; TMUX--live4) echo 30004 ;;
            TMUX--live5) echo 30005 ;; TMUX--live6) echo 30006 ;;
            *) echo 99999 ;;
        esac
        exit 0 ;;
    display-message) echo 0; exit 0 ;;
    display) echo 0; exit 0 ;;
    show-option) echo 1; exit 0 ;;
    new-session) exit 0 ;;
    set-option) exit 0 ;;
    *) exit 0 ;;
esac
SH
    chmod +x "$dir/bin/tmux"
    cat > "$dir/bin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
    *3000*) echo "claude --model test"; exit 0 ;;
esac
exec /bin/ps "$@"
SH
    chmod +x "$dir/bin/ps"

    # Create metadata to make them managed
    for n in TMUX--live1 TMUX--live2 TMUX--live3 TMUX--live4 TMUX--live5 TMUX--live6; do
        cat > "$dir/session-metadata/$n.json" <<JSON
{"name":"$n","cctrl_managed":true,"cwd":"/tmp","purpose":"live"}
JSON
    done

    local out
    out="$(PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/cap-sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        CCTRL_RESTORE_MAX_ACTIVE=8 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/latest.json" \
        --dry-run --json 2>&1)"
    local restore_count deferred_count
    restore_count="$(printf '%s' "$out" | jq '[.plan[] | select(.disposition=="restore")] | length')"
    deferred_count="$(printf '%s' "$out" | jq '[.plan[] | select(.disposition=="deferred")] | length')"
    # 6 live + 2 restore = 8 = max. Remaining should be deferred (minus the null-conv skip)
    [[ "$restore_count" -le 2 ]] || fail "expected at most 2 restores with 6 live and max 8, got $restore_count"
    [[ "$deferred_count" -gt 0 ]] || fail "expected some deferred candidates with cap at 8"
    echo "ok: restore cap on total managed count"
}

test_restore_null_conversation_id_skipped() {
    local dir="$TMPDIR/restore-nullconv"
    _restore_fixture "$dir"
    local out
    out="$(PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        TMUX_FAKE_SESSIONS="" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        CCTRL_RESTORE_MAX_ACTIVE=10 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/latest.json" \
        --dry-run --json 2>&1)"
    # The nullconv session should be skipped
    local skipped
    skipped="$(printf '%s' "$out" | jq '[.plan[] | select(.disposition=="skipped" and .name=="TMUX--nullconv")] | length')"
    [[ "$skipped" -eq 1 ]] || fail "expected nullconv to be skipped, got $skipped"
    # It should never appear in restore
    local restored_null
    restored_null="$(printf '%s' "$out" | jq '[.plan[] | select(.disposition=="restore" and .name=="TMUX--nullconv")] | length')"
    [[ "$restored_null" -eq 0 ]] || fail "null conversation_id session should never be restored"
    # Check launch log is empty for nullconv
    ! grep -q "nullconv" "$dir/launch.log" || fail "nullconv should not appear in launch log"
    echo "ok: null conversation_id skipped"
}

test_restore_dry_run_spawns_nothing() {
    local dir="$TMPDIR/restore-dryrun"
    _restore_fixture "$dir"
    PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        TMUX_FAKE_SESSIONS="" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        CCTRL_RESTORE_MAX_ACTIVE=10 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/latest.json" \
        --dry-run --quiet 2>&1
    # Launch log should be empty (dry-run never writes to it)
    local log_content
    log_content="$(cat "$dir/launch.log")"
    [[ -z "$log_content" ]] || fail "dry-run should not write to launch log, got: $log_content"
    echo "ok: dry-run spawns nothing"
}

test_restore_gate_stops_below_threshold() {
    local dir="$TMPDIR/restore-gate"
    _restore_fixture "$dir"
    local rc=0
    PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        TMUX_FAKE_SESSIONS="" \
        CCTRL_FAKE_MEM_FREE_PCT=5 \
        CCTRL_FAKE_SWAP_MB=0 \
        CCTRL_RESTORE_MAX_ACTIVE=10 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/latest.json" \
        --yes --quiet 2>&1 || rc=$?
    [[ "$rc" -eq 2 ]] || fail "expected exit 2 when memory below threshold, got $rc"
    # Launch log should be empty
    local log_content
    log_content="$(cat "$dir/launch.log")"
    [[ -z "$log_content" ]] || fail "gate should prevent all spawns, got: $log_content"
    echo "ok: resource gate stops below threshold"
}

test_restore_limit_caps_spawns() {
    local dir="$TMPDIR/restore-limit"
    _restore_fixture "$dir"
    local out
    out="$(PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        TMUX_FAKE_SESSIONS="" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        CCTRL_RESTORE_MAX_ACTIVE=10 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/latest.json" \
        --limit 2 --yes --quiet 2>&1)"
    local spawn_count
    spawn_count="$(wc -l < "$dir/launch.log" | tr -d ' ')"
    [[ "$spawn_count" -le 2 ]] || fail "expected at most 2 spawns with --limit 2, got $spawn_count"
    echo "ok: --limit caps spawns"
}

test_restore_no_tty_no_yes_exits_2() {
    local dir="$TMPDIR/restore-notty"
    _restore_fixture "$dir"
    local rc=0
    PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        TMUX_FAKE_SESSIONS="" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        CCTRL_RESTORE_MAX_ACTIVE=10 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/latest.json" \
        < /dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 2 ]] || fail "expected exit 2 with no TTY and no --yes, got $rc"
    echo "ok: no TTY no --yes exits 2"
}

test_restore_unknown_schema_refused() {
    local dir="$TMPDIR/restore-schema"
    _restore_fixture "$dir"
    cat > "$dir/snapshots/bad.json" <<'JSON'
{"schema_version": 42, "hostname": "test-host", "sessions": []}
JSON
    local out rc=0
    out="$(PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        TMUX_FAKE_SESSIONS="" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/bad.json" \
        --yes 2>&1)" || rc=$?
    [[ "$rc" -eq 2 ]] || fail "expected exit 2 for unknown schema, got $rc"
    assert_contains "$out" "42"
    echo "ok: unknown schema_version refused"
}

test_restore_stale_snapshot_refused() {
    local dir="$TMPDIR/restore-stale"
    _restore_fixture "$dir"
    # Create a snapshot with an old timestamp
    local old_iso
    old_iso="$(date -u -v-2d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "2 days ago" +"%Y-%m-%dT%H:%M:%SZ")"
    cat > "$dir/snapshots/old.json" <<SNAP
{"schema_version": 1, "generated_at": "$old_iso", "hostname": "test-host", "session_count": 0, "sessions": []}
SNAP
    local rc=0
    PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        TMUX_FAKE_SESSIONS="" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        CCTRL_RESTORE_MAX_SNAPSHOT_AGE=86400 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/old.json" \
        2>&1 || rc=$?
    [[ "$rc" -eq 2 ]] || fail "expected exit 2 for stale snapshot without --stale-ok, got $rc"
    echo "ok: stale snapshot refused"
}

test_restore_host_mismatch_refused() {
    local dir="$TMPDIR/restore-host"
    _restore_fixture "$dir"
    local now_iso
    now_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    cat > "$dir/snapshots/other.json" <<SNAP
{"schema_version": 1, "generated_at": "$now_iso", "hostname": "other-machine", "session_count": 0, "sessions": []}
SNAP
    local out rc=0
    out="$(PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        TMUX_FAKE_SESSIONS="" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/other.json" \
        --yes 2>&1)" || rc=$?
    [[ "$rc" -eq 2 ]] || fail "expected exit 2 for host mismatch, got $rc"
    assert_contains "$out" "other-machine"
    assert_contains "$out" "test-host"
    echo "ok: host mismatch refused"
}

test_restore_cap_fails_closed() {
    local dir="$TMPDIR/restore-capfail"
    _restore_fixture "$dir"
    # Shadow tmux with a script that fails `command -v` by being absent,
    # so _session_require_tmux fails inside _session_list.
    rm -f "$dir/bin/tmux"
    # Build a PATH that includes the fake bin dir (for hostname etc) and
    # the standard system dirs but excludes homebrew (where real tmux lives).
    local out rc=0
    out="$(PATH="$dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/latest.json" \
        --yes 2>&1)" || rc=$?
    [[ "$rc" -eq 2 ]] || fail "expected exit 2 when session list fails, got $rc"
    assert_contains "$out" "unavailable"
    echo "ok: cap fails closed"
}

test_restore_picker_expected_routing() {
    local dir="$TMPDIR/restore-picker"
    _restore_fixture "$dir"
    local out
    out="$(PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        TMUX_FAKE_SESSIONS="" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        CCTRL_RESTORE_MAX_ACTIVE=10 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/latest.json" \
        --dry-run --json 2>&1)"
    # bigone has 5000000 bytes -> picker expected
    local bigone_picker
    bigone_picker="$(printf '%s' "$out" | jq -r '.plan[] | select(.name=="TMUX--bigone") | .picker')"
    [[ "$bigone_picker" == "expected" ]] || fail "expected picker=expected for bigone (5MB), got: $bigone_picker"
    # cctrl has 500000 bytes -> picker not expected
    local cctrl_picker
    cctrl_picker="$(printf '%s' "$out" | jq -r '.plan[] | select(.name=="TMUX--cctrl") | .picker')"
    [[ "$cctrl_picker" == "not expected" ]] || fail "expected picker='not expected' for cctrl (500K), got: $cctrl_picker"
    # codexproj is codex agent -> picker n/a
    local codex_picker
    codex_picker="$(printf '%s' "$out" | jq -r '.plan[] | select(.name=="TMUX--codexproj") | .picker')"
    [[ "$codex_picker" == "n/a (codex)" ]] || fail "expected picker='n/a (codex)' for codex session, got: $codex_picker"
    echo "ok: picker expected routing"
}

test_restore_wave_pacing() {
    local dir="$TMPDIR/restore-wave"
    _restore_fixture "$dir"
    PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        TMUX_FAKE_SESSIONS="" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        CCTRL_RESTORE_MAX_ACTIVE=10 \
        CCTRL_RESTORE_WAVE_SIZE=2 \
        CCTRL_RESTORE_WAVE_PAUSE=0 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/latest.json" \
        --yes --quiet 2>&1
    # With 4 restorable sessions and wave size 2, we should get 4 spawns across 2 waves
    local spawn_count
    spawn_count="$(wc -l < "$dir/launch.log" | tr -d ' ')"
    [[ "$spawn_count" -eq 4 ]] || fail "expected 4 spawns with wave pacing, got $spawn_count"
    echo "ok: wave pacing"
}

test_restore_already_live_skipped() {
    local dir="$TMPDIR/restore-live"
    _restore_fixture "$dir"
    # Make one of the snapshot sessions already live
    mkdir -p "$dir/live-sessions"
    cat > "$dir/live-sessions/40001.json" <<'JSON'
{"pid":40001,"sessionId":"conv-aaa-111"}
JSON
    cat > "$dir/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions) printf 'TMUX--already-live\n'; exit 0 ;;
    list-panes)
        if [[ "$*" == *pane_current_path* ]]; then echo /tmp/demo; exit 0; fi
        echo 40001; exit 0 ;;
    display-message) echo 0; exit 0 ;;
    display) echo 0; exit 0 ;;
    show-option) echo 1; exit 0 ;;
    new-session) exit 0 ;;
    set-option) exit 0 ;;
    *) exit 0 ;;
esac
SH
    chmod +x "$dir/bin/tmux"
    cat > "$dir/bin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in *40001*) echo "claude --model test"; exit 0 ;; esac
exec /bin/ps "$@"
SH
    chmod +x "$dir/bin/ps"
    cat > "$dir/session-metadata/TMUX--already-live.json" <<'JSON'
{"name":"TMUX--already-live","cctrl_managed":true,"cwd":"/tmp","purpose":"live"}
JSON

    local out
    out="$(PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/live-sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        CCTRL_RESTORE_MAX_ACTIVE=10 \
        CCTRL_RESTORE_WAVE_PAUSE=0 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/latest.json" \
        --yes --json 2>&1)"
    local already
    already="$(printf '%s' "$out" | jq '.already_live')"
    [[ "$already" -ge 1 ]] || fail "expected at least 1 already-live, got $already"
    # conv-aaa-111 should not appear in launch log
    ! grep -q "conv-aaa-111" "$dir/launch.log" || fail "already-live conversation should not be spawned"
    echo "ok: already-live skipped"
}

test_restore_launch_config_replay() {
    local dir="$TMPDIR/restore-config"
    _restore_fixture "$dir"
    PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        TMUX_FAKE_SESSIONS="" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        CCTRL_RESTORE_MAX_ACTIVE=10 \
        CCTRL_RESTORE_WAVE_PAUSE=0 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/latest.json" \
        --yes --quiet 2>&1
    # Check that launch_flags.model produces --model in the launch log
    assert_contains "$(cat "$dir/launch.log")" "--model claude-sonnet-4"
    assert_contains "$(cat "$dir/launch.log")" "--model claude-fable-5"
    assert_contains "$(cat "$dir/launch.log")" "--model claude-opus-4"
    # Check --no-bridge for bigone
    assert_contains "$(cat "$dir/launch.log")" "--no-bridge"
    # Check --peer for cctrl session
    assert_contains "$(cat "$dir/launch.log")" "--peer fleet-mgr"
    # Check --profile for bigone
    assert_contains "$(cat "$dir/launch.log")" "--profile deep-work"
    echo "ok: launch config replay"
}

test_restore_no_force_structural() {
    # Structural: the _session_restore function body (excluding comments and
    # --force-host references) must not contain --force.
    local body
    body="$(sed -n '/_session_restore()/,/^}/p' "$ROOT/cctrl" | grep -v '^\s*#' | grep -v 'force-host\|force_host')"
    if printf '%s' "$body" | grep -q -- '--force'; then
        fail "_session_restore contains --force (must never pass --force to cctrl start)"
    fi
    echo "ok: no --force structural"
}

test_restore_no_pane_inference_structural() {
    # Structural: _session_restore must contain no send-keys, paste-buffer,
    # load-buffer, or capture-pane.
    local body
    body="$(sed -n '/_session_restore()/,/^}/p' "$ROOT/cctrl" | grep -v '^\s*#')"
    if printf '%s' "$body" | grep -Eq 'send-keys|paste-buffer|load-buffer|capture-pane'; then
        fail "_session_restore contains pane inference commands"
    fi
    echo "ok: no pane inference structural"
}

test_restore_already_live_record_join() {
    # A live session whose *record* (metadata JSON) has the conversation_id but
    # whose live session_id is empty should still be recognized as already-live.
    local dir="$TMPDIR/restore-recordjoin"
    _restore_fixture "$dir"
    mkdir -p "$dir/rj-sessions"
    # No live session file — session_id will be empty
    cat > "$dir/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions) printf 'TMUX--record-holder\n'; exit 0 ;;
    list-panes)
        if [[ "$*" == *pane_current_path* ]]; then echo /tmp/demo; exit 0; fi
        echo 50001; exit 0 ;;
    display-message) echo 0; exit 0 ;;
    display) echo 0; exit 0 ;;
    show-option) echo 1; exit 0 ;;
    new-session) exit 0 ;;
    set-option) exit 0 ;;
    *) exit 0 ;;
esac
SH
    chmod +x "$dir/bin/tmux"
    cat > "$dir/bin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in *50001*) echo "claude"; exit 0 ;; esac
exec /bin/ps "$@"
SH
    chmod +x "$dir/bin/ps"
    # Record has conversation_id matching a snapshot session
    cat > "$dir/session-metadata/TMUX--record-holder.json" <<'JSON'
{"name":"TMUX--record-holder","cctrl_managed":true,"cwd":"/tmp","purpose":"live","conversation_id":"conv-bbb-222"}
JSON

    local out
    out="$(PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/rj-sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        CCTRL_RESTORE_MAX_ACTIVE=10 \
        CCTRL_RESTORE_WAVE_PAUSE=0 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/latest.json" \
        --yes --json 2>&1)"
    local already
    already="$(printf '%s' "$out" | jq '.already_live')"
    [[ "$already" -ge 1 ]] || fail "expected at least 1 already-live from record join, got $already"
    ! grep -q "conv-bbb-222" "$dir/launch.log" || fail "record-joined conversation should not be spawned"
    echo "ok: already-live record join"
}

test_restore_exit_codes() {
    local dir="$TMPDIR/restore-exit"
    _restore_fixture "$dir"

    # Exit 0: all-already-live (use a snapshot with only one session, and it's already live)
    local now_iso
    now_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    cat > "$dir/snapshots/one.json" <<SNAP
{"schema_version":1,"generated_at":"$now_iso","hostname":"test-host","session_count":1,"sessions":[
  {"name":"TMUX--only","managed":true,"conversation_id":"conv-only","cwd":"/tmp","purpose":"test","display_label":"only","agent":"claude","transcript_bytes":100,"last_active":"2026-08-05T12:00:00Z","launch_flags":{}}
]}
SNAP
    mkdir -p "$dir/exit-sessions"
    cat > "$dir/exit-sessions/60001.json" <<'JSON'
{"pid":60001,"sessionId":"conv-only"}
JSON
    cat > "$dir/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions) printf 'TMUX--live-only\n'; exit 0 ;;
    list-panes)
        if [[ "$*" == *pane_current_path* ]]; then echo /tmp/demo; exit 0; fi
        echo 60001; exit 0 ;;
    display-message) echo 0; exit 0 ;;
    display) echo 0; exit 0 ;;
    show-option) echo 1; exit 0 ;;
    *) exit 0 ;;
esac
SH
    chmod +x "$dir/bin/tmux"
    cat > "$dir/bin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in *60001*) echo "claude"; exit 0 ;; esac
exec /bin/ps "$@"
SH
    chmod +x "$dir/bin/ps"
    cat > "$dir/session-metadata/TMUX--live-only.json" <<'JSON'
{"name":"TMUX--live-only","cctrl_managed":true,"cwd":"/tmp","purpose":"live"}
JSON

    local rc=0
    PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/exit-sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        CCTRL_RESTORE_MAX_ACTIVE=10 \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/one.json" \
        --yes --quiet 2>/dev/null || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected exit 0 for all-already-live, got $rc"

    # Exit 2: unreadable snapshot
    rc=0
    PATH="$dir/bin:$PATH" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$dir/exit-sessions" \
        CCTRL_CLAUDE_PROJECTS_DIR="$dir/projects" \
        CCTRL_FAKE_MEM_FREE_PCT=80 \
        CCTRL_FAKE_SWAP_MB=0 \
        "$ROOT/cctrl" session restore --from "/nonexistent/path.json" \
        --yes 2>/dev/null || rc=$?
    [[ "$rc" -eq 2 ]] || fail "expected exit 2 for unreadable snapshot, got $rc"

    echo "ok: exit codes"
}

test_usage_cost_fixtures() {
    local base="$TMPDIR/fixtures"
    local claude_dir
    claude_dir="$base/claude/projects/$(printf %s "$HOME/dev/demo" | tr -c "[:alnum:]" -)"
    local archive_dir="$base/codex/archived_sessions"
    local claude_ts claude_user_ts codex_meta_ts codex_context_ts codex_token_ts codex_path primary_reset secondary_reset
    { IFS= read -r claude_ts
      IFS= read -r claude_user_ts
      IFS= read -r codex_meta_ts
      IFS= read -r codex_context_ts
      IFS= read -r codex_token_ts
      IFS= read -r codex_path
      IFS= read -r primary_reset
      IFS= read -r secondary_reset
    } < <(python3 - <<'PY'
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

tz = ZoneInfo("Europe/Berlin")
now = datetime.now(timezone.utc).astimezone(tz)
days_since_thu = (now.weekday() - 3) % 7
start = (now - timedelta(days=days_since_thu)).replace(hour=6, minute=0, second=0, microsecond=0)
if now < start:
    start -= timedelta(days=7)
base = (start + timedelta(hours=1)).astimezone(timezone.utc)

def iso(dt):
    return dt.isoformat().replace("+00:00", "Z")

print(iso(base))
print(iso(base + timedelta(seconds=1)))
print(iso(base + timedelta(hours=1)))
print(iso(base + timedelta(hours=1, seconds=1)))
print(iso(base + timedelta(hours=1, seconds=2)))
print(base.strftime("%Y/%m/%d"))
print(iso(base + timedelta(hours=5)))
print(iso(start.astimezone(timezone.utc) + timedelta(days=7)))
PY
    )
    local codex_dir="$base/codex/sessions/$codex_path"
    mkdir -p "$claude_dir" "$codex_dir" "$archive_dir"

    cat > "$claude_dir/claude-session.jsonl" <<JSONL
{"timestamp":"$claude_ts","sessionId":"claude-session","type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":200,"cache_creation_input_tokens":300,"cache_read_input_tokens":400}}}
{"timestamp":"$claude_user_ts","type":"user","message":{"role":"user","content":"ok"}}
JSONL

    cat > "$codex_dir/codex-session.jsonl" <<JSONL
{"timestamp":"$codex_meta_ts","type":"session_meta","payload":{"id":"codex-session","cwd":"$HOME/dev/demo"}}
{"timestamp":"$codex_context_ts","type":"turn_context","payload":{"cwd":"$HOME/dev/demo","model":"gpt-5.5"}}
{"timestamp":"$codex_token_ts","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":250,"output_tokens":100,"reasoning_output_tokens":10},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":250,"output_tokens":100,"reasoning_output_tokens":10}},"rate_limits":{"plan_type":"plus","primary":{"used_percent":12,"resets_at":"$primary_reset"},"secondary":{"used_percent":34,"resets_at":"$secondary_reset"}}}}
JSONL

    local out
    out="$(python3 "$ROOT/lib/usage_costs.py" costs "$base/claude/projects" "$base/codex/sessions" "$archive_dir" 1 demo "")"
    assert_contains "$out" "By Agent"
    assert_contains "$out" "claude"
    assert_contains "$out" "codex"
    assert_contains "$out" "gpt-5.5"
    assert_contains "$out" "claude-sonnet-4-6"

    out="$(python3 "$ROOT/lib/usage_costs.py" usage "$base/rate-limits.json" "$base/history.jsonl" "$base/claude/projects" "$base/codex/sessions" "$archive_dir" 1)"
    assert_contains "$out" "Codex Plan Usage"
    assert_contains "$out" "plus"
    assert_contains "$out" "Billing Weeks"
    assert_contains "$out" "Agent"
    assert_contains "$out" "API Value"
    assert_contains "$out" "codex:"
}

test_project_name_derives_home_at_runtime() {
    # Regression: claude_project_name matched the literal strings
    # '-Users-matthew--projects-' and '-Users-matthew-', so on any machine whose
    # home directory was not the author's, EVERY Claude project fell through to
    # its raw encoded path in the `By Project` column. The encoded-$HOME prefix
    # must be derived from the running user's HOME instead. Driven through a
    # fake HOME so the assertion is about the code, not this machine.
    local probe="$TMPDIR/project-name-probe.py"
    cat > "$probe" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/lib")
import usage_costs as u

enc = u.encoded_home()
assert enc == "-Users-someone-else", enc

# A project under the running user's HOME renders tilde-relative.
print(u.claude_project_name("/p", "/p/" + enc + "-dev-demo/s.jsonl"))
# HOME itself.
print(u.claude_project_name("/p", "/p/" + enc + "/s.jsonl"))
# A path outside HOME is left alone rather than mangled.
print(u.claude_project_name("/p", "/p/-opt-apps-thing/s.jsonl"))
# A loose file at the top level keeps its name.
print(u.claude_project_name("/p", "/p/loose.jsonl"))
# Codex reports a real cwd, not an encoded one.
print(u.codex_project_name("/Users/someone-else/dev/demo"))
print(u.codex_project_name("/Users/someone-else"))
print(u.codex_project_name("/opt/apps/thing"))
PY

    local out
    out="$(HOME=/Users/someone-else python3 "$probe" "$ROOT")"
    local expected tilde='~'
    expected="$(printf '%s\n' "$tilde/dev-demo" "$tilde" '-opt-apps-thing' 'loose.jsonl' 'demo' "$tilde" 'thing')"
    [[ "$out" == "$expected" ]] || fail "project naming did not track HOME; got:
$out
expected:
$expected"

    # And the author's old hardcoded username must not reappear in the source.
    if grep -q 'Users-matthew' "$ROOT/lib/usage_costs.py"; then
        fail "lib/usage_costs.py still hardcodes a personal home directory"
    fi
    echo "ok: project naming derives the encoded \$HOME at runtime (no hardcoded username)"
}

# ── Fleet aggregation ────────────────────────────────────────────────
# `cctrl fleet` shells out to each remote host's `cctrl session ls --json`.
# We stub that per-host invocation by putting a fake `ssh` on PATH that emits a
# canned fixture keyed by the target hostname (or fails, to model an offline
# host) — so NO real SSH ever happens. The local host is queried in-process via
# the fake tmux/ps already used by the session-ls tests.
make_fleet_ssh() {
    # Fake ssh: last positional arg is the remote command, the one before it is
    # the target. Emits $FLEET_FIXTURES/<target>.json when present; a target
    # containing "offline" exits non-zero (unreachable); otherwise emits [].
    local path="$1"
    cat > "$path" <<'SH'
#!/usr/bin/env bash
target="${@:(-2):1}"
case "$target" in
    *offline*)
        echo "ssh: connect to host $target port 22: Connection refused" >&2
        exit 255
        ;;
esac
fixture="${FLEET_FIXTURES:-}/$target.json"
if [[ -n "${FLEET_FIXTURES:-}" && -f "$fixture" ]]; then
    cat "$fixture"
    exit 0
fi
echo "[]"
exit 0
SH
    chmod +x "$path"
}

fleet_rootcopy() {
    # Copy cctrl into an isolated root so HOSTS_FILE (=<root>/data/hosts.json)
    # can be controlled per test without touching the repo's data/hosts.json.
    local root="$1" hosts_json="$2"
    mkdir -p "$root/data"
    cp "$ROOT/cctrl" "$root/cctrl"
    chmod +x "$root/cctrl"
    printf '%s\n' "$hosts_json" > "$root/data/hosts.json"
}

test_fleet_merges_multiple_hosts() {
    local bin="$TMPDIR/fleet-multi-bin"
    local root="$TMPDIR/fleet-multi-root"
    local fix="$TMPDIR/fleet-multi-fix"
    mkdir -p "$bin" "$fix"
    make_fake_tmux "$bin/tmux"
    make_fake_ps "$bin/ps"
    make_fleet_ssh "$bin/ssh"
    fleet_rootcopy "$root" '{"hA":{"hostname":"a.invalid","user":""},"hB":{"hostname":"b.invalid","user":""}}'
    printf '[{"name":"recent","dir":"/r","state":"working","attached":false,"last_active":"2026-06-30T00:00:00Z"}]\n' > "$fix/a.invalid.json"
    printf '[{"name":"old","dir":"/o","state":"idle","attached":false,"last_active":"2025-01-01T00:00:00Z"}]\n' > "$fix/b.invalid.json"

    local out
    out="$(PATH="$bin:$PATH" FLEET_FIXTURES="$fix" CCTRL_TEST_HOSTNAME=fleet-local.example \
        "$root/cctrl" fleet --json)"
    # Rows from more than one distinct host (local + hA + hB).
    local distinct
    distinct="$(printf '%s' "$out" | jq -r '[.[].host] | unique | length')"
    [[ "$distinct" -ge 2 ]] || fail "fleet --json should merge >1 distinct host (got $distinct)"
    assert_contains "$out" '"host": "hA"'
    assert_contains "$out" '"host": "hB"'
    assert_contains "$out" '"host": "local"'
    echo "ok: fleet merges + labels multiple hosts"
}

test_fleet_sorts_by_recency_across_hosts() {
    local bin="$TMPDIR/fleet-sort-bin"
    local root="$TMPDIR/fleet-sort-root"
    local fix="$TMPDIR/fleet-sort-fix"
    mkdir -p "$bin" "$fix"
    make_fake_tmux "$bin/tmux"
    make_fake_ps "$bin/ps"
    make_fleet_ssh "$bin/ssh"
    fleet_rootcopy "$root" '{"hA":{"hostname":"a.invalid","user":""},"hB":{"hostname":"b.invalid","user":""}}'
    printf '[{"name":"newest","dir":"/n","state":"working","attached":false,"last_active":"2026-06-30T00:00:00Z"}]\n' > "$fix/a.invalid.json"
    printf '[{"name":"older","dir":"/o","state":"idle","attached":false,"last_active":"2025-01-01T00:00:00Z"}]\n' > "$fix/b.invalid.json"

    local out first second
    out="$(PATH="$bin:$PATH" FLEET_FIXTURES="$fix" CCTRL_TEST_HOSTNAME=fleet-local.example \
        "$root/cctrl" fleet --json)"
    # Sessions with a real last_active sort first, most-recent first.
    first="$(printf '%s' "$out" | jq -r '[.[] | select(.last_active != null)][0].host')"
    second="$(printf '%s' "$out" | jq -r '[.[] | select(.last_active != null)][1].host')"
    [[ "$first" == "hA" ]] || fail "most-recent host should sort first (got $first)"
    [[ "$second" == "hB" ]] || fail "older host should sort after newer (got $second)"
    echo "ok: fleet sorts by last-active across hosts"
}

test_fleet_offline_host_non_fatal() {
    local bin="$TMPDIR/fleet-offline-bin"
    local root="$TMPDIR/fleet-offline-root"
    local fix="$TMPDIR/fleet-offline-fix"
    mkdir -p "$bin" "$fix"
    make_fake_tmux "$bin/tmux"
    make_fake_ps "$bin/ps"
    make_fleet_ssh "$bin/ssh"
    fleet_rootcopy "$root" '{"ms":{"hostname":"offline.invalid","user":""}}'

    local out rc=0
    out="$(PATH="$bin:$PATH" FLEET_FIXTURES="$fix" CCTRL_TEST_HOSTNAME=fleet-local.example \
        "$root/cctrl" fleet --json)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "fleet must exit 0 even when a host is unreachable (rc=$rc)"
    local offhost
    offhost="$(printf '%s' "$out" | jq -r '.[] | select(.offline == true) | .host')"
    [[ "$offhost" == "ms" ]] || fail "unreachable host should be marked offline (got '$offhost')"

    # Human table also shows the offline marker and still exits 0.
    local human
    human="$(PATH="$bin:$PATH" FLEET_FIXTURES="$fix" CCTRL_TEST_HOSTNAME=fleet-local.example \
        "$root/cctrl" fleet)" || fail "fleet (human) must exit 0 with an offline host"
    assert_contains "$human" "offline"
    echo "ok: fleet tolerates an offline host (exit 0, marked offline)"
}

test_fleet_version_skew_missing_fields() {
    local bin="$TMPDIR/fleet-skew-bin"
    local root="$TMPDIR/fleet-skew-root"
    local fix="$TMPDIR/fleet-skew-fix"
    mkdir -p "$bin" "$fix"
    make_fake_tmux "$bin/tmux"
    make_fake_ps "$bin/ps"
    make_fleet_ssh "$bin/ssh"
    fleet_rootcopy "$root" '{"hOld":{"hostname":"old.invalid","user":""}}'
    # Older cctrl: rows lack last_active AND state entirely.
    printf '[{"name":"legacy","dir":"/legacy"}]\n' > "$fix/old.invalid.json"

    local out rc=0
    out="$(PATH="$bin:$PATH" FLEET_FIXTURES="$fix" CCTRL_TEST_HOSTNAME=fleet-local.example \
        "$root/cctrl" fleet --json)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "fleet must not crash on version-skew rows (rc=$rc)"
    # Missing fields defaulted to null (never absent -> never crash the merge).
    local la st
    la="$(printf '%s' "$out" | jq -r '.[] | select(.host == "hOld") | .last_active')"
    st="$(printf '%s' "$out" | jq -r '.[] | select(.host == "hOld") | .state')"
    [[ "$la" == "null" ]] || fail "missing last_active should default to null (got '$la')"
    [[ "$st" == "null" ]] || fail "missing state should default to null (got '$st')"

    # Human table renders those cells as '-'.
    local human
    human="$(PATH="$bin:$PATH" FLEET_FIXTURES="$fix" CCTRL_TEST_HOSTNAME=fleet-local.example \
        "$root/cctrl" fleet)" || fail "fleet (human) must render skew rows without crashing"
    assert_contains "$human" "legacy"
    assert_contains "$human" "hOld"
    # The legacy row's state/last-active columns are '-'.
    local legacy_line
    legacy_line="$(printf '%s\n' "$human" | grep legacy || true)"
    assert_contains "$legacy_line" "-"
    echo "ok: fleet tolerates version-skew (missing last_active/state -> '-')"
}

test_session_say_submit_and_no_submit() {
    # `session say` pastes an exact body into a live tmux session and submits
    # with Enter by default; --no-submit pastes without pressing Enter. It never
    # touches mailbox state. The pane runs codex (fake ps, pane pid 12345) with a
    # benign capture, so readiness passes without --force-busy.
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_ps "$TMPDIR/ps"
    local log="$TMPDIR/say-submit.log" out
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        "$ROOT/cctrl" session say TMUX--demo --json -- "hello there")"
    printf '%s\n' "$out" | jq -e '.ok == true and .session == "TMUX--demo" and .submitted == true and .status == "ok"' >/dev/null \
        || fail "expected session say submit ok result"
    assert_contains "$(cat "$log")" "BUFFER hello there"
    assert_contains "$(cat "$log")" "paste-buffer -b cctrl-say-TMUX--demo-"
    assert_contains "$(cat "$log")" "send-keys -t TMUX--demo Enter"
    # No mailbox file is created or touched by a direct say.
    [[ ! -e "$TMPDIR/data/messages.jsonl" ]] || fail "session say must not write messages.jsonl"

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        "$ROOT/cctrl" session say TMUX--demo --no-submit --json -- "no enter please")"
    printf '%s\n' "$out" | jq -e '.ok == true and .submitted == false and .status == "ok"' >/dev/null \
        || fail "expected session say --no-submit result"
    assert_contains "$(cat "$log")" "paste-buffer -b cctrl-say-TMUX--demo-"
    assert_not_contains "$(cat "$log")" "send-keys -t TMUX--demo Enter"

    echo "ok: session say pastes with Enter by default and honors --no-submit"
}

test_session_say_body_file_preserves_newlines() {
    # --body-file PATH and --body-file - preserve multi-line bodies including the
    # trailing newline (sentinel-guarded read, same as mailbox bodies).
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_ps "$TMPDIR/ps"
    local log="$TMPDIR/say-body.log" bf="$TMPDIR/say-body.txt" out
    printf 'line one\nline two\n' > "$bf"
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        "$ROOT/cctrl" session say TMUX--demo --body-file "$bf" --no-submit --json)"
    printf '%s\n' "$out" | jq -e '.ok == true' >/dev/null || fail "expected --body-file paste ok"
    assert_contains "$(cat "$log")" "BUFFER line one"
    assert_contains "$(cat "$log")" "line two"

    : > "$log"
    out="$(printf 'from stdin\ntrailing newline kept\n' | PATH="$TMPDIR:$PATH" TMUX_LOG="$log" \
        TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        "$ROOT/cctrl" session say TMUX--demo --body-file - --no-submit --json)"
    printf '%s\n' "$out" | jq -e '.ok == true' >/dev/null || fail "expected stdin body paste ok"
    assert_contains "$(cat "$log")" "BUFFER from stdin"

    echo "ok: session say --body-file (PATH and -) preserves multi-line bodies and trailing newline"
}

test_session_say_modal_deferral_not_overridden_by_force_busy() {
    # A known modal (codex approval dialog visible in the pane) is a hard stop:
    # status busy, non-zero exit, no paste — and --force-busy must NOT override it.
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_ps "$TMPDIR/ps"
    local log="$TMPDIR/say-modal.log" out rc=0 codex_modal hook_modal
    codex_modal="$(printf '%s\n' \
        '● Applying the proposed patch next.' \
        '' \
        '│ Allow Codex to apply proposed code changes?      │' \
        '│   No, and tell Codex what to do differently      │')"
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        TMUX_FAKE_CAPTURE_PANE="$codex_modal" \
        "$ROOT/cctrl" session say TMUX--demo --force-busy --json -- "should be blocked")" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit when a modal prompt is visible"
    printf '%s\n' "$out" | jq -e '.ok == false and .status == "busy" and .reason == "modal prompt visible"' >/dev/null \
        || fail "expected status busy for visible modal even with --force-busy"
    assert_not_contains "$(cat "$log")" "paste-buffer"

    hook_modal="$(printf '%s\n' \
        'Hooks need review' \
        '2 hooks are new or changed.' \
        '' \
        'PreToolUse hooks' \
        '1 hook needs review before it can run.' \
        '' \
        'Press t to trust; esc to go back')"
    : > "$log"
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        TMUX_FAKE_CAPTURE_PANE="$hook_modal" \
        "$ROOT/cctrl" session say TMUX--demo --force-busy --json -- "should also be blocked")" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit when a hook-review prompt is visible"
    printf '%s\n' "$out" | jq -e '.ok == false and .status == "busy" and .reason == "modal prompt visible"' >/dev/null \
        || fail "expected status busy for visible hook-review prompt even with --force-busy"
    assert_not_contains "$(cat "$log")" "paste-buffer"

    echo "ok: session say never overrides a known modal, even with --force-busy"
}

test_session_say_claude_modal_blocks_and_benign_pane_passes() {
    # The say path had a Codex modal fixture but no Claude one, so the claude)
    # branch of the readiness check was only ever exercised through `peer
    # deliver` — a different code path with a different contract (deferred vs
    # busy). Both directions matter here: a real Claude proceed modal (anchored
    # on the highlighted "❯ 1." selection line) is a hard stop that --force-busy
    # must NOT override, and a benign markdown numbered list plus "Do you want
    # ... proceed" prose must still paste — that false positive is what the old
    # '. 1\.' heuristic got wrong.
    make_fake_tmux "$TMPDIR/tmux"
    # Pane must resolve to claude (make_fake_ps hardcodes codex for 12345).
    cat > "$TMPDIR/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *4242* ]]; then
    printf 'claude --model opus-5 --name TMUX--demo\n'
    exit 0
fi
exec /bin/ps "$@"
SH
    chmod +x "$TMPDIR/ps"

    local log="$TMPDIR/say-claude-modal.log" out rc=0 modal_pane benign_pane
    modal_pane="$(printf '%s\n' \
        '● Ready to remove the old build artifacts.' \
        '' \
        '╭──────────────────────────────────────────────────╮' \
        '│ Do you want to proceed?                          │' \
        '│ ❯ 1. Yes                                         │' \
        '│   2. No, and tell Claude what to do differently  │' \
        '╰──────────────────────────────────────────────────╯')"
    benign_pane="$(printf '%s\n' \
        '● Here is the fleet plan:' \
        '  1. First item' \
        '  2. Second item' \
        '' \
        'Earlier you asked: Do you want to proceed with the old approach?')"

    # A visible Claude modal is a hard stop even with --force-busy, and nothing
    # is pasted into the dialog.
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        TMUX_FAKE_PANE_PID=4242 TMUX_FAKE_CAPTURE_PANE="$modal_pane" \
        "$ROOT/cctrl" session say TMUX--demo --force-busy --json -- "should be blocked")" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for a visible Claude modal"
    printf '%s\n' "$out" | jq -e '.ok == false and .status == "busy" and .reason == "modal prompt visible"' >/dev/null \
        || fail "expected status busy / modal prompt visible for the Claude modal"
    assert_not_contains "$(cat "$log")" "paste-buffer"

    # A numbered list is not a modal: the message pastes with no override flag.
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        TMUX_FAKE_PANE_PID=4242 TMUX_FAKE_CAPTURE_PANE="$benign_pane" \
        "$ROOT/cctrl" session say TMUX--demo --json -- "should paste")"
    printf '%s\n' "$out" | jq -e '.ok == true and .status == "ok"' >/dev/null \
        || fail "expected a benign numbered-list pane to accept the paste"
    assert_contains "$(cat "$log")" "paste-buffer -b cctrl-say-TMUX--demo-"
    echo "ok: session say blocks on a Claude modal and still pastes on a benign numbered list"
}

test_session_say_unknown_readiness_requires_force_busy() {
    # When the agent can't be inferred (pane runs neither claude nor codex),
    # readiness is unknown: refuse by default, permit only with --force-busy.
    make_fake_tmux "$TMPDIR/tmux"   # no fake ps -> pane pid 55555 resolves to no agent
    local log="$TMPDIR/say-unknown.log" out rc=0
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        TMUX_FAKE_PANE_PID=55555 \
        "$ROOT/cctrl" session say TMUX--demo --json -- "hi")" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for unknown agent readiness without --force-busy"
    printf '%s\n' "$out" | jq -e '.ok == false and .status == "busy" and .reason == "unknown agent readiness"' >/dev/null \
        || fail "expected unknown agent readiness refusal"
    assert_not_contains "$(cat "$log")" "paste-buffer"

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        TMUX_FAKE_PANE_PID=55555 \
        "$ROOT/cctrl" session say TMUX--demo --force-busy --json -- "hi")"
    printf '%s\n' "$out" | jq -e '.ok == true and .status == "ok"' >/dev/null \
        || fail "expected --force-busy to permit paste under unknown readiness"
    assert_contains "$(cat "$log")" "paste-buffer -b cctrl-say-TMUX--demo-"
    echo "ok: session say gates unknown readiness behind --force-busy"
}

test_session_say_errors() {
    # Unknown session, empty body, missing body, body-file read failure, and
    # tmux load/paste/send failures all produce clear errors and non-zero exits.
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_ps "$TMPDIR/ps"
    local log="$TMPDIR/say-err.log" out rc=0 body_path
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="" \
        "$ROOT/cctrl" session say TMUX--nope --json -- "hi")" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for unknown session"
    printf '%s\n' "$out" | jq -e '.ok == false and .status == "unknown-session"' >/dev/null || fail "expected unknown-session status"
    assert_not_contains "$(cat "$log")" "paste-buffer"

    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        "$ROOT/cctrl" session say TMUX--demo --json --)" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for empty body"
    printf '%s\n' "$out" | jq -e '.ok == false and .status == "validation"' >/dev/null || fail "expected validation status for empty body"

    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        "$ROOT/cctrl" session say TMUX--demo --json)" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for missing body"
    printf '%s\n' "$out" | jq -e '.ok == false and .status == "validation"' >/dev/null || fail "expected validation status for missing body"

    body_path="$TMPDIR/unreadable-say-body.txt"
    printf 'hidden body\n' > "$body_path"
    cat > "$TMPDIR/cat" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "$body_path" ]]; then
    echo "permission denied" >&2
    exit 1
fi
exec /bin/cat "\$@"
SH
    chmod +x "$TMPDIR/cat"
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        "$ROOT/cctrl" session say TMUX--demo --body-file "$body_path" --json 2>&1)" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for body-file read failure"
    printf '%s\n' "$out" | jq -e '.ok == false and .status == "validation" and (.reason | test("Failed to read body file"))' >/dev/null \
        || fail "expected structured validation error for body-file read failure"
    rm -f "$TMPDIR/cat"

    : > "$log"
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        TMUX_FAKE_LOAD_FAIL=1 \
        "$ROOT/cctrl" session say TMUX--demo --json -- "load boom")" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for tmux load-buffer failure"
    printf '%s\n' "$out" | jq -e '.ok == false and .status == "paste-failed" and (.reason | test("load failed|load-buffer"))' >/dev/null \
        || fail "expected paste-failed status for tmux load-buffer failure"

    : > "$log"
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        TMUX_FAKE_PASTE_FAIL=1 \
        "$ROOT/cctrl" session say TMUX--demo --json -- "boom")" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for tmux paste failure"
    printf '%s\n' "$out" | jq -e '.ok == false and .status == "paste-failed"' >/dev/null || fail "expected paste-failed status"

    : > "$log"
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        TMUX_FAKE_SEND_FAIL=1 \
        "$ROOT/cctrl" session say TMUX--demo --json -- "send boom")" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for tmux send-keys failure"
    printf '%s\n' "$out" | jq -e '.ok == false and .status == "paste-failed" and (.reason | test("send failed|send-keys"))' >/dev/null \
        || fail "expected paste-failed status for tmux send-keys failure"

    echo "ok: session say reports unknown session, empty/missing body, body-file read failure, and tmux load/paste/send failures"
}

test_peer_session_resolves_and_alias() {
    # `peer session <peer>` resolves through the shared peer JSON resolver
    # (aliases + canonical names) to the backing live tmux session. Human output
    # is concise (name -> target); --json carries canonical name, requested
    # label, session/tmux_target, host, and live status.
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_ps "$TMPDIR/ps"
    local meta="$TMPDIR/peer-session-meta"
    local data="$TMPDIR/peer-session-data"
    mkdir -p "$meta"
    cat > "$meta/demo.json" <<'JSON'
{"purpose":"peer chat target","created_at":"2026-06-11T10:00:00Z","peer":"comet"}
JSON
    local out
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_SESSIONS="demo" TMUX_FAKE_HAS_SESSION="demo" \
        "$ROOT/cctrl" peer session comet)"
    assert_contains "$out" "comet -> demo"

    # Alias ("demo") resolves to canonical name "comet"; label echoes the request.
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_SESSIONS="demo" TMUX_FAKE_HAS_SESSION="demo" \
        "$ROOT/cctrl" peer session demo --json)"
    printf '%s\n' "$out" | jq -e '.ok == true and .name == "comet" and .label == "demo" and .session == "demo" and .tmux_target == "demo" and .host == "local" and .live == true and .status == "ok"' >/dev/null \
        || fail "expected peer session json to resolve alias to canonical live target"

    echo "ok: peer session resolves canonical + alias through the peer resolver to the backing tmux session"
}

test_peer_session_offline_unknown_stale() {
    # Clear, machine-readable errors for polling/MCP-only peers (no session),
    # unknown peers, and manual peers whose recorded session is no longer live.
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_ps "$TMPDIR/ps"
    local meta="$TMPDIR/peer-session-err-meta"
    mkdir -p "$meta"
    local out rc

    # Unknown peer.
    rc=0
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$TMPDIR/peer-unknown-data" CCTRL_SESSION_METADATA_DIR="$meta" \
        "$ROOT/cctrl" peer session ghost --json)" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for unknown peer session"
    printf '%s\n' "$out" | jq -e '.ok == false and .status == "unknown-peer"' >/dev/null || fail "expected unknown-peer status"

    # Polling/MCP-only peer with no tmux session.
    local poll_data="$TMPDIR/peer-poll-data"
    CCTRL_DATA_DIR="$poll_data" CCTRL_SESSION_METADATA_DIR="$meta" \
        "$ROOT/cctrl" peer register poller --agent codex --capability polling >/dev/null
    rc=0
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$poll_data" CCTRL_SESSION_METADATA_DIR="$meta" \
        "$ROOT/cctrl" peer session poller --json)" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for polling-only peer session"
    printf '%s\n' "$out" | jq -e '.ok == false and .status == "no-session"' >/dev/null || fail "expected no-session status"

    # Manual peer with a recorded session that is not live (stale).
    local stale_data="$TMPDIR/peer-stale-data"
    CCTRL_DATA_DIR="$stale_data" CCTRL_SESSION_METADATA_DIR="$meta" \
        "$ROOT/cctrl" peer register stale --agent codex --session TMUX--gone >/dev/null
    rc=0
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$stale_data" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_HAS_SESSION="" \
        "$ROOT/cctrl" peer session stale --json)" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for stale peer session"
    printf '%s\n' "$out" | jq -e '.ok == false and .status == "stale" and .tmux_target == "TMUX--gone"' >/dev/null || fail "expected stale status with recorded target"

    echo "ok: peer session reports unknown, polling-only (no-session), and stale peers with clear machine-readable errors"
}

test_peer_attach_targets_resolved_session() {
    # `peer attach <peer>` resolves the peer to its backing tmux session and
    # delegates to the existing session-attach path (exec tmux attach-session).
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_ps "$TMPDIR/ps"
    local meta="$TMPDIR/peer-attach-meta"
    local data="$TMPDIR/peer-attach-data"
    local log="$TMPDIR/peer-attach.log"
    mkdir -p "$meta"
    cat > "$meta/demo.json" <<'JSON'
{"purpose":"peer chat target","created_at":"2026-06-11T10:00:00Z","peer":"comet"}
JSON
    : > "$log"
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_SESSIONS="demo" TMUX_FAKE_HAS_SESSION="demo" \
        "$ROOT/cctrl" peer attach comet >/dev/null 2>&1 || true
    assert_contains "$(cat "$log")" "attach-session -t demo"

    echo "ok: peer attach resolves the peer and attaches to the resolved tmux session"
}

test_peer_say_delegates_and_no_mailbox() {
    # `peer say` resolves a peer/alias to a live tmux session and delegates to
    # plan 009's `session say` (same flags). It must NEVER write messages.jsonl
    # or otherwise touch mailbox state.
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_ps "$TMPDIR/ps"
    local meta="$TMPDIR/peer-say-meta"
    local data="$TMPDIR/peer-say-data"
    local log="$TMPDIR/peer-say.log"
    mkdir -p "$meta"
    cat > "$meta/demo.json" <<'JSON'
{"purpose":"peer chat target","created_at":"2026-06-11T10:00:00Z","peer":"comet"}
JSON
    local out
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_SESSIONS="demo" TMUX_FAKE_HAS_SESSION="demo" \
        "$ROOT/cctrl" peer say demo --json -- "live chat hi")"
    printf '%s\n' "$out" | jq -e '.ok == true and .session == "demo" and .submitted == true and .status == "ok"' >/dev/null \
        || fail "expected peer say to delegate to session say with ok result"
    assert_contains "$(cat "$log")" "BUFFER live chat hi"
    assert_contains "$(cat "$log")" "send-keys -t demo Enter"
    # No mailbox mutation whatsoever.
    [[ ! -e "$data/messages.jsonl" ]] || fail "peer say must not write messages.jsonl"

    # --no-submit is honored (shared session say flag).
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_SESSIONS="demo" TMUX_FAKE_HAS_SESSION="demo" \
        "$ROOT/cctrl" peer say comet --no-submit --json -- "no enter")"
    printf '%s\n' "$out" | jq -e '.ok == true and .submitted == false' >/dev/null || fail "expected peer say --no-submit"
    assert_not_contains "$(cat "$log")" "send-keys -t demo Enter"
    [[ ! -e "$data/messages.jsonl" ]] || fail "peer say --no-submit must not write messages.jsonl"

    # peer say rejects --as/--from at the peer level with a clear message (they
    # belong to the mailbox path, peer send), rather than leaking session say's
    # "Unknown session say flag" error.
    local rc=0
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_SESSIONS="demo" TMUX_FAKE_HAS_SESSION="demo" \
        "$ROOT/cctrl" peer say demo --as beta --json -- "hi")" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for peer say --as"
    printf '%s\n' "$out" | jq -e '.ok == false and .status == "validation" and (.reason | test("peer say takes no --as"))' >/dev/null \
        || fail "expected a peer-level --as rejection, not a session say flag leak"

    # A message body that mentions --as after `--` is delivered, not misread.
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_SESSIONS="demo" TMUX_FAKE_HAS_SESSION="demo" \
        "$ROOT/cctrl" peer say demo --json -- "explain --as usage")"
    printf '%s\n' "$out" | jq -e '.ok == true' >/dev/null || fail "peer say must not misread --as inside the body"
    assert_contains "$(cat "$log")" "BUFFER explain --as usage"

    echo "ok: peer say delegates to session say (flags shared), rejects --as/--from clearly, never touches the mailbox"
}

test_peer_help_agent() {
    # plan 011: `cctrl peer help-agent` is the agent-facing operating contract that
    # distinguishes `peer say` (live tmux chat), `peer send` (durable async), and
    # the `peer recv` / `peer ack` mailbox loop. A bare (no --as, no CCTRL_PEER)
    # call prints GENERIC guidance and must NOT fail for a missing identity;
    # `--as NAME` and `CCTRL_PEER` canonicalize the peer via the shared resolver and
    # tailor the examples; `--json` returns a structured version of the same
    # contract; an invalid peer fails rather than silently printing generic text.
    local data="$TMPDIR/help-agent-data"
    mkdir -p "$TMPDIR/comet-ha"
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register comet --dir "$TMPDIR/comet-ha" --agent codex >/dev/null
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer alias comet comet-agent >/dev/null

    local out rc

    # (1) bare: generic guidance, exit 0, names all four verbs, no identity failure.
    rc=0
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer help-agent 2>&1)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected bare peer help-agent to exit 0 (generic guidance, no identity failure)"
    assert_contains "$out" "peer say"
    assert_contains "$out" "peer send"
    assert_contains "$out" "peer recv"
    assert_contains "$out" "peer ack"

    # (2) bare --json: generic structured JSON contract, peer null, no auto-injection.
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer help-agent --json)"
    printf '%s\n' "$out" | jq -e '
        .ok == true and .generic == true and .peer == null
        and (.commands | has("say") and has("send") and has("recv") and has("ack"))
        and .commands.say.mailbox == false and .commands.send.mailbox == true
        and .auto_injection == false
    ' >/dev/null || fail "expected bare --json help-agent to return generic structured JSON contract"

    # (3) --as canonicalizes an alias to the peer and tailors the examples.
    out="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer help-agent --as comet-agent --json)"
    printf '%s\n' "$out" | jq -e '
        .ok == true and .generic == false and .peer == "comet"
        and (.commands.send.example | test("--from comet"))
    ' >/dev/null || fail "expected --as to canonicalize the alias and tailor examples for the peer"

    # (4) CCTRL_PEER produces the SAME peer-specific guidance as --as.
    local via_as via_env
    via_as="$(CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer help-agent --as comet --json)"
    via_env="$(CCTRL_DATA_DIR="$data" CCTRL_PEER=comet "$ROOT/cctrl" peer help-agent --json)"
    [[ "$via_as" == "$via_env" ]] || fail "expected CCTRL_PEER help-agent to match --as help-agent"

    # (5) invalid peer fails (does not fall back to generic guidance).
    rc=0
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer help-agent --as nope-not-real >/dev/null 2>&1 || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected an unknown --as peer to fail rather than print generic guidance"

    echo "ok: peer help-agent generic guidance + --as/CCTRL_PEER canonicalization + structured JSON + invalid peer"
}

test_peer_mcp_say_peer() {
    # plan 011: the MCP `say_peer` tool is direct live-tmux chat (the tool-call form
    # of `cctrl peer say`). It must (a) be advertised in tools/list, (b) pass the
    # body through `cctrl peer say --body-file -` so trailing newlines survive
    # byte-for-byte, (c) map submit:false -> --no-submit and force_busy:true ->
    # --force-busy, (d) reject non-boolean submit/force_busy like the other tools,
    # and (e) NEVER create a mailbox message (no messages.jsonl write).
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_ps "$TMPDIR/ps"
    local data="$TMPDIR/say-peer-data"
    local log="$TMPDIR/say-peer.log"
    local bytes="$TMPDIR/say-peer-buffer.bin"
    local expected="$TMPDIR/say-peer-expected.bin"
    mkdir -p "$TMPDIR/comet-sp" "$TMPDIR/orchestrator-sp"
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register comet --dir "$TMPDIR/comet-sp" --agent codex --session TMUX--comet >/dev/null
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register orchestrator --dir "$TMPDIR/orchestrator-sp" --agent codex >/dev/null

    local out say_req

    # (a) advertised in tools/list.
    out="$(
        {
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
            printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
        } | PATH="$TMPDIR:$PATH" TMUX_FAKE_SESSIONS="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as orchestrator
    )"
    printf '%s\n' "$out" | jq -s -e '[.[].result.tools[]?.name] | index("say_peer") != null' >/dev/null \
        || fail "expected MCP tools/list to advertise say_peer"

    # (b) + default submit: trailing newline preserved through --body-file -, submits.
    : > "$log"
    say_req="$(jq -cn --arg to comet --arg body $'live line one\nlive line two\n' '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"say_peer",arguments:{to:$to,body:$body}}}')"
    out="$(printf '%s\n' "$say_req" | PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_BUFFER_FILE="$bytes" TMUX_FAKE_HAS_SESSION="TMUX--comet" TMUX_FAKE_SESSIONS="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as orchestrator)"
    printf '%s\n' "$out" | jq -e '
        .result.structuredContent.ok == true
        and .result.structuredContent.data.ok == true
        and .result.structuredContent.data.submitted == true
        and .result.structuredContent.data.status == "ok"
    ' >/dev/null || fail "expected say_peer to submit via the live tmux path with an ok result"
    printf 'live line one\nlive line two\n' > "$expected"
    cmp -s "$bytes" "$expected" || fail "expected say_peer to preserve the trailing newline via --body-file -"
    assert_contains "$(cat "$log")" "send-keys -t TMUX--comet Enter"
    # (e) NEVER creates a mailbox message.
    [[ ! -e "$data/messages.jsonl" ]] || fail "say_peer must not create a mailbox message"

    # (c) submit:false -> --no-submit (no Enter is sent).
    : > "$log"
    say_req="$(jq -cn --arg to comet --arg body "draft only" '{jsonrpc:"2.0",id:4,method:"tools/call",params:{name:"say_peer",arguments:{to:$to,body:$body,submit:false}}}')"
    out="$(printf '%s\n' "$say_req" | PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" TMUX_FAKE_SESSIONS="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as orchestrator)"
    printf '%s\n' "$out" | jq -e '.result.structuredContent.ok == true and .result.structuredContent.data.submitted == false' >/dev/null \
        || fail "expected say_peer submit:false to map to --no-submit"
    assert_not_contains "$(cat "$log")" "send-keys -t TMUX--comet Enter"

    # (c) force_busy:true -> --force-busy is accepted.
    : > "$log"
    say_req="$(jq -cn --arg to comet --arg body "busy override" '{jsonrpc:"2.0",id:5,method:"tools/call",params:{name:"say_peer",arguments:{to:$to,body:$body,force_busy:true}}}')"
    out="$(printf '%s\n' "$say_req" | PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" TMUX_FAKE_SESSIONS="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as orchestrator)"
    printf '%s\n' "$out" | jq -e '.result.structuredContent.ok == true and .result.structuredContent.data.submitted == true' >/dev/null \
        || fail "expected say_peer force_busy:true to succeed"

    # (d) non-boolean submit is a validation error, same style as the other tools.
    out="$(printf '%s\n' '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"say_peer","arguments":{"to":"comet","body":"x","submit":"yes"}}}' | PATH="$TMPDIR:$PATH" TMUX_FAKE_HAS_SESSION="TMUX--comet" TMUX_FAKE_SESSIONS="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as orchestrator)"
    printf '%s\n' "$out" | jq -e '.result.isError == true and .result.structuredContent.ok == false and .result.structuredContent.error.code == "validation" and .result.structuredContent.error.message == "submit must be a boolean"' >/dev/null \
        || fail "expected non-boolean submit to be a validation error"

    # (d) non-boolean force_busy is a validation error too.
    out="$(printf '%s\n' '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"say_peer","arguments":{"to":"comet","body":"x","force_busy":1}}}' | PATH="$TMPDIR:$PATH" TMUX_FAKE_HAS_SESSION="TMUX--comet" TMUX_FAKE_SESSIONS="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer mcp --as orchestrator)"
    printf '%s\n' "$out" | jq -e '.result.isError == true and .result.structuredContent.error.code == "validation" and .result.structuredContent.error.message == "force_busy must be a boolean"' >/dev/null \
        || fail "expected non-boolean force_busy to be a validation error"

    echo "ok: MCP say_peer is direct live-tmux chat — preserves trailing newlines, maps submit/force_busy, creates no mailbox message"
}

test_peer_direct_non_local_host_hint() {
    # A peer whose host metadata differs from the current host label must NOT be
    # auto-SSH'd; direct commands fail with an actionable `--host` hint.
    make_fake_tmux "$TMPDIR/tmux"
    local meta="$TMPDIR/peer-host-meta"
    local data="$TMPDIR/peer-host-data"
    mkdir -p "$meta"
    CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" \
        "$ROOT/cctrl" peer register comet --host studio --agent codex --session TMUX--comet >/dev/null

    local out rc
    # Human `peer say` prints the reason plus the top-level `--host` hint.
    rc=0
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" \
        "$ROOT/cctrl" peer say comet -- "hi" 2>&1)" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for non-local peer say"
    assert_contains "$out" "cctrl --host studio peer say comet"

    # JSON `peer session` surfaces remote-host status.
    rc=0
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" \
        "$ROOT/cctrl" peer session comet --json)" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for non-local peer session"
    printf '%s\n' "$out" | jq -e '.ok == false and .status == "remote-host" and .host == "studio"' >/dev/null || fail "expected remote-host status"

    # peer attach also refuses and hints.
    rc=0
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" \
        "$ROOT/cctrl" peer attach comet 2>&1)" || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for non-local peer attach"
    assert_contains "$out" "cctrl --host studio peer attach comet"

    echo "ok: non-local peer host metadata fails with a --host hint instead of auto-SSH"
}

test_peer_attach_remote_forwarding_tty() {
    # `cctrl --host <host> peer attach <peer>` is interactive: the forwarding
    # layer must request a TTY (ssh -t), the same as `session attach`.
    make_fake_ssh "$TMPDIR/ssh"
    local rootcopy="$TMPDIR/cctrl-peerattach-copy"
    local log="$TMPDIR/peer-attach-ssh.log"
    mkdir -p "$rootcopy/data"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    printf '{"ms":{"hostname":"example.invalid","user":"tester"}}\n' > "$rootcopy/data/hosts.json"

    : > "$log"
    PATH="$TMPDIR:$PATH" SSH_LOG="$log" \
        "$rootcopy/cctrl" --host ms peer attach comet >/dev/null 2>&1 || true

    local ssh_log
    ssh_log="$(cat "$log")"
    assert_contains "$ssh_log" "SSH -t tester@example.invalid"
    assert_contains "$ssh_log" "peer\\ attach\\ comet"

    echo "ok: cctrl --host <host> peer attach requests a TTY (ssh -t)"
}

test_peer_ls_shows_session_and_status() {
    # Human `peer ls` shows the backing SESSION column and live/offline status by
    # default, without dropping any existing --json fields.
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_ps "$TMPDIR/ps"
    local meta="$TMPDIR/peer-ls-meta"
    local data="$TMPDIR/peer-ls-data"
    mkdir -p "$meta"
    cat > "$meta/demo.json" <<'JSON'
{"purpose":"peer chat target","created_at":"2026-06-11T10:00:00Z","peer":"comet"}
JSON
    local out
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_SESSIONS="demo" TMUX_FAKE_HAS_SESSION="demo" \
        "$ROOT/cctrl" peer ls)"
    assert_contains "$out" "SESSION"
    assert_contains "$out" "STATUS"
    assert_contains "$out" "demo"
    assert_contains "$out" "live"

    # An offline manual peer (recorded session not live) shows offline.
    local off_data="$TMPDIR/peer-ls-off-data"
    CCTRL_DATA_DIR="$off_data" CCTRL_SESSION_METADATA_DIR="$meta" \
        "$ROOT/cctrl" peer register comet --agent codex --session TMUX--gone >/dev/null
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$off_data" CCTRL_SESSION_METADATA_DIR="$TMPDIR/peer-ls-empty-meta" \
        TMUX_FAKE_HAS_SESSION="" \
        "$ROOT/cctrl" peer ls)"
    assert_contains "$out" "offline"

    # --json still carries the full peer objects (tmux_target preserved).
    out="$(PATH="$TMPDIR:$PATH" CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_SESSIONS="demo" TMUX_FAKE_HAS_SESSION="demo" \
        "$ROOT/cctrl" peer ls --json)"
    printf '%s\n' "$out" | jq -e '.peers[] | select(.name == "comet") | .tmux_target == "demo"' >/dev/null \
        || fail "expected peer ls --json to keep tmux_target field"

    echo "ok: peer ls human output shows SESSION + live/offline while --json keeps all fields"
}

test_peer_contract_docs() {
    # Plan 026: the peer operating contract must live where agents actually read
    # (AGENTS.md + CLAUDE.md routing), and the README must document the sender
    # envelope, peer_overview, and the dangling-address limitation.
    local agents="$ROOT/AGENTS.md" claude="$ROOT/CLAUDE.md" readme="$ROOT/README.md"
    grep -q '^## Peer messaging' "$agents" || fail "AGENTS.md missing '## Peer messaging' section"
    grep -q 'cctrl peer ack' "$agents" || fail "AGENTS.md contract missing concrete 'cctrl peer ack' command"
    grep -q 'cctrl peer reply' "$agents" || fail "AGENTS.md contract missing 'cctrl peer reply'"
    grep -q 'sender' "$agents" || fail "AGENTS.md contract missing sender identity"
    grep -qi 'peer' "$claude" || fail "CLAUDE.md missing a peer routing entry"
    grep -q 'peer_overview' "$readme" || fail "README.md missing peer_overview documentation"
    grep -qi 'an address can dangle' "$readme" || fail "README.md missing the dangling-address limitation"
    # Contract stays compact: <=30 lines between the heading and the next '## ' (or EOF).
    local n
    n="$(awk '/^## Peer messaging/{f=1;next}/^## /{if(f)exit}f' "$agents" | wc -l | tr -d ' ')"
    [[ "$n" -le 30 ]] || fail "AGENTS.md peer contract too long ($n lines > 30)"
    # Public-repo hygiene: no environment specifics inside the contract section.
    if awk '/^## Peer messaging/{f=1;next}/^## /{if(f)exit}f' "$agents" \
        | grep -Eq 'TMUX--|home\.matthew|homelab|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|:[0-9]{4}\b'; then
        fail "AGENTS.md peer contract contains environment specifics"
    fi
    echo "ok: peer operating contract in AGENTS.md + CLAUDE.md routing + README envelope/overview/limitation docs"
}

# ── Plan 051: persist conversation_id tests ──────────────────────────

test_update_metadata_field_preserves_keys() {
    # _session_update_metadata_field merges a single field without clobbering
    # any existing keys. Tested via backfill --apply which calls the function.
    local meta="$TMPDIR/bf-merge-meta"
    rm -rf "$meta"; mkdir -p "$meta"
    cat > "$meta/TMUX--merge-test.json" <<'JSON'
{"name":"TMUX--merge-test","created_at":"2026-08-03T10:00:00Z","cwd":"/tmp/test","purpose":"original","agent":"claude","launch_command":"cctrl start --resume aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","cctrl_managed":true,"conversation_id":null}
JSON
    local before
    before="$(shasum -a 256 "$meta/TMUX--merge-test.json" | awk '{print $1}')"
    CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$TMPDIR/bf-merge-host-id" "$ROOT/cctrl" session backfill-ids --apply >/dev/null 2>&1
    local result
    result="$(session_record_json "TMUX--merge-test" "$meta")"
    assert_contains "$result" '"purpose": "original"'
    assert_contains "$result" '"agent": "claude"'
    assert_contains "$result" '"created_at": "2026-08-03T10:00:00Z"'
    assert_contains "$result" '"conversation_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"'
    assert_contains "$result" '"cctrl_managed": true'
    [[ "$before" == "$(shasum -a 256 "$meta/TMUX--merge-test.json" | awk '{print $1}')" ]] || fail "legacy input was rewritten during lazy promotion"
    echo "ok: lazy promotion preserves all keys and leaves legacy input immutable"
}

test_update_metadata_field_missing_record() {
    # _session_update_metadata_field returns non-zero and does not create a file
    # when the record doesn't exist.
    mkdir -p "$CCTRL_SESSION_METADATA_DIR"
    rm -f "$CCTRL_SESSION_METADATA_DIR/TMUX--nonexistent.json"
    local wrapper="$TMPDIR/test-update-field.sh"
    cat > "$wrapper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
SESSION_METADATA_DIR="$1"
_session_metadata_file() {
    local safe
    safe="$(printf '%s' "$1" | tr '/:' '__')"
    printf '%s/%s.json' "$SESSION_METADATA_DIR" "$safe"
}
_session_update_metadata_field() {
    local session_name="$1" field="$2" value="$3"
    local file tmp
    file="$(_session_metadata_file "$session_name")"
    [[ -f "$file" ]] || return 1
    tmp="$(mktemp "$SESSION_METADATA_DIR/tmp.XXXXXX")" || return 1
    if jq --arg f "$field" --arg v "$value" \
        'if $v == "" then .[$f] = null else .[$f] = $v end' \
        "$file" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
}
_session_update_metadata_field "$2" "$3" "$4"
SH
    chmod +x "$wrapper"
    local rc=0
    "$wrapper" "$CCTRL_SESSION_METADATA_DIR" "TMUX--nonexistent" "conversation_id" "some-uuid" 2>/dev/null || rc=$?
    [[ $rc -ne 0 ]] || fail "expected non-zero return for missing record"
    [[ ! -f "$CCTRL_SESSION_METADATA_DIR/TMUX--nonexistent.json" ]] || fail "should not create file for missing record"
    echo "ok: _session_update_metadata_field returns non-zero and does not create file for missing record"
}

test_update_metadata_field_malformed_json() {
    # _session_update_metadata_field leaves a malformed file untouched and returns non-zero.
    mkdir -p "$CCTRL_SESSION_METADATA_DIR"
    printf 'this is not json {{{' > "$CCTRL_SESSION_METADATA_DIR/TMUX--malformed.json"
    local wrapper="$TMPDIR/test-update-malformed.sh"
    cat > "$wrapper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
SESSION_METADATA_DIR="$1"
_session_metadata_file() {
    local safe
    safe="$(printf '%s' "$1" | tr '/:' '__')"
    printf '%s/%s.json' "$SESSION_METADATA_DIR" "$safe"
}
_session_update_metadata_field() {
    local session_name="$1" field="$2" value="$3"
    local file tmp
    file="$(_session_metadata_file "$session_name")"
    [[ -f "$file" ]] || return 1
    tmp="$(mktemp "$SESSION_METADATA_DIR/tmp.XXXXXX")" || return 1
    if jq --arg f "$field" --arg v "$value" \
        'if $v == "" then .[$f] = null else .[$f] = $v end' \
        "$file" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
}
_session_update_metadata_field "$2" "$3" "$4"
SH
    chmod +x "$wrapper"
    local rc=0
    "$wrapper" "$CCTRL_SESSION_METADATA_DIR" "TMUX--malformed" "conversation_id" "some-uuid" 2>/dev/null || rc=$?
    [[ $rc -ne 0 ]] || fail "expected non-zero return for malformed json"
    local content
    content="$(cat "$CCTRL_SESSION_METADATA_DIR/TMUX--malformed.json")"
    [[ "$content" == "this is not json {{{"  ]] || fail "malformed file should be untouched, got: $content"
    echo "ok: _session_update_metadata_field leaves malformed json untouched"
}

test_backfill_ids_fills_resume_flag() {
    # Backfill fills conversation_id from --resume UUID in launch_command.
    local meta="$TMPDIR/bf-fill-meta"
    rm -rf "$meta"; mkdir -p "$meta"
    cp "$ROOT/tests/fixtures/backfill/TMUX--resume-test.json" "$meta/"
    local out
    out="$(CCTRL_SESSION_METADATA_DIR="$meta" "$ROOT/cctrl" session backfill-ids --apply)"
    assert_contains "$out" "1 filled"
    local result
    result="$(session_record_json "TMUX--resume-test" "$meta")"
    assert_contains "$result" '"conversation_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"'
    echo "ok: backfill-ids fills the --resume case from fixture"
}

test_backfill_ids_refuses_uuid_in_cwd() {
    # Backfill does NOT fill when the UUID appears only in the cwd, not after --resume/-r.
    local meta="$TMPDIR/bf-cwd-meta"
    rm -rf "$meta"; mkdir -p "$meta"
    cp "$ROOT/tests/fixtures/backfill/TMUX--ms--spawndryrun.json" "$meta/"
    local out
    out="$(CCTRL_SESSION_METADATA_DIR="$meta" "$ROOT/cctrl" session backfill-ids --apply)"
    assert_contains "$out" "1 unrecoverable"
    local result
    result="$(jq -r '.conversation_id // empty' "$meta/TMUX--ms--spawndryrun.json")"
    [[ -z "$result" || "$result" == "null" ]] || fail "UUID-in-cwd false positive should not be filled, got: $result"
    echo "ok: backfill-ids refuses UUID-in-cwd false positive"
}

test_backfill_ids_already_set() {
    # Backfill does not overwrite a record that already has conversation_id.
    local meta="$TMPDIR/bf-already-meta"
    rm -rf "$meta"; mkdir -p "$meta"
    cp "$ROOT/tests/fixtures/backfill/TMUX--already-set.json" "$meta/"
    local out
    out="$(CCTRL_SESSION_METADATA_DIR="$meta" "$ROOT/cctrl" session backfill-ids --apply)"
    assert_contains "$out" "already-set"
    local result
    result="$(jq -r '.conversation_id' "$meta/TMUX--already-set.json")"
    [[ "$result" == "deadbeef-1234-5678-9abc-def012345678" ]] || fail "already-set record should keep its value"
    echo "ok: backfill-ids does not overwrite already-set records"
}

test_backfill_ids_dry_run_writes_nothing() {
    # Default (--dry-run) mode writes nothing.
    local meta="$TMPDIR/bf-dryrun-meta"
    rm -rf "$meta"; mkdir -p "$meta"
    cp "$ROOT/tests/fixtures/backfill/TMUX--resume-test.json" "$meta/"
    local out
    out="$(CCTRL_SESSION_METADATA_DIR="$meta" "$ROOT/cctrl" session backfill-ids)"
    assert_contains "$out" "DRY RUN"
    assert_contains "$out" "1 filled"
    local result
    result="$(jq -r '.conversation_id // empty' "$meta/TMUX--resume-test.json")"
    [[ -z "$result" || "$result" == "null" ]] || fail "dry-run should not write, got: $result"
    echo "ok: backfill-ids --dry-run writes nothing"
}

test_backfill_ids_idempotent() {
    # Second run after --apply fills zero.
    local meta="$TMPDIR/bf-idemp-meta"
    rm -rf "$meta"; mkdir -p "$meta"
    cp "$ROOT/tests/fixtures/backfill/TMUX--resume-test.json" "$meta/"
    CCTRL_SESSION_METADATA_DIR="$meta" "$ROOT/cctrl" session backfill-ids --apply >/dev/null 2>&1
    local out
    out="$(CCTRL_SESSION_METADATA_DIR="$meta" "$ROOT/cctrl" session backfill-ids --apply)"
    assert_contains "$out" "0 filled"
    assert_contains "$out" "already-set"
    echo "ok: backfill-ids is idempotent (second run fills zero)"
}

test_backfill_ids_json() {
    # --json emits structured output with mode, counts, and records.
    local meta="$TMPDIR/bf-json-meta"
    rm -rf "$meta"; mkdir -p "$meta"
    cp "$ROOT/tests/fixtures/backfill/TMUX--resume-test.json" "$meta/"
    cp "$ROOT/tests/fixtures/backfill/TMUX--already-set.json" "$meta/"
    cp "$ROOT/tests/fixtures/backfill/TMUX--no-uuid.json" "$meta/"
    local out
    out="$(CCTRL_SESSION_METADATA_DIR="$meta" "$ROOT/cctrl" session backfill-ids --json)"
    printf '%s' "$out" | jq -e '.mode == "dry-run"' >/dev/null || fail "expected mode dry-run"
    printf '%s' "$out" | jq -e '.filled == 1' >/dev/null || fail "expected 1 filled"
    printf '%s' "$out" | jq -e '.already_set == 1' >/dev/null || fail "expected 1 already_set"
    printf '%s' "$out" | jq -e '.unrecoverable == 1' >/dev/null || fail "expected 1 unrecoverable"
    printf '%s' "$out" | jq -e '.records | length == 3' >/dev/null || fail "expected 3 records"
    echo "ok: backfill-ids --json emits structured output"
}

test_active_session_count_excludes_unmanaged() {
    # _active_session_count only counts managed sessions, not plain tmux.
    local bin="$TMPDIR/countbin"
    mkdir -p "$bin"
    make_fake_tmux "$bin/tmux"
    # Patch fake tmux: show-option returns 1 only for managed sessions (not unmanaged-shell).
    # The default make_fake_tmux returns 1 for ALL show-option calls, which
    # falsely marks every session as cctrl_managed.
    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
    list-sessions)
        IFS=$'\n'
        for s in $TMUX_FAKE_SESSIONS; do
            printf '%s: 1 windows (created Mon Jan  1 00:00:00 2024)\n' "$s"
        done
        exit 0
        ;;
    list-panes)
        printf '%%0 [200x50] [active] (pid %s)\n' "${TMUX_FAKE_PANE_PID:-12345}"
        exit 0
        ;;
    capture-pane) exit 0 ;;
    show-buffer) printf '%s\n' "${TMUX_FAKE_PANE_CONTENT:-}" ; exit 0 ;;
    display)
        if [[ "$*" == *pane_in_mode* ]]; then
            printf '%s\n' "${TMUX_FAKE_PANE_IN_MODE:-0}"
        else
            printf '0\n'
        fi
        exit 0
        ;;
    show-option)
        # Only return "1" for sessions whose name starts with "TMUX--"
        if [[ "$*" == *TMUX--* ]]; then printf '1\n'; else printf '\n'; fi
        exit 0
        ;;
    *) exit 0 ;;
esac
SH
    chmod +x "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *7777* ]]; then echo "claude --remote-control"; exit 0; fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    # Create one managed session with metadata only; the unmanaged has nothing.
    local meta="$TMPDIR/count-meta"
    rm -rf "$meta"; mkdir -p "$meta"
    cat > "$meta/TMUX--managed.json" <<'JSON'
{"name":"TMUX--managed","agent":"claude","cctrl_managed":true,"created_at":"2026-08-03T10:00:00Z"}
JSON
    local out
    out="$(PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" TMUX_FAKE_SESSIONS=$'TMUX--managed\nunmanaged-shell' TMUX_FAKE_PANE_PID=7777 "$ROOT/cctrl" session ls --json)"
    local total managed_count
    total="$(printf '%s' "$out" | jq 'length')"
    managed_count="$(printf '%s' "$out" | jq '[.[] | select(.managed)] | length')"
    [[ "$total" -ge 2 ]] || fail "expected at least 2 total sessions"
    [[ "$managed_count" -lt "$total" ]] || fail "expected unmanaged session to not be counted as managed"
    echo "ok: _active_session_count uses the managed filter"
}

test_session_list_refresh_writes_on_change() {
    # Listing reports a discovered live id but intentionally leaves legacy
    # metadata unchanged; promotion belongs to explicit mutating paths.
    local bin="$TMPDIR/refreshbin" sdir="$TMPDIR/refresh-sessions" pdir="$TMPDIR/refresh-projects"
    mkdir -p "$bin" "$sdir" "$pdir"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *9999* ]]; then echo "claude --remote-control"; exit 0; fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    cat > "$sdir/9999.json" <<'JSON'
{"pid":9999,"sessionId":"live-uuid-refreshed","updatedAt":1700000000000,"bridgeSessionId":"session_bridge"}
JSON
    mkdir -p "$CCTRL_SESSION_METADATA_DIR"
    cat > "$CCTRL_SESSION_METADATA_DIR/TMUX--refresh.json" <<'JSON'
{"name":"TMUX--refresh","agent":"claude","cctrl_managed":true,"created_at":"2026-08-03T10:00:00Z","conversation_id":null,"transcript_path":null}
JSON
    local out result
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        TMUX_FAKE_SESSIONS="TMUX--refresh" TMUX_FAKE_PANE_PID=9999 "$ROOT/cctrl" session ls --json)"
    result="$(jq -r '.conversation_id // empty' "$CCTRL_SESSION_METADATA_DIR/TMUX--refresh.json")"
    [[ -z "$result" ]] || fail "read-only session ls rewrote legacy conversation_id: $result"
    [[ "$(jq -r '.[0].session_id' <<< "$out")" == "live-uuid-refreshed" ]] || fail "session ls did not report discovered live id"
    echo "ok: session ls reports discovered identity without metadata backfill"
}

test_session_list_refresh_skips_when_unchanged() {
    # When the live session_id matches stored conversation_id, no write happens.
    local bin="$TMPDIR/nowritebin" sdir="$TMPDIR/nowrite-sessions" pdir="$TMPDIR/nowrite-projects"
    mkdir -p "$bin" "$sdir" "$pdir"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *8888* ]]; then echo "claude --remote-control"; exit 0; fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    cat > "$sdir/8888.json" <<'JSON'
{"pid":8888,"sessionId":"already-known-uuid","updatedAt":1700000000000,"bridgeSessionId":"session_bridge"}
JSON
    mkdir -p "$CCTRL_SESSION_METADATA_DIR"
    cat > "$CCTRL_SESSION_METADATA_DIR/TMUX--nowrite.json" <<'JSON'
{"name":"TMUX--nowrite","agent":"claude","cctrl_managed":true,"created_at":"2026-08-03T10:00:00Z","conversation_id":"already-known-uuid","transcript_path":null}
JSON
    local mtime_before mtime_after
    mtime_before="$(stat -f %m "$CCTRL_SESSION_METADATA_DIR/TMUX--nowrite.json")"
    sleep 1
    PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        TMUX_FAKE_SESSIONS="TMUX--nowrite" TMUX_FAKE_PANE_PID=8888 "$ROOT/cctrl" session ls --json >/dev/null 2>&1
    mtime_after="$(stat -f %m "$CCTRL_SESSION_METADATA_DIR/TMUX--nowrite.json")"
    [[ "$mtime_before" == "$mtime_after" ]] || fail "file should not be written when unchanged (mtime before=$mtime_before after=$mtime_after)"
    echo "ok: session ls refresh skips write when conversation_id unchanged"
}

test_launch_resume_captures_conversation_id() {
    # --resume <uuid> populates conversation_id on the session record.
    make_fake_tmux "$TMPDIR/tmux"
    local project="$TMPDIR/resume-project"
    local log="$TMPDIR/resume-tmux.log"
    mkdir -p "$project"
    : > "$log"
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_AGENT=claude CCTRL_EMIT_SESSION=1 \
        CCTRL_RESUME_POLL_TIMEOUT=0 \
        "$ROOT/cctrl" start -d "$project" --resume a1b2c3d4-e5f6-7890-abcd-ef1234567890 2>&1)"
    assert_contains "$out" "detached session started"
    local result
    result="$(session_record_json "TMUX--resume-project" | jq -r '.conversation_id // empty')"
    [[ "$result" == "a1b2c3d4-e5f6-7890-abcd-ef1234567890" ]] || fail "expected conversation_id from --resume, got: $result"
    echo "ok: --resume <uuid> populates conversation_id on the record"
}

test_launch_stdout_closes_promptly() {
    # Command substitution out="$(cctrl start -d ...)" completes promptly,
    # not blocked by the background poll.
    make_fake_tmux "$TMPDIR/tmux"
    local project="$TMPDIR/stdout-project"
    local log="$TMPDIR/stdout-tmux.log"
    mkdir -p "$project"
    : > "$log"
    local start_time end_time elapsed
    start_time="$(date +%s)"
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_AGENT=claude CCTRL_EMIT_SESSION=1 \
        CCTRL_RESUME_POLL_TIMEOUT=10 CCTRL_RESUME_POLL_INTERVAL=2 \
        "$ROOT/cctrl" start -d "$project" 2>&1)"
    end_time="$(date +%s)"
    elapsed=$((end_time - start_time))
    [[ "$elapsed" -lt 8 ]] || fail "command substitution took ${elapsed}s (should be <8s); stdout likely inherited by poll"
    assert_contains "$out" "detached session started"
    echo "ok: start -d stdout closes promptly (poll does not block command substitution)"
}

test_launch_metadata_write_warns() {
    # Failed metadata write shows warning on non-peer launch.
    make_fake_tmux "$TMPDIR/tmux"
    local project="$TMPDIR/warn-project"
    local log="$TMPDIR/warn-tmux.log"
    mkdir -p "$project"
    : > "$log"
    local bad_meta="$TMPDIR/bad-meta"
    mkdir -p "$bad_meta"
    chmod 000 "$bad_meta"
    local out rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_AGENT=claude CCTRL_SESSION_METADATA_DIR="$bad_meta" \
        CCTRL_RESUME_POLL_TIMEOUT=0 \
        "$ROOT/cctrl" start -d "$project" 2>&1)" || rc=$?
    chmod 755 "$bad_meta"
    assert_contains "$out" "Could not write session metadata"
    echo "ok: failed metadata write shows warning on non-peer launch"
}

test_resume_no_uuid_no_conversation_id() {
    # --resume without a UUID value writes no conversation_id.
    make_fake_tmux "$TMPDIR/tmux"
    local project="$TMPDIR/noid-project"
    local log="$TMPDIR/noid-tmux.log"
    mkdir -p "$project"
    : > "$log"
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_AGENT=claude CCTRL_EMIT_SESSION=1 \
        CCTRL_RESUME_POLL_TIMEOUT=0 \
        "$ROOT/cctrl" start -d "$project" --resume 2>&1)"
    local result
    result="$(session_record_json "TMUX--noid-project" | jq -r '.conversation_id // empty' 2>/dev/null)"
    [[ -z "$result" || "$result" == "null" ]] || fail "bare --resume should not set conversation_id, got: $result"
    echo "ok: --resume with no UUID writes no conversation_id"
}

test_session_write_metadata_includes_new_fields() {
    # _session_write_metadata emits conversation_id and transcript_path keys.
    make_fake_tmux "$TMPDIR/tmux"
    local project="$TMPDIR/newfields-project"
    local log="$TMPDIR/newfields-tmux.log"
    mkdir -p "$project"
    : > "$log"
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_AGENT=claude CCTRL_EMIT_SESSION=1 \
        CCTRL_RESUME_POLL_TIMEOUT=0 \
        "$ROOT/cctrl" start -d "$project" 2>&1)"
    assert_contains "$out" "detached session started"
    local meta
    meta="$(session_record_json "TMUX--newfields-project")"
    printf '%s' "$meta" | jq -e 'has("conversation_id")' >/dev/null || fail "record missing conversation_id field"
    printf '%s' "$meta" | jq -e 'has("transcript_path")' >/dev/null || fail "record missing transcript_path field"
    echo "ok: _session_write_metadata emits conversation_id and transcript_path"
}

# ── Plan 058: provider-neutral task records ──────────────────────────

test_task_record_host_id_is_stable_exclusive_and_private() {
    local root="$TMPDIR/task-host-id" host_file="$TMPDIR/task-host-id/host-id" outputs="$TMPDIR/task-host-id/outputs"
    rm -rf "$root"; mkdir -p "$root" "$outputs"
    local -a pids=()
    local i pid
    for i in 1 2 3 4 5 6 7 8; do
        (CCTRL_DATA_DIR="$root" CCTRL_HOST_ID_FILE="$host_file" cctrl_source_eval '_cctrl_host_id' > "$outputs/$i") &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || fail "concurrent host-id creator failed"
    done
    [[ "$(cat "$outputs"/* | sort -u | wc -l | tr -d ' ')" == "1" ]] || fail "host-id creators did not converge on one winner"
    [[ "$(cat "$outputs/1")" =~ ^[0-9a-f]{32}$ ]] || fail "host id has wrong format"
    local mode
    mode="$(stat -f %Lp "$host_file" 2>/dev/null || stat -c %a "$host_file")"
    [[ "$mode" == "600" ]] || fail "host-id mode is $mode, expected 600"

    local bad="$TMPDIR/task-host-id-bad"
    printf 'malformed\n' > "$bad"
    if CCTRL_HOST_ID_FILE="$bad" cctrl_source_eval '_cctrl_host_id' >/dev/null 2>&1; then
        fail "malformed host id was accepted"
    fi
    rm -f "$bad"; ln -s "$host_file" "$bad"
    if CCTRL_HOST_ID_FILE="$bad" cctrl_source_eval '_cctrl_host_id' >/dev/null 2>&1; then
        fail "symlink host-id file was accepted"
    fi
    echo "ok: durable host id has exclusive winner semantics, stable value, mode 0600, and rejects malformed/symlink inputs"
}

test_task_record_schema_v2_and_provisional_promotion() {
    local root="$TMPDIR/task-v2" meta="$TMPDIR/task-v2/meta" data="$TMPDIR/task-v2/data"
    rm -rf "$root"; mkdir -p "$meta" "$data"
    CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_session_write_metadata "TMUX--task-v2" "/same/cwd" directory "/same/cwd" "same title" "purpose" "prompt" "cmd" "" codex "" ""'
    local provisional record canonical
    provisional="$(session_record_path "TMUX--task-v2" "$meta")"
    [[ "${provisional##*/}" == launch-*.json ]] || fail "fresh launch was not provisional: $provisional"
    record="$(cat "$provisional")"
    printf '%s' "$record" | jq -e '
        .schema_version == 2 and .provider == "codex" and .provider_task_id == null and
        .origin == "cctrl" and (.host_id|type == "string") and
        .registered_by_cctrl == true and .launched_by_cctrl == true and
        .execution_runtime == "tmux" and .control_owner == "cctrl" and
        .lifecycle_state == "provisional" and .restore_strategy == "tmux" and
        (.last_observed_at|type == "string") and .tmux_session == "TMUX--task-v2" and
        .lineage == {forked_from_id:null,parent_thread_id:null,derived_root_id:null,derived_root_basis:null} and
        (.ownership_evidence|length == 1)
    ' >/dev/null || fail "new launch does not satisfy schema-v2 shape"

    CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_session_update_metadata_field "TMUX--task-v2" conversation_id "provider/task:id?raw"'
    canonical="$(session_record_path "TMUX--task-v2" "$meta")"
    [[ "${canonical##*/}" =~ ^task-[0-9a-f]{64}\.json$ ]] || fail "promotion did not use a fixed digest key: $canonical"
    [[ "${canonical##*/}" != *provider* && "${canonical##*/}" != *raw* ]] || fail "canonical filename leaked provider id"
    [[ ! -e "$provisional" ]] || fail "provisional source was not retired after canonical commit"
    jq -e '.provider_task_id == "provider/task:id?raw" and .conversation_id == "provider/task:id?raw" and .lifecycle_state == "active"' "$canonical" >/dev/null \
        || fail "promotion did not persist stable identity"

    local host_id key_alias_a key_alias_b key_other
    host_id="$(jq -r '.host_id' "$canonical")"
    # shellcheck disable=SC2016 # evaluated deliberately inside cctrl_source_eval
    key_alias_a="$(CCTRL_HOST_PREFIX=alias-a CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_record_key codex "$(_cctrl_host_id)" "same-id"')"
    # shellcheck disable=SC2016 # evaluated deliberately inside cctrl_source_eval
    key_alias_b="$(CCTRL_HOST_PREFIX=alias-b CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_record_key codex "$(_cctrl_host_id)" "same-id"')"
    # shellcheck disable=SC2016 # evaluated deliberately inside cctrl_source_eval
    key_other="$(CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_record_key codex "$(_cctrl_host_id)" "different-id"')"
    [[ "$key_alias_a" == "$key_alias_b" ]] || fail "mutable host alias changed task identity"
    [[ "$key_alias_a" != "$key_other" ]] || fail "different provider ids collided despite matching cwd/title"
    [[ "$host_id" =~ ^[0-9a-f]{32}$ ]] || fail "record host_id is malformed"
    local other_data="$root/other-data" other_key
    mkdir -p "$other_data"
    # shellcheck disable=SC2016 # evaluated deliberately inside cctrl_source_eval
    other_key="$(CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$other_data/host-id" cctrl_source_eval '_task_record_key codex "$(_cctrl_host_id)" "same-id"')"
    [[ "$key_alias_a" != "$other_key" ]] || fail "different durable hosts produced the same task key"

    CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_session_write_metadata "TMUX--claude-v2" /tmp directory /tmp label purpose prompt cmd "" claude "claude-session-id" ""'
    jq -e '.provider == "claude" and .provider_task_id == "claude-session-id" and .origin == "cctrl" and .execution_runtime == "tmux"' \
        "$(session_record_path "TMUX--claude-v2" "$meta")" >/dev/null || fail "Claude launch did not use provider-neutral v2 record"
    echo "ok: schema-v2 launch is provisional, promotes atomically to digest identity, and ignores aliases/cwd/title"
}

test_task_record_legacy_validation_and_lazy_promotion() {
    local root="$TMPDIR/task-legacy" meta="$TMPDIR/task-legacy/meta" data="$TMPDIR/task-legacy/data" legacy="$TMPDIR/task-legacy/meta/TMUX--legacy.json"
    rm -rf "$root"; mkdir -p "$meta" "$data"
    cat > "$legacy" <<'JSON'
{"name":"TMUX--legacy","agent":"codex","cctrl_managed":true,"control_surface":"app","conversation_id":"legacy-id","created_at":"2026-09-16T10:00:00Z","cwd":"/same","purpose":"same"}
JSON
    local before normalized canonical
    before="$(shasum -a 256 "$legacy" | awk '{print $1}')"
    # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
    normalized="$(CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_record_normalize_json "$1"' "$legacy")"
    printf '%s' "$normalized" | jq -e '
        .schema_version == 2 and .provider == "codex" and .provider_task_id == "legacy-id" and
        .control_owner == "unknown" and .execution_runtime == "unknown" and
        .restore_strategy == null and .origin == "cctrl"
    ' >/dev/null || fail "legacy app-intent record was not normalized conservatively"
    # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
    canonical="$(CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_record_promote_legacy "$1"' "$legacy")"
    [[ -f "$canonical" ]] || fail "legacy promotion did not create canonical record"
    [[ "$before" == "$(shasum -a 256 "$legacy" | awk '{print $1}')" ]] || fail "legacy compatibility input changed"
    [[ "$(CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_session_metadata_file "TMUX--legacy"')" == "$canonical" ]] \
        || fail "canonical-first lookup did not prefer promoted record"

    printf '%s\n' '{"schema_version":3}' > "$meta/future.json"
    # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
    if CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_record_normalize_json "$1"' "$meta/future.json" >/dev/null 2>&1; then
        fail "future schema version was accepted"
    fi
    jq '.schema_version="2"' "$canonical" > "$meta/wrong-type.json"
    # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
    if CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_record_normalize_json "$1"' "$meta/wrong-type.json" >/dev/null 2>&1; then
        fail "wrong-type schema version was accepted"
    fi
    jq '.lineage.derived_root_id="root" | .lineage.derived_root_basis="provider-root"' "$canonical" > "$meta/bad-root.json"
    # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
    if CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_record_normalize_json "$1"' "$meta/bad-root.json" >/dev/null 2>&1; then
        fail "provider-looking derived root basis was accepted"
    fi
    jq '(.ownership_evidence[0]) as $e | .ownership_evidence = [range(0;33) as $i | $e + {source:("source-" + ($i|tostring))}]' "$canonical" > "$meta/too-much-evidence.json"
    # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
    if CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_record_normalize_json "$1"' "$meta/too-much-evidence.json" >/dev/null 2>&1; then
        fail "unbounded ownership evidence was accepted"
    fi
    cat > "$meta/TMUX--no-id.json" <<'JSON'
{"name":"TMUX--no-id","agent":"codex","cctrl_managed":true,"control_surface":"tmux","conversation_id":null,"created_at":"2026-09-16T10:00:00Z"}
JSON
    local no_id_before
    no_id_before="$(shasum -a 256 "$meta/TMUX--no-id.json" | awk '{print $1}')"
    if CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_session_update_metadata_field "TMUX--no-id" purpose changed' >/dev/null 2>&1; then
        fail "legacy mutation without stable provider identity succeeded"
    fi
    [[ "$no_id_before" == "$(shasum -a 256 "$meta/TMUX--no-id.json" | awk '{print $1}')" ]] || fail "identity-less legacy record was modified"
    echo "ok: legacy normalization is conservative/read-only, promotion is lazy/canonical-first, and malformed/future schemas fail closed"
}

test_task_record_merge_conflict_preserves_evidence() {
    local root="$TMPDIR/task-conflict" meta="$TMPDIR/task-conflict/meta" data="$TMPDIR/task-conflict/data"
    rm -rf "$root"; mkdir -p "$meta" "$data"
    CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_session_write_metadata "TMUX--canonical" /tmp directory /tmp label purpose prompt cmd "" codex "shared-id" ""'
    local canonical incoming
    canonical="$(session_record_path "TMUX--canonical" "$meta")"
    incoming="$meta/launch-interrupted.json"
    jq '
        .name="APP--observation" | .tmux_session=null | .origin="codex-app" |
        .registered_by_cctrl=false | .launched_by_cctrl=false |
        .execution_runtime="app-server" | .control_owner="app" | .restore_strategy="provider-managed" |
        .ownership_evidence=[{source:"app-server",source_instance:"connection-1",source_cursor:"cursor-1",authority_class:"authoritative",observed_owner:"app",observed_runtime:"app-server",observed_state:"active",observed_at:"2026-09-16T11:00:00Z",reason:"thread response on app connection"}]
    ' "$canonical" > "$incoming"
    # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
    CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_task_record_promote_legacy "$1" "shared-id" >/dev/null' "$incoming"
    jq -e '
        .origin == "cctrl" and .provider_task_id == "shared-id" and
        .execution_runtime == "conflict" and .control_owner == "conflict" and
        .registered_by_cctrl == true and .launched_by_cctrl == true and
        ([.ownership_evidence[].source] | index("cctrl-launch") != null) and
        ([.ownership_evidence[].source] | index("app-server") != null)
    ' "$canonical" >/dev/null || fail "no-clobber merge did not preserve canonical identity/origin and competing evidence"
    [[ ! -e "$incoming" ]] || fail "committed interrupted-promotion source was not retired"
    echo "ok: canonical merge is no-clobber, provenance-strengthening, and preserves authoritative conflicts"
}

test_task_record_identity_independent_close_continues() {
    local root="$TMPDIR/task-close-no-id" meta="$TMPDIR/task-close-no-id/meta" data="$TMPDIR/task-close-no-id/data" bin="$TMPDIR/task-close-no-id/bin" log="$TMPDIR/task-close-no-id/tmux.log"
    rm -rf "$root"; mkdir -p "$meta" "$data" "$bin"
    make_fake_tmux "$bin/tmux"
    : > "$log"
    cat > "$meta/TMUX--no-provider-id.json" <<'JSON'
{"name":"TMUX--no-provider-id","agent":"codex","cctrl_managed":true,"control_surface":"tmux","conversation_id":null,"created_at":"2026-09-16T10:00:00Z"}
JSON
    local before out
    before="$(shasum -a 256 "$meta/TMUX--no-provider-id.json" | awk '{print $1}')"
    out="$(PATH="$bin:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION=1 CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" \
        "$ROOT/cctrl" session close TMUX--no-provider-id --now)"
    assert_contains "$out" "Closed session: TMUX--no-provider-id"
    assert_contains "$out" "Provider metadata was not updated"
    grep -q 'kill-session' "$log" || fail "identity-independent tmux close did not run"
    [[ "$before" == "$(shasum -a 256 "$meta/TMUX--no-provider-id.json" | awk '{print $1}')" ]] || fail "close rewrote identity-less legacy metadata"
    echo "ok: identity-dependent provider archive refuses missing identity while identity-independent tmux close continues"
}

test_task_registry_atomic_concurrent_updates() {
    local root="$TMPDIR/task-registry-concurrent" meta="$TMPDIR/task-registry-concurrent/meta" data="$TMPDIR/task-registry-concurrent/data"
    rm -rf "$root"; mkdir -p "$meta" "$data"
    CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_session_write_metadata "TMUX--registry" /tmp directory /tmp label purpose prompt cmd "" codex "registry-id" ""'
    local record key host event_a="$root/a.json" event_b="$root/b.json" p1 p2 rc1=0 rc2=0
    record="$(session_record_path "TMUX--registry" "$meta")"; key="${record##*/}"; key="${key%.json}"
    host="$(jq -r '.host_id' "$record")"
    jq -n --arg host "$host" '{version:1,event_id:"field-a",event_type:"observe",provider:"codex",provider_task_id:"registry-id",host_id:$host,source:"cctrl-metadata",source_instance_id:"writer-a",source_sequence:1,source_cursor:null,expected_record_digest:null,observed_at:"2026-09-16T10:00:00Z",payload:{authority_class:"authoritative",set:{purpose:"atomic-purpose"}}}' > "$event_a"
    jq -n --arg host "$host" '{version:1,event_id:"field-b",event_type:"observe",provider:"codex",provider_task_id:"registry-id",host_id:$host,source:"cctrl-metadata",source_instance_id:"writer-b",source_sequence:1,source_cursor:null,expected_record_digest:null,observed_at:"2026-09-16T10:00:01Z",payload:{authority_class:"authoritative",set:{transcript_path:"/tmp/atomic-rollout.jsonl"}}}' > "$event_b"

    # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
    CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_task_registry_apply_event "$1" "$2" >/dev/null' "$key" "$event_a" & p1=$!
    # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
    CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_task_registry_apply_event "$1" "$2" >/dev/null' "$key" "$event_b" & p2=$!
    wait "$p1" || rc1=$?
    wait "$p2" || rc2=$?
    [[ "$rc1" -eq 0 && "$rc2" -eq 0 ]] || fail "concurrent registry writers failed: $rc1/$rc2"
    jq -e '.purpose == "atomic-purpose" and .transcript_path == "/tmp/atomic-rollout.jsonl" and
        (.registry_event_ids | index("field-a") != null) and (.registry_event_ids | index("field-b") != null)' "$record" >/dev/null \
        || fail "locked concurrent registry writers lost an update"
    [[ ! -e "$meta/.task-registry-locks/$key.lock" ]] || fail "registry lock leaked after concurrent writers"
    echo "ok: registry lock serializes the whole read-reduce-write cycle without losing different-field updates"
}

test_task_registry_replay_order_and_guards() {
    local root="$TMPDIR/task-registry-order" seed data a b
    seed="$root/seed"; data="$root/data"; a="$root/a"; b="$root/b"
    rm -rf "$root"; mkdir -p "$seed" "$data" "$a" "$b"
    CCTRL_SESSION_METADATA_DIR="$seed" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_session_write_metadata "TMUX--order" /tmp directory /tmp label purpose prompt cmd "" codex "<THREAD_ID>" ""'
    local seed_record key host basis terminal="$root/terminal.json" app="$root/app.json" filtered_a filtered_b before bad="$root/bad.json" out
    seed_record="$(session_record_path "TMUX--order" "$seed")"; key="${seed_record##*/}"; key="${key%.json}"
    cp "$seed_record" "$a/$key.json"; cp "$seed_record" "$b/$key.json"
    host="$(jq -r '.host_id' "$seed_record")"
    # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
    basis="$(CCTRL_SESSION_METADATA_DIR="$seed" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_registry_record_digest "$1"' "$seed_record")"
    jq --arg host "$host" --arg basis "$basis" '.host_id=$host | .expected_record_digest=$basis' \
        "$ROOT/tests/fixtures/codex-lifecycle/registry-events/terminal-claim.json" > "$terminal"
    jq --arg host "$host" --arg basis "$basis" '.host_id=$host | .expected_record_digest=$basis' \
        "$ROOT/tests/fixtures/codex-lifecycle/registry-events/app-claim.json" > "$app"
    # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
    CCTRL_SESSION_METADATA_DIR="$a" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_registry_apply_event "$1" "$2" >/dev/null' "$key" "$terminal"
    # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
    CCTRL_SESSION_METADATA_DIR="$a" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_registry_apply_event "$1" "$2" >/dev/null' "$key" "$app"
    # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
    CCTRL_SESSION_METADATA_DIR="$b" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_registry_apply_event "$1" "$2" >/dev/null' "$key" "$app"
    # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
    CCTRL_SESSION_METADATA_DIR="$b" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_registry_apply_event "$1" "$2" >/dev/null' "$key" "$terminal"
    filtered_a="$(jq -S '{control_owner,execution_runtime,lifecycle_state,restore_strategy,ownership_observations,registry_event_ids,registry_source_high_water,ownership_evidence,last_observed_at}' "$a/$key.json")"
    filtered_b="$(jq -S '{control_owner,execution_runtime,lifecycle_state,restore_strategy,ownership_observations,registry_event_ids,registry_source_high_water,ownership_evidence,last_observed_at}' "$b/$key.json")"
    [[ "$filtered_a" == "$filtered_b" ]] || fail "same-basis ownership conflict depended on arrival order"
    jq -e --slurpfile expected "$ROOT/tests/fixtures/codex-lifecycle/registry-events/conflict-expected.json" '
        .control_owner == $expected[0].control_owner and .execution_runtime == $expected[0].execution_runtime and
        .lifecycle_state == $expected[0].lifecycle_state and .restore_strategy == null and
        (.ownership_observations | length) == $expected[0].ownership_observation_count
    ' "$a/$key.json" >/dev/null || fail "canonical conflict state did not match fixture"

    before="$(shasum -a 256 "$a/$key.json" | awk '{print $1}')"
    jq '.event_id="weak-owner" | .payload.authority_class="diagnostic" | .expected_record_digest="bad"' "$terminal" > "$bad"
    # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
    if CCTRL_SESSION_METADATA_DIR="$a" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_registry_apply_event "$1" "$2" >/dev/null' "$key" "$bad" 2>/dev/null; then
        fail "weak diagnostic evidence changed ownership"
    fi
    jq -n --arg host "$host" '{version:1,event_id:"immutable-attack",event_type:"observe",provider:"codex",provider_task_id:"<THREAD_ID>",host_id:$host,source:"cctrl-metadata",source_instance_id:"attack",source_sequence:null,source_cursor:null,expected_record_digest:null,observed_at:"2026-09-16T10:00:02Z",payload:{authority_class:"diagnostic",set:{origin:"codex-app",launched_by_cctrl:false}}}' > "$bad"
    # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
    if CCTRL_SESSION_METADATA_DIR="$a" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_registry_apply_event "$1" "$2" >/dev/null' "$key" "$bad" 2>/dev/null; then
        fail "observer downgraded immutable provenance"
    fi
    [[ "$before" == "$(shasum -a 256 "$a/$key.json" | awk '{print $1}')" ]] || fail "rejected registry event modified the record"

    jq -n --arg host "$host" '{version:1,event_id:"cursor-10",event_type:"observe",provider:"codex",provider_task_id:"<THREAD_ID>",host_id:$host,source:"cctrl-metadata",source_instance_id:"cursor-source",source_sequence:10,source_cursor:null,expected_record_digest:null,observed_at:"2026-09-16T10:00:03Z",payload:{authority_class:"authoritative",set:{purpose:"cursor-new"}}}' > "$bad"
    # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
    CCTRL_SESSION_METADATA_DIR="$a" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_registry_apply_event "$1" "$2" >/dev/null' "$key" "$bad"
    jq '.event_id="cursor-9" | .source_sequence=9 | .payload.set.purpose="cursor-old"' "$bad" > "$root/stale.json"
    # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
    out="$(CCTRL_SESSION_METADATA_DIR="$a" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_registry_apply_event "$1" "$2"' "$key" "$root/stale.json")"
    [[ "$(jq -r '.status' <<< "$out")" == "stale" && "$(jq -r '.purpose' "$a/$key.json")" == "cursor-new" ]] \
        || fail "source cursor below the high-water mark was not rejected"

    before="$(shasum -a 256 "$a/$key.json" | awk '{print $1}')"
    jq '.event_id="fail-before-rename" | .source_sequence=11 | .payload.set.purpose="must-not-commit"' "$bad" > "$root/failpoint.json"
    # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
    if CCTRL_TASK_REGISTRY_FAIL_BEFORE_RENAME=1 CCTRL_SESSION_METADATA_DIR="$a" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_task_registry_apply_event "$1" "$2" >/dev/null' "$key" "$root/failpoint.json" 2>/dev/null; then
        fail "injected pre-rename termination unexpectedly succeeded"
    fi
    [[ "$before" == "$(shasum -a 256 "$a/$key.json" | awk '{print $1}')" ]] || fail "pre-rename failure modified the canonical record"

    printf '%s\n' '{not-json' > "$a/$key.json"
    before="$(shasum -a 256 "$a/$key.json" | awk '{print $1}')"
    # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
    if CCTRL_SESSION_METADATA_DIR="$a" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_task_registry_apply_event "$1" "$2" >/dev/null' "$key" "$terminal" 2>/dev/null; then
        fail "malformed registry record was accepted"
    fi
    [[ "$before" == "$(shasum -a 256 "$a/$key.json" | awk '{print $1}')" ]] || fail "malformed registry record was touched"
    echo "ok: replay order converges; cursors, CAS, provenance, malformed input, and pre-rename failure all fail closed"
}

test_task_registry_lock_stale_timeout_and_release_token() {
    local root="$TMPDIR/task-registry-lock" meta data key lock token rc=0
    meta="$root/meta"; data="$root/data"; key="task-$(printf 'a%.0s' {1..64})"
    rm -rf "$root"; mkdir -p "$meta/.task-registry-locks" "$data"; chmod 700 "$meta/.task-registry-locks"
    lock="$meta/.task-registry-locks/$key.lock"
    printf '999999\t1\t%s\n' "$(printf 'b%.0s' {1..32})" > "$lock"
    # shellcheck disable=SC2016 # registry token variables belong to the sourced shell
    CCTRL_TASK_REGISTRY_LOCK_GRACE=0 CCTRL_TASK_REGISTRY_LOCK_TIMEOUT=1 CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_task_registry_lock_acquire "$1"; _task_registry_lock_release "$TASK_REGISTRY_LOCK_FILE" "$TASK_REGISTRY_LOCK_TOKEN"' "$key" \
        || fail "dead stale registry lock was not reclaimed"
    printf '%s\t%s\t%s\n' "$$" "$(date +%s)" "$(printf 'c%.0s' {1..32})" > "$lock"
    # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
    CCTRL_TASK_REGISTRY_LOCK_GRACE=0 CCTRL_TASK_REGISTRY_LOCK_TIMEOUT=1 CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_task_registry_lock_acquire "$1"' "$key" >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 75 ]] || fail "live registry lock did not time out closed (rc=$rc)"
    token="$(awk -F '\t' '{print $3}' "$lock")"
    # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
    if CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_task_registry_lock_release "$1" deadbeefdeadbeefdeadbeefdeadbeef' "$lock" >/dev/null 2>&1; then
        fail "registry lock released with a non-owner token"
    fi
    [[ -f "$lock" && "$token" == "$(awk -F '\t' '{print $3}' "$lock")" ]] || fail "token mismatch disturbed live registry lock"
    rm -f "$lock"
    echo "ok: task registry locks reclaim dead owners after grace, time out on live owners, and require the owner token"
}

test_task_registry_structural_boundary() {
    rg -q '^_task_registry_apply_event\(\)' "$ROOT/cctrl" || fail "registry apply boundary is missing"
    rg -q '^_task_registry_reduce\(\)' "$ROOT/cctrl" || fail "pure registry reducer boundary is missing"
    local update transition direct_rewrite
    update="$(awk '/^_session_update_metadata_field\(\)/,/^}/' "$ROOT/cctrl")"
    transition="$(awk '/^_task_record_transition\(\)/,/^}/' "$ROOT/cctrl")"
    [[ "$update" == *'_task_registry_apply_event'* && "$transition" == *'_task_registry_apply_event'* ]] \
        || fail "schema-v2 metadata writers bypass the task registry boundary"
    direct_rewrite="mv \"\$tmp\" \"\$file\""
    [[ "$update" != *"$direct_rewrite"* && "$transition" != *"$direct_rewrite"* ]] \
        || fail "ad-hoc schema-v2 rewrite remains outside the registry"
    echo "ok: schema-v2 metadata and transition writers route through the single registry API"
}

if [[ -n "${CCTRL_TEST_ONLY:-}" ]]; then
    case "$CCTRL_TEST_ONLY" in
        session-attest)
            test_session_attest_live_tmux_process_matches
            test_session_attest_direct_metadata
            test_session_attest_stale_tmux_session_missing
            test_session_attest_malformed_metadata_fails_human_mode
            test_session_runtime_mcp_attests_fixed_session
            echo "ok"
            exit 0
            ;;
        task-records)
            test_task_record_host_id_is_stable_exclusive_and_private
            test_task_record_schema_v2_and_provisional_promotion
            test_task_record_legacy_validation_and_lazy_promotion
            test_task_record_merge_conflict_preserves_evidence
            test_task_record_identity_independent_close_continues
            test_task_registry_atomic_concurrent_updates
            test_task_registry_replay_order_and_guards
            test_task_registry_lock_stale_timeout_and_release_token
            test_task_registry_structural_boundary
            echo "ok"
            exit 0
            ;;
        task-record-compat)
            test_codex_rename_updates_app_title
            test_codex_rename_prefers_prompt_match_over_stale_id
            test_session_app_ls_codex_records
            test_codex_close_archives_and_resolves_rollout_identity
            test_session_release_to_app_quarantines_stale_codex_lock
            test_update_metadata_field_preserves_keys
            test_backfill_ids_fills_resume_flag
            test_backfill_ids_idempotent
            test_session_list_refresh_writes_on_change
            test_session_list_refresh_skips_when_unchanged
            echo "ok"
            exit 0
            ;;
        task-record-launch)
            test_detached_arg_parsing
            test_start_peer_env_and_metadata
            test_live_aware_index_picker
            test_launch_resume_captures_conversation_id
            test_resume_no_uuid_no_conversation_id
            test_session_write_metadata_includes_new_fields
            echo "ok"
            exit 0
            ;;
        task-record-launch-basic)
            test_detached_arg_parsing
            echo "ok"
            exit 0
            ;;
        task-record-launch-peer)
            test_start_peer_env_and_metadata
            test_live_aware_index_picker
            echo "ok"
            exit 0
            ;;
        task-record-launch-peer-only)
            test_start_peer_env_and_metadata
            echo "ok"
            exit 0
            ;;
        task-record-launch-index)
            test_live_aware_index_picker
            echo "ok"
            exit 0
            ;;
        task-record-launch-resume)
            test_launch_resume_captures_conversation_id
            test_resume_no_uuid_no_conversation_id
            test_session_write_metadata_includes_new_fields
            echo "ok"
            exit 0
            ;;
        task-record-list)
            test_session_list_codex_default_model
            test_session_list_agent_not_mislabelled_by_prompt
            test_session_list_agent_prefers_recorded_metadata
            test_session_list_malformed_metadata_uses_unknown_defaults
            test_session_list_refresh_writes_on_change
            test_session_list_refresh_skips_when_unchanged
            echo "ok"
            exit 0
            ;;
        *)
            fail "unknown focused test group: $CCTRL_TEST_ONLY"
            ;;
    esac
fi

test_syntax
test_launch_args
test_agent_prompt_without_default
test_profile_prompt_overrides_global_default
test_local_config_overrides_shared_defaults
test_profile_writes_are_owner_only
test_profile_use_current_diff
test_detached_agent_prompt_exports_selection
test_detached_arg_parsing
test_live_aware_index_picker
test_start_defaults_to_tmux
test_start_peer_env_and_metadata
test_shortcut_no_args_defaults_to_tmux
test_purpose_prompt_uses_controlling_tty
test_remote_shortcut_injects_purpose
test_attach_prompt_after_start
test_codex_statusline_tui_config
test_context_names
test_bridge_prefix_matches_explicit_name
test_dir_launch_adopts_shortcut_alias
test_dir_launch_shortcut_collision_deterministic
test_dir_launch_no_shortcut_match_unchanged
test_session_doctor_classifies_bridge
test_session_doctor_detects_collision
test_session_doctor_quarantines_orphan_codex_writer_lock
test_session_doctor_realign_reports_hint
test_session_doctor_realign_fix_emits_relaunch
test_session_doctor_realign_skips_busy
test_session_doctor_realign_idempotent
test_session_doctor_realign_real_relaunch
test_session_autoheal_dry_run_selects_dead_and_no_repair
test_session_autoheal_skips_unsent_draft
test_session_autoheal_skips_glyph_draft
test_session_autoheal_skips_busy
test_session_autoheal_skips_copy_mode
test_session_autoheal_heals_clean_dead_bridge
test_session_autoheal_ignores_live_bridge
test_session_autoheal_install_uninstall_plist
test_session_list_codex_default_model
test_session_list_agent_not_mislabelled_by_prompt
test_session_list_agent_prefers_recorded_metadata
test_session_list_malformed_metadata_uses_unknown_defaults
test_session_list_last_active_from_updated_at
test_session_list_last_active_from_transcript_mtime
test_session_list_unresolvable_session
test_session_list_sorts_by_last_active
test_session_list_base_state
test_session_list_recap
test_session_list_rich_state
test_session_pane_has_draft_glyph_fixtures
test_session_rich_state_detects_glyph_draft
test_needs_me_digest
test_host_registry_crud
test_fleet_merges_multiple_hosts
test_fleet_sorts_by_recency_across_hosts
test_fleet_offline_host_non_fatal
test_fleet_version_skew_missing_fields
test_peer_registry_manual_alias_and_identity
test_peer_derived_tmux_and_shadowing
test_peer_validation_and_errors
test_peer_alias_derived_requires_manual_registration
test_peer_tmux_missing_still_resolves_manual
test_peer_mailbox_send_list_show
test_peer_sender_snapshot
test_peer_mailbox_ack_authorization_and_states
test_peer_mailbox_unknowns_and_identity
# SKIPPED: hangs on macOS bash 3.2 (flock issue) — pre-existing, not 051/052
# test_peer_mailbox_concurrency_and_stale_lock
test_peer_polling_json_contracts
test_peer_polling_identity_and_errors
test_peer_mcp_bridge_stdio
test_peer_overview
test_peer_deliver_tmux_nudge_lifecycle
test_peer_deliver_addressee_guard_replaced_occupant
test_peer_deliver_busy_no_submit_and_inline
test_peer_inline_envelope_and_ack
test_peer_inline_envelope_reachability
test_peer_inline_paste_failure_keeps_queued
test_peer_inline_delivery_idempotent
test_peer_inline_pastes_into_recipient_pane
test_peer_reachability_class_is_pure
test_peer_inline_body_bytes_preserved
test_peer_inline_delivered_appears_in_stale_sweep
test_peer_deliver_claude_modal_detection
test_peer_deliver_codex_modal_detection
test_peer_deliver_failures_all_and_concurrency
test_peer_orchestrator_status_nudge_watch
test_peer_gc_retention_and_doctor
test_peer_doorbell_hook
test_peer_send_deliver_outcomes
test_peer_reply_core
test_peer_reply_ack_and_refusals
test_peer_reply_single_enumeration
test_peer_mcp_send_deliver_outcomes
test_session_close_self_graceful
test_session_close_stale_tmux_refuses_current
test_session_current_identity_json
test_session_attest_live_tmux_process_matches
test_session_attest_direct_metadata
test_session_attest_stale_tmux_session_missing
test_session_attest_malformed_metadata_fails_human_mode
test_session_runtime_mcp_attests_fixed_session
test_session_say_submit_and_no_submit
test_session_say_body_file_preserves_newlines
test_session_say_modal_deferral_not_overridden_by_force_busy
test_session_say_claude_modal_blocks_and_benign_pane_passes
test_session_say_unknown_readiness_requires_force_busy
test_session_say_errors
test_peer_session_resolves_and_alias
test_peer_session_offline_unknown_stale
test_peer_attach_targets_resolved_session
test_peer_say_delegates_and_no_mailbox
test_peer_help_agent
test_peer_mcp_say_peer
test_peer_direct_non_local_host_hint
test_peer_attach_remote_forwarding_tty
test_peer_ls_shows_session_and_status
test_session_close_named_immediate
test_session_close_outside_requires_name
test_session_prune_never_prompted_claude
test_session_prune_fresh_active_not_candidate
test_session_prune_codex_no_claude_transcript_bug_guard
test_session_prune_codex_never_prompted
test_codex_rename_updates_app_title
test_codex_rename_prefers_prompt_match_over_stale_id
test_session_app_ls_codex_records
test_codex_wrapper_exit_preserves_app_task
test_codex_close_archives_and_resolves_rollout_identity
test_session_release_to_app_quarantines_stale_codex_lock
test_session_prune_dry_run_closes_nothing
test_session_prune_excludes_self_and_attached
test_usage_cost_fixtures
test_project_name_derives_home_at_runtime
test_peer_contract_docs
test_update_metadata_field_preserves_keys
test_update_metadata_field_missing_record
test_update_metadata_field_malformed_json
test_backfill_ids_fills_resume_flag
test_backfill_ids_refuses_uuid_in_cwd
test_backfill_ids_already_set
test_backfill_ids_dry_run_writes_nothing
test_backfill_ids_idempotent
test_backfill_ids_json
test_active_session_count_excludes_unmanaged
test_session_list_refresh_writes_on_change
test_session_list_refresh_skips_when_unchanged
test_launch_resume_captures_conversation_id
test_launch_stdout_closes_promptly
test_launch_metadata_write_warns
test_resume_no_uuid_no_conversation_id
test_session_write_metadata_includes_new_fields
test_task_record_host_id_is_stable_exclusive_and_private
test_task_record_schema_v2_and_provisional_promotion
test_task_record_legacy_validation_and_lazy_promotion
test_task_record_merge_conflict_preserves_evidence
test_task_record_identity_independent_close_continues
test_task_registry_atomic_concurrent_updates
test_task_registry_replay_order_and_guards
test_task_registry_lock_stale_timeout_and_release_token
test_task_registry_structural_boundary
test_snapshot_header_and_session_shape
test_snapshot_initial_prompt_absent
test_snapshot_empty_fleet_guard_preserves
test_snapshot_allow_empty_overrides
test_snapshot_history_and_latest_agree
test_snapshot_retention_pruning
test_snapshot_no_tmux_mutation
test_snapshot_tmux_absent_preserves
test_snapshot_first_run_empty_writes
test_snapshot_transcript_bytes_null_when_missing
test_snapshot_managed_matches_session_ls
test_snapshot_launch_flags_round_trip
test_snapshot_conversation_id_from_session_id
test_restore_ordering_by_last_active
test_restore_only_filter
test_restore_cap_on_total
test_restore_null_conversation_id_skipped
test_restore_dry_run_spawns_nothing
test_restore_gate_stops_below_threshold
test_restore_limit_caps_spawns
test_restore_no_tty_no_yes_exits_2
test_restore_unknown_schema_refused
test_restore_stale_snapshot_refused
test_restore_host_mismatch_refused
test_restore_cap_fails_closed
test_restore_picker_expected_routing
test_restore_wave_pacing
test_restore_already_live_skipped
test_restore_launch_config_replay
test_restore_no_force_structural
test_restore_no_pane_inference_structural
test_restore_already_live_record_join
test_restore_exit_codes

# =====================================================================
# Health check pattern table & health check tests (plan 056)
# =====================================================================

test_health_check_patterns_syntax() {
    # The shared pattern table must be valid bash and define the expected arrays.
    bash -n "$ROOT/lib/health-check-patterns.sh" \
        || fail "health-check-patterns.sh has syntax errors"
    bash -n "$ROOT/lib/health-check.sh" \
        || fail "health-check.sh has syntax errors"
    echo "ok: health check lib files have valid syntax"
}

test_health_check_pattern_matching() {
    # Source the pattern table and verify each pattern matches its intended
    # fixture text and does NOT false-match on seeded prompt text that
    # merely mentions the keywords in prose.
    source "$ROOT/lib/health-check-patterns.sh"
    _hc_patterns_for_agent claude

    # Workspace trust modal (should match)
    local trust_pane
    trust_pane="$(printf '%s\n' \
        '╭──────────────────────────────────────────────────╮' \
        '│ Do you trust the files in this folder?            │' \
        '│ ❯ 1. Yes                                         │' \
        '│   2. No                                          │' \
        '╰──────────────────────────────────────────────────╯')"
    printf '%s\n' "$trust_pane" | grep -E "${HC_PATTERN[0]}" >/dev/null 2>&1 \
        || fail "workspace-trust pattern should match trust modal"

    # Conversation picker (should match)
    local picker_pane
    picker_pane="$(printf '%s\n' \
        'Continue from a previous conversation?' \
        '❯ 1. Start new conversation')"
    printf '%s\n' "$picker_pane" | grep -E "${HC_PATTERN[1]}" >/dev/null 2>&1 \
        || fail "conversation-picker pattern should match picker modal"

    # Seeded prompt text mentioning "trust" should NOT match
    local seeded_pane
    seeded_pane="$(printf '%s\n' \
        'Your task: ensure the files are trustworthy.' \
        'Continue from a previous plan and verify.')"
    ! printf '%s\n' "$seeded_pane" | grep -E "${HC_PATTERN[0]}" >/dev/null 2>&1 \
        || fail "workspace-trust pattern should NOT match seeded prompt prose"

    # Codex patterns
    _hc_patterns_for_agent codex
    local codex_modal
    codex_modal="$(printf '%s\n' \
        'Allow Codex to run: npm test' \
        'tell Codex what to do differently')"
    printf '%s\n' "$codex_modal" | grep -E "${HC_PATTERN[0]}" >/dev/null 2>&1 \
        || fail "codex-approval-modal pattern should match Codex modal"

    local codex_hooks
    codex_hooks="$(printf '%s\n' 'Hooks need review' 'Press t to trust')"
    printf '%s\n' "$codex_hooks" | grep -E "${HC_PATTERN[1]}" >/dev/null 2>&1 \
        || fail "codex-hooks-trust pattern should match hooks modal"

    echo "ok: health check patterns match expected fixtures and reject prose"
}

test_health_check_transition_guard() {
    # The health check must auto-dismiss each pattern at most once. After
    # dismissal, the same pattern should not trigger another send-keys.
    # We test this by sourcing the health check in a controlled env with
    # a fake tmux that logs send-keys calls.
    local hc_bin="$TMPDIR/hcguard-bin"
    mkdir -p "$hc_bin"

    # Fake tmux: capture-pane returns the trust modal for the first 2 calls,
    # then returns a clean pane. Logs send-keys calls.
    local call_count_file="$TMPDIR/hcguard-call-count"
    local sendkeys_log="$TMPDIR/hcguard-sendkeys.log"
    echo "0" > "$call_count_file"
    : > "$sendkeys_log"

    cat > "$hc_bin/tmux" <<FAKESH
#!/usr/bin/env bash
case "\${1:-}" in
    capture-pane)
        count=\$(cat "$call_count_file")
        count=\$((count + 1))
        echo "\$count" > "$call_count_file"
        if [[ \$count -le 2 ]]; then
            printf '%s\n' '❯ 1. Yes' 'Do you trust the files in this folder?'
        else
            printf '%s\n' 'claude> ready to work'
        fi
        exit 0
        ;;
    send-keys)
        echo "SEND-KEYS \$*" >> "$sendkeys_log"
        exit 0
        ;;
    *) exit 0 ;;
esac
FAKESH
    chmod +x "$hc_bin/tmux"

    # Minimal session metadata setup
    local sdir="$TMPDIR/hcguard-sessions"
    mkdir -p "$sdir"
    echo '{"created_at":"2026-01-01T00:00:00Z"}' > "$sdir/test-session.json"

    # Source cctrl functions we need (color vars, metadata helpers, tmux wrapper)
    local fn_file="$TMPDIR/hcguard-fns.sh"
    cat > "$fn_file" <<'FNSSH'
RED="" GREEN="" YELLOW="" BOLD="" DIM="" RESET=""
_session_update_metadata_field() { :; }
_tmux_run_with_timeout() {
    TMUX_RUN_OUTPUT="$(tmux "$@" 2>/dev/null)" || return $?
}
FNSSH
    # shellcheck source=/dev/null
    source "$fn_file"

    # Source the health check
    _HC_SCRIPT_DIR="$ROOT/lib"
    _HC_PATTERNS_LOADED=""
    source "$ROOT/lib/health-check.sh"

    # Run with a short timeout and poll interval
    (
        PATH="$hc_bin:$PATH" CCTRL_HC_POLL_INTERVAL=0 CCTRL_HC_STABLE_THRESHOLD=2 \
            _health_check_run "test-session" "claude" 5
    ) 2>/dev/null

    # Count send-keys calls — should be exactly 1 (transition guard)
    local sk_count
    sk_count="$(grep -c 'SEND-KEYS' "$sendkeys_log" 2>/dev/null || echo 0)"
    [[ "$sk_count" -eq 1 ]] \
        || fail "expected exactly 1 send-keys call (transition guard), got $sk_count"

    echo "ok: transition guard fires auto-dismiss exactly once per pattern"
}

test_health_check_needs_human_path() {
    # When the pane shows a needs-human modal, the health check should detect
    # it immediately and return 0.
    local hc_bin="$TMPDIR/hcneeds-bin"
    mkdir -p "$hc_bin"

    cat > "$hc_bin/tmux" <<'FAKESH'
#!/usr/bin/env bash
case "${1:-}" in
    capture-pane)
        # Show a login-unavailable needs-human modal (no auto-dismiss match)
        printf '%s\n' 'auth is required to proceed' 'please visit the web console'
        exit 0
        ;;
    *) exit 0 ;;
esac
FAKESH
    chmod +x "$hc_bin/tmux"

    export RED="" GREEN="" YELLOW="" BOLD="" DIM="" RESET=""
    _session_update_metadata_field() { :; }
    _tmux_run_with_timeout() {
        TMUX_RUN_OUTPUT="$(tmux "$@" 2>/dev/null)" || return $?
    }
    _HC_SCRIPT_DIR="$ROOT/lib"
    _HC_PATTERNS_LOADED=""
    source "$ROOT/lib/health-check.sh"

    local rc=0
    (
        PATH="$hc_bin:$PATH" CCTRL_HC_POLL_INTERVAL=0 \
            _health_check_run "test-session" "claude" 2
    ) 2>/dev/null || rc=$?

    [[ "$rc" -eq 0 ]] \
        || fail "health check should always return 0, got $rc"

    echo "ok: health check needs-human path returns 0"
}

test_health_check_timeout_path() {
    # When the pane shows unrecognized content (no pattern match), the health
    # check should time out and still return 0.
    local hc_bin="$TMPDIR/hctimeout-bin"
    mkdir -p "$hc_bin"

    local timeout_count_file="$TMPDIR/hctimeout-count"
    echo "0" > "$timeout_count_file"
    cat > "$hc_bin/tmux" <<FAKESH
#!/usr/bin/env bash
case "\${1:-}" in
    capture-pane)
        # Always show unrecognized content — never matches any pattern
        printf '%s\n' 'Loading...' 'Please wait...'
        count=\$(cat "$timeout_count_file")
        echo "\$((count + 1))" > "$timeout_count_file"
        exit 0
        ;;
    *) exit 0 ;;
esac
FAKESH
    chmod +x "$hc_bin/tmux"

    export RED="" GREEN="" YELLOW="" BOLD="" DIM="" RESET=""
    _session_update_metadata_field() { :; }
    _tmux_run_with_timeout() {
        TMUX_RUN_OUTPUT="$(tmux "$@" 2>/dev/null)" || return $?
    }
    _HC_SCRIPT_DIR="$ROOT/lib"
    _HC_PATTERNS_LOADED=""
    source "$ROOT/lib/health-check.sh"

    local rc=0
    (
        PATH="$hc_bin:$PATH" CCTRL_HC_POLL_INTERVAL=0 \
            _health_check_run "test-session" "claude" 3
    ) 2>/dev/null || rc=$?

    [[ "$rc" -eq 0 ]] \
        || fail "health check should always return 0 on timeout, got $rc"

    echo "ok: health check timeout path returns 0"
}

test_health_check_bypass_flag() {
    # --no-health-check must be parsed by _launch_detached and skip the check.
    # We verify by checking that the flag is accepted in the arg parser.
    local fn_file="$TMPDIR/hcbypass-fn.sh"
    awk '/^_launch_detached\(\) \{/,/^}/' "$ROOT/cctrl" > "$fn_file"
    grep -q 'no_health_check=true' "$fn_file" \
        || fail "expected --no-health-check to set no_health_check=true in _launch_detached"
    grep -q 'health_check_timeout=' "$fn_file" \
        || fail "expected --health-check-timeout to be parsed in _launch_detached"
    echo "ok: --no-health-check and --health-check-timeout flags are parsed"
}

test_session_pane_has_dialog_refactored() {
    # Regression test: _session_pane_has_dialog must still detect the same
    # modals after refactoring to the shared pattern table.
    local fn_file="$TMPDIR/hcdialog-fn.sh"

    # Extract the function + the pattern table source
    cat > "$fn_file" <<FNSH
#!/usr/bin/env bash
SCRIPT_DIR="$ROOT"
_HC_SCRIPT_DIR="$ROOT/lib"
source "$ROOT/lib/health-check-patterns.sh"
$(awk '/^_session_pane_has_dialog\(\) \{/,/^}/' "$ROOT/cctrl")
FNSH

    # shellcheck source=/dev/null
    source "$fn_file"

    # Claude trust modal (should match)
    local trust_pane
    trust_pane="$(printf '%s\n' 'Do you trust the files' '❯ 1. Yes')"
    _session_pane_has_dialog "$trust_pane" \
        || fail "refactored dialog detector should match workspace trust modal"

    # Codex approval modal (should match)
    local codex_pane
    codex_pane="$(printf '%s\n' 'Allow Codex to run' 'tell Codex what to do differently')"
    _session_pane_has_dialog "$codex_pane" \
        || fail "refactored dialog detector should match Codex approval modal"

    # Codex hooks modal (should match)
    local hooks_pane
    hooks_pane="$(printf '%s\n' 'Hooks need review' 'Press t to trust')"
    _session_pane_has_dialog "$hooks_pane" \
        || fail "refactored dialog detector should match Codex hooks modal"

    # Benign text (should NOT match)
    local benign_pane
    benign_pane="$(printf '%s\n' 'Here is the plan:' '  1. First step' '  2. Second step')"
    ! _session_pane_has_dialog "$benign_pane" \
        || fail "refactored dialog detector should NOT match benign text"

    # Proceed prompt (should match — added in refactor)
    local proceed_pane
    proceed_pane="$(printf '%s\n' 'Do you want to proceed?' '❯ 1. Yes')"
    _session_pane_has_dialog "$proceed_pane" \
        || fail "refactored dialog detector should match proceed prompt"

    echo "ok: _session_pane_has_dialog regression tests pass after shared-pattern refactor"
}

test_codex_lifecycle_fixture_contract() {
    python3 "$ROOT/tests/fixtures/codex-lifecycle/validate.py" \
        || fail "Codex lifecycle fixture contract validation failed"
}

test_health_check_patterns_syntax
test_health_check_pattern_matching
test_health_check_transition_guard
test_health_check_needs_human_path
test_health_check_timeout_path
test_health_check_bypass_flag
test_session_pane_has_dialog_refactored
test_codex_lifecycle_fixture_contract

echo "ok"
