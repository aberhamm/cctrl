#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
export CCTRL_SESSION_METADATA_DIR="$TMPDIR/session-metadata"
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
unset CCTRL_SESSION_KIND CCTRL_SESSION_NAME CCTRL_SESSION_TARGET CCTRL_SESSION_PURPOSE

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
        exit 0
        ;;
    paste-buffer)
        if [[ "${TMUX_FAKE_PASTE_FAIL:-}" == "1" ]]; then
            echo "paste failed" >&2
            exit 1
        fi
        exit 0
        ;;
    send-keys|delete-buffer)
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
    python3 -m py_compile "$ROOT/lib/usage_costs.py" "$ROOT/lib/peer_mcp.py" "$ROOT/hooks/session-log.py" "$ROOT/hooks/block-git-commit.py"
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

    command -v script >/dev/null 2>&1 || return 0
    script -q /dev/null true >/dev/null 2>&1 || return 0

    local out_file="$TMPDIR/agent-prompt-output.log"
    printf '2\n' | env PATH="$TMPDIR:$PATH" \
        script -q /dev/null "$rootcopy/cctrl" start --foreground -m "prompted agent" \
        > "$out_file" 2>&1

    out="$(cat "$out_file")"
    assert_contains "$out" "Choose agent runtime:"
    assert_contains "$out" "1) claude"
    assert_contains "$out" "2) codex"
    assert_contains "$out" "CMD=codex"
    assert_contains "$out" "ARG[0]=--yolo"
    assert_contains "$out" "ARG[1]=prompted agent"
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

    command -v script >/dev/null 2>&1 || return 0
    script -q /dev/null true >/dev/null 2>&1 || return 0

    local out_file="$TMPDIR/profile-agent-prompt-output.log"
    printf '1\n' | env PATH="$TMPDIR:$PATH" \
        script -q /dev/null "$rootcopy/cctrl" start --foreground --no-bridge -m "profile picked claude" \
        > "$out_file" 2>&1

    out="$(cat "$out_file")"
    assert_contains "$out" "Choose agent runtime:"
    assert_contains "$out" "CMD=claude"
    assert_contains "$out" "ARG[0]=--permission-mode"
    assert_contains "$out" "ARG[2]=--chrome"
    assert_contains "$out" "ARG[3]=profile picked claude"
}

test_detached_agent_prompt_exports_selection() {
    command -v script >/dev/null 2>&1 || return 0
    script -q /dev/null true >/dev/null 2>&1 || return 0

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
    printf '2\n' | env PATH="$TMPDIR:$PATH" TMUX_LOG="$log" \
        CCTRL_PURPOSE_PROMPT=never CCTRL_ATTACH_PROMPT=never CCTRL_EMIT_SESSION=1 \
        script -q /dev/null "$rootcopy/cctrl" start -d "$project" \
        > "$out_file" 2>&1

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
    assert_contains "$(cat "$CCTRL_SESSION_METADATA_DIR/TMUX--project.json")" '"purpose": "line one"'
    assert_contains "$(cat "$CCTRL_SESSION_METADATA_DIR/TMUX--project.json")" '"initial_prompt": "line one"'

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_AGENT=codex CCTRL_EMIT_SESSION=1 "$ROOT/cctrl" start -d "$project" -- "literal prompt words")"
    assert_contains "$out" "detached session started"
    assert_contains "$(cat "$log")" "-- literal\\ prompt\\ words"
    assert_contains "$(cat "$log")" "start --foreground"
    assert_contains "$(cat "$CCTRL_SESSION_METADATA_DIR/TMUX--project.json")" '"purpose": "literal prompt words"'

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_AGENT=codex CCTRL_EMIT_SESSION=1 "$ROOT/cctrl" start -d --purpose "cleanup context" "$project")"
    assert_contains "$out" "detached session started"
    assert_contains "$(cat "$log")" "start --foreground"
    assert_not_contains "$(cat "$log")" "--purpose"
    assert_contains "$(cat "$CCTRL_SESSION_METADATA_DIR/TMUX--project.json")" '"purpose": "cleanup context"'

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
    assert_contains "$(cat "$CCTRL_SESSION_METADATA_DIR/TMUX--reuseproj--2.json")" '"purpose": "fresh"'

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
    assert_contains "$(cat "$CCTRL_SESSION_METADATA_DIR/TMUX--profile-detached-project.json")" '"peer": "comet"'

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 CCTRL_DATA_DIR="$data" "$ROOT/cctrl" start -d --peer comet --agent codex "$project")"
    assert_contains "$out" "detached session started"
    assert_contains "$(cat "$log")" "CCTRL_PEER=comet"
    assert_contains "$(cat "$log")" "CCTRL_DATA_DIR=$data"
    assert_contains "$(cat "$log")" "CCTRL_SESSION_METADATA_DIR=$CCTRL_SESSION_METADATA_DIR"
    assert_contains "$(cat "$log")" "--peer\\ comet"
    assert_contains "$(cat "$CCTRL_SESSION_METADATA_DIR/TMUX--start-peer-project.json")" '"peer": "comet"'

    local ordered_project="$TMPDIR/start-peer-ordered-project"
    mkdir -p "$ordered_project"
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 CCTRL_DATA_DIR="$data" "$ROOT/cctrl" start --peer comet --agent codex "$ordered_project")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--start-peer-ordered-project"
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--start-peer-ordered-project"
    assert_contains "$(cat "$log")" "SHELL_CMD=cd $ordered_project &&"
    assert_contains "$(cat "$log")" "--peer\\ comet"
    assert_contains "$(cat "$CCTRL_SESSION_METADATA_DIR/TMUX--start-peer-ordered-project.json")" '"target": "'"$ordered_project"'"'

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
    assert_contains "$(cat "$CCTRL_SESSION_METADATA_DIR/TMUX--start-peer-new-project.json")" '"peer": "rover"'

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
    assert_contains "$(cat "$CCTRL_SESSION_METADATA_DIR/TMUX--peerproj.json")" '"peer": "comet"'

    cat > "$profile_meta/TMUX--shortcut-live.json" <<'JSON'
{"purpose":"shortcut live peer","created_at":"2026-06-11T10:00:00Z","peer":"comet","cctrl_managed":true}
JSON
    local rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_FAKE_SESSIONS="TMUX--shortcut-live" "$rootcopy/cctrl" @peerlive --foreground --peer c 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected shortcut foreground profile metadata --peer duplicate to fail"
    assert_contains "$out" "already has a live tmux session"
}

