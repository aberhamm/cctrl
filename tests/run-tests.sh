#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
export CCTRL_SESSION_METADATA_DIR="$TMPDIR/session-metadata"
trap 'rm -rf "$TMPDIR"' EXIT

# Tests may be run from inside a cctrl tmux session; don't let its context
# leak in (CCTRL_TMUX_CONTEXT flips `cctrl start` into foreground mode).
unset CCTRL_TMUX_CONTEXT TMUX TMUX_PANE CCTRL_AGENT CCTRL_HOST_PREFIX CCTRL_PEER
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
        printf 'demo\n'
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
    bash -n "$ROOT/hooks/statusline.sh"
    bash -n "$ROOT/install.sh"
    zsh -n "$ROOT/completions/_cctrl"
    python3 -m py_compile "$ROOT/lib/usage_costs.py" "$ROOT/hooks/session-log.py" "$ROOT/hooks/block-git-commit.py"
}

test_launch_args() {
    make_fake_agent "$TMPDIR/codex" codex
    make_fake_agent "$TMPDIR/claude" claude

    local out
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
    assert_contains "$out" "ARG[4]=fix bug"

    out="$(PATH="$TMPDIR:$PATH" "$ROOT/cctrl" start --foreground -m "default agent")"
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

test_detached_arg_parsing() {
    make_fake_tmux "$TMPDIR/tmux"
    local project="$TMPDIR/project"
    local log="$TMPDIR/tmux.log"
    mkdir -p "$project"

    : > "$log"
    local out
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
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 "$ROOT/cctrl" start -d "$project" -- "literal prompt words")"
    assert_contains "$out" "detached session started"
    assert_contains "$(cat "$log")" "-- literal\\ prompt\\ words"
    assert_contains "$(cat "$log")" "start --foreground"
    assert_contains "$(cat "$CCTRL_SESSION_METADATA_DIR/TMUX--project.json")" '"purpose": "literal prompt words"'

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 "$ROOT/cctrl" start -d --purpose "cleanup context" "$project")"
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
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 \
        TMUX_FAKE_HAS_SESSION="TMUX--project" "$ROOT/cctrl" start -d "$project")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--project--2"
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--project--2"
    assert_contains "$(cat "$log")" "CCTRL_SESSION_NAME=TMUX--project--2"
    assert_contains "$(cat "$log")" "--name TMUX--project--2"
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
}

test_shortcut_no_args_defaults_to_tmux() {
    make_fake_tmux "$TMPDIR/tmux"
    local rootcopy="$TMPDIR/cctrl-shortcut-copy"
    local project="$TMPDIR/mstack"
    local log="$TMPDIR/shortcut-tmux.log"
    mkdir -p "$rootcopy/data" "$project"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    printf '{"mstack":{"dir":"%s","agent":"codex"}}\n' "$project" > "$rootcopy/data/shortcuts.json"
    printf '{"defaultAgent":"codex"}\n' > "$rootcopy/data/config.json"

    : > "$log"
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 "$rootcopy/cctrl" @mstack)"
    assert_contains "$out" "detached session started"
    assert_contains "$out" "CCTRL_SESSION=TMUX--mstack"
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--mstack"
    assert_contains "$(cat "$log")" "@mstack --foreground --name TMUX--mstack"
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
}

test_attach_prompt_after_start() {
    make_fake_tmux "$TMPDIR/tmux"
    local project="$TMPDIR/prompt-project"
    local log="$TMPDIR/prompt-tmux.log"
    mkdir -p "$project"

    : > "$log"
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_ATTACH_PROMPT=always "$ROOT/cctrl" start -d "$project" <<< "")"
    assert_contains "$out" "Connect to session TMUX--prompt-project now? [y/N]"
    assert_contains "$out" "Not connected. Attach later: cctrl session attach TMUX--prompt-project"
    assert_not_contains "$(cat "$log")" "attach-session"

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_ATTACH_PROMPT=always "$ROOT/cctrl" start -d "$project" <<< "y")"
    assert_contains "$out" "Connect to session TMUX--prompt-project now? [y/N]"
    assert_contains "$(cat "$log")" "attach-session -t TMUX--prompt-project"

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_ATTACH_PROMPT=always "$ROOT/cctrl" start "$project" <<< "")"
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

    local out id inbox outbox shown
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
    assert_contains "$out" "No sender identity"

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

test_syntax
test_launch_args
test_detached_arg_parsing
test_start_defaults_to_tmux
test_shortcut_no_args_defaults_to_tmux
test_purpose_prompt_uses_controlling_tty
test_remote_shortcut_injects_purpose
test_attach_prompt_after_start
test_codex_statusline_tui_config
test_context_names
test_session_list_codex_default_model
test_peer_registry_manual_alias_and_identity
test_peer_derived_tmux_and_shadowing
test_peer_validation_and_errors
test_peer_alias_derived_requires_manual_registration
test_peer_tmux_missing_still_resolves_manual
test_peer_mailbox_send_list_show
test_peer_mailbox_ack_authorization_and_states
test_peer_mailbox_unknowns_and_identity
test_peer_mailbox_concurrency_and_stale_lock
test_session_close_self_graceful
test_session_close_stale_tmux_refuses_current
test_session_current_identity_json
test_session_close_named_immediate
test_session_close_outside_requires_name
test_usage_cost_fixtures

echo "ok"
