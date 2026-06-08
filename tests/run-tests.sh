#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local haystack="$1" needle="$2"
    [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
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
    has-session) exit 1 ;;
    list-sessions)
        printf 'demo\n'
        exit 0
        ;;
    list-panes)
        if [[ "$*" == *pane_current_path* ]]; then
            printf '/tmp/demo\n'
        else
            printf '12345\n'
        fi
        exit 0
        ;;
    display-message)
        printf '0\n'
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

test_syntax() {
    bash -n "$ROOT/cctrl" "$ROOT/completions/_cctrl" "$ROOT/hooks/notify.sh" "$ROOT/hooks/statusline.sh" "$ROOT/install.sh"
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

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 "$ROOT/cctrl" start -d "$project" -- "literal prompt words")"
    assert_contains "$out" "detached session started"
    assert_contains "$(cat "$log")" "-- literal\\ prompt\\ words"
    assert_contains "$(cat "$log")" "start --foreground"

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

    local out
    out="$(PATH="$TMPDIR:$PATH" "$ROOT/cctrl" session ls --json)"
    assert_contains "$out" '"name": "demo"'
    assert_contains "$out" '"agent": "codex"'
    assert_contains "$out" '"model": "?"'
}

test_usage_cost_fixtures() {
    local base="$TMPDIR/fixtures"
    local claude_dir="$base/claude/projects/-Users-matthew--projects-demo"
    local codex_dir="$base/codex/sessions/2026/06/07"
    local archive_dir="$base/codex/archived_sessions"
    mkdir -p "$claude_dir" "$codex_dir" "$archive_dir"

    cat > "$claude_dir/claude-session.jsonl" <<'JSONL'
{"timestamp":"2026-06-06T10:00:00Z","sessionId":"claude-session","type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":200,"cache_creation_input_tokens":300,"cache_read_input_tokens":400}}}
{"timestamp":"2026-06-06T10:00:01Z","type":"user","message":{"role":"user","content":"ok"}}
JSONL

    cat > "$codex_dir/codex-session.jsonl" <<'JSONL'
{"timestamp":"2026-06-06T11:00:00Z","type":"session_meta","payload":{"id":"codex-session","cwd":"/Users/matthew/_projects/demo"}}
{"timestamp":"2026-06-06T11:00:01Z","type":"turn_context","payload":{"cwd":"/Users/matthew/_projects/demo","model":"gpt-5.5"}}
{"timestamp":"2026-06-06T11:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":250,"output_tokens":100,"reasoning_output_tokens":10},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":250,"output_tokens":100,"reasoning_output_tokens":10}},"rate_limits":{"plan_type":"plus","primary":{"used_percent":12,"resets_at":"2026-06-06T16:00:00Z"},"secondary":{"used_percent":34,"resets_at":"2026-06-11T04:00:00Z"}}}}
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
test_context_names
test_session_list_codex_default_model
test_usage_cost_fixtures

echo "ok"