test_purpose_prompt_uses_controlling_tty() {
    command -v script >/dev/null 2>&1 || return 0
    script -q /dev/null true >/dev/null 2>&1 || return 0

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
    printf '\n' | env PATH="$TMPDIR:$PATH" TMUX_LOG="$log" \
        CCTRL_ATTACH_PROMPT=never script -q /dev/null "$rootcopy/cctrl" @cctrl \
        > "$out_file" 2>&1

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
    printf '%s\n' "$out" | jq -s -e '
      length == 2
      and .[0].id == 1
      and .[1].id == 2
      and ([.[1].result.tools[].name] | sort) == (["ack_message","check_messages","list_peers","recv_message","resolve_peer","send_message","show_message","whoami"] | sort)
    ' >/dev/null || fail "expected MCP tools/list to advertise peer messaging tools"

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
        '│ Allow Codex to run `npm test`?                   │' \
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
    assert_contains "$(cat "$log")" "BUFFER inline body"
    assert_contains "$(cat "$log")" "paste-buffer -b cctrl-inline-comet-"
    assert_not_contains "$(cat "$log")" "send-keys -t TMUX--comet Enter"
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

    local out modal_pane benign_pane
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

    # (a) A real Claude modal ("❯ 1. Yes") must still DEFER.
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send cq --from orchestrator --json -- "hold for modal" >/dev/null
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--cq" TMUX_FAKE_CAPTURE_PANE="$modal_pane" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver cq --json)"
    printf '%s\n' "$out" | jq -e '.results[0].status == "deferred" and .results[0].reason == "modal prompt visible"' >/dev/null || fail "expected real Claude modal (❯ 1.) to defer"
    assert_not_contains "$(cat "$log")" "paste-buffer"

    # (b) A markdown numbered list plus benign "Do you want ... proceed" prose,
    # with no "❯ 1." selection line, must NOT defer — it should nudge normally.
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--cq" TMUX_FAKE_CAPTURE_PANE="$benign_pane" CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-13T00:00:05Z" "$ROOT/cctrl" peer deliver cq --json)"
    printf '%s\n' "$out" | jq -e '.results[0].status == "nudged" and .results[0].submitted == true' >/dev/null || fail "expected markdown list + prose (no ❯ 1.) to nudge, not defer"
    assert_contains "$(cat "$log")" "paste-buffer -b cctrl-nudge-cq-"
    assert_contains "$(cat "$log")" "send-keys -t TMUX--cq Enter"

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

    local out modal_pane benign_pane
    modal_pane="$(printf '%s\n' \
        '● Applying the proposed patch next.' \
        '' \
        '╭──────────────────────────────────────────────────╮' \
        '│ Allow Codex to apply proposed code changes?      │' \
        '│                                                  │' \
        '│ > Yes, proceed                                   │' \
        '│   No, and tell Codex what to do differently      │' \
        '╰──────────────────────────────────────────────────╯')"
    # Benign output the OLD regex would have wrongly deferred on: prose with
    # "Approve", a shell "[y/N]" prompt, and a markdown numbered list — but no
    # real Codex approval-modal marker.
    benign_pane="$(printf '%s\n' \
        '● Next steps for the PR:' \
        '  1. Approve the upstream change' \
        '  2. Rerun CI' \
        '' \
        'I ran `git clean -n` (the tool would normally ask y/N before deleting).')"

    # (a) A real Codex approval modal must DEFER.
    CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --json -- "hold for codex modal" >/dev/null
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" TMUX_FAKE_CAPTURE_PANE="$modal_pane" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver comet --json)"
    printf '%s\n' "$out" | jq -e '.results[0].status == "deferred" and .results[0].reason == "modal prompt visible"' >/dev/null || fail "expected real Codex approval modal to defer"
    assert_not_contains "$(cat "$log")" "paste-buffer"

    # (b) Benign output with "Approve"/"y/N"/numbered list but no Codex modal
    # marker must NOT defer — it should nudge normally.
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" TMUX_FAKE_CAPTURE_PANE="$benign_pane" CCTRL_DATA_DIR="$data" CCTRL_NOW_UTC="2026-06-13T00:00:06Z" "$ROOT/cctrl" peer deliver comet --json)"
    printf '%s\n' "$out" | jq -e '.results[0].status == "nudged" and .results[0].submitted == true' >/dev/null || fail "expected benign Approve/y/N prose (no Codex modal) to nudge, not defer"
    assert_contains "$(cat "$log")" "paste-buffer -b cctrl-nudge-comet-"
    assert_contains "$(cat "$log")" "send-keys -t TMUX--comet Enter"

    echo "ok: codex modal-detector anchors on real Codex modal text (no false-positive deferral)"
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

test_session_close_named_immediate() {
    make_fake_tmux "$TMPDIR/tmux"
    local log="$TMPDIR/close-named.log"
    : > "$log"

    # Outside tmux with an explicit name: immediate kill.
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX= TMUX_FAKE_HAS_SESSION=1 \
        "$ROOT/cctrl" close TMUX--demo)"
    assert_contains "$out" "Closed session: TMUX--demo"
    assert_contains "$(cat "$log")" "kill-session -t TMUX--demo"
    assert_not_contains "$(cat "$log")" "run-shell"
}

test_session_close_outside_requires_name() {
    make_fake_tmux "$TMPDIR/tmux"
    local out rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX= "$ROOT/cctrl" session close 2>&1)" || rc=$?
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

test_usage_cost_fixtures() {
    local base="$TMPDIR/fixtures"
    local claude_dir="$base/claude/projects/-Users-matthew--projects-demo"
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
{"timestamp":"$codex_meta_ts","type":"session_meta","payload":{"id":"codex-session","cwd":"/Users/matthew/_projects/demo"}}
{"timestamp":"$codex_context_ts","type":"turn_context","payload":{"cwd":"/Users/matthew/_projects/demo","model":"gpt-5.5"}}
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

test_syntax
test_launch_args
test_agent_prompt_without_default
test_profile_prompt_overrides_global_default
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
test_session_doctor_classifies_bridge
test_session_doctor_detects_collision
test_session_doctor_realign_reports_hint
test_session_doctor_realign_fix_emits_relaunch
test_session_doctor_realign_skips_busy
test_session_doctor_realign_idempotent
test_session_doctor_realign_real_relaunch
test_session_autoheal_dry_run_selects_dead_and_no_repair
test_session_autoheal_skips_unsent_draft
test_session_autoheal_skips_busy
test_session_autoheal_skips_copy_mode
test_session_autoheal_heals_clean_dead_bridge
test_session_autoheal_ignores_live_bridge
test_session_autoheal_install_uninstall_plist
test_session_list_codex_default_model
test_session_list_last_active_from_updated_at
test_session_list_last_active_from_transcript_mtime
test_session_list_unresolvable_session
test_session_list_sorts_by_last_active
test_session_list_base_state
test_session_list_recap
test_session_list_rich_state
test_needs_me_digest
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
test_peer_mailbox_ack_authorization_and_states
test_peer_mailbox_unknowns_and_identity
test_peer_mailbox_concurrency_and_stale_lock
test_peer_polling_json_contracts
test_peer_polling_identity_and_errors
test_peer_mcp_bridge_stdio
test_peer_deliver_tmux_nudge_lifecycle
test_peer_deliver_busy_no_submit_and_inline
test_peer_deliver_claude_modal_detection
test_peer_deliver_codex_modal_detection
test_peer_deliver_failures_all_and_concurrency
test_peer_orchestrator_status_nudge_watch
test_peer_gc_retention_and_doctor
test_peer_doorbell_hook
test_session_close_self_graceful
test_session_close_stale_tmux_refuses_current
test_session_current_identity_json
test_session_close_named_immediate
test_session_close_outside_requires_name
test_session_prune_never_prompted_claude
test_session_prune_fresh_active_not_candidate
test_session_prune_codex_no_claude_transcript_bug_guard
test_session_prune_codex_never_prompted
test_session_prune_dry_run_closes_nothing
test_session_prune_excludes_self_and_attached
test_usage_cost_fixtures

echo "ok"
