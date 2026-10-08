#!/usr/bin/env bash
set -euo pipefail

# Health-check tests match a literal "❯" prompt glyph, which never compares
# equal under a non-UTF-8 locale. Pin this so the suite doesn't depend on
# whatever LANG/LC_ALL the caller's shell happens to have (p5 incident
# follow-up: a bare `LANG=`/`LC_ALL=` environment failed here).
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# >>> test runner (plan 105 P3): per-test timing, filter, --list. Keep this
# block self-contained: test_runner_filter_and_list extracts it between the
# markers and runs it against a fixture file.
_RT_LIST=0
_RT_FILTER=0
_RT_WANT=""
_RT_ROWS=""
_RT_FAILED=""
_RT_CURRENT=""
_RT_CURRENT_T0=0
_RT_COUNT=0
_RT_NOW=0
_RT_FMT=""
_RT_SELF=""
_RT_START_MS=0
_RT_REG_COUNT=0
# Milliseconds since the epoch into _RT_NOW. bash 5 has EPOCHREALTIME; bash
# 3.2 does not, so it falls back to whole seconds from date (no perl/python).
_rt_now() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        local _rt_t="${EPOCHREALTIME/[.,]/}"
        _RT_NOW=$(( _rt_t / 1000 ))
    else
        _RT_NOW=$(( $(date +%s) * 1000 ))
    fi
}
_rt_fmt() { # milliseconds -> _RT_FMT "S.mmm"
    printf -v _RT_FMT '%d.%03d' $(( $1 / 1000 )) $(( $1 % 1000 ))
}
_runner_parse() { # "$@" of the harness; sets _RT_LIST/_RT_FILTER/_RT_WANT
    local _rt_a
    for _rt_a in "$@"; do
        case "$_rt_a" in
            --list) _RT_LIST=1 ;;
            -*) echo "usage: run-tests.sh [--list] [test_name ...]  (unknown option: $_rt_a)" >&2; exit 64 ;;
            "") echo "run-tests.sh: empty test name" >&2; exit 64 ;;
            *) _RT_WANT="$_RT_WANT $_rt_a"; _RT_FILTER=1 ;;
        esac
    done
    if [[ -n "${CCTRL_TEST_NAMES:-}" ]]; then
        _RT_WANT="$_RT_WANT $CCTRL_TEST_NAMES"
        _RT_FILTER=1
    fi
    if [[ "$_RT_FILTER" -eq 1 ]]; then
        # Normalise any whitespace (newlines, tabs) to single spaces, and
        # refuse a filter that names nothing: it would "pass" on zero tests.
        set -- $_RT_WANT
        if [[ "$#" -eq 0 ]]; then
            echo "run-tests.sh: test filter is empty" >&2
            exit 64
        fi
        _RT_WANT=" $*"
    fi
    _rt_now
    _RT_START_MS=$_RT_NOW
    if [[ "$_RT_LIST" -eq 1 && "$_RT_FILTER" -eq 1 ]]; then
        echo "run-tests.sh: --list takes no test names" >&2
        exit 64
    fi
    if [[ -n "${CCTRL_TEST_ONLY:-}" && ( "$_RT_FILTER" -eq 1 || "$_RT_LIST" -eq 1 ) ]]; then
        echo "run-tests.sh: CCTRL_TEST_ONLY (a group) cannot be combined with test names or --list" >&2
        exit 64
    fi
    if [[ "$_RT_FILTER" -eq 1 ]]; then
        # The registry is whatever --list prints (run order); ask the same
        # script so the answer can never drift from the call lists.
        local _rt_reg _rt_w _rt_near _rt_bad=0
        _rt_reg="$(CCTRL_TEST_NAMES='' "$BASH" "$_RT_SELF" --list)" \
            || { echo "run-tests.sh: could not read the test registry (--list failed)" >&2; exit 64; }
        _RT_REG_COUNT="$(printf '%s\n' "$_rt_reg" | grep -c .)"
        for _rt_w in $_RT_WANT; do
            if ! printf '%s\n' "$_rt_reg" | grep -Fxq -- "$_rt_w"; then
                _rt_near="$(printf '%s\n' "$_rt_reg" | grep -iF -- "$_rt_w" | head -5 | tr '\n' ' ' || true)"
                echo "run-tests.sh: unknown test name (not in the full-run list): $_rt_w${_rt_near:+  (near: $_rt_near)}" >&2
                _rt_bad=1
            fi
        done
        [[ "$_rt_bad" -eq 0 ]] || exit 64
    fi
}
# One result line per test on stderr (stdout stays exactly what the test body
# prints): `ok: <name> (S.mmms)`, or `FAIL: <name> (rc=N, S.mmms)`.
# The test runs as a plain statement, never in an ||, &&, if or ! context, so
# `set -e` stays live inside it. Default is fail-fast: the first failing test
# exits the harness through its EXIT trap (which calls _rt_fail_report).
# CCTRL_TEST_KEEP_GOING=1 records the failure and continues.
_run_test() { # [--always] <name>
    local _rt_always=0
    if [[ "${1:-}" == "--always" ]]; then _rt_always=1; shift; fi
    local _rt_name="$1" _rt_t0 _rt_rc=0 _rt_ms _rt_status=ok
    if [[ "$_RT_LIST" -eq 1 ]]; then
        printf '%s\n' "$_rt_name"
        return 0
    fi
    if [[ "$_RT_FILTER" -eq 1 && "$_rt_always" -eq 0 ]]; then
        case " $_RT_WANT " in *" $_rt_name "*) ;; *) return 0 ;; esac
    fi
    _rt_now
    _rt_t0=$_RT_NOW
    _RT_CURRENT="$_rt_name"
    _RT_CURRENT_T0=$_rt_t0
    # Each test runs in its own subshell (plan 105 P4): exports, cd, traps and
    # function redefinitions no longer leak into the next test. The subshell
    # is a plain statement, never in an ||, &&, if or ! context, so `set -e`
    # stays live inside the test. Fail-fast is the default: the first failing
    # test exits the harness with the test's own status; the EXIT trap then
    # names it through _rt_fail_report.
    set +e
    ( set -e; "$_rt_name" )
    _rt_rc=$?
    set -e
    if [[ "$_rt_rc" -ne 0 && "${CCTRL_TEST_KEEP_GOING:-0}" != "1" ]]; then
        exit "$_rt_rc"
    fi
    _rt_now
    _rt_ms=$(( _RT_NOW - _rt_t0 ))
    _RT_CURRENT=""
    _RT_COUNT=$(( _RT_COUNT + 1 ))
    _rt_fmt "$_rt_ms"
    if [[ "$_rt_rc" -ne 0 ]]; then
        _rt_status=FAIL
        _RT_FAILED="$_RT_FAILED $_rt_name"
        echo "FAIL: $_rt_name (rc=$_rt_rc, ${_RT_FMT}s)" >&2
    else
        echo "ok: $_rt_name (${_RT_FMT}s)" >&2
    fi
    _RT_ROWS="${_RT_ROWS}${_rt_name}"$'\t'"${_rt_ms}"$'\t'"${_rt_status}"$'\n'
}
# Called from the harness EXIT trap: names the test that was running when the
# harness died (fail-fast), because the test's own `fail` message does not.
_rt_fail_report() { # rc
    if [[ "${1:-0}" -ne 0 && -n "$_RT_CURRENT" ]]; then
        _rt_now
        _rt_fmt $(( _RT_NOW - _RT_CURRENT_T0 ))
        echo "FAIL: $_RT_CURRENT (rc=$1, ${_RT_FMT}s)" >&2
    fi
}
# Slowest-20 table + totals on stderr; full TSV (name, seconds, status) when
# CCTRL_TEST_TIMINGS=<file>. Returns 1 if a keep-going run saw failures.
_runner_report() {
    local _rt_total _rt_name _rt_ms _rt_status
    _rt_now
    _rt_total=$(( _RT_NOW - _RT_START_MS ))
    if [[ -n "${CCTRL_TEST_TIMINGS:-}" ]]; then
        : > "$CCTRL_TEST_TIMINGS"
        while IFS=$'\t' read -r _rt_name _rt_ms _rt_status; do
            [[ -n "$_rt_name" ]] || continue
            _rt_fmt "$_rt_ms"
            printf '%s\t%s\t%s\n' "$_rt_name" "$_RT_FMT" "$_rt_status" >> "$CCTRL_TEST_TIMINGS"
        done <<< "$_RT_ROWS"
    fi
    _rt_fmt "$_rt_total"
    {
        echo "== $_RT_COUNT tests, ${_RT_FMT}s wall; slowest 20 =="
        [[ "$_RT_FILTER" -eq 0 ]] || echo "== FILTERED RUN: $_RT_COUNT of $_RT_REG_COUNT registered tests (not a full run) =="
        while IFS=$'\t' read -r _rt_name _rt_ms _rt_status; do
            [[ -n "$_rt_name" ]] || continue
            _rt_fmt "$_rt_ms"
            printf '%9ss  %s\n' "$_RT_FMT" "$_rt_name"
        done < <(printf '%s' "$_RT_ROWS" | sort -t$'\t' -k2,2nr | head -20)
    } >&2
    if [[ "$_RT_FILTER" -eq 1 && "$_RT_COUNT" -eq 0 ]]; then
        echo "FAIL: the filter selected no tests" >&2
        return 1
    fi
    if [[ -n "$_RT_FAILED" ]]; then
        echo "FAIL: keep-going run, failed tests:$_RT_FAILED" >&2
        return 1
    fi
    return 0
}
# After the last _run_test of the full list: --list stops here; a filtered
# run reports and stops here (Python unittests are not part of a filtered run).
_runner_finish() {
    if [[ "$_RT_LIST" -eq 1 ]]; then exit 0; fi
    if [[ "$_RT_FILTER" -eq 1 ]]; then
        _runner_report || exit 1
        exit 0
    fi
}
# <<< test runner
_RT_SELF="$ROOT/tests/run-tests.sh"
_runner_parse "$@"
_RT_BANNER_FD=1
[[ "$_RT_LIST" -eq 0 ]] || _RT_BANNER_FD=2
TMPDIR="$(mktemp -d)"
CCTRL_TEST_REAL_HOME="${HOME:?HOME must be set}"
# Never let a bare `tmux` reach the developer's real default server. Run from
# inside a tmux pane (or with TMUX unset), an untargeted tmux command resolves
# to that server's "current" session -- `cctrl restart` once SIGTERMed the
# agent of the session running this suite that way (plan 071 p5 incident).
# Every tmux call below therefore sees a private, initially empty socket dir;
# the guard test test_tmux_default_server_is_private proves it. mktemp under
# /tmp, not $TMPDIR: macOS $TMPDIR is long enough that a -L socket path
# beneath it would overflow sun_path (104 bytes).
unset TMUX TMUX_PANE
# This suite runs FROM a cctrl-managed session as often as not (every
# worker session is one) -- that session's own launch already exported its
# profile identity (plan 071 phases 4-6) into this very shell, and a test
# that spawns a bare subprocess (not through a rootcopy or an explicit env
# prefix) would otherwise inherit it verbatim, making e.g.
# test_profile_settings_none_profile_no_file see a stale real
# CCTRL_PROFILE_SETTINGS_FILE instead of the fresh, unset value its fixture
# expects. Individual tests still `export` these deliberately for their own
# fixtures; this only clears what this shell brought in from outside the run.
unset CCTRL_AGENT CCTRL_PEER CCTRL_TMUX_CONTEXT CCTRL_RESTART_MARKER \
    CCTRL_PROFILE_SETTINGS_FILE CCTRL_SESSION_KIND CCTRL_SESSION_NAME \
    CCTRL_SESSION_TARGET CCTRL_SESSION_PURPOSE CCTRL_SESSION_LAUNCH_ID \
    CCTRL_SESSION_PROFILE CCTRL_SESSION_PROFILE_SOURCE CCTRL_SESSION_AUTH_BACKEND
CCTRL_TEST_TMUX_TMPDIR="$(mktemp -d /tmp/cctrl-test-tmux.XXXXXX)" \
    || { echo "FAIL: could not create a private TMUX_TMPDIR; refusing to run against the real tmux server" >&2; exit 1; }
export TMUX_TMPDIR="$CCTRL_TEST_TMUX_TMPDIR"
# Phase-5 --settings overlay files (write + orphan GC) must never touch the
# real per-user runtime dir: a GC there under a fake tmux would delete live
# sessions' settings files.
export CCTRL_RUNTIME_DIR="$TMPDIR/runtime"
# With TMUX_TMPDIR set above, tmux's socket dir is $TMUX_TMPDIR/tmux-<uid>
# (not $TMPDIR, this suite's own scratch root). Private-socket tests
# (test_session_terminate_records_closed, test_session_close_reaps_pane_processes,
# test_session_stop_exact_identity) clean up into this dir; the guard test
# below (plan 095) checks nothing cctrl-*-$$-* is left there afterward. The
# guard matches on this run's own pid ($$, unaffected by subshells) rather
# than diffing a startup snapshot, so a concurrent suite run or worktree
# doing the same thing at the same time is never blamed on this run.
CCTRL_TEST_TMUX_SOCKET_DIR="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
if [[ "${CCTRL_TEST_ONLY:-}" == "codex-ownership-matrix" ]]; then
    mkdir -p "$TMPDIR/home"
    export HOME="$TMPDIR/home"
fi
export CCTRL_DATA_DIR="$TMPDIR/data"
export CCTRL_SESSION_METADATA_DIR="$TMPDIR/session-metadata"
export CCTRL_HOST_ID_FILE="$CCTRL_DATA_DIR/host-id"
# Keep discovery tests isolated from large, live Codex/Claude stores. Individual
# persistence tests override these roots with their own fixtures.
export CODEX_HOME="$TMPDIR/no-codex-home"
export CLAUDE_CONFIG_DIR="$TMPDIR/no-claude-config"
# plan 106: the task ls helper footer reads ps; keep it off unless a test sets fixtures.
export CCTRL_HELPERS_FOOTER=off
# Honest bash leg (plan 103): everything cctrl-shaped must run under the SAME
# bash as this harness. `#!/usr/bin/env bash` shebangs (cctrl, lib/, hooks/) and
# bare `bash -c` otherwise resolve to whatever bash is first on PATH (Homebrew
# 5.x on the Studio), so `/bin/bash tests/run-tests.sh` exercised cctrl under
# bash 5 while only the harness ran under 3.2. The shim lives only in this
# suite's TMPDIR and PATH; nothing outside is touched.
mkdir -p "$TMPDIR/bash-shim"
ln -s "$BASH" "$TMPDIR/bash-shim/bash"
export PATH="$TMPDIR/bash-shim:$PATH"
echo "bash: harness=$BASH_VERSION ($BASH) cctrl-under-test=$(printf '%s\n' 'echo "$BASH_VERSION"' | env bash -s) (via env bash shim)" >&"$_RT_BANNER_FD"  # --list keeps stdout to test names only
# `_test_path [--sbin] <dir>...` prints a PATH for fixture runs: the bash shim
# first (so cctrl runs under THIS harness bash), then the given dirs, then the
# system dirs. Every `PATH=` that builds a restricted PATH must use it
# (test_no_shimless_test_path). The system dirs are assembled from parts so this
# file holds no literal of the bare form the lint searches for.
_test_path() {
    local sys=/usr/bin out dir sbin=0
    if [[ "${1:-}" == "--sbin" ]]; then sbin=1; shift; fi
    out="$TMPDIR/bash-shim"
    for dir in "$@"; do out="$out:$dir"; done
    out="$out:$sys:/bin"
    if [[ "$sbin" -eq 1 ]]; then out="$out:/usr/sbin:/sbin"; fi
    printf '%s' "$out"
}
# Name the aborting test on any non-zero exit. A bare statement such as
# `cmd >/dev/null 2>&1` that fails under `set -e` otherwise kills the suite
# with no FAIL line at all -- that hid a real bash-5 regression for two
# install-gate runs (the output looked like a flake). `fail` still prints
# its own FAIL line first; this adds where the suite stopped.
_suite_exit() {
    local rc=$? cmd="$BASH_COMMAND"
    if [[ "$rc" -ne 0 ]]; then
        local frames="${FUNCNAME[*]:1}" lines="${BASH_LINENO[*]}"
        echo "FAIL: test suite aborted (exit $rc) in [${frames:-main}] (call lines: $lines) at: $cmd" >&2
        _rt_fail_report "$rc"
    fi
    if [[ -n "$TMPDIR" && -d "$TMPDIR" ]]; then
        # Detached launches leave background conversation-id pollers that can
        # still write into $TMPDIR during cleanup ("Directory not empty").
        # $TMPDIR is this run's own mktemp dir, so matching it on a command
        # line only ever hits this run's processes; then retry the rm.
        local _try
        pkill -f -- "$TMPDIR/" 2>/dev/null || true
        for _try in 1 2 3 4 5; do
            rm -rf -- "$TMPDIR" 2>/dev/null && break
            sleep 1
            pkill -f -- "$TMPDIR/" 2>/dev/null || true
        done
        [[ ! -d "$TMPDIR" ]] || rm -rf -- "$TMPDIR"
    fi
    if [[ "${CCTRL_TEST_TMUX_TMPDIR:-}" == /tmp/cctrl-test-tmux.* && -d "$CCTRL_TEST_TMUX_TMPDIR" ]]; then
        # Every server under the private dir is ours (default or a test's
        # -L socket); -S pins each one so nothing else is ever addressed.
        local _sock
        for _sock in "$CCTRL_TEST_TMUX_TMPDIR"/tmux-*/*; do
            [[ -S "$_sock" ]] && tmux -S "$_sock" kill-server 2>/dev/null || true
        done
        rm -rf -- "$CCTRL_TEST_TMUX_TMPDIR"
    fi
    return "$rc"
}
trap _suite_exit EXIT

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
# Plan 100: an agent running the suite sets these; any of them would force
# the non-interactive answer in the tty-ask tests or change an ask's outcome.
unset CLAUDECODE CCTRL_NO_INPUT CCTRL_ASK_TIMEOUT CCTRL_ALLOW_SECOND_FLEET_MANAGER
# Sandbox XDG_CONFIG_HOME globally so a test's default profile/config lookup
# (no CCTRL_PROFILES_DIR override) never falls through to the real
# ~/.config/cctrl, which could hold real secrets and would shadow fixture
# profile names (work, personal, home, team). CCTRL_PROFILES_DIR is unset so
# individual fallback/clash tests control it explicitly.
unset CCTRL_PROFILES_DIR
export XDG_CONFIG_HOME="$TMPDIR/xdg"
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

# `tmux kill-server` does not reliably unlink its own socket file (confirmed
# on the macOS tmux this suite runs against: the file survives kill-server
# and only a matching pid's exit races it) -- private-socket test cleanup
# traps must rm -f the path themselves. Plan 095.
_test_tmux_socket_rm() { # socket-name
    rm -f -- "$CCTRL_TEST_TMUX_SOCKET_DIR/$1" 2>/dev/null || true
}

test_tmux_sockets_left_behind() {
    # Backstop for the cleanup traps above: fails if any socket this run
    # created (name contains this script's own $$, unaffected by subshells)
    # still exists in the tmux socket dir. Matching on our own pid rather
    # than diffing a startup snapshot means a concurrent suite run or
    # worktree doing the same private-socket tests at the same time is never
    # blamed on this run. Must run after every test that opens a private
    # cctrl-* socket (session-stop-exact group and the main run).
    local leftover=() f
    shopt -s nullglob
    for f in "$CCTRL_TEST_TMUX_SOCKET_DIR"/cctrl-*-"$$"-*; do
        leftover+=("$(basename "$f")")
    done
    shopt -u nullglob
    [[ "${#leftover[@]}" -eq 0 ]] \
        || fail "test suite left tmux sockets behind in $CCTRL_TEST_TMUX_SOCKET_DIR: ${leftover[*]}"
    echo "ok: no leftover cctrl-* tmux sockets"
}

test_tmux_default_server_is_private() {
    # Plan 071 p5 incident guard: a bare `tmux` anywhere in the suite (a
    # test, or cctrl/wrapper code under test) must land on this run's own
    # private server, never the developer's real default one -- an
    # untargeted command there acts on whichever real session is "current".
    [[ -z "${TMUX:-}" && -z "${TMUX_PANE:-}" ]] || fail "TMUX/TMUX_PANE leaked into the suite"
    [[ "${TMUX_TMPDIR:-}" == "$CCTRL_TEST_TMUX_TMPDIR" && "$TMUX_TMPDIR" == /tmp/cctrl-test-tmux.* ]] \
        || fail "TMUX_TMPDIR is not the suite's private dir: ${TMUX_TMPDIR:-<unset>}"
    [[ "$CCTRL_TEST_TMUX_SOCKET_DIR" == "$TMUX_TMPDIR/"* ]] \
        || fail "private-socket tests would use a shared socket dir: $CCTRL_TEST_TMUX_SOCKET_DIR"
    [[ "${CCTRL_RUNTIME_DIR:-}" == "$TMPDIR/"* ]] || fail "CCTRL_RUNTIME_DIR is not sandboxed"

    local real_tmux sock private
    real_tmux="$(command -v tmux || true)"
    if [[ -n "$real_tmux" ]]; then
        "$real_tmux" -f /dev/null new-session -d -s cctrl-guard 'sleep 60' \
            || fail "could not start a session on the private default server"
        sock="$("$real_tmux" display-message -p -t '=cctrl-guard:' '#{socket_path}' 2>/dev/null || true)"
        "$real_tmux" kill-server 2>/dev/null || true
        private="$(cd "$TMUX_TMPDIR" && pwd -P)"
        [[ "$sock" == "$private/"* || "$sock" == "$TMUX_TMPDIR/"* ]] \
            || fail "bare tmux resolved outside the private dir: ${sock:-<none>}"
    fi

    # Static half: an untargeted display-message falls back to the default
    # server's current pane. Only the TMUX-guarded, ancestry-checked helper
    # may use one.
    local hits
    hits="$(grep -nE 'tmux display-message( -p)? ' "$ROOT/cctrl" "$ROOT"/lib/*.sh \
        | grep -v -- ' -t ' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
        | grep -v "display-message -p '#{session_name}' 2>/dev/null$" || true)"
    [[ -z "$hits" ]] || fail "untargeted tmux display-message (resolves to the real current pane):
$hits"
    echo "ok: bare tmux in the suite hits a private server; no untargeted display-message in shipped code"
}

# "Tests did not touch the real live store" guards (plan 090). Each guarded
# test takes a per-file manifest of the live store before and after, then
# asserts it is unchanged. On a mismatch the failure lists every changed
# path (added/removed/modified) instead of just "the digest moved".
#
# Files the live fleet rewrites while the suite runs; no code under test
# writes them, so they are left out of the manifest entirely:
#   rate-limits*.json(l)  statusline hook of every live Claude session
#   messages.jsonl        live peer mailbox (other sessions sending messages)
#   needs-me-snapshot.json  rewritten by every fleet-manager `cctrl needs-me`
#                         poll. Since plan 090 it follows CCTRL_DATA_DIR (which
#                         this file exports globally), so a test can't reach
#                         the real one without an explicit override.
#   snapshots/latest.json, snapshots/<UTC>Z.json, snapshots/.snapshot-*
#                         the launchd snapshot timer (every 5 minutes), which
#                         runs independently of this suite and does not set
#                         CCTRL_DATA_DIR. Since plan 078, `session snapshot`/
#                         `session restore --from latest`/doctor's staleness
#                         check all default to CCTRL_DATA_DIR (which this file
#                         exports globally above), so a test omitting --dir no
#                         longer risks writing the real directory; only these
#                         names remain exempt.
#
# data/sessions/ (the live session/task registry: heartbeats, spawns, closes
# of every live session) stays IN the manifest. An added or modified record
# there is tolerated as live-fleet churn only when it can't be the guarded
# test's own write: its file stem isn't one the test passed as its own, and
# its content mentions neither this run's $TMPDIR nor any of those names.
# Live records are mostly task-<hash>.json / launch-<uuid>.json, so in
# practice the content check (cwd, tmux_session, name) does the work, not the
# filename. A REMOVED record always fails: the live fleet adds and rewrites
# records but almost never deletes them, and a leaked close/prune is exactly
# what this guard exists to catch. Registry lock files
# (sessions/.task-registry-locks/*) and mktemp'd .task-event.* files come and
# go around every live write and are tolerated. Tolerated churn is reported as
# a `note:` line so it stays visible.
#
# The manifest follows a symlinked root: the install gate runs this suite from
# a release whose data/ is a symlink to the live store, and a bare `find` on
# that symlink used to hash nothing.
LIVE_GUARD_PY="$TMPDIR/live_store_guard.py"
cat > "$LIVE_GUARD_PY" <<'PY'
import hashlib
import os
import re
import sys

EXCLUDED_NAMES = {"rate-limits.json", "rate-limits-history.jsonl",
                  "messages.jsonl", "needs-me-snapshot.json"}
SNAPSHOT_TS = re.compile(r"\d{8}T\d{6}Z\.json")


def excluded(rel):
    parts = rel.split(os.sep)
    name = parts[-1]
    if name in EXCLUDED_NAMES:
        return True
    if len(parts) >= 2 and parts[-2] == "snapshots":
        return (name == "latest.json" or name.startswith(".snapshot-")
                or SNAPSHOT_TS.fullmatch(name) is not None)
    return False


def file_row(path):
    try:
        with open(path, "rb") as fh:
            return "sha256:" + hashlib.sha256(fh.read()).hexdigest()
    except FileNotFoundError:
        return None  # removed mid-walk; the after-manifest decides
    except OSError as exc:
        return "unreadable:" + exc.__class__.__name__


def manifest(roots):
    rows = []
    for root in roots:
        if os.path.islink(root):
            rows.append(("link:" + os.readlink(root), root))
        if os.path.isdir(root):
            for dirpath, dirnames, filenames in os.walk(root):
                for name in sorted(dirnames + filenames):
                    path = os.path.join(dirpath, name)
                    rel = os.path.relpath(path, root)
                    if excluded(rel):
                        continue
                    if os.path.islink(path):
                        rows.append(("link:" + os.readlink(path), path))
                    elif os.path.isdir(path):
                        rows.append(("dir", path))
                    else:
                        row = file_row(path)
                        if row is not None:
                            rows.append((row, path))
        elif os.path.isfile(root):
            row = file_row(root)
            rows.append((row or "absent", root))
        elif not os.path.lexists(root):
            rows.append(("absent", root))
    for kind, path in sorted(rows, key=lambda r: r[1]):
        print(f"{kind}\t{path}")


def load(path):
    out = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if "\t" in line:
                kind, p = line.split("\t", 1)
                out[p] = kind
    return out


def tolerated_churn(how, path, tmpdir, owned):
    parent, name = os.path.split(path)
    if (os.path.basename(parent) == ".task-registry-locks"
            and os.path.basename(os.path.dirname(parent)) == "sessions"):
        return True  # pid/time/token lock around a live registry write
    if os.path.basename(parent) != "sessions":
        return False
    if name == ".task-registry-locks" or name.startswith(".task-event."):
        return True  # mktemp'd event file, caught mid-write
    if how == "removed":
        return False
    stem = name[:-5] if name.endswith(".json") else name
    if stem in owned:
        return False
    try:
        with open(path, "rb") as fh:
            body = fh.read().decode("utf-8", "replace")
    except OSError:
        return False  # changed and now unreadable: don't guess
    needles = [tmpdir] + list(owned)
    return not any(n and n in body for n in needles)


def diff(before_file, after_file, tmpdir, owned):
    before, after = load(before_file), load(after_file)
    changes = []
    for p in sorted(set(before) | set(after)):
        if p not in before:
            changes.append(("added", p))
        elif p not in after:
            changes.append(("removed", p))
        elif before[p] != after[p]:
            changes.append(("modified", p))
    bad = [c for c in changes if not tolerated_churn(c[0], c[1], tmpdir, owned)]
    churn = [c for c in changes if c not in bad]
    if bad:
        for how, p in bad:
            print(f"  {how}: {p}")
        if churn:
            print(f"  (also {len(churn)} tolerated live-fleet registry change(s): "
                  + ", ".join(f"{h} {os.path.basename(p)}" for h, p in churn) + ")")
        return 1
    if churn:
        print(f"ignored {len(churn)} live-fleet registry change(s): "
              + ", ".join(f"{h} {os.path.basename(p)}" for h, p in churn))
    return 0


if __name__ == "__main__":
    if sys.argv[1] == "manifest":
        manifest(sys.argv[2:])
    elif sys.argv[1] == "diff":
        sys.exit(diff(sys.argv[2], sys.argv[3], sys.argv[4], set(sys.argv[5:])))
    else:
        sys.exit(f"unknown mode {sys.argv[1]}")
PY

live_tree_manifest() { python3 "$LIVE_GUARD_PY" manifest "$@"; }
live_data_manifest() { live_tree_manifest "$ROOT/data"; }
ownership_live_store_manifest() {
    live_tree_manifest "$ROOT/data" "$ROOT/.active-profile" \
        "$CCTRL_TEST_REAL_HOME/.config/cctrl" \
        "$CCTRL_TEST_REAL_HOME/.codex/hooks.json" \
        "$CCTRL_TEST_REAL_HOME/.codex/config.toml" \
        "$CCTRL_TEST_REAL_HOME/.claude/settings.json"
}

# live_store_changes BEFORE AFTER [owned-name...]: prints the changed paths and
# returns 1 if any change could be the test's own write; prints a churn note
# (or nothing) and returns 0 otherwise.
live_store_changes() {
    local before="$1" after="$2"; shift 2
    [[ "$before" == "$after" ]] && return 0
    local bf af
    bf="$(mktemp "$TMPDIR/live-guard-before.XXXXXX")"
    af="$(mktemp "$TMPDIR/live-guard-after.XXXXXX")"
    printf '%s\n' "$before" > "$bf"
    printf '%s\n' "$after" > "$af"
    local rc=0
    python3 "$LIVE_GUARD_PY" diff "$bf" "$af" "$TMPDIR" "$@" || rc=$?
    rm -f -- "$bf" "$af"
    return "$rc"
}

# assert_live_store_unchanged BEFORE AFTER MESSAGE [owned-name...]
assert_live_store_unchanged() {
    local before="$1" after="$2" message="$3"; shift 3
    local report rc=0
    report="$(live_store_changes "$before" "$after" "$@")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        fail "$message; changed paths:
$report"
    fi
    [[ -z "$report" ]] || echo "note: live-store guard: $report" >&2
    return 0
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
    # Fixture helper only: fake tmux permits repeated names within one second.
    # Bash 3.2 -nt loses the fractional mtime and can select an older fixture.
    python3 - "$1" "${2:-$CCTRL_SESSION_METADATA_DIR}" <<'PYFIXTURE'
import json, pathlib, sys
name, directory = sys.argv[1], pathlib.Path(sys.argv[2])
files = []
for path in list(directory.glob('task-*.json')) + list(directory.glob('launch-*.json')):
    value = json.loads(path.read_text())
    if value.get('tmux_session', value.get('name', '')) == name:
        files.append(path)
if files:
    print(max(files, key=lambda path: path.stat().st_mtime_ns)); sys.exit(0)
legacy = directory / (name.replace('/', '_').replace(':', '_') + '.json')
if legacy.is_file():
    print(legacy); sys.exit(0)
sys.exit(1)
PYFIXTURE
}

session_record_json() {
    local path
    path="$(session_record_path "$1" "${2:-$CCTRL_SESSION_METADATA_DIR}")" || return 1
    cat "$path"
}

cctrl_source_eval() {
    local code="$1"
    shift
    CCTRL_NO_MAIN=1 "$BASH" -c 'code="$1"; shift; source "$0"; eval "$code"' "$ROOT/cctrl" "$code" "$@"
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
if [[ -n "\${FAKE_AGENT_ENV_NAMES:-}" ]]; then
    for _fake_env_name in \$FAKE_AGENT_ENV_NAMES; do
        if [[ -n "\${!_fake_env_name+set}" ]]; then
            printf 'ENV_%s=%s\n' "\$_fake_env_name" "\${!_fake_env_name}"
        else
            printf 'ENV_%s=<unset>\n' "\$_fake_env_name"
        fi
    done
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
    # One write per line: a detached start leaves a background
    # conversation-id poller calling this fake with the same TMUX_LOG, and
    # per-arg printf appends let its line splice into ours mid-line.
    _log_line="TMUX"
    for arg in "$@"; do
        printf -v _q ' %q' "$arg"
        _log_line+="$_q"
    done
    printf '%s\n' "$_log_line" >> "$TMUX_LOG"
fi
if [[ "${1:-}" == "-u" ]]; then shift; fi
if [[ "${1:-}" == "new-session" ]]; then
    printf 'SHELL_CMD=%s\n' "${@: -1}" >> "${TMUX_LOG:?}"
fi

# Extract a "-t VALUE" target argument, if present.
_fake_tmux_target() {
    local i j
    for ((i = 1; i <= $#; i++)); do
        if [[ "${!i}" == "-t" ]]; then
            j=$((i + 1))
            printf '%s' "${!j:-}"
            return 0
        fi
    done
}

# Resolve a target against TMUX_FAKE_STATE (a file of "id:name" lines, one
# per live fake session; see plan 080's regression test). A target prefixed
# with "=" is tmux's real exact-match syntax and is matched ONLY against the
# exact name; a bare target additionally falls back to a prefix match,
# reproducing the real tmux behavior a missing "=" is vulnerable to (a bare
# "-t NAME" can silently resolve to a still-live "NAME--2").
#
# $2 is the resolution mode: "session" (default) for has-session/
# kill-session/attach-session, where real tmux accepts a bare "=NAME" (no
# trailing ":") as an exact match; or "pane" for every other subcommand
# (display-message, capture-pane, send-keys, list-panes, ...), where real
# tmux additionally requires the trailing ":" on "=NAME" — a colon-less
# "=NAME" fails to resolve there (verified against tmux 3.7c; see plan 080's
# review). Getting this wrong let a broken implementation pass its own tests.
_fake_tmux_state_resolve() {
    local target="$1" mode="${2:-session}" exact=false id lname
    [[ -n "$target" ]] || return 1
    if [[ "$target" == "="* ]]; then
        exact=true
        target="${target#=}"
        if [[ "$mode" == "pane" ]]; then
            [[ "$target" == *:* ]] || return 1
        fi
    fi
    target="${target%%:*}"
    [[ -f "${TMUX_FAKE_STATE:-/dev/null}" ]] || return 1
    # A literal tmux session id ($N) is always an exact, non-prefix target —
    # real tmux never prefix-matches it, so it bypasses the name logic below.
    if [[ "$target" == '$'* ]]; then
        while IFS=: read -r id lname; do
            [[ -n "$id" ]] || continue
            [[ "$id" == "$target" ]] && { printf '%s:%s\n' "$id" "$lname"; return 0; }
        done < "$TMUX_FAKE_STATE"
        return 1
    fi
    while IFS=: read -r id lname; do
        [[ -n "$id" ]] || continue
        [[ "$lname" == "$target" ]] && { printf '%s:%s\n' "$id" "$lname"; return 0; }
    done < "$TMUX_FAKE_STATE"
    $exact && return 1
    while IFS=: read -r id lname; do
        [[ -n "$id" ]] || continue
        [[ "$lname" == "$target"* ]] && { printf '%s:%s\n' "$id" "$lname"; return 0; }
    done < "$TMUX_FAKE_STATE"
    return 1
}

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
        if [[ -n "${TMUX_FAKE_STATE:-}" ]]; then
            _fake_tmux_state_resolve "$(_fake_tmux_target "$@")" >/dev/null && exit 0 || exit 1
        fi
        if [[ "${TMUX_FAKE_HAS_SESSION:-}" == "1" ]]; then
            exit 0
        fi
        if [[ -n "${TMUX_FAKE_HAS_SESSION:-}" ]]; then
            target="$(_fake_tmux_target "$@")"
            target="${target#=}"
            [[ " ${TMUX_FAKE_HAS_SESSION} " == *" ${target} "* ]] && exit 0
        fi
        exit 1
        ;;
    kill-session)
        if [[ -n "${TMUX_FAKE_STATE:-}" ]]; then
            match="$(_fake_tmux_state_resolve "$(_fake_tmux_target "$@")")" || { echo "can't find session" >&2; exit 1; }
            grep -v -x -F "$match" "$TMUX_FAKE_STATE" > "$TMUX_FAKE_STATE.tmp" 2>/dev/null || true
            mv "$TMUX_FAKE_STATE.tmp" "$TMUX_FAKE_STATE"
        fi
        exit 0
        ;;
    list-sessions)
        if [[ "${TMUX_FAKE_LIST_SESSIONS_FAIL:-}" == "1" ]]; then
            echo "no server running on this socket" >&2
            exit 1
        fi
        if [[ -n "${TMUX_FAKE_STATE:-}" && -f "${TMUX_FAKE_STATE:-/dev/null}" ]]; then
            cut -d: -f2- "$TMUX_FAKE_STATE"
        elif [[ -n "${TMUX_FAKE_SESSIONS:-}" ]]; then
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
        if [[ -n "${TMUX_FAKE_STATE:-}" ]]; then
            match="$(_fake_tmux_state_resolve "$(_fake_tmux_target "$@")" pane)" || exit 1
            if [[ "$*" == *'session_id'* && "$*" == *'session_name'* ]]; then
                printf '%s %s\n' "${match%%:*}" "${match#*:}"
                exit 0
            elif [[ "$*" == *session_name* ]]; then
                printf '%s\n' "${match#*:}"
                exit 0
            elif [[ "$*" == *session_id* ]]; then
                printf '%s\n' "${match%%:*}"
                exit 0
            fi
        fi
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
    bash -n "$ROOT/install.sh"
    zsh -n "$ROOT/completions/_cctrl"

    # Glob rather than a hand-kept list, so a new lib/hooks/install file is
    # checked automatically instead of silently exempted from the gate that
    # install/self-install.sh relies on to decide "safe to ship".
    local f
    for f in "$ROOT"/lib/*.sh "$ROOT"/hooks/*.sh "$ROOT"/install/*.sh; do
        [[ -f "$f" ]] || continue
        bash -n "$f"
    done
    for f in "$ROOT"/lib/*.py "$ROOT"/hooks/*.py; do
        [[ -f "$f" ]] || continue
        python3 -m py_compile "$f"
    done
    for f in "$ROOT"/lib/*.pl; do
        [[ -f "$f" ]] || continue
        perl -c "$f" 2>/dev/null
    done

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

_registration_problems() { # <harness file> -> one problem per line; empty when the registry is sound
    # plan 105 P4. Reads the file as text (never sources it), so a fixture can
    # be checked the same way as the real harness.
    local f="$1" defs kind name entry
    defs="$(awk '/^test_[A-Za-z0-9_]+\(\)/ { n = $0; sub(/\(\).*/, "", n); print n }' "$f" | sort)"
    # 1. every SKIP / RUN_FIRST / RUN_LAST entry names a defined test and has a reason
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        if ! printf '%s\n' "$entry" | grep -Eq "^_rt_register (RUN_FIRST|SKIP|RUN_LAST) test_[A-Za-z0-9_]+ '.+'$"; then
            echo "registry entry without a name or reason: $entry"
            continue
        fi
        kind="$(printf '%s\n' "$entry" | awk '{print $2}')"
        name="$(printf '%s\n' "$entry" | awk '{print $3}')"
        printf '%s\n' "$defs" | grep -Fxq -- "$name" || echo "$kind entry names no defined test: $name"
    done < <(grep '^_rt_register [A-Z]' "$f" || true)
    # 2. every group entry names a defined, discoverable test (a test the
    # discovery pattern cannot see would be reachable only through a group)
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        printf '%s\n' "$defs" | grep -Fxq -- "$name" || echo "group entry names no defined (discoverable) test: $name"
    done < <(awk '/^_group_tests\(\) \{/ { g = 1; next } g && /^\}/ { g = 0 } g && /printf/ { while (match($0, /test_[A-Za-z0-9_]+/)) { print substr($0, RSTART, RLENGTH); $0 = substr($0, RSTART + RLENGTH) } }' "$f")
    # 3. discovery sees as many tests as a second, independent grep finds
    local n_awk n_grep
    n_awk="$(printf '%s\n' "$defs" | grep -c . || true)"
    n_grep="$(grep -Ec '^function +test_[A-Za-z0-9_]+|^test_[A-Za-z0-9_]+ *\(\)' "$f" || true)"
    [[ "$n_awk" == "$n_grep" ]] || echo "discovery found $n_awk tests but grep found $n_grep definitions (a test the discovery pattern cannot see)"
    # 4. no test defined twice
    printf '%s\n' "$defs" | uniq -d | sed 's/^/test defined twice: /'
}

test_every_defined_test_is_registered() {
    # A test_* function that is defined but never run is a dead test: it gives
    # false confidence (dbe923e silently dropped 31 tests that way, plan 097).
    # Since plan 105 P4 tests are discovered, so the risks that remain are
    # stale registry entries and tests the discovery pattern cannot see.
    # Checks (see _registration_problems): every SKIP/RUN_FIRST/RUN_LAST/group
    # entry names a defined test (SKIP and RUN_* entries carry a reason);
    # no test is reachable only through a group (undiscoverable); discovery equals an
    # independent grep count; no duplicates. "Every tests/suite/*.sh was
    # sourced" arrives with the split (P6).
    local problems
    problems="$(_registration_problems "$ROOT/tests/run-tests.sh")"
    [[ -z "$problems" ]] || fail "test registry problems:
$problems"
    echo "ok: every defined test_* function is registered"
}

test_registration_guard_self_test() {
    # plan 105 P4: the guard must bite. Fixtures are written with the test
    # names assembled at runtime so none starts a line in this file.
    local d="$TMPDIR/reg-guard-fx" fx out t_a="test_fx""_a" t_b="test_fx""_b" t_g="test_fx""_gonly" t_sk="test_fx""_skipped"
    mkdir -p "$d"
    fx="$d/fx.sh"
    _fx_registry() { # skip-name group-names...  [GONLY=1 defines the group test in a form discovery cannot see]
        local skip="$1"; shift
        {
            printf '%s() { :; }\n%s() { :; }\n%s() { :; }\n' "$t_a" "$t_b" "$t_sk"
            if [[ "${GONLY:-0}" == "1" ]]; then printf '%s () { :; }\n' "$t_g"; fi
            printf "_rt_register SKIP %s 'fixture reason'\n" "$skip"
            printf "_rt_register RUN_LAST %s 'fixture reason'\n" "$t_b"
            printf '_group_tests() {\n    case "$1" in\n        g1) printf '"'"'%%s\\n'"'"' %s ;;\n    esac\n}\n' "$*"
        } > "$fx"
    }
    _fx_registry "$t_sk" "$t_a $t_b"
    out="$(_registration_problems "$fx")"
    [[ -z "$out" ]] || fail "guard flagged a sound fixture registry: $out"
    # a SKIP entry that names no defined test
    _fx_registry "test_fx_no_such_test" "$t_a"
    out="$(_registration_problems "$fx")"
    assert_contains "$out" "SKIP entry names no defined test: test_fx_no_such_test"
    # a SKIP-listed test may be named by a group (a manual focused run)
    _fx_registry "$t_sk" "$t_a $t_sk"
    out="$(_registration_problems "$fx")"
    [[ -z "$out" ]] || fail "guard flagged a SKIP-listed test named by a group: $out"
    # a group test the discovery pattern cannot see
    GONLY=1 _fx_registry "$t_sk" "$t_a $t_g"
    out="$(_registration_problems "$fx")"
    assert_contains "$out" "group entry names no defined (discoverable) test: $t_g"
    assert_contains "$out" "discovery found 3 tests but grep found 4 definitions"
    # a SKIP entry without a reason
    _fx_registry "$t_sk" "$t_a"
    printf "_rt_register SKIP %s\n" "$t_a" >> "$fx"
    out="$(_registration_problems "$fx")"
    assert_contains "$out" "registry entry without a name or reason"
    # the same test defined twice
    _fx_registry "$t_sk" "$t_a"
    printf '%s() { :; }\n' "$t_a" >> "$fx"
    out="$(_registration_problems "$fx")"
    assert_contains "$out" "test defined twice: $t_a"
    unset -f _fx_registry
    echo "ok: the registration guard flags bad SKIP names, group-only tests, hidden definitions, missing reasons and duplicates"
}

test_no_unreferenced_functions() {
    # plan 104: a top-level cctrl function whose name appears nowhere else (cctrl,
    # lib, hooks, completions, tests; whole-name match) is dead code. Intentional
    # entry points go in the allowlist WITH a reason (one "name  # reason" per
    # line). Approximate: any second mention (comment, string) keeps a function
    # alive; install/, contrib/, plugins/ and skills/ are not scanned, so a
    # function used only there must be allowlisted.
    local allow=" " dead="" f n files=("$ROOT/cctrl" "$ROOT/tests/run-tests.sh")
    [[ -d "$ROOT/lib" ]] && files+=("$ROOT/lib")
    [[ -d "$ROOT/hooks" ]] && files+=("$ROOT/hooks")
    [[ -d "$ROOT/completions" ]] && files+=("$ROOT/completions")
    while IFS= read -r f; do
        [[ "$allow" == *" $f "* ]] && continue
        n="$(grep -rwo -- "$f" "${files[@]}" 2>/dev/null | wc -l | tr -d ' ')"
        [[ "$n" -gt 1 ]] || dead+="$f"$'\n'
    done < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\) \{' "$ROOT/cctrl" | sed 's/() {$//' | sort -u)
    [[ -z "$dead" ]] || fail "functions defined in cctrl but never referenced (delete them, or allowlist with a reason):
$dead"
    echo "ok: every top-level cctrl function is referenced"
}

test_runner_filter_and_list() {
    # plan 105 P3: the runner (timing, positional filter, --list, fail-fast,
    # keep-going) against a 3-test fixture built from the real runner block,
    # plus the real harness's own --list / unknown-name behaviour. The fixture
    # lines are indented so the dead-test scanner does not see them as tests.
    local d="$TMPDIR/runner-fx" fx out rc tsv
    mkdir -p "$d"
    fx="$d/fixture.sh"
    {
        printf '%s\n' 'set -euo pipefail'
        sed -n '/^# >>> test runner/,/^# <<< test runner/p' "$ROOT/tests/run-tests.sh"
        cat <<'FX'
    _RT_SELF="$0"
    fail() { echo "FAIL: $*" >&2; exit 1; }
    trap '_rt_fail_report "$?"' EXIT
    _runner_parse "$@"
    test_fx_pass() { echo "body: pass"; }
    test_fx_fail() { echo "body: before false"; false; echo "SET-E-NOT-LIVE"; }
    test_fx_after() { echo "body: after"; }
    _run_test test_fx_pass
    _run_test test_fx_fail
    _run_test test_fx_after
    _runner_finish
    echo "FULL-RUN-REACHED-END"
    _runner_report || exit 1
FX
    } > "$fx"
    [[ -n "$(sed -n '/^# >>> test runner/p' "$fx")" ]] || fail "runner block not extracted from the harness"
    local -a clean=(env -u CCTRL_TEST_ONLY -u CCTRL_TEST_NAMES -u CCTRL_TEST_KEEP_GOING -u CCTRL_TEST_TIMINGS)

    # --list: names in registry order, nothing executed, rc 0.
    rc=0; out="$("${clean[@]}" "$BASH" "$fx" --list 2>&1)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "--list rc=$rc: $out"
    [[ "$out" == $'test_fx_pass\ntest_fx_fail\ntest_fx_after' ]] || fail "--list output wrong: $out"

    # Default: fail-fast. The bare `false` must abort the test (set -e live),
    # the third test never runs, and the FAIL line names the test and its rc.
    rc=0; out="$("${clean[@]}" "$BASH" "$fx" 2>&1)" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "fail-fast rc=$rc (want 1): $out"
    assert_contains "$out" "ok: test_fx_pass ("
    assert_contains "$out" "FAIL: test_fx_fail (rc=1,"
    assert_not_contains "$out" "SET-E-NOT-LIVE"
    assert_not_contains "$out" "body: after"
    assert_not_contains "$out" "FULL-RUN-REACHED-END"

    # Filter runs only the named tests, in registry order (not argument order),
    # skips the failing one, and does not reach the full-run tail.
    tsv="$d/timings.tsv"
    rc=0; out="$("${clean[@]}" CCTRL_TEST_TIMINGS="$tsv" "$BASH" "$fx" test_fx_after test_fx_pass 2>&1)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "filter rc=$rc: $out"
    assert_not_contains "$out" "test_fx_fail"
    assert_not_contains "$out" "FULL-RUN-REACHED-END"
    [[ "${out%%body: after*}" == *"body: pass"* ]] || fail "filter ran in argument order, not registry order: $out"
    assert_contains "$out" "slowest 20"
    [[ "$(wc -l < "$tsv" | tr -d ' ')" -eq 2 ]] || fail "timings TSV should have one row per run test: $(cat "$tsv")"
    [[ "$(awk -F'\t' 'NF==3 && $1 ~ /^test_fx_/ && $2 ~ /^[0-9]+\.[0-9][0-9][0-9]$/ && $3=="ok"' "$tsv" | wc -l | tr -d ' ')" -eq 2 ]] \
        || fail "timings TSV rows are not name<TAB>seconds<TAB>ok: $(cat "$tsv")"
    # Same through CCTRL_TEST_NAMES.
    rc=0; out="$("${clean[@]}" CCTRL_TEST_NAMES="test_fx_pass" "$BASH" "$fx" 2>&1)" || rc=$?
    [[ "$rc" -eq 0 && "$out" == *"ok: test_fx_pass ("* && "$out" != *"body: after"* ]] || fail "CCTRL_TEST_NAMES filter wrong (rc=$rc): $out"

    # Unknown name: rc 64 with the near matches, before anything runs.
    rc=0; out="$("${clean[@]}" "$BASH" "$fx" test_fx_pas 2>&1)" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "unknown name rc=$rc (want 64): $out"
    assert_contains "$out" "unknown test name"
    assert_contains "$out" "test_fx_pass"
    assert_not_contains "$out" "body: pass"
    # A group and a test name together are refused.
    rc=0; out="$("${clean[@]}" CCTRL_TEST_ONLY=x "$BASH" "$fx" test_fx_pass 2>&1)" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "group+name rc=$rc (want 64): $out"

    # Empty / whitespace-only filters are refused (they would pass on zero
    # tests); newline- or tab-separated CCTRL_TEST_NAMES still select.
    rc=0; out="$("${clean[@]}" "$BASH" "$fx" '' 2>&1)" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "empty name rc=$rc (want 64): $out"
    rc=0; out="$("${clean[@]}" CCTRL_TEST_NAMES=" " "$BASH" "$fx" 2>&1)" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "blank CCTRL_TEST_NAMES rc=$rc (want 64): $out"
    rc=0; out="$("${clean[@]}" CCTRL_TEST_NAMES=$'test_fx_pass\ntest_fx_after' "$BASH" "$fx" 2>&1)" || rc=$?
    [[ "$rc" -eq 0 && "$out" == *"body: pass"* && "$out" == *"body: after"* ]] || fail "newline-separated CCTRL_TEST_NAMES wrong (rc=$rc): $out"
    assert_contains "$out" "FILTERED RUN: 2 of 3"

    # Keep-going (opt-in): the failing test is reported, the later one still
    # runs, the summary lists the failure, rc 1.
    rc=0; out="$("${clean[@]}" CCTRL_TEST_KEEP_GOING=1 "$BASH" "$fx" 2>&1)" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "keep-going rc=$rc (want 1): $out"
    assert_contains "$out" "FAIL: test_fx_fail (rc=1,"
    assert_not_contains "$out" "SET-E-NOT-LIVE"
    assert_contains "$out" "ok: test_fx_after ("
    assert_contains "$out" "failed tests: test_fx_fail"

    # Isolation (P4): every test runs in its own subshell. An export, a cd, a
    # function redefinition and an EXIT trap set by one test must not leak
    # into the next, the trap fires at the end of that test, and a bare
    # `false` still aborts the test (set -e live) with the harness exiting
    # with the test's own status.
    local fx2="$d/fixture-iso.sh"
    {
        printf '%s\n' 'set -euo pipefail'
        sed -n '/^# >>> test runner/,/^# <<< test runner/p' "$ROOT/tests/run-tests.sh"
        cat <<'FX'
    _RT_SELF="$0"
    fail() { echo "FAIL: $*" >&2; exit 1; }
    trap '_rt_fail_report "$?"' EXIT
    _runner_parse "$@"
    fx_helper() { echo "helper: original"; }
    test_iso_dirty() { export FX_LEAK=1; cd /; fx_helper() { echo "helper: redefined"; }; trap 'echo "TRAP-FIRED-AT-TEST-END"' EXIT; echo "body: dirty"; }
    test_iso_clean() { [[ -z "${FX_LEAK:-}" && "$PWD" != "/" ]] || { echo "LEAKED"; return 1; }; [[ "$(fx_helper)" == "helper: original" ]] || { echo "LEAKED-FN"; return 1; }; echo "body: clean"; }
    test_iso_status() { echo "body: status"; ( exit 7 ); echo "SET-E-NOT-LIVE-7"; }
    test_iso_never() { echo "body: never"; }
    _run_test test_iso_dirty
    _run_test test_iso_clean
    _run_test test_iso_status
    _run_test test_iso_never
FX
    } > "$fx2"
    rc=0; out="$("${clean[@]}" "$BASH" "$fx2" 2>&1)" || rc=$?
    assert_contains "$out" "TRAP-FIRED-AT-TEST-END"
    assert_contains "$out" "ok: test_iso_clean ("
    assert_not_contains "$out" "LEAKED"
    [[ "$rc" -eq 7 ]] || fail "isolation fixture should exit with the failing test's status 7, got $rc: $out"
    assert_contains "$out" "FAIL: test_iso_status (rc=7,"
    assert_not_contains "$out" "SET-E-NOT-LIVE-7"
    assert_not_contains "$out" "body: never"

    # The real harness: --list is the registry (first entry is the always-on
    # test, this test is in it) and an unknown name is refused with rc 64.
    rc=0; out="$("${clean[@]}" "$BASH" "$ROOT/tests/run-tests.sh" --list 2>/dev/null)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "real --list rc=$rc"
    [[ "$(printf '%s\n' "$out" | sed -n 1p)" == "test_tmux_default_server_is_private" ]] || fail "real --list should start with the always-on test"
    printf '%s\n' "$out" | grep -Fxq test_runner_filter_and_list || fail "real --list does not contain this test"
    # Discovery (P4): --list is every definition minus the SKIP entries, in
    # source order, with RUN_LAST last.
    local n_def n_skip
    n_def="$(grep -Ec '^test_[A-Za-z0-9_]+\(\)' "$ROOT/tests/run-tests.sh")"
    n_skip="$(grep -c '^_rt_register SKIP ' "$ROOT/tests/run-tests.sh")"
    [[ "$(printf '%s\n' "$out" | grep -c '^test_')" -eq $(( n_def - n_skip )) ]] || fail "real --list should be every definition minus the $n_skip SKIP entries"
    local n_sk
    while IFS= read -r n_sk; do
        if printf '%s\n' "$out" | grep -Fxq -- "$n_sk"; then fail "real --list contains the SKIP-listed test $n_sk"; fi
    done < <(grep '^_rt_register SKIP ' "$ROOT/tests/run-tests.sh" | awk '{print $3}')
    [[ "$(printf '%s\n' "$out" | tail -n 1)" == "test_tmux_sockets_left_behind" ]] || fail "real --list should end with the RUN_LAST test"
    [[ "$(printf '%s\n' "$out" | grep -c '^test_')" -gt 400 ]] || fail "real --list has too few tests"
    rc=0; out="$("${clean[@]}" "$BASH" "$ROOT/tests/run-tests.sh" test_no_such_test_zz 2>&1)" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "real unknown name rc=$rc (want 64)"
    echo "ok: runner filter, --list, fail-fast, keep-going and live set -e work"
}

_helper_census_fixture() {
    # plan 106 P1: fixture ps tables only; never the live process table.
    local d="$1"
    local pl="PLAN""TED"   # assembled at runtime: no secret-shaped literal in the tree
    HC_NEEDLES=("${pl}-SECRET-123" "sk-${pl}" "${pl}PW" "${pl}-COMM" "${pl}3")
    mkdir -p "$d"
    cat > "$d/ps.txt" <<'E'
  100     1 2000000 /usr/local/bin/codex
  200     1 3000 /usr/local/bin/codex
  300     1 400000 /Users/x/.local/bin/claude
  400     1 100 /usr/sbin/cron
  500   100 1 /bin/zombie-thing
  not a row
E
    local i
    for i in $(seq 1 40); do
        echo "  $((1000 + i))   100 600000 /opt/my tools/mcp-server-$((i % 3))" >> "$d/ps.txt"
    done
    echo "  1500  1001 50000 /bin/sh" >> "$d/ps.txt"
    echo "  600     1 90000 /usr/local/bin/codex" >> "$d/ps.txt"
    for i in $(seq 1 400); do echo "  $((3000 + i))   600 100 /usr/bin/small-helper" >> "$d/ps.txt"; done
    echo "  700     1 100 /usr/bin/node /opt/x.js --token=${pl}-COMM-SECRET" >> "$d/ps.txt"
    echo "  701     600 100 ${pl}-COMM=oops" >> "$d/ps.txt"
    for i in $(seq 1 18); do printf '[mcp_servers.srv%s]\ncommand = "x"\n' "$i" >> "$d/codex-config.toml"; done
    echo "  301   300 40000 /usr/bin/node" >> "$d/ps.txt"
    echo "  201   200 40000 /usr/bin/node" >> "$d/ps.txt"
    printf '100 /usr/local/bin/codex app-server --remote-control --token=%s-SECRET-123 --api-key sk-%s\n200 codex --api-key=sk-%s2 https://user:%sPW@example.com\n600 codex app-server\n300 claude KEY=%s3\n' "$pl" "$pl" "$pl" "$pl" "$pl" > "$d/args.txt"
    printf '1 TMUX--ignored\n200 TMUX--demo--1\n' > "$d/panes.txt"
}

test_helper_census() {
    local d="$TMPDIR/helper-census" out rc=0 j
    _helper_census_fixture "$d"
    out="$(CCTRL_HELPERS_FIXTURE_DIR="$d" "$ROOT/cctrl" helpers 2>&1)" || rc=$?
    [[ $rc -eq 0 ]] || fail "helpers rc=$rc: $out"
    [[ "$out" == *"codex app-server (remote-control)"* ]] || fail "app-server label missing: $out"
    [[ "$out" == *"codex tui"* && "$out" == *"claude"* && "$out" == *"TMUX--demo--1"* ]] || fail "tui/claude/session rows missing: $out"
    [[ "$out" == *"FLAGGED pid 100"* ]] || fail "app-server not flagged: $out"
    [[ "$out" != *"cron"* ]] || fail "unrelated process leaked: $out"
    [[ "$out" == *"mcp-server-"* ]] || fail "spaces in comm path broke parsing: $out"
    [[ "$out" == *"cctrl does not reap helpers"* ]] || fail "reap sentence missing"
    j="$(CCTRL_HELPERS_FIXTURE_DIR="$d" "$ROOT/cctrl" helpers --json 2>&1)" || fail "helpers --json failed"
    [[ "$(jq -r '[.owners[]|select(.pid==100)][0]|"\(.direct_children) \(.label)"' <<< "$j")" == "41 codex app-server (remote-control)" ]] || fail "app-server counts wrong: $j"
    [[ "$(jq -r '.summary.owners' <<< "$j")" == "4" ]] || fail "owner count wrong"
    [[ "$(jq -r '[.owners[]|select(.pid==100)][0]|"\(.per_set) \(.est_sets) \(.flagged)"' <<< "$j")" == "18 2 true" ]] || fail "per_set/est_sets/memory flag wrong (18-server config)"
    [[ "$(jq -r '[.owners[]|select(.pid==600)][0]|"\(.flagged) \(.est_sets)"' <<< "$j")" == "true 22" ]] || fail "sets-only flag wrong"
    # --warn-sets lowered so the 40-helper owner is flagged whatever the per-set estimate
    rc=0; CCTRL_HELPERS_FIXTURE_DIR="$d" "$ROOT/cctrl" helpers --check --warn-sets 0 >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 1 ]] || fail "--check should exit 1 when flagged, got $rc"
    rc=0; CCTRL_HELPERS_FIXTURE_DIR="$d" "$ROOT/cctrl" helpers --check --warn-sets 9999 --warn-gb 9999 >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 0 ]] || fail "--check should exit 0 when nothing flagged, got $rc"
    # planted secrets in args never reach text or json output
    local needle
    for needle in "${HC_NEEDLES[@]}"; do
        grep -qF -- "$needle" "$d/args.txt" "$d/ps.txt" 2>/dev/null || fail "fixture lost its planted value $needle (test would prove nothing)"
        [[ "$out$j" != *"$needle"* ]] || fail "planted secret $needle leaked into output"
    done
    [[ "$out$j" != *example.com* ]] || fail "credential URL leaked into output"
    # empty / failed ps: exit 69, no traceback
    : > "$d/ps.txt"
    out="$(CCTRL_HELPERS_FIXTURE_DIR="$d" "$ROOT/cctrl" helpers 2>&1)" && rc=0 || rc=$?
    [[ $rc -eq 69 && "$out" != *Traceback* ]] || fail "empty ps: want rc 69 without traceback, got $rc: $out"
    printf 'garbage\n\x00\xff binary\n' > "$d/ps.txt"
    out="$(CCTRL_HELPERS_FIXTURE_DIR="$d" "$ROOT/cctrl" helpers --json 2>&1)" && rc=0 || rc=$?
    [[ $rc -eq 69 && "$out" != *Traceback* ]] || fail "odd ps: want rc 69 without traceback, got $rc: $out"
    rc=0; "$ROOT/cctrl" helpers --bogus >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 64 ]] || fail "bad flag should exit 64, got $rc"
    echo "ok: helper census counts, labels, flags, redaction, soft failure"
}

test_helper_census_never_kills_structural() {
    local f="$ROOT/lib/helper_census.py" hit
    hit="$(grep -inE 'kill|signal|terminat|os\.remove|unlink|rmtree|os\.system|Popen|os\.write|open\([^)]*[\"'\'']w' "$f" || true)"
    [[ -z "$hit" ]] || fail "helper_census.py must have no kill/signal/write path: $hit"
    hit="$(grep -nE 'getenv|eww|printenv|environ\[|environ\.(items|copy|keys|values)|"-E"|"axe' "$f" || true)"
    [[ -z "$hit" ]] || fail "helper_census.py must not read process environments: $hit"
    hit="$(grep -oE 'environ\.get\("[A-Z_]+"' "$f" | sort -u | tr '\n' ' ')"
    [[ "$hit" == 'environ.get("CCTRL_HELPERS_FIXTURE_DIR" environ.get("CODEX_HOME" ' ]] || fail "unexpected environment reads: $hit"
    echo "ok: helper census has no kill/signal/write path"
}

test_task_ls_helper_footer() {
    local d="$TMPDIR/helper-footer" human json_off json_on rc_off rc_on
    _helper_census_fixture "$d"
    "$ROOT/cctrl" task ls --json >/dev/null 2>&1 || true   # prime: the first call initializes the host id
    rc_off=0; json_off="$("$ROOT/cctrl" task ls --json 2>/dev/null)" || rc_off=$?
    rc_on=0; json_on="$(CCTRL_HELPERS_FOOTER=on CCTRL_HELPERS_FIXTURE_DIR="$d" "$ROOT/cctrl" task ls --json 2>/dev/null)" || rc_on=$?
    [[ "$json_off" == "$json_on" && $rc_off -eq $rc_on ]] || fail "task ls --json must be identical with a flagged owner"
    human="$(CCTRL_HELPERS_FOOTER=on CCTRL_HELPERS_FIXTURE_DIR="$d" "$ROOT/cctrl" task ls 2>&1 || true)"
    [[ "$human" == *"MCP helpers:"* ]] || fail "human task ls lacks the footer: $human"
    human="$(CCTRL_HELPERS_FOOTER=off CCTRL_HELPERS_FIXTURE_DIR="$d" "$ROOT/cctrl" task ls 2>&1 || true)"
    [[ "$human" != *"MCP helpers:"* ]] || fail "footer must be switchable off"
    : > "$d/ps.txt"
    local rc_a=0 rc_b=0
    CCTRL_HELPERS_FOOTER=on CCTRL_HELPERS_FIXTURE_DIR="$d" "$ROOT/cctrl" task ls >/dev/null 2>&1 || rc_a=$?
    CCTRL_HELPERS_FOOTER=off "$ROOT/cctrl" task ls >/dev/null 2>&1 || rc_b=$?
    [[ $rc_a -eq $rc_b ]] || fail "a failed census changed task ls rc ($rc_a vs $rc_b)"
    echo "ok: task ls footer human-only, json identical, census failure keeps rc"
}

test_release_prune() {
    # plan 089: sandbox releases dir ONLY (CCTRL_HOME), stub ps/lsof/tmux; never
    # touches ~/.local/lib/cctrl.
    local dir="$TMPDIR/release-prune"
    local home="$dir/home" stubs="$dir/stubs" binhome="$dir/binhome" meta="$dir/meta" rt="$dir/rt" uhome="$dir/uhome"
    mkdir -p "$home/releases" "$stubs" "$binhome" "$meta" "$rt/cctrl-$(id -u)/profile-settings" "$uhome" "$dir/outside"
    echo keepme > "$dir/outside/precious"
    local n
    local -a names=(aaaaaaaaaaa1-20261001T000001Z bbbbbbbbbbb2-20261002T000002Z ccccccccccc3-20261003T000003Z
        ddddddddddd4-20261004T000004Z eeeeeeeeeee5-20261005T000005Z fffffffffff6-20261006T000006Z 00000000000a-20261007T000007Z)
    for n in "${names[@]}"; do
        mkdir -p "$home/releases/$n"; : > "$home/releases/$n/cctrl"; echo "$n" > "$home/releases/$n/VERSION"
    done
    mkdir -p "$home/releases/.tmp-999" "$home/releases/abababababa8-20261008T000008Z" "$home/releases/not-a-release"
    echo x > "$home/releases/.tmp-999/f"; echo x > "$home/releases/abababababa8-20261008T000008Z/cctrl"   # no VERSION: incomplete
    echo x > "$home/releases/not-a-release/f"
    ln -s "$dir/outside" "$home/releases/cdcdcdcdcdc9-20261009T000009Z"
    ln -s "releases/${names[6]}" "$home/current"
    printf '#!/bin/sh\nexec "%s/current/cctrl" "$@"\n' "$home" > "$binhome/cctrl"
    cat > "$stubs/ps" <<'SH'
#!/usr/bin/env bash
[[ -n "${FAKE_PS_FAIL:-}" ]] && exit 1
cat "${FAKE_PS_FILE:-/dev/null}"
echo "1 /sbin/launchd"
# plan 102: the tool must see its own pid ($PPID = the python module)
[[ -n "${FAKE_PS_NO_OWN:-}" ]] || echo "${FAKE_PS_OWN:-$PPID} /usr/bin/python3 release_prune.py"
SH
    cat > "$stubs/lsof" <<'SH'
#!/usr/bin/env bash
[[ -n "${FAKE_LSOF_FAIL:-}" ]] && exit 2
printf 'p1\nn/\n'
[[ -n "${FAKE_LSOF_NO_OWN:-}" ]] || printf 'p%s\nn/\n' "${FAKE_LSOF_OWN:-$PPID}"
[[ -n "${FAKE_LSOF_FILE:-}" ]] && cat "$FAKE_LSOF_FILE"
exit 0
SH
    cat > "$stubs/tmux" <<'SH'
#!/usr/bin/env bash
[[ "$1" == "list-sessions" ]] || exit 0
if [[ -n "${FAKE_TMUX_FAIL:-}" ]]; then echo "error connecting to /tmp/x (Permission denied)" >&2; exit 1; fi
for s in ${FAKE_TMUX_SESSIONS:-}; do echo "$s"; done
SH
    chmod +x "$stubs/ps" "$stubs/lsof" "$stubs/tmux"
    : > "$dir/ps.txt"
    local -a envv=(env HOME="$uhome" CCTRL_HOME="$home" CCTRL_BIN="$binhome/cctrl" CCTRL_SESSION_METADATA_DIR="$meta"
        CCTRL_RUNTIME_DIR="$rt" PATH="$stubs:$PATH" FAKE_PS_FILE="$dir/ps.txt")
    local out rc count

    # 1. dry run is the default and deletes nothing; keeps newest 3 + current.
    out="$("${envv[@]}" "$ROOT/cctrl" release prune --keep 3 --json)" || fail "dry run failed: $out"
    assert_contains "$(jq -r '.mode' <<< "$out")" "dry-run"
    [[ "$(jq -r '.kept | map(.name) | sort | join(",")' <<< "$out")" == "$(printf '%s\n' "${names[4]}" "${names[5]}" "${names[6]}" | sort | paste -sd, -)" ]] \
        || fail "keep 3 should keep the newest three: $(jq -c '.kept' <<< "$out")"
    [[ "$(jq -r '.would_delete | length' <<< "$out")" -eq 4 ]] || fail "expected 4 would_delete: $(jq -c . <<< "$out")"
    [[ "$(jq -r '.incomplete | map(.name) | sort | join(",")' <<< "$out")" == "$(printf '%s\n' .tmp-999 abababababa8-20261008T000008Z | sort | paste -sd, -)" ]] \
        || fail "incomplete dirs not reported: $(jq -c '.incomplete' <<< "$out")"
    for n in "${names[@]}"; do [[ -d "$home/releases/$n" ]] || fail "dry run removed $n"; done

    # 2. references keep a release regardless of age: process argv, live session
    #    metadata (dead-session metadata does NOT), settings overlay, bin symlink.
    printf '4242 /usr/bin/claude --mcp-config {"command":"%s/releases/%s/cctrl"}\n' "$home" "${names[0]}" > "$dir/ps.txt"
    # real-shaped registry records: task-<hex>.json keyed by `.name`
    printf '{"name":"TMUX--live","lifecycle_state":"active","launch_command":"%s/releases/%s/cctrl"}\n' "$home" "${names[1]}" > "$meta/task-aa11.json"
    printf '{"name":"TMUX--dead","lifecycle_state":"active","launch_command":"%s/releases/%s/cctrl"}\n' "$home" "${names[2]}" > "$meta/task-bb22.json"
    printf '{"name":"TMUX--live","lifecycle_state":"closed","launch_command":"%s/releases/%s/cctrl"}\n' "$home" "${names[4]}" > "$meta/task-cc33.json"
    printf '{"statusLine":"%s/releases/%s/cctrl"}\n' "$home" "${names[3]}" > "$rt/cctrl-$(id -u)/profile-settings/x.json"
    out="$(FAKE_TMUX_SESSIONS="TMUX--live" "${envv[@]}" FAKE_TMUX_SESSIONS="TMUX--live" "$ROOT/cctrl" release prune --keep 3 --json)" || fail "referenced dry run failed"
    [[ "$(jq -r '.would_delete | length' <<< "$out")" -eq 1 ]] || fail "only the dead-session release should remain deletable: $(jq -c '.would_delete,.kept' <<< "$out")"
    assert_contains "$(jq -r '.would_delete[0]' <<< "$out")" "${names[2]}"
    assert_contains "$(jq -r '.kept[] | select(.name=="'"${names[0]}"'") | .reasons | join(";")' <<< "$out")" "in use by process 4242 (claude)"
    assert_contains "$(jq -r '.kept[] | select(.name=="'"${names[1]}"'") | .reasons | join(";")' <<< "$out")" "session record task-aa11.json (TMUX--live)"
    assert_contains "$(jq -r '.kept[] | select(.name=="'"${names[3]}"'") | .reasons | join(";")' <<< "$out")" "settings overlay x.json"
    # a closed record of a live name must not pin (names[4] is in the keep-3 set anyway, so check names[4] via keep 2 below)
    ln -s "$home/releases/${names[2]}" "$dir/binhome/other-tool"
    out="$(FAKE_TMUX_SESSIONS="TMUX--live" "${envv[@]}" FAKE_TMUX_SESSIONS="TMUX--live" "$ROOT/cctrl" release prune --keep 3 --json)"
    [[ "$(jq -r '.would_delete | length' <<< "$out")" -eq 0 ]] || fail "bin symlink should keep ${names[2]}: $(jq -c '.would_delete' <<< "$out")"
    rm -f "$dir/binhome/other-tool"

    # 2b. more reference sources: open-file (lsof), user config; each pins its release.
    printf 'n%s/releases/%s/lib/x.sh\n' "$home" "${names[2]}" > "$dir/lsof.txt"
    out="$(FAKE_TMUX_SESSIONS="TMUX--live" "${envv[@]}" FAKE_LSOF_FILE="$dir/lsof.txt" FAKE_TMUX_SESSIONS="TMUX--live" "$ROOT/cctrl" release prune --keep 3 --json)"
    [[ "$(jq -r '.would_delete | length' <<< "$out")" -eq 0 ]] || fail "lsof open-file reference should keep ${names[2]}: $(jq -c '.would_delete' <<< "$out")"
    assert_contains "$(jq -r '.kept[] | select(.name=="'"${names[2]}"'") | .reasons | join(";")' <<< "$out")" "open file/cwd"
    rm -f "$dir/binhome/other-tool"
    printf '{"mcpServers":{"x":{"command":"%s/releases/%s/cctrl"}}}\n' "$home" "${names[2]}" > "$uhome/.claude.json"
    out="$(FAKE_TMUX_SESSIONS="TMUX--live" "${envv[@]}" FAKE_TMUX_SESSIONS="TMUX--live" "$ROOT/cctrl" release prune --keep 3 --json)"
    [[ "$(jq -r '.would_delete | length' <<< "$out")" -eq 0 ]] || fail "~/.claude.json reference should keep ${names[2]}"
    assert_contains "$(jq -r '.kept[] | select(.name=="'"${names[2]}"'") | .reasons | join(";")' <<< "$out")" "~/.claude.json"
    rm -f "$uhome/.claude.json"
    # closed record of a live name does not pin names[4]: keep 2 leaves names[4] deletable
    out="$(FAKE_TMUX_SESSIONS="TMUX--live" "${envv[@]}" FAKE_TMUX_SESSIONS="TMUX--live" "$ROOT/cctrl" release prune --keep 2 --json)"
    jq -e '.would_delete | index("'"${names[4]}"'")' <<< "$out" >/dev/null || fail "closed record must not pin ${names[4]}: $(jq -c '.would_delete' <<< "$out")"

    # 3a. tmux failing (not "no server") and unreadable/oversized files fail closed.
    rc=0; "${envv[@]}" FAKE_TMUX_FAIL=1 "$ROOT/cctrl" release prune --keep 1 --apply >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 69 ]] || fail "tmux error must exit 69, got $rc"
    printf '{}' > "$rt/cctrl-$(id -u)/profile-settings/locked.json"; chmod 000 "$rt/cctrl-$(id -u)/profile-settings/locked.json"
    rc=0; "${envv[@]}" "$ROOT/cctrl" release prune --keep 1 --apply >/dev/null 2>&1 || rc=$?
    chmod 600 "$rt/cctrl-$(id -u)/profile-settings/locked.json"; rm -f "$rt/cctrl-$(id -u)/profile-settings/locked.json"
    [[ "$rc" -eq 69 ]] || fail "unreadable overlay must exit 69, got $rc"
    for n in "${names[@]}"; do [[ -d "$home/releases/$n" ]] || fail "fail-closed run removed $n"; done
    rm -f "$meta"/*.json

    # 3. fail closed: an incomplete reference scan deletes nothing (exit 69), even with --apply.
    rc=0; out="$(FAKE_PS_FAIL=1 "${envv[@]}" FAKE_PS_FAIL=1 "$ROOT/cctrl" release prune --keep 1 --apply --json)" || rc=$?
    [[ "$rc" -eq 69 ]] || fail "failed ps scan must exit 69, got $rc"
    [[ "$(jq -r '.scan_complete' <<< "$out")" == false ]] || fail "scan_complete should be false"
    [[ "$(jq -r '(.deleted|length) + (.would_delete|length)' <<< "$out")" -eq 0 ]] || fail "fail-closed must propose no deletion"
    rc=0; "${envv[@]}" FAKE_LSOF_FAIL=1 "$ROOT/cctrl" release prune --keep 1 --apply >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 69 ]] || fail "failed lsof scan must exit 69, got $rc"
    for n in "${names[@]}"; do [[ -d "$home/releases/$n" ]] || fail "fail-closed run removed $n"; done

    # 3b. plan 102 hardening, every case fail closed (exit 69, nothing deleted), dry run AND apply.
    local mode
    for mode in "" --apply; do
        # a. dangling / outside-pointing / absent `current`
        mv "$home/current" "$dir/current.save"
        ln -s "releases/zzzzzzzzzzzz-20269999T000000Z" "$home/current"
        rc=0; "${envv[@]}" "$ROOT/cctrl" release prune --keep 1 $mode >/dev/null 2>&1 || rc=$?
        [[ "$rc" -eq 69 ]] || fail "dangling current must exit 69 ($mode), got $rc"
        rm -f "$home/current"; ln -s "$dir/outside" "$home/current"
        rc=0; out="$("${envv[@]}" "$ROOT/cctrl" release prune --keep 1 $mode --json 2>&1)" || rc=$?
        [[ "$rc" -eq 69 ]] || fail "outside-pointing current must exit 69 ($mode), got $rc"
        assert_contains "$out" "direct child"
        rm -f "$home/current"; ln -s "releases/${names[6]}/.." "$home/current"   # resolves to home, not a child of releases/
        rc=0; "${envv[@]}" "$ROOT/cctrl" release prune --keep 1 $mode >/dev/null 2>&1 || rc=$?
        [[ "$rc" -eq 69 ]] || fail "non-direct-child current must exit 69 ($mode), got $rc"
        rm -f "$home/current"
        rc=0; "${envv[@]}" "$ROOT/cctrl" release prune --keep 1 $mode >/dev/null 2>&1 || rc=$?
        [[ "$rc" -eq 69 ]] || fail "absent current must exit 69 ($mode), got $rc"
        mv "$dir/current.save" "$home/current"
        # b. own pid must be in the ps and the lsof output (exact match: a pid that merely
        #    contains ours as a substring does not count)
        rc=0; "${envv[@]}" FAKE_PS_NO_OWN=1 "$ROOT/cctrl" release prune --keep 1 $mode >/dev/null 2>&1 || rc=$?
        [[ "$rc" -eq 69 ]] || fail "ps output without own pid must exit 69 ($mode), got $rc"
        rc=0; "${envv[@]}" FAKE_LSOF_NO_OWN=1 "$ROOT/cctrl" release prune --keep 1 $mode >/dev/null 2>&1 || rc=$?
        [[ "$rc" -eq 69 ]] || fail "lsof output without own pid must exit 69 ($mode), got $rc"
        # c. missing bin dir / registry (data) dir are scan errors
        mv "$binhome" "$dir/binhome.save"
        rc=0; "${envv[@]}" "$ROOT/cctrl" release prune --keep 1 $mode >/dev/null 2>&1 || rc=$?
        mv "$dir/binhome.save" "$binhome"
        [[ "$rc" -eq 69 ]] || fail "missing bin dir must exit 69 ($mode), got $rc"
        mv "$meta" "$dir/meta.save"
        rc=0; "${envv[@]}" "$ROOT/cctrl" release prune --keep 1 $mode >/dev/null 2>&1 || rc=$?
        mv "$dir/meta.save" "$meta"
        [[ "$rc" -eq 69 ]] || fail "missing registry dir must exit 69 ($mode), got $rc"
        for n in "${names[@]}"; do [[ -d "$home/releases/$n" ]] || fail "plan-102 fail-closed run removed $n ($mode)"; done
    done
    # b (positive control, and the substring case run through the module directly with a pid-prefix stub)
    cat > "$stubs/ps-prefix" <<'SH'
#!/usr/bin/env bash
echo "${PPID}9 /usr/bin/python3 other"
echo "1 /sbin/launchd"
SH
    mkdir -p "$dir/prefix-stubs"; cp "$stubs/lsof" "$stubs/tmux" "$dir/prefix-stubs/"; cp "$stubs/ps-prefix" "$dir/prefix-stubs/ps"; chmod +x "$dir/prefix-stubs/"*
    rc=0; "${envv[@]}" PATH="$dir/prefix-stubs:$PATH" "$ROOT/cctrl" release prune --keep 1 --apply >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 69 ]] || fail "ps line for pid '<own>9' must not satisfy the own-pid check, got $rc"
    printf '#!/usr/bin/env bash\nprintf "p1\\nn/\\np%%s9\\nn/\\n" "$PPID"\n' > "$dir/prefix-stubs/lsof"; cp "$stubs/ps" "$dir/prefix-stubs/ps"
    rc=0; "${envv[@]}" PATH="$dir/prefix-stubs:$PATH" "$ROOT/cctrl" release prune --keep 1 --apply >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 69 ]] || fail "lsof pid '<own>9' must not satisfy the own-pid check, got $rc"
    # d. no flag abbreviations when the module is called directly
    for n in --app --kee --js; do
        rc=0; python3 "$ROOT/lib/release_prune.py" --home "$home" --bin "$binhome/cctrl" --data-dir "$meta" \
            --runtime-settings-dir "$rt" "$n" 1 >/dev/null 2>&1 || rc=$?
        [[ "$rc" -eq 2 ]] || fail "module must reject abbreviation $n (argparse exit 2), got $rc"
    done
    for n in "${names[@]}"; do [[ -d "$home/releases/$n" ]] || fail "abbreviation/prefix run removed $n"; done
    # the optional overlay dir: absent is fine (plan 102 documents why)
    mv "$rt/cctrl-$(id -u)/profile-settings" "$dir/ps-overlay.save"
    rc=0; "${envv[@]}" "$ROOT/cctrl" release prune --keep 1 >/dev/null 2>&1 || rc=$?
    mv "$dir/ps-overlay.save" "$rt/cctrl-$(id -u)/profile-settings"
    [[ "$rc" -eq 0 ]] || fail "absent overlay dir is legitimately optional, got $rc"

    # 4. --apply deletes exactly the unreferenced, complete, older releases.
    : > "$dir/ps.txt"; rm -f "$meta"/*.json "$rt/cctrl-$(id -u)/profile-settings/x.json"
    out="$("${envv[@]}" "$ROOT/cctrl" release prune --keep 2 --apply --json)" || fail "apply failed: $out"
    [[ "$(jq -r '.deleted | sort | join(",")' <<< "$out")" == "$(printf '%s\n' "${names[@]:0:5}" | sort | paste -sd, -)" ]] \
        || fail "apply deleted the wrong set: $(jq -c '.deleted' <<< "$out")"
    for n in "${names[5]}" "${names[6]}"; do [[ -d "$home/releases/$n" ]] || fail "apply removed kept release $n"; done
    for n in "${names[0]}" "${names[4]}"; do [[ ! -e "$home/releases/$n" ]] || fail "apply left $n"; done
    [[ -d "$home/releases/.tmp-999" && -d "$home/releases/abababababa8-20261008T000008Z" && -d "$home/releases/not-a-release" ]] \
        || fail "apply must not touch incomplete/unrecognized dirs"
    [[ -L "$home/releases/cdcdcdcdcdc9-20261009T000009Z" && -f "$dir/outside/precious" ]] || fail "apply must not follow or remove a symlink entry"
    [[ "$(readlink "$home/current")" == "releases/${names[6]}" ]] || fail "current changed"

    # 5. current's target survives even with --keep 0.
    out="$("${envv[@]}" "$ROOT/cctrl" release prune --keep 0 --apply --json)" || fail "keep 0 apply failed"
    [[ -d "$home/releases/${names[6]}" ]] || fail "--keep 0 must still keep current's target"

    # 5b. direct guard checks (symlink, outside path, current target, empty dir, bad name) and an
    #     apply-time failure that must stop with exit 70 and a report, not a traceback.
    local g="$dir/guards"; mkdir -p "$g/releases/abababababab-20261001T000001Z" "$g/releases/cdcdcdcdcdcd-20261001T000002Z" "$g/elsewhere/ededededeaed-20261001T000003Z"
    : > "$g/releases/abababababab-20261001T000001Z/f"; : > "$g/elsewhere/ededededeaed-20261001T000003Z/f"
    ln -s "$g/elsewhere/ededededeaed-20261001T000003Z" "$g/releases/ededededeaed-20261001T000003Z"
    out="$(python3 -I - "$ROOT/lib" "$g" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import release_prune as r
g = sys.argv[2]; rd = g + "/releases"; real = os.path.realpath(rd)
cur = os.path.realpath(rd + "/abababababab-20261001T000001Z")
res = {
 "ok": r.safe_to_delete(rd, real, "cdcdcdcdcdcd-20261001T000002Z", cur)[0],   # empty dir -> refuse
 "empty": r.safe_to_delete(rd, real, "cdcdcdcdcdcd-20261001T000002Z", None)[0],
 "cur": r.safe_to_delete(rd, real, "abababababab-20261001T000001Z", cur)[0],
 "symlink": r.safe_to_delete(rd, real, "ededededeaed-20261001T000003Z", None)[0],
 "badname": r.safe_to_delete(rd, real, "../elsewhere", None)[0],
 "good": r.safe_to_delete(rd, real, "abababababab-20261001T000001Z", None)[0],
}
print(" ".join("%s=%s" % kv for kv in sorted(res.items())))
PY
)"
    [[ "$out" == "badname=False cur=False empty=False good=True ok=False symlink=False" ]] || fail "safe_to_delete guards wrong: $out"
    mkdir -p "$home/releases/123456789abc-20260101T000001Z"; : > "$home/releases/123456789abc-20260101T000001Z/cctrl"; echo v > "$home/releases/123456789abc-20260101T000001Z/VERSION"
    rc=0; out="$(python3 -I - "$ROOT/lib" "$home" "$binhome/cctrl" "$meta" "$rt/cctrl-$(id -u)/profile-settings" "$stubs" <<'PY' 2>&1
import os, sys
sys.path.insert(0, sys.argv[1]); os.environ["PATH"] = sys.argv[6] + os.pathsep + os.environ["PATH"]
os.environ["FAKE_PS_FILE"] = "/dev/null"
import shutil, release_prune as r
def boom(path, *a, **k): raise PermissionError("denied")
shutil.rmtree = boom
sys.argv = ["x", "--home", sys.argv[2], "--bin", sys.argv[3], "--data-dir", sys.argv[4], "--runtime-settings-dir", sys.argv[5], "--keep", "0", "--apply"]
sys.exit(r.main())
PY
)" || rc=$?
    [[ "$rc" -eq 70 ]] || fail "apply-time delete failure must exit 70, got $rc: $out"
    assert_contains "$out" "FAILED deleting"
    [[ -d "$home/releases/123456789abc-20260101T000001Z" ]] || fail "failed delete should leave the dir (monkeypatched rmtree)"

    # 6. never auto-run from the installer; bad flags refused.
    ! grep -q "release prune" "$ROOT/install/self-install.sh" || fail "self-install.sh must not run release prune"
    rc=0; "${envv[@]}" "$ROOT/cctrl" release prune --keep x >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 64 ]] || fail "bad --keep should exit 64, got $rc"
    echo "ok: release prune is dry-run by default, fails closed, honors references, and deletes only guarded complete releases"
}

test_no_errexit_unsafe_post_increment() {
    # Under bash >= 4.1 with `set -e`, a standalone `((x++))` whose old value
    # is 0 evaluates to 0, returns status 1, and exits the script. bash 3.2
    # (macOS /bin/bash) never tripped on it, so it went unnoticed until a
    # Homebrew bash 5 landed first on PATH and `cctrl --host H @shortcut`
    # started exiting 1 silently. Use `x=$((x + 1))` instead.
    local hits
    hits="$(cd "$ROOT" && grep -nE '\(\( *[A-Za-z_][A-Za-z_0-9]*(\+\+|--) *\)\)' cctrl lib/*.sh hooks/*.sh install/*.sh 2>/dev/null || true)"
    [[ -z "$hits" ]] || fail "errexit-unsafe ((x++))/((x--)) (use x=\$((x + 1))):
$hits"
    echo "ok: no errexit-unsafe ((x++)) post-increments in shipped bash"
}

test_live_store_guard_diagnostics_and_churn() {
    # plan 090: the live-store guard names what changed, tolerates live-fleet
    # registry churn it can't have caused, and still catches the test's own
    # writes -- including through a symlinked root, as in the install gate.
    local root="$TMPDIR/live-guard-fixture" link="$TMPDIR/live-guard-link" before after out rc
    mkdir -p "$root/sessions" "$root/snapshots"
    printf '{"k":1}\n' > "$root/config.json"
    printf '{"purpose":"live"}\n' > "$root/sessions/TMUX--ms--other.json"
    ln -s "$root" "$link"

    before="$(live_tree_manifest "$link")"
    assert_contains "$before" "link:$root"
    assert_contains "$before" "$link/sessions/TMUX--ms--other.json" # walked through the link

    # Live-fleet churn only: another session's record, the needs-me poll, the
    # snapshot timer. Tolerated, and reported as such.
    printf '{"purpose":"live","heartbeat":2}\n' > "$root/sessions/TMUX--ms--other.json"
    printf 'task-abc.json\n' > "$root/sessions/.session-index-abc.ref"
    printf '{}\n' > "$root/needs-me-snapshot.json"
    printf '{}\n' > "$root/snapshots/latest.json"
    mkdir -p "$root/sessions/.task-registry-locks"
    printf '1 2 tok\n' > "$root/sessions/.task-registry-locks/k.lock"
    printf '{}\n' > "$root/sessions/.task-event.x1"
    after="$(live_tree_manifest "$link")"
    out="$(live_store_changes "$before" "$after" TMUX--owned 2>&1)" || fail "guard flagged pure live-fleet churn: $out"
    assert_contains "$out" "ignored 5 live-fleet registry change(s)"

    # A record named after the test's own session is caught.
    before="$after"
    printf '{"purpose":"x"}\n' > "$root/sessions/TMUX--owned.json"
    after="$(live_tree_manifest "$link")"
    rc=0; out="$(live_store_changes "$before" "$after" TMUX--owned)" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "guard missed a write to the test's own session record"
    assert_contains "$out" "added: $link/sessions/TMUX--owned.json"

    # A record carrying this run's TMPDIR is caught whatever its name.
    before="$after"
    printf '{"dir":"%s/project"}\n' "$TMPDIR" > "$root/sessions/TMUX--leaked.json"
    after="$(live_tree_manifest "$link")"
    rc=0; out="$(live_store_changes "$before" "$after")" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "guard missed a registry record that references the test TMPDIR"
    assert_contains "$out" "added: $link/sessions/TMUX--leaked.json"

    # Deleting a live registry record is never churn (a leaked close/prune).
    before="$after"
    rm -f -- "$root/sessions/TMUX--ms--other.json"
    after="$(live_tree_manifest "$link")"
    rc=0; out="$(live_store_changes "$before" "$after")" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "guard tolerated a removed live registry record"
    assert_contains "$out" "removed: $link/sessions/TMUX--ms--other.json"

    # Anything outside data/sessions/ is never churn; the report says how it changed.
    before="$after"
    printf '{"k":2}\n' > "$root/config.json"
    after="$(live_tree_manifest "$link")"
    rc=0; out="$(live_store_changes "$before" "$after")" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "guard missed a modified config.json"
    assert_contains "$out" "modified: $link/config.json"

    rc=0; out="$( (assert_live_store_unchanged "$before" "$after" "fixture changed the store") 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "assert_live_store_unchanged passed a real change"
    assert_contains "$out" "FAIL: fixture changed the store; changed paths:"
    assert_contains "$out" "modified: $link/config.json"
    echo "ok: live-store guard lists changed paths, tolerates registry churn, catches own writes"
}

test_tmux_exact_target_lint() {
    # plan 080 (reworked after an Opus eng review found the first pass wrong):
    # tmux's `-t NAME` falls back to prefix matching when no session named
    # exactly NAME exists, so `tmux kill-session -t TMUX--ms--cctrl` can
    # silently kill a still-live `TMUX--ms--cctrl--2`. Every `tmux ... -t
    # "$NAME"` call must use tmux's real exact-match syntax instead — and
    # that syntax differs by subcommand (verified directly against tmux
    # 3.7c, not guessed):
    #   - has-session / kill-session / attach-session (session-scoped): the
    #     bare exact form `-t "=$NAME"` (no trailing ":") is correct.
    #   - every other subcommand (capture-pane, send-keys, paste-buffer,
    #     set-option, show-option, display-message, display, list-panes,
    #     and any other pane/window-target subcommand) additionally
    #     REQUIRES the trailing ":" — `-t "=$NAME:"` — without it the
    #     target fails outright or silently resolves to nothing. A prior
    #     version of this check only verified an "=" was present anywhere,
    #     which let a broken all-bare-no-colon implementation pass its own
    #     tests; it now checks the exact form per subcommand.
    # A handful of sites legitimately target an already-exact value (a
    # literal tmux "$N" session id, or a pane id) rather than a
    # session-name string; those are marked inline with
    # `# tmux-target:exact-id` so this check can tell a real exception from
    # a reintroduced bug.
    local out script="$TMPDIR/tmux_exact_target_lint.py"
    cat > "$script" <<'PY'
import glob, os, re, sys

root = sys.argv[1]
files = [os.path.join(root, "cctrl")] + sorted(glob.glob(os.path.join(root, "lib", "*.sh")))

# A tmux invocation clause: "tmux" (or the timeout-wrapped helper) optionally
# followed by "-u", then the subcommand word, then a run of characters that
# doesn't cross a pipe/backgrounding boundary, up to a quoted -t target.
# Capturing the subcommand alongside the target (rather than just scanning
# for any "-t \"...\"" on the line) means a -t belonging to an unrelated
# command earlier on the same line — e.g. `ssh -t "$x" "... tmux ... -t
# \"$y\""` — is never mistaken for a tmux target, and vice versa. Brace
# expansion (${sessions[0]}) is matched, not just a bare $NAME.
CLAUSE_RE = re.compile(
    r'(?:\btmux\b|_tmux_run_with_timeout)\s+(?:-u\s+)?(?P<cmd>[a-z][a-z-]*)\b'
    r'[^|&\n]*?-t\s+"(?P<tgt>[^"]*)"'
)

SESSION_SCOPED = {"has-session", "kill-session", "attach-session"}

errors = []

for path in files:
    if not os.path.isfile(path):
        continue
    with open(path) as f:
        lines = f.readlines()
    for lineno, line in enumerate(lines, 1):
        if "# tmux-target:exact-id" in line:
            continue
        for m in CLAUSE_RE.finditer(line):
            cmd = m.group("cmd")
            tgt = m.group("tgt")
            is_exact = tgt.startswith("=")
            body = tgt[1:] if is_exact else tgt
            # Only variable-shaped targets ($NAME or ${NAME[...]}) are in
            # scope; a literal constant string is not what this check is for.
            if not body.startswith("$"):
                continue
            if not is_exact:
                errors.append(
                    f'{path}:{lineno}: bare (prefix-matchable) tmux {cmd} -t "{tgt}" — '
                    f'use -t "={tgt}" (session-scoped: has-session/kill-session/'
                    f'attach-session) or -t "={tgt}:" (every other subcommand), or mark '
                    f"a genuinely pre-exact id/pane target with '# tmux-target:exact-id'"
                )
                continue
            if cmd in SESSION_SCOPED:
                continue  # bare "=NAME" (no trailing ":") is correct here
            if ":" not in body:
                errors.append(
                    f'{path}:{lineno}: tmux {cmd} -t "{tgt}" is missing the trailing ":" '
                    f'required for this pane/window-target subcommand — use -t "{tgt}:" '
                    f"(or mark a genuinely pre-exact target with '# tmux-target:exact-id')"
                )

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
    out="$(python3 "$script" "$ROOT")" || true
    if [[ -n "$out" ]]; then
        fail "tmux -t target(s) using the wrong exact-match form (plan 080 review):
$out"
    fi
    echo "ok: every tmux -t target in cctrl and lib/*.sh uses the exact-match form its subcommand requires"
}

# install/cctrl-launcher.sh is the tiny tracked file that becomes
# ~/.local/bin/cctrl (see docs/plans/079). These tests exercise it directly
# via `bash install/cctrl-launcher.sh`, pointing CCTRL_HOME at a scratch
# directory -- never the real ~/.local/lib/cctrl.

test_cctrl_launcher_hooks_run_fails_open_on_broken_release() {
    local home="$TMPDIR/launcher-broken" out rc=0
    mkdir -p "$home/current"
    # A bad shebang (bad interpreter, exit 127) rather than a bash syntax
    # error (bash itself exits 2 on those, which would collide with the
    # deliberate exit-2 passthrough added by docs/plans/083 and make this
    # "broken/unrunnable release" case indistinguishable from a real block).
    cat > "$home/current/cctrl" <<'SH'
#!/nonexistent/interpreter-xyz
echo hi
SH
    chmod +x "$home/current/cctrl"

    out="$(CCTRL_HOME="$home" bash "$ROOT/install/cctrl-launcher.sh" hooks run pre-tool-use 2>&1)" || rc=$?
    [[ $rc -eq 0 ]] || fail "expected launcher to fail open (exit 0) on a broken release, got $rc: $out"
    assert_contains "$out" "failing open"
}

test_cctrl_launcher_hooks_run_passes_deliberate_exit_through() {
    local home="$TMPDIR/launcher-exit1" rc=0
    mkdir -p "$home/current"
    cat > "$home/current/cctrl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    chmod +x "$home/current/cctrl"

    CCTRL_HOME="$home" bash "$ROOT/install/cctrl-launcher.sh" hooks run pre-tool-use >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 1 ]] || fail "expected a deliberate exit 1 to pass through unchanged, got $rc"
}

test_cctrl_launcher_hooks_run_fails_open_on_unexpected_exit() {
    local home="$TMPDIR/launcher-exit137" out rc=0
    mkdir -p "$home/current"
    cat > "$home/current/cctrl" <<'SH'
#!/usr/bin/env bash
exit 137
SH
    chmod +x "$home/current/cctrl"

    out="$(CCTRL_HOME="$home" bash "$ROOT/install/cctrl-launcher.sh" hooks run pre-tool-use 2>&1)" || rc=$?
    [[ $rc -eq 0 ]] || fail "expected an unexpected exit code to fail open (exit 0), got $rc: $out"
    assert_contains "$out" "failing open"
}

test_cctrl_launcher_non_hooks_run_commands_fail_loudly() {
    local home="$TMPDIR/launcher-passthrough" out rc=0
    mkdir -p "$home/current"
    cat > "$home/current/cctrl" <<'SH'
#!/usr/bin/env bash
echo "real cctrl invoked with: $*"
exit 3
SH
    chmod +x "$home/current/cctrl"

    out="$(CCTRL_HOME="$home" bash "$ROOT/install/cctrl-launcher.sh" session ls 2>&1)" || rc=$?
    [[ $rc -eq 3 ]] || fail "expected non-'hooks run' commands to fail loudly with the real exit code, got $rc: $out"
    assert_contains "$out" "real cctrl invoked with: session ls"
}

test_cctrl_launcher_hooks_run_fails_open_when_release_missing() {
    local home="$TMPDIR/launcher-missing" out rc=0
    mkdir -p "$home"

    out="$(CCTRL_HOME="$home" bash "$ROOT/install/cctrl-launcher.sh" hooks run stop 2>&1)" || rc=$?
    [[ $rc -eq 0 ]] || fail "expected a missing release to fail open (exit 0), got $rc: $out"
    assert_contains "$out" "failing open"
}

# docs/plans/083: the launcher must pass a deliberate exit 2 (Claude Code's
# real "block" code) through unchanged, never downgrading it to "allow".
test_cctrl_launcher_hooks_run_passes_exit_2_through() {
    local home="$TMPDIR/launcher-exit2" rc=0
    mkdir -p "$home/current"
    cat > "$home/current/cctrl" <<'SH'
#!/usr/bin/env bash
exit 2
SH
    chmod +x "$home/current/cctrl"

    CCTRL_HOME="$home" bash "$ROOT/install/cctrl-launcher.sh" hooks run pre-tool-use >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 2 ]] || fail "expected a deliberate exit 2 to pass through unchanged, got $rc"
}

# docs/plans/083: every other unexpected code (not 0/1/2) must still fail
# open -- adding 2 to the passthrough set must not widen it further.
test_cctrl_launcher_hooks_run_fails_open_on_exit_42() {
    local home="$TMPDIR/launcher-exit42" out rc=0
    mkdir -p "$home/current"
    cat > "$home/current/cctrl" <<'SH'
#!/usr/bin/env bash
exit 42
SH
    chmod +x "$home/current/cctrl"

    out="$(CCTRL_HOME="$home" bash "$ROOT/install/cctrl-launcher.sh" hooks run pre-tool-use 2>&1)" || rc=$?
    [[ $rc -eq 0 ]] || fail "expected exit 42 (not in 0/1/2) to fail open (exit 0), got $rc: $out"
    assert_contains "$out" "failing open"
}

# docs/plans/079's "Hook exit-code convention" note and docs/plans/088: if a
# release's target hook script is missing, `_hooks_run pre-tool-use`'s `exec
# python3 "$SCRIPT_DIR/hooks/block-git-commit.py"` itself exits 2 (python3's
# own file-not-found code) with no marker distinguishing it from a
# deliberate block. Pins the real mechanism, not just the launcher's generic
# exit-2 passthrough (already covered by
# test_cctrl_launcher_hooks_run_passes_exit_2_through with a fabricated stub).
test_cctrl_hooks_run_exits_2_when_target_hook_script_missing() {
    local home="$TMPDIR/hooks-missing-script" out rc=0
    mkdir -p "$home/current"
    cp "$ROOT/cctrl" "$home/current/cctrl"
    chmod +x "$home/current/cctrl"
    # Deliberately no hooks/ dir under $home/current/.

    out="$("$home/current/cctrl" hooks run pre-tool-use 2>&1)" || rc=$?
    [[ $rc -eq 2 ]] || fail "expected a missing target hook script to make cctrl exit 2 (python3's own file-not-found code), got $rc: $out"
    assert_contains "$out" "block-git-commit.py"

    rc=0
    CCTRL_HOME="$home" bash "$ROOT/install/cctrl-launcher.sh" hooks run pre-tool-use >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 2 ]] || fail "expected the launcher to pass the missing-script exit 2 through unchanged (indistinguishable from a deliberate block), got $rc"
}

# install/self-install.sh's atomic `current` swap: on macOS/BSD, a plain
# `mv -f x current` follows `current` (a symlink to a directory) instead of
# replacing it, silently leaving `current` on the old release. This
# regression-tests the exact swap sequence self-install.sh uses.
test_cctrl_current_swap_is_atomic_on_bsd_mv() {
    local home="$TMPDIR/swap-home"
    mkdir -p "$home/releases/rel-a" "$home/releases/rel-b"

    local swap
    swap() {
        local target="$1"
        rm -f "$home/current.next"
        ln -s "releases/$target" "$home/current.next"
        mv -fh "$home/current.next" "$home/current"
    }

    swap rel-a
    [[ "$(readlink "$home/current")" == "releases/rel-a" ]] \
        || fail "first swap: expected current -> releases/rel-a, got $(readlink "$home/current")"

    swap rel-b
    [[ "$(readlink "$home/current")" == "releases/rel-b" ]] \
        || fail "second swap: expected current -> releases/rel-b, got $(readlink "$home/current")"
    [[ ! -e "$home/releases/rel-a/current.next" ]] \
        || fail "swap regressed to the BSD mv bug: current.next ended up inside the old release"
}

# install/self-install.sh refuses to build a release from a dirty tree
# (uncommitted changes to tracked files) using `git status --porcelain
# --untracked-files=no`. This exercises that exact check against a real
# git fixture rather than the full self-install.sh (which also runs the
# entire suite internally and would make this test recursive).
test_git_dirty_check_matches_self_install_semantics() {
    local repo="$TMPDIR/dirty-check-repo"
    mkdir -p "$repo"
    (cd "$repo" && git init -q && git config user.email t@t.co && git config user.name t \
        && echo hi > f.txt && git add f.txt && git commit -q -m init)

    [[ -z "$(cd "$repo" && git status --porcelain --untracked-files=no)" ]] \
        || fail "expected a freshly committed repo to report clean"

    (cd "$repo" && echo changed > f.txt)
    [[ -n "$(cd "$repo" && git status --porcelain --untracked-files=no)" ]] \
        || fail "expected a modified tracked file to be detected as dirty"
    (cd "$repo" && git checkout -q -- f.txt)

    (cd "$repo" && echo untracked > new.txt)
    [[ -z "$(cd "$repo" && git status --porcelain --untracked-files=no)" ]] \
        || fail "expected an untracked file alone not to count as dirty (data/costs/profiles/.active-profile are gitignored and must not block install)"
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

    # --profile none: this test isn't exercising profile resolution, and
    # invoking "$ROOT/cctrl" directly without an explicit --profile falls
    # through to whatever legacy/default profile this machine happens to
    # have (see the phase-4 handoff hazard note) -- which, as of phase 5,
    # would add a --settings flag and shift every ARG index below.
    out="$(PATH="$TMPDIR:$PATH" "$ROOT/cctrl" start --foreground --agent claude --profile none --model sonnet --yolo --no-bridge -m "fix bug")"
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

test_launch_env_scrub_claude() {
    # plan 071 phase 4: every launch scrubs inherited CLAUDE_*/ANTHROPIC_*/
    # CLAUDECODE env before applying the resolved profile's overlay, so a
    # profile's own values always win and an unprofiled launch never
    # silently inherits a leaked provider var. CLAUDE_CONFIG_DIR is kept by
    # default (already exported globally by this harness, D7); AWS_PROFILE
    # is never touched (wrong prefix).
    make_fake_agent "$TMPDIR/claude" claude
    local profiles="$TMPDIR/launch-scrub-profiles"
    mkdir -p "$profiles"
    printf '{"agents":{"claude":{"env":{"CLAUDE_CODE_USE_BEDROCK":"1","ANTHROPIC_MODEL":"bedrock-model"}}}}\n' \
        > "$profiles/work.json"
    local names="CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_ENTRYPOINT CLAUDE_EFFORT CLAUDE_CODE_DISABLE_TERMINAL_TITLE CLAUDECODE CLAUDE_CONFIG_DIR AWS_PROFILE CCTRL_SESSION_PROFILE CCTRL_SESSION_PROFILE_SOURCE CCTRL_SESSION_AUTH_BACKEND"

    # No profile: a leaked provider var from the caller's shell must not survive.
    local out
    out="$(CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_EFFORT=high \
        CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 CLAUDECODE=1 AWS_PROFILE=keepme \
        FAKE_AGENT_ENV_NAMES="$names" PATH="$TMPDIR:$PATH" \
        "$ROOT/cctrl" start --foreground --agent claude --profile none -m scrub)"
    assert_contains "$out" "ENV_CLAUDE_CODE_USE_BEDROCK=<unset>"
    assert_contains "$out" "ENV_CLAUDE_CODE_ENTRYPOINT=<unset>"
    assert_contains "$out" "ENV_CLAUDE_EFFORT=<unset>"
    assert_contains "$out" "ENV_CLAUDE_CODE_DISABLE_TERMINAL_TITLE=<unset>"
    assert_contains "$out" "ENV_CLAUDECODE=<unset>"
    assert_contains "$out" "ENV_AWS_PROFILE=keepme"
    assert_contains "$out" "ENV_CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"
    assert_contains "$out" "ENV_CCTRL_SESSION_PROFILE=none"
    assert_contains "$out" "ENV_CCTRL_SESSION_PROFILE_SOURCE=explicit"
    assert_contains "$out" "ENV_CCTRL_SESSION_AUTH_BACKEND=subscription"

    # --profile work: the scrub runs first, then the profile overlay -- its
    # own CLAUDE_CODE_USE_BEDROCK must survive (ordering guard).
    out="$(CLAUDE_CODE_USE_BEDROCK=0 FAKE_AGENT_ENV_NAMES="$names" PATH="$TMPDIR:$PATH" \
        CCTRL_PROFILES_DIR="$profiles" \
        "$ROOT/cctrl" start --foreground --agent claude --profile work -m scrub)"
    assert_contains "$out" "ENV_CLAUDE_CODE_USE_BEDROCK=1"
    assert_contains "$out" "ENV_CCTRL_SESSION_PROFILE=work"
    assert_contains "$out" "ENV_CCTRL_SESSION_PROFILE_SOURCE=explicit"
    assert_contains "$out" "ENV_CCTRL_SESSION_AUTH_BACKEND=bedrock"

    # CCTRL_KEEP_HOST_ENV=1 skips the scrub entirely.
    out="$(CLAUDE_CODE_USE_BEDROCK=1 CCTRL_KEEP_HOST_ENV=1 FAKE_AGENT_ENV_NAMES="$names" \
        PATH="$TMPDIR:$PATH" "$ROOT/cctrl" start --foreground --agent claude --profile none -m scrub)"
    assert_contains "$out" "ENV_CLAUDE_CODE_USE_BEDROCK=1"

    # A config launchEnvKeep entry is kept even without CCTRL_KEEP_HOST_ENV.
    local rootcopy="$TMPDIR/cctrl-launch-scrub-keep-copy"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    printf '{"launchEnvKeep":["ANTHROPIC_LOG"]}\n' > "$rootcopy/data/config.json"
    out="$(ANTHROPIC_LOG=debug CCTRL_USER_CONFIG="" CCTRL_CONFIG_LOCAL="$rootcopy/data/config.local.json" \
        FAKE_AGENT_ENV_NAMES="ANTHROPIC_LOG" PATH="$TMPDIR:$PATH" \
        "$rootcopy/cctrl" start --foreground --agent claude --profile none -m scrub)"
    assert_contains "$out" "ENV_ANTHROPIC_LOG=debug"
}

test_launch_env_scrub_codex() {
    # Same scrub applies to codex (D2); the CLAUDE_*/ANTHROPIC_* prefixes
    # don't overlap CODEX_*, so CODEX_HOME is untouched.
    make_fake_agent "$TMPDIR/codex" codex
    local out
    out="$(ANTHROPIC_API_KEY=sk-leaked CODEX_HOME="$TMPDIR/codex-home" \
        FAKE_AGENT_ENV_NAMES="ANTHROPIC_API_KEY CODEX_HOME CCTRL_SESSION_AUTH_BACKEND" \
        PATH="$TMPDIR:$PATH" "$ROOT/cctrl" start --foreground --agent codex --profile none -m scrub)"
    assert_contains "$out" "ENV_ANTHROPIC_API_KEY=<unset>"
    assert_contains "$out" "ENV_CODEX_HOME=$TMPDIR/codex-home"
    assert_contains "$out" "ENV_CCTRL_SESSION_AUTH_BACKEND=codex"
}

test_launch_env_scrub_source_label_not_inherited() {
    # R1: labels are always freshly derived at launch, never read back from
    # an already-exported CCTRL_SESSION_PROFILE_SOURCE -- so a later launch
    # inside an already-labelled session (e.g. a nested foreground run) can't
    # inherit a stale source from a previous one in the same process/env.
    make_fake_agent "$TMPDIR/claude" claude
    local profiles="$TMPDIR/launch-scrub-nested-profiles"
    mkdir -p "$profiles"
    printf '{}\n' > "$profiles/work.json"
    local out
    out="$(CCTRL_SESSION_PROFILE_SOURCE=default CCTRL_PROFILES_DIR="$profiles" \
        FAKE_AGENT_ENV_NAMES="CCTRL_SESSION_PROFILE_SOURCE" PATH="$TMPDIR:$PATH" \
        "$ROOT/cctrl" start --foreground --agent claude --profile work -m nested)"
    assert_contains "$out" "ENV_CCTRL_SESSION_PROFILE_SOURCE=explicit"
}

test_launch_env_scrub_dir_adopted_profile_source_handoff() {
    # R1: a detached dir launch that adopts a matching shortcut's profile
    # forwards it to its child as an explicit --profile flag, plus a
    # one-shot CCTRL_LAUNCH_PROFILE_SOURCE=shortcut so the child's label
    # reads source=shortcut, not source=explicit.
    make_fake_tmux "$TMPDIR/tmux"
    local rootcopy="$TMPDIR/cctrl-dir-adopt-copy"
    local project="$TMPDIR/dir-adopt-project"
    local log="$TMPDIR/dir-adopt-tmux.log"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$project"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    printf '{"adopted":{"dir":"%s","profile":"work","agent":"codex"}}\n' "$project" > "$rootcopy/data/shortcuts.json"
    printf '{}\n' > "$rootcopy/profiles/work.json"
    # Dir-adoption only adopts the matched shortcut's .profile, not its
    # .agent (that part of the shortcut's "agent" field above is unused
    # here) -- supply an agent some other way so resolution doesn't prompt.
    printf '{"defaultAgent":"codex"}\n' > "$rootcopy/data/config.json"

    : > "$log"
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" "$rootcopy/cctrl" start -d "$project" >/dev/null
    assert_contains "$(cat "$log")" "CCTRL_LAUNCH_PROFILE_SOURCE=shortcut"
    assert_contains "$(cat "$log")" "--profile work"
}

test_shortcut_profile_none_is_explicit_no_overlay() {
    # fm-cctrl design decision (2026-10-02): a shortcut's own `.profile:
    # "none"` is an explicit no-overlay, matching `--profile none` -- not an
    # unknown-profile failure.
    make_fake_agent "$TMPDIR/claude" claude
    local rootcopy="$TMPDIR/cctrl-shortcut-none-copy"
    local project="$TMPDIR/shortcut-none-project"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$project"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    printf '{"noprof":{"dir":"%s","profile":"none","agent":"claude"}}\n' "$project" > "$rootcopy/data/shortcuts.json"

    local out
    out="$(FAKE_AGENT_ENV_NAMES="CCTRL_SESSION_PROFILE CCTRL_SESSION_PROFILE_SOURCE" \
        PATH="$TMPDIR:$PATH" "$rootcopy/cctrl" @noprof --foreground)"
    assert_contains "$out" "CMD=claude"
    assert_contains "$out" "ENV_CCTRL_SESSION_PROFILE=none"
    assert_contains "$out" "ENV_CCTRL_SESSION_PROFILE_SOURCE=shortcut"
}

test_detached_launch_writes_profile_identity_fields() {
    # Plan 071 phase 6: profile becomes part of a detached launch's identity.
    # Metadata carries profile/profile_source/auth_backend/requested_model/
    # claude_config_dir/profile_file, and the tmux display options mirror
    # profile/auth_backend -- for the plain default-profile path (no explicit
    # --profile, no shortcut), the gap phase 6 closes (previously only a
    # dir-adopted shortcut profile got this forwarding).
    mkdir -p "$TMPDIR/p6bin"
    make_fake_tmux "$TMPDIR/p6bin/tmux"
    local rootcopy="$TMPDIR/cctrl-p6-copy"
    local project="$TMPDIR/p6-project"
    local log="$TMPDIR/p6-tmux.log"
    local p6meta="$TMPDIR/p6-metadata"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$project" "$p6meta"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    printf '{"model":"sonnet-x","env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}\n' > "$rootcopy/profiles/work.json"
    printf '{"defaultProfile":"work","defaultAgent":"claude"}\n' > "$rootcopy/data/config.json"

    : > "$log"
    CLAUDE_CONFIG_DIR="$TMPDIR/p6-fake-claude-config" CCTRL_SESSION_METADATA_DIR="$p6meta" \
        PATH="$TMPDIR/p6bin:$PATH" TMUX_LOG="$log" "$rootcopy/cctrl" start -d "$project" >/dev/null

    local record_file
    record_file="$(ls "$p6meta"/*.json 2>/dev/null | head -1)"
    [[ -n "$record_file" ]] || fail "expected a metadata record to be written"
    local record
    record="$(cat "$record_file")"
    assert_contains "$record" '"provider": "claude"'
    assert_contains "$record" '"profile": "work"'
    assert_contains "$record" '"profile_source": "default"'
    assert_contains "$record" '"auth_backend": "bedrock"'
    assert_contains "$record" '"requested_model": "sonnet-x"'
    assert_contains "$record" '"claude_config_dir": "'"$TMPDIR"'/p6-fake-claude-config"'
    # _profile_find resolves SCRIPT_DIR through `cd && pwd` (physical path),
    # so on macOS this canonicalizes /tmp to /private/tmp -- match the
    # meaningful suffix rather than the exact (possibly non-canonical) prefix.
    assert_contains "$record" 'cctrl-p6-copy/profiles/work.json"'

    local tmuxlog
    tmuxlog="$(cat "$log")"
    assert_contains "$tmuxlog" "@cctrl_profile work"
    assert_contains "$tmuxlog" "@cctrl_auth_backend bedrock"
    echo "ok: detached launch writes profile identity metadata + tmux options"
}

test_profile_settings_file_written_scoped_and_not_in_argv() {
    # plan 071 phase 5 (D5/D8): a resolved profile gets a per-session
    # --settings overlay file (0600, dir 0700) in addition to the phase-4
    # process-env overlay. The secret value must land only in that file,
    # never inline in argv (ps-visible), and every unused provider key is
    # neutralised to "" so it can't fall through to a contaminated global
    # settings.json.
    make_fake_agent "$TMPDIR/claude" claude
    local profiles="$TMPDIR/settings-write-profiles" runtime="$TMPDIR/settings-write-runtime"
    mkdir -p "$profiles"
    printf '{"agents":{"claude":{"env":{"CLAUDE_CODE_USE_BEDROCK":"1","ANTHROPIC_AUTH_TOKEN":"sekrit-token-value"}}}}\n' \
        > "$profiles/work.json"

    local out
    out="$(CCTRL_PROFILES_DIR="$profiles" CCTRL_RUNTIME_DIR="$runtime" PATH="$TMPDIR:$PATH" \
        "$ROOT/cctrl" start --foreground --agent claude --profile work -m scrub)"

    assert_not_contains "$out" "sekrit-token-value"

    local dir="$runtime/cctrl-$(id -u)/profile-settings"
    [[ -d "$dir" ]] || fail "profile-settings dir was not created"
    local mode
    mode="$(stat -f '%Lp' "$dir" 2>/dev/null || stat -c '%a' "$dir")"
    [[ "$mode" == "700" ]] || fail "profile-settings dir should be 0700, got $mode"

    local settings_path
    settings_path="$(printf '%s\n' "$out" \
        | awk -F= '/^ARG\[[0-9]+\]=--settings$/{getline; sub(/^ARG\[[0-9]+\]=/, ""); print; exit}')"
    [[ -n "$settings_path" ]] || fail "no --settings path found in argv: $out"
    [[ -f "$settings_path" ]] || fail "--settings path does not exist: $settings_path"

    mode="$(stat -f '%Lp' "$settings_path" 2>/dev/null || stat -c '%a' "$settings_path")"
    [[ "$mode" == "600" ]] || fail "settings file should be 0600, got $mode"

    jq -e '.env.CLAUDE_CODE_USE_BEDROCK == "1"' "$settings_path" >/dev/null \
        || fail "settings file missing the profile's own set key"
    jq -e '.env.ANTHROPIC_AUTH_TOKEN == "sekrit-token-value"' "$settings_path" >/dev/null \
        || fail "settings file missing the profile's secret value"
    jq -e '.env.CLAUDE_CODE_USE_VERTEX == ""' "$settings_path" >/dev/null \
        || fail "settings file should neutralise an unused provider key to \"\""
}

test_profile_settings_none_profile_no_file() {
    # Profile "none" relies solely on the phase-4 scrub -- no --settings
    # file or flag.
    make_fake_agent "$TMPDIR/claude" claude
    local runtime="$TMPDIR/settings-none-runtime"
    local out
    out="$(CCTRL_RUNTIME_DIR="$runtime" FAKE_AGENT_ENV_NAMES="CCTRL_PROFILE_SETTINGS_FILE" \
        PATH="$TMPDIR:$PATH" "$ROOT/cctrl" start --foreground --agent claude --profile none -m scrub)"
    assert_contains "$out" "ENV_CCTRL_PROFILE_SETTINGS_FILE=<unset>"
    assert_not_contains "$out" "--settings"
}

test_bash_leg_is_honest() {
    # Plan 103 guard: cctrl-shaped execution must run under the harness's own
    # bash, through every path the suite uses (shebang lookup, bash -c, the
    # eval helper). Fails if the PATH shim is missing or bypassed.
    local want="$BASH_VERSION" got
    [[ "$(head -n 1 "$ROOT/cctrl")" == "#!/usr/bin/env bash" ]] \
        || fail "cctrl shebang is no longer '#!/usr/bin/env bash'; the shim probe no longer models it"
    local probe="$TMPDIR/bash-probe.sh"
    printf '#!/usr/bin/env bash\necho "$BASH_VERSION"\n' > "$probe"
    chmod +x "$probe"
    got="$("$probe")"
    [[ "$got" == "$want" ]] || fail "shebang path ran bash $got, harness is $want"
    got="$(bash -c 'echo "$BASH_VERSION"')"
    [[ "$got" == "$want" ]] || fail "bare 'bash -c' ran bash $got, harness is $want"
    got="$(cctrl_source_eval 'echo "$BASH_VERSION"')"
    [[ "$got" == "$want" ]] || fail "cctrl_source_eval ran bash $got, harness is $want"
    [[ "$(command -v bash)" == "$TMPDIR/bash-shim/bash" ]] || fail "PATH shim is not first for bash"
    [[ "$(_test_path)" == "$TMPDIR/bash-shim:"* ]] || fail "_test_path does not start with the bash shim"
    [[ "$(_test_path --sbin /x /y)" == "$TMPDIR/bash-shim:/x:/y:/usr/bin"":/bin:/usr/sbin:/sbin" ]] \
        || fail "_test_path --sbin output is wrong: $(_test_path --sbin /x /y)"
}

_shimless_path_hits() {
    # args: root. Prints offending lines; CCTRL_HOOK_GUI_PATH (2 sites in the
    # codex hook test) is allowlisted by its exact assignment: it only simulates
    # a GUI PATH for `hooks doctor`, which uses it for `command -v cctrl`.
    local pat=':/usr/bin'"$(printf ':/bin')"
    [[ -d "$1/tests" ]] || { echo "no tests dir under $1"; return 0; }
    grep -rnF --include='*.sh' --include='*.py' --exclude-dir=__pycache__ -e "$pat" "$1/tests" \
        | grep -vF 'CCTRL_HOOK_GUI_PATH="$doctor_bin:' || true
}

test_no_shimless_test_path() {
    # A fixture PATH that ends in the system dirs without the bash shim makes
    # `#!/usr/bin/env bash` resolve to /bin/bash 3.2 on the bash 5 leg. Build
    # PATH with _test_path. The pattern is assembled so this test does not match
    # itself.
    local hits root="${CCTRL_LINT_ROOT:-$ROOT}" plant="$TMPDIR/lint-plant"
    hits="$(_shimless_path_hits "$root")"
    [[ -z "$hits" ]] || fail "fixture PATH without the bash shim (use _test_path): $(printf '%s' "$hits" | cut -c1-160 | head -n 5)"
    # Self-test: a planted bare PATH site must be reported.
    mkdir -p "$plant/tests"
    printf 'x() { PATH="$b%s" true; }\n' ':/usr/bin'":/bin" > "$plant/tests/planted.sh"
    [[ -n "$(_shimless_path_hits "$plant")" ]] || fail "shimless-PATH lint did not flag a planted site"
    printf '        CCTRL_HOOK_GUI_PATH="$doctor_bin%s" true\n' ':/usr/bin'":/bin" > "$plant/tests/planted.sh"
    [[ -z "$(_shimless_path_hits "$plant")" ]] || fail "shimless-PATH lint flagged the allowlisted CCTRL_HOOK_GUI_PATH form"
}

test_profile_settings_gc_portable_membership() {
    # Plan 103: GC liveness must work without associative arrays (bash 3.2).
    # Calls the function directly under the harness bash.
    make_fake_tmux "$TMPDIR/tmux"
    local runtime="$TMPDIR/settings-gc-portable-runtime"
    local dir="$runtime/cctrl-$(id -u)/profile-settings"
    mkdir -p "$dir"
    printf '{}\n' > "$dir/TMUX--p-live.json"
    printf '{}\n' > "$dir/TMUX--p-live-2.json"
    printf '{}\n' > "$dir/TMUX--p-dead.json"
    touch -t 202001010000 "$dir/TMUX--p-live.json" "$dir/TMUX--p-live-2.json" "$dir/TMUX--p-dead.json"
    local state="$TMPDIR/settings-gc-portable-state"
    printf '%s\n' '$0:TMUX--p-live' '$1:TMUX--p-live-2' > "$state"
    CCTRL_RUNTIME_DIR="$runtime" TMUX_FAKE_STATE="$state" PATH="$TMPDIR:$PATH" \
        cctrl_source_eval '_profile_settings_gc'
    [[ -f "$dir/TMUX--p-live.json" && -f "$dir/TMUX--p-live-2.json" ]] || fail "GC removed a live session's file"
    [[ ! -f "$dir/TMUX--p-dead.json" ]] || fail "GC kept a dead (old) session's file"
}

test_profile_settings_gc_removes_dead_keeps_live() {
    # D5/R3: the orphan sweep removes a dead fg-<pid> file and a dead
    # tmux-session-named file, but keeps one whose tmux session is live.
    make_fake_agent "$TMPDIR/claude" claude
    make_fake_tmux "$TMPDIR/tmux"
    local runtime="$TMPDIR/settings-gc-runtime"
    local dir="$runtime/cctrl-$(id -u)/profile-settings"
    mkdir -p "$dir"
    printf '{"env":{}}\n' > "$dir/fg-999999.json"
    printf '{"env":{}}\n' > "$dir/TMUX--gc-dead.json"
    # Old enough to clear the age gate (test_profile_settings_gc_removes_dead_only_after_age_threshold
    # covers the "too fresh to remove" case on its own).
    touch -t 202001010000 "$dir/TMUX--gc-dead.json"
    printf '{"env":{}}\n' > "$dir/TMUX--gc-live.json"
    local state="$TMPDIR/settings-gc-state"
    printf '%s\n' '$0:TMUX--gc-live' > "$state"

    CCTRL_RUNTIME_DIR="$runtime" TMUX_FAKE_STATE="$state" PATH="$TMPDIR:$PATH" \
        "$ROOT/cctrl" start --foreground --agent claude --profile none -m gc >/dev/null

    [[ ! -f "$dir/fg-999999.json" ]] || fail "GC should remove a dead fg-pid settings file"
    [[ ! -f "$dir/TMUX--gc-dead.json" ]] || fail "GC should remove a settings file for a dead tmux session"
    [[ -f "$dir/TMUX--gc-live.json" ]] || fail "GC should keep a settings file for a live tmux session"
}

test_profile_settings_gc_skips_sweep_when_list_sessions_fails() {
    # Review hardening (p5 incident): `tmux has-session` returning nonzero is
    # ambiguous -- it also fails when tmux is missing, times out, or this
    # process is pointed at a different/wrong socket, none of which mean the
    # session is dead. So the whole sweep must be skipped unless
    # `tmux list-sessions` first proves this server is actually reachable.
    make_fake_agent "$TMPDIR/claude" claude
    make_fake_tmux "$TMPDIR/tmux"
    local runtime="$TMPDIR/settings-gc-unreachable-runtime"
    local dir="$runtime/cctrl-$(id -u)/profile-settings"
    mkdir -p "$dir"
    printf '{"env":{}}\n' > "$dir/TMUX--gc-dead.json"
    touch -t 202001010000 "$dir/TMUX--gc-dead.json"

    CCTRL_RUNTIME_DIR="$runtime" TMUX_FAKE_LIST_SESSIONS_FAIL=1 PATH="$TMPDIR:$PATH" \
        "$ROOT/cctrl" start --foreground --agent claude --profile none -m gc >/dev/null

    [[ -f "$dir/TMUX--gc-dead.json" ]] || fail "GC must not sweep when tmux list-sessions fails (server unreachable)"
}

test_profile_settings_gc_removes_dead_only_after_age_threshold() {
    # Review hardening (p5 incident): even a confirmed-absent session's file
    # is only removed once it's at least 10 minutes old, so a transient
    # has-session blip can't explain away a just-written file.
    make_fake_agent "$TMPDIR/claude" claude
    make_fake_tmux "$TMPDIR/tmux"
    local runtime="$TMPDIR/settings-gc-age-runtime"
    local dir="$runtime/cctrl-$(id -u)/profile-settings"
    mkdir -p "$dir"
    printf '{"env":{}}\n' > "$dir/TMUX--gc-fresh-dead.json"
    printf '{"env":{}}\n' > "$dir/TMUX--gc-old-dead.json"
    touch -t 202001010000 "$dir/TMUX--gc-old-dead.json"

    CCTRL_RUNTIME_DIR="$runtime" PATH="$TMPDIR:$PATH" \
        "$ROOT/cctrl" start --foreground --agent claude --profile none -m gc >/dev/null

    [[ -f "$dir/TMUX--gc-fresh-dead.json" ]] || fail "GC should not remove a dead session's file before the age threshold"
    [[ ! -f "$dir/TMUX--gc-old-dead.json" ]] || fail "GC should remove a dead session's file once it's old enough"
}

test_profile_settings_wrapper_removes_file_on_exit() {
    # D5: both the wrapper's signal trap and its normal exit path remove
    # the --settings overlay file so it doesn't outlive the session.
    local bin="$TMPDIR/wrap-settings-bin" settings="$TMPDIR/wrap-settings-file.json"
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/claude"
    chmod +x "$bin/claude"
    printf '{"env":{}}\n' > "$settings"

    CCTRL_EARLY_EXIT_WINDOW_SECONDS=0 CCTRL_PROFILE_SETTINGS_FILE="$settings" \
        PATH="$bin:$PATH" "$ROOT/lib/session-wrapper.sh" claude "$TMPDIR/wrap-settings-marker" --flag \
        >/dev/null 2>&1

    [[ ! -f "$settings" ]] || fail "wrapper exit should remove the profile-settings file"
}

test_profile_settings_restart_regenerates_file() {
    # cmd_restart writes a fresh settings file from the session's current
    # profile before the restart marker, so a profile edit (profile
    # save/use) takes effect on the restarted ("fresh config") agent
    # instead of the stale file the original launch wrote.
    local profiles="$TMPDIR/restart-settings-profiles" runtime="$TMPDIR/restart-settings-runtime"
    mkdir -p "$profiles"
    printf '{"agents":{"claude":{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}}}\n' > "$profiles/work.json"
    local dir="$runtime/cctrl-$(id -u)/profile-settings"
    mkdir -p "$dir"
    printf '{"env":{"CLAUDE_CODE_USE_BEDROCK":""}}\n' > "$dir/TMUX--restart-settings.json"
    local marker="$TMPDIR/restart-settings-marker"
    # cmd_restart stops the agent it runs under; this test runs under no
    # session at all, so it must go through the fake tmux and find nothing
    # to stop (the real tmux here once killed the suite's own session).
    make_fake_tmux "$TMPDIR/tmux"
    local log="$TMPDIR/restart-settings-tmux.log" out
    : > "$log"

    out="$(CLAUDE_CODE_SESSION_ID="sess-restart-settings" CCTRL_RESTART_MARKER="$marker" \
        CCTRL_SESSION_KIND=tmux CCTRL_SESSION_NAME="TMUX--restart-settings" \
        CCTRL_SESSION_PROFILE=work CCTRL_PROFILES_DIR="$profiles" CCTRL_RUNTIME_DIR="$runtime" \
        PATH="$TMPDIR:$PATH" TMUX_LOG="$log" "$ROOT/cctrl" restart 2>&1)"

    assert_contains "$out" "Could not locate this session's agent process"
    assert_not_contains "$out" "Restarting with fresh config in 3s"
    [[ -f "$marker" ]] || fail "restart marker was not written"
    [[ "$(cat "$marker")" == "sess-restart-settings" ]] || fail "marker should hold the resolved session id"
    jq -e '.env.CLAUDE_CODE_USE_BEDROCK == "1"' "$dir/TMUX--restart-settings.json" >/dev/null \
        || fail "cmd_restart should regenerate the settings file from the current profile"
}

test_restart_write_failure_warns_but_restarts() {
    # Review hardening (p5 incident item 2): a refused profile-settings dir
    # must not silently abort the restart under set -e before the marker is
    # written. It should warn and let the restart continue.
    local profiles="$TMPDIR/restart-write-fail-profiles" runtime="$TMPDIR/restart-write-fail-runtime"
    mkdir -p "$profiles" "$runtime"
    printf '{"agents":{"claude":{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}}}\n' > "$profiles/work.json"
    # A regular file where the profile-settings dir needs to be created makes
    # `mkdir -p` fail, simulating a refused/unwritable runtime dir.
    printf 'not a directory\n' > "$runtime/cctrl-$(id -u)"
    local marker="$TMPDIR/restart-write-fail-marker"
    make_fake_tmux "$TMPDIR/tmux"
    local log="$TMPDIR/restart-write-fail-tmux.log"
    : > "$log"

    local out
    out="$(CLAUDE_CODE_SESSION_ID="sess-restart-write-fail" CCTRL_RESTART_MARKER="$marker" \
        CCTRL_SESSION_KIND=tmux CCTRL_SESSION_NAME="TMUX--restart-write-fail" \
        CCTRL_SESSION_PROFILE=work CCTRL_PROFILES_DIR="$profiles" CCTRL_RUNTIME_DIR="$runtime" \
        PATH="$TMPDIR:$PATH" TMUX_LOG="$log" "$ROOT/cctrl" restart 2>&1)"

    assert_contains "$out" "WARN"
    [[ -f "$marker" ]] || fail "restart marker was not written despite the settings-write failure"
    [[ "$(cat "$marker")" == "sess-restart-write-fail" ]] || fail "marker should hold the resolved session id"
}

test_agent_model_py_settings_flag() {
    # lib/agent_model.py: --settings is a value-taking flag so a --settings
    # <path> ahead of --model never swallows --model as its own value.
    local out
    out="$(printf '%s' "claude --settings /tmp/p.json --model opus-5" \
        | python3 "$ROOT/lib/agent_model.py" claude 2>&1)" \
        || fail "agent_model.py invocation failed: $out"
    [[ "$out" == "opus-5" ]] || fail "expected model 'opus-5', got '$out'"
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
    # plan 071 phase 3: `use`, `current`, and `diff` moved off
    # ~/.claude/settings.json. `use` now only writes defaultProfile into the
    # XDG user config; `current` reports the resolved default plus its
    # source; `diff` compares two profiles (or a profile vs. the configured
    # default) instead of a profile vs. settings.json. HOME and
    # XDG_CONFIG_HOME are both redirected at fixture dirs, and settings.json
    # is hashed before/after to prove `use` never touches it.
    local rootcopy="$TMPDIR/cctrl-profile-verbs-copy"
    local fakehome="$rootcopy/home"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$fakehome/.claude" "$fakehome/.config"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    make_fake_tmux "$TMPDIR/tmux"

    printf '{"model":"claude-sonnet-5","env":{"KEEP":"yes"}}\n' > "$fakehome/.claude/settings.json"
    printf '{"model":"claude-opus-5","env":{"PROFILE_ONLY":"1"}}\n' > "$rootcopy/profiles/work.json"
    printf '{"model":"claude-sonnet-5","env":{"KEEP":"yes"}}\n' > "$rootcopy/profiles/home.json"

    local out rc settings_before settings_after

    # ls lists both profiles.
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" ls)"
    assert_contains "$out" "work"
    assert_contains "$out" "home"

    settings_before="$(shasum "$fakehome/.claude/settings.json")"

    # use sets ONLY the configured default; it never touches settings.json or
    # the legacy .active-profile file.
    HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" use work >/dev/null
    jq -e '.defaultProfile == "work"' "$fakehome/.config/cctrl/config.json" >/dev/null \
        || fail "use should write defaultProfile into the XDG user config"
    settings_after="$(shasum "$fakehome/.claude/settings.json")"
    [[ "$settings_before" == "$settings_after" ]] || fail "use must never touch ~/.claude/settings.json"
    [[ ! -f "$rootcopy/.active-profile" ]] || fail "use must not write the legacy .active-profile file"

    # current reports the resolved default (source: default), its model, and
    # the config file that supplied it.
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" CCTRL_ROOT="$rootcopy" \
        PATH="$TMPDIR:$PATH" "$rootcopy/cctrl" current)"
    assert_contains "$out" "work"
    assert_contains "$out" "claude-opus-5"
    assert_contains "$out" "source: default"
    assert_contains "$out" "~/.config/cctrl/config.json"

    # diff compares two named profiles directly.
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" diff work home)"
    assert_contains "$out" "claude-sonnet-5"
    assert_contains "$out" "claude-opus-5"
    assert_contains "$out" "PROFILE_ONLY"

    # With no second profile, diff falls back to the configured default.
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" diff home)"
    assert_contains "$out" "claude-sonnet-5"
    assert_contains "$out" "claude-opus-5"

    # Unknown profile names fail loudly on both verbs.
    rc=0
    HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" use ghost >/dev/null 2>&1 || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for 'use' with an unknown profile"
    rc=0
    HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" diff ghost >/dev/null 2>&1 || rc=$?
    (( rc != 0 )) || fail "expected non-zero exit for 'diff' with an unknown profile"
    # The failed 'use' must not have moved the configured default.
    jq -e '.defaultProfile == "work"' "$fakehome/.config/cctrl/config.json" >/dev/null \
        || fail "a failed 'use' changed the configured default"

    echo "ok: profile use/current/diff resolve off XDG config, never touch settings.json, and reject unknown names"
}

test_profile_xdg_config_home() {
    # plan 071 phase 1: profiles and user config move to XDG. A custom
    # XDG_CONFIG_HOME relocates both; a relative one is invalid per spec and
    # falls back to $HOME/.config.
    local rootcopy="$TMPDIR/cctrl-xdg-copy"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$rootcopy/xdg-home" "$rootcopy/home"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    printf '{"model":"x","env":{}}\n' > "$rootcopy/profiles/myprof.json"

    HOME="$rootcopy/home" XDG_CONFIG_HOME="$rootcopy/xdg-home" "$rootcopy/cctrl" profile migrate >/dev/null
    [[ -f "$rootcopy/xdg-home/cctrl/profiles/myprof.json" ]] || fail "XDG_CONFIG_HOME was not honoured for the cctrl profiles dir"

    # Relative XDG_CONFIG_HOME is ignored -> falls back to $HOME/.config.
    rm -rf "$rootcopy/xdg-home"
    HOME="$rootcopy/home2" XDG_CONFIG_HOME="relative/path" "$rootcopy/cctrl" profile migrate >/dev/null 2>&1 || true
    [[ -f "$rootcopy/home2/.config/cctrl/profiles/myprof.json" ]] || fail "a relative XDG_CONFIG_HOME should fall back to \$HOME/.config"

    echo "ok: XDG_CONFIG_HOME honoured, relative value falls back to \$HOME/.config"
}

test_profile_repo_fallback_and_clash() {
    # A profile only in the repo dir still resolves (legacy fallback); one
    # present in both resolves to the XDG copy and ls/current warn about it.
    local rootcopy="$TMPDIR/cctrl-clash-copy"
    local fakehome="$rootcopy/home"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$fakehome/.config/cctrl/profiles" "$fakehome/.claude"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"

    printf '{"model":"repo-only","env":{}}\n' > "$rootcopy/profiles/reponly.json"
    local out
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" "$rootcopy/cctrl" ls)"
    assert_contains "$out" "reponly"

    printf '{"model":"repo-version","env":{}}\n' > "$rootcopy/profiles/dupe.json"
    printf '{"model":"xdg-version","env":{}}\n' > "$fakehome/.config/cctrl/profiles/dupe.json"
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" "$rootcopy/cctrl" ls)"
    assert_contains "$out" "xdg-version"
    assert_contains "$out" "WARN"
    if echo "$out" | grep -q "repo-version"; then
        fail "ls should show the XDG copy's summary, not the shadowed repo one"
    fi
    [[ "$(echo "$out" | grep -c '^\s*\*\? *dupe ')" == "1" ]] \
        || fail "a name in both dirs should produce exactly one row in ls, not a duplicate"

    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" "$rootcopy/cctrl" current)"
    assert_contains "$out" "none"   # nothing set as default yet; current must not crash either way

    echo "ok: repo-only profile resolves; a name in both dirs resolves to XDG, warns once, no duplicate row"
}

test_profile_shadow_identical_warn_quiet() {
    # Plan 099: once the repo and XDG copies of a profile are byte-identical
    # (the normal post-`profile migrate` state), ls/current must NOT print
    # the "exists in both" WARN -- there is nothing to warn about.
    # plan 105 P4: `use` writes the user config; keep it private so it cannot
    # leak a default profile into later tests (shared $CCTRL_USER_CONFIG path).
    local rootcopy="$TMPDIR/cctrl-shadowsame-copy"
    local fakehome="$rootcopy/home"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$fakehome/.config/cctrl/profiles" "$fakehome/.claude"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"

    printf '{"model":"same-version","env":{}}\n' > "$rootcopy/profiles/twin.json"
    printf '{"model":"same-version","env":{}}\n' > "$fakehome/.config/cctrl/profiles/twin.json"

    local out
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="$rootcopy/user-config.json" "$rootcopy/cctrl" ls)"
    assert_contains "$out" "twin"
    assert_not_contains "$out" "WARN: twin exists in both"

    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="$rootcopy/user-config.json" "$rootcopy/cctrl" use twin 2>&1)"
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="$rootcopy/user-config.json" "$rootcopy/cctrl" current)"
    assert_contains "$out" "twin"
    assert_not_contains "$out" "WARN: twin exists in both"

    echo "ok: byte-identical repo/XDG profile copies stay silent in ls and current"
}

test_profile_shadow_current_warns_when_differs() {
    # Plan 099 counterpart: when the two copies genuinely differ, `current`'s
    # own WARN (not just `ls`'s, covered by test_profile_repo_fallback_and_clash)
    # must still print.
    # plan 105 P4: `use` writes the user config; keep it private so it cannot
    # leak a default profile into later tests (shared $CCTRL_USER_CONFIG path).
    local rootcopy="$TMPDIR/cctrl-shadowdiff-copy"
    local fakehome="$rootcopy/home"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$fakehome/.config/cctrl/profiles" "$fakehome/.claude"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"

    printf '{"model":"repo-version","env":{}}\n' > "$rootcopy/profiles/diverged.json"
    printf '{"model":"xdg-version","env":{}}\n' > "$fakehome/.config/cctrl/profiles/diverged.json"

    HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="$rootcopy/user-config.json" "$rootcopy/cctrl" use diverged >/dev/null 2>&1
    local out
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="$rootcopy/user-config.json" "$rootcopy/cctrl" current)"
    assert_contains "$out" "WARN: diverged exists in both"

    echo "ok: current still warns when the repo/XDG profile copies genuinely differ"
}

test_profile_find_sole_dir_override() {
    # CCTRL_PROFILES_DIR, when set, is the ONLY dir searched -- no XDG or
    # repo fallback, even when the name exists in both of those.
    local rootcopy="$TMPDIR/cctrl-sole-copy"
    local fakehome="$rootcopy/home"
    local sole="$TMPDIR/cctrl-sole-profiles"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$fakehome/.config/cctrl/profiles" "$sole"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"

    printf '{"model":"sole","env":{}}\n' > "$sole/onlyhere.json"
    # "elsewhere" exists in BOTH the repo and XDG fallback dirs, but NOT in
    # the sole override dir -- proves the override excludes them, not just
    # that a genuinely absent name reports missing.
    printf '{"model":"repo","env":{}}\n' > "$rootcopy/profiles/elsewhere.json"
    printf '{"model":"xdg","env":{}}\n' > "$fakehome/.config/cctrl/profiles/elsewhere.json"

    local out
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_PROFILES_DIR="$sole" \
        CCTRL_NO_MAIN=1 bash -c 'source "$0"; _profile_exists onlyhere && echo FOUND; _profile_find onlyhere' "$rootcopy/cctrl")"
    assert_contains "$out" "FOUND"
    assert_contains "$out" "$sole/onlyhere.json"

    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_PROFILES_DIR="$sole" \
        CCTRL_NO_MAIN=1 bash -c 'source "$0"; _profile_exists elsewhere && echo FOUND || echo MISSING' "$rootcopy/cctrl")"
    assert_contains "$out" "MISSING"

    echo "ok: CCTRL_PROFILES_DIR is the sole dir searched, excluding XDG/repo even for a name present in both"
}

test_profile_writes_and_edit_copy_on_write_use_xdg() {
    # save and the edit copy-on-write path write only to XDG, 0600 in a 0700 dir.
    local rootcopy="$TMPDIR/cctrl-xdg-write-copy"
    local fakehome="$rootcopy/home"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$fakehome/.claude"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    printf '{"model":"claude-opus-5","env":{"K":"v"}}\n' > "$fakehome/.claude/settings.json"

    ( umask 022; HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" "$rootcopy/cctrl" save newprof >/dev/null )
    local pf="$fakehome/.config/cctrl/profiles/newprof.json"
    [[ -f "$pf" ]] || fail "save should write the profile under XDG"
    [[ ! -f "$rootcopy/profiles/newprof.json" ]] || fail "save must not write into the repo profiles dir"
    local mode dmode
    mode="$(stat -f '%Lp' "$pf" 2>/dev/null || stat -c '%a' "$pf")"
    dmode="$(stat -f '%Lp' "$fakehome/.config/cctrl/profiles" 2>/dev/null || stat -c '%a' "$fakehome/.config/cctrl/profiles")"
    [[ "$mode" == "600" ]] || fail "XDG profile write is mode $mode, expected 600"
    [[ "$dmode" == "700" ]] || fail "XDG profiles dir is mode $dmode, expected 700"

    # edit copy-on-write: a repo-only profile gets copied to XDG on first edit.
    printf '{"model":"repo-edit","env":{}}\n' > "$rootcopy/profiles/repoedit.json"
    EDITOR=true HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" "$rootcopy/cctrl" edit repoedit >/dev/null
    [[ -f "$fakehome/.config/cctrl/profiles/repoedit.json" ]] || fail "edit should copy a repo-only profile to XDG"
    mode="$(stat -f '%Lp' "$fakehome/.config/cctrl/profiles/repoedit.json" 2>/dev/null || stat -c '%a' "$fakehome/.config/cctrl/profiles/repoedit.json")"
    [[ "$mode" == "600" ]] || fail "edit copy-on-write landed at mode $mode, expected 600"

    echo "ok: save and edit copy-on-write land only in XDG, at 0600/0700"
}

test_profile_migrate() {
    local rootcopy="$TMPDIR/cctrl-migrate-copy"
    local fakehome="$rootcopy/home"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$fakehome"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"

    printf '{"model":"a","env":{}}\n' > "$rootcopy/profiles/alpha.json"
    printf '{"model":"b","env":{}}\n' > "$rootcopy/profiles/beta.json"
    printf 'alpha\n' > "$rootcopy/.active-profile"

    local userdir="$fakehome/.config/cctrl/profiles"

    # --dry-run writes nothing.
    HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" "$rootcopy/cctrl" profile migrate --dry-run >/dev/null
    [[ ! -d "$fakehome/.config" ]] || fail "--dry-run must not create any XDG state"

    local out
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" "$rootcopy/cctrl" profile migrate)"
    assert_contains "$out" "copied: alpha"
    assert_contains "$out" "copied: beta"
    cmp -s "$rootcopy/profiles/alpha.json" "$userdir/alpha.json" || fail "migrated alpha.json is not byte-identical"
    local mode
    mode="$(stat -f '%Lp' "$userdir/alpha.json" 2>/dev/null || stat -c '%a' "$userdir/alpha.json")"
    [[ "$mode" == "600" ]] || fail "migrated profile is mode $mode, expected 600"
    [[ -f "$rootcopy/.active-profile" ]] && fail "legacy .active-profile should be removed after migrate"
    jq -e '.defaultProfile == "alpha"' "$fakehome/.config/cctrl/config.json" >/dev/null \
        || fail "migrate should write defaultProfile from the legacy .active-profile"

    # Second run: idempotent, no changes, repo originals untouched.
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" "$rootcopy/cctrl" profile migrate)"
    assert_contains "$out" "exists identical: alpha"
    assert_contains "$out" "exists identical: beta"
    [[ -f "$rootcopy/profiles/alpha.json" ]] || fail "migrate without --remove-old must keep the repo original"

    # A differing XDG copy is never overwritten.
    printf '{"model":"DIFFERENT","env":{}}\n' > "$userdir/alpha.json"
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" "$rootcopy/cctrl" profile migrate)"
    assert_contains "$out" "exists differs: alpha"
    jq -e '.model == "DIFFERENT"' "$userdir/alpha.json" >/dev/null \
        || fail "migrate must never overwrite a differing XDG profile"
    printf '{"model":"a","env":{}}\n' > "$userdir/alpha.json"   # restore identical for the next step

    # --remove-old removes only identical originals.
    printf '{"model":"DIFFERENT2","env":{}}\n' > "$userdir/beta.json"
    HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" "$rootcopy/cctrl" profile migrate --remove-old --yes >/dev/null
    [[ -f "$rootcopy/profiles/alpha.json" ]] && fail "--remove-old should have removed the identical alpha original"
    [[ -f "$rootcopy/profiles/beta.json" ]] || fail "--remove-old must not remove a differing beta original"

    echo "ok: profile migrate copies/verifies, is idempotent, never overwrites a differing XDG file, --remove-old is identical-only, --dry-run writes nothing, and migrates .active-profile"
}

test_profile_use_symlinked_user_config() {
    # N4: the user config may be a dotfiles symlink; `cctrl use` must write
    # defaultProfile through it (realpath) rather than replacing the link
    # with a plain file.
    local rootcopy="$TMPDIR/cctrl-use-symlink-copy"
    local fakehome="$rootcopy/home"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$fakehome/.config/cctrl" "$rootcopy/dotfiles"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"

    printf '{"model":"x","env":{}}\n' > "$rootcopy/profiles/work.json"
    printf '{}\n' > "$rootcopy/dotfiles/config.json"
    ln -s "$rootcopy/dotfiles/config.json" "$fakehome/.config/cctrl/config.json"

    HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" use work >/dev/null
    [[ -L "$fakehome/.config/cctrl/config.json" ]] || fail "use replaced the user config symlink with a plain file"
    jq -e '.defaultProfile == "work"' "$rootcopy/dotfiles/config.json" >/dev/null \
        || fail "use should write defaultProfile through the symlink to its target"

    echo "ok: 'cctrl use' writes defaultProfile through a dotfiles symlink without replacing it"
}

test_profile_current_source_file_and_warnings() {
    # cmd_current (phase 3) names the config file that supplied defaultProfile,
    # warns when data/config.local.json overrides the XDG user config, and
    # warns when the global settings.json env still carries a provider key.
    local rootcopy="$TMPDIR/cctrl-current-warn-copy"
    local fakehome="$rootcopy/home"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$fakehome/.config/cctrl" "$fakehome/.claude"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    make_fake_tmux "$TMPDIR/tmux"

    printf '{"model":"x","env":{}}\n' > "$rootcopy/profiles/work.json"
    printf '{"model":"y","env":{}}\n' > "$rootcopy/profiles/personal.json"
    printf '{"defaultProfile":"work"}\n' > "$fakehome/.config/cctrl/config.json"

    # CCTRL_USER_CONFIG and CCTRL_CONFIG_LOCAL must both be overridden here:
    # the harness globally points them at fixed, nonexistent sentinel paths
    # (shared across the whole suite run) so an unrelated test's CONFIG_FILE
    # lookups stay inert; this test specifically wants the real XDG user
    # config and a real data/config.local.json under $rootcopy.
    local out
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" \
        CCTRL_CONFIG_LOCAL="$rootcopy/data/config.local.json" CCTRL_ROOT="$rootcopy" \
        PATH="$TMPDIR:$PATH" "$rootcopy/cctrl" current)"
    assert_contains "$out" "~/.config/cctrl/config.json"

    # data/config.local.json (higher precedence) sets a different default:
    # current should report THAT file and warn about the override.
    printf '{"defaultProfile":"personal"}\n' > "$rootcopy/data/config.local.json"
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" \
        CCTRL_CONFIG_LOCAL="$rootcopy/data/config.local.json" CCTRL_ROOT="$rootcopy" \
        PATH="$TMPDIR:$PATH" "$rootcopy/cctrl" current)"
    assert_contains "$out" "personal"
    assert_contains "$out" "config.local.json"
    assert_contains "$out" "WARN"
    rm -f "$rootcopy/data/config.local.json"

    # A global settings.json leaking a provider key gets its own warning.
    printf '{"model":"x","env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}\n' > "$fakehome/.claude/settings.json"
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" \
        CCTRL_CONFIG_LOCAL="$rootcopy/data/config.local.json" CCTRL_ROOT="$rootcopy" \
        PATH="$TMPDIR:$PATH" "$rootcopy/cctrl" current)"
    assert_contains "$out" "WARN"
    assert_contains "$out" "settings.json"

    echo "ok: 'cctrl current' names the winning config file and warns on local-override + leaked settings.json provider keys"
}

test_profile_diff_redaction() {
    # R4: diff never prints a credential-shaped env value in cleartext, even
    # though the generated overlay still carries the real secret.
    local rootcopy="$TMPDIR/cctrl-diff-redact-copy"
    local fakehome="$rootcopy/home"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$fakehome/.config"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"

    printf '{"model":"claude-opus-5","env":{"HEALTHCHECKS_API_KEY":"s3cr3t-value","PORTKEY_API_KEY":"another-s3cr3t"}}\n' \
        > "$rootcopy/profiles/work.json"
    printf '{"model":"claude-sonnet-5","env":{}}\n' > "$rootcopy/profiles/personal.json"

    local out
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_ROOT="$rootcopy" "$rootcopy/cctrl" diff work personal)"
    assert_contains "$out" "<redacted>"
    if echo "$out" | grep -q 's3cr3t-value\|another-s3cr3t'; then
        fail "diff must redact credential-shaped env values, not print them"
    fi
    assert_contains "$out" "claude-opus-5"
    assert_contains "$out" "claude-sonnet-5"

    echo "ok: 'cctrl diff' redacts KEY/TOKEN/SECRET/HEADERS/AUTH/PASSWORD-shaped env values"
}

test_profile_auth_backend_table() {
    # _profile_auth_backend classifies bedrock / api (key or base URL) /
    # subscription / codex. Exercised directly via CCTRL_NO_MAIN=1 sourcing.
    local rootcopy="$TMPDIR/cctrl-auth-backend-copy"
    local pf="$TMPDIR/cctrl-auth-backend-profiles"
    mkdir -p "$rootcopy/data" "$pf"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"

    printf '{"model":"x","env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}\n' > "$pf/bedrock.json"
    printf '{"model":"x","env":{"ANTHROPIC_API_KEY":"k"}}\n' > "$pf/apikey.json"
    printf '{"model":"x","env":{"ANTHROPIC_BASE_URL":"https://gateway.example/v1"}}\n' > "$pf/apibase.json"
    printf '{"model":"x","env":{}}\n' > "$pf/subscription.json"

    local out
    out="$(CCTRL_AUTH_BACKEND_FIXTURES="$pf" CCTRL_NO_MAIN=1 bash -c '
        source "$0"
        _profile_auth_backend claude "$CCTRL_AUTH_BACKEND_FIXTURES/bedrock.json"
        echo
        _profile_auth_backend claude "$CCTRL_AUTH_BACKEND_FIXTURES/apikey.json"
        echo
        _profile_auth_backend claude "$CCTRL_AUTH_BACKEND_FIXTURES/apibase.json"
        echo
        _profile_auth_backend claude "$CCTRL_AUTH_BACKEND_FIXTURES/subscription.json"
        echo
        _profile_auth_backend codex "$CCTRL_AUTH_BACKEND_FIXTURES/subscription.json"
    ' "$rootcopy/cctrl")"

    local -a lines=()
    local l
    while IFS= read -r l; do lines+=("$l"); done <<< "$out"
    [[ "${#lines[@]}" -eq 5 ]] || fail "expected 5 classification lines, got ${#lines[@]}: $out"
    [[ "${lines[0]}" == "bedrock" ]] || fail "bedrock profile classified as '${lines[0]}'"
    [[ "${lines[1]}" == "api" ]] || fail "API-key profile classified as '${lines[1]}'"
    [[ "${lines[2]}" == "api" ]] || fail "custom-base-URL profile classified as '${lines[2]}'"
    [[ "${lines[3]}" == "subscription" ]] || fail "no-override profile classified as '${lines[3]}'"
    [[ "${lines[4]}" == "codex" ]] || fail "codex agent classified as '${lines[4]}'"

    echo "ok: _profile_auth_backend classifies bedrock/api(key)/api(base url)/subscription/codex"
}

test_profile_bridge_override_table() {
    # Plan 071 phase 7: _profile_bridge_override is false by default and true
    # only when a profile explicitly opts back into the remote-control bridge
    # on a non-subscription backend, via either the top-level "bridge" key or
    # the agents.claude.bridge fallback (same shape/truthy rule as
    # _profile_auth_backend).
    local rootcopy="$TMPDIR/cctrl-bridge-override-copy"
    local pf="$TMPDIR/cctrl-bridge-override-profiles"
    mkdir -p "$rootcopy/data" "$pf"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"

    printf '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}\n' > "$pf/no-override.json"
    printf '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"},"bridge":true}\n' > "$pf/override.json"
    printf '{"agents":{"claude":{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"},"bridge":"yes"}}}\n' > "$pf/agents-override.json"

    local out
    out="$(CCTRL_BRIDGE_FIXTURES="$pf" CCTRL_NO_MAIN=1 bash -c '
        source "$0"
        _profile_bridge_override "$CCTRL_BRIDGE_FIXTURES/no-override.json"
        echo
        _profile_bridge_override "$CCTRL_BRIDGE_FIXTURES/override.json"
        echo
        _profile_bridge_override "$CCTRL_BRIDGE_FIXTURES/agents-override.json"
    ' "$rootcopy/cctrl")"

    local -a lines=()
    local l
    while IFS= read -r l; do lines+=("$l"); done <<< "$out"
    [[ "${#lines[@]}" -eq 3 ]] || fail "expected 3 classification lines, got ${#lines[@]}: $out"
    [[ "${lines[0]}" == "false" ]] || fail "no-override profile reported '${lines[0]}'"
    [[ "${lines[1]}" == "true" ]] || fail "top-level bridge:true profile reported '${lines[1]}'"
    [[ "${lines[2]}" == "true" ]] || fail "agents.claude.bridge profile reported '${lines[2]}'"

    echo "ok: _profile_bridge_override honors top-level and agents.claude bridge overrides"
}

test_launch_skips_bridge_for_non_subscription_backend() {
    # Plan 071 phase 7: a non-subscription backend (Bedrock here) can't
    # authenticate the remote-control app bridge, so --remote-control is
    # skipped at launch -- unless the profile sets "bridge": true.
    make_fake_agent "$TMPDIR/claude" claude
    local pf="$TMPDIR/launch-bridge-profiles" runtime="$TMPDIR/launch-bridge-runtime"
    mkdir -p "$pf"
    printf '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}\n' > "$pf/work.json"
    printf '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"},"bridge":true}\n' > "$pf/work-bridge.json"

    local out
    out="$(PATH="$TMPDIR:$PATH" CCTRL_PROFILES_DIR="$pf" CCTRL_RUNTIME_DIR="$runtime" \
        "$ROOT/cctrl" start --foreground --agent claude --profile work -m "bedrock prompt")"
    assert_contains "$out" "CMD=claude"
    assert_not_contains "$out" "--remote-control"

    out="$(PATH="$TMPDIR:$PATH" CCTRL_PROFILES_DIR="$pf" CCTRL_RUNTIME_DIR="$runtime" \
        "$ROOT/cctrl" start --foreground --agent claude --profile work-bridge -m "bedrock prompt 2")"
    assert_contains "$out" "--remote-control"

    echo "ok: launch skips --remote-control for a non-subscription backend, unless the profile sets bridge:true"
}

test_profile_use_migrates_legacy_active_profile() {
    # Plan 071 phase 3: `cctrl use` also runs the shared legacy-migration
    # helper (previously only `profile migrate` did), removing a
    # pre-existing .active-profile file as a side effect of its first run.
    local rootcopy="$TMPDIR/cctrl-use-migrate-copy"
    local fakehome="$rootcopy/home"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$fakehome/.config"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"

    printf '{"model":"x","env":{}}\n' > "$rootcopy/profiles/alpha.json"
    printf 'alpha\n' > "$rootcopy/.active-profile"

    HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" CCTRL_ROOT="$rootcopy" \
        "$rootcopy/cctrl" use alpha >/dev/null
    [[ ! -f "$rootcopy/.active-profile" ]] || fail "'cctrl use' should migrate/remove the legacy .active-profile file on its first run"
    jq -e '.defaultProfile == "alpha"' "$fakehome/.config/cctrl/config.json" >/dev/null \
        || fail "'cctrl use alpha' should leave defaultProfile set to alpha"

    # profile migrate afterward is a no-op: the legacy file is already gone
    # and defaultProfile is already set, so nothing changes.
    HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" CCTRL_ROOT="$rootcopy" \
        "$rootcopy/cctrl" profile migrate >/dev/null
    jq -e '.defaultProfile == "alpha"' "$fakehome/.config/cctrl/config.json" >/dev/null \
        || fail "'profile migrate' after 'use' must not disturb an already-set defaultProfile"

    echo "ok: 'cctrl use' also runs the shared legacy .active-profile migration; a later 'profile migrate' is a no-op"
}

test_profile_rename_dispatch_and_defaultProfile() {
    # REGRESSION: plain `cctrl rename` is the SESSION rename, not the profile
    # one -- `cctrl profile rename` is the only way to rename a profile (plan
    # 071 phase 3 moved its body into _profile_rename and deleted the
    # shadowed duplicate `cmd_rename` definition). `_profile_rename` also
    # follows a renamed profile's defaultProfile pointer.
    local rootcopy="$TMPDIR/cctrl-rename-dispatch-copy"
    local fakehome="$rootcopy/home"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$fakehome/.config/cctrl"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    make_fake_tmux "$TMPDIR/tmux"

    printf '{"model":"x","env":{}}\n' > "$rootcopy/profiles/alpha.json"
    printf '{"defaultProfile":"alpha"}\n' > "$fakehome/.config/cctrl/config.json"

    # Plain `cctrl rename <old> <new>` must NOT rename a profile -- it hits
    # the session rename, which fails loudly with no matching tmux session,
    # and must not touch the profile file or defaultProfile. The fake tmux
    # (empty TMUX_FAKE_SESSIONS/no TMUX_FAKE_STATE) always reports no such
    # session, so this never depends on the real tmux server.
    local rc=0
    HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" CCTRL_ROOT="$rootcopy" \
        PATH="$TMPDIR:$PATH" "$rootcopy/cctrl" rename alpha beta >/dev/null 2>&1 || rc=$?
    (( rc != 0 )) || fail "plain 'cctrl rename alpha beta' should fail (no session named alpha), not silently rename a profile"
    [[ -f "$rootcopy/profiles/alpha.json" ]] || fail "plain 'cctrl rename' must not touch the profile file"
    [[ ! -f "$rootcopy/profiles/beta.json" ]] || fail "plain 'cctrl rename' must not rename a profile"

    # cctrl profile rename does the real work (writing the renamed file to
    # XDG per D9) and follows defaultProfile.
    HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_USER_CONFIG="" CCTRL_ROOT="$rootcopy" \
        "$rootcopy/cctrl" profile rename alpha beta >/dev/null
    [[ ! -f "$rootcopy/profiles/alpha.json" ]] || fail "profile rename should remove the old profile file"
    [[ -f "$fakehome/.config/cctrl/profiles/beta.json" ]] || fail "profile rename should create the new profile under XDG"
    jq -e '.defaultProfile == "beta"' "$fakehome/.config/cctrl/config.json" >/dev/null \
        || fail "profile rename should update defaultProfile when it pointed at the old name"

    echo "ok: plain 'cctrl rename' hits the session rename; 'cctrl profile rename' renames the file (to XDG) and follows defaultProfile"
}

test_profile_ls_shows_auth_backend_and_current_lists_sessions() {
    # cmd_ls (phase 3) adds an auth_backend column; cmd_current lists live
    # cctrl sessions, all grouped under "unknown" until plan 071 phase 6 adds
    # per-session profile metadata. A fake tmux makes the session list
    # deterministic instead of depending on whatever is really running.
    local rootcopy="$TMPDIR/cctrl-ls-backend-copy"
    local fakehome="$rootcopy/home"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$fakehome/.config"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    make_fake_tmux "$TMPDIR/tmux"

    printf '{"model":"x","env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}\n' > "$rootcopy/profiles/work.json"
    printf '{"model":"y","env":{}}\n' > "$rootcopy/profiles/personal.json"

    local out
    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_ROOT="$rootcopy" \
        PATH="$TMPDIR:$PATH" "$rootcopy/cctrl" ls)"
    assert_contains "$out" "[bedrock]"
    assert_contains "$out" "[subscription]"

    out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" CCTRL_ROOT="$rootcopy" \
        TMUX_FAKE_SESSIONS="TMUX--ms--work TMUX--ms--personal" PATH="$TMPDIR:$PATH" "$rootcopy/cctrl" current)"
    assert_contains "$out" "Live sessions by profile"
    assert_contains "$out" "unknown"
    assert_contains "$out" "TMUX--ms--work"
    assert_contains "$out" "TMUX--ms--personal"

    echo "ok: 'cctrl ls' shows an auth_backend column; 'cctrl current' lists live sessions under 'unknown' pre-phase-6"
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
    # The resolved "personal" profile (even with an empty env) gets a phase-5
    # --settings overlay file, shifting --chrome/the prompt two slots later.
    assert_contains "$out" "ARG[2]=--settings"
    assert_contains "$out" "ARG[4]=--chrome"
    assert_contains "$out" "ARG[5]=profile picked claude"
}

test_resolve_profile_precedence() {
    # plan 071 phase 2: _resolve_profile implements the 5-step precedence
    # (explicit > shortcut > default > legacy > none). Exercised directly
    # (not through a full launch) since it's a pure function of its two
    # arguments plus config/ACTIVE_FILE state. CCTRL_PROFILES_DIR makes the
    # profile lookup deterministic (sole dir, no XDG/repo fallback).
    local rootcopy="$TMPDIR/cctrl-resolve-profile-copy"
    local profiles="$TMPDIR/cctrl-resolve-profile-dir"
    mkdir -p "$rootcopy/data" "$profiles"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    printf '{"model":"w"}\n' > "$profiles/work.json"
    printf '{"model":"p"}\n' > "$profiles/personal.json"

    local out rc

    # explicit wins over shortcut/default/legacy.
    printf '{"defaultProfile":"personal"}\n' > "$rootcopy/data/config.json"
    printf 'personal\n' > "$rootcopy/.active-profile"
    out="$(CCTRL_PROFILES_DIR="$profiles" CCTRL_NO_MAIN=1 bash -c \
        'source "$0"; _resolve_profile work personal' "$rootcopy/cctrl")"
    [[ "$out" == $'work\texplicit' ]] || fail "explicit should win over shortcut/default/legacy, got: $out"

    # explicit "none" is a no-overlay sentinel, not a profile lookup.
    out="$(CCTRL_PROFILES_DIR="$profiles" CCTRL_NO_MAIN=1 bash -c \
        'source "$0"; _resolve_profile none personal' "$rootcopy/cctrl")"
    [[ "$out" == $'none\texplicit' ]] || fail "explicit none should short-circuit to none/explicit, got: $out"

    # a missing explicit profile fails closed (exit 64), even with a valid
    # shortcut underneath it.
    rc=0
    CCTRL_PROFILES_DIR="$profiles" CCTRL_NO_MAIN=1 bash -c \
        'source "$0"; _resolve_profile bogus personal >/dev/null 2>&1' "$rootcopy/cctrl" || rc=$?
    [[ "$rc" == 64 ]] || fail "a missing explicit profile should exit 64, got rc=$rc"

    # name grammar rejects a path-like name (exit 64, same fail-closed path).
    rc=0
    CCTRL_PROFILES_DIR="$profiles" CCTRL_NO_MAIN=1 bash -c \
        'source "$0"; _resolve_profile "../x" "" >/dev/null 2>&1' "$rootcopy/cctrl" || rc=$?
    [[ "$rc" == 64 ]] || fail "a path-like explicit profile name should be rejected (exit 64), got rc=$rc"

    # shortcut wins over default and legacy.
    out="$(CCTRL_PROFILES_DIR="$profiles" CCTRL_NO_MAIN=1 bash -c \
        'source "$0"; _resolve_profile "" work' "$rootcopy/cctrl")"
    [[ "$out" == $'work\tshortcut' ]] || fail "shortcut should win over default/legacy, got: $out"

    # a missing shortcut profile fails closed too.
    rc=0
    CCTRL_PROFILES_DIR="$profiles" CCTRL_NO_MAIN=1 bash -c \
        'source "$0"; _resolve_profile "" bogus >/dev/null 2>&1' "$rootcopy/cctrl" || rc=$?
    [[ "$rc" == 64 ]] || fail "a missing shortcut profile should exit 64, got rc=$rc"

    # configured default wins over legacy .active-profile.
    out="$(CCTRL_PROFILES_DIR="$profiles" CCTRL_NO_MAIN=1 bash -c \
        'source "$0"; _resolve_profile "" ""' "$rootcopy/cctrl")"
    [[ "$out" == $'personal\tdefault' ]] || fail "configured default should win over legacy, got: $out"

    # a default pointing at a missing profile warns and falls straight to
    # none (not to legacy underneath it).
    printf '{"defaultProfile":"ghost"}\n' > "$rootcopy/data/config.json"
    out="$(CCTRL_PROFILES_DIR="$profiles" CCTRL_NO_MAIN=1 bash -c \
        'source "$0"; _resolve_profile "" ""' "$rootcopy/cctrl" 2>/dev/null)"
    [[ "$out" == $'none\tnone' ]] || fail "a missing default should fall to none (not legacy), got: $out"
    out="$(CCTRL_PROFILES_DIR="$profiles" CCTRL_NO_MAIN=1 bash -c \
        'source "$0"; _resolve_profile "" "" 2>&1 1>/dev/null' "$rootcopy/cctrl")"
    assert_contains "$out" "WARN"

    # with no default configured, legacy .active-profile applies.
    rm -f "$rootcopy/data/config.json"
    out="$(CCTRL_PROFILES_DIR="$profiles" CCTRL_NO_MAIN=1 bash -c \
        'source "$0"; _resolve_profile "" ""' "$rootcopy/cctrl" 2>/dev/null)"
    [[ "$out" == $'personal\tlegacy' ]] || fail "legacy .active-profile should apply when no default is configured, got: $out"

    # with nothing configured at all, none.
    rm -f "$rootcopy/.active-profile"
    out="$(CCTRL_PROFILES_DIR="$profiles" CCTRL_NO_MAIN=1 bash -c \
        'source "$0"; _resolve_profile "" ""' "$rootcopy/cctrl")"
    [[ "$out" == $'none\tnone' ]] || fail "with nothing configured, resolution should be none/none, got: $out"

    echo "ok: _resolve_profile precedence (explicit > shortcut > default > legacy > none), fail-closed on explicit/shortcut, soft-fail on default, name grammar enforced"
}

test_shortcut_foreground_profile_flag_not_leaked_and_overlay_applied() {
    # plan 071 phase 2 REGRESSION: `cctrl @x --profile work --foreground` must
    # not pass --profile through to the agent's argv, and the named
    # profile's overlay (its model, here) must actually apply. Before this
    # fix, _shortcut_jump's foreground arg loop had no --profile case, so
    # --profile/work fell into the catch-all passthrough (reaching the
    # agent's own argv) while the overlay silently stayed on the shortcut's
    # OWN .profile.
    make_fake_agent "$TMPDIR/claude" claude

    local rootcopy="$TMPDIR/cctrl-shortcut-profile-flag-copy"
    local project="$TMPDIR/shortcut-profile-flag-project"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$project"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    printf '{"x":{"dir":"%s","profile":"personal"}}\n' "$project" > "$rootcopy/data/shortcuts.json"
    printf '{"model":"personal-model"}\n' > "$rootcopy/profiles/personal.json"
    printf '{"model":"work-model"}\n' > "$rootcopy/profiles/work.json"

    local out
    out="$(PATH="$TMPDIR:$PATH" CCTRL_TMUX_CONTEXT=1 \
        "$rootcopy/cctrl" @x --agent claude --profile work --foreground --no-bridge -m hi 2>&1)"
    assert_contains "$out" "CMD=claude"
    if echo "$out" | grep -qE '^ARG\[[0-9]+\]=--profile$'; then
        fail "--profile must not reach the agent's argv: $out"
    fi
    assert_not_contains "$out" "ARG[3]=personal-model"
    assert_contains "$out" "ARG[2]=--model"
    assert_contains "$out" "ARG[3]=work-model"

    echo "ok: @shortcut --profile CLI override is not forwarded to the agent, and its overlay (not the shortcut's own profile) applies"
}

test_detached_dir_adopts_shortcut_profile() {
    # plan 071 phase 2: `cctrl start -d <dir>` must resolve the SAME profile
    # as `cctrl start -d @<key>` when <dir> matches a configured shortcut --
    # not just the same session name (that naming-only adoption predates
    # this). The parent resolves the shortcut's .profile early and forwards
    # it into the child's own `cctrl start --foreground` invocation, since a
    # dir launch's child never sees `@<key>` (it gets `cd <dir> && cctrl
    # start --foreground`) and so cannot re-derive the profile itself the
    # way an `@<key>` launch's child does.
    make_fake_tmux "$TMPDIR/tmux"

    local rootcopy="$TMPDIR/cctrl-dir-adopt-copy"
    local project="$TMPDIR/dir-adopt-project"
    local log="$TMPDIR/dir-adopt-tmux.log"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$project"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    printf '{"defaultAgent":"claude"}\n' > "$rootcopy/data/config.json"
    printf '{"proj":{"dir":"%s","profile":"work"}}\n' "$project" > "$rootcopy/data/shortcuts.json"
    printf '{"model":"work-model"}\n' > "$rootcopy/profiles/work.json"

    : > "$log"
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_NO_HEALTH_CHECK=1 \
        "$rootcopy/cctrl" start -d "$project" --no-bridge >/dev/null 2>&1
    local dir_shell_cmd
    dir_shell_cmd="$(grep '^SHELL_CMD=' "$log" | head -1)"
    assert_contains "$dir_shell_cmd" "cctrl start --foreground"
    assert_contains "$dir_shell_cmd" "--profile work"

    : > "$log"
    PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_NO_HEALTH_CHECK=1 \
        "$rootcopy/cctrl" start -d @proj --no-bridge >/dev/null 2>&1
    local shortcut_shell_cmd
    shortcut_shell_cmd="$(grep '^SHELL_CMD=' "$log" | head -1)"
    assert_contains "$shortcut_shell_cmd" "@proj --foreground"

    echo "ok: a detached dir launch that adopts a matching shortcut's name also forwards the shortcut's profile into the child"
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
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_EMIT_SESSION=1 CCTRL_DATA_DIR="$data" CCTRL_DEVICE_TAG=peerhost "$ROOT/cctrl" start -d --peer comet --profile none --agent codex "$prompt_project" -- "do task")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--peerhost--start-peer-prompt-project"
    assert_contains "$(cat "$log")" "CCTRL_DEVICE_TAG=peerhost"
    # Explicit `--profile none` keeps this deterministic regardless of
    # ambient/legacy profile state (plan 071 phase 6 forwards a resolved
    # profile into every launch's child argv, so an unpinned profile here
    # would otherwise depend on test run order -- this call site invokes the
    # real $ROOT/cctrl directly, so an unpinned profile would fall through to
    # the live repo's own legacy .active-profile). An explicit --profile
    # isn't re-injected (only --peer is spliced in, directly before the
    # first `--`), so the original contiguous assertion still holds.
    assert_contains "$(cat "$log")" "--peer comet -- do\\ task"
    assert_contains "$(cat "$log")" "--profile none"

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

test_remote_detach_attach_escapes_exact_target() {
    # plan 085: the remote detach-and-attach path's second ssh call re-parses
    # its command string inside a remote zsh login shell (it sources
    # ~/.zprofile), where a bare `-t =NAME` would trigger zsh's own
    # equals-expansion. That second (attach) call never fires in
    # test_remote_shortcut_injects_purpose above, because the generic
    # make_fake_ssh emits no CCTRL_SESSION marker for the launch call, so
    # _remote_exec gives up before reaching it. Make the fake ssh emit that
    # marker so the attach call actually runs, and confirm its logged
    # command carries the backslash-escaped "\=" target.
    local bin="$TMPDIR/remote-attach-bin" hosts="$TMPDIR/remote-attach-hosts.json" log="$TMPDIR/remote-attach-ssh.log"
    mkdir -p "$bin"
    cat > "$bin/ssh" <<'SH'
#!/usr/bin/env bash
{
    printf 'SSH'
    for arg in "$@"; do printf ' %q' "$arg"; done
    printf '\n'
} >> "${SSH_LOG:?}"
[[ "${1:-}" == "-t" ]] && exit 0
printf 'CCTRL_SESSION=TMUX--fake-remote\n'
exit 0
SH
    chmod +x "$bin/ssh"
    printf '{"remote":{"hostname":"example.invalid","user":"tester"}}\n' > "$hosts"
    : > "$log"

    # shellcheck disable=SC2016 # positional parameter belongs to the sourced shell
    PATH="$(_test_path "$bin")" SSH_LOG="$log" cctrl_source_eval \
        'HOSTS_FILE="$1"; _remote_exec remote start -d' "$hosts" >/dev/null 2>&1 || true

    local ssh_log; ssh_log="$(cat "$log")"
    assert_contains "$ssh_log" "SSH -t tester@example.invalid"
    assert_contains "$ssh_log" 'tmux\ attach-session\ -t\ \\=TMUX--fake-remote'
    echo "ok: remote detach-and-attach escapes tmux's exact-match \"=\" so a remote zsh login shell won't equals-expand it"
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
    assert_contains "$(cat "$log")" "attach-session -t =TMUX--prompt-project"

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_AGENT=codex CCTRL_ATTACH_PROMPT=always "$ROOT/cctrl" start "$project" <<< "")"
    assert_contains "$out" "Connect to session TMUX--prompt-project now? [Y/n]"
    assert_contains "$(cat "$log")" "attach-session -t =TMUX--prompt-project"
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

test_dir_launch_skips_manager_shortcut_for_plain_key() {
    # Plan 098: only fm- (manager) shortcuts should ever produce an fm- name.
    # Before the fix, _shortcut_for_dir's sorted-key collision rule let an
    # fm- key beat a plain key for the same dir (fm-aaa < zzz), so a plain
    # `-d <dir>` launch was silently named and profiled after the manager.
    make_fake_tmux "$TMPDIR/tmux"

    local rootcopy="$TMPDIR/cctrl-fmcollision-copy"
    local project="$TMPDIR/fm-collision-project"
    local log="$TMPDIR/fmcollision.log"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$project"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    # fm-aaa sorts before zzz, so the old first-sorted-key rule would pick it.
    printf '{"fm-aaa":{"dir":"%s"},"zzz":{"dir":"%s"}}\n' "$project" "$project" > "$rootcopy/data/shortcuts.json"
    printf '{"defaultAgent":"codex"}\n' > "$rootcopy/data/config.json"

    : > "$log"
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_HOST_PREFIX=ms CCTRL_EMIT_SESSION=1 \
        "$rootcopy/cctrl" start -d --agent codex --purpose p "$project")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--zzz"
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--ms--zzz"
    assert_not_contains "$(cat "$log")" "TMUX--ms--fm-aaa"

    echo "ok: dir launch with a plain and an fm- key for the same dir names from the plain key"
}

test_dir_launch_only_manager_shortcut_uses_dir_basename() {
    # Plan 098: a dir with ONLY an fm- key configured for it must NOT adopt
    # that manager shortcut's name — it falls back to the dir basename, same
    # as no match at all.
    make_fake_tmux "$TMPDIR/tmux"

    local rootcopy="$TMPDIR/cctrl-fmonly-copy"
    local project="$TMPDIR/fm-only-project"
    local log="$TMPDIR/fmonly.log"
    mkdir -p "$rootcopy/data" "$rootcopy/profiles" "$project"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"
    chmod +x "$rootcopy/cctrl"
    printf '{"fm-only":{"dir":"%s"}}\n' "$project" > "$rootcopy/data/shortcuts.json"
    printf '{"defaultAgent":"codex"}\n' > "$rootcopy/data/config.json"

    : > "$log"
    local out
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" CCTRL_HOST_PREFIX=ms CCTRL_EMIT_SESSION=1 \
        "$rootcopy/cctrl" start -d --agent codex --purpose p "$project")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--fm-only-project"
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--ms--fm-only-project"
    local got_name
    got_name="$(grep -oE -- '--name TMUX--[^ ]+' "$log" | head -1)"
    [[ "$got_name" == "--name TMUX--ms--fm-only-project" ]] || \
        fail "expected the dir-basename name, got: $got_name"

    echo "ok: dir launch with only an fm- key for that dir falls back to the dir basename"
}

# ── Plan 100 phase 1: roles, kinds, the ask, remote preflight, replay ──────
# Every launch here uses a rootcopy of cctrl (its own data/shortcuts.json), the
# fake tmux on PATH and stdin from /dev/null, so nothing prompts, hangs, or
# reaches the real tmux server, registry or shortcuts file.

_rf_setup() {
    # args: tag shortcuts-json (@P@ is replaced with the project dir)
    RF_COPY="$TMPDIR/rf-$1-copy"; RF_PROJ="$TMPDIR/rf-$1-proj"; RF_LOG="$TMPDIR/rf-$1.log"
    mkdir -p "$RF_COPY/data" "$RF_COPY/profiles" "$RF_PROJ"
    cp "$ROOT/cctrl" "$RF_COPY/cctrl"
    chmod +x "$RF_COPY/cctrl"
    local json="${2//@P@/$RF_PROJ}"
    printf '%s\n' "$json" > "$RF_COPY/data/shortcuts.json"
    printf '{"defaultAgent":"codex"}\n' > "$RF_COPY/data/config.json"
    make_fake_tmux "$TMPDIR/tmux"
    : > "$RF_LOG"
}

_rf() {
    # Run the rootcopy. stdin is /dev/null and stderr is merged, so the first
    # line of the output is the first line of stderr when nothing precedes it.
    PATH="$TMPDIR:$PATH" TMUX_LOG="$RF_LOG" CCTRL_HOST_PREFIX=ms CCTRL_EMIT_SESSION=1 CCTRL_PURPOSE_PROMPT=never CCTRL_ATTACH_PROMPT=never \
        "$RF_COPY/cctrl" "$@" </dev/null 2>&1
}

_rf_session() { sed -n 's/^CCTRL_SESSION=//p' <<< "$1" | tail -n 1; }

_rf_field() {
    # args: output field -> that field of the record for the launched session
    local sess
    sess="$(_rf_session "$1")"
    [[ -n "$sess" ]] || fail "no CCTRL_SESSION in output: $1"
    session_record_json "$sess" | jq -r --arg f "$2" '.[$f] // empty'
}

_rf_records() { { ls "$CCTRL_SESSION_METADATA_DIR" 2>/dev/null || true; } | wc -l | tr -d ' '; }

_assert_ask_78() {
    # args: output rc
    [[ "$2" -eq 78 ]] || fail "expected exit 78, got $2: $1"
    [[ "$(head -n 1 <<< "$1")" == "cctrl: needs-user-decision: orchestrator-kind" ]] \
        || fail "first stderr line must be the needs-user-decision marker, got: $(head -n 1 <<< "$1")"
    assert_contains "$1" "--orch-kind fleet"
    assert_contains "$1" "--orch-kind repo"
    assert_contains "$1" "--role worker"
    assert_not_contains "$(cat "$RF_LOG")" "new-session"
}

test_role_flags_before_dir_target_with_detach() {
    _rf_setup rp1 '{}'
    local out rc=0
    out="$(_rf start -d --orch-kind repo --purpose p "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "launch with --orch-kind before the dir failed: $out"
    assert_contains "$(grep '^SHELL_CMD=' "$RF_LOG" | head -n 1)" "$RF_PROJ"
    [[ "$(_rf_field "$out" role)" == orchestrator ]] || fail "role not recorded: $out"
    [[ "$(_rf_field "$out" orch_kind)" == repo ]] || fail "kind not recorded: $out"
    echo "ok: role flags before the dir target are consumed, not taken as the target"
}

test_role_flags_before_at_target_without_detach() {
    cctrl_source_eval '_start_args_have_explicit_target --role worker @x' || fail "--role worker @x has an explicit target"
    cctrl_source_eval '_start_args_have_explicit_target --orch-kind repo --succeeds old --no-input @x' || fail "value flags and --no-input must be skipped"
    if cctrl_source_eval "_start_args_have_explicit_target --role $TMPDIR"; then
        fail "the value of --role must not be taken as a target dir"
    fi
    if cctrl_source_eval '_start_requests_app_owned --role --app-owned'; then
        fail "the value of --role must not be taken as --app-owned"
    fi
    echo "ok: role flags are skipped by the target and app-owned scanners"
}

test_role_flags_never_reach_child_command() {
    _rf_setup rp3 '{}'
    local out shell_cmd
    out="$(_rf start -d --role orchestrator --orch-kind repo --no-input --purpose p "$RF_PROJ")"
    shell_cmd="$(grep '^SHELL_CMD=' "$RF_LOG" | head -n 1)"
    [[ -n "$shell_cmd" ]] || fail "no tmux new-session command logged: $out"
    local needle
    for needle in "--role" "--orch-kind" "--succeeds" "--no-input" "CCTRL_ROLE" "CCTRL_ORCH" "CCTRL_NO_INPUT"; do
        assert_not_contains "$shell_cmd" "$needle"
    done
    # --succeeds is only valid for a fleet manager: prove it never reaches the child there.
    _rf_setup rp3f '{}'
    : > "$RF_LOG"
    local live_state="$TMPDIR/rp3f.state"
    printf '$1:TMUX--ms--old-fm\n' > "$live_state"
    CCTRL_SESSION_METADATA_DIR="$CCTRL_SESSION_METADATA_DIR" CCTRL_HOST_PREFIX=ms cctrl_source_eval '_session_write_metadata "$1" /tmp @x @x @x p "" cmd "" claude "conv-rp3f" "" "" "" "" "" "" "" orchestrator fleet' TMUX--ms--old-fm || fail "fixture record"
    out="$(TMUX_FAKE_STATE="$live_state" _rf start -d --agent claude --role orchestrator --orch-kind fleet --succeeds TMUX--ms--old-fm --no-input --purpose p "$RF_PROJ")"
    shell_cmd="$(grep '^SHELL_CMD=' "$RF_LOG" | head -n 1)"
    [[ -n "$shell_cmd" ]] || fail "no tmux new-session command logged for the fleet launch: $out"
    for needle in "--role" "--orch-kind" "--succeeds" "--no-input"; do
        assert_not_contains "$shell_cmd" "$needle"
    done
    echo "ok: role flags and role env never reach the pane child"
}

test_role_flags_with_foreground_exit_64() {
    _rf_setup rp4 '{"k":{"dir":"@P@"}}'
    local out rc=0
    out="$(_rf start --foreground --role worker "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "start --foreground --role must exit 64, got $rc: $out"
    assert_contains "$out" "add -d"
    rc=0
    out="$(_rf @k --foreground --orch-kind repo)" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "@key --foreground --orch-kind must exit 64, got $rc: $out"
    echo "ok: role flags on a foreground launch exit 64"
}

test_role_flags_with_app_owned_and_launch_to_app_exit_64() {
    _rf_setup rp5 '{}'
    local out rc=0
    out="$(_rf start --app-owned --role worker "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "--app-owned with --role must exit 64, got $rc: $out"
    rc=0
    [[ -e "$RF_COPY/lib" ]] || ln -s "$ROOT/lib" "$RF_COPY/lib"
    out="$(PATH="$TMPDIR:$PATH" "$RF_COPY/cctrl" launch-to-app --orch-kind repo "$RF_PROJ" </dev/null 2>&1)" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "launch-to-app with --orch-kind must exit 64, got $rc: $out"
    echo "ok: role flags are rejected by app-owned and launch-to-app"
}

test_remote_role_value_not_taken_as_purpose() {
    make_fake_ssh "$TMPDIR/ssh"
    local rootcopy="$TMPDIR/rp6-copy" log="$TMPDIR/rp6-ssh.log" proj="$TMPDIR/rp6-proj"
    mkdir -p "$rootcopy/data" "$proj"
    cp "$ROOT/cctrl" "$rootcopy/cctrl"; chmod +x "$rootcopy/cctrl"
    printf '{"ms":{"hostname":"example.invalid","user":"tester"}}\n' > "$rootcopy/data/hosts.json"
    : > "$log"
    PATH="$TMPDIR:$PATH" SSH_LOG="$log" CCTRL_PURPOSE_PROMPT=never \
        "$rootcopy/cctrl" --host ms start -d --role orchestrator --orch-kind repo "$proj" >/dev/null 2>&1 </dev/null || true
    local ssh_log
    ssh_log="$(cat "$log")"
    assert_not_contains "$ssh_log" "--purpose\\ orchestrator"
    assert_not_contains "$ssh_log" "--purpose\\ repo"
    assert_contains "$ssh_log" "--purpose\\ rp6-proj"
    echo "ok: remote default purpose skips role flag values"
}

test_role_flag_recorded_in_metadata_and_tmux_option() {
    _rf_setup rp7 '{}'
    local out sess
    out="$(_rf start -d --role worker --purpose p "$RF_PROJ")"
    sess="$(_rf_session "$out")"
    [[ "$(_rf_field "$out" role)" == worker ]] || fail "worker role not recorded: $out"
    assert_contains "$(cat "$RF_LOG")" "@cctrl_role worker"
    out="$(_rf start -d --orch-kind fleet --purpose p "$RF_PROJ")"
    assert_contains "$(cat "$RF_LOG")" "@cctrl_role orchestrator"
    assert_contains "$(cat "$RF_LOG")" "@cctrl_orch_kind fleet"
    [[ "$(_rf_field "$out" orch_kind)" == fleet ]] || fail "fleet kind not recorded"
    echo "ok: role and kind are recorded and set as tmux options"
}

test_role_and_orch_kind_invalid_values_exit_64() {
    _rf_setup rp8 '{}'
    local out rc=0
    out="$(_rf start -d --role boss --purpose p "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "--role boss must exit 64, got $rc: $out"
    rc=0
    out="$(_rf start -d --orch-kind king --purpose p "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "--orch-kind king must exit 64, got $rc: $out"
    rc=0
    out="$(_rf start -d --role --purpose p "$RF_PROJ")" || rc=$?
    assert_not_contains "$(cat "$RF_LOG")" "new-session"
    echo "ok: invalid role and kind values exit 64 and launch nothing"
}

test_orch_kind_flag_implies_orchestrator_role() {
    _rf_setup rp9 '{}'
    local out
    out="$(_rf start -d --orch-kind fleet --purpose p "$RF_PROJ")"
    [[ "$(_rf_field "$out" role)" == orchestrator ]] || fail "--orch-kind alone must imply orchestrator: $out"
    echo "ok: --orch-kind implies the orchestrator role"
}

test_role_worker_with_orch_kind_exits_64() {
    _rf_setup rp10 '{}'
    local out rc=0
    out="$(_rf start -d --role worker --orch-kind repo --purpose p "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "worker with --orch-kind must exit 64, got $rc: $out"
    echo "ok: --role worker with --orch-kind exits 64"
}

test_shortcut_role_and_kind_resolve_on_at_launch() {
    _rf_setup rp11 '{"mgr":{"dir":"@P@","role":"orchestrator","orch_kind":"fleet"},"wk":{"dir":"@P@","role":"worker"}}'
    local out
    out="$(_rf start -d --purpose p @mgr)"
    [[ "$(_rf_field "$out" role)" == orchestrator && "$(_rf_field "$out" orch_kind)" == fleet ]] || fail "@mgr role/kind: $out"
    out="$(_rf start -d --purpose p @wk)"
    [[ "$(_rf_field "$out" role)" == worker ]] || fail "@wk role: $out"
    echo "ok: an explicit @key launch takes the shortcut's role and kind"
}

test_shortcut_orch_kind_without_role_is_orchestrator() {
    _rf_setup rp12 '{"k":{"dir":"@P@","orch_kind":"repo"}}'
    local out
    out="$(_rf start -d --purpose p @k)"
    [[ "$(_rf_field "$out" role)" == orchestrator && "$(_rf_field "$out" orch_kind)" == repo ]] || fail "orch_kind alone: $out"
    echo "ok: orch_kind without role is a known orchestrator"
}

test_shortcut_invalid_role_exits_64_naming_key() {
    _rf_setup rp13 '{"bad":{"dir":"@P@","role":"boss"},"bad2":{"dir":"@P@","orch_kind":"king"}}'
    local out rc=0
    out="$(_rf start -d --purpose p @bad)" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "invalid role must exit 64, got $rc: $out"
    assert_contains "$out" 'shortcut @bad: invalid role "boss"'
    rc=0
    out="$(_rf start -d --purpose p @bad2)" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "invalid orch_kind must exit 64, got $rc: $out"
    assert_contains "$out" 'shortcut @bad2: invalid orch_kind "king"'
    assert_not_contains "$(cat "$RF_LOG")" "new-session"
    echo "ok: an invalid shortcut role or kind exits 64 naming the key"
}

test_orch_kind_flag_overrides_shortcut_kind() {
    _rf_setup rp14 '{"k":{"dir":"@P@","role":"orchestrator","orch_kind":"repo"}}'
    local out
    out="$(_rf start -d --orch-kind fleet --purpose p @k)"
    [[ "$(_rf_field "$out" orch_kind)" == fleet ]] || fail "flag must win over the shortcut kind: $out"
    assert_contains "$out" "flags override shortcut @k"
    echo "ok: --orch-kind wins over the shortcut and says so"
}

test_dir_launch_never_inherits_shortcut_role() {
    _rf_setup rp15 '{"plain":{"dir":"@P@","role":"orchestrator","orch_kind":"fleet"}}'
    local out
    out="$(_rf start -d --purpose p "$RF_PROJ")"
    [[ "$(_rf_field "$out" role)" == worker ]] || fail "a dir launch is a worker: $out"
    assert_not_contains "$out" "CCTRL_SESSION=TMUX--ms--plain"
    echo "ok: a dir launch never inherits a shortcut's role"
}

test_dir_launch_with_orch_key_and_plain_key_uses_plain_key() {
    _rf_setup rp16 '{"orch-x":{"dir":"@P@"},"plainkey":{"dir":"@P@"}}'
    local out
    out="$(_rf start -d --purpose p "$RF_PROJ")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--plainkey"
    echo "ok: a dir with an orch-* key and a plain key is named from the plain key"
}

test_dir_launch_with_only_orch_key_uses_basename() {
    _rf_setup rp17 '{"ORCH-x":{"dir":"@P@"}}'
    local out
    out="$(_rf start -d --purpose p "$RF_PROJ")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--rf-rp17-proj"
    echo "ok: a dir with only an orch-* key falls back to the dir basename"
}

test_dir_launch_matches_stored_dir_with_trailing_slash() {
    _rf_setup rp18 '{"slashy":{"dir":"@P@/"}}'
    local out
    out="$(_rf start -d --purpose p "$RF_PROJ")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--slashy"
    echo "ok: a stored dir with a trailing slash still matches"
}

test_dir_launch_skips_role_shortcut_without_legacy_prefix() {
    _rf_setup rp19 '{"boss":{"dir":"@P@","role":"orchestrator"},"kinded":{"dir":"@P@","orch_kind":"repo"}}'
    local out
    out="$(_rf start -d --purpose p "$RF_PROJ")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--rf-rp19-proj"
    echo "ok: an orchestrator shortcut is skipped by role, not only by prefix"
}

test_legacy_prefixed_key_with_worker_role_is_adopted() {
    _rf_setup rp20 '{"fm-w":{"dir":"@P@","role":"worker"}}'
    local out
    out="$(_rf start -d --purpose p "$RF_PROJ")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--fm-w"
    [[ "$(_rf_field "$out" role)" == worker ]] || fail "adopted key must stay a worker: $out"
    echo "ok: a legacy-prefixed key with role worker is adopted by a dir launch"
}

test_no_env_var_supplies_role_or_kind() {
    _rf_setup rp21 '{}'
    local out
    out="$(CCTRL_ROLE=orchestrator CCTRL_ORCH_KIND=fleet CCTRL_SESSION_ROLE=orchestrator CCTRL_SESSION_ORCH_KIND=fleet \
        _rf start -d --purpose p "$RF_PROJ")"
    [[ "$(_rf_field "$out" role)" == worker ]] || fail "no env var may supply a role: $out"
    echo "ok: no environment variable supplies a role or kind"
}

test_shortcut_add_preserves_role_fields() {
    _rf_setup rp22 '{"k":{"dir":"/old","role":"orchestrator","orch_kind":"repo"}}'
    _rf @add k /new --profile personal >/dev/null
    local got
    got="$(jq -c '.k | [.dir,.role,.orch_kind]' "$RF_COPY/data/shortcuts.json")"
    [[ "$got" == '["/new","orchestrator","repo"]' ]] || fail "@add must keep role fields, got $got"
    echo "ok: @add keeps an existing entry's role and orch_kind"
}

test_shortcut_add_role_flags_set_and_clear() {
    _rf_setup rp23 '{}'
    _rf @add k /d --role orchestrator --orch-kind fleet >/dev/null
    [[ "$(jq -c '.k | [.role,.orch_kind]' "$RF_COPY/data/shortcuts.json")" == '["orchestrator","fleet"]' ]] || fail "set failed"
    _rf @add k /d --role worker >/dev/null
    [[ "$(jq -c '.k | [.role,.orch_kind]' "$RF_COPY/data/shortcuts.json")" == '["worker",null]' ]] || fail "--role worker must drop the kind"
    local out rc=0
    out="$(_rf @add k /d --role worker --orch-kind repo)" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "worker + kind must exit 64, got $rc: $out"
    rc=0
    out="$(_rf @add k /d --role boss)" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "invalid role must exit 64, got $rc: $out"
    echo "ok: @add --role/--orch-kind set, clear and validate"
}

test_ask_a1_role_orchestrator_without_kind_exits_78() {
    _rf_setup a1 '{}'
    local before out rc=0
    before="$(_rf_records)"
    out="$(_rf start -d --role orchestrator --purpose p "$RF_PROJ")" || rc=$?
    _assert_ask_78 "$out" "$rc"
    [[ "$(_rf_records)" == "$before" ]] || fail "a refused launch must write no record"
    echo "ok: A1 --role orchestrator without a kind exits 78"
}

test_ask_a2_shortcut_role_without_kind_exits_78() {
    _rf_setup a2 '{"k":{"dir":"@P@","role":"orchestrator"}}'
    local out rc=0
    out="$(_rf start -d --purpose p @k)" || rc=$?
    _assert_ask_78 "$out" "$rc"
    assert_contains "$out" "cctrl @add k"
    echo "ok: A2 a shortcut with role orchestrator and no kind exits 78"
}

test_ask_a3_legacy_fm_and_orch_keys_without_role_exit_78() {
    _rf_setup a3 '{"fm-k":{"dir":"@P@"},"orch-k":{"dir":"@P@"},"FM-Upper":{"dir":"@P@"}}'
    local out rc key
    for key in fm-k orch-k FM-Upper; do
        rc=0
        out="$(_rf start -d --purpose p "@$key")" || rc=$?
        _assert_ask_78 "$out" "$rc"
    done
    echo "ok: A3 role-less fm-* and orch-* keys (any case) exit 78"
}

test_ask_a4_set_role_orchestrator_without_kind_exits_78() {
    _rf_setup a4 '{}'
    local out rc=0
    out="$(TMUX_FAKE_HAS_SESSION=TMUX--ms--x _rf session set-role TMUX--ms--x orchestrator)" || rc=$?
    [[ "$rc" -eq 78 ]] || fail "set-role orchestrator without a kind must exit 78, got $rc: $out"
    [[ "$(head -n 1 <<< "$out")" == "cctrl: needs-user-decision: orchestrator-kind" ]] || fail "marker line: $out"
    assert_not_contains "$(cat "$RF_LOG")" "@cctrl_role"
    echo "ok: A4 set-role orchestrator without a kind exits 78"
}

test_ask_a5_shortcut_add_orchestrator_without_kind_exits_78() {
    _rf_setup a5 '{}'
    local out rc=0
    out="$(_rf @add k /d --role orchestrator)" || rc=$?
    [[ "$rc" -eq 78 ]] || fail "@add --role orchestrator without a kind must exit 78, got $rc: $out"
    [[ "$(head -n 1 <<< "$out")" == "cctrl: needs-user-decision: orchestrator-kind" ]] || fail "marker line: $out"
    [[ "$(jq 'length' "$RF_COPY/data/shortcuts.json")" == 0 ]] || fail "nothing may be written"
    echo "ok: A5 @add --role orchestrator without a kind exits 78"
}

test_non_interactive_never_reads_stdin() {
    _rf_setup nostdin '{}'
    local out
    out="$(printf '1\n' | { PATH="$TMPDIR:$PATH" TMUX_LOG="$RF_LOG" CCTRL_HOST_PREFIX=ms "$RF_COPY/cctrl" start -d --role orchestrator --purpose p "$RF_PROJ" 2>&1; echo "RC=$?"; echo "LEFT=$(cat)"; })"
    assert_contains "$out" "RC=78"
    assert_contains "$out" "LEFT=1"
    echo "ok: the non-interactive refusal leaves stdin unread"
}

test_no_input_flag_and_env_force_78_on_pty() {
    _rf_setup noinput '{}'
    local rc=0 out_file="$TMPDIR/noinput.out"
    run_with_pty_input $'1\n' env PATH="$TMPDIR:$PATH" TMUX_LOG="$RF_LOG" CCTRL_HOST_PREFIX=ms CCTRL_NO_INPUT=1 \
        "$RF_COPY/cctrl" start -d --role orchestrator --purpose p "$RF_PROJ" > "$out_file" 2>&1 || rc=$?
    [[ "$rc" -eq 78 ]] || fail "CCTRL_NO_INPUT=1 must refuse on a pty, got $rc: $(cat "$out_file")"
    rc=0
    run_with_pty_input $'1\n' env PATH="$TMPDIR:$PATH" TMUX_LOG="$RF_LOG" CCTRL_HOST_PREFIX=ms \
        "$RF_COPY/cctrl" start -d --role orchestrator --no-input --purpose p "$RF_PROJ" > "$out_file" 2>&1 || rc=$?
    [[ "$rc" -eq 78 ]] || fail "--no-input must refuse on a pty, got $rc: $(cat "$out_file")"
    assert_not_contains "$(cat "$out_file")" "Which kind of orchestrator"
    echo "ok: --no-input and CCTRL_NO_INPUT force the non-interactive answer on a pty"
}

test_agent_env_markers_force_78_on_pty() {
    _rf_setup markers '{}'
    local rc out_file="$TMPDIR/markers.out" marker
    for marker in CCTRL_TMUX_CONTEXT=1 CCTRL_SESSION_KIND=tmux CCTRL_SESSION_KIND=foreground CLAUDECODE=1; do
        rc=0
        run_with_pty_input $'1\n' env PATH="$TMPDIR:$PATH" TMUX_LOG="$RF_LOG" CCTRL_HOST_PREFIX=ms "$marker" \
            "$RF_COPY/cctrl" start -d --role orchestrator --purpose p "$RF_PROJ" > "$out_file" 2>&1 || rc=$?
        [[ "$rc" -eq 78 ]] || fail "$marker must force the non-interactive answer, got $rc: $(cat "$out_file")"
        assert_not_contains "$(cat "$out_file")" "Which kind of orchestrator"
    done
    echo "ok: agent environment markers force exit 78 even on a pty"
}

test_ask_tty_accepts_fleet() {
    _rf_setup ttyfleet '{}'
    local rc=0 out_file="$TMPDIR/ttyfleet.out"
    run_with_pty_input $'1\n' env PATH="$TMPDIR:$PATH" TMUX_LOG="$RF_LOG" CCTRL_HOST_PREFIX=ms CCTRL_EMIT_SESSION=1 CCTRL_PURPOSE_PROMPT=never CCTRL_ATTACH_PROMPT=never \
        "$RF_COPY/cctrl" start -d --role orchestrator --purpose p "$RF_PROJ" > "$out_file" 2>&1 || rc=$?
    [[ "$rc" -eq 0 ]] || fail "answering 1 must launch, got $rc: $(cat "$out_file")"
    assert_contains "$(cat "$out_file")" "Which kind of orchestrator"
    local out
    out="$(tr -d '\r' < "$out_file")"
    [[ "$(_rf_field "$out" orch_kind)" == fleet ]] || fail "answer 1 must record fleet: $out"
    echo "ok: the tty ask accepts 1 = fleet"
}

test_ask_tty_accepts_repo() {
    _rf_setup ttyrepo '{}'
    local rc=0 out_file="$TMPDIR/ttyrepo.out"
    run_with_pty_input $'repo\n' env PATH="$TMPDIR:$PATH" TMUX_LOG="$RF_LOG" CCTRL_HOST_PREFIX=ms CCTRL_EMIT_SESSION=1 CCTRL_PURPOSE_PROMPT=never CCTRL_ATTACH_PROMPT=never \
        "$RF_COPY/cctrl" start -d --role orchestrator --purpose p "$RF_PROJ" > "$out_file" 2>&1 || rc=$?
    [[ "$rc" -eq 0 ]] || fail "answering repo must launch, got $rc: $(cat "$out_file")"
    local out
    out="$(tr -d '\r' < "$out_file")"
    [[ "$(_rf_field "$out" orch_kind)" == repo ]] || fail "answer repo must record repo: $out"
    echo "ok: the tty ask accepts repo"
}

test_ask_tty_prompts_when_stdout_is_captured() {
    _rf_setup ttycap '{}'
    local rc=0 out_file="$TMPDIR/ttycap.out"
    run_with_pty_input $'2\n' env PATH="$TMPDIR:$PATH" TMUX_LOG="$RF_LOG" CCTRL_HOST_PREFIX=ms CCTRL_EMIT_SESSION=1 CCTRL_PURPOSE_PROMPT=never CCTRL_ATTACH_PROMPT=never \
        bash -c 'out="$("$1" start -d --role orchestrator --purpose p "$2")"; echo "CAPTURED=$out"' _ "$RF_COPY/cctrl" "$RF_PROJ" > "$out_file" 2>&1 || rc=$?
    [[ "$rc" -eq 0 ]] || fail "a captured stdout must still prompt on the tty, got $rc: $(cat "$out_file")"
    assert_contains "$(cat "$out_file")" "Which kind of orchestrator"
    assert_contains "$(cat "$out_file")" "CCTRL_SESSION=TMUX--ms--orch-rf-ttycap-proj"
    echo "ok: the tty ask works when stdout is captured"
}

test_ask_tty_three_invalid_answers_exit_78() {
    _rf_setup ttybad '{}'
    local rc=0 out_file="$TMPDIR/ttybad.out"
    run_with_pty_input $'x\ny\nz\n' env PATH="$TMPDIR:$PATH" TMUX_LOG="$RF_LOG" CCTRL_HOST_PREFIX=ms CCTRL_ASK_TIMEOUT=5 \
        "$RF_COPY/cctrl" start -d --role orchestrator --purpose p "$RF_PROJ" > "$out_file" 2>&1 || rc=$?
    [[ "$rc" -eq 78 ]] || fail "three invalid answers must exit 78, got $rc: $(cat "$out_file")"
    assert_not_contains "$(cat "$RF_LOG")" "new-session"
    echo "ok: three invalid tty answers exit 78"
}

test_ask_tty_read_timeout_exits_78() {
    _rf_setup ttyto '{}'
    local rc=0 out_file="$TMPDIR/ttyto.out"
    run_with_pty_input "" env PATH="$TMPDIR:$PATH" TMUX_LOG="$RF_LOG" CCTRL_HOST_PREFIX=ms CCTRL_ASK_TIMEOUT=1 \
        "$RF_COPY/cctrl" start -d --role orchestrator --purpose p "$RF_PROJ" > "$out_file" 2>&1 || rc=$?
    [[ "$rc" -eq 78 ]] || fail "an ask timeout must exit 78, got $rc: $(cat "$out_file")"
    echo "ok: the tty ask times out to exit 78"
}

test_ask_tty_abort_exits_78_nothing_launched() {
    _rf_setup ttyq '{}'
    local rc=0 out_file="$TMPDIR/ttyq.out" before
    before="$(_rf_records)"
    run_with_pty_input $'q\n' env PATH="$TMPDIR:$PATH" TMUX_LOG="$RF_LOG" CCTRL_HOST_PREFIX=ms \
        "$RF_COPY/cctrl" start -d --role orchestrator --purpose p "$RF_PROJ" > "$out_file" 2>&1 || rc=$?
    [[ "$rc" -eq 78 ]] || fail "q must exit 78, got $rc: $(cat "$out_file")"
    assert_not_contains "$(cat "$RF_LOG")" "new-session"
    [[ "$(_rf_records)" == "$before" ]] || fail "an aborted ask must write no record"
    echo "ok: q aborts with exit 78 and launches nothing"
}

# Remote preflight. The fake ssh answers the hidden `_role-resolve` call from
# SSH_PRE_RC / SSH_PRE_OUT / SSH_PRE_ERR and exits 0 for everything else.
_make_fake_ssh_role() {
    cat > "$1" <<'SH'
#!/usr/bin/env bash
{
    printf 'SSH'
    for arg in "$@"; do printf ' %q' "$arg"; done
    printf '\n'
} >> "${SSH_LOG:?}"
if [[ "$*" == *_role-resolve* ]]; then
    [[ -n "${SSH_PRE_OUT:-}" ]] && printf '%s\n' "$SSH_PRE_OUT"
    [[ -n "${SSH_PRE_ERR:-}" ]] && printf '%s\n' "$SSH_PRE_ERR" >&2
    exit "${SSH_PRE_RC:-0}"
fi
exit 0
SH
    chmod +x "$1"
}

_remote_role_fixture() {
    _make_fake_ssh_role "$TMPDIR/ssh"
    RR_COPY="$TMPDIR/rr-$1-copy"; RR_LOG="$TMPDIR/rr-$1-ssh.log"; RR_PROJ="$TMPDIR/rr-$1-proj"
    mkdir -p "$RR_COPY/data" "$RR_PROJ"
    cp "$ROOT/cctrl" "$RR_COPY/cctrl"; chmod +x "$RR_COPY/cctrl"
    printf '{"ms":{"hostname":"example.invalid","user":"tester"}}\n' > "$RR_COPY/data/hosts.json"
    printf '{"k":{"dir":"%s","role":"orchestrator"}}\n' "$RR_PROJ" > "$RR_COPY/data/shortcuts.json"
    : > "$RR_LOG"
}

_remote_role() {
    # stdin /dev/null, stderr merged; run through a `--host ms` alias
    PATH="$TMPDIR:$PATH" SSH_LOG="$RR_LOG" CCTRL_PURPOSE_PROMPT=never "$RR_COPY/cctrl" --host ms "$@" </dev/null 2>&1
}

test_remote_preflight_forwards_resolved_role_and_kind() {
    _remote_role_fixture fwd
    local out rc=0 last
    out="$(SSH_PRE_OUT='role=orchestrator orch_kind=repo' _remote_role @k)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "remote launch failed: $out"
    [[ "$(grep -c '_role-resolve' "$RR_LOG")" -eq 1 ]] || fail "expected one preflight call: $(cat "$RR_LOG")"
    last="$(tail -n 1 "$RR_LOG")"
    assert_contains "$last" "--role\\ orchestrator\\ --orch-kind\\ repo"
    assert_not_contains "$last" "_role-resolve"
    echo "ok: the remote preflight result is forwarded as explicit flags"
}

test_remote_ambiguous_prompts_locally_and_forwards_kind() {
    _remote_role_fixture ask
    local rc=0 out_file="$TMPDIR/rr-ask.out"
    run_with_pty_input $'2\n' env PATH="$TMPDIR:$PATH" SSH_LOG="$RR_LOG" CCTRL_PURPOSE_PROMPT=never \
        SSH_PRE_RC=78 SSH_PRE_ERR='Cannot tell which kind of orchestrator this is: shortcut @k is an orchestrator with no orch_kind.' \
        "$RR_COPY/cctrl" --host ms @k > "$out_file" 2>&1 || rc=$?
    [[ "$rc" -eq 0 ]] || fail "a local answer must launch, got $rc: $(cat "$out_file")"
    assert_contains "$(cat "$out_file")" "Which kind of orchestrator"
    assert_contains "$(tail -n 1 "$RR_LOG")" "--role\\ orchestrator\\ --orch-kind\\ repo"
    echo "ok: an ambiguous remote kind is asked locally and forwarded"
}

test_remote_ambiguous_non_interactive_returns_78_with_message() {
    _remote_role_fixture noni
    local out rc=0
    out="$(SSH_PRE_RC=78 SSH_PRE_ERR=$'cctrl: needs-user-decision: orchestrator-kind\nCannot tell which kind of orchestrator this is: x.' _remote_role @k)" || rc=$?
    [[ "$rc" -eq 78 ]] || fail "expected 78, got $rc: $out"
    [[ "$(head -n 1 <<< "$out")" == "cctrl: needs-user-decision: orchestrator-kind" ]] || fail "remote stderr must be relayed first: $out"
    [[ "$(grep -vc '_role-resolve' "$RR_LOG")" -eq 0 ]] || fail "nothing may be launched: $(cat "$RR_LOG")"
    echo "ok: a non-interactive remote ambiguity returns 78 with the remote message"
}

test_remote_sets_no_input_on_remote_side() {
    _remote_role_fixture noin
    SSH_PRE_OUT='role=worker orch_kind=-' _remote_role @k >/dev/null || true
    assert_contains "$(tail -n 1 "$RR_LOG")" "CCTRL_NO_INPUT=1"
    assert_contains "$(head -n 1 "$RR_LOG")" "CCTRL_NO_INPUT=1"
    echo "ok: remote tmux launches run with CCTRL_NO_INPUT=1"
}

test_remote_old_cctrl_with_role_flags_exits_69() {
    _remote_role_fixture old
    local out rc=0
    out="$(SSH_PRE_RC=1 _remote_role start -d --orch-kind repo "$RR_PROJ")" || rc=$?
    [[ "$rc" -eq 69 ]] || fail "an old remote with role flags must exit 69, got $rc: $out"
    rc=0
    : > "$RR_LOG"
    out="$(SSH_PRE_RC=1 _remote_role @k)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "an old remote without role flags launches unchanged, got $rc: $out"
    assert_not_contains "$(tail -n 1 "$RR_LOG")" "--role"
    echo "ok: an old remote cctrl with role flags exits 69"
}

test_remote_dir_launch_without_role_flags_skips_preflight() {
    _remote_role_fixture skip
    _remote_role start -d "$RR_PROJ" >/dev/null || true
    assert_not_contains "$(cat "$RR_LOG")" "_role-resolve"
    echo "ok: a remote dir launch without role flags skips the preflight"
}

test_remote_preflight_exit_0_without_role_line_launches_unchanged() {
    _remote_role_fixture noline
    _remote_role @k >/dev/null || true
    assert_not_contains "$(tail -n 1 "$RR_LOG")" "--role"
    echo "ok: a preflight with no role= line launches unchanged"
}

test_remote_preflight_66_falls_through_to_launch() {
    _remote_role_fixture f66
    local rc=0
    SSH_PRE_RC=66 _remote_role @k >/dev/null || rc=$?
    [[ "$rc" -eq 0 ]] || fail "66 must fall through to the launch, got $rc"
    assert_not_contains "$(tail -n 1 "$RR_LOG")" "_role-resolve"
    echo "ok: preflight 66 falls through to the real launch"
}

test_remote_foreground_skips_preflight_and_role_flags() {
    _remote_role_fixture fg
    local out rc=0
    out="$(SSH_PRE_OUT='role=orchestrator orch_kind=repo' _remote_role start --foreground @k)" || rc=$?
    [[ "$(grep -c '_role-resolve' "$RR_LOG")" -eq 0 ]] || fail "foreground must not preflight: $(cat "$RR_LOG")"
    assert_not_contains "$(cat "$RR_LOG")" "--role"
    : > "$RR_LOG"
    out="$(SSH_PRE_OUT='role=orchestrator orch_kind=repo' _remote_role start --no-tmux @k)" || rc=$?
    [[ "$(grep -c '_role-resolve' "$RR_LOG")" -eq 0 ]] || fail "--no-tmux must not preflight: $(cat "$RR_LOG")"
    assert_not_contains "$(cat "$RR_LOG")" "--role"
    echo "ok: remote --foreground/--no-tmux skips the preflight and forwards no role flags"
}

test_remote_preflight_other_exit_code_is_relayed() {
    _remote_role_fixture other
    local out rc=0
    out="$(SSH_PRE_RC=127 SSH_PRE_ERR='cctrl: command not found' _remote_role @k)" || rc=$?
    [[ "$rc" -eq 127 ]] || fail "127 must be relayed, got $rc: $out"
    assert_contains "$out" "command not found"
    echo "ok: any other preflight exit code is relayed"
}

test_set_role_updates_live_session_and_keeps_label() {
    _rf_setup sr1 '{}'
    local out sess before after rc=0
    out="$(_rf start -d --purpose p "$RF_PROJ")"
    sess="$(_rf_session "$out")"
    before="$(session_record_json "$sess" | jq -c '[.display_label,.purpose,.name]')"
    out="$(TMUX_FAKE_HAS_SESSION="$sess" _rf session set-role "$sess" orchestrator --orch-kind fleet)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "set-role failed: $out"
    assert_contains "$out" "role=orchestrator orch_kind=fleet"
    after="$(session_record_json "$sess" | jq -c '[.display_label,.purpose,.name]')"
    [[ "$before" == "$after" ]] || fail "set-role must not touch label, purpose or name: $before -> $after"
    [[ "$(session_record_json "$sess" | jq -r '.role + "/" + .orch_kind')" == orchestrator/fleet ]] || fail "record not updated"
    assert_contains "$(cat "$RF_LOG")" "@cctrl_role orchestrator"
    assert_not_contains "$(cat "$RF_LOG")" "rename-session"
    echo "ok: set-role tags a live session without touching its label"
}

test_set_role_on_provisional_record() {
    _rf_setup sr2 '{}'
    local out sess
    out="$(_rf start -d --purpose p "$RF_PROJ")"
    sess="$(_rf_session "$out")"
    [[ "$(session_record_json "$sess" | jq -r '.lifecycle_state')" == provisional ]] || fail "fixture must be a provisional record"
    out="$(TMUX_FAKE_HAS_SESSION="$sess" _rf session set-role "$sess" worker)"
    assert_contains "$out" "record + tmux options"
    [[ "$(session_record_json "$sess" | jq -r '.role')" == worker ]] || fail "provisional record not updated: $out"
    echo "ok: set-role updates a provisional launch record"
}

test_set_role_clear_removes_fields() {
    _rf_setup sr3 '{}'
    local out sess
    out="$(_rf start -d --orch-kind repo --purpose p "$RF_PROJ")"
    sess="$(_rf_session "$out")"
    out="$(TMUX_FAKE_HAS_SESSION="$sess" _rf session set-role "$sess" --clear)"
    assert_contains "$out" "role cleared"
    [[ -z "$(session_record_json "$sess" | jq -r '.role // empty')" ]] || fail "role must be cleared"
    [[ -z "$(session_record_json "$sess" | jq -r '.orch_kind // empty')" ]] || fail "kind must be cleared"
    assert_contains "$(cat "$RF_LOG")" "-u @cctrl_role"
    echo "ok: set-role --clear removes role, kind and tmux options"
}

test_relaunch_with_new_role_replaces_recorded_role() {
    _rf_setup relaunch '{}'
    local out sess first
    out="$(_rf start -d --role worker -r conv-relaunch-1 --purpose p "$RF_PROJ")"
    sess="$(_rf_session "$out")"; first="$sess"
    [[ "$(session_record_json "$sess" | jq -r '.role')" == worker ]] || fail "first launch: $out"
    out="$(_rf start -d --orch-kind repo -r conv-relaunch-1 --purpose p "$RF_PROJ")"
    # One record per conversation: it keeps the first launch's tmux name.
    [[ "$(session_record_json "$first" | jq -r '.role + "/" + .orch_kind')" == orchestrator/repo ]] \
        || fail "a relaunch with a new role must replace the recorded one: $(session_record_json "$first")"
    echo "ok: a relaunch with a new role replaces the recorded role"
}

test_roleless_relaunch_keeps_recorded_role_and_kind() {
    _rf_setup keeprole '{}'
    local out sess first
    out="$(_rf start -d --role orchestrator --orch-kind repo -r conv-keep-1 --purpose p "$RF_PROJ")"
    sess="$(_rf_session "$out")"; first="$sess"
    [[ "$(session_record_json "$sess" | jq -r '.role + "/" + .orch_kind')" == orchestrator/repo ]] || fail "first launch: $out"
    out="$(_rf start -d -r conv-keep-1 --purpose p "$RF_PROJ")"
    sess="$(_rf_session "$out")"
    [[ "$(session_record_json "$sess" | jq -r '.role + "/" + .orch_kind')" == orchestrator/repo ]] \
        || fail "a role-less relaunch must keep the recorded role: $(session_record_json "$sess")"
    out="$(_rf start -d --role worker -r conv-keep-1 --purpose p "$RF_PROJ")"
    [[ "$(session_record_json "$first" | jq -r '.role + "/" + (.orch_kind // "")')" == worker/ ]] \
        || fail "an explicit --role worker must win and clear the kind: $(session_record_json "$first")"
    echo "ok: a role-less relaunch keeps the recorded role and kind; an explicit flag wins"
}

test_snapshot_launch_flags_carry_role_and_kind() {
    _rf_setup snapflags '{}'
    local out sess flags
    out="$(_rf start -d --orch-kind repo --purpose p "$RF_PROJ")"
    sess="$(_rf_session "$out")"
    flags="$(python3 "$ROOT/lib/snapshot_restore.py" launch-flags --metadata-dir "$CCTRL_SESSION_METADATA_DIR" --name "$sess")"
    [[ "$(jq -r '.role + "/" + .orch_kind' <<< "$flags")" == orchestrator/repo ]] || fail "launch_flags missing role: $flags"
    echo "ok: launch_flags carry role and orch_kind"
}

_restore_role_fixture() {
    # args: dir. A restore fixture whose cctrl row points at a real temp cwd so a
    # real _launch_detached (fake tmux) can run.
    local dir="$1"
    _restore_fixture "$dir"
    make_fake_tmux "$dir/bin/tmux"   # has-session says "not live", so the real launcher can pick a name
    mkdir -p "$dir/work"
    jq --arg w "$dir/work" '.tasks[].cwd = $w' "$dir/snapshots/latest.json" > "$dir/snap.tmp" && mv "$dir/snap.tmp" "$dir/snapshots/latest.json"
    jq --arg w "$dir/work" '.rows[].cwd = $w' "$dir/catalogue.json" > "$dir/cat.tmp" && mv "$dir/cat.tmp" "$dir/catalogue.json"
}

_restore_run_real() {
    # Like _restore_run but WITHOUT the launch-log seam: the real
    # _launch_detached runs against the fixture's fake tmux, in this
    # fixture's private metadata dir.
    local dir="$1"
    shift
    PATH="$dir/bin:$PATH" CCTRL_HOST_ID_FILE="$dir/host-id" CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_RESTORE_CATALOGUE_FILE="$dir/catalogue.json" CCTRL_RESTORE_PROCESS_FILE="$dir/process.json" \
        CCTRL_RESTORE_CODEX_EVIDENCE_FILE="$dir/codex.json" CCTRL_FAKE_MEM_FREE_PCT=80 CCTRL_FAKE_SWAP_MB=0 \
        CCTRL_RESTORE_MAX_ACTIVE=10 CCTRL_RESTORE_WAVE_SIZE=2 CCTRL_RESTORE_WAVE_PAUSE=0 CCTRL_NO_HEALTH_CHECK=1 \
        CCTRL_PURPOSE_PROMPT=never \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/latest.json" "$@"
}

test_restore_replays_role_and_kind() {
    local dir="$TMPDIR/restore-role"
    _restore_fixture "$dir"
    jq '(.tasks[] | select(.tmux_session=="TMUX--cctrl") | .launch_flags) += {role:"orchestrator",orch_kind:"repo"}' \
        "$dir/snapshots/latest.json" > "$dir/snap.tmp" && mv "$dir/snap.tmp" "$dir/snapshots/latest.json"
    _restore_run "$dir" --yes --quiet >/dev/null 2>&1 || fail "restore failed"
    assert_contains "$(grep -- '--resume\|-r conv-aaa-111' "$dir/launch.log" | head -n 1)" "--role orchestrator --orch-kind repo"
    echo "ok: restore replays role and orch_kind from launch_flags"
}

test_restore_legacy_row_infers_orchestrator_from_tmux_name() {
    local dir="$TMPDIR/restore-role-legacy"
    _restore_fixture "$dir"
    jq '(.tasks[] | select(.tmux_session=="TMUX--homelab") | .tmux_session) = "TMUX--ms--fm-homelab"' \
        "$dir/snapshots/latest.json" > "$dir/snap.tmp" && mv "$dir/snap.tmp" "$dir/snapshots/latest.json"
    _restore_run "$dir" --yes --quiet >/dev/null 2>&1 || fail "restore failed"
    local line
    line="$(grep 'conv-bbb-222' "$dir/launch.log" | head -n 1)"
    assert_contains "$line" "--role orchestrator"
    assert_not_contains "$line" "--orch-kind"
    echo "ok: a legacy fm-* row is replayed as an orchestrator of unknown kind"
}

test_restore_unknown_kind_row_never_asks() {
    local dir="$TMPDIR/restore-role-noask" out_file="$TMPDIR/restore-role-noask.out" rc=0
    _restore_role_fixture "$dir"
    jq '(.tasks[] | select(.tmux_session=="TMUX--cctrl") | .launch_flags) += {role:"orchestrator"}' \
        "$dir/snapshots/latest.json" > "$dir/snap.tmp" && mv "$dir/snap.tmp" "$dir/snapshots/latest.json"
    run_with_pty_input $'1\n' env PATH="$dir/bin:$PATH" CCTRL_HOST_ID_FILE="$dir/host-id" CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_RESTORE_CATALOGUE_FILE="$dir/catalogue.json" CCTRL_RESTORE_PROCESS_FILE="$dir/process.json" \
        CCTRL_RESTORE_CODEX_EVIDENCE_FILE="$dir/codex.json" CCTRL_FAKE_MEM_FREE_PCT=80 CCTRL_FAKE_SWAP_MB=0 \
        CCTRL_RESTORE_MAX_ACTIVE=10 CCTRL_RESTORE_WAVE_PAUSE=0 CCTRL_NO_HEALTH_CHECK=1 CCTRL_PURPOSE_PROMPT=never TMUX_LOG="$dir/tmux.log" \
        "$ROOT/cctrl" session restore --from "$dir/snapshots/latest.json" --only cctrl --yes > "$out_file" 2>&1 || rc=$?
    [[ "$rc" -eq 0 ]] || fail "restore of an unknown-kind orchestrator failed ($rc): $(cat "$out_file")"
    assert_not_contains "$(cat "$out_file")" "Which kind of orchestrator"
    local rec
    rec="$(grep -l 'conv-aaa-111\|TMUX--ms--cctrl' "$dir/session-metadata"/*.json 2>/dev/null | head -n 1)"
    [[ -n "$rec" ]] || fail "no record written by the restore: $(ls "$dir/session-metadata")"
    [[ "$(jq -r '.role' "$rec")" == orchestrator && -z "$(jq -r '.orch_kind // empty' "$rec")" ]] \
        || fail "expected orchestrator with an unknown kind: $(cat "$rec")"
    echo "ok: restore never asks about an unknown kind"
}

test_restore_old_snapshot_does_not_erase_recorded_kind() {
    local dir="$TMPDIR/restore-role-old"
    _restore_fixture "$dir"
    # The current registry record already carries role + kind; the snapshot row
    # has none (it predates `set-role`).
    CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" CCTRL_HOST_ID_FILE="$dir/host-id" CCTRL_HOST_PREFIX=ms \
        cctrl_source_eval '_session_write_metadata TMUX--ms--cctrl /tmp @cctrl @cctrl @cctrl p "" "cmd" "" claude conv-aaa-111 "" "" "" "" "" "" "" orchestrator repo' \
        || fail "fixture record could not be written"
    _restore_run "$dir" --yes --quiet >/dev/null 2>&1 || fail "restore failed"
    assert_contains "$(grep 'conv-aaa-111' "$dir/launch.log" | head -n 1)" "--role orchestrator --orch-kind repo"
    echo "ok: an old snapshot cannot erase the recorded kind"
}

test_restore_current_record_beats_snapshot_row_role() {
    local dir="$TMPDIR/restore-role-rec-wins"
    _restore_fixture "$dir"
    jq '(.tasks[] | select(.tmux_session=="TMUX--cctrl") | .launch_flags) += {role:"worker"}' \
        "$dir/snapshots/latest.json" > "$dir/snap.tmp" && mv "$dir/snap.tmp" "$dir/snapshots/latest.json"
    CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" CCTRL_HOST_ID_FILE="$dir/host-id" CCTRL_HOST_PREFIX=ms \
        cctrl_source_eval '_session_write_metadata TMUX--ms--cctrl /tmp @cctrl @cctrl @cctrl p "" "cmd" "" claude conv-aaa-111 "" "" "" "" "" "" "" orchestrator fleet' \
        || fail "fixture record could not be written"
    _restore_run "$dir" --yes --quiet >/dev/null 2>&1 || fail "restore failed"
    assert_contains "$(grep 'conv-aaa-111' "$dir/launch.log" | head -n 1)" "--role orchestrator --orch-kind fleet"
    assert_not_contains "$(grep 'conv-aaa-111' "$dir/launch.log" | head -n 1)" "--role worker"
    echo "ok: the current record beats a snapshot row's role"
}

test_recorded_worker_beats_legacy_name_inference() {
    local dir="$TMPDIR/restore-role-worker"
    _restore_fixture "$dir"
    jq '(.tasks[] | select(.tmux_session=="TMUX--homelab") | .tmux_session) = "TMUX--ms--fm-homelab"
        | (.tasks[] | select(.tmux_session=="TMUX--ms--fm-homelab") | .launch_flags) += {role:"worker"}' \
        "$dir/snapshots/latest.json" > "$dir/snap.tmp" && mv "$dir/snap.tmp" "$dir/snapshots/latest.json"
    _restore_run "$dir" --yes --quiet >/dev/null 2>&1 || fail "restore failed"
    local line
    line="$(grep 'conv-bbb-222' "$dir/launch.log" | head -n 1)"
    assert_contains "$line" "--role worker"
    assert_not_contains "$line" "--role orchestrator"
    echo "ok: a recorded worker beats legacy name inference"
}

test_ask_rechecks_tty_at_read_site() {
    # _CCTRL_CAN_ASK=1 was decided in main(), but fd 0 here is a pipe (as it is
    # inside restore's `while read ... < <(jq ...)`): the ask must refuse and
    # must not read the pipe.
    local out rc=0
    out="$(printf '1\n' | cctrl_source_eval '_CCTRL_CAN_ASK=1; ORCH_KIND_RESOLVED=""; _role_ask_kind "reason" "dir" "" || echo "RC=$?"; echo "KIND=$ORCH_KIND_RESOLVED"' 2>&1)" || rc=$?
    assert_contains "$out" "needs-user-decision: orchestrator-kind"
    assert_contains "$out" "RC=78"
    assert_not_contains "$out" "KIND=fleet"
    echo "ok: the ask re-tests the terminal at the read site"
}

test_restore_prints_reason_for_failed_row() {
    local dir="$TMPDIR/restore-role-fail" out rc=0
    _restore_role_fixture "$dir"
    jq '(.tasks[] | select(.tmux_session=="TMUX--cctrl") | .launch_flags) += {profile:"no-such-profile"}' \
        "$dir/snapshots/latest.json" > "$dir/snap.tmp" && mv "$dir/snap.tmp" "$dir/snapshots/latest.json"
    out="$(_restore_run_real "$dir" --only cctrl --yes 2>&1 </dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "a failed row must make restore exit non-zero: $out"
    assert_contains "$out" "TMUX--cctrl: "
    assert_contains "$out" "failed=1"
    echo "ok: restore prints the first stderr line of a failed row"
}

test_realign_flags_carry_role_and_kind() {
    local bin="$TMPDIR/rl-role-bin" sdir="$TMPDIR/rl-role-sessions" relog="$TMPDIR/rl-role-relaunch.log"
    _doctor_realign_fixture "$bin" "$sdir" "TMUX--ms--unstructured-data-portal-" "idle"
    jq '. + {role:"orchestrator",orch_kind:"repo"}' "$CCTRL_SESSION_METADATA_DIR/TMUX--ms--portal.json" > "$TMPDIR/rl-role.tmp" \
        && mv "$TMPDIR/rl-role.tmp" "$CCTRL_SESSION_METADATA_DIR/TMUX--ms--portal.json"
    : > "$relog"
    PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_DOCTOR_RELAUNCH_LOG="$relog" TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 \
        "$ROOT/cctrl" session doctor --fix --yes --json >/dev/null </dev/null
    assert_contains "$(cat "$relog")" "--role orchestrator --orch-kind repo"
    local hint
    hint="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 \
        "$ROOT/cctrl" session doctor --json </dev/null 2>/dev/null)" || true
    assert_contains "$hint" "realign_hint"
    assert_not_contains "$hint" "--role"
    echo "ok: realign carries role and orch_kind (the printed hint carries neither)"
}

test_realign_keeps_recorded_tmux_name() {
    local bin="$TMPDIR/rl-name-bin" sdir="$TMPDIR/rl-name-sessions" log="$TMPDIR/rl-name-tmux.log"
    _doctor_realign_fixture "$bin" "$sdir" "TMUX--ms--unstructured-data-portal-" "idle"
    : > "$log"
    PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" TMUX_LOG="$log" TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 \
        CCTRL_NO_HEALTH_CHECK=1 CCTRL_HOST_PREFIX=ms CCTRL_PURPOSE_PROMPT=never \
        "$ROOT/cctrl" session doctor --fix --yes --json >/dev/null 2>&1 </dev/null || true
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--ms--portal"
    echo "ok: realign relaunches under the recorded tmux name"
}

test_legacy_live_prefixed_session_reads_as_orchestrator_unknown_kind() {
    local out
    out="$(PATH="$TMPDIR:$PATH" cctrl_source_eval 'make() { :; }; _session_role_of TMUX--ms--fm-legacy-x')"
    [[ "$out" == "orchestrator||name" ]] || fail "expected orchestrator, unknown kind, from the name; got: $out"
    out="$(PATH="$TMPDIR:$PATH" cctrl_source_eval '_session_role_of TMUX--ms--plainone')"
    [[ "$out" == "worker||default" ]] || fail "expected a default worker; got: $out"
    echo "ok: a legacy fm-* session reads as an orchestrator of unknown kind"
}

test_recorded_worker_beats_legacy_name_inference_live() {
    local meta="$TMPDIR/role-live-meta"
    mkdir -p "$meta"
    printf '{"target":"/tmp","cwd":"/tmp","role":"worker"}\n' > "$meta/TMUX--ms--fm-homelab.json"
    local out
    out="$(PATH="$TMPDIR:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" cctrl_source_eval '_session_role_of TMUX--ms--fm-homelab')"
    [[ "$out" == "worker||record" ]] || fail "a recorded worker must beat name inference; got: $out"
    echo "ok: a recorded worker beats name inference for a live session"
}

test_session_ls_json_exposes_role_and_kind() {
    local meta="$TMPDIR/role-ls-meta" out
    make_fake_tmux "$TMPDIR/tmux"
    mkdir -p "$meta"
    printf '{"target":"/tmp","cwd":"/tmp","role":"orchestrator","orch_kind":"repo","purpose":"p"}\n' > "$meta/TMUX--ms--ls-role.json"
    out="$(PATH="$TMPDIR:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" TMUX_FAKE_SESSIONS="TMUX--ms--ls-role" "$ROOT/cctrl" session ls --json </dev/null)"
    [[ "$(jq -r '.[0].role + "/" + .[0].orch_kind' <<< "$out")" == orchestrator/repo ]] || fail "session ls --json role/orch_kind: $out"
    echo "ok: session ls --json exposes role and orch_kind"
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
    local bin="$TMPDIR/doctorbin" sdir="$TMPDIR/claude-sessions" meta="$TMPDIR/doctorbin-meta"
    mkdir -p "$bin" "$sdir" "$meta"
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

    # Plan 071 phase 7: the classifier now reads session metadata too, so this
    # test needs its own metadata dir -- isolated from any earlier test's
    # real `cctrl start --name TMUX--ms--portal` launch (a provisional
    # launch-*.json record keyed by that same session name, found by name
    # scan regardless of which dir it landed in) -- or it would pick that up
    # instead of staying metadata-free like a pre-071 session.
    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_SESSION_METADATA_DIR="$meta" TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session doctor --json)"
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
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_SESSION_METADATA_DIR="$meta" TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session doctor --json)"
    assert_contains "$out" '"remote_control": "dead"'
    assert_contains "$out" '"name_aligned": false'
}

test_session_doctor_detects_collision() {
    # Two sessions reporting the same bridgeSessionId = a bridge collision from a
    # shared name prefix. Both read "live" individually; only cross-checking ids
    # reveals it.
    local bin="$TMPDIR/colbin" sdir="$TMPDIR/col-sessions" meta="$TMPDIR/colbin-meta"
    mkdir -p "$bin" "$sdir" "$meta"
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
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_SESSION_METADATA_DIR="$meta" TMUX_FAKE_SESSIONS="TMUX--ms--homelab--3 TMUX--ms--homelab--5" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session doctor --json)"
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
    # Earlier launch tests intentionally reuse TMUX--ms--portal. Keep doctor
    # fixtures in their own registry so a newer canonical task record cannot
    # shadow the legacy metadata this fixture is explicitly exercising.
    export CCTRL_SESSION_METADATA_DIR="$TMPDIR/doctor-realign-metadata"
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

test_session_doctor_realign_carries_profile_model_peer() {
    # Plan 071 phase 6: realign must not silently drop the old session's
    # profile/model/peer -- it reads them back via launch_flags_for instead of
    # hand-adding only the corrected --name/--resume. profile comes from the
    # metadata record's own field (preferred over argv); model and peer come
    # from the argv parse of launch_command (unchanged mechanism).
    local bin="$TMPDIR/rl6bin" sdir="$TMPDIR/rl6-sessions" relog="$TMPDIR/rl6-relaunch.log"
    _doctor_realign_fixture "$bin" "$sdir" "TMUX--ms--unstructured-data-portal-" "idle"
    cat > "$CCTRL_SESSION_METADATA_DIR/TMUX--ms--portal.json" <<JSON
{"name":"TMUX--ms--portal","tmux_session":"TMUX--ms--portal","target":"$TMPDIR/rl-proj","cwd":"$TMPDIR/rl-proj","purpose":"realign me","profile":"work","launch_command":"cctrl start --foreground --model X --peer p"}
JSON
    : > "$relog"
    # own fixture profile: do not depend on the gitignored profiles/work.json
    mkdir -p "$TMPDIR/rl6-profiles"; printf '{}\n' > "$TMPDIR/rl6-profiles/work.json"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_PROFILES_DIR="$TMPDIR/rl6-profiles" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_DOCTOR_RELAUNCH_LOG="$relog" TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session doctor --fix --yes --json)"
    assert_contains "$out" '"action": "realigned'

    local cmd
    cmd="$(cat "$relog")"
    assert_contains "$cmd" '--profile work'
    assert_contains "$cmd" '--model X'
    assert_contains "$cmd" '--peer p'
    echo "ok: realign carries profile/model/peer forward"
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
    # Plan 071 phase 7: the bridge classifier now reads session metadata, so
    # give every autoheal test its own empty metadata dir -- isolated from
    # any earlier test's real `cctrl start --name TMUX--ms--portal` launch
    # (a provisional launch-*.json record found by session-name scan
    # regardless of which dir it landed in) -- or this fixture's session
    # would stop looking metadata-free like a pre-071 session.
    export CCTRL_SESSION_METADATA_DIR="$sdir/.autoheal-meta"
    mkdir -p "$CCTRL_SESSION_METADATA_DIR"
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

test_session_bridge_state_na_backend() {
    # Plan 071 phase 7: a session whose profile uses a non-subscription
    # backend is classified "na" -- the bridge can't authenticate there -- the
    # same way across ls, doctor, and autoheal. One fixture, three
    # assertions, per the plan's test list. Never /rc-repaired.
    local bin="$TMPDIR/na-bin" sdir="$TMPDIR/na-sessions" meta="$TMPDIR/na-meta"
    local rlog="$TMPDIR/na-repair.log" hlog="$TMPDIR/na-heal.log"
    mkdir -p "$bin" "$sdir" "$meta"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *4242* ]]; then
    echo "claude --name TMUX--ms--bedrock --remote-control --remote-control-session-name-prefix TMUX--ms--bedrock-"
    exit 0
fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    cat > "$sdir/4242.json" <<'JSON'
{"pid":4242,"name":"TMUX--ms--bedrock","status":"idle"}
JSON
    cat > "$meta/TMUX--ms--bedrock.json" <<'JSON'
{"name":"TMUX--ms--bedrock","agent":"claude","profile":"work","auth_backend":"bedrock","cctrl_managed":true}
JSON
    : > "$rlog"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_SESSIONS="TMUX--ms--bedrock" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session ls --json)"
    assert_contains "$out" '"remote_control": "na"'

    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_SESSIONS="TMUX--ms--bedrock" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session doctor --json)"
    assert_contains "$out" '"remote_control": "na"'

    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_SESSIONS="TMUX--ms--bedrock" TMUX_FAKE_PANE_PID=4242 \
        CCTRL_AUTOHEAL_LOG="$hlog" CCTRL_AUTOHEAL_REPAIR_LOG="$rlog" \
        "$ROOT/cctrl" session autoheal --json)"
    [[ "$out" == "[]" ]] || fail "na session must not be selected for autoheal (got: $out)"
    [[ -s "$rlog" ]] && fail "na session must NOT have /rc injected"
    echo "ok: na backend classified consistently across ls, doctor, autoheal; never /rc-repaired"
}

test_session_bridge_state_subscription_dead_still_heals() {
    # Regression: a post-071 session (metadata carries a `profile` field) on
    # the default subscription backend is still a plain live/dead bridge, and
    # a dead one is still autoheal-repairable -- having a `profile` field at
    # all must not reclassify it as na/na-inferred/unknown.
    local bin="$TMPDIR/subdead-bin" sdir="$TMPDIR/subdead-sessions" meta="$TMPDIR/subdead-meta"
    local rlog="$TMPDIR/subdead-repair.log" hlog="$TMPDIR/subdead-heal.log"
    mkdir -p "$bin" "$sdir" "$meta"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *4242* ]]; then
    echo "claude --name TMUX--ms--subdead --remote-control --remote-control-session-name-prefix TMUX--ms--subdead-"
    exit 0
fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    cat > "$sdir/4242.json" <<'JSON'
{"pid":4242,"name":"TMUX--ms--subdead","status":"idle"}
JSON
    cat > "$meta/TMUX--ms--subdead.json" <<'JSON'
{"name":"TMUX--ms--subdead","agent":"claude","profile":"personal","auth_backend":"subscription","cctrl_managed":true}
JSON
    : > "$rlog"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_SESSIONS="TMUX--ms--subdead" TMUX_FAKE_PANE_PID=4242 \
        TMUX_FAKE_CAPTURE_PANE='⏺ Done.' \
        CCTRL_AUTOHEAL_LOG="$hlog" CCTRL_AUTOHEAL_REPAIR_LOG="$rlog" \
        "$ROOT/cctrl" session autoheal --json)"
    assert_contains "$out" '"action": "healed"'
    assert_contains "$(cat "$rlog")" "TMUX--ms--subdead"
    echo "ok: a post-071 subscription-backend dead bridge still heals normally"
}

test_session_bridge_state_pre_change_inferred_and_unknown() {
    # Pre-071 sessions carry no `profile` metadata field at all. With no
    # bridge, the classifier infers backend from the claude pid's own env via
    # `ps eww` (grep -q only -- the content itself is never stored/printed,
    # R2): a provider var present -> na-inferred; ps unreadable -> unknown.
    # Neither is ever /rc-repaired.
    local bin="$TMPDIR/inf-bin" sdir="$TMPDIR/inf-sessions"
    local rlog="$TMPDIR/inf-repair.log" hlog="$TMPDIR/inf-heal.log"
    mkdir -p "$bin" "$sdir"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *4242* ]]; then
    if [[ "$*" == *eww* ]]; then
        echo "claude --name TMUX--ms--legacy --remote-control --remote-control-session-name-prefix TMUX--ms--legacy- CLAUDE_CODE_USE_BEDROCK=1"
    else
        echo "claude --name TMUX--ms--legacy --remote-control --remote-control-session-name-prefix TMUX--ms--legacy-"
    fi
    exit 0
fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    cat > "$sdir/4242.json" <<'JSON'
{"pid":4242,"name":"TMUX--ms--legacy","status":"idle"}
JSON
    : > "$rlog"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--legacy" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session ls --json)"
    assert_contains "$out" '"remote_control": "na-inferred"'
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--legacy" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session doctor --json)"
    assert_contains "$out" '"remote_control": "na-inferred"'
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--legacy" TMUX_FAKE_PANE_PID=4242 \
        CCTRL_AUTOHEAL_LOG="$hlog" CCTRL_AUTOHEAL_REPAIR_LOG="$rlog" \
        "$ROOT/cctrl" session autoheal --json)"
    [[ "$out" == "[]" ]] || fail "na-inferred session must not be autohealed (got: $out)"
    [[ -s "$rlog" ]] && fail "na-inferred session must NOT have /rc injected"

    # ps unreadable for the env probe (but cmd-sniffing still works) -> unknown.
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *4242* ]]; then
    if [[ "$*" == *eww* ]]; then
        exit 1
    fi
    echo "claude --name TMUX--ms--legacy --remote-control --remote-control-session-name-prefix TMUX--ms--legacy-"
    exit 0
fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--legacy" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session ls --json)"
    assert_contains "$out" '"remote_control": "unknown"'
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--legacy" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session doctor --json)"
    assert_contains "$out" '"remote_control": "unknown"'
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--legacy" TMUX_FAKE_PANE_PID=4242 \
        CCTRL_AUTOHEAL_LOG="$hlog" CCTRL_AUTOHEAL_REPAIR_LOG="$rlog" \
        "$ROOT/cctrl" session autoheal --json)"
    [[ "$out" == "[]" ]] || fail "unknown session must not be autohealed (got: $out)"
    [[ -s "$rlog" ]] && fail "unknown session must NOT have /rc injected"
    echo "ok: pre-change sessions classify na-inferred/unknown from env inference, never repaired"
}

test_session_bridge_state_never_prints_ps_env() {
    # R2: the pre-change inference reads the claude pid's env via `ps eww`
    # but must never surface that content. Plant a fixture secret in the fake
    # ps output and prove it never reaches ls, doctor (text + json), or
    # autoheal output.
    local bin="$TMPDIR/leak-bin" sdir="$TMPDIR/leak-sessions"
    local rlog="$TMPDIR/leak-repair.log" hlog="$TMPDIR/leak-heal.log"
    local secret="FIXTURE_SECRET_sk-test-do-not-leak-9f2a"
    mkdir -p "$bin" "$sdir"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<SH
#!/usr/bin/env bash
if [[ "\$*" == *4242* ]]; then
    if [[ "\$*" == *eww* ]]; then
        echo "claude --name TMUX--ms--leak --remote-control --remote-control-session-name-prefix TMUX--ms--leak- CLAUDE_CODE_USE_BEDROCK=1 ANTHROPIC_API_KEY=${secret}"
    else
        echo "claude --name TMUX--ms--leak --remote-control --remote-control-session-name-prefix TMUX--ms--leak-"
    fi
    exit 0
fi
exec /bin/ps "\$@"
SH
    chmod +x "$bin/ps"
    cat > "$sdir/4242.json" <<'JSON'
{"pid":4242,"name":"TMUX--ms--leak","status":"idle"}
JSON
    : > "$rlog"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--leak" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session ls 2>&1)"
    assert_not_contains "$out" "$secret"
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--leak" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session ls --json 2>&1)"
    assert_not_contains "$out" "$secret"
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--leak" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session doctor 2>&1)"
    assert_not_contains "$out" "$secret"
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--leak" TMUX_FAKE_PANE_PID=4242 "$ROOT/cctrl" session doctor --json 2>&1)"
    assert_not_contains "$out" "$secret"
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--leak" TMUX_FAKE_PANE_PID=4242 \
        CCTRL_AUTOHEAL_LOG="$hlog" CCTRL_AUTOHEAL_REPAIR_LOG="$rlog" \
        "$ROOT/cctrl" session autoheal --json 2>&1)"
    assert_not_contains "$out" "$secret"
    echo "ok: planted ps env secret never surfaces in ls, doctor, or autoheal output"
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

test_session_list_profile_column_mixed() {
    # Plan 071 phase 8: PROFILE column + --json fields, across a bedrock
    # profile, a plain subscription profile, a genuinely pre-071 record
    # (metadata exists but was never given a `profile` key at all -- the
    # real has("profile")==false path, not just "no metadata file"), and an
    # explicit --profile none no-overlay record (has("profile")==true,
    # value null). The first two must render "?" and "none" respectively --
    # the whole point of the has("profile") distinction.
    local bin="$TMPDIR/profcol-bin" meta="$TMPDIR/profcol-meta"
    mkdir -p "$bin" "$meta"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *4242* ]]; then
    echo "claude"
    exit 0
fi
exec /bin/ps "$@"
SH
    chmod +x "$bin/ps"
    cat > "$meta/TMUX--ms--work.json" <<'JSON'
{"name":"TMUX--ms--work","agent":"claude","profile":"work","profile_source":"explicit","auth_backend":"bedrock","cctrl_managed":true}
JSON
    cat > "$meta/TMUX--ms--personal.json" <<'JSON'
{"name":"TMUX--ms--personal","agent":"claude","profile":"personal","profile_source":"default","auth_backend":"subscription","cctrl_managed":true}
JSON
    # Metadata exists (this is a real, managed cctrl record) but was written
    # before phase 6 ever added the `profile` key -- no "profile" field at
    # all, not even null.
    cat > "$meta/TMUX--ms--legacy.json" <<'JSON'
{"name":"TMUX--ms--legacy","agent":"claude","cctrl_managed":true,"purpose":"pre-071 session"}
JSON
    cat > "$meta/TMUX--ms--none.json" <<'JSON'
{"name":"TMUX--ms--none","agent":"claude","profile":null,"profile_source":"explicit","auth_backend":"subscription","cctrl_managed":true}
JSON

    local sessions="TMUX--ms--work TMUX--ms--personal TMUX--ms--legacy TMUX--ms--none"
    local out
    out="$(PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_SESSIONS="$sessions" TMUX_FAKE_PANE_PID=4242 \
        "$ROOT/cctrl" session ls)"
    echo "$out" | grep "TMUX--ms--work" | grep -q "work·bedrock" || fail "work row must show 'work·bedrock' in its own PROFILE column: $out"
    echo "$out" | grep "TMUX--ms--personal" | grep -q "·subscription" && fail "subscription (the default backend) must never get a ·backend suffix: $out"
    # " ? " / " none " (surrounded by the format's own separator+padding
    # spaces) targets the PROFILE column specifically -- a bare '?' or
    # 'none' substring would also match inside the KIND column's model
    # placeholder ("claude (?)") or elsewhere.
    echo "$out" | grep "TMUX--ms--legacy" | grep -q ' ? ' || fail "pre-071 row (no profile key at all) must show '?' in the PROFILE column: $out"
    echo "$out" | grep "TMUX--ms--none" | grep -q ' none ' || fail "explicit --profile none row must show 'none' in the PROFILE column: $out"

    local jout
    jout="$(PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" \
        TMUX_FAKE_SESSIONS="$sessions" TMUX_FAKE_PANE_PID=4242 \
        "$ROOT/cctrl" session ls --json)"
    printf '%s\n' "$jout" | jq -e '
        (map(select(.name=="TMUX--ms--work"))[0] | .profile=="work" and .profile_source=="explicit" and .auth_backend=="bedrock")
        and (map(select(.name=="TMUX--ms--personal"))[0] | .profile=="personal" and .profile_source=="default" and .auth_backend=="subscription")
        and (map(select(.name=="TMUX--ms--legacy"))[0] | .profile==null and .profile_source==null and .auth_backend==null)
        and (map(select(.name=="TMUX--ms--none"))[0] | .profile==null and .profile_source=="explicit" and .auth_backend=="subscription")
    ' >/dev/null || fail "profile/profile_source/auth_backend --json fields wrong: $jout"
    echo "ok: session ls PROFILE column and --json fields handle bedrock/subscription/pre-071/explicit-none"
}

test_statusline_bridge_label_and_rate_limit_gate() {
    # Plan 071 phase 8: the visible label comes from CCTRL_SESSION_PROFILE
    # (never the configured default or the legacy single-machine
    # .active-profile file), shown as a "[profile·backend]" prefix only when
    # the auth backend isn't the subscription default. The rate-limit file
    # write stays gated on `rate_limits` being present in the hook input --
    # proven here by never giving that key, so this test cannot touch the
    # live, shared data/rate-limits.json.
    local payload rl_file rl_before rl_after out
    payload='{"model":{"display_name":"Opus"},"cwd":"/tmp/demo","context_window":{"total_input_tokens":500}}'
    rl_file="$ROOT/data/rate-limits.json"
    rl_before=""
    [[ -f "$rl_file" ]] && rl_before="$(cat "$rl_file")"

    out="$("$ROOT/hooks/statusline.sh" <<< "$payload")"
    assert_contains "$out" "Opus | demo | 500"
    assert_not_contains "$out" "["

    out="$(CCTRL_SESSION_AUTH_BACKEND=bedrock CCTRL_SESSION_PROFILE=work "$ROOT/hooks/statusline.sh" <<< "$payload")"
    assert_contains "$out" "[work·bedrock] Opus | demo | 500"

    out="$(CCTRL_SESSION_AUTH_BACKEND=bedrock "$ROOT/hooks/statusline.sh" <<< "$payload")"
    assert_contains "$out" "[unknown·bedrock] Opus | demo | 500"

    out="$(CCTRL_SESSION_AUTH_BACKEND=subscription CCTRL_SESSION_PROFILE=personal "$ROOT/hooks/statusline.sh" <<< "$payload")"
    assert_contains "$out" "Opus | demo | 500"
    assert_not_contains "$out" "["

    rl_after=""
    [[ -f "$rl_file" ]] && rl_after="$(cat "$rl_file")"
    [[ "$rl_before" == "$rl_after" ]] || fail "rate-limits.json changed even though the fixture input carried no rate_limits key"
    echo "ok: statusline bridge-label prefix (bedrock, unset-profile, subscription-no-prefix); rate-limit write still gated"
}

test_session_log_concurrency_regression() {
    # Plan 071 phase 8 REGRESSION: the old implementation rglobbed every
    # ~/.claude/projects/*.jsonl touched in the last 120s, so a concurrent
    # second session's usage could bleed into the wrong profile's log. It now
    # processes only the transcript the Stop hook's own stdin names.
    local root="$TMPDIR/seslog-root" projdir="$TMPDIR/seslog-proj"
    mkdir -p "$root/hooks" "$projdir"
    cp "$ROOT/hooks/session-log.py" "$root/hooks/session-log.py"
    local t_a="$projdir/a.jsonl" t_b="$projdir/b.jsonl"
    cat > "$t_a" <<'JSONL'
{"sessionId":"sess-a","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":111,"output_tokens":22}}}
JSONL
    cat > "$t_b" <<'JSONL'
{"sessionId":"sess-b","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":999,"output_tokens":88}}}
JSONL
    touch "$t_a" "$t_b"

    local hook_in spend
    hook_in="$(jq -nc --arg tp "$t_a" '{transcript_path:$tp, session_id:"sess-a"}')"
    spend="$root/costs/spending.jsonl"

    printf '%s' "$hook_in" | CCTRL_SESSION_PROFILE=work CCTRL_SESSION_AUTH_BACKEND=bedrock \
        python3 "$root/hooks/session-log.py"
    [[ -f "$spend" ]] || fail "expected $spend to be written"
    local body
    body="$(cat "$spend")"
    assert_contains "$body" '"session_id": "sess-a"'
    assert_contains "$body" '"input_tokens": 111'
    assert_contains "$body" '"profile": "work"'
    assert_contains "$body" '"auth_backend": "bedrock"'
    assert_not_contains "$body" "sess-b"
    assert_not_contains "$body" "999"
    echo "ok: session-log.py logs only the transcript the hook stdin names, with env profile/auth_backend"
}

test_hooks_run_stop_tees_stdin_to_notify_and_session_log() {
    # Plan 071 phase 8: notify.sh and session-log.py each used to read stdin
    # independently; the first one to run (notify.sh) drained the pipe, so
    # session-log.py (now that it also reads stdin) got nothing. `hooks run
    # stop` must capture stdin once and hand the same bytes to both.
    local scratch="$TMPDIR/stop-tee"
    mkdir -p "$scratch/hooks"
    cp "$ROOT/cctrl" "$scratch/cctrl"
    chmod +x "$scratch/cctrl"
    cat > "$scratch/hooks/notify.sh" <<SH
#!/usr/bin/env bash
cat > "$scratch/notify.in"
SH
    chmod +x "$scratch/hooks/notify.sh"
    cat > "$scratch/hooks/session-log.py" <<PY
import sys
with open("$scratch/sessionlog.in", "w") as f:
    f.write(sys.stdin.read())
PY

    local payload
    payload='{"transcript_path":"/tmp/x","session_id":"abc"}'
    printf '%s' "$payload" | "$scratch/cctrl" hooks run stop
    [[ "$(cat "$scratch/notify.in" 2>/dev/null)" == "$payload" ]] || fail "notify.sh did not receive the full stop stdin"
    [[ "$(cat "$scratch/sessionlog.in" 2>/dev/null)" == "$payload" ]] || fail "session-log.py did not receive the full stop stdin"
    echo "ok: hooks run stop tees one stdin capture to both notify.sh and session-log.py"
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
# Pane/window-target commands (list-panes, display-message, display,
# capture-pane, ...) require the trailing ":" on tmux's exact "=NAME" match
# syntax; a bare "=NAME" (no colon) must fail to resolve, matching real tmux
# (verified against tmux 3.7c; see plan 080's review). Strip a well-formed
# "=NAME:" down to the bare name; leave a colon-less "=NAME" as a target
# nothing below will match.
if [[ "$target" == *: ]]; then
    target="${target#=}"
    target="${target%:}"
elif [[ "$target" == "="* ]]; then
    target="__cctrl_test_unmatched__"
fi
if [[ "${1:-}" == "-u" ]]; then shift; fi
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
# Pane/window-target commands (list-panes, display-message, display,
# capture-pane, ...) require the trailing ":" on tmux's exact "=NAME" match
# syntax; a bare "=NAME" (no colon) must fail to resolve, matching real tmux
# (verified against tmux 3.7c; see plan 080's review). Strip a well-formed
# "=NAME:" down to the bare name; leave a colon-less "=NAME" as a target
# nothing below will match.
if [[ "$target" == *: ]]; then
    target="${target#=}"
    target="${target%:}"
elif [[ "$target" == "="* ]]; then
    target="__cctrl_test_unmatched__"
fi
if [[ "${1:-}" == "-u" ]]; then shift; fi
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
# Pane/window-target commands (list-panes, display-message, display,
# capture-pane, ...) require the trailing ":" on tmux's exact "=NAME" match
# syntax; a bare "=NAME" (no colon) must fail to resolve, matching real tmux
# (verified against tmux 3.7c; see plan 080's review). Strip a well-formed
# "=NAME:" down to the bare name; leave a colon-less "=NAME" as a target
# nothing below will match.
if [[ "$target" == *: ]]; then
    target="${target#=}"
    target="${target%:}"
elif [[ "$target" == "="* ]]; then
    target="__cctrl_test_unmatched__"
fi
if [[ "${1:-}" == "-u" ]]; then shift; fi
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
# Pane/window-target commands (list-panes, display-message, display,
# capture-pane, ...) require the trailing ":" on tmux's exact "=NAME" match
# syntax; a bare "=NAME" (no colon) must fail to resolve, matching real tmux
# (verified against tmux 3.7c; see plan 080's review). Strip a well-formed
# "=NAME:" down to the bare name; leave a colon-less "=NAME" as a target
# nothing below will match.
if [[ "$target" == *: ]]; then
    target="${target#=}"
    target="${target%:}"
elif [[ "$target" == "="* ]]; then
    target="__cctrl_test_unmatched__"
fi
if [[ "${1:-}" == "-u" ]]; then shift; fi
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
    local fn="$TMPDIR/pane-draft-fn.sh" SCRIPT_DIR="$ROOT"
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
    # Plan 073: Claude Code's predicted next prompt is dimmed ghost text in an
    # EMPTY composer (the exact bytes it draws: ❯, U+00A0, SGR 2 … SGR 0).
    ! _session_pane_has_draft "$(cat "$fx/pane-ghost-suggestion.txt")" \
        || fail "dimmed ghost suggestion was read as an unsent draft"
    ! _session_pane_has_draft $'\xe2\x9d\xaf\xc2\xa0\e[7my\e[27m\e[2meah clean up the scaffolded project\e[0m' \
        || fail "ghost suggestion under a reverse-video cursor was read as a draft"
    _session_pane_has_draft $'\xe2\x9d\xaf\xc2\xa0fix the tests\e[7m \e[27m' \
        || fail "typed text in an escaped capture was not detected as a draft"
    _session_pane_has_draft $'\xe2\x9d\xaf\xc2\xa0\e[2myeah\e[0m\e[38;5;231m and more\e[39m' \
        || fail "typed text after ghost text was not detected as a draft"
    # Review P2: hint words inside a typed draft don't make it a placeholder.
    _session_pane_has_draft '❯ check lib/ for the retry bug' \
        || fail "a draft containing 'lib/ for' was read as a placeholder"
    _session_pane_has_draft '❯ list the for commands we support' \
        || fail "a draft containing 'for commands' was read as a placeholder"
    # Review P3: colon SGR sub-parameters and OSC 8 links ended by ST.
    ! _session_pane_has_draft $'\xe2\x9d\xaf\xc2\xa0\e[2;4:3myeah clean up\e[0m' \
        || fail "ghost text with a colon SGR code was read as a draft"
    ! _session_pane_has_draft $'\e]8;;https://example.com\e\\link\e]8;;\e\\\n\xe2\x9d\xaf\xc2\xa0\e[2mghost\e[0m' \
        || fail "an OSC 8 link ended by ST broke ghost-text parsing"
    # A failing detector is neither "draft" (0) nor "no draft" (1).
    local rc=0
    SCRIPT_DIR="$TMPDIR/no-such-cctrl" _session_pane_has_draft '❯ hi' || rc=$?
    (( rc > 1 )) || fail "a failing draft detector returned $rc instead of an unverifiable status"
    # Only the last prompt line is the composer: a submitted "❯ yes" in the
    # transcript above an empty composer is not a draft (seen live 2026-09-27).
    ! _session_pane_has_draft $'\e[38;5;239m\e[48;5;237m\xe2\x9d\xaf \e[38;5;231myes\e[39m\n  answer text\n\e[39m\xe2\x9d\xaf\xc2\xa0' \
        || fail "a submitted transcript line above an empty composer was read as a draft"
    echo "ok: _session_pane_has_draft fires on ❯ and > drafts, ignores hint text and dimmed ghost suggestions"
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
# Pane/window-target commands (list-panes, display-message, display,
# capture-pane, ...) require the trailing ":" on tmux's exact "=NAME" match
# syntax; a bare "=NAME" (no colon) must fail to resolve, matching real tmux
# (verified against tmux 3.7c; see plan 080's review). Strip a well-formed
# "=NAME:" down to the bare name; leave a colon-less "=NAME" as a target
# nothing below will match.
if [[ "$target" == *: ]]; then
    target="${target#=}"
    target="${target%:}"
elif [[ "$target" == "="* ]]; then
    target="__cctrl_test_unmatched__"
fi
if [[ "${1:-}" == "-u" ]]; then shift; fi
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
    # An empty composer showing only the dimmed ghost suggestion is not a draft.
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        DRAFT_FIXTURE="$ROOT/tests/fixtures/pane-ghost-suggestion.txt" \
        TMUX_FAKE_SESSIONS="TMUX--glyphdraft" "$ROOT/cctrl" session ls --json)"
    state="$(printf '%s' "$out" | jq -r '.[0].state')"
    [[ "$state" != "unsent-draft" ]] || fail "dimmed ghost suggestion surfaced as unsent-draft in session ls"

    # Plan 086: a wrapped/multi-line draft whose first composer line is empty
    # still surfaces as unsent-draft through the full rich-state path.
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        DRAFT_FIXTURE="$ROOT/tests/fixtures/pane-draft-multiline.txt" \
        TMUX_FAKE_SESSIONS="TMUX--glyphdraft" "$ROOT/cctrl" session ls --json)"
    state="$(printf '%s' "$out" | jq -r '.[0].state')"
    [[ "$state" == "unsent-draft" ]] \
        || fail "expected a multi-line draft with an empty first composer line to surface as unsent-draft; got: $state"

    # Plan 086: a bash-mode "!" prompt with an older submitted "❯ ..." line
    # still visible in scrollback must NOT surface as unsent-draft — the
    # detector's "no composer found" (rc=2) falls through to the base state,
    # same as any other rc it doesn't recognize as a draft.
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        DRAFT_FIXTURE="$ROOT/tests/fixtures/pane-bashmode-with-history.txt" \
        TMUX_FAKE_SESSIONS="TMUX--glyphdraft" "$ROOT/cctrl" session ls --json)"
    state="$(printf '%s' "$out" | jq -r '.[0].state')"
    [[ "$state" == "idle" ]] \
        || fail "expected a glyph-less bash-mode composer with older scrollback to keep the base 'idle' state; got: $state"

    echo "ok: rich-state surfaces a ❯ (U+276F) input line as unsent-draft, but not a dimmed ghost suggestion"
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

    # Plan 073: if the draft detector itself fails, the gate fails closed —
    # it can't confirm the input line is empty, so it never sends C-u.
    local brokebin="$TMPDIR/ah-glyph-brokeperl"
    mkdir -p "$brokebin"
    printf '#!/usr/bin/env bash
exit 2
' > "$brokebin/perl"; chmod +x "$brokebin/perl"
    : > "$rlog"
    out="$(PATH="$brokebin:$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 \
        TMUX_FAKE_CAPTURE_PANE="$(cat "$ROOT/tests/fixtures/pane-empty-hint.txt")" \
        CCTRL_AUTOHEAL_LOG="$hlog" CCTRL_AUTOHEAL_REPAIR_LOG="$rlog" \
        "$ROOT/cctrl" session autoheal --json)"
    assert_contains "$out" '"reason": "unverifiable-input"'
    [[ -s "$rlog" ]] && fail "autoheal repaired a session although the draft detector failed"

    # Plan 086: a real "no composer found" pane (bash-mode "!" prompt, an
    # older submitted "❯ ..." line still in scrollback) must fail closed the
    # same way, via rc=2 rather than a broken detector.
    : > "$rlog"
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" \
        TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 \
        TMUX_FAKE_CAPTURE_PANE="$(cat "$ROOT/tests/fixtures/pane-bashmode-with-history.txt")" \
        CCTRL_AUTOHEAL_LOG="$hlog" CCTRL_AUTOHEAL_REPAIR_LOG="$rlog" \
        "$ROOT/cctrl" session autoheal --json)"
    assert_contains "$out" '"action": "skipped"'
    assert_contains "$out" '"reason": "unverifiable-input"'
    [[ -s "$rlog" ]] && fail "autoheal repaired a session with no composer found (bash-mode prompt)"

    echo "ok: autoheal safety gate skips a ❯ (U+276F) real-pane draft and fails closed when the detector fails or finds no composer"
}

# --- plan 086: draft detector follow-ups from the 073 re-review ---
# Fixtures below are real `tmux capture-pane -e` output harvested from a live
# Claude Code v2.1.281 pane (see docs/plans/086), not hand-crafted: the plain
# dash-divider composer style, a wrapped long line, a newline-then-type
# multi-line draft whose first composer line is empty, and a bash-mode "!"
# prompt with a real submitted "❯ ..." line still visible higher in
# scrollback (the exact shape that used to misreport as a draft).
test_pane_draft_plan086_followups() {
    local fn="$TMPDIR/pane-draft-fn086.sh" SCRIPT_DIR="$ROOT"
    awk '/^_session_pane_has_draft\(\) \{/,/^}/' "$ROOT/cctrl" > "$fn"
    # shellcheck source=/dev/null
    source "$fn"
    local fx="$ROOT/tests/fixtures"

    # Wrapped/multi-line drafts (requirement 1): every composer line up to the
    # bottom border is judged, not just the first.
    _session_pane_has_draft "$(cat "$fx/pane-draft-wrapped.txt")" \
        || fail "a long wrapped composer line was not detected as a draft"
    # Eng-review regression (border-pair scoping): when the capture window
    # cuts off the composer's TOP border (only the bottom border and footer
    # remain in view), the single-border fallback must still find the draft
    # on the side that actually holds a glyph line, not blindly assume
    # "after the border" (that used to mean the footer here, losing the draft).
    _session_pane_has_draft "$(cat "$fx/pane-draft-wrapped-truncated-top.txt")" \
        || fail "a draft was missed when its composer's top border scrolled out of the capture window"
    _session_pane_has_draft "$(cat "$fx/pane-draft-multiline.txt")" \
        || fail "a draft whose first composer line is empty but a wrapped continuation line holds real text was not detected"

    # "no composer found" gets its own exit code (requirement 2), distinct
    # from both draft (0) and empty composer (1): a bash-mode "!" prompt with
    # an older submitted "❯ ..." line still in scrollback above it must not
    # be misread as a live draft just because it's the last glyph line seen.
    local rc=0
    _session_pane_has_draft "$(cat "$fx/pane-bashmode-with-history.txt")" || rc=$?
    (( rc == 2 )) || fail "expected 'no composer found' (rc=2) for a bash-mode prompt with older scrollback; got rc=$rc"

    # A draft whose entire typed content is the single character '>' or '|'
    # must still be detected — neither is border/whitespace filler once it is
    # the composer's own typed text, not the box's own drawing.
    _session_pane_has_draft $'\xe2\x9d\xaf >' \
        || fail "a draft consisting only of '>' was not detected"
    _session_pane_has_draft $'\xe2\x9d\xaf |' \
        || fail "a draft consisting only of '|' was not detected"

    # requirement 5: the hint-word fallback only fires on a composer line with
    # NO escape sequences at all. An escaped capture already excludes a real
    # dimmed placeholder by dimness, so real typed text starting with "Try "
    # must not be excluded just because some (non-dim) SGR appears on the
    # line.
    _session_pane_has_draft $'\xe2\x9d\xaf \e[38;5;231mTry "foo" as the new name\e[39m' \
        || fail "escaped typed text starting with 'Try ' was misread as the placeholder"
    # Plain capture (no SGR at all): the hint-word fallback still applies and
    # this remains a known, accepted limitation (073 review) — not exercised
    # by either production caller, which always pass an escaped capture.
    ! _session_pane_has_draft '❯ Try "foo" as the new name' \
        || fail "plain-capture 'Try ' hint fallback regressed (should still exclude, by design)"

    # requirement 3: verified live against a real Claude Code v2.1.281 pane
    # (docs/plans/086) that the "[Pasted text #N +M lines]" placeholder is
    # drawn in the default foreground, not dim — so it already reads as a
    # draft with no detector change needed. Pinned here against the real
    # captured bytes so a future rendering change would be caught.
    _session_pane_has_draft "$(cat "$fx/pane-pasted-text.txt")" \
        || fail "the '[Pasted text ...]' placeholder was not detected as a draft"

    echo "ok: plan 086 draft-detector follow-ups (multi-line, >/| content, no-composer exit code, hint/SGR gating, pasted-text placeholder)"
}

# --- plan 086 hotfix: single-border fallback misread an empty composer as a
# draft when its top edge is a plain-dash divider carrying a title (tmux's
# own pane-border-status line, e.g. "── portal: resume from handoff ... ──"),
# because that line isn't ALL border-drawing characters so only the bottom
# divider registered as a border. The single-border fallback then scoped the
# composer from index 0 (the FIRST glyph line anywhere in the whole captured
# scrollback) through the border, instead of the LAST glyph line immediately
# above it, so real conversation text in between read as "typed" content.
# Found live 2026-09-29: 3 idle fleet sessions showed as unsent-draft.
test_pane_draft_plan086_hotfix_titled_divider() {
    local fn="$TMPDIR/pane-draft-fn086hotfix.sh" SCRIPT_DIR="$ROOT"
    awk '/^_session_pane_has_draft\(\) \{/,/^}/' "$ROOT/cctrl" > "$fn"
    # shellcheck source=/dev/null
    source "$fn"
    local fx="$ROOT/tests/fixtures"

    ! _session_pane_has_draft "$(cat "$fx/pane-draft-titled-divider-empty.txt")" \
        || fail "an empty composer (❯ + NBSP only) under a titled top divider was read as a draft"
    ! _session_pane_has_draft "$(cat "$fx/pane-draft-titled-divider-ghost.txt")" \
        || fail "a dimmed ghost suggestion under a titled top divider was read as a draft"

    echo "ok: plan 086 hotfix — single-border fallback uses the last glyph line, not the first, so a titled top divider doesn't misread scrollback as a draft"
}

test_strip_sgr_shared_regex() {
    # requirement 4: _strip_sgr and lib/pane_draft.pl share one escape regex
    # (lib/ansi_escape.pl, plan 086). Probe _strip_sgr with the same
    # colon-SGR-subparameter and ST-terminated-OSC shapes plan 073 hardened
    # pane_draft.pl against, so the two can't silently drift apart again.
    local fn="$TMPDIR/strip-sgr-fn086.sh" SCRIPT_DIR="$ROOT"
    awk '/^_strip_sgr\(\) \{/,/^}/' "$ROOT/cctrl" > "$fn"
    # shellcheck source=/dev/null
    source "$fn"

    local out
    out="$(_strip_sgr $'\e[2;4:3myeah\e[0m plain text')"
    [[ "$out" == "yeah plain text" ]] \
        || fail "_strip_sgr did not strip a colon-SGR-subparameter sequence; got: $out"
    out="$(_strip_sgr $'\e]8;;https://example.com\e\\link\e]8;;\e\\ trailing')"
    [[ "$out" == "link trailing" ]] \
        || fail "_strip_sgr did not strip an ST-terminated OSC 8 link; got: $out"
    echo "ok: _strip_sgr shares lib/pane_draft.pl's escape regex (colon SGR sub-params, ST-terminated OSC)"
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
# Pane/window-target commands (list-panes, display-message, display,
# capture-pane, ...) require the trailing ":" on tmux's exact "=NAME" match
# syntax; a bare "=NAME" (no colon) must fail to resolve, matching real tmux
# (verified against tmux 3.7c; see plan 080's review). Strip a well-formed
# "=NAME:" down to the bare name; leave a colon-less "=NAME" as a target
# nothing below will match.
if [[ "$target" == *: ]]; then
    target="${target#=}"
    target="${target%:}"
elif [[ "$target" == "="* ]]; then
    target="__cctrl_test_unmatched__"
fi
if [[ "${1:-}" == "-u" ]]; then shift; fi
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
if [[ "${1:-}" == "-u" ]]; then shift; fi
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

    out="$(PATH="$(_test_path --sbin)" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer ls --json)"
    assert_contains "$out" '"derived_skipped": true'
    assert_contains "$out" '"derived_skip_reason": "tmux unavailable"'
    assert_contains "$out" '"name": "offline"'

    out="$(PATH="$(_test_path --sbin)" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer resolve offline --json)"
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
    assert_contains "$(cat "$log")" "paste-buffer -p -r -b cctrl-nudge-$peer-"
    assert_contains "$(cat "$log")" "send-keys -t =$session: Enter"
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
if [[ "${1:-}" == "-u" ]]; then shift; fi
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
    count="$(grep -Ec 'TMUX (-u )?list-sessions' "$log" || true)"
    [[ "$count" -eq 1 ]] || fail "expected exactly 1 session enumeration for peer overview, got $count"

    # (3) derived_skipped passthrough: with tmux unavailable the manual identity and
    # mailbox counts still resolve, no derived peers appear, and the skip reason is
    # surfaced instead of failing the whole call.
    out="$(PATH="$(_test_path --sbin)" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer overview --as comet --json)"
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

test_peer_send_sender_binding_refuses_mismatch() {
    # plan 077: a tmux-hosted caller can only send AS its own live tmux session
    # (or a role alias bound to it) — never a literal, possibly-stale/reused
    # session name — unless --impersonate is given. Closes msg_20260927_175609_8f2f78.
    # TMUX_FAKE_PANE_PID=__current__ makes the fake tmux report this test
    # process's own pid as the pane pid, so _session_current_name's pane-
    # ancestry check (it doesn't trust bare $TMUX alone) resolves trivially.
    local bin="$TMPDIR/bindbin" data="$TMPDIR/peer-bind-data"
    mkdir -p "$bin" "$data" "$CCTRL_SESSION_METADATA_DIR"
    make_fake_tmux "$bin/tmux"
    cat > "$CCTRL_SESSION_METADATA_DIR/TMUX--sender-a.json" <<'JSON'
{"name":"TMUX--sender-a","agent":"claude","created_at":"2026-09-27T10:00:00Z","cctrl_managed":true}
JSON
    cat > "$CCTRL_SESSION_METADATA_DIR/TMUX--sender-b.json" <<'JSON'
{"name":"TMUX--sender-b","agent":"claude","created_at":"2026-09-27T10:05:00Z","cctrl_managed":true}
JSON
    PATH="$bin:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register mailbox-only --dir /tmp/mo --agent codex >/dev/null

    local before=0 after=0 out rc=0
    [[ -f "$data/messages.jsonl" ]] && before="$(wc -l < "$data/messages.jsonl" | tr -d ' ')"
    out="$(PATH="$bin:$PATH" TMUX="fake,1,0" TMUX_FAKE_PANE_PID=__current__ TMUX_FAKE_SESSIONS="TMUX--sender-a TMUX--sender-b" TMUX_FAKE_SESSION_NAME="TMUX--sender-a" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send mailbox-only --as TMUX--sender-b --json -- "impersonation attempt" 2>&1)" || rc=$?
    [[ "$rc" -eq 66 ]] || fail "expected exit 66 for a sender that isn't the caller's own tmux session, got $rc"
    assert_contains "$out" "not your session"
    [[ -f "$data/messages.jsonl" ]] && after="$(wc -l < "$data/messages.jsonl" | tr -d ' ')"
    [[ "$before" == "$after" ]] || fail "expected no message written on sender-binding refusal (was $before, now $after)"

    # Sending as yourself still works, and records the plan-077 audit fields.
    rc=0
    out="$(PATH="$bin:$PATH" TMUX="fake,1,0" TMUX_FAKE_PANE_PID=__current__ TMUX_FAKE_SESSIONS="TMUX--sender-a TMUX--sender-b" TMUX_FAKE_SESSION_NAME="TMUX--sender-a" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send mailbox-only --as TMUX--sender-a --json -- "as myself")" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected send as own session to succeed"
    printf '%s\n' "$out" | jq -e '.audit.requested_from == "TMUX--sender-a"' >/dev/null || fail "expected requested_from audit field"
    printf '%s\n' "$out" | jq -e '.audit.requested_to == "mailbox-only"' >/dev/null || fail "expected requested_to audit field"
    printf '%s\n' "$out" | jq -e '.audit.caller_tmux_session == "TMUX--sender-a"' >/dev/null || fail "expected caller_tmux_session audit field"
    printf '%s\n' "$out" | jq -e '(.audit | has("impersonated")) | not' >/dev/null || fail "expected no impersonated audit field when --impersonate wasn't used"

    # --impersonate overrides the binding refusal on purpose, and is recorded.
    rc=0
    out="$(PATH="$bin:$PATH" TMUX="fake,1,0" TMUX_FAKE_PANE_PID=__current__ TMUX_FAKE_SESSIONS="TMUX--sender-a TMUX--sender-b" TMUX_FAKE_SESSION_NAME="TMUX--sender-a" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send mailbox-only --as TMUX--sender-b --impersonate --json -- "on purpose")" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected --impersonate to override the sender-binding refusal"
    printf '%s\n' "$out" | jq -e '.audit.impersonated == true' >/dev/null || fail "expected impersonated audit field to record the override"

    echo "ok: peer send binds the sender to the caller's own tmux session unless --impersonate"
}

test_peer_send_refuses_when_caller_tmux_session_unresolved() {
    # plan 091: `_peer_cmd_send` used to swallow `_session_current_name`'s
    # failure (`|| true`) into the SAME empty-string fail-open path used for
    # the legitimate "not in tmux at all" case -- so a caller whose own
    # identity couldn't be verified (a stale/inherited session state) could
    # still `--as` any peer, exactly the misroute shape plan 077 was meant to
    # close. Reproduces the validator's sandbox scenario: $TMUX is set
    # (genuinely in a tmux pane) but the process isn't a descendant of any
    # pane in the session tmux reports as current (no
    # TMUX_FAKE_PANE_PID=__current__, so the fake pane pid never matches this
    # test's own pid) -- the same shape `_session_process_in_session` is
    # meant to catch for a stale/inherited CCTRL_SESSION_NAME.
    local bin="$TMPDIR/unresolvedbin" data="$TMPDIR/peer-unresolved-data"
    mkdir -p "$bin" "$data" "$CCTRL_SESSION_METADATA_DIR"
    make_fake_tmux "$bin/tmux"
    cat > "$CCTRL_SESSION_METADATA_DIR/TMUX--sender-b.json" <<'JSON'
{"name":"TMUX--sender-b","agent":"claude","created_at":"2026-09-27T10:05:00Z","cctrl_managed":true}
JSON
    PATH="$bin:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register mailbox-only --dir /tmp/mo --agent codex >/dev/null
    PATH="$bin:$PATH" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer register mailbox-sender --dir /tmp/ms --agent codex >/dev/null

    local before=0 after=0 out rc=0
    [[ -f "$data/messages.jsonl" ]] && before="$(wc -l < "$data/messages.jsonl" | tr -d ' ')"
    out="$(PATH="$bin:$PATH" TMUX="fake,1,0" TMUX_FAKE_SESSION_NAME="TMUX--stale-inherited" TMUX_FAKE_SESSIONS="TMUX--sender-b" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send mailbox-only --as TMUX--sender-b --json -- "unresolved caller attempt" 2>&1)" || rc=$?
    [[ "$rc" -eq 66 ]] || fail "expected exit 66 when the caller's own tmux session can't be resolved, got $rc"
    assert_contains "$out" "Cannot verify"
    [[ -f "$data/messages.jsonl" ]] && after="$(wc -l < "$data/messages.jsonl" | tr -d ' ')"
    [[ "$before" == "$after" ]] || fail "expected no message written when the caller is unresolved (was $before, now $after)"

    # --impersonate still overrides it, on purpose, and the anomaly is audited.
    rc=0
    out="$(PATH="$bin:$PATH" TMUX="fake,1,0" TMUX_FAKE_SESSION_NAME="TMUX--stale-inherited" TMUX_FAKE_SESSIONS="TMUX--sender-b" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send mailbox-only --as TMUX--sender-b --impersonate --json -- "on purpose")" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected --impersonate to override the unresolved-caller refusal"
    printf '%s\n' "$out" | jq -e '.audit.caller_unresolved == true' >/dev/null || fail "expected caller_unresolved audit field to record the anomaly even when overridden"
    printf '%s\n' "$out" | jq -e '(.audit | has("caller_tmux_session")) | not' >/dev/null || fail "expected no caller_tmux_session audit field when it couldn't be resolved"

    # Genuinely not in tmux at all (no $TMUX) is completely unaffected --
    # still the pre-091 fail-open behavior, per plan 091's "not in scope".
    rc=0
    out="$(PATH="$bin:$PATH" TMUX_FAKE_SESSIONS="TMUX--sender-b" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send mailbox-only --as TMUX--sender-b --json -- "not in tmux at all")" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected a send with no \$TMUX at all to still fail open, got $rc"
    printf '%s\n' "$out" | jq -e '(.audit | has("caller_unresolved")) | not' >/dev/null || fail "expected no caller_unresolved audit field for the legitimate not-in-tmux case"

    # An unresolved caller sending AS a peer with no tmux binding at all
    # (mailbox-only, no --session at registration) has nothing to
    # impersonate, so it must stay exempt exactly like a resolved caller
    # sending as one already is (2026-09-29 eng review: an earlier version of
    # this fix refused this case too, which was stricter than the known-
    # caller case and outside plan 091's scope).
    rc=0
    out="$(PATH="$bin:$PATH" TMUX="fake,1,0" TMUX_FAKE_SESSION_NAME="TMUX--stale-inherited" TMUX_FAKE_SESSIONS="TMUX--sender-b" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send mailbox-only --as mailbox-sender --json -- "unresolved caller, mailbox-only sender" 2>&1)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected an unresolved caller sending as a peer with no tmux binding to still succeed, got $rc: $out"

    echo "ok: peer send refuses rather than silently fail-opening when the caller's own tmux session can't be resolved"
}

test_peer_send_recipient_created_at_is_audit_only() {
    # plan 077 (2026-09-28 eng review): an earlier version of this change
    # refused sending to any recipient whose derived-peer created_at postdated
    # the caller's own session start, on the theory that it might have been
    # reissued. That's also true of every ordinary session spawned after the
    # caller (a fleet manager messaging a freshly spawned worker, a reply to
    # it, restore-order-dependent sends), so it refused normal fleet traffic
    # far more often than it caught an actual reissue. Dropped; the field is
    # recorded for audit only. See docs/plans/075 for the open design
    # question on a real, non-false-positive-prone freshness check.
    local bin="$TMPDIR/reissuebin" data="$TMPDIR/peer-reissue-data"
    mkdir -p "$bin" "$data" "$CCTRL_SESSION_METADATA_DIR"
    make_fake_tmux "$bin/tmux"
    cat > "$CCTRL_SESSION_METADATA_DIR/TMUX--recip-a.json" <<'JSON'
{"name":"TMUX--recip-a","agent":"claude","created_at":"2026-09-20T10:00:00Z","cctrl_managed":true}
JSON
    cat > "$CCTRL_SESSION_METADATA_DIR/TMUX--recip-b.json" <<'JSON'
{"name":"TMUX--recip-b","agent":"claude","created_at":"2026-09-25T10:00:00Z","cctrl_managed":true}
JSON

    # A recipient session created AFTER the caller's own session started (the
    # shape that used to be refused) sends fine, and the audit field reflects
    # the recipient's actual registration time.
    local out rc=0
    out="$(PATH="$bin:$PATH" TMUX="fake,1,0" TMUX_FAKE_PANE_PID=__current__ TMUX_FAKE_SESSIONS="TMUX--recip-a TMUX--recip-b" TMUX_FAKE_SESSION_NAME="TMUX--recip-a" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send TMUX--recip-b --from TMUX--recip-a --json -- "newer worker")" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected send to a recipient newer than the caller's own session to succeed (got $rc)"
    printf '%s\n' "$out" | jq -e '.audit.recipient_created_at == "2026-09-25T10:00:00Z"' >/dev/null || fail "expected recipient_created_at audit field to reflect the recipient's own created_at"

    # A recipient older than the caller also sends fine, with its own audit value.
    rc=0
    out="$(PATH="$bin:$PATH" TMUX="fake,1,0" TMUX_FAKE_PANE_PID=__current__ TMUX_FAKE_SESSIONS="TMUX--recip-a TMUX--recip-b" TMUX_FAKE_SESSION_NAME="TMUX--recip-b" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send TMUX--recip-a --from TMUX--recip-b --json -- "older peer")" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected send to a recipient older than the caller's own session to succeed"
    printf '%s\n' "$out" | jq -e '.audit.recipient_created_at == "2026-09-20T10:00:00Z"' >/dev/null || fail "expected recipient_created_at audit field for the older recipient"

    echo "ok: peer send records recipient_created_at for audit without refusing on recency"
}

test_peer_send_sender_binding_applies_to_remote_recipients() {
    # plan 077 (2026-09-28 eng review, finding #2): the sender-binding check
    # must not be bypassable just by sending to a peer that lives on another
    # host. `_peer_send_and_deliver`'s cross-machine hop used to SSH straight
    # out to `_peer_send_and_deliver_remote`, skipping the local
    # `_peer_cmd_send` path entirely — the only vantage point where
    # `$TMUX`/pane ancestry are meaningful (the remote host never sees them
    # over a non-interactive SSH command).
    make_fake_ssh "$TMPDIR/ssh"
    make_fake_tmux "$TMPDIR/tmux"
    local data="$TMPDIR/peer-remote-bind-data" hosts="$TMPDIR/peer-remote-bind-hosts.json"
    local log="$TMPDIR/peer-remote-bind-ssh.log"
    mkdir -p "$CCTRL_SESSION_METADATA_DIR"
    : > "$log"
    printf '{"studio":{"hostname":"studio.invalid","user":"tester"}}\n' > "$hosts"
    cat > "$CCTRL_SESSION_METADATA_DIR/TMUX--remotebind-a.json" <<'JSON'
{"name":"TMUX--remotebind-a","agent":"claude","created_at":"2026-09-27T10:00:00Z","cctrl_managed":true}
JSON
    cat > "$CCTRL_SESSION_METADATA_DIR/TMUX--remotebind-b.json" <<'JSON'
{"name":"TMUX--remotebind-b","agent":"claude","created_at":"2026-09-27T10:05:00Z","cctrl_managed":true}
JSON
    CCTRL_DATA_DIR="$data" CCTRL_HOSTS_FILE="$hosts" "$ROOT/cctrl" peer register faraway --host studio --agent codex --session TMUX--faraway >/dev/null

    # Impersonating a different (also live) session while messaging a remote
    # peer is refused, and SSH is never invoked.
    local out rc=0
    out="$(PATH="$TMPDIR:$PATH" SSH_LOG="$log" TMUX="fake,1,0" TMUX_FAKE_PANE_PID=__current__ TMUX_FAKE_SESSIONS="TMUX--remotebind-a TMUX--remotebind-b" TMUX_FAKE_SESSION_NAME="TMUX--remotebind-a" CCTRL_DATA_DIR="$data" CCTRL_HOSTS_FILE="$hosts" "$ROOT/cctrl" peer send faraway --as TMUX--remotebind-b --deliver --json -- "should not ssh" 2>&1)" || rc=$?
    [[ "$rc" -eq 66 ]] || fail "expected exit 66 for a mismatched sender routed to a remote peer, got $rc"
    assert_not_contains "$(cat "$log")" "SSH"

    # Sending as yourself still proceeds to the remote hop (SSH gets called).
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" SSH_LOG="$log" TMUX="fake,1,0" TMUX_FAKE_PANE_PID=__current__ TMUX_FAKE_SESSIONS="TMUX--remotebind-a TMUX--remotebind-b" TMUX_FAKE_SESSION_NAME="TMUX--remotebind-a" CCTRL_DATA_DIR="$data" CCTRL_HOSTS_FILE="$hosts" "$ROOT/cctrl" peer send faraway --as TMUX--remotebind-a --deliver --json -- "should ssh" 2>&1)" || true
    assert_contains "$(cat "$log")" "SSH"

    # Plan 091: an unresolved caller (here, no TMUX_FAKE_PANE_PID=__current__,
    # so pane ancestry can't confirm this process belongs to
    # TMUX--remotebind-a even though $TMUX/TMUX_FAKE_SESSION_NAME claim it)
    # is refused before the remote hop too, not just a real mismatch.
    : > "$log"
    rc=0
    out="$(PATH="$TMPDIR:$PATH" SSH_LOG="$log" TMUX="fake,1,0" TMUX_FAKE_SESSIONS="TMUX--remotebind-a TMUX--remotebind-b" TMUX_FAKE_SESSION_NAME="TMUX--remotebind-a" CCTRL_DATA_DIR="$data" CCTRL_HOSTS_FILE="$hosts" "$ROOT/cctrl" peer send faraway --as TMUX--remotebind-a --deliver --json -- "unresolved, should not ssh" 2>&1)" || rc=$?
    [[ "$rc" -eq 66 ]] || fail "expected exit 66 for an unresolved caller routed to a remote peer, got $rc"
    assert_contains "$out" "sender-unresolved"
    assert_not_contains "$(cat "$log")" "SSH"

    echo "ok: peer send's sender-binding check also applies before a cross-machine SSH hop"
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
    count="$(grep -Ec 'TMUX (-u )?list-sessions' "$log" || true)"
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
    assert_contains "$(cat "$log")" "paste-buffer -p -r -b cctrl-nudge-comet-"
    assert_contains "$(cat "$log")" "send-keys -t =TMUX--comet: Enter"
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
    assert_contains "$(cat "$log")" "paste-buffer -p -r -b cctrl-nudge-comet-"
    assert_not_contains "$(cat "$log")" "send-keys -t TMUX--comet Enter"

    inline_id="$(printf 'inline body\n' | CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer send comet --from orchestrator --body-file - --json | jq -r '.id')"
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_HAS_SESSION="TMUX--comet" CCTRL_DATA_DIR="$data" "$ROOT/cctrl" peer deliver comet --inline "$inline_id" --json)"
    printf '%s\n' "$out" | jq -e '.results[0].status == "inline" and .results[0].inline == true and .results[0].submitted == false' >/dev/null || fail "expected inline paste result"
    # Envelope (plan 024): the pasted buffer now leads with a sender header and
    # the reply/ack commands, then the original body verbatim after `---`.
    assert_contains "$(cat "$log")" "[cctrl peer message] from: orchestrator (orchestrator)"
    assert_contains "$(cat "$log")" "inline body"
    assert_contains "$(cat "$log")" "paste-buffer -p -r -b cctrl-inline-comet-"
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
    assert_contains "$buf" "paste-buffer -p -r -b cctrl-inline-comet-"
    assert_contains "$buf" "-t =TMUX--comet:"
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
    count="$(grep -c 'paste-buffer -p -r -b cctrl-nudge-comet-' "$log" || true)"
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
    assert_contains "$(cat "$log")" "paste-buffer -p -r -b cctrl-nudge-comet-"

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
    assert_contains "$(cat "$log")" "run-shell -b sleep\\ 5\\;\\ tmux\\ kill-session\\ -t\\ =TMUX--demo"
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

test_session_terminate_records_closed() (
    # Plan 070 S3: kill, close, and stop-exact record `closed` on the task
    # records anchored to the killed panes, so restore never resurrects a
    # session ended on purpose. Real tmux on a private socket; temp registry.
    local real_tmux socket bin root meta data rows exec_id out rc
    real_tmux="$(command -v tmux)"
    [[ -x "$real_tmux" ]] || fail "tmux is required for terminate-record coverage"
    socket="cctrl-terminate-$$-$RANDOM"
    root="$TMPDIR/terminate-records"; bin="$root/bin"; meta="$root/meta"; data="$root/data"
    rm -rf "$root"; mkdir -p "$bin" "$meta" "$data"
    printf '#!/usr/bin/env bash\n[[ "${1:-}" == kill-session && -n "${CCTRL_TEST_FAIL_KILL:-}" ]] && exit 1\nexec %q -L %q "$@"\n' "$real_tmux" "$socket" > "$bin/tmux"
    chmod +x "$bin/tmux"
    # shellcheck disable=SC2329 # invoked by the EXIT trap
    cleanup_terminate() { "$real_tmux" -L "$socket" kill-server 2>/dev/null || true; _test_tmux_socket_rm "$socket"; }
    trap cleanup_terminate EXIT
    export CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id"

    record_for() { # name task-id [pane_id pane_pid]
        # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
        cctrl_source_eval '_session_write_metadata "$1" /tmp directory /tmp label purpose prompt cmd "" claude "$2" ""' "$1" "$2"
        local file; file="$(CCTRL_SESSION_METADATA_DIR="$meta" cctrl_source_eval '_task_record_file claude "$(_cctrl_host_id)" "$1"' "$2")"
        if [[ -n "${3:-}" ]]; then
            jq --arg p "$3" --arg pid "$4" '.pane_id=$p | .pane_pid=$pid' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
        fi
        printf '%s' "$file"
    }
    anchor_of() { "$real_tmux" -L "$socket" list-panes -s -t "=$1" -F '#{pane_id} #{pane_pid}' | head -1; }
    state_of() { jq -r '.lifecycle_state' "$1"; }

    local name anchor f_kill f_other f_keep f_close f_stop f_gone
    for name in s-kill s-keep s-close s-stop s-live s-fail s-grace s-noanchor; do
        "$real_tmux" -L "$socket" new-session -d -s "$name" 'sleep 120'
    done
    anchor="$(anchor_of s-kill)"; f_kill="$(record_for s-kill id-kill $anchor)"
    f_other="$(record_for s-kill id-elsewhere %999 1)"
    anchor="$(anchor_of s-keep)"; f_keep="$(record_for s-keep id-keep $anchor)"
    anchor="$(anchor_of s-close)"; f_close="$(record_for s-close id-close $anchor)"
    anchor="$(anchor_of s-stop)"; f_stop="$(record_for s-stop id-stop $anchor)"
    f_gone="$(record_for s-gone id-gone %77 7)"

    PATH="$bin:$PATH" "$ROOT/cctrl" session kill s-kill >/dev/null || fail "session kill failed"
    [[ "$(state_of "$f_kill")" == closed ]] || fail "kill did not record the anchored task closed: $(jq -c . "$f_kill")"
    jq -e '.control_owner=="unknown" and .execution_runtime=="unknown" and
           any(.ownership_evidence[]?; .source=="cctrl-terminate")' "$f_kill" >/dev/null \
        || fail "kill did not record authoritative cctrl-terminate evidence: $(jq -c . "$f_kill")"
    [[ "$(state_of "$f_other")" == active ]] || fail "kill closed a record anchored to a different pane"

    PATH="$bin:$PATH" "$ROOT/cctrl" session kill s-keep --keep-restorable >/dev/null || fail "kill --keep-restorable failed"
    "$real_tmux" -L "$socket" has-session -t '=s-keep' 2>/dev/null && fail "kill --keep-restorable did not kill"
    [[ "$(state_of "$f_keep")" == active ]] || fail "kill --keep-restorable recorded the task closed"

    PATH="$bin:$PATH" "$ROOT/cctrl" session close s-close >/dev/null || fail "session close failed"
    [[ "$(state_of "$f_close")" == closed ]] || fail "close did not record the anchored task closed"

    # A kill that fails records nothing: the conversation is still running.
    local f_fail f_grace i
    anchor="$(anchor_of s-fail)"; f_fail="$(record_for s-fail id-fail $anchor)"
    rc=0; CCTRL_TEST_FAIL_KILL=1 PATH="$bin:$PATH" "$ROOT/cctrl" session kill s-fail >/dev/null 2>&1 || rc=$?
    [[ "$rc" -ne 0 ]] || fail "a failed kill reported success"
    [[ "$(state_of "$f_fail")" == active ]] || fail "a failed kill recorded the task closed"
    rc=0; CCTRL_TEST_FAIL_KILL=1 PATH="$bin:$PATH" "$ROOT/cctrl" session close s-fail >/dev/null 2>&1 || rc=$?
    [[ "$rc" -ne 0 && "$(state_of "$f_fail")" == active ]] || fail "a failed close recorded the task closed (rc=$rc)"

    # A delayed close records the end only after the session is actually gone.
    anchor="$(anchor_of s-grace)"; f_grace="$(record_for s-grace id-grace $anchor)"
    PATH="$bin:$PATH" "$ROOT/cctrl" session close s-grace --in 2 >/dev/null || fail "delayed close failed"
    [[ "$(state_of "$f_grace")" == active ]] || fail "a delayed close recorded closed before the kill ran"
    for i in $(seq 1 20); do [[ "$(state_of "$f_grace")" == closed ]] && break; sleep 0.5; done
    ! "$real_tmux" -L "$socket" has-session -t '=s-grace' 2>/dev/null || fail "delayed close did not kill the session"
    [[ "$(state_of "$f_grace")" == closed ]] || fail "a delayed close never recorded the end after the kill"

    # A session closing itself: the pane (and anything it started) dies with
    # the kill, so the end must be recorded by the tmux-server job.
    local f_self
    "$real_tmux" -L "$socket" new-session -d -s s-self "sleep 1; PATH=$(printf '%q' "$bin:$PATH") CCTRL_SESSION_METADATA_DIR=$(printf '%q' "$meta") CCTRL_DATA_DIR=$(printf '%q' "$data") CCTRL_HOST_ID_FILE=$(printf '%q' "$data/host-id") $(printf '%q' "$ROOT/cctrl") session close s-self --in 1 >/dev/null 2>&1; sleep 60"
    anchor="$(anchor_of s-self)"; f_self="$(record_for s-self id-self $anchor)"
    for i in $(seq 1 30); do [[ "$(state_of "$f_self")" == closed ]] && break; sleep 0.5; done
    ! "$real_tmux" -L "$socket" has-session -t '=s-self' 2>/dev/null || fail "self-close did not kill the session"
    [[ "$(state_of "$f_self")" == closed ]] || fail "a self-closing session's end was not recorded after its pane died"

    # A session whose records carry no pane anchor gets a hint instead of silence.
    record_for s-noanchor id-noanchor >/dev/null
    out="$(PATH="$bin:$PATH" "$ROOT/cctrl" session kill s-noanchor 2>&1)" || fail "kill of an unanchored session failed"
    assert_contains "$out" "session mark-closed s-noanchor --apply"

    rows="$(PATH="$bin:$PATH" "$ROOT/cctrl" session ls --json)"
    exec_id="$(jq -r '.[] | select(.name=="s-stop") | .execution_id' <<< "$rows")"
    PATH="$bin:$PATH" "$ROOT/cctrl" session stop-exact s-stop --execution-id "$exec_id" --json >/dev/null \
        || fail "stop-exact failed"
    [[ "$(state_of "$f_stop")" == closed ]] || fail "stop-exact did not record the anchored task closed"

    # Backfill: a name with no live session. Dry run changes nothing; --apply
    # closes; a live name is refused.
    out="$(PATH="$bin:$PATH" "$ROOT/cctrl" session mark-closed s-gone --json)" || fail "mark-closed dry run failed: $out"
    jq -e '.apply==false and ([.records[] | select(.provider_task_id=="id-gone" and .action=="would-close")] | length)==1' <<< "$out" >/dev/null \
        || fail "mark-closed dry run did not list the record: $out"
    [[ "$(state_of "$f_gone")" == active ]] || fail "mark-closed dry run wrote the registry"
    PATH="$bin:$PATH" "$ROOT/cctrl" session mark-closed s-gone --apply >/dev/null || fail "mark-closed --apply failed"
    [[ "$(state_of "$f_gone")" == closed ]] || fail "mark-closed --apply did not close the record"
    out="$(PATH="$bin:$PATH" "$ROOT/cctrl" session mark-closed s-gone --json)"
    jq -e '.records==[]' <<< "$out" >/dev/null || fail "mark-closed is not idempotent: $out"
    record_for s-live id-live >/dev/null
    rc=0; PATH="$bin:$PATH" "$ROOT/cctrl" session mark-closed s-live --apply >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 75 ]] || fail "mark-closed on a live session did not refuse with 75 (rc=$rc)"

    # A closed record no longer claims its tmux name: reusing the name is not
    # an ownership conflict in the task catalogue.
    "$real_tmux" -L "$socket" new-session -d -s s-kill 'sleep 120'
    out="$(PATH="$bin:$PATH" "$ROOT/cctrl" task ls --json 2>/dev/null || true)"
    jq -e '[.rows[] | select(.provider_task_id=="id-kill")][0] | .control_owner!="conflict" and .lifecycle_state=="closed"' <<< "$out" >/dev/null \
        || fail "a closed record still conflicts with a reused tmux name: $(jq -c '[.rows[] | select(.provider_task_id=="id-kill")]' <<< "$out")"
    echo "ok: kill, close, and stop-exact record closed; mark-closed backfills; ended tasks release their tmux name"
)

test_session_close_reaps_pane_processes() (
    # Plan 074: tmux kill-session only hangs up the pty. The real wrapper then
    # TERMs the agent; an agent that ignores SIGTERM used to keep the wrapper
    # waiting forever and both survived as orphans. Private tmux socket, the
    # real lib/session-wrapper.sh, and a fake agent that ignores TERM and HUP.
    local real_tmux socket root bin agents out rc name pids p i
    real_tmux="$(command -v tmux)"
    [[ -x "$real_tmux" ]] || fail "tmux is required for pane reaping coverage"
    socket="cctrl-reap-$$-$RANDOM"
    root="$TMPDIR/reap"; bin="$root/bin"; agents="$root/agents"
    rm -rf "$root"; mkdir -p "$bin" "$agents" "$root/meta" "$root/data"
    printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$real_tmux" "$socket" > "$bin/tmux"
    # Stays a bash process running this script (not an exec'd sleep), so its
    # argv names the test root and cleanup can always find it.
    printf '#!/usr/bin/env bash\ntrap "" TERM HUP\nwhile :; do sleep 1; done\n' > "$agents/claude"
    # Same shape, so a Codex-flavored pane exercises the identical reaper
    # path (plan 087): the reap kills by snapshot pid, independent of which
    # agent the wrapper launched.
    cp "$agents/claude" "$agents/codex"
    chmod +x "$bin/tmux" "$agents/claude" "$agents/codex"
    # shellcheck disable=SC2329 # invoked by the EXIT trap
    cleanup_reap() {
        "$real_tmux" -L "$socket" kill-server 2>/dev/null || true
        _test_tmux_socket_rm "$socket"
        pkill -KILL -f "$root" 2>/dev/null || true
    }
    trap cleanup_reap EXIT
    export CCTRL_SESSION_METADATA_DIR="$root/meta" CCTRL_DATA_DIR="$root/data" CCTRL_HOST_ID_FILE="$root/data/host-id"

    launch() { # name wrapper-grace [agent]
        local agent="${3:-claude}" agent_args=(--probe "$root")
        [[ "$agent" == "codex" ]] && agent_args=(--probe "$root" --cctrl-initial)
        "$real_tmux" -L "$socket" new-session -d -s "$1" \
            "CCTRL_WRAPPER_TERM_GRACE=$2 PATH=$(printf '%q' "$agents:$PATH") bash $(printf '%q' "$ROOT/lib/session-wrapper.sh") $agent $(printf '%q' "$root/marker-$1") $(printf '%q ' "${agent_args[@]}")"
        for i in $(seq 1 30); do
            pids="$(pane_tree "$1")"
            [[ "$(wc -w <<< "$pids")" -ge 2 ]] && return 0
            sleep 0.1
        done
        fail "$1 did not start the wrapper and agent: $pids"
    }
    pane_tree() { # the pane leader and all its descendants, except transient sleeps
        local leader todo p kids all=""
        leader="$("$real_tmux" -L "$socket" list-panes -s -t "=$1" -F '#{pane_pid}' 2>/dev/null)" || return 0
        todo="$leader"
        while [[ -n "${todo// /}" ]]; do
            p="${todo%% *}"; todo="${todo#"$p"}"; todo="${todo# }"
            [[ -n "$p" ]] || continue
            [[ "$(ps -o command= -p "$p" 2>/dev/null)" == "sleep 1" ]] || all+="$p "
            kids="$(pgrep -P "$p" | tr '\n' ' ')"
            todo="$todo $kids"
        done
        printf '%s' "${all% }"
    }
    assert_gone() { # label pids timeout-tenths
        local left
        for i in $(seq 1 "$3"); do
            left=""
            for p in $2; do kill -0 "$p" 2>/dev/null && left+=" $p"; done
            [[ -z "$left" ]] && return 0
            sleep 0.1
        done
        left="${left# }"
        fail "$1 left pane processes running: $left ($(ps -o pid=,command= -p "${left// /,}" 2>/dev/null | tr '\n' ';'))"
    }

    # 1. The wrapper alone: a plain tmux kill-session no longer strands it.
    launch w-plain 1; pids="$(pane_tree w-plain)"
    "$real_tmux" -L "$socket" kill-session -t '=w-plain'
    assert_gone "plain tmux kill-session" "$pids" 40

    # Plan 076: Codex used to run synchronously in the wrapper's foreground,
    # so the SIGHUP trap only fired once Codex exited on its own — the
    # escalation above never applied to it. Same bare kill-session, codex
    # agent instead of claude's default.
    launch w-plain-codex 1 codex; pids="$(pane_tree w-plain-codex)"
    "$real_tmux" -L "$socket" kill-session -t '=w-plain-codex'
    assert_gone "plain tmux kill-session (codex)" "$pids" 40

    # Plan 076: respawn-pane -k hangs up the pane the same way kill-session
    # does, without tearing down the session — a second path onto the same
    # trap.
    launch w-respawn-codex 1 codex; pids="$(pane_tree w-respawn-codex)"
    "$real_tmux" -L "$socket" respawn-pane -k -t '=w-respawn-codex:'
    assert_gone "respawn-pane -k (codex)" "$pids" 40
    "$real_tmux" -L "$socket" kill-session -t '=w-respawn-codex:' 2>/dev/null || true

    # 2-5. cctrl paths, with the wrapper's own escalation pushed out of reach
    #      so cctrl's reaper is what must end them.
    for name in r-kill r-close r-now r-stop r-grace; do launch "$name" 600; done
    pids="$(pane_tree r-kill)"
    out="$(CCTRL_CLOSE_REAP_GRACE=1 PATH="$bin:$PATH" "$ROOT/cctrl" session kill r-kill 2>&1)" || fail "kill failed: $out"
    assert_gone "session kill" "$pids" 10
    assert_contains "$out" "ignored SIGTERM and were killed"

    pids="$(pane_tree r-close)"
    CCTRL_CLOSE_REAP_GRACE=1 PATH="$bin:$PATH" "$ROOT/cctrl" session close r-close --force >/dev/null 2>&1 || fail "close failed"
    assert_gone "session close" "$pids" 10
    pids="$(pane_tree r-now)"
    CCTRL_CLOSE_REAP_GRACE=1 PATH="$bin:$PATH" "$ROOT/cctrl" session close r-now --now --force >/dev/null 2>&1 || fail "close --now failed"
    assert_gone "session close --now" "$pids" 10

    pids="$(pane_tree r-stop)"
    local exec_id
    exec_id="$(PATH="$bin:$PATH" "$ROOT/cctrl" session ls --json | jq -r '.[] | select(.name=="r-stop") | .execution_id')"
    CCTRL_CLOSE_REAP_GRACE=1 PATH="$bin:$PATH" "$ROOT/cctrl" session stop-exact r-stop --execution-id "$exec_id" --json >/dev/null 2>&1 \
        || fail "stop-exact failed"
    assert_gone "session stop-exact" "$pids" 10

    # Delayed close: the tmux-server job kills, then reaps.
    pids="$(pane_tree r-grace)"
    CCTRL_CLOSE_JOB_LOG="$root/close-job.log" CCTRL_CLOSE_REAP_GRACE=1 PATH="$bin:$PATH" "$ROOT/cctrl" session close r-grace --in 1 --force >/dev/null 2>&1 || fail "delayed close failed"
    # The last session: its kill ends the tmux server, which must not take the
    # record/reap step down with it.
    assert_gone "delayed session close" "$pids" 150
    # A Codex-flavored pane (not just claude) through `session close`: the
    # reaper kills by pid/start-time snapshot, independent of which agent the
    # wrapper launched.
    launch r-codex 600 codex; pids="$(pane_tree r-codex)"
    CCTRL_CLOSE_REAP_GRACE=1 PATH="$bin:$PATH" "$ROOT/cctrl" session close r-codex --force >/dev/null 2>&1 || fail "codex pane close failed"
    assert_gone "session close of a codex pane" "$pids" 10

    # Safety property: a pid whose start time no longer matches the snapshot
    # (the pid was reused) is never signalled.
    local victim good_start
    bash -c 'exec sleep 30' & victim=$!
    sleep 0.2
    good_start="$(LC_ALL=C TZ=UTC0 ps -o lstart= -p "$victim" | awk '{$1=$1; gsub(/ /, "_"); print}')"
    # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
    CCTRL_CLOSE_REAP_GRACE=0 cctrl_source_eval '_session_reap_processes "$1" reuse-test' "$victim@Mon_Jan__1_00:00:00_2001" 2>/dev/null
    kill -0 "$victim" 2>/dev/null || fail "the reaper signalled a pid whose start time did not match"
    # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
    CCTRL_CLOSE_REAP_GRACE=0 cctrl_source_eval '_session_reap_processes "$1" reuse-test' "$victim@$good_start" 2>/dev/null
    sleep 0.3
    ! kill -0 "$victim" 2>/dev/null || { kill -KILL "$victim" 2>/dev/null; fail "the reaper did not stop a matching pid"; }

    # Survivors report: nothing can actually survive a real SIGKILL, so this
    # simulates it with a stubbed `ps` that always reports the pid alive
    # (matching pid/stat/lstart), regardless of reality — confirming the
    # reaper's own accounting (not the OS's) drives the survivor message and
    # exit code. Uses a real, self-spawned (and actually-killed) pid rather
    # than a hardcoded number, so there's no chance of the stub's lie ever
    # pointing at an unrelated live process.
    local survivor_bin="$root/survivor-ps" survivor_pid survivor_start="Mon_Jan__1_00:00:00_2001"
    bash -c 'exec sleep 30' & survivor_pid=$!
    mkdir -p "$survivor_bin"
    cat > "$survivor_bin/ps" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-axo" ]]; then
    printf '%s R %s\n' "$survivor_pid" "$survivor_start"
else
    exec /bin/ps "\$@"
fi
EOF
    chmod +x "$survivor_bin/ps"
    local survivor_out survivor_rc=0
    # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
    survivor_out="$(CCTRL_CLOSE_REAP_GRACE=0 PATH="$survivor_bin:$PATH" cctrl_source_eval '_session_reap_processes "$1" survivor-test' "$survivor_pid@$survivor_start" 2>&1)" || survivor_rc=$?
    [[ "$survivor_rc" -eq 1 ]] || fail "a process that survives SIGKILL should report failure, got rc=$survivor_rc: $survivor_out"
    assert_contains "$survivor_out" "survivor-test: 1 pane process(es) survived SIGKILL: $survivor_pid"
    kill -KILL "$survivor_pid" 2>/dev/null || true

    # A failed process snapshot never blocks the kill itself.
    local brokebin="$root/brokepy"
    mkdir -p "$brokebin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$brokebin/python3"; chmod +x "$brokebin/python3"
    launch r-snapfail 1; pids="$(pane_tree r-snapfail)"
    out="$(PATH="$brokebin:$bin:$PATH" "$ROOT/cctrl" session kill r-snapfail 2>&1)" || fail "kill aborted when the process snapshot failed: $out"
    ! "$real_tmux" -L "$socket" has-session -t '=r-snapfail' 2>/dev/null || fail "a failed snapshot left the session alive"
    assert_contains "$out" "Could not record r-snapfail's pane processes"
    assert_gone "kill with a failed snapshot (wrapper escalation)" "$pids" 40
    echo "ok: kill, close, close --now, stop-exact, and delayed close leave no pane processes behind"
)

test_session_stop_exact_identity() (
    # Every tmux command is forced through a private socket. This exercises the
    # real tmux identity/command-queue semantics without touching live sessions.
    local real_tmux socket bin out rows old_id fresh_id server_id rc=0
    local concurrent_dir concurrent_file pid n
    local -a concurrent_pids=()
    assert_stop_exact_error() {
        local expected_rc="$1" expected_status="$2" description="$3" case_out case_rc=0
        shift 3
        case_out="$(PATH="$bin:$PATH" "$ROOT/cctrl" session stop-exact "$@" --json)" || case_rc=$?
        if [[ "$case_rc" -ne "$expected_rc" ]] \
            || ! jq -e --arg status "$expected_status" '.ok==false and .status==$status' <<< "$case_out" >/dev/null; then
            fail "$description did not fail closed: rc=$case_rc out=$case_out"
        fi
    }
    real_tmux="$(command -v tmux)"
    [[ -x "$real_tmux" ]] || fail "tmux is required for exact-stop integration coverage"
    socket="cctrl-exact-stop-$$-$RANDOM"
    bin="$TMPDIR/exact-stop-bin"
    mkdir -p "$bin"
    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
real_tmux="${CCTRL_TEST_REAL_TMUX:?}"
socket="${CCTRL_TEST_TMUX_SOCKET:?}"

# Return the inspected execution, then replace it before cctrl reaches its
# guarded effect command. "session" models same-server name reuse; "server"
# models a full tmux restart that reuses both the name and native $N id.
if [[ -n "${CCTRL_TEST_REPLACE_MODE:-}" \
      && ( "${1:-}" == "display-message" || ( "${1:-}" == "-u" && "${2:-}" == "display-message" ) ) \
      && "$*" == *session_id* && "$*" == *@cctrl_server_instance_id* ]]; then
    observed="$("$real_tmux" -L "$socket" "$@")"
    name="${CCTRL_TEST_REPLACE_NAME:?}"
    if [[ "$CCTRL_TEST_REPLACE_MODE" == "server" ]]; then
        "$real_tmux" -L "$socket" kill-server
    else
        "$real_tmux" -L "$socket" kill-session -t "=$name"
    fi
    "$real_tmux" -L "$socket" new-session -d -s "$name" 'sleep 120'
    if [[ "$CCTRL_TEST_REPLACE_MODE" == "server" && -n "${CCTRL_TEST_RESTORE_SERVER_ID:-}" ]]; then
        "$real_tmux" -L "$socket" set-option -s @cctrl_server_instance_id \
            "$CCTRL_TEST_RESTORE_SERVER_ID"
    fi
    printf '%s\n' "$observed"
    exit 0
fi

exec "$real_tmux" -L "$socket" "$@"
SH
    chmod +x "$bin/tmux"
    export CCTRL_TEST_REAL_TMUX="$real_tmux" CCTRL_TEST_TMUX_SOCKET="$socket"
    # shellcheck disable=SC2329 # invoked by the EXIT trap
    cleanup_exact_stop() { "$real_tmux" -L "$socket" kill-server 2>/dev/null || true; _test_tmux_socket_rm "$socket"; }
    trap cleanup_exact_stop EXIT

    "$real_tmux" -L "$socket" new-session -d -s reused 'sleep 120'
    "$real_tmux" -L "$socket" new-session -d -s bystander 'sleep 120'

    # Concurrent first-time listers must converge on the one value installed
    # by tmux's serialized command queue; no caller may mint a competing ID.
    concurrent_dir="$TMPDIR/exact-stop-concurrent"
    mkdir -p "$concurrent_dir"
    for n in 1 2 3 4; do
        PATH="$bin:$PATH" "$ROOT/cctrl" session ls --json >"$concurrent_dir/$n.json" &
        concurrent_pids+=("$!")
    done
    for pid in "${concurrent_pids[@]}"; do wait "$pid"; done
    server_id="$("$real_tmux" -L "$socket" show-options -sqv @cctrl_server_instance_id)"
    [[ "$server_id" =~ ^[0-9a-f]{32}$ ]] \
        || fail "concurrent listing did not install a valid server identity: $server_id"
    for concurrent_file in "$concurrent_dir"/*.json; do
        jq -e --arg server_id "$server_id" \
            'length == 2 and all(.[].execution_id; split(":") as $p | ($p | length) == 5 and $p[0] == "tmux-v1" and $p[1] == $server_id and ($p[2] | test("^[0-9]+$")) and ($p[3] | test("^[0-9]+$")) and ($p[4] | test("^\\$[0-9]+$")))' \
            "$concurrent_file" >/dev/null \
            || fail "concurrent listing did not converge on $server_id: $(cat "$concurrent_file")"
    done

    rows="$(PATH="$bin:$PATH" "$ROOT/cctrl" session ls --json)"
    old_id="$(jq -r '.[] | select(.name=="reused") | .execution_id' <<< "$rows")"
    [[ "$old_id" =~ ^tmux-v1:[0-9a-f]{32}:[0-9]+:[0-9]+:\$[0-9]+$ ]] \
        || fail "listing did not expose a valid execution_id: $old_id"
    jq -e '.[] | select(.name=="reused") | .session_id == null' <<< "$rows" >/dev/null \
        || fail "provider session_id was repurposed as execution identity"

    # A replacement with the same name in the same server receives a new $N.
    "$real_tmux" -L "$socket" kill-session -t '=reused'
    "$real_tmux" -L "$socket" new-session -d -s reused 'sleep 120'
    rc=0
    out="$(PATH="$bin:$PATH" "$ROOT/cctrl" session stop-exact reused --execution-id "$old_id" --json)" || rc=$?
    [[ "$rc" -eq 69 ]] || fail "stale same-server identity returned $rc: $out"
    jq -e '.ok==false and .status=="stale-identity"' <<< "$out" >/dev/null \
        || fail "stale same-server identity returned the wrong contract: $out"
    "$real_tmux" -L "$socket" has-session -t '=reused' \
        || fail "stale identity stopped the same-name replacement"

    rows="$(PATH="$bin:$PATH" "$ROOT/cctrl" session ls --json)"
    fresh_id="$(jq -r '.[] | select(.name=="reused") | .execution_id' <<< "$rows")"

    # Missing, malformed, unsupported, and name-mismatched identities fail
    # closed. Neither the target nor an unrelated session is touched.
    assert_stop_exact_error 64 missing-name "missing name" --execution-id "$fresh_id"
    assert_stop_exact_error 64 missing-identity "missing identity" reused
    assert_stop_exact_error 64 missing-identity "valueless identity" reused --execution-id
    assert_stop_exact_error 64 malformed-identity "malformed identity" reused --execution-id nonsense
    assert_stop_exact_error 64 malformed-identity "malformed tmux identity" reused --execution-id tmux-v1:bad
    assert_stop_exact_error 64 unsupported-identity "unsupported identity" reused --execution-id tmux-v2:future
    assert_stop_exact_error 64 invalid-input "unknown flag" reused --bogus --execution-id "$fresh_id"
    assert_stop_exact_error 64 invalid-input "multiple names" reused bystander --execution-id "$fresh_id"
    assert_stop_exact_error 75 mismatched-identity "mismatched identity" bystander --execution-id "$fresh_id"

    rc=0
    out="$(cctrl_source_eval '_session_require_tmux(){ return 1; }; _session_stop_exact reused --execution-id "$1" --json' "$fresh_id")" || rc=$?
    if [[ "$rc" -ne 1 ]] || ! jq -e '.ok==false and .status=="tmux-unavailable"' <<< "$out" >/dev/null; then
        fail "tmux-unavailable error did not preserve the JSON contract: rc=$rc out=$out"
    fi
    "$real_tmux" -L "$socket" has-session -t '=reused' || fail "invalid identity stopped its target"
    "$real_tmux" -L "$socket" has-session -t '=bystander' || fail "invalid identity stopped a bystander"

    # Force same-name replacement after inspection but before termination.
    # The immutable $N target makes the effect-boundary command fail stale.
    rc=0
    out="$(CCTRL_TEST_REPLACE_MODE=session CCTRL_TEST_REPLACE_NAME=reused \
        PATH="$bin:$PATH" "$ROOT/cctrl" session stop-exact reused --execution-id "$fresh_id" --json)" || rc=$?
    if [[ "$rc" -ne 69 ]] || ! jq -e '.status=="stale-identity"' <<< "$out" >/dev/null; then
        fail "inspection/effect name-reuse race did not fail stale: rc=$rc out=$out"
    fi
    "$real_tmux" -L "$socket" has-session -t '=reused' \
        || fail "inspection/effect race stopped the replacement"

    # A server restart can reuse $0 and restore the old valid-looking random
    # option. Immutable server PID/start fields still reject the replacement,
    # even when it appears after inspection.
    rows="$(PATH="$bin:$PATH" "$ROOT/cctrl" session ls --json)"
    fresh_id="$(jq -r '.[] | select(.name=="reused") | .execution_id' <<< "$rows")"
    server_id="${fresh_id#tmux-v1:}"
    server_id="${server_id%%:*}"
    rc=0
    out="$(CCTRL_TEST_REPLACE_MODE=server CCTRL_TEST_REPLACE_NAME=reused CCTRL_TEST_RESTORE_SERVER_ID="$server_id" \
        PATH="$bin:$PATH" "$ROOT/cctrl" session stop-exact reused --execution-id "$fresh_id" --json)" || rc=$?
    if [[ "$rc" -ne 69 ]] || ! jq -e '.status=="stale-identity"' <<< "$out" >/dev/null; then
        fail "tmux restart race did not fail stale: rc=$rc out=$out"
    fi
    "$real_tmux" -L "$socket" has-session -t '=reused' \
        || fail "stale pre-restart identity stopped the replacement server's session"

    # A malformed pre-existing server annotation must never be upgraded into
    # a claimed execution identity. The session remains visible but unstoppably
    # fail-closed until a valid incarnation can be established.
    "$real_tmux" -L "$socket" set-option -s @cctrl_server_instance_id invalid
    rows="$(PATH="$bin:$PATH" "$ROOT/cctrl" session ls --json)"
    jq -e '.[] | select(.name=="reused") | .execution_id == null' <<< "$rows" >/dev/null \
        || fail "invalid server identity did not make execution_id null: $rows"
    "$real_tmux" -L "$socket" has-session -t '=reused' \
        || fail "fail-closed listing changed the running session"
    "$real_tmux" -L "$socket" set-option -su @cctrl_server_instance_id

    # A fresh identity stops only its intended execution.
    "$real_tmux" -L "$socket" new-session -d -s survivor 'sleep 120'
    rows="$(PATH="$bin:$PATH" "$ROOT/cctrl" session ls --json)"
    fresh_id="$(jq -r '.[] | select(.name=="reused") | .execution_id' <<< "$rows")"
    out="$(PATH="$bin:$PATH" "$ROOT/cctrl" session stop-exact reused --execution-id "$fresh_id" --json)"
    jq -e '.ok==true and .status=="stopped"' <<< "$out" >/dev/null \
        || fail "correct identity did not stop its execution: $out"
    ! "$real_tmux" -L "$socket" has-session -t '=reused' 2>/dev/null \
        || fail "correct identity left its execution alive"
    "$real_tmux" -L "$socket" has-session -t '=survivor' \
        || fail "correct identity stopped an unrelated session"

    # C locale must preserve UTF-8 names and a delimiter in the opaque name.
    # The fixed identity header remains parseable and the exact stop uses the
    # same name that listing returned.
    local unicode_name='rü|pipe|' unicode_id
    "$real_tmux" -L "$socket" new-session -d -s "$unicode_name" 'sleep 120'
    rows="$(LC_ALL=C PATH="$bin:$PATH" "$ROOT/cctrl" session ls --json)"
    unicode_id="$(jq -r --arg name "$unicode_name" '.[] | select(.name==$name) | .execution_id' <<< "$rows")"
    [[ "$unicode_id" =~ ^tmux-v1:[0-9a-f]{32}:[0-9]+:[0-9]+:\$[0-9]+$ ]] \
        || fail "C-locale listing lost UTF-8/delimited session identity: $rows"
    out="$(LC_ALL=C PATH="$bin:$PATH" "$ROOT/cctrl" session stop-exact "$unicode_name" --execution-id "$unicode_id" --json)"
    jq -e '.ok==true and .status=="stopped"' <<< "$out" >/dev/null \
        || fail "C-locale exact stop rejected listed UTF-8/delimited session: $out"
    ! "$real_tmux" -L "$socket" has-session -t "=$unicode_name" 2>/dev/null \
        || fail "C-locale exact stop left the named execution alive"

    # Preserve the existing name-based manual command for CLI compatibility.
    "$real_tmux" -L "$socket" new-session -d -s legacy-kill 'sleep 120'
    PATH="$bin:$PATH" "$ROOT/cctrl" session kill legacy-kill >/dev/null
    ! "$real_tmux" -L "$socket" has-session -t '=legacy-kill' 2>/dev/null \
        || fail "legacy session kill no longer works"

    echo "ok: exact stop binds server+session identity and fails closed across reuse/restart"
)

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
    assert_contains "$(cat "$log")" "kill-session -t =TMUX--demo"
    assert_not_contains "$(cat "$log")" "run-shell"
}

test_session_kill_exact_target_no_prefix_match() {
    # plan 080: tmux's `-t NAME` falls back to prefix matching when no session
    # named exactly NAME exists — `-t TMUX--x` can silently resolve to a live
    # `TMUX--x--2`. Two fake sessions "X" and "X--2" (exactly the shape cctrl
    # creates for a duplicate label): kill X once (must remove only X), then
    # kill the now-gone name "X" again — a second/stale/racing kill — and
    # confirm it refuses instead of prefix-matching and killing X--2.
    make_fake_tmux "$TMPDIR/tmux"
    local state="$TMPDIR/prefix-match-state"
    printf '$1:X\n$2:X--2\n' > "$state"

    local out rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_FAKE_STATE="$state" "$ROOT/cctrl" session kill X 2>&1)" \
        || fail "first kill of X failed: $out"
    assert_contains "$out" "Killed session: X"
    grep -qx '$2:X--2' "$state" || fail "first kill left an unexpected state: $(cat "$state")"
    ! grep -q ':X$' "$state" || fail "first kill did not remove X: $(cat "$state")"

    # X is already gone. Killing the bare name "X" again must NOT prefix-match
    # and kill "X--2" — it must refuse with no session found.
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_FAKE_STATE="$state" "$ROOT/cctrl" session kill X 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "a second kill of an already-gone session reported success: $out"
    assert_contains "$out" "No session named 'X'"
    grep -qx '$2:X--2' "$state" || fail "second kill of the gone 'X' touched X--2: $(cat "$state")"

    # X--2 is still live and attachable (an exact match still resolves it).
    PATH="$TMPDIR:$PATH" TMUX_FAKE_STATE="$state" tmux has-session -t "=X--2" \
        || fail "X--2 should still be attachable after the second (no-op) kill of X"

    echo "ok: session kill targets tmux exactly, so a stale/repeated kill of a gone name never prefix-matches a live X--2"
}

test_session_close_exact_target_no_prefix_match() {
    # plan 085 (080 re-review): the same prefix-match-collision coverage as
    # test_session_kill_exact_target_no_prefix_match, extended to `session
    # close` — both the immediate (--now) path and the delayed (--in) path.
    make_fake_tmux "$TMPDIR/tmux"
    local state="$TMPDIR/close-prefix-match-state"
    printf '$1:X\n$2:X--2\n' > "$state"

    local out rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_FAKE_STATE="$state" "$ROOT/cctrl" session close X --now 2>&1)" \
        || fail "immediate close of X failed: $out"
    assert_contains "$out" "Closed session: X"
    grep -qx '$2:X--2' "$state" || fail "immediate close left an unexpected state: $(cat "$state")"
    ! grep -q ':X$' "$state" || fail "immediate close did not remove X: $(cat "$state")"

    # X is already gone. Closing the bare name "X" again must NOT prefix-match
    # and close "X--2" — it must refuse with no session found.
    rc=0
    out="$(PATH="$TMPDIR:$PATH" TMUX_FAKE_STATE="$state" "$ROOT/cctrl" session close X --now 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "a second close of an already-gone session reported success: $out"
    assert_contains "$out" "No session named 'X'"
    grep -qx '$2:X--2' "$state" || fail "second close of the gone 'X' touched X--2: $(cat "$state")"

    PATH="$TMPDIR:$PATH" TMUX_FAKE_STATE="$state" tmux has-session -t "=X--2" \
        || fail "X--2 should still be attachable after the second (no-op) close of X"

    # Delayed close (--in): the scheduled kill-session is embedded in a shell
    # string run later by the tmux server (cctrl:~13156), outside the reach of
    # test_tmux_exact_target_lint (it's a nested command string, not a literal
    # `-t "$VAR"` clause) — confirm it carries the resolved immutable tmux
    # session id ($1, from TMUX_FAKE_STATE) rather than a bare, prefix-
    # matchable "X" or even a re-usable "=X" name (plan 087: the id, once
    # resolved, is used for the kill everywhere in `session close`, not just
    # for the record/reap steps).
    printf '$1:X\n$2:X--2\n' > "$state"
    local log="$TMPDIR/close-prefix-match.log"
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_STATE="$state" "$ROOT/cctrl" session close X --in 5 2>&1)" \
        || fail "delayed close of X failed: $out"
    assert_contains "$out" "will close in 5s"
    assert_contains "$(cat "$log")" 'kill-session\ -t\ \\\$1'
    grep -qx '$1:X' "$state" || fail "delayed close must not kill before its grace elapses: $(cat "$state")"

    echo "ok: session close targets tmux exactly (immediate and delayed), so a stale/repeated close of a gone name never prefix-matches a live X--2"
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
    local metadata="$TMPDIR/bg-metadata" rollout thread_id
    mkdir -p "$metadata"
    rollout="$(make_codex_rollout "$ch" "/tmp/demo" yes)"
    thread_id="$(head -1 "$rollout" | jq -r '.payload.id')"
    jq -n --arg id "$thread_id" '{name:"TMUX--busycx",agent:"codex",cwd:"/tmp/demo",conversation_id:$id}' \
        > "$metadata/TMUX--busycx.json"

    local out
    out="$(PATH="$bin:$PATH" CODEX_HOME="$ch" CCTRL_SESSION_METADATA_DIR="$metadata" \
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
    local metadata="$TMPDIR/cnp-metadata" rollout thread_id
    mkdir -p "$metadata"
    rollout="$(make_codex_rollout "$ch" "/tmp/demo" no)"
    thread_id="$(head -1 "$rollout" | jq -r '.payload.id')"
    jq -n --arg id "$thread_id" '{name:"TMUX--emptycx",agent:"codex",cwd:"/tmp/demo",conversation_id:$id}' \
        > "$metadata/TMUX--emptycx.json"

    local out
    out="$(PATH="$bin:$PATH" CODEX_HOME="$ch" CCTRL_SESSION_METADATA_DIR="$metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$TMPDIR/cnp-nope" CCTRL_CLAUDE_PROJECTS_DIR="$TMPDIR/cnp-nope" \
        TMUX_FAKE_SESSIONS="TMUX--emptycx" TMUX_FAKE_PANE_PID=4545 "$ROOT/cctrl" session prune --json)"
    assert_contains "$out" '"name": "TMUX--emptycx"'
    assert_contains "$out" '"reason": "never-prompted"'
    # The same cwd alone cannot authorize pruning an unbound terminal.
    rm "$metadata/TMUX--emptycx.json"
    out="$(PATH="$bin:$PATH" CODEX_HOME="$ch" CCTRL_SESSION_METADATA_DIR="$metadata" \
        CCTRL_CLAUDE_SESSIONS_DIR="$TMPDIR/cnp-nope" CCTRL_CLAUDE_PROJECTS_DIR="$TMPDIR/cnp-nope" \
        TMUX_FAKE_SESSIONS="TMUX--emptycx" TMUX_FAKE_PANE_PID=4545 "$ROOT/cctrl" session prune --json)"
    [[ "$out" == "[]" ]] || fail "unbound same-cwd Codex rollout must not authorize pruning; got: $out"
    echo "ok: exact Codex receipt permits never-prompted classification; unbound cwd stays unknown"
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
    # conversation_id. The exact current prompt in the launch cwd is a stronger identity signal.
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
{"timestamp":"2026-08-24T10:02:00.000Z","type":"session_meta","payload":{"id":"thread-new","cwd":"/tmp/demo"}}
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

test_codex_wrapper_resume_and_restart_args() {
    # Codex positional args (resume subcommand, id, prompt) must reach codex
    # after its options on first launch, and an in-place restart must reuse
    # only the options -- including `-c key=value`, which is Codex's --config.
    local rootcopy="$TMPDIR/codex-resume-wrapper" bin="$TMPDIR/codex-resume-bin" log="$TMPDIR/codex-resume.log"
    local marker="$TMPDIR/codex-resume-marker"
    mkdir -p "$rootcopy/lib" "$bin"
    cp "$ROOT/lib/session-wrapper.sh" "$rootcopy/lib/session-wrapper.sh"
    chmod +x "$rootcopy/lib/session-wrapper.sh"
    cat > "$bin/codex" <<'SH'
#!/usr/bin/env bash
{
    echo "RUN"
    i=0
    for arg in "$@"; do printf 'ARG[%d]=%s\n' "$i" "$arg"; i=$((i + 1)); done
} >> "$CODEX_FAKE_LOG"
if [[ -n "${CODEX_FAKE_RESTART_ID:-}" && ! -f "$CODEX_FAKE_LOG.restarted" ]]; then
    : > "$CODEX_FAKE_LOG.restarted"
    printf '%s' "$CODEX_FAKE_RESTART_ID" > "$CCTRL_RESTART_MARKER"
fi
exit 0
SH
    chmod +x "$bin/codex"

    local opts=(--yolo --cd /tmp/demo -c 'mcp_servers.x.command="/bin/x"')

    # First launch resumes by id with a prompt.
    : > "$log"
    PATH="$bin:$PATH" CODEX_FAKE_LOG="$log" CCTRL_RESTART_MARKER="$marker" \
        "$rootcopy/lib/session-wrapper.sh" codex "$marker" "${opts[@]}" --cctrl-initial resume thread-1 "next step" >/dev/null
    local out
    out="$(cat "$log")"
    assert_contains "$out" "ARG[0]=resume"
    assert_contains "$out" "ARG[1]=--yolo"
    assert_contains "$out" "ARG[4]=-c"
    assert_contains "$out" 'ARG[5]=mcp_servers.x.command="/bin/x"'
    assert_contains "$out" "ARG[6]=thread-1"
    assert_contains "$out" "ARG[7]=next step"
    assert_not_contains "$out" "--cctrl-initial"

    # Fresh launch with a prompt, then an in-place restart.
    : > "$log"
    rm -f "$log.restarted"
    PATH="$bin:$PATH" CODEX_FAKE_LOG="$log" CODEX_FAKE_RESTART_ID=thread-2 CCTRL_RESTART_MARKER="$marker" \
        "$rootcopy/lib/session-wrapper.sh" codex "$marker" "${opts[@]}" --cctrl-initial "first prompt" >/dev/null
    local first second
    first="$(awk '/^RUN$/{n++} n==1' "$log")"
    second="$(awk '/^RUN$/{n++} n==2' "$log")"
    assert_contains "$first" "ARG[0]=--yolo"
    assert_contains "$first" "ARG[5]=first prompt"
    assert_contains "$second" "ARG[0]=resume"
    assert_contains "$second" "ARG[4]=-c"
    assert_contains "$second" 'ARG[5]=mcp_servers.x.command="/bin/x"'
    assert_contains "$second" "ARG[6]=thread-2"
    assert_not_contains "$second" "first prompt"
    assert_not_contains "$second" "ARG[7]="

    # cctrl's tmux launch path hands the wrapper the resume id, not a prompt.
    make_fake_agent "$bin/codex" codex
    out="$(cd /tmp && PATH="$bin:$PATH" CCTRL_TMUX_CONTEXT=1 CCTRL_SESSION_KIND=tmux CCTRL_SESSION_NAME=TMUX--resume \
        "$ROOT/cctrl" start --foreground --agent codex --no-bridge --resume thread-3 2>/dev/null)"
    assert_contains "$out" "ARG[0]=resume"
    assert_contains "$out" "ARG[1]=--yolo"
    assert_contains "$out" "=thread-3"
    assert_not_contains "$out" "--cctrl-initial"
    local last
    last="$(grep '^ARG\[' <<< "$out" | tail -1)"
    [[ "$last" == *"=thread-3" ]] || fail "resume id must be codex's last argument, got: $last"

    echo "ok: codex wrapper resumes by id and restarts with options intact"
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
    # Legacy metadata without a pane/PID/start receipt is not sufficient to
    # authorize a handoff. The strict state machine must reject it before
    # touching the writer lock; the anchored success case is covered by the
    # codex-handoff fixture below.
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

    local out control rc=0
    out="$(PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" CODEX_HOME="$codex_home" \
        CCTRL_CODEX_LOCK_BACKUP_DIR="$backup" "$ROOT/cctrl" session release-to-app TMUX--release --yes --json)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "unanchored legacy release unexpectedly succeeded"
    assert_contains "$out" '"error": "non-transferable-state"'
    [[ -e "$codex_home/thread-writer-locks/thread-release-1.lock" ]] || fail "rejected release touched the writer lock"
    control="$(session_record_json "TMUX--release" "$meta" | jq -r '.control_surface')"
    [[ "$control" == "null" ]] || fail "rejected release changed control surface: $control"
    [[ "$(session_record_json "TMUX--release" "$meta" | jq -r '.control_owner')" == "null" ]] || fail "rejected release changed owner"
    [[ "$(sqlite3 "$codex_home/state_5.sqlite" "SELECT archived FROM threads WHERE id='thread-release-1'")" == "0" ]] \
        || fail "release-to-app archived the Codex task"
    echo "ok: release-to-app rejects unanchored legacy ownership before lock repair"
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
    assert_contains "$(cat "$log2")" "kill-session -t =TMUX--drname"
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
# Pane/window-target commands (list-panes, display-message, display,
# capture-pane, ...) require the trailing ":" on tmux's exact "=NAME" match
# syntax; a bare "=NAME" (no colon) must fail to resolve, matching real tmux
# (verified against tmux 3.7c; see plan 080's review). Strip a well-formed
# "=NAME:" down to the bare name; leave a colon-less "=NAME" as a target
# nothing below will match.
if [[ "$target" == *: ]]; then
    target="${target#=}"
    target="${target%:}"
elif [[ "$target" == "="* ]]; then
    target="__cctrl_test_unmatched__"
fi
if [[ "${1:-}" == "-u" ]]; then shift; fi
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

test_session_prune_claude_long_transcript_user_turn_not_flagged() {
    # Plan 081, P1a regression: a transcript over 500 lines whose user turn
    # sits within the first few lines must not be misclassified as
    # never-prompted. Before the fix, _session_never_prompted's Claude branch
    # did `head -n 500 "$tpath" | grep -qE '"(type|role)":"user"' && return 1`
    # under `set -euo pipefail`: grep -q can exit as soon as it sees the
    # match, head can then get SIGPIPE writing the rest of its 500 lines, and
    # pipefail reports that as pipeline failure -- so the check silently fell
    # through to "never-prompted" even though the transcript plainly had a
    # user turn. The fix captures head's output into a variable before
    # grepping it, so there is no pipe left for pipefail to misread.
    local bin="$TMPDIR/lt-bin" sdir="$TMPDIR/lt-sess" pdir="$TMPDIR/lt-proj"
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
{"pid":4646,"sessionId":"lt-uuid","updatedAt":$now_ms}
JSON
    # Pad each line so the first 500 lines exceed a pipe buffer (64KB on
    # macOS/Linux): head must still be writing when grep -q's early match on
    # line 1 closes its read end, so head reliably gets SIGPIPE and the
    # pipefail bug actually reproduces. A handful of short lines fits in one
    # buffer's worth and never races.
    local pad; pad="$(printf 'x%.0s' $(seq 1 2000))"
    {
        printf '{"type":"user","message":{"role":"user","content":"do the thing"}}\n'
        local i
        for i in $(seq 1 600); do
            printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"line %d %s"}]}}\n' "$i" "$pad"
        done
    } > "$pdir/p/lt-uuid.jsonl"
    [[ "$(wc -l < "$pdir/p/lt-uuid.jsonl")" -gt 500 ]] || fail "fixture transcript must exceed 500 lines"
    [[ "$(head -n 500 "$pdir/p/lt-uuid.jsonl" | wc -c)" -gt 65536 ]] || fail "fixture's first 500 lines must exceed a pipe buffer to actually race SIGPIPE"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        TMUX_FAKE_SESSIONS="TMUX--lt" TMUX_FAKE_PANE_PID=4646 "$ROOT/cctrl" session prune --json)"
    [[ "$out" == "[]" ]] || fail "a >500-line transcript with an early user turn must not be pruned; got: $out"
    echo "ok: long transcript with an early user turn is not misclassified as never-prompted"
}

test_session_prune_yes_caps_large_batch() {
    # Plan 081, P1b: --yes refuses to close an oversized batch of candidates
    # (the exact shape of the incident this plan fixes: a classifier bug
    # proposing a large fraction of the fleet in one call) unless
    # --allow-large-batch is also given. --force already means something else
    # in this codebase (include attached sessions) and must not also bypass
    # the cap.
    local bin="$TMPDIR/cap-bin" meta="$TMPDIR/cap-meta"
    mkdir -p "$bin" "$meta"
    make_fake_tmux "$bin/tmux"
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
echo "-zsh"; exit 0
SH
    chmod +x "$bin/ps"

    # Six old, staleness-only candidates (default --older-than 72h; no
    # transcript fixtures needed since staleness alone is the reason). With
    # PRUNE_CAP_K=5 and PRUNE_CAP_PCT=25, max(5, ceil(25% of 6)=2) = 5 < 6.
    local names="" i
    for i in $(seq 1 6); do
        names="$names TMUX--cap$i"
        cat > "$meta/TMUX--cap$i.json" <<'JSON'
{"created_at":"2020-01-01T00:00:00Z"}
JSON
    done
    names="${names# }"

    local log="$TMPDIR/prune-cap-refuse.log"; : > "$log"
    local out rc=0
    out="$(PATH="$bin:$PATH" TMUX_LOG="$log" CCTRL_SESSION_METADATA_DIR="$meta" \
        CCTRL_CLAUDE_SESSIONS_DIR="$TMPDIR/cap-nope" CCTRL_CLAUDE_PROJECTS_DIR="$TMPDIR/cap-nope" \
        TMUX_FAKE_SESSIONS="$names" "$ROOT/cctrl" session prune --yes 2>&1)" || rc=$?
    [[ "$rc" -eq 75 ]] || fail "expected an oversized --yes batch to refuse with 75 (rc=$rc): $out"
    assert_contains "$out" "Refusing to close 6 candidate(s)"
    assert_contains "$out" "--allow-large-batch"
    assert_not_contains "$(cat "$log")" "kill-session"

    # --force alone (widens which sessions are considered) must not bypass
    # the cap -- it means something different in this codebase.
    rc=0
    out="$(PATH="$bin:$PATH" TMUX_LOG="$log" CCTRL_SESSION_METADATA_DIR="$meta" \
        CCTRL_CLAUDE_SESSIONS_DIR="$TMPDIR/cap-nope" CCTRL_CLAUDE_PROJECTS_DIR="$TMPDIR/cap-nope" \
        TMUX_FAKE_SESSIONS="$names" "$ROOT/cctrl" session prune --yes --force 2>&1)" || rc=$?
    [[ "$rc" -eq 75 ]] || fail "expected --force to leave the safety cap in place (rc=$rc): $out"

    local log2="$TMPDIR/prune-cap-allow.log"; : > "$log2"
    out="$(PATH="$bin:$PATH" TMUX_LOG="$log2" TMUX_FAKE_HAS_SESSION=1 CCTRL_SESSION_METADATA_DIR="$meta" \
        CCTRL_CLAUDE_SESSIONS_DIR="$TMPDIR/cap-nope" CCTRL_CLAUDE_PROJECTS_DIR="$TMPDIR/cap-nope" \
        TMUX_FAKE_SESSIONS="$names" "$ROOT/cctrl" session prune --yes --allow-large-batch)" \
        || fail "expected --allow-large-batch to proceed: $out"
    assert_contains "$out" "Closing 6 prune candidate(s)"
    local kills; kills="$(grep -c 'kill-session' "$log2" || true)"
    [[ "$kills" -eq 6 ]] || fail "expected 6 kill-session calls under --allow-large-batch, got $kills: $(cat "$log2")"
    echo "ok: prune --yes refuses an oversized batch unless --allow-large-batch overrides it"
}

test_session_mark_closed_provisional_launch_record() (
    # Plan 081, P2: a session that never got a stable provider id only has a
    # launch-*.json provisional record (no task-*.json). Before the fix,
    # _session_task_records_for_name globbed only task-*.json, so mark-closed
    # (and _session_close/prune, which share the same lookup) could never
    # close it through any normal path. A name whose tmux session is gone
    # now closes; a name whose tmux session is still live is refused, same as
    # today's live-name protection for canonical records.
    local meta="$TMPDIR/p2-meta" bin="$TMPDIR/p2-bin" file file2 file3 out rc=0 old_created
    mkdir -p "$meta" "$bin"
    make_fake_tmux "$bin/tmux"
    export CCTRL_SESSION_METADATA_DIR="$meta"

    # conversation_id (the 11th positional) empty -> _session_write_metadata
    # writes launch-<uuid>.json with lifecycle_state=provisional and no
    # task-*.json ever exists for this name.
    cctrl_source_eval '_session_write_metadata "$1" /tmp directory /tmp label purpose prompt cmd "" claude "" ""' s-gone-prov >/dev/null
    file="$(session_record_path s-gone-prov "$meta")" || fail "no provisional record was written for s-gone-prov"
    [[ "$(basename "$file")" == launch-*.json ]] || fail "expected a launch-*.json record, got $(basename "$file")"
    [[ "$(jq -r '.lifecycle_state' "$file")" == provisional ]] || fail "fixture record is not provisional: $(jq -c . "$file")"
    # Backdate past the 300s startup grace (plan 084 re-review of 081): this
    # scenario means "genuinely gone", not "still in its launch window", and
    # the grace test below covers the fresh-and-gone case directly.
    old_created="$(date -u -v-400S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "400 seconds ago" +"%Y-%m-%dT%H:%M:%SZ")"
    jq --arg t "$old_created" '.created_at=$t' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

    out="$(PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" TMUX_FAKE_SESSIONS="TMUX--other" \
        "$ROOT/cctrl" session mark-closed s-gone-prov --apply 2>&1)" \
        || fail "mark-closed --apply on a gone provisional-only record failed: $out"
    [[ "$(jq -r '.lifecycle_state' "$file")" == closed ]] || fail "mark-closed --apply did not close the provisional record: $(jq -c . "$file")"

    # A freshly-launched provisional record with no live tmux session yet is
    # NOT offered, within the startup grace (plan 084 re-review of 081):
    # _session_write_metadata writes the launch receipt before `tmux
    # new-session` runs, so a mark-closed landing in that window must not
    # close a session that is only still starting up.
    cctrl_source_eval '_session_write_metadata "$1" /tmp directory /tmp label purpose prompt cmd "" claude "" ""' s-starting-prov >/dev/null
    file3="$(session_record_path s-starting-prov "$meta")" || fail "no provisional record was written for s-starting-prov"
    out="$(PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" TMUX_FAKE_SESSIONS="TMUX--other" \
        "$ROOT/cctrl" session mark-closed s-starting-prov --apply 2>&1)" \
        || fail "mark-closed --apply on a fresh starting-up provisional record failed: $out"
    assert_contains "$out" "No open cctrl/tmux records claim"
    [[ "$(jq -r '.lifecycle_state' "$file3")" == provisional ]] \
        || fail "mark-closed closed a fresh provisional record still inside its startup grace: $(jq -c . "$file3")"

    # A live tmux session with the same provisional-only shape is refused,
    # exactly like mark-closed already refuses a live name backed by a
    # canonical task-*.json record.
    cctrl_source_eval '_session_write_metadata "$1" /tmp directory /tmp label purpose prompt cmd "" claude "" ""' s-live-prov >/dev/null
    file2="$(session_record_path s-live-prov "$meta")" || fail "no provisional record was written for s-live-prov"
    rc=0
    out="$(PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" TMUX_FAKE_SESSIONS="s-live-prov" \
        "$ROOT/cctrl" session mark-closed s-live-prov --apply 2>&1)" || rc=$?
    [[ "$rc" -eq 75 ]] || fail "mark-closed on a live provisional-only session did not refuse with 75 (rc=$rc): $out"
    [[ "$(jq -r '.lifecycle_state' "$file2")" == provisional ]] || fail "mark-closed closed a record for a still-live session: $(jq -c . "$file2")"
    echo "ok: mark-closed closes a provisional-only (launch-*.json) record once its tmux session is genuinely gone; withholds it during its startup grace; refuses while live"
)

test_session_task_records_for_name_launch_liveness_gate() (
    # Plan 081, P2 (direct unit coverage): mark-closed's own live-name check
    # already refuses a live session before ever reaching
    # _session_task_records_for_name, so the end-to-end test above never
    # actually exercises that helper's own `tmux has-session -t "=$1"` gate
    # around launch-*.json (cctrl:12420). Call the helper directly, with the
    # fake tmux's has-session answering both ways, so a regression in the
    # gate itself (not just in mark-closed's outer guard) is caught.
    local meta="$TMPDIR/p2-gate-meta" bin="$TMPDIR/p2-gate-bin" file old_created
    mkdir -p "$meta" "$bin"
    make_fake_tmux "$bin/tmux"
    export CCTRL_SESSION_METADATA_DIR="$meta"

    cctrl_source_eval '_session_write_metadata "$1" /tmp directory /tmp label purpose prompt cmd "" claude "" ""' s-gate-prov >/dev/null
    file="$(session_record_path s-gate-prov "$meta")" || fail "no provisional record was written for s-gate-prov"
    [[ "$(basename "$file")" == launch-*.json ]] || fail "expected a launch-*.json record, got $(basename "$file")"
    # Backdate past the 300s startup grace (plan 084 re-review of 081) so this
    # exercises "genuinely gone", not "still starting up"; the fresh case is
    # covered separately below.
    old_created="$(date -u -v-400S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "400 seconds ago" +"%Y-%m-%dT%H:%M:%SZ")"
    jq --arg t "$old_created" '.created_at=$t' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

    local out
    out="$(PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" TMUX_FAKE_HAS_SESSION="" \
        cctrl_source_eval '_session_task_records_for_name "$1" cctrl-tmux' s-gate-prov)"
    [[ "$out" == "$file" ]] || fail "gone session: expected the launch record listed, got: $out"

    out="$(PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" TMUX_FAKE_HAS_SESSION="s-gate-prov" \
        cctrl_source_eval '_session_task_records_for_name "$1" cctrl-tmux' s-gate-prov)"
    [[ -z "$out" ]] || fail "live session: expected no launch record offered, got: $out"

    # Fresh (not backdated) + no live tmux session: still inside the startup
    # grace, so the record must not be offered as closeable (plan 084
    # re-review of 081's missing-grace finding).
    cctrl_source_eval '_session_write_metadata "$1" /tmp directory /tmp label purpose prompt cmd "" claude "" ""' s-gate-fresh-prov >/dev/null
    out="$(PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" TMUX_FAKE_HAS_SESSION="" \
        cctrl_source_eval '_session_task_records_for_name "$1" cctrl-tmux' s-gate-fresh-prov)"
    [[ -z "$out" ]] || fail "fresh + gone session: expected no launch record offered inside the startup grace, got: $out"
    echo "ok: _session_task_records_for_name's own liveness gate includes launch-*.json only once its tmux session is confirmed gone and past its startup grace"
)

test_task_record_close_provisional_honors_digest_guard() (
    # Plan 084 re-review of 081: _task_record_transition_file's generic path
    # refuses (75) when the caller's digest guard no longer matches the
    # record on disk, but its special-case launch-*.json close path used to
    # call _task_record_close_provisional_file without forwarding that guard
    # at all -- silently ignoring a caller's stale-read protection instead of
    # refusing. Nothing in cctrl reaches this with a real digest yet (only
    # lib/conflict_resolve.py's "close" rows do, and those only read
    # task-*.json), so this is direct unit coverage of the guard itself.
    local meta="$TMPDIR/digest-guard-meta" file digest rc=0
    mkdir -p "$meta"
    export CCTRL_SESSION_METADATA_DIR="$meta"

    cctrl_source_eval '_session_write_metadata "$1" /tmp directory /tmp label purpose prompt cmd "" claude "" ""' s-digest-prov >/dev/null
    file="$(session_record_path s-digest-prov "$meta")" || fail "no provisional record was written for s-digest-prov"
    digest="$(cctrl_source_eval '_task_registry_record_digest "$1"' "$file")" || fail "could not compute the fixture record's digest"

    rc=0
    cctrl_source_eval '_task_record_transition_file "$1" s-digest-prov unknown unknown closed "" cctrl-test authoritative "stale guard" wrong-digest' "$file" >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 75 ]] || fail "a stale digest guard on a provisional close did not refuse with 75 (rc=$rc)"
    [[ "$(jq -r '.lifecycle_state' "$file")" == provisional ]] \
        || fail "a stale digest guard closed the provisional record anyway: $(jq -c . "$file")"

    cctrl_source_eval '_task_record_transition_file "$1" s-digest-prov unknown unknown closed "" cctrl-test authoritative "matching guard" "$2"' "$file" "$digest" >/dev/null \
        || fail "a matching digest guard was refused on a provisional close"
    [[ "$(jq -r '.lifecycle_state' "$file")" == closed ]] \
        || fail "a matching digest guard did not close the provisional record: $(jq -c . "$file")"
    echo "ok: a provisional launch-*.json close honors its caller's digest guard (refuses when stale, applies when matching)"
)

test_session_record_terminated_closes_fresh_anchored_provisional() (
    # Plan 084 re-review of 081 (required fix from eng review): the 300s
    # startup grace added to _session_task_records_for_name's name-only
    # "cctrl-tmux" selector must NOT gate the pane-anchored selector that
    # _session_record_terminated (kill/close/stop-exact) uses. An exact
    # pane_id+pane_pid anchor match is identity evidence cctrl captured
    # itself before tearing the pane down -- there is no "still starting
    # up" ambiguity to guard against, and age-gating it would leave a
    # session the user explicitly closed within its first 5 minutes wrongly
    # stuck at lifecycle_state=provisional (and so still offered as a
    # tmux-resume restore candidate).
    local meta="$TMPDIR/anchor-terminated-meta" bin="$TMPDIR/anchor-terminated-bin" file receipt out
    mkdir -p "$meta" "$bin"
    make_fake_tmux "$bin/tmux"
    export CCTRL_SESSION_METADATA_DIR="$meta"

    cctrl_source_eval '_session_write_metadata "$1" /tmp directory /tmp label purpose prompt cmd "" claude "" ""' s-anchor-fresh-prov >/dev/null
    file="$(session_record_path s-anchor-fresh-prov "$meta")" || fail "no provisional record was written for s-anchor-fresh-prov"
    [[ "$(jq -r '.lifecycle_state' "$file")" == provisional ]] || fail "fixture record is not provisional: $(jq -c . "$file")"

    receipt='{"control_surface":"tmux","tmux_session":"s-anchor-fresh-prov","pane_id":"%1","pane_pid":"12345","wrapper_pid":"12345","pane_started":"Mon Sep 29 00:00:00 2026"}'
    cctrl_source_eval '_session_update_metadata_field "$1" _terminal_anchor_receipt "$2"' s-anchor-fresh-prov "$receipt" >/dev/null \
        || fail "could not attach a pane anchor to the fresh provisional fixture"
    [[ "$(jq -r '.pane_id' "$file")" == "%1" ]] || fail "anchor was not persisted onto the provisional record: $(jq -c . "$file")"

    out="$(PATH="$bin:$PATH" CCTRL_SESSION_METADATA_DIR="$meta" TMUX_FAKE_HAS_SESSION="" \
        cctrl_source_eval '_session_record_terminated "$1" "%1 12345" "test: anchored close"' s-anchor-fresh-prov 2>&1)"
    [[ "$(jq -r '.lifecycle_state' "$file")" == closed ]] \
        || fail "an anchored close did not close a fresh (0s-old) provisional record: $(jq -c . "$file"); output: $out"
    echo "ok: _session_record_terminated's pane-anchored close is not gated by the launch-*.json startup grace"
)

test_snapshot_excludes_stale_provisional_restore_candidates() {
    # Plan 081, P2 impact: because of the P2 bug, a provisional record whose
    # tmux session died stuck forever at lifecycle_state=provisional (it
    # never reached "closed"), so it kept surviving into latest.json as a
    # restore_strategy:tmux-resume candidate -- a reboot-time restore could
    # then try to resurrect a session that was supposed to stay gone. The fix
    # is at the capture layer: a provisional record with no live tmux session
    # is only still a tmux-resume candidate within a short grace window
    # (covering the real race where cctrl writes the launch receipt before
    # `tmux new-session` runs); past that window it is stale and excluded.
    # This must filter on staleness, not on "provisional" itself -- a
    # genuinely fresh, still-starting-up provisional row must still appear.
    local root="$TMPDIR/snapshot-stale-prov" host="0123456789abcdef0123456789abcdef"
    mkdir -p "$root/data" "$root/snapshots"
    printf '%s\n' "$host" > "$root/data/host-id"
    cat > "$root/process.json" <<'JSON'
{"schema_version":1,"status":"available","observed_at":"2026-09-24T10:00:00Z","source_cursor":"p","processes":[],"error":null}
JSON
    local stale_ts now_ts near_fresh_ts near_stale_ts
    stale_ts="$(date -u -v-1H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "1 hour ago" +"%Y-%m-%dT%H:%M:%SZ")"
    now_ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    # Near-boundary rows (plan 084 re-review of 081): the 1h-vs-0s pair above
    # only proves the filter exists, not that it actually sits at
    # PROVISIONAL_STALE_GRACE_SECONDS (300s). 60s (well inside the grace) and
    # 310s (just past it) pin the threshold without racing exactly 300s
    # against wall-clock drift while the snapshot command itself runs.
    near_fresh_ts="$(date -u -v-60S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "60 seconds ago" +"%Y-%m-%dT%H:%M:%SZ")"
    near_stale_ts="$(date -u -v-310S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "310 seconds ago" +"%Y-%m-%dT%H:%M:%SZ")"
    row() { # id tmux recency
        printf '{"provider":"claude","provider_task_id":null,"host_id":"%s","origin":"cctrl","execution_runtime":"tmux","control_owner":"cctrl","lifecycle_state":"provisional","restore_strategy":"tmux","registered_by_cctrl":true,"launched_by_cctrl":true,"cwd":"/tmp/x","display_title":"%s","tmux_session":"%s","recency":"%s","action_capabilities":{"tmux_attach":{"supported":false}}}' \
            "$host" "$1" "$2" "$3"
    }
    cat > "$root/catalogue.json" <<JSON
{"schema_version":2,"host_id":"$host","source_status":{"registry":"available","tmux":"available","codex_provider":"available"},"source_errors":[],"rows":[
 $(row stale-prov TMUX--stale-prov "$stale_ts"), $(row fresh-prov TMUX--fresh-prov "$now_ts"),
 $(row near-fresh-prov TMUX--near-fresh-prov "$near_fresh_ts"), $(row near-stale-prov TMUX--near-stale-prov "$near_stale_ts")
]}
JSON
    printf '[]\n' > "$root/sessions.json"   # neither name has a live tmux session
    local out
    out="$(CCTRL_DATA_DIR="$root/data" CCTRL_HOST_ID_FILE="$root/data/host-id" CCTRL_SNAPSHOT_CATALOGUE_FILE="$root/catalogue.json" \
      CCTRL_SNAPSHOT_SESSIONS_FILE="$root/sessions.json" CCTRL_SNAPSHOT_PROCESS_FILE="$root/process.json" \
      CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=0 "$ROOT/cctrl" session snapshot --dir "$root/snapshots" --json)" \
      || fail "snapshot with a stale provisional row failed: $out"
    jq -e '[.tasks[] | select(.tmux_session=="TMUX--stale-prov")] | length==1 and .[0].restore_strategy==null' <<< "$out" >/dev/null \
        || fail "a stale provisional row still carries restore_strategy tmux-resume: $(jq -c '[.tasks[]|select(.tmux_session=="TMUX--stale-prov")]' <<< "$out")"
    jq -e '[.tasks[] | select(.tmux_session=="TMUX--fresh-prov")] | length==1 and .[0].restore_strategy=="tmux-resume"' <<< "$out" >/dev/null \
        || fail "a genuinely fresh provisional row lost its tmux-resume candidacy: $(jq -c '[.tasks[]|select(.tmux_session=="TMUX--fresh-prov")]' <<< "$out")"
    jq -e '[.tasks[] | select(.tmux_session=="TMUX--near-fresh-prov")] | length==1 and .[0].restore_strategy=="tmux-resume"' <<< "$out" >/dev/null \
        || fail "a 60s-old provisional row (inside the 300s grace) lost its tmux-resume candidacy: $(jq -c '[.tasks[]|select(.tmux_session=="TMUX--near-fresh-prov")]' <<< "$out")"
    jq -e '[.tasks[] | select(.tmux_session=="TMUX--near-stale-prov")] | length==1 and .[0].restore_strategy==null' <<< "$out" >/dev/null \
        || fail "a 310s-old provisional row (past the 300s grace) still carries restore_strategy tmux-resume: $(jq -c '[.tasks[]|select(.tmux_session=="TMUX--near-stale-prov")]' <<< "$out")"
    jq -e '[.tasks[] | select(.restore_strategy=="tmux-resume") | .tmux_session] | sort == ["TMUX--fresh-prov","TMUX--near-fresh-prov"]' <<< "$out" >/dev/null \
        || fail "restore-candidate rows are not exactly the two fresh provisional ones: $(jq -c '[.tasks[] | select(.restore_strategy=="tmux-resume") | .tmux_session]' <<< "$out")"
    [[ "$(jq -r '.restore_candidate_count' <<< "$out")" == 2 ]] || fail "restore_candidate_count did not exclude both stale provisional rows: $(jq -r '.restore_candidate_count' <<< "$out")"
    echo "ok: a stale provisional record is excluded from tmux-resume restore candidates (including a near-boundary 310s row); a fresh one still appears (including a near-boundary 60s row)"
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
# Pane/window-target commands (list-panes, display-message, display,
# capture-pane, ...) require the trailing ":" on tmux's exact "=NAME" match
# syntax; a bare "=NAME" (no colon) must fail to resolve, matching real tmux
# (verified against tmux 3.7c; see plan 080's review). Strip a well-formed
# "=NAME:" down to the bare name; leave a colon-less "=NAME" as a target
# nothing below will match.
if [[ "$target" == *: ]]; then
    target="${target#=}"
    target="${target%:}"
elif [[ "$target" == "="* ]]; then
    target="__cctrl_test_unmatched__"
fi
if [[ "${1:-}" == "-u" ]]; then shift; fi
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

# Durable host id shared by the ported snapshot/restore fixtures below.
_SR_HOST_ID=0123456789abcdef0123456789abcdef

_snapshot_v2_evidence() {
    # args: dir [catalogue-rows-json-array]
    # Writes the evidence a schema-v2 capture needs besides the fake tmux:
    # a schema-2 task catalogue (all mandatory sources available), a process
    # snapshot, and a durable host id. Default rows: one live cctrl/tmux row
    # owning TMUX--snap for the _snapshot_fixture conversation. Nothing is
    # exported; _snapshot_run passes every seam per command.
    local dir="$1" rows="${2:-}"
    mkdir -p "$dir"
    if [[ -z "$rows" ]]; then
        rows="$(jq -nc '[{provider:"claude",provider_task_id:"snap-conv-uuid",origin:"cctrl",execution_runtime:"tmux",control_owner:"cctrl",lifecycle_state:"active",restore_strategy:"tmux",registered_by_cctrl:true,launched_by_cctrl:true,cwd:"/tmp/demo",display_title:"snap",tmux_session:"TMUX--snap",action_capabilities:{tmux_attach:{supported:true}}}]')"
    fi
    printf '%s\n' "$_SR_HOST_ID" > "$dir/host-id"
    printf '%s\n' '{"schema_version":1,"status":"available","observed_at":"2026-09-24T10:00:00Z","source_cursor":"p","processes":[],"error":null}' > "$dir/process.json"
    jq -n --arg host "$_SR_HOST_ID" --argjson rows "$rows" \
        '{schema_version:2,host_id:$host,source_status:{registry:"available",tmux:"available",codex_provider:"available"},source_errors:[],rows:($rows|map({host_id:$host}+.))}' \
        > "$dir/catalogue.json"
}

_snapshot_run() {
    # args: evidence-dir bindir sessdir projdir metadir snapdir [snapshot flags...]
    # Live sessions come from the real `session ls` path over the fake tmux
    # (TMUX--snap); the catalogue and process table are injected.
    local ev="$1" bin="$2" sdir="$3" pdir="$4" meta="$5" snapdir="$6"
    shift 6
    PATH="$bin:$PATH" CCTRL_HOST_ID_FILE="$ev/host-id" CCTRL_SNAPSHOT_CATALOGUE_FILE="$ev/catalogue.json" \
        CCTRL_SNAPSHOT_PROCESS_FILE="$ev/process.json" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" CCTRL_CLAUDE_PROJECTS_DIR="$pdir" \
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=100 \
        TMUX_FAKE_SESSIONS="TMUX--snap" "$ROOT/cctrl" session snapshot --dir "$snapdir" "$@"
}

_snapshot_ls_json() {
    # args: evidence-dir bindir sessdir projdir metadir -- `session ls --json`
    # over the same fake tmux and host id a _snapshot_run sees.
    PATH="$2:$PATH" CCTRL_HOST_ID_FILE="$1/host-id" CCTRL_CLAUDE_SESSIONS_DIR="$3" CCTRL_CLAUDE_PROJECTS_DIR="$4" \
        CCTRL_SESSION_METADATA_DIR="$5" TMUX_FAKE_SESSIONS="TMUX--snap" "$ROOT/cctrl" session ls --json
}

test_tmux_inventory_survives_sanitized_formats() {
    # tmux 3.7 prints control characters in -F output as "_". The read-only
    # inventory must still parse every session, including names with ":".
    local bin="$TMPDIR/tmux-sanitize-bin"
    mkdir -p "$bin"
    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
fmt=""; target=""; cmd="$1"; shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        -F) fmt="$2"; shift 2 ;;
        -t)
            # list-panes requires the trailing ":" on an exact "=NAME"
            # target; a colon-less "=NAME" must not resolve (plan 080).
            if [[ "$2" == *: ]]; then
                target="${2#=}"; target="${target%:}"
            elif [[ "$2" == "="* ]]; then
                target="__cctrl_test_unmatched__"
            else
                target="$2"
            fi
            shift 2 ;;
        *) shift ;;
    esac
done
emit() { printf '%s\n' "$1" | LC_ALL=C tr '\001-\011\013-\037' '_'; }
case "$cmd" in
    list-sessions)
        for entry in '$3|TMUX--ms--demo|1790000000' '$7|odd:name.x|1790000001'; do
            IFS='|' read -r id name activity <<< "$entry"
            out="${fmt//'#{session_id}'/$id}"; out="${out//'#{session_name}'/$name}"; out="${out//'#{session_activity}'/$activity}"
            emit "$out"
        done ;;
    list-panes)
        out="${fmt//'#{pane_id}'/%9}"; out="${out//'#{pane_pid}'/4242}"; out="${out//'#{pane_current_path}'//tmp/$target}"
        emit "$out" ;;
esac
SH
    chmod +x "$bin/tmux"
    local out
    out="$(PATH="$bin:$PATH" cctrl_source_eval '_task_tmux_rows_json_readonly')"
    jq -e '
        .status == "available" and (.errors | length) == 0 and (.rows | length) == 2 and
        (.rows[0] | .session_id == "$3" and .name == "TMUX--ms--demo" and .pane_id == "%9" and .pane_pid == "4242" and .recency != null) and
        (.rows[1] | .session_id == "$7" and .name == "odd:name.x")
    ' <<< "$out" >/dev/null || fail "tmux inventory mis-parsed sanitized -F output: $out"
    echo "ok: tmux inventory parses sanitized -F output and names containing ':'"
}

test_snapshot_header_and_session_shape() {
    local bin="$TMPDIR/sh-bin" sdir="$TMPDIR/sh-sess" pdir="$TMPDIR/sh-proj" meta="$TMPDIR/sh-meta"
    local snapdir="$TMPDIR/sh-snapshots" ev="$TMPDIR/sh-ev"
    mkdir -p "$snapdir"
    _snapshot_fixture "$bin" "$sdir" "$pdir" "$meta"
    _snapshot_v2_evidence "$ev"

    local out
    out="$(_snapshot_run "$ev" "$bin" "$sdir" "$pdir" "$meta" "$snapdir" --json)" || fail "snapshot failed: $out"
    jq -e --arg host "$_SR_HOST_ID" '
        .schema_version == 2 and (.generated_at | type == "string" and length > 0)
        and (.hostname | type == "string" and length > 0) and .host_id == $host
        and .session_count == 1 and .task_reference_count == 1
        and .resource_metadata.memory_free_percent == 50 and .resource_metadata.swap_used_mb == 100
        and .capture_quality.status == "complete"' <<< "$out" >/dev/null \
        || fail "snapshot header is wrong: $(jq -c 'del(.tasks)' <<< "$out")"
    jq -e --arg host "$_SR_HOST_ID" '.tasks[0] |
        .tmux_session == "TMUX--snap" and .live == true and .recovery_action == "already-live"
        and .provider == "claude" and .provider_task_id == "snap-conv-uuid" and .resume_identity == "snap-conv-uuid"
        and .resume_identity_kind == "claude-session-id" and .host_id == $host
        and .purpose == "test snapshot" and .display_label == "snap" and .cwd == "/tmp/demo"
        and .agent == "claude" and (.launch_flags | type == "object")' <<< "$out" >/dev/null \
        || fail "snapshot task shape is wrong: $(jq -c '.tasks' <<< "$out")"
    [[ -f "$snapdir/latest.json" ]] || fail "latest.json not created"
    local hcount
    hcount="$(find "$snapdir" -maxdepth 1 -type f -name '[0-9]*.json' -print | wc -l | tr -d ' ')"
    [[ "$hcount" -ge 1 ]] || fail "no history file created"
    echo "ok: snapshot header and per-session shape"
}

test_snapshot_initial_prompt_absent() {
    local bin="$TMPDIR/ip-bin" sdir="$TMPDIR/ip-sess" pdir="$TMPDIR/ip-proj" meta="$TMPDIR/ip-meta"
    local snapdir="$TMPDIR/ip-snapshots" ev="$TMPDIR/ip-ev"
    mkdir -p "$snapdir"
    _snapshot_fixture "$bin" "$sdir" "$pdir" "$meta"
    _snapshot_v2_evidence "$ev"
    cat > "$meta/TMUX--snap.json" <<'JSON'
{"name":"TMUX--snap","cwd":"/tmp/demo","target":"/tmp/demo","target_kind":"dir","host":"test-host","display_label":"snap","purpose":"test","initial_prompt":"do the thing","launch_command":"claude","cctrl_managed":true}
JSON

    local out
    out="$(_snapshot_run "$ev" "$bin" "$sdir" "$pdir" "$meta" "$snapdir" --json)" || fail "snapshot failed: $out"
    jq -e '.tasks | length == 1' <<< "$out" >/dev/null || fail "fixture session was not captured: $out"
    assert_not_contains "$out" 'initial_prompt'
    assert_not_contains "$out" 'do the thing'
    assert_not_contains "$(cat "$snapdir/latest.json")" 'do the thing'
    echo "ok: initial_prompt absent from snapshot"
}

test_snapshot_empty_fleet_guard_preserves() {
    local bin="$TMPDIR/eg-bin" snapdir="$TMPDIR/eg-snapshots"
    mkdir -p "$bin" "$snapdir"
    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then shift; fi
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
if [[ "${1:-}" == "-u" ]]; then shift; fi
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
    local snapdir="$TMPDIR/ha-snapshots" ev="$TMPDIR/ha-ev"
    mkdir -p "$snapdir"
    _snapshot_fixture "$bin" "$sdir" "$pdir" "$meta"
    _snapshot_v2_evidence "$ev"

    _snapshot_run "$ev" "$bin" "$sdir" "$pdir" "$meta" "$snapdir" --quiet || fail "snapshot failed"

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
    local snapdir="$TMPDIR/rp-snapshots" ev="$TMPDIR/rp-ev"
    mkdir -p "$snapdir"
    _snapshot_fixture "$bin" "$sdir" "$pdir" "$meta"
    _snapshot_v2_evidence "$ev"

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

    _snapshot_run "$ev" "$bin" "$sdir" "$pdir" "$meta" "$snapdir" --quiet || fail "snapshot failed"

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
    # tmux missing from PATH: the live-session source is unavailable, so the
    # capture is degraded -- exit 69 (evidence unavailable) and latest.json is
    # preserved byte-for-byte, never replaced by an empty capture.
    local bin="$TMPDIR/ta-bin" snapdir="$TMPDIR/ta-snapshots" ev="$TMPDIR/ta-ev"
    mkdir -p "$bin" "$snapdir"
    cp "$TMPDIR/hostname" "$bin/hostname"
    _snapshot_v2_evidence "$ev"
    command -v jq >/dev/null && ln -sf "$(command -v jq)" "$bin/jq"
    cat > "$snapdir/latest.json" <<'JSON'
{"schema_version":1,"session_count":3,"sessions":[{"name":"a"},{"name":"b"},{"name":"c"}]}
JSON
    local latest_hash
    latest_hash="$(shasum "$snapdir/latest.json" | awk '{print $1}')"
    [[ ! -x /usr/bin/tmux && ! -x /bin/tmux ]] || fail "fixture invalid: tmux is on the reduced PATH"

    local out rc=0
    out="$(PATH="$(_test_path "$bin")" CCTRL_HOST_ID_FILE="$ev/host-id" CCTRL_SNAPSHOT_CATALOGUE_FILE="$ev/catalogue.json" \
        CCTRL_SNAPSHOT_PROCESS_FILE="$ev/process.json" \
        CCTRL_CLAUDE_SESSIONS_DIR="$TMPDIR/ta-nope" CCTRL_CLAUDE_PROJECTS_DIR="$TMPDIR/ta-nope" \
        CCTRL_SESSION_METADATA_DIR="$TMPDIR/ta-nope" CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=100 \
        "$ROOT/cctrl" session snapshot --dir "$snapdir" 2>&1)" || rc=$?
    [[ "$rc" -eq 69 ]] || fail "snapshot with absent tmux should exit 69 (evidence unavailable); got rc=$rc: $out"
    assert_contains "$out" 'tmux'
    [[ "$latest_hash" == "$(shasum "$snapdir/latest.json" | awk '{print $1}')" ]] || fail "latest.json was modified when tmux absent"
    local hcount
    hcount="$(find "$snapdir" -maxdepth 1 -type f -name '[0-9]*.json' -print | wc -l | tr -d ' ')"
    [[ "$hcount" == 0 ]] || fail "a capture with tmux absent wrote history"
    echo "ok: tmux absent preserves existing latest.json"
}

test_snapshot_first_run_empty_writes() {
    local bin="$TMPDIR/fr-bin" snapdir="$TMPDIR/fr-snapshots"
    mkdir -p "$bin" "$snapdir"
    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then shift; fi
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

test_snapshot_managed_matches_session_ls() {
    # schema-v2 successor of `managed`: the cctrl registration/launch
    # provenance the snapshot records for a live session (with no catalogue
    # row to override it) must agree with what `session ls` reports.
    local bin="$TMPDIR/mm-bin" sdir="$TMPDIR/mm-sess" pdir="$TMPDIR/mm-proj" meta="$TMPDIR/mm-meta"
    local snapdir="$TMPDIR/mm-snapshots" ev="$TMPDIR/mm-ev"
    mkdir -p "$snapdir"
    _snapshot_fixture "$bin" "$sdir" "$pdir" "$meta"
    _snapshot_v2_evidence "$ev" '[]'

    local ls_out snap_out ls_prov snap_prov
    ls_out="$(_snapshot_ls_json "$ev" "$bin" "$sdir" "$pdir" "$meta")" || fail "session ls failed: $ls_out"
    ls_prov="$(jq -c '.[0] | [.registered_by_cctrl, .launched_by_cctrl]' <<< "$ls_out")"
    snap_out="$(_snapshot_run "$ev" "$bin" "$sdir" "$pdir" "$meta" "$snapdir" --json)" || fail "snapshot failed: $snap_out"
    snap_prov="$(jq -c '.tasks[] | select(.tmux_session=="TMUX--snap") | [.registered_by_cctrl, .launched_by_cctrl]' <<< "$snap_out")"

    [[ "$ls_prov" == "[true,true]" ]] || fail "fixture invalid: session ls does not report cctrl provenance: $ls_prov"
    [[ "$ls_prov" == "$snap_prov" ]] || fail "cctrl provenance mismatch: ls=$ls_prov snapshot=$snap_prov"
    echo "ok: managed (cctrl provenance) matches session ls"
}

test_snapshot_launch_flags_round_trip() {
    local bin="$TMPDIR/lf-bin" sdir="$TMPDIR/lf-sess" pdir="$TMPDIR/lf-proj" meta="$TMPDIR/lf-meta"
    local snapdir="$TMPDIR/lf-snapshots" ev="$TMPDIR/lf-ev"
    mkdir -p "$snapdir"
    _snapshot_fixture "$bin" "$sdir" "$pdir" "$meta" "claude --model claude-fable-5 --permission-mode bypassPermissions --peer fleet-mgr"
    _snapshot_v2_evidence "$ev"

    local out lf_model lf_perm lf_peer
    out="$(_snapshot_run "$ev" "$bin" "$sdir" "$pdir" "$meta" "$snapdir" --json)" || fail "snapshot failed: $out"
    lf_model="$(printf '%s' "$out" | jq -r '.tasks[0].launch_flags.model')"
    lf_perm="$(printf '%s' "$out" | jq -r '.tasks[0].launch_flags.permission_mode')"
    lf_peer="$(printf '%s' "$out" | jq -r '.tasks[0].launch_flags.peer')"
    [[ "$lf_model" == "claude-fable-5" ]] || fail "launch_flags.model should be claude-fable-5; got: $lf_model"
    [[ "$lf_perm" == "bypassPermissions" ]] || fail "launch_flags.permission_mode should be bypassPermissions; got: $lf_perm"
    [[ "$lf_peer" == "fleet-mgr" ]] || fail "launch_flags.peer should be fleet-mgr; got: $lf_peer"

    cat > "$meta/TMUX--snap.json" <<'JSON'
{"name":"TMUX--snap","cwd":"/tmp/demo","target":"/tmp/demo","target_kind":"dir","host":"test-host","cctrl_managed":true}
JSON
    local snapdir2="$TMPDIR/lf-snapshots2"
    mkdir -p "$snapdir2"
    out="$(_snapshot_run "$ev" "$bin" "$sdir" "$pdir" "$meta" "$snapdir2" --json)" || fail "snapshot failed: $out"
    local lf_keys
    lf_keys="$(printf '%s' "$out" | jq '.tasks[0].launch_flags | keys | length')"
    [[ "$lf_keys" == "0" ]] || fail "empty launch_command should produce empty launch_flags; got $lf_keys keys"
    echo "ok: launch_flags round-trip"
}

test_snapshot_conversation_id_from_session_id() {
    # The resume identity of a live session comes from its live session_id
    # (no catalogue row supplies it here) and matches `session ls`.
    local bin="$TMPDIR/ci-bin" sdir="$TMPDIR/ci-sess" pdir="$TMPDIR/ci-proj" meta="$TMPDIR/ci-meta"
    local snapdir="$TMPDIR/ci-snapshots" ev="$TMPDIR/ci-ev"
    mkdir -p "$snapdir"
    _snapshot_fixture "$bin" "$sdir" "$pdir" "$meta"
    _snapshot_v2_evidence "$ev" '[]'

    local ls_out snap_out ls_sid snap_cid
    ls_out="$(_snapshot_ls_json "$ev" "$bin" "$sdir" "$pdir" "$meta")" || fail "session ls failed: $ls_out"
    ls_sid="$(printf '%s' "$ls_out" | jq -r '.[0].session_id')"

    snap_out="$(_snapshot_run "$ev" "$bin" "$sdir" "$pdir" "$meta" "$snapdir" --json)" || fail "snapshot failed: $snap_out"
    snap_cid="$(printf '%s' "$snap_out" | jq -r '.tasks[0].resume_identity')"

    [[ "$ls_sid" == "$snap_cid" ]] || fail "resume_identity ($snap_cid) should match session_id ($ls_sid)"
    [[ "$snap_cid" == "snap-conv-uuid" ]] || fail "resume_identity should be snap-conv-uuid; got: $snap_cid"
    [[ "$(jq -r '.tasks[0].provider_task_id' <<< "$snap_out")" == "snap-conv-uuid" ]] || fail "provider_task_id did not follow the live session_id"
    echo "ok: conversation_id from session_id"
}

_restore_fixture() {
    # Build a restore test environment under DIR: fake hostname/tmux/ps, a
    # schema-v2 snapshot of five tasks, and the current evidence restore joins
    # it with -- task catalogue (every task present but not live, i.e. after a
    # reboot), process table, a Codex ownership pass proving the Codex task's
    # owners absent, and the durable host id. Nothing is exported: _restore_run
    # passes every seam (including the launch log) per command, so no fixture
    # state leaks into later tests in the same shell.
    local dir="$1"
    mkdir -p "$dir/bin" "$dir/snapshots" "$dir/session-metadata"

    cat > "$dir/bin/hostname" <<'SH'
#!/usr/bin/env bash
printf 'test-host\n'
SH
    chmod +x "$dir/bin/hostname"

    cat > "$dir/bin/tmux" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then shift; fi
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

    : > "$dir/launch.log"
    printf '%s\n' "$_SR_HOST_ID" > "$dir/host-id"
    printf '%s\n' '{"schema_version":1,"status":"available","observed_at":"2026-08-05T12:00:00Z","source_cursor":"p","processes":[],"error":null}' > "$dir/process.json"

    local now_iso
    now_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    jq -n --arg host "$_SR_HOST_ID" --arg now "$now_iso" '
      def task($p; $id; $tmux; $label; $purpose; $cwd; $last; $flags):
        {provider:$p, provider_task_id:$id, host_id:$host, origin:"cctrl", execution_runtime:"tmux",
         control_owner:"cctrl", lifecycle_state:"active", restore_strategy:"tmux-resume",
         registered_by_cctrl:true, launched_by_cctrl:true,
         registration_provenance:[{source:"registry"}], launch_provenance:[{source:"launch-receipt"}],
         lineage:{forked_from_id:null,parent_thread_id:null,derived_root_id:null,derived_root_basis:null},
         tmux_session:$tmux,
         resume_identity_kind:(if $id == null then null elif $p == "claude" then "claude-session-id" else "codex-thread-id" end),
         resume_identity:$id, observed_at:$last, ownership_evidence:[], cwd:$cwd, purpose:$purpose,
         display_label:$label, agent:$p, launch_flags:$flags, transcript_path:null, transcript_bytes:null,
         last_active:$last, live:false, recovery_action:"insufficient-evidence",
         recovery_reason:"snapshot is informational until current ownership evidence is joined"};
      [ task("claude"; "conv-aaa-111"; "TMUX--cctrl"; "@cctrl"; "session management"; "/Users/test/dev/cctrl"; "2026-08-05T11:55:00Z";
             {model:"claude-sonnet-4", permission_mode:"bypassPermissions", peer:"fleet-mgr"}),
        task("claude"; "conv-bbb-222"; "TMUX--homelab"; "@homelab"; "homelab infra"; "/Users/test/dev/homelab"; "2026-08-05T12:00:00Z";
             {model:"claude-fable-5"}),
        task("claude"; null; "TMUX--nullconv"; "nullconv"; "no conversation"; "/Users/test/dev/other"; "2026-08-05T10:00:00Z"; {}),
        task("codex"; "conv-ccc-333"; "TMUX--codexproj"; "@codexproj"; "codex project"; "/Users/test/dev/codexproj"; "2026-08-05T11:00:00Z";
             {agent:"codex"}),
        task("claude"; "conv-ddd-444"; "TMUX--bigone"; "@bigone"; "big transcript test"; "/Users/test/dev/bigone"; "2026-08-05T11:30:00Z";
             {model:"claude-opus-4", no_bridge:true, profile:"deep-work"}) ] as $tasks
      | {schema_version:2, generated_at:$now, host_id:$host, hostname:"test-host",
         resource_metadata:{memory_free_percent:50,swap_used_mb:100,load_1m:null}, tasks:$tasks,
         task_reference_count:($tasks|length), catalogue_task_count:($tasks|length),
         omitted_task_references:{count:0,by_provider_state:{}},
         restore_candidate_count:([$tasks[] | select(.provider_task_id != null)] | length),
         capture_quality:{status:"complete",mandatory_sources:{registry:"available",tmux:"available",process:"available",codex_provider:"available"}},
         source_errors:[], session_count:($tasks|length)}' > "$dir/snapshots/latest.json"

    # Current catalogue: one exact row per task id, none live. The Claude rows
    # still carry their cctrl/tmux registry ownership; the Codex row's owner
    # is unknown until the Codex ownership pass below proves absence.
    jq --arg host "$_SR_HOST_ID" '
      {schema_version:2, host_id:$host,
       source_status:{registry:"available",tmux:"available",codex_provider:"available"}, source_errors:[],
       rows:[.tasks[] | select(.provider_task_id != null) |
         {task_key:("provider:" + .provider + ":" + $host + ":" + .provider_task_id),
          provider, provider_task_id, host_id:$host, origin:"cctrl",
          execution_runtime:(if .provider == "codex" then "unknown" else "tmux" end),
          control_owner:(if .provider == "codex" then "unknown" else "cctrl" end),
          lifecycle_state:(if .provider == "codex" then "inactive" else "active" end),
          restore_strategy:"tmux", registered_by_cctrl:true, launched_by_cctrl:true,
          registration_provenance:[{source:"registry"}], launch_provenance:[{source:"launch-receipt"}],
          lineage, ownership_evidence:[], cwd, display_title:.display_label, tmux_session,
          action_capabilities:{tmux_attach:{supported:false,reason:"no-live-cctrl-tmux-owner"}}}]}' \
        "$dir/snapshots/latest.json" > "$dir/catalogue.json"

    jq -n --arg host "$_SR_HOST_ID" '
      {schema_version:1, kind:"codex_reconcile_result_v1", errors:[],
       records:[{provider_task_id:"conv-ccc-333", host_id:$host,
         sources:{registry:{status:"available",source_cursor:"r1",error:null},
                  app_server:{status:"confirmed-absence",source_cursor:"a1",error:null},
                  tmux:{status:"confirmed-absence",source_cursor:"t1",error:null},
                  process_table:{status:"confirmed-absence",source_cursor:"p1",error:null}},
         chosen_outcome:{control_owner:"unknown",execution_runtime:"unknown",lifecycle_state:"inactive",restore_strategy:"tmux-resume"}}]}' \
        > "$dir/codex.json"
}

_restore_run() {
    # args: dir [restore flags...]. Runs `cctrl session restore` against the
    # _restore_fixture evidence with every seam passed per command (nothing
    # exported). Overridable through the caller's command-prefix env:
    # SR_FROM (snapshot path), SR_CATALOGUE (catalogue path; empty = real
    # inventory), CCTRL_FAKE_MEM_FREE_PCT, CCTRL_RESTORE_MAX_ACTIVE,
    # CCTRL_RESTORE_WAVE_SIZE, CCTRL_RESTORE_WAVE_PAUSE. Every run records
    # spawns to the launch log; nothing is ever really launched.
    local dir="$1"
    shift
    PATH="${SR_PATH:-$dir/bin:$PATH}" CCTRL_HOST_ID_FILE="$dir/host-id" \
        CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" \
        CCTRL_RESTORE_CATALOGUE_FILE="${SR_CATALOGUE-$dir/catalogue.json}" \
        CCTRL_RESTORE_PROCESS_FILE="$dir/process.json" \
        CCTRL_RESTORE_CODEX_EVIDENCE_FILE="$dir/codex.json" \
        CCTRL_RESTORE_LAUNCH_LOG="$dir/launch.log" \
        CCTRL_FAKE_MEM_FREE_PCT="${CCTRL_FAKE_MEM_FREE_PCT:-80}" CCTRL_FAKE_SWAP_MB="${CCTRL_FAKE_SWAP_MB:-0}" \
        CCTRL_RESTORE_MAX_ACTIVE="${CCTRL_RESTORE_MAX_ACTIVE:-10}" \
        CCTRL_RESTORE_WAVE_SIZE="${CCTRL_RESTORE_WAVE_SIZE:-2}" CCTRL_RESTORE_WAVE_PAUSE="${CCTRL_RESTORE_WAVE_PAUSE:-0}" \
        "$ROOT/cctrl" session restore --from "${SR_FROM:-$dir/snapshots/latest.json}" "$@"
}

_restore_spawn_count() { wc -l < "$1/launch.log" | tr -d ' '; }

test_restore_only_filter() {
    local dir="$TMPDIR/restore-only"
    _restore_fixture "$dir"
    local out
    out="$(_restore_run "$dir" --only cctrl --only homelab --dry-run --json)" || fail "restore --only dry-run failed: $out"
    local restored
    restored="$(jq -c '[.plan[] | select(.disposition=="restore") | .tmux_session] | sort' <<< "$out")"
    [[ "$restored" == '["TMUX--cctrl","TMUX--homelab"]' ]] || fail "expected exactly cctrl+homelab restore candidates with --only cctrl --only homelab, got $restored"
    local filtered_count
    filtered_count="$(jq '[.plan[] | select(.reason=="filtered by --only")] | length' <<< "$out")"
    [[ "$filtered_count" -gt 0 ]] || fail "expected some filtered candidates"
    echo "ok: restore --only filter"
}

test_restore_cap_on_total() {
    local dir="$TMPDIR/restore-cap"
    _restore_fixture "$dir"
    # Six other tasks are currently live under cctrl tmux owners.
    jq --arg host "$_SR_HOST_ID" '.rows += [range(1;7) | tostring | {provider:"claude", provider_task_id:("live-" + .), host_id:$host,
        origin:"cctrl", execution_runtime:"tmux", control_owner:"cctrl", lifecycle_state:"active", restore_strategy:"tmux",
        registered_by_cctrl:true, launched_by_cctrl:true, cwd:"/tmp", tmux_session:("TMUX--live" + .),
        action_capabilities:{tmux_attach:{supported:true}}}]' "$dir/catalogue.json" > "$dir/catalogue-live6.json"

    local out restore_count deferred_count
    # Contrast: without the cap pressure all four restorable tasks are eligible.
    out="$(CCTRL_RESTORE_MAX_ACTIVE=10 _restore_run "$dir" --dry-run --json)" || fail "uncapped dry-run failed: $out"
    [[ "$(jq '[.plan[] | select(.disposition=="restore")] | length' <<< "$out")" -eq 4 ]] \
        || fail "fixture invalid: expected 4 restore candidates without live sessions: $(jq -c '[.plan[]|{tmux_session,disposition,reason}]' <<< "$out")"

    out="$(SR_CATALOGUE="$dir/catalogue-live6.json" CCTRL_RESTORE_MAX_ACTIVE=8 _restore_run "$dir" --dry-run --json)" || fail "capped dry-run failed: $out"
    restore_count="$(jq '[.plan[] | select(.disposition=="restore")] | length' <<< "$out")"
    deferred_count="$(jq '[.plan[] | select(.reason=="deferred by CCTRL_RESTORE_MAX_ACTIVE")] | length' <<< "$out")"
    # 6 live + 2 restore = 8 = max. The remaining candidates are deferred.
    [[ "$restore_count" -eq 2 ]] || fail "expected exactly 2 restores with 6 live and max 8, got $restore_count"
    [[ "$deferred_count" -eq 2 ]] || fail "expected exactly 2 deferred candidates with cap at 8, got $deferred_count"

    SR_CATALOGUE="$dir/catalogue-live6.json" CCTRL_RESTORE_MAX_ACTIVE=8 _restore_run "$dir" --yes --quiet >/dev/null 2>&1 \
        || fail "capped restore failed"
    [[ "$(_restore_spawn_count "$dir")" -eq 2 ]] || fail "capped restore should spawn exactly 2: $(cat "$dir/launch.log")"
    echo "ok: restore cap on total managed count"
}

test_restore_null_conversation_id_skipped() {
    local dir="$TMPDIR/restore-nullconv"
    _restore_fixture "$dir"
    local out
    out="$(_restore_run "$dir" --dry-run --json)" || fail "restore dry-run failed: $out"
    # The nullconv task has no provider task id: it is reported and skipped.
    local skipped
    skipped="$(jq '[.plan[] | select(.tmux_session=="TMUX--nullconv" and .disposition=="insufficient-evidence" and .reason=="provider task id is missing")] | length' <<< "$out")"
    [[ "$skipped" -eq 1 ]] || fail "expected nullconv to be skipped, got $(jq -c '[.plan[]|select(.tmux_session=="TMUX--nullconv")]' <<< "$out")"
    local restored_null
    restored_null="$(jq '[.plan[] | select(.disposition=="restore" and .tmux_session=="TMUX--nullconv")] | length' <<< "$out")"
    [[ "$restored_null" -eq 0 ]] || fail "null conversation_id session should never be restored"
    _restore_run "$dir" --yes --quiet >/dev/null 2>&1 || fail "restore --yes failed"
    [[ "$(_restore_spawn_count "$dir")" -gt 0 ]] || fail "fixture invalid: nothing was spawned at all"
    ! grep -q "nullconv" "$dir/launch.log" || fail "nullconv should not appear in launch log"
    echo "ok: null conversation_id skipped"
}

test_restore_dry_run_spawns_nothing() {
    local dir="$TMPDIR/restore-dryrun"
    _restore_fixture "$dir"
    local out
    out="$(_restore_run "$dir" --dry-run --json)" || fail "restore dry-run failed: $out"
    [[ "$(jq '[.plan[] | select(.disposition=="restore")] | length' <<< "$out")" -gt 0 ]] \
        || fail "fixture invalid: the plan has no restore candidates"
    _restore_run "$dir" --dry-run --quiet >/dev/null 2>&1 || fail "restore --dry-run --quiet failed"
    local log_content
    log_content="$(cat "$dir/launch.log")"
    [[ -z "$log_content" ]] || fail "dry-run should not write to launch log, got: $log_content"
    echo "ok: dry-run spawns nothing"
}

test_restore_gate_stops_below_threshold() {
    local dir="$TMPDIR/restore-gate"
    _restore_fixture "$dir"
    local rc=0
    CCTRL_FAKE_MEM_FREE_PCT=5 _restore_run "$dir" --yes --quiet >/dev/null 2>&1 || rc=$?
    # Memory below CCTRL_MEM_FREE_MIN_PCT stops restore before any spawn (exit 1).
    [[ "$rc" -eq 1 ]] || fail "expected exit 1 when memory below threshold, got $rc"
    local log_content
    log_content="$(cat "$dir/launch.log")"
    [[ -z "$log_content" ]] || fail "gate should prevent all spawns, got: $log_content"
    echo "ok: resource gate stops below threshold"
}

test_restore_limit_caps_spawns() {
    local dir="$TMPDIR/restore-limit"
    _restore_fixture "$dir"
    _restore_run "$dir" --limit 2 --yes --quiet >/dev/null 2>&1 || fail "restore --limit 2 --yes failed"
    local spawn_count
    spawn_count="$(_restore_spawn_count "$dir")"
    [[ "$spawn_count" -le 2 ]] || fail "expected at most 2 spawns with --limit 2, got $spawn_count"
    [[ "$spawn_count" -eq 2 ]] || fail "expected --limit 2 to still spawn 2 of 4 candidates, got $spawn_count"
    echo "ok: --limit caps spawns"
}

test_restore_no_tty_no_yes_refused() {
    local dir="$TMPDIR/restore-notty"
    _restore_fixture "$dir"
    local rc=0
    _restore_run "$dir" < /dev/null >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 64 ]] || fail "expected exit 64 with no TTY and no --yes, got $rc"
    [[ ! -s "$dir/launch.log" ]] || fail "no-TTY restore without --yes spawned: $(cat "$dir/launch.log")"
    echo "ok: no TTY no --yes is refused"
}

test_restore_unknown_schema_refused() {
    local dir="$TMPDIR/restore-schema"
    _restore_fixture "$dir"
    cat > "$dir/snapshots/bad.json" <<'JSON'
{"schema_version": 42, "hostname": "test-host", "sessions": []}
JSON
    local out rc=0
    out="$(SR_FROM="$dir/snapshots/bad.json" _restore_run "$dir" --yes --json 2>&1)" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "expected exit 64 for unknown schema, got $rc"
    assert_contains "$out" "42"
    assert_contains "$out" "unsupported snapshot schema"
    [[ ! -s "$dir/launch.log" ]] || fail "unknown schema spawned"
    echo "ok: unknown schema_version refused"
}

test_restore_stale_snapshot_refused() {
    local dir="$TMPDIR/restore-stale"
    _restore_fixture "$dir"
    local old_iso
    old_iso="$(date -u -v-2d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "2 days ago" +"%Y-%m-%dT%H:%M:%SZ")"
    jq --arg old "$old_iso" '.generated_at = $old' "$dir/snapshots/latest.json" > "$dir/snapshots/old.json"
    local out rc=0
    out="$(SR_FROM="$dir/snapshots/old.json" CCTRL_RESTORE_MAX_SNAPSHOT_AGE=86400 _restore_run "$dir" --json 2>&1)" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "expected exit 64 for stale snapshot without --stale-ok, got $rc"
    assert_contains "$out" "snapshot is stale"
    # --stale-ok is the explicit override: the same snapshot then plans normally.
    rc=0
    out="$(SR_FROM="$dir/snapshots/old.json" CCTRL_RESTORE_MAX_SNAPSHOT_AGE=86400 _restore_run "$dir" --stale-ok --dry-run --json 2>&1)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "--stale-ok did not accept the stale snapshot (rc=$rc): $out"
    [[ ! -s "$dir/launch.log" ]] || fail "stale snapshot spawned"
    echo "ok: stale snapshot refused"
}

test_restore_host_mismatch_refused() {
    local dir="$TMPDIR/restore-host"
    _restore_fixture "$dir"
    jq '.hostname = "other-machine"' "$dir/snapshots/latest.json" > "$dir/snapshots/other.json"
    local out rc=0
    out="$(SR_FROM="$dir/snapshots/other.json" _restore_run "$dir" --yes --json 2>&1)" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "expected exit 64 for host mismatch, got $rc"
    assert_contains "$out" "other-machine"
    assert_contains "$out" "test-host"
    [[ ! -s "$dir/launch.log" ]] || fail "host-mismatched snapshot spawned"
    echo "ok: host mismatch refused"
}

test_restore_cap_fails_closed() {
    # The live inventory (which the active cap counts) comes from the real
    # task catalogue here, with tmux absent from PATH. Restore must fail
    # closed: evidence unavailable (69), nothing spawned.
    local dir="$TMPDIR/restore-capfail"
    _restore_fixture "$dir"
    rm -f "$dir/bin/tmux"
    [[ ! -x /usr/bin/tmux && ! -x /bin/tmux && ! -x /usr/sbin/tmux && ! -x /sbin/tmux ]] \
        || fail "fixture invalid: tmux is on the reduced PATH"
    command -v jq >/dev/null && ln -sf "$(command -v jq)" "$dir/bin/jq"
    local out rc=0
    out="$(SR_PATH="$(_test_path --sbin "$dir/bin")" SR_CATALOGUE="" _restore_run "$dir" --yes 2>&1)" || rc=$?
    [[ "$rc" -eq 69 ]] || fail "expected exit 69 when the live inventory is unavailable, got $rc: $out"
    assert_contains "$out" "unavailable"
    [[ ! -s "$dir/launch.log" ]] || fail "restore spawned without a live inventory: $(cat "$dir/launch.log")"
    echo "ok: cap fails closed"
}

test_restore_wave_pacing() {
    local dir="$TMPDIR/restore-wave"
    _restore_fixture "$dir"
    CCTRL_RESTORE_WAVE_SIZE=2 CCTRL_RESTORE_WAVE_PAUSE=0 _restore_run "$dir" --yes --quiet >/dev/null 2>&1 \
        || fail "waved restore failed"
    # With 4 restorable sessions and wave size 2, we should get 4 spawns across 2 waves
    local spawn_count
    spawn_count="$(_restore_spawn_count "$dir")"
    [[ "$spawn_count" -eq 4 ]] || fail "expected 4 spawns with wave pacing, got $spawn_count"
    echo "ok: wave pacing"
}

test_restore_already_live_skipped() {
    local dir="$TMPDIR/restore-live"
    _restore_fixture "$dir"
    # conv-aaa-111 currently has a live cctrl tmux owner.
    jq '(.rows[] | select(.provider_task_id=="conv-aaa-111") | .action_capabilities.tmux_attach) = {supported:true,reason:"available"}' \
        "$dir/catalogue.json" > "$dir/catalogue-live.json"

    local out
    out="$(SR_CATALOGUE="$dir/catalogue-live.json" _restore_run "$dir" --yes --json 2>&1)" || fail "restore failed: $out"
    local already
    already="$(jq '.counts["already-live"] // 0' <<< "$out")"
    [[ "$already" -ge 1 ]] || fail "expected at least 1 already-live, got $already"
    jq -e 'any(.plan[]; .provider_task_id=="conv-aaa-111" and .disposition=="already-live")' <<< "$out" >/dev/null \
        || fail "the live task was not reported already-live"
    [[ "$(_restore_spawn_count "$dir")" -gt 0 ]] || fail "fixture invalid: nothing was spawned at all"
    ! grep -q "conv-aaa-111" "$dir/launch.log" || fail "already-live conversation should not be spawned"
    echo "ok: already-live skipped"
}

test_launch_flags_for_prefers_metadata_profile() {
    # Plan 071 phase 6: launch_flags_for prefers the metadata record's own
    # `profile` field over re-parsing launch_command -- a default-sourced
    # profile has no `--profile` token in argv at all, so only the metadata
    # field can recover it for restore/realign. A pre-change record (no such
    # field) still falls back to the argv parse.
    local meta="$TMPDIR/p6-launch-flags-meta"
    mkdir -p "$meta"
    cat > "$meta/TMUX--default-sourced.json" <<'JSON'
{"tmux_session":"TMUX--default-sourced","name":"TMUX--default-sourced","launch_command":"cd /tmp && cctrl start --foreground --name TMUX--default-sourced","profile":"work"}
JSON
    cat > "$meta/TMUX--pre-change.json" <<'JSON'
{"tmux_session":"TMUX--pre-change","name":"TMUX--pre-change","launch_command":"cd /tmp && cctrl start --foreground --profile legacy-work --name TMUX--pre-change"}
JSON

    local out
    out="$(python3 "$ROOT/lib/snapshot_restore.py" launch-flags --metadata-dir "$meta" --name TMUX--default-sourced)"
    assert_contains "$out" '"profile": "work"'
    out="$(python3 "$ROOT/lib/snapshot_restore.py" launch-flags --metadata-dir "$meta" --name TMUX--pre-change)"
    assert_contains "$out" '"profile": "legacy-work"'
    echo "ok: launch_flags_for prefers metadata profile, falls back to argv"
}

test_restore_launch_config_replay() {
    local dir="$TMPDIR/restore-config"
    _restore_fixture "$dir"
    _restore_run "$dir" --yes --quiet >/dev/null 2>&1 || fail "restore failed"
    local log
    log="$(cat "$dir/launch.log")"
    # Check that launch_flags.model produces --model in the launch log
    assert_contains "$log" "--model claude-sonnet-4"
    assert_contains "$log" "--model claude-fable-5"
    assert_contains "$log" "--model claude-opus-4"
    # Check --no-bridge for bigone
    assert_contains "$log" "--no-bridge"
    # Check --peer and --permission-mode for cctrl session
    assert_contains "$log" "--peer fleet-mgr"
    assert_contains "$log" "--permission-mode bypassPermissions"
    # Check --profile for bigone
    assert_contains "$log" "--profile deep-work"
    # The Codex task comes back on the Codex agent
    assert_contains "$log" "--agent codex"
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
    # The current registry record for conv-bbb-222 is live under a different
    # tmux name than the snapshot captured (TMUX--record-holder vs
    # TMUX--homelab). The exact provider id joins them, so it is already-live.
    local dir="$TMPDIR/restore-recordjoin"
    _restore_fixture "$dir"
    jq '(.rows[] | select(.provider_task_id=="conv-bbb-222")) |= (.tmux_session = "TMUX--record-holder" | .action_capabilities.tmux_attach = {supported:true,reason:"available"})' \
        "$dir/catalogue.json" > "$dir/catalogue-join.json"

    local out
    out="$(SR_CATALOGUE="$dir/catalogue-join.json" _restore_run "$dir" --yes --json 2>&1)" || fail "restore failed: $out"
    local already
    already="$(jq '.counts["already-live"] // 0' <<< "$out")"
    [[ "$already" -ge 1 ]] || fail "expected at least 1 already-live from record join, got $already"
    jq -e 'any(.plan[]; .tmux_session=="TMUX--homelab" and .disposition=="already-live")' <<< "$out" >/dev/null \
        || fail "the record-joined task was not reported already-live"
    ! grep -q "conv-bbb-222" "$dir/launch.log" || fail "record-joined conversation should not be spawned"
    echo "ok: already-live record join"
}

test_restore_exit_codes() {
    local dir="$TMPDIR/restore-exit"
    _restore_fixture "$dir"

    # Exit 0: all-already-live (a snapshot with only one task, and it's already live)
    jq '.tasks = [.tasks[0] | .provider_task_id = "conv-only" | .resume_identity = "conv-only" | .tmux_session = "TMUX--only"]
        | .task_reference_count = 1' "$dir/snapshots/latest.json" > "$dir/snapshots/one.json"
    jq '.rows = [.rows[0] | .provider_task_id = "conv-only" | .tmux_session = "TMUX--live-only"
        | .action_capabilities.tmux_attach = {supported:true,reason:"available"}]' "$dir/catalogue.json" > "$dir/catalogue-one.json"

    local rc=0
    SR_FROM="$dir/snapshots/one.json" SR_CATALOGUE="$dir/catalogue-one.json" _restore_run "$dir" --yes --quiet >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected exit 0 for all-already-live, got $rc"
    [[ ! -s "$dir/launch.log" ]] || fail "all-already-live restore spawned: $(cat "$dir/launch.log")"

    # Exit 64: unreadable snapshot
    rc=0
    SR_FROM="/nonexistent/path.json" _restore_run "$dir" --yes >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 64 ]] || fail "expected exit 64 for unreadable snapshot, got $rc"

    echo "ok: exit codes"
}

# --- plan 068: ownership-aware snapshot / restore --------------------------

test_snapshot_tmux_row_selection() {
    # Plan 070 S1: when several registry rows claim one tmux name, the live
    # session's own provider id picks the row; catalogue order never does.
    local root="$TMPDIR/snapshot-tmux-select" host="0123456789abcdef0123456789abcdef"
    mkdir -p "$root/data" "$root/snapshots"
    printf '%s\n' "$host" > "$root/data/host-id"
    cat > "$root/process.json" <<'JSON'
{"schema_version":1,"status":"available","observed_at":"2026-09-24T10:00:00Z","source_cursor":"p","processes":[],"error":null}
JSON
    row() { # id tmux attach
        printf '{"provider":"claude","provider_task_id":"%s","host_id":"%s","origin":"cctrl","execution_runtime":"tmux","control_owner":"cctrl","lifecycle_state":"active","restore_strategy":"tmux","registered_by_cctrl":true,"launched_by_cctrl":true,"cwd":"/tmp/x","display_title":"%s","tmux_session":"%s","action_capabilities":{"tmux_attach":{"supported":%s}}}' \
            "$1" "$host" "$1" "$2" "$3"
    }
    # Stale record listed FIRST so the old setdefault() would have picked it.
    cat > "$root/catalogue.json" <<JSON
{"schema_version":2,"host_id":"$host","source_status":{"registry":"available","tmux":"available","codex_provider":"available"},"source_errors":[],"rows":[
 $(row stale-1 TMUX--pick false), $(row live-1 TMUX--pick false),
 $(row old-a TMUX--mismatch false), $(row old-b TMUX--noid false), $(row old-c TMUX--noid false),
 $(row gone-1 TMUX--gone false),
 $(row ended-1 TMUX--dead1 false | jq -c '.lifecycle_state="closed" | .control_owner="unknown" | .execution_runtime="unknown"'), $(row active-1 TMUX--dead1 false),
 $(row open-a TMUX--dead2 false), $(row open-b TMUX--dead2 false),
 $(row app-x TMUX--dead3 false | jq -c '.control_owner="app" | .execution_runtime="app-server" | .restore_strategy="provider-managed"'), $(row cctrl-x TMUX--dead3 false)
]}
JSON
    mkdir -p "$root/meta"
    printf '{"tmux_session":"TMUX--dead1","launch_command":"cd /tmp && cctrl start --foreground --name TMUX--dead1 --model opus --profile work"}\n' > "$root/meta/legacy-dead1.json"
    cat > "$root/sessions.json" <<'JSON'
[{"name":"TMUX--pick","agent":"claude","session_id":"live-1","dir":"/tmp/x"},
 {"name":"TMUX--mismatch","agent":"claude","session_id":"brand-new","dir":"/tmp/x","control_owner":"cctrl","execution_runtime":"tmux","lifecycle_state":"active","registered_by_cctrl":true,"launched_by_cctrl":true},
 {"name":"TMUX--noid","agent":"claude","dir":"/tmp/x"}]
JSON
    local out
    out="$(CCTRL_DATA_DIR="$root/data" CCTRL_HOST_ID_FILE="$root/data/host-id" CCTRL_SNAPSHOT_CATALOGUE_FILE="$root/catalogue.json" \
      CCTRL_SNAPSHOT_SESSIONS_FILE="$root/sessions.json" CCTRL_SNAPSHOT_PROCESS_FILE="$root/process.json" \
      CCTRL_SESSION_METADATA_DIR="$root/meta" \
      CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=0 "$ROOT/cctrl" session snapshot --dir "$root/snapshots" --json)" \
      || fail "snapshot with shared tmux names failed: $out"
    jq -e '[.tasks[] | select(.tmux_session=="TMUX--pick")] | length==1 and .[0].provider_task_id=="live-1"
           and .[0].resume_identity=="live-1" and .[0].shadowed_task_ids==["stale-1"]
           and .[0].recovery_action=="already-live"' <<< "$out" >/dev/null \
      || fail "snapshot did not pick the live row for a shared tmux name: $out"
    jq -e '[.tasks[] | select(.tmux_session=="TMUX--mismatch")] | length==1 and .[0].control_owner=="unknown"
           and .[0].recovery_action=="unknown" and (.[0].recovery_reason|startswith("ambiguous-tmux-claim"))
           and .[0].shadowed_task_ids==["old-a"]' <<< "$out" >/dev/null \
      || fail "a stale-only tmux claim was not marked ambiguous: $out"
    jq -e '[.tasks[] | select(.tmux_session=="TMUX--noid")] | length==1 and .[0].control_owner=="unknown"
           and .[0].shadowed_task_ids==["old-b","old-c"]' <<< "$out" >/dev/null \
      || fail "several claims without a live id were not marked ambiguous: $out"
    # A cctrl/tmux/active record whose pane is gone is not already-live.
    jq -e '[.tasks[] | select(.provider_task_id=="gone-1")] | length==1 and .[0].live==false
           and .[0].recovery_action=="insufficient-evidence"' <<< "$out" >/dev/null \
      || fail "a dead cctrl/tmux/active record was labelled already-live: $out"
    # Names that are not live (after a reboot): an ended record never hides the
    # open one, and several open claims are ambiguous, never catalogue order.
    jq -e '[.tasks[] | select(.tmux_session=="TMUX--dead1" and .provider_task_id=="active-1")] | length==1
           and .[0].control_owner=="cctrl" and .[0].recovery_action=="insufficient-evidence"' <<< "$out" >/dev/null \
      || fail "a closed record hid the open record of a dead tmux name: $out"
    jq -e 'any(.tasks[]; .provider_task_id=="ended-1" and .lifecycle_state=="closed")' <<< "$out" >/dev/null \
      || fail "the ended record of a dead tmux name was dropped"
    jq -e '[.tasks[] | select(.tmux_session=="TMUX--dead2")] | length==1 and .[0].provider_task_id=="open-a"
           and .[0].control_owner=="unknown" and (.[0].recovery_reason|startswith("ambiguous-tmux-claim"))
           and .[0].shadowed_task_ids==["open-b"]' <<< "$out" >/dev/null \
      || fail "several open claims on a dead tmux name were not ambiguous: $out"
    # Rows that are not live still carry their launch flags for replay.
    jq -e '[.tasks[] | select(.provider_task_id=="active-1")][0].launch_flags == {"model":"opus","profile":"work"}' <<< "$out" >/dev/null \
      || fail "a row that is not live lost its launch flags: $(jq -c '[.tasks[] | select(.provider_task_id=="active-1")][0].launch_flags' <<< "$out")"
    # An app-owned record does not claim a terminal, so it never makes the cctrl
    # record on the same dead name ambiguous.
    jq -e '[.tasks[] | select(.provider_task_id=="cctrl-x")][0] | .control_owner=="cctrl" and (.recovery_reason|startswith("ambiguous")|not)' <<< "$out" >/dev/null \
      || fail "an app-owned record made a cctrl record ambiguous: $out"
    echo "ok: snapshot picks the live row per tmux name, never lets catalogue order decide a dead name, and only labels live rows already-live"
}

test_snapshot_size_controls() {
    # Plan 070 S2: bounded labels, discovery-only rows summarised, history only
    # on change, retention caps, and a size guard that preserves last-known-good.
    local root="$TMPDIR/snapshot-size" host="0123456789abcdef0123456789abcdef" out rc big
    mkdir -p "$root/data" "$root/snapshots"
    printf '%s\n' "$host" > "$root/data/host-id"
    cat > "$root/process.json" <<'JSON'
{"schema_version":1,"status":"available","observed_at":"2026-09-24T10:00:00Z","source_cursor":"p","processes":[],"error":null}
JSON
    big="$(python3 -c 'print("x" * 5000)')"
    write_catalogue() { # $1 = purpose of the live session
        cat > "$root/catalogue.json" <<JSON
{"schema_version":2,"host_id":"$host","source_status":{"registry":"available","tmux":"available","codex_provider":"available"},"source_errors":[],"rows":[
 {"provider":"claude","provider_task_id":"live-1","host_id":"$host","origin":"cctrl","execution_runtime":"tmux","control_owner":"cctrl","lifecycle_state":"active","restore_strategy":"tmux","registered_by_cctrl":true,"launched_by_cctrl":true,"cwd":"/tmp/x","display_title":"Live","tmux_session":"TMUX--live","action_capabilities":{"tmux_attach":{"supported":true}}},
 {"provider":"codex","provider_task_id":"app-1","host_id":"$host","origin":"codex-app","execution_runtime":"app-server","control_owner":"app","lifecycle_state":"active","restore_strategy":"provider-managed","registered_by_cctrl":false,"launched_by_cctrl":false,"cwd":"/tmp/a","display_title":"$big","tmux_session":null},
 {"provider":"codex","provider_task_id":"seen-1","host_id":"$host","origin":"unknown","execution_runtime":"unknown","control_owner":"unknown","lifecycle_state":"unknown","restore_strategy":null,"registered_by_cctrl":false,"launched_by_cctrl":false,"cwd":"/tmp/s","display_title":"$big","tmux_session":null},
 {"provider":"codex","provider_task_id":"old-1","host_id":"$host","origin":"unknown","execution_runtime":"unknown","control_owner":"unknown","lifecycle_state":"archived","restore_strategy":null,"registered_by_cctrl":false,"launched_by_cctrl":false,"cwd":"/tmp/o","display_title":"old","tmux_session":null}
]}
JSON
        printf '[{"name":"TMUX--live","agent":"claude","session_id":"live-1","dir":"/tmp/x","purpose":"%s","last_active":"%s"}]\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$root/sessions.json"
    }
    snap() {
        CCTRL_DATA_DIR="$root/data" CCTRL_HOST_ID_FILE="$root/data/host-id" CCTRL_SNAPSHOT_CATALOGUE_FILE="$root/catalogue.json" \
          CCTRL_SNAPSHOT_SESSIONS_FILE="$root/sessions.json" CCTRL_SNAPSHOT_PROCESS_FILE="$root/process.json" \
          CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=0 "$ROOT/cctrl" session snapshot --dir "$root/snapshots" "$@"
    }
    history_count() { find "$root/snapshots" -name '20*.json' -type f | wc -l | tr -d ' '; }

    write_catalogue "first"
    out="$(snap --json)" || fail "size-controlled snapshot failed: $out"
    jq -e '
      .task_reference_count==2 and .catalogue_task_count==4 and
      .omitted_task_references=={"count":2,"by_provider_state":{"codex:archived":1,"codex:unknown":1}} and
      ([.tasks[] | select(.provider_task_id=="app-1")][0] | (.display_label|length)==200 and (.display_label_sha256|test("^[0-9a-f]{64}$")))' \
      <<< "$out" >/dev/null || fail "snapshot rows were not slimmed: $(jq -c '{task_reference_count,omitted_task_references}' <<< "$out")"
    [[ "$(jq -r '.tasks[] | select(.provider_task_id=="app-1") | .display_label_sha256' <<< "$out")" \
        == "$(printf '%s' "$big" | shasum -a 256 | awk '{print $1}')" ]] || fail "label hash does not identify the full title"
    [[ "$(history_count)" == 1 ]] || fail "first snapshot did not write one history file"

    # Unchanged restore-relevant content (only last_active moved): latest is
    # refreshed, no new history file.
    local first_generated; first_generated="$(jq -r '.generated_at' "$root/snapshots/latest.json")"
    sleep 1; write_catalogue "first"
    out="$(snap)" || fail "unchanged snapshot failed"
    assert_contains "$out" "unchanged; no history file"
    [[ "$(history_count)" == 1 ]] || fail "unchanged snapshot wrote a history file"
    [[ "$(jq -r '.generated_at' "$root/snapshots/latest.json")" != "$first_generated" ]] || fail "latest.json was not refreshed"

    # A restore-relevant change writes history again.
    sleep 1; write_catalogue "second"
    snap --quiet || fail "changed snapshot failed"
    [[ "$(history_count)" == 2 ]] || fail "changed snapshot did not write history"

    # Size guard: over the cap exits 69 and preserves latest/history.
    local latest_hash; latest_hash="$(shasum "$root/snapshots/latest.json" | awk '{print $1}')"
    sleep 1; write_catalogue "third"
    rc=0; CCTRL_SNAPSHOT_MAX_BYTES=100 snap --quiet 2>/dev/null || rc=$?
    [[ "$rc" -eq 69 ]] || fail "oversized snapshot did not exit 69 (rc=$rc)"
    [[ "$latest_hash" == "$(shasum "$root/snapshots/latest.json" | awk '{print $1}')" ]] || fail "oversized snapshot replaced latest"
    [[ "$(history_count)" == 2 ]] || fail "oversized snapshot wrote history"

    # Retention caps: newest-first window by count, then by bytes; the newest
    # history file and latest.json always survive.
    local caps="$root/caps" i
    mkdir -p "$caps"; printf '{}' > "$caps/latest.json"
    for i in 1 2 3 4 5; do printf '%0100d' 0 > "$caps/2026092${i}T000000Z.json"; done
    CCTRL_SNAPSHOT_HISTORY_MAX=3 cctrl_source_eval '_snapshot_retention_prune "$1"' "$caps"
    [[ "$(ls "$caps" | tr '\n' ' ')" == "20260923T000000Z.json 20260924T000000Z.json 20260925T000000Z.json latest.json " ]] \
        || fail "count cap kept the wrong files: $(ls "$caps" | tr '\n' ' ')"
    CCTRL_SNAPSHOT_HISTORY_MAX_BYTES=150 cctrl_source_eval '_snapshot_retention_prune "$1"' "$caps"
    [[ "$(ls "$caps" | tr '\n' ' ')" == "20260925T000000Z.json latest.json " ]] \
        || fail "byte cap kept the wrong files: $(ls "$caps" | tr '\n' ' ')"
    CCTRL_SNAPSHOT_HISTORY_MAX_BYTES=10 cctrl_source_eval '_snapshot_retention_prune "$1"' "$caps"
    [[ -f "$caps/20260925T000000Z.json" && -f "$caps/latest.json" ]] || fail "caps removed the newest history file or latest.json"
    # Age pruning never removes the newest history file, however old it is:
    # with history written only on change it is the last known state.
    local aged="$root/aged"
    mkdir -p "$aged"
    printf '{}' > "$aged/20260101T000000Z.json"; printf '{}' > "$aged/20260102T000000Z.json"
    touch -t 202601010000 "$aged/20260101T000000Z.json" "$aged/20260102T000000Z.json"
    cctrl_source_eval '_snapshot_retention_prune "$1"' "$aged"
    [[ "$(ls "$aged" | tr '\n' ' ')" == "20260102T000000Z.json " ]] \
        || fail "age pruning removed the newest history file or kept an old one: $(ls "$aged" | tr '\n' ' ')"
    echo "ok: snapshots are slim, write history only on change, cap retention, and refuse oversized captures"
}

test_snapshot_reboot_keeps_live_latest() {
    # Plan 070 D7: after a power cycle no tmux session is live but registry
    # rows survive. That capture must not replace a latest.json that had live
    # sessions (restore reads latest by default); it goes to history only.
    local root="$TMPDIR/snapshot-reboot" host="0123456789abcdef0123456789abcdef" out good
    mkdir -p "$root/data" "$root/snapshots"
    printf '%s\n' "$host" > "$root/data/host-id"
    cat > "$root/process.json" <<'JSON'
{"schema_version":1,"status":"available","observed_at":"2026-09-27T10:00:00Z","source_cursor":"p","processes":[],"error":null}
JSON
    write_state() { # $1 = tmux_attach supported (true = live, false = rebooted)
        cat > "$root/catalogue.json" <<JSON
{"schema_version":2,"host_id":"$host","source_status":{"registry":"available","tmux":"available","codex_provider":"available"},"source_errors":[],"rows":[
 {"provider":"claude","provider_task_id":"live-1","host_id":"$host","origin":"cctrl","execution_runtime":"tmux","control_owner":"cctrl","lifecycle_state":"active","restore_strategy":"tmux","registered_by_cctrl":true,"launched_by_cctrl":true,"cwd":"/tmp/x","display_title":"Live","tmux_session":"TMUX--live","action_capabilities":{"tmux_attach":{"supported":$1}}}
]}
JSON
        if [[ "$1" == true ]]; then
            printf '[{"name":"TMUX--live","agent":"claude","session_id":"live-1","dir":"/tmp/x"}]\n' > "$root/sessions.json"
        else
            printf '[]\n' > "$root/sessions.json"
        fi
    }
    snap() {
        CCTRL_DATA_DIR="$root/data" CCTRL_HOST_ID_FILE="$root/data/host-id" CCTRL_SNAPSHOT_CATALOGUE_FILE="$root/catalogue.json" \
          CCTRL_SNAPSHOT_SESSIONS_FILE="$root/sessions.json" CCTRL_SNAPSHOT_PROCESS_FILE="$root/process.json" \
          CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=0 "$ROOT/cctrl" session snapshot --dir "$root/snapshots" "$@"
    }
    history_count() { find "$root/snapshots" -name '20*.json' -type f | wc -l | tr -d ' '; }

    write_state true
    snap --quiet || fail "live snapshot failed"
    good="$(shasum "$root/snapshots/latest.json" | awk '{print $1}')"
    jq -e '[.tasks[] | select(.live == true)] | length == 1' "$root/snapshots/latest.json" >/dev/null || fail "fixture latest has no live session"

    sleep 1; write_state false
    out="$(snap)" || fail "post-reboot snapshot failed: $out"
    assert_contains "$out" "keeping latest.json with 1 live session(s)"
    [[ "$good" == "$(shasum "$root/snapshots/latest.json" | awk '{print $1}')" ]] || fail "post-reboot capture replaced the good latest.json"
    [[ "$(history_count)" == 2 ]] || fail "post-reboot capture was not kept in history"
    # Repeated post-reboot captures still leave latest alone and add no history.
    sleep 1; snap --quiet || fail "second post-reboot snapshot failed"
    [[ "$good" == "$(shasum "$root/snapshots/latest.json" | awk '{print $1}')" ]] || fail "a later post-reboot capture replaced latest.json"
    [[ "$(history_count)" == 2 ]] || fail "an unchanged post-reboot capture wrote history"

    # --allow-empty is the explicit override.
    sleep 1; snap --quiet --allow-empty || fail "--allow-empty snapshot failed"
    [[ "$good" != "$(shasum "$root/snapshots/latest.json" | awk '{print $1}')" ]] || fail "--allow-empty did not replace latest.json"

    # Once sessions are live again (e.g. restored), latest moves on normally.
    sleep 1; write_state true; snap --quiet || fail "live-again snapshot failed"
    jq -e '[.tasks[] | select(.live == true)] | length == 1' "$root/snapshots/latest.json" >/dev/null || fail "latest did not return to the live capture"
    echo "ok: a capture with no live sessions never replaces a latest.json that had them"
}

test_snapshot_ownership_policy() {
    local root="$TMPDIR/snapshot-ownership" data="$TMPDIR/snapshot-ownership/data"
    local snapshots="$TMPDIR/snapshot-ownership/snapshots" host="0123456789abcdef0123456789abcdef"
    local catalogue="$TMPDIR/snapshot-ownership/catalogue.json" sessions="$TMPDIR/snapshot-ownership/sessions.json"
    local process="$TMPDIR/snapshot-ownership/process.json" codex="$TMPDIR/snapshot-ownership/codex.json"
    local launch_log="$TMPDIR/snapshot-ownership/launch.log" before after out rc=0
    mkdir -p "$root" "$data" "$snapshots"
    printf '%s\n' "$host" > "$data/host-id"
    cat > "$process" <<'JSON'
{"schema_version":1,"status":"available","observed_at":"2026-09-17T10:00:00Z","source_cursor":"process-1","processes":[],"error":null}
JSON
    cat > "$catalogue" <<JSON
{"schema_version":2,"host_id":"$host","source_status":{"registry":"available","tmux":"available","codex_provider":"available"},"source_errors":[],"rows":[
 {"task_key":"provider:claude:$host:claude-1","provider":"claude","provider_task_id":"claude-1","host_id":"$host","origin":"cctrl","execution_runtime":"tmux","control_owner":"cctrl","lifecycle_state":"active","restore_strategy":"tmux","registered_by_cctrl":true,"launched_by_cctrl":true,"registration_provenance":[{"source":"registry"}],"launch_provenance":[{"source":"launch-receipt"}],"lineage":{"forked_from_id":null,"parent_thread_id":null,"derived_root_id":null,"derived_root_basis":null},"ownership_evidence":[],"cwd":"/tmp/claude","display_title":"Claude owned","tmux_session":"TMUX--claude","action_capabilities":{"tmux_attach":{"supported":true,"reason":"available"}}},
 {"task_key":"provider:codex:$host:app-1","provider":"codex","provider_task_id":"app-1","host_id":"$host","origin":"codex-app","execution_runtime":"app-server","control_owner":"app","lifecycle_state":"active","restore_strategy":"provider-managed","registered_by_cctrl":false,"launched_by_cctrl":false,"registration_provenance":[],"launch_provenance":[],"lineage":{"forked_from_id":null,"parent_thread_id":null,"derived_root_id":null,"derived_root_basis":null},"ownership_evidence":[],"cwd":"/tmp/app","display_title":"Native app","tmux_session":null,"action_capabilities":{"tmux_attach":{"supported":false,"reason":"no-live-cctrl-tmux-owner"}}},
 {"task_key":"provider:codex:$host:released-1","provider":"codex","provider_task_id":"released-1","host_id":"$host","origin":"cctrl","execution_runtime":"app-server","control_owner":"app","lifecycle_state":"released","restore_strategy":"provider-managed","registered_by_cctrl":true,"launched_by_cctrl":true,"registration_provenance":[{"source":"registry"}],"launch_provenance":[{"source":"launch-receipt"}],"lineage":{"forked_from_id":null,"parent_thread_id":null,"derived_root_id":null,"derived_root_basis":null},"ownership_evidence":[],"cwd":"/tmp/released","display_title":"Released","tmux_session":null,"action_capabilities":{"tmux_attach":{"supported":false,"reason":"no-live-cctrl-tmux-owner"}}},
 {"task_key":"provider:codex:$host:unknown-1","provider":"codex","provider_task_id":"unknown-1","host_id":"$host","origin":"unknown","execution_runtime":"unknown","control_owner":"unknown","lifecycle_state":"unknown","restore_strategy":null,"registered_by_cctrl":false,"launched_by_cctrl":false,"registration_provenance":[],"launch_provenance":[],"lineage":{"forked_from_id":null,"parent_thread_id":null,"derived_root_id":null,"derived_root_basis":null},"ownership_evidence":[],"cwd":"/tmp/unknown","display_title":"Observed only","tmux_session":null,"action_capabilities":{"tmux_attach":{"supported":false,"reason":"unknown"}}}
]}
JSON
    cat > "$sessions" <<'JSON'
[{"name":"TMUX--claude","agent":"claude","session_id":"claude-1","dir":"/tmp/claude","purpose":"restore me","display_label":"Claude owned","last_active":"2026-09-17T09:59:00Z","registered_by_cctrl":true,"launched_by_cctrl":true,"origin":"cctrl","execution_runtime":"tmux","control_owner":"cctrl","lifecycle_state":"active","restore_strategy":"tmux"}]
JSON
    cat > "$codex" <<'JSON'
{"schema_version":1,"kind":"codex_reconcile_result_v1","records":[],"errors":[]}
JSON

    before="$(live_data_manifest)"
    out="$(CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_SNAPSHOT_CATALOGUE_FILE="$catalogue" \
      CCTRL_SNAPSHOT_SESSIONS_FILE="$sessions" CCTRL_SNAPSHOT_PROCESS_FILE="$process" \
      CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=0 "$ROOT/cctrl" session snapshot --dir "$snapshots" --json)"
    jq -e --arg host "$host" '
      .schema_version==2 and .host_id==$host and .task_reference_count==3 and .restore_candidate_count==1 and
      .catalogue_task_count==4 and .omitted_task_references=={"count":1,"by_provider_state":{"codex:unknown":1}} and
      (.content_digest|test("^[0-9a-f]{64}$")) and ([.tasks[] | select(.provider_task_id=="unknown-1")] | length)==0 and
      .capture_quality.status=="complete" and
      ([.tasks[] | select(.provider_task_id=="app-1" and .recovery_action=="provider-managed")] | length)==1 and
      ([.tasks[] | select(.provider_task_id=="released-1" and .restore_strategy=="provider-managed")] | length)==1 and
      ([.tasks[] | select(.provider_task_id=="claude-1" and .restore_strategy=="tmux-resume" and .resume_identity_kind=="claude-session-id")] | length)==1' \
      <<< "$out" >/dev/null || fail "schema-v2 ownership snapshot is wrong: $out"
    [[ "$(shasum "$snapshots/latest.json" | awk '{print $1}')" == "$(find "$snapshots" -name '20*.json' -type f -exec shasum {} \; | head -1 | awk '{print $1}')" ]] \
      || fail "latest/history snapshot bytes differ"

    # A mandatory source failure is degraded/nonzero and preserves both files;
    # --allow-empty cannot weaken this quality gate.
    local latest_hash history_count degraded="$TMPDIR/snapshot-ownership/degraded.json"
    latest_hash="$(shasum "$snapshots/latest.json" | awk '{print $1}')"; history_count="$(find "$snapshots" -name '20*.json' | wc -l | tr -d ' ')"
    jq '.source_status.tmux="unavailable"' "$catalogue" > "$degraded"
    rc=0
    CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_SNAPSHOT_CATALOGUE_FILE="$degraded" \
      CCTRL_SNAPSHOT_SESSIONS_FILE="$sessions" CCTRL_SNAPSHOT_PROCESS_FILE="$process" \
      "$ROOT/cctrl" session snapshot --dir "$snapshots" --allow-empty --quiet >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 69 ]] || fail "degraded snapshot did not exit 69 (rc=$rc)"
    [[ "$latest_hash" == "$(shasum "$snapshots/latest.json" | awk '{print $1}')" ]] || fail "degraded capture replaced latest"
    [[ "$history_count" == "$(find "$snapshots" -name '20*.json' | wc -l | tr -d ' ')" ]] || fail "degraded capture wrote history"

    # Partial mandatory-source enumeration is also degraded, even when the
    # aggregate source_status remains "available". It must preserve the same
    # last-known-good files rather than silently replacing them with omissions.
    jq '.source_errors += [{"source":"registry","status":"partial","error":"invalid-json:broken.json"}]' "$catalogue" > "$degraded"
    rc=0
    CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_SNAPSHOT_CATALOGUE_FILE="$degraded" \
      CCTRL_SNAPSHOT_SESSIONS_FILE="$sessions" CCTRL_SNAPSHOT_PROCESS_FILE="$process" \
      "$ROOT/cctrl" session snapshot --dir "$snapshots" --quiet >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 69 ]] || fail "partial registry enumeration did not exit 69 (rc=$rc)"
    [[ "$latest_hash" == "$(shasum "$snapshots/latest.json" | awk '{print $1}')" ]] || fail "partial enumeration replaced latest"
    [[ "$history_count" == "$(find "$snapshots" -name '20*.json' | wc -l | tr -d ' ')" ]] || fail "partial enumeration wrote history"

    # Reboot evidence: the exact row still exists but no live tmux capability.
    local current="$TMPDIR/snapshot-ownership/current.json"
    jq '(.rows[] | select(.provider_task_id=="claude-1") | .action_capabilities.tmux_attach)={supported:false,reason:"no-live-cctrl-tmux-owner"}' "$catalogue" > "$current"
    out="$(CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_RESTORE_CATALOGUE_FILE="$current" \
      CCTRL_RESTORE_PROCESS_FILE="$process" CCTRL_RESTORE_CODEX_EVIDENCE_FILE="$codex" CCTRL_RESTORE_LAUNCH_LOG="$launch_log" \
      "$ROOT/cctrl" session restore --from "$snapshots/latest.json" --dry-run --json)"
    jq -e '
      ([.plan[] | select(.provider_task_id=="claude-1" and .disposition=="restore" and .action_capabilities.restore=={supported:true,reason:"tmux-resume"})] | length)==1 and
      ([.plan[] | select(.provider_task_id=="app-1" and .disposition=="provider-managed")] | length)==1 and
      ([.plan[] | select(.provider_task_id=="released-1" and .disposition=="provider-managed")] | length)==1 and
      ([.plan[] | select(.provider_task_id=="unknown-1")] | length)==0' <<< "$out" >/dev/null \
      || fail "ownership-aware restore plan is wrong: $out"
    : > "$launch_log"
    CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_RESTORE_CATALOGUE_FILE="$current" \
      CCTRL_RESTORE_PROCESS_FILE="$process" CCTRL_RESTORE_CODEX_EVIDENCE_FILE="$codex" CCTRL_RESTORE_LAUNCH_LOG="$launch_log" \
      CCTRL_FAKE_MEM_FREE_PCT=80 CCTRL_FAKE_SWAP_MB=0 CCTRL_RESTORE_WAVE_PAUSE=0 \
      "$ROOT/cctrl" session restore --from "$snapshots/latest.json" --yes --quiet >/dev/null
    [[ "$(wc -l < "$launch_log" | tr -d ' ')" == 1 ]] || fail "restore executed more than the exact eligible row"
    assert_contains "$(cat "$launch_log")" "claude-1"
    assert_not_contains "$(cat "$launch_log")" "app-1"
    assert_not_contains "$(cat "$launch_log")" "released-1"

    # --only is a strict demotion-only boundary. A non-matching filter must not
    # leave the otherwise eligible row executable.
    : > "$launch_log"
    out="$(CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_RESTORE_CATALOGUE_FILE="$current" \
      CCTRL_RESTORE_PROCESS_FILE="$process" CCTRL_RESTORE_CODEX_EVIDENCE_FILE="$codex" CCTRL_RESTORE_LAUNCH_LOG="$launch_log" \
      "$ROOT/cctrl" session restore --from "$snapshots/latest.json" --only definitely-not-claude --dry-run --json)"
    jq -e 'any(.plan[]; .provider_task_id=="claude-1" and .disposition=="insufficient-evidence" and .reason=="filtered by --only")' <<< "$out" >/dev/null \
      || fail "--only did not demote the non-matching restore candidate: $out"
    CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_RESTORE_CATALOGUE_FILE="$current" \
      CCTRL_RESTORE_PROCESS_FILE="$process" CCTRL_RESTORE_CODEX_EVIDENCE_FILE="$codex" CCTRL_RESTORE_LAUNCH_LOG="$launch_log" \
      CCTRL_FAKE_MEM_FREE_PCT=80 CCTRL_FAKE_SWAP_MB=0 "$ROOT/cctrl" session restore --from "$snapshots/latest.json" \
      --only definitely-not-claude --yes --quiet >/dev/null
    [[ ! -s "$launch_log" ]] || fail "--only launched a non-matching restore candidate"

    # Resume authority is bound to the exact provider identity and its
    # provider-specific kind, never merely to a nonempty resume token.
    local mismatched_resume="$TMPDIR/snapshot-ownership/mismatched-resume.json"
    jq '.tasks=[(.tasks[]|select(.provider_task_id=="claude-1")|.resume_identity="other-task"),(.tasks[]|select(.provider_task_id=="claude-1")|.resume_identity_kind="codex-thread-id")]|.task_reference_count=2' \
      "$snapshots/latest.json" > "$mismatched_resume"
    out="$(CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_RESTORE_CATALOGUE_FILE="$current" \
      CCTRL_RESTORE_PROCESS_FILE="$process" CCTRL_RESTORE_CODEX_EVIDENCE_FILE="$codex" \
      "$ROOT/cctrl" session restore --from "$mismatched_resume" --dry-run --json)"
    jq -e '([.plan[] | select(.provider_task_id=="claude-1" and .disposition=="insufficient-evidence" and .action_capabilities.restore.supported==false)] | length)==2' <<< "$out" >/dev/null \
      || fail "mismatched resume identity/kind was granted restore authority: $out"

    # Live wins over restore, absent evidence exits 69, duplicates conflict/75.
    out="$(CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_RESTORE_CATALOGUE_FILE="$catalogue" \
      CCTRL_RESTORE_PROCESS_FILE="$process" CCTRL_RESTORE_CODEX_EVIDENCE_FILE="$codex" \
      "$ROOT/cctrl" session restore --from "$snapshots/latest.json" --dry-run --json)"
    jq -e 'any(.plan[]; .provider_task_id=="claude-1" and .disposition=="already-live")' <<< "$out" >/dev/null || fail "live row did not override restore"
    local absent="$TMPDIR/snapshot-ownership/absent.json" duplicate="$TMPDIR/snapshot-ownership/duplicate.json"
    jq 'del(.rows[] | select(.provider_task_id=="claude-1"))' "$current" > "$absent"
    rc=0; out="$(CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_RESTORE_CATALOGUE_FILE="$absent" \
      CCTRL_RESTORE_PROCESS_FILE="$process" CCTRL_RESTORE_CODEX_EVIDENCE_FILE="$codex" \
      "$ROOT/cctrl" session restore --from "$snapshots/latest.json" --dry-run --json 2>/dev/null)" || rc=$?
    [[ "$rc" -eq 69 ]] || fail "absent live identity did not exit 69 (rc=$rc)"
    jq -e 'any(.plan[]; .provider_task_id=="claude-1" and .disposition=="insufficient-evidence")' <<< "$out" >/dev/null || fail "absent identity was not explained"
    jq '.rows += [.rows[] | select(.provider_task_id=="claude-1")]' "$current" > "$duplicate"
    rc=0; out="$(CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_RESTORE_CATALOGUE_FILE="$duplicate" \
      CCTRL_RESTORE_PROCESS_FILE="$process" CCTRL_RESTORE_CODEX_EVIDENCE_FILE="$codex" \
      "$ROOT/cctrl" session restore --from "$snapshots/latest.json" --dry-run --json 2>/dev/null)" || rc=$?
    [[ "$rc" -eq 75 ]] || fail "duplicate live identity did not exit 75 (rc=$rc)"
    jq -e 'any(.plan[]; .provider_task_id=="claude-1" and .disposition=="conflict")' <<< "$out" >/dev/null || fail "duplicate identity was not a conflict"

    local partial_current="$TMPDIR/snapshot-ownership/partial-current.json"
    jq '.source_errors += [{"source":"registry","status":"partial","error":"invalid-json:broken.json"}]' "$current" > "$partial_current"
    rc=0; out="$(CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_RESTORE_CATALOGUE_FILE="$partial_current" \
      CCTRL_RESTORE_PROCESS_FILE="$process" CCTRL_RESTORE_CODEX_EVIDENCE_FILE="$codex" \
      "$ROOT/cctrl" session restore --from "$snapshots/latest.json" --dry-run --json 2>/dev/null)" || rc=$?
    [[ "$rc" -eq 69 ]] || fail "partial restore-time registry evidence did not exit 69 (rc=$rc)"
    jq -e 'any(.plan[]; .provider_task_id=="claude-1" and .disposition=="insufficient-evidence" and .action_capabilities.restore.supported==false)' <<< "$out" >/dev/null \
      || fail "partial restore-time registry evidence left restore executable: $out"

    # A stale pre-handoff Codex snapshot is overridden by current App Server ownership.
    local handoff_snap="$TMPDIR/snapshot-ownership/handoff.json" handoff_catalog="$TMPDIR/snapshot-ownership/handoff-catalog.json" handoff_evidence="$TMPDIR/snapshot-ownership/handoff-evidence.json"
    jq --arg host "$host" '.tasks=[(.tasks[]|select(.provider_task_id=="claude-1")|.provider="codex"|.provider_task_id="handoff-1"|.resume_identity_kind="codex-thread-id"|.resume_identity="handoff-1")]|.task_reference_count=1|.restore_candidate_count=1' "$snapshots/latest.json" > "$handoff_snap"
    jq --arg host "$host" '.rows=[(.rows[]|select(.provider_task_id=="claude-1")|.provider="codex"|.provider_task_id="handoff-1"|.task_key=("provider:codex:"+$host+":handoff-1"))]' "$current" > "$handoff_catalog"
    cat > "$handoff_evidence" <<JSON
{"schema_version":1,"kind":"codex_reconcile_result_v1","records":[{"provider_task_id":"handoff-1","host_id":"$host","sources":{"registry":{"status":"available","source_cursor":"r1","error":null},"app_server":{"status":"claimed","source_cursor":"a1","error":null},"tmux":{"status":"confirmed-absence","source_cursor":"t1","error":null},"process_table":{"status":"confirmed-absence","source_cursor":"p1","error":null}},"chosen_outcome":{"control_owner":"app","execution_runtime":"app-server","lifecycle_state":"active","restore_strategy":"provider-managed"}}],"errors":[]}
JSON
    out="$(CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_RESTORE_CATALOGUE_FILE="$handoff_catalog" \
      CCTRL_RESTORE_PROCESS_FILE="$process" CCTRL_RESTORE_CODEX_EVIDENCE_FILE="$handoff_evidence" \
      "$ROOT/cctrl" session restore --from "$handoff_snap" --dry-run --json)"
    jq -e 'any(.plan[]; .provider_task_id=="handoff-1" and .disposition=="provider-managed" and .action_capabilities.restore.supported==false)' <<< "$out" >/dev/null \
      || fail "post-handoff app ownership did not veto stale restore"

    # Codex is restorable from an unknown current owner only when exact-host
    # evidence proves both App Server and tmux absence. Ambiguous or terminal
    # current evidence must close the capability.
    local codex_restore_snap="$TMPDIR/snapshot-ownership/codex-restore.json"
    local codex_restore_catalog="$TMPDIR/snapshot-ownership/codex-restore-catalog.json"
    local codex_absent="$TMPDIR/snapshot-ownership/codex-absent.json"
    local codex_ambiguous="$TMPDIR/snapshot-ownership/codex-ambiguous.json"
    local codex_archived="$TMPDIR/snapshot-ownership/codex-archived.json"
    jq --arg host "$host" '.tasks=[(.tasks[]|select(.provider_task_id=="claude-1")|.provider="codex"|.agent="codex"|.provider_task_id="codex-restore-1"|.resume_identity_kind="codex-thread-id"|.resume_identity="codex-restore-1")]|.task_reference_count=1|.restore_candidate_count=1' \
      "$snapshots/latest.json" > "$codex_restore_snap"
    jq --arg host "$host" '.rows=[(.rows[]|select(.provider_task_id=="claude-1")|.provider="codex"|.provider_task_id="codex-restore-1"|.task_key=("provider:codex:"+$host+":codex-restore-1")|.control_owner="unknown"|.execution_runtime="unknown"|.lifecycle_state="inactive"|.action_capabilities.tmux_attach={supported:false,reason:"no-live-cctrl-tmux-owner"})]' \
      "$current" > "$codex_restore_catalog"
    cat > "$codex_absent" <<JSON
{"schema_version":1,"kind":"codex_reconcile_result_v1","records":[{"provider_task_id":"codex-restore-1","host_id":"$host","sources":{"registry":{"status":"available","source_cursor":"r2","error":null},"app_server":{"status":"confirmed-absence","source_cursor":"a2","error":null},"tmux":{"status":"confirmed-absence","source_cursor":"t2","error":null},"process_table":{"status":"confirmed-absence","source_cursor":"p2","error":null}},"chosen_outcome":{"control_owner":"unknown","execution_runtime":"unknown","lifecycle_state":"inactive","restore_strategy":"tmux-resume"}}],"errors":[]}
JSON
    out="$(CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_RESTORE_CATALOGUE_FILE="$codex_restore_catalog" \
      CCTRL_RESTORE_PROCESS_FILE="$process" CCTRL_RESTORE_CODEX_EVIDENCE_FILE="$codex_absent" \
      "$ROOT/cctrl" session restore --from "$codex_restore_snap" --dry-run --json)"
    jq -e 'any(.plan[]; .provider_task_id=="codex-restore-1" and .disposition=="restore" and .action_capabilities.restore.supported==true)' <<< "$out" >/dev/null \
      || fail "authoritative Codex owner absence did not permit exact restore: $out"

    jq '.records[0].sources.app_server.status="ambiguous"' "$codex_absent" > "$codex_ambiguous"
    rc=0; out="$(CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_RESTORE_CATALOGUE_FILE="$codex_restore_catalog" \
      CCTRL_RESTORE_PROCESS_FILE="$process" CCTRL_RESTORE_CODEX_EVIDENCE_FILE="$codex_ambiguous" \
      "$ROOT/cctrl" session restore --from "$codex_restore_snap" --dry-run --json 2>/dev/null)" || rc=$?
    [[ "$rc" -eq 69 ]] || fail "ambiguous Codex evidence did not exit 69 (rc=$rc)"
    jq -e 'any(.plan[]; .provider_task_id=="codex-restore-1" and .disposition=="insufficient-evidence" and .action_capabilities.restore.supported==false)' <<< "$out" >/dev/null \
      || fail "ambiguous Codex evidence left restore executable: $out"

    jq '.records[0].chosen_outcome.lifecycle_state="archived"' "$codex_absent" > "$codex_archived"
    out="$(CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_RESTORE_CATALOGUE_FILE="$codex_restore_catalog" \
      CCTRL_RESTORE_PROCESS_FILE="$process" CCTRL_RESTORE_CODEX_EVIDENCE_FILE="$codex_archived" \
      "$ROOT/cctrl" session restore --from "$codex_restore_snap" --dry-run --json)"
    jq -e 'any(.plan[]; .provider_task_id=="codex-restore-1" and .disposition=="insufficient-evidence" and (.reason|contains("archived")))' <<< "$out" >/dev/null \
      || fail "archived current Codex evidence left restore executable: $out"

    # Legacy adapter: Claude may carry candidate provenance, Codex never does.
    local legacy="$TMPDIR/snapshot-ownership/legacy.json" adapted
    cat > "$legacy" <<'JSON'
{"schema_version":1,"generated_at":"2026-09-17T10:00:00Z","hostname":"test-host","sessions":[
 {"name":"TMUX--old-claude","managed":true,"agent":"claude","conversation_id":"old-claude","cwd":"/tmp/old"},
 {"name":"TMUX--old-codex","managed":true,"agent":"codex","conversation_id":"old-codex","cwd":"/tmp/old"}]}
JSON
    adapted="$(CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_NO_MAIN=1 bash -c 'source "$0"; _snapshot_v1_to_v2 "$1" "$2" test-host' "$ROOT/cctrl" "$legacy" "$host")"
    jq -e '(.tasks[]|select(.provider_task_id=="old-claude")|.restore_strategy)=="tmux-resume" and (.tasks[]|select(.provider_task_id=="old-codex")|.restore_strategy)==null' <<< "$adapted" >/dev/null \
      || fail "v1 adapter eligibility is wrong: $adapted"

    # --force-host bypasses only the envelope hostname, never row host identity.
    local foreign="$TMPDIR/snapshot-ownership/foreign.json"
    jq '.hostname="other-host" | .tasks[0].host_id="ffffffffffffffffffffffffffffffff" | .tasks=[.tasks[0]] | .task_reference_count=1' "$snapshots/latest.json" > "$foreign"
    rc=0; out="$(CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_RESTORE_CATALOGUE_FILE="$current" \
      CCTRL_RESTORE_PROCESS_FILE="$process" CCTRL_RESTORE_CODEX_EVIDENCE_FILE="$codex" \
      "$ROOT/cctrl" session restore --from "$foreign" --force-host --dry-run --json 2>/dev/null)" || rc=$?
    [[ "$rc" -eq 75 ]] || fail "foreign durable host evidence did not exit 75 (rc=$rc)"
    jq -e '.plan[0].disposition=="insufficient-evidence" and (.plan[0].reason|contains("host id mismatch"))' <<< "$out" >/dev/null \
      || fail "--force-host upgraded a foreign durable host id"

    after="$(live_data_manifest)"
    assert_live_store_unchanged "$before" "$after" "snapshot ownership tests changed the real cctrl data store" \
        TMUX--claude TMUX--live TMUX--old-claude TMUX--old-codex
    echo "ok: snapshot/restore is schema-v2, ownership-aware, exact-id, source-gated, and non-destructive"
}

test_snapshot_restore_default_honors_data_dir() {
    # Plan 078: `session snapshot` (and `session restore --from latest`)
    # without --dir must follow CCTRL_DATA_DIR, not the real data/snapshots.
    # live_data_manifest() deliberately EXEMPTS snapshots/latest.json and its
    # siblings (the live launchd timer legitimately rewrites them every 5
    # minutes), so a before/after manifest comparison can't catch a regression
    # here — it would pass even if this wrote straight into the real store.
    # Assert the real thing instead: a distinct fake host id that can only
    # have come from THIS test never appears in the real latest.json, and the
    # restore default's "not found" error reports the CCTRL_DATA_DIR path,
    # not the real one.
    local root="$TMPDIR/snapshot-default-datadir" data host="0123456789abcdef0123456789abcdef"
    data="$root/data"
    mkdir -p "$root" "$data"
    printf '%s\n' "$host" > "$data/host-id"
    local catalogue="$root/catalogue.json" process="$root/process.json"
    cat > "$process" <<'JSON'
{"schema_version":1,"status":"available","observed_at":"2026-09-17T10:00:00Z","source_cursor":"process-1","processes":[],"error":null}
JSON
    cat > "$catalogue" <<JSON
{"schema_version":2,"host_id":"$host","source_status":{"registry":"available","tmux":"available","codex_provider":"available"},"source_errors":[],"rows":[]}
JSON

    local real_latest="$ROOT/data/snapshots/latest.json" out rc=0
    out="$(CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_SNAPSHOT_CATALOGUE_FILE="$catalogue" \
      CCTRL_SNAPSHOT_PROCESS_FILE="$process" CCTRL_FAKE_MEM_FREE_PCT=50 CCTRL_FAKE_SWAP_MB=0 \
      "$ROOT/cctrl" session snapshot --allow-empty --json)" || fail "default-dir snapshot failed: $out"
    [[ -f "$data/snapshots/latest.json" ]] || fail "snapshot without --dir did not honor CCTRL_DATA_DIR"
    jq -e --arg host "$host" '.host_id==$host' "$data/snapshots/latest.json" >/dev/null \
      || fail "test snapshot did not land the fake host id (isolation check invalid)"
    if [[ -f "$real_latest" ]]; then
        [[ "$(jq -r '.host_id // empty' "$real_latest" 2>/dev/null)" != "$host" ]] \
            || fail "session snapshot without --dir wrote the real cctrl data store"
    fi

    # A fresh, empty CCTRL_DATA_DIR (no snapshots/ at all yet) makes restore's
    # default resolution deterministic: it must report ITS OWN missing path,
    # never fall through to the real store's (possibly-present) latest.json.
    local empty_root="$TMPDIR/snapshot-default-datadir-empty/data"
    mkdir -p "$empty_root"
    rc=0; out="$(CCTRL_DATA_DIR="$empty_root" CCTRL_HOST_ID_FILE="$empty_root/host-id" \
      "$ROOT/cctrl" session restore --from latest --json 2>&1)" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "restore --from latest against an empty CCTRL_DATA_DIR should exit 64 (rc=$rc): $out"
    jq -e --arg path "$empty_root/snapshots/latest.json" '.path==$path' <<< "$out" >/dev/null \
      || fail "restore --from latest without --dir did not resolve against CCTRL_DATA_DIR: $out"

    rc=0; out="$(CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_RESTORE_CATALOGUE_FILE="$catalogue" \
      CCTRL_RESTORE_PROCESS_FILE="$process" \
      "$ROOT/cctrl" session restore --from latest --dry-run --json 2>&1)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "default-dir restore --from latest failed (rc=$rc): $out"

    echo "ok: session snapshot/restore without --dir honor CCTRL_DATA_DIR, not the real store"
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
    # Fake ssh: fixtures may provide task/legacy stdout, stderr, and status
    # separately. Existing <target>.json fixtures model an older cctrl: the task
    # command returns the exact unsupported signature, then session ls reads it.
    local path="$1"
    cat > "$path" <<'SH'
#!/usr/bin/env bash
target="${@:(-2):1}"
command="${@:(-1):1}"
case "$target" in
    *slow*)
        sleep 20
        exit 0
        ;;
    *offline*)
        echo "ssh: connect to host $target port 22: Connection refused" >&2
        exit 255
        ;;
esac
kind=legacy
[[ "$command" == *"task ls --json"* ]] && kind=task
base="${FLEET_FIXTURES:-}/$target.$kind"
if [[ -n "${FLEET_FIXTURES:-}" && -f "$base.stdout" ]]; then
    cat "$base.stdout"
    [[ -f "$base.stderr" ]] && cat "$base.stderr" >&2
    [[ -f "$base.status" ]] && exit "$(cat "$base.status")"
    exit 0
fi
fixture="${FLEET_FIXTURES:-}/$target.json"
if [[ "$kind" == task && -f "$fixture" ]]; then
    printf 'Unknown command: task\nUsage: cctrl <command>\n'
    exit 1
fi
if [[ "$kind" == legacy && -f "$fixture" ]]; then
    cat "$fixture"
    exit 0
fi
printf 'Unknown command: task\nUsage: cctrl <command>\n'
[[ "$kind" == task ]] && exit 1
echo "[]"
exit 0
SH
    chmod +x "$path"
}

fleet_rootcopy() {
    # Copy cctrl into an isolated root so HOSTS_FILE (=<root>/data/hosts.json)
    # can be controlled per test without touching the repo's data/hosts.json.
    local root="$1" hosts_json="$2"
    mkdir -p "$root/data" "$root/lib"
    cp "$ROOT/cctrl" "$root/cctrl"
    cp "$ROOT/lib/cctrl_fleet_collect.py" "$root/lib/cctrl_fleet_collect.py"
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
    first="$(printf '%s' "$out" | jq -r '[.[] | select(.host == "hA" or .host == "hB")][0].host')"
    second="$(printf '%s' "$out" | jq -r '[.[] | select(.host == "hA" or .host == "hB")][1].host')"
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

test_fleet_v2_provider_neutral_federation() {
    local root="$TMPDIR/fleet-v2-root" bin="$TMPDIR/fleet-v2-bin" fix="$TMPDIR/fleet-v2-fix"
    local data="$TMPDIR/fleet-v2-data" meta="$TMPDIR/fleet-v2-meta" codex="$TMPDIR/fleet-v2-codex"
    rm -rf "$root" "$bin" "$fix" "$data" "$meta" "$codex"
    mkdir -p "$bin" "$fix" "$data" "$meta" "$codex"
    make_fake_tmux "$bin/tmux"
    make_fake_ps "$bin/ps"
    make_fleet_ssh "$bin/ssh"
    fleet_rootcopy "$root" '{
      "new":{"hostname":"new.invalid","user":"","federation_host_id":"fed-new","remote_host_id":"remote-new"},
      "old":{"hostname":"old.invalid","user":""},
      "bad":{"hostname":"bad.invalid","user":"","federation_host_id":"fed-bad","remote_host_id":null},
      "invalidrow":{"hostname":"invalidrow.invalid","user":"","federation_host_id":"fed-invalidrow","remote_host_id":null},
      "wrong":{"hostname":"wrong.invalid","user":"","federation_host_id":"fed-wrong","remote_host_id":null},
      "partial":{"hostname":"partial.invalid","user":"","federation_host_id":"fed-partial","remote_host_id":"remote-partial"},
      "duplicate":{"hostname":"duplicate.invalid","user":"","federation_host_id":"fed-duplicate","remote_host_id":"remote-duplicate"},
      "mismatch":{"hostname":"mismatch.invalid","user":"","federation_host_id":"fed-mismatch","remote_host_id":"expected-remote"},
      "large":{"hostname":"large.invalid","user":"","federation_host_id":"fed-large","remote_host_id":"remote-large"},
      "off":{"hostname":"offline.invalid","user":"","federation_host_id":"fed-offline","remote_host_id":null}
    }'
    cat > "$fix/new.invalid.task.stdout" <<'JSON'
{"schema_version":2,"host_id":"remote-new","capabilities":{"task_list":{"supported":true,"reason":"available"}},"source_status":{"registry":"available","tmux":"available","codex_provider":"available"},"source_errors":[],"rows":[
 {"task_key":"provider:codex:remote-new:same-id","provider":"codex","provider_task_id":"same-id","host_id":"remote-new","origin":"codex-app","execution_runtime":"app-server","control_owner":"app","lifecycle_state":"active","registered_by_cctrl":false,"launched_by_cctrl":false,"recency":"2026-09-17T12:00:00Z","cwd":"/new","display_title":"Native app","action_capabilities":{"app_open":{"supported":true,"reason":"available"},"tmux_attach":{"supported":false,"reason":"no-live-cctrl-tmux-owner"},"handoff":{"supported":false,"reason":"not-implemented"},"cctrl_restore":{"supported":false,"reason":"not-implemented"}}},
 {"task_key":"provider:codex:remote-new:tmux-id","provider":"codex","provider_task_id":"tmux-id","host_id":"remote-new","origin":"cctrl","execution_runtime":"tmux","control_owner":"cctrl","lifecycle_state":"active","registered_by_cctrl":true,"launched_by_cctrl":true,"recency":"2026-09-17T11:00:00Z","cwd":"/tmux","display_title":"Managed tmux","tmux_session":"TMUX--managed","action_capabilities":{"app_open":{"supported":false,"reason":"owned-by-cctrl"},"tmux_attach":{"supported":true,"reason":"available"},"handoff":{"supported":false,"reason":"not-implemented"},"cctrl_restore":{"supported":false,"reason":"not-implemented"}}}
]}
JSON
    sed 's/remote-new/unexpected-remote/g' "$fix/new.invalid.task.stdout" > "$fix/mismatch.invalid.task.stdout"
    python3 - "$fix/large.invalid.task.stdout" <<'PY'
import json,sys
rows=[]
for i in range(1200):
    rows.append({"task_key":f"provider:codex:remote-large:large-{i}","provider":"codex","provider_task_id":f"large-{i}","host_id":"remote-large","origin":"unknown","execution_runtime":"unknown","control_owner":"unknown","lifecycle_state":"unknown","registered_by_cctrl":False,"launched_by_cctrl":False,"recency":None,"cwd":"/large","display_title":"x"*256,"action_capabilities":{"app_open":{"supported":False,"reason":"unknown"},"tmux_attach":{"supported":False,"reason":"unknown"},"handoff":{"supported":False,"reason":"not-implemented"},"cctrl_restore":{"supported":False,"reason":"not-implemented"}}})
doc={"schema_version":2,"host_id":"remote-large","capabilities":{"task_list":{"supported":True,"reason":"available"}},"source_status":{"registry":"available","tmux":"available","codex_provider":"available"},"source_errors":[],"rows":rows}
open(sys.argv[1],"w",encoding="utf-8").write(json.dumps(doc)+"\n")
PY
    cat > "$fix/partial.invalid.task.stdout" <<'JSON'
{"schema_version":2,"host_id":"remote-partial","capabilities":{"task_list":{"supported":true,"reason":"available"}},"source_status":{"registry":"available","tmux":"available","codex_provider":"unavailable"},"source_errors":[{"source":"codex-provider","status":"unavailable","error":"state-db-not-found"}],"rows":[{"task_key":"tmux:remote-partial:$1","provider":"unknown","provider_task_id":null,"host_id":"remote-partial","origin":"unknown","execution_runtime":"tmux","control_owner":"unknown","lifecycle_state":"active","registered_by_cctrl":false,"launched_by_cctrl":false,"recency":null,"cwd":"/partial","display_title":"partial-tmux","action_capabilities":{"app_open":{"supported":false,"reason":"provider-unavailable"},"tmux_attach":{"supported":false,"reason":"no-live-cctrl-tmux-owner"},"handoff":{"supported":false,"reason":"not-implemented"},"cctrl_restore":{"supported":false,"reason":"not-implemented"}}}]}
JSON
    cat > "$fix/duplicate.invalid.task.stdout" <<'JSON'
{"schema_version":2,"host_id":"remote-duplicate","capabilities":{"task_list":{"supported":true,"reason":"available"}},"source_status":{"registry":"available","tmux":"available","codex_provider":"available"},"source_errors":[],"rows":[{"task_key":"provider:codex:remote-duplicate:same-id","provider":"codex","provider_task_id":"same-id","host_id":"remote-duplicate","origin":"unknown","execution_runtime":"unknown","control_owner":"unknown","lifecycle_state":"unknown","registered_by_cctrl":false,"launched_by_cctrl":false,"recency":"not-a-standard-date","cwd":"/duplicate","display_title":"Same id, other host","action_capabilities":{"app_open":{"supported":false,"reason":"unknown"},"tmux_attach":{"supported":false,"reason":"unknown"},"handoff":{"supported":false,"reason":"not-implemented"},"cctrl_restore":{"supported":false,"reason":"not-implemented"}}}]}
JSON
    printf '[{"name":"legacy","dir":"/legacy","state":"idle","attached":false,"last_active":null,"session_id":"legacy-session"}]\n' > "$fix/old.invalid.json"
    printf '\033[31mUnknown command: task\033[0m\nUsage: cctrl <command>\n' > "$fix/old.invalid.task.stdout"
    printf '1\n' > "$fix/old.invalid.task.status"
    printf '{definitely not json\n' > "$fix/bad.invalid.task.stdout"
    printf '[{"name":"must-not-fallback"}]\n' > "$fix/bad.invalid.json"
    printf '%s\n' '{"schema_version":2,"host_id":"remote-invalid","capabilities":{},"source_status":{"registry":"available","tmux":"available","codex_provider":"available"},"source_errors":[],"rows":[{"task_key":"bad","provider":"codex","origin":"unknown","execution_runtime":"unknown","control_owner":"app","lifecycle_state":"active","action_capabilities":{}}]}' > "$fix/invalidrow.invalid.task.stdout"
    printf '[{"name":"invalid-row-must-not-fallback"}]\n' > "$fix/invalidrow.invalid.json"
    printf 'Unknown command: task\nUsage: cctrl <command>\n' > "$fix/wrong.invalid.task.stdout"
    printf 'warning\n' > "$fix/wrong.invalid.task.stderr"
    printf '1\n' > "$fix/wrong.invalid.task.status"
    printf '[{"name":"must-not-fallback-either"}]\n' > "$fix/wrong.invalid.json"

    local before after out legacy human
    before="$(live_data_manifest)"
    out="$(PATH="$(_test_path "$bin")" FLEET_FIXTURES="$fix" CCTRL_DATA_DIR="$data" \
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" CODEX_HOME="$codex" \
        CCTRL_CODEX_STATE_DB="$codex/missing.sqlite" "$root/cctrl" fleet --json-v2)" || fail "fleet v2 failed"
    after="$(live_data_manifest)"
    assert_live_store_unchanged "$before" "$after" "fleet v2 tests changed the real cctrl live store" TMUX--managed
    jq -e '
      (keys == ["capabilities","error","rows","schema_version","status"]) and
      .schema_version == 2 and .status == "partial" and
      ([.rows[] | select(.host=="new" and .provider_task_id=="same-id")] | length == 1) and
      ([.rows[] | select(.host=="duplicate" and .provider_task_id=="same-id")] | length == 1) and
      ([.rows[] | select(.host=="new" and .provider_task_id=="tmux-id")][0].action_hint == "tmux-attach") and
      ([.rows[] | select(.host=="new" and .provider_task_id=="same-id")][0].action_hint == "app-open") and
      ([.rows[] | select(.host=="old")][0].remote_schema_version == 1) and
      ([.rows[] | select(.host=="old")][0].host_identity_state == "identity-uninitialized") and
      ([.rows[] | select(.host=="partial")][0].remote_status == "partial") and
      ([.rows[] | select(.host=="mismatch")][0] |
        .host_marker == true and .remote_status == "identity-conflict" and .remote_error.code == "remote-host-id-mismatch") and
      ([.rows[] | select(.host=="mismatch" and .provider_task_id!=null)] | length == 0) and
      ([.rows[] | select(.host=="bad")][0].remote_status == "malformed") and
      ([.rows[] | select(.host=="bad" and .name=="must-not-fallback")] | length == 0) and
      ([.rows[] | select(.host=="invalidrow")][0].remote_status == "malformed") and
      ([.rows[] | select(.host=="invalidrow" and .name=="invalid-row-must-not-fallback")] | length == 0) and
      ([.rows[] | select(.host=="wrong")][0].remote_status == "unavailable") and
      ([.rows[] | select(.host=="wrong" and .name=="must-not-fallback-either")] | length == 0) and
      ([.rows[] | select(.host=="large")] | length == 1200) and
      ([.rows[] | select(.host=="off")][0].offline == true) and
      (all(.rows[]; has("name") and has("host") and has("managed") and has("agent") and has("claude") and has("model") and has("dir") and has("state") and has("attached") and has("remote_control") and has("bridge") and has("session_id") and has("transcript") and has("last_active") and has("purpose") and has("created_at") and has("peer") and has("display_label")))
    ' <<< "$out" >/dev/null || fail "fleet v2 ownership, compatibility, or failure envelope is wrong: $out"

    legacy="$(PATH="$(_test_path "$bin")" FLEET_FIXTURES="$fix" CCTRL_DATA_DIR="$data" \
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" CODEX_HOME="$codex" \
        CCTRL_CODEX_STATE_DB="$codex/missing.sqlite" "$root/cctrl" fleet --json)"
    jq -e 'type=="array" and any(.[]; .host=="new") and any(.[]; .host=="old")' <<< "$legacy" >/dev/null \
        || fail "fleet --json no longer returns the compatibility array"
    human="$(PATH="$(_test_path "$bin")" FLEET_FIXTURES="$fix" CCTRL_DATA_DIR="$data" \
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" CODEX_HOME="$codex" \
        CCTRL_CODEX_STATE_DB="$codex/missing.sqlite" "$root/cctrl" fleet)"
    assert_contains "$human" "OWNER"
    assert_contains "$human" "RUNTIME"
    assert_contains "$human" "ORIGIN"
    assert_contains "$human" "app-open"
    assert_contains "$human" "tmux-attach"
    local native_line
    native_line="$(printf '%s\n' "$human" | grep 'Native app' || true)"
    assert_contains "$native_line" "active"
    assert_not_contains "$native_line" " ok "

    # Host ids are initialized atomically for new registrations, survive alias
    # changes, and legacy registrations migrate only on explicit refresh.
    local host_data="$TMPDIR/fleet-v2-host-data" first_id renamed_id
    rm -rf "$host_data"; mkdir -p "$host_data"
    PATH="$(_test_path "$bin")" CCTRL_DATA_DIR="$host_data" CCTRL_HOSTS_FILE="$host_data/hosts.json" "$root/cctrl" host add alpha new.invalid >/dev/null
    first_id="$(jq -r '.alpha.federation_host_id' "$host_data/hosts.json")"
    [[ "$first_id" =~ ^[0-9a-f]{32}$ ]] || fail "host add did not create a federation id"
    [[ "$(stat -f %Lp "$host_data/hosts.json")" == 600 ]] || fail "host registry is not private"
    PATH="$(_test_path "$bin")" CCTRL_DATA_DIR="$host_data" CCTRL_HOSTS_FILE="$host_data/hosts.json" "$root/cctrl" host rename alpha beta >/dev/null
    renamed_id="$(jq -r '.beta.federation_host_id' "$host_data/hosts.json")"
    [[ "$first_id" == "$renamed_id" ]] || fail "alias rename changed federation identity"
    printf '{"legacy":{"hostname":"new.invalid","user":""}}\n' > "$host_data/hosts.json"
    PATH="$(_test_path "$bin")" FLEET_FIXTURES="$fix" CCTRL_DATA_DIR="$host_data" CCTRL_HOSTS_FILE="$host_data/hosts.json" \
        "$root/cctrl" host refresh-identity legacy >/dev/null
    jq -e '.legacy.federation_host_id | test("^[0-9a-f]{32}$")' "$host_data/hosts.json" >/dev/null \
        || fail "refresh-identity did not initialize legacy registration"
    [[ "$(jq -r '.legacy.remote_host_id' "$host_data/hosts.json")" == remote-new ]] \
        || fail "refresh-identity did not map authoritative remote host id"
    local identity_before identity_after identity_rc=0
    jq '.legacy.remote_host_id="different-remote"' "$host_data/hosts.json" > "$host_data/hosts.tmp"
    mv "$host_data/hosts.tmp" "$host_data/hosts.json"
    identity_before="$(shasum -a 256 "$host_data/hosts.json" | awk '{print $1}')"
    PATH="$(_test_path "$bin")" FLEET_FIXTURES="$fix" CCTRL_DATA_DIR="$host_data" CCTRL_HOSTS_FILE="$host_data/hosts.json" \
        "$root/cctrl" host refresh-identity legacy >/dev/null 2>&1 || identity_rc=$?
    (( identity_rc != 0 )) || fail "refresh-identity replaced an immutable remote identity"
    identity_after="$(shasum -a 256 "$host_data/hosts.json" | awk '{print $1}')"
    [[ "$identity_before" == "$identity_after" ]] || fail "failed identity refresh mutated the host registration"

    # The helper enforces a whole-process timeout and emits a structured marker.
    local timeout_hosts="$TMPDIR/fleet-timeout-hosts.json" timeout_results="$TMPDIR/fleet-timeout-results" timeout_path
    printf '{"slow":{"hostname":"slow.invalid","user":"","federation_host_id":"fed-slow","remote_host_id":null}}\n' > "$timeout_hosts"
    rm -rf "$timeout_results"
    timeout_path="$(PATH="$(_test_path "$bin")" FLEET_FIXTURES="$fix" python3 "$ROOT/lib/cctrl_fleet_collect.py" collect \
        --hosts-file "$timeout_hosts" --output-dir "$timeout_results" --workers 4 --timeout .1)" || fail "timeout collector crashed"
    jq -e '.status=="timeout" and .error.code=="timeout"' "$timeout_path" >/dev/null \
        || fail "timed-out worker did not emit a structured timeout envelope"
    [[ -f "$timeout_results/host-00000/task.stdout" && -f "$timeout_results/host-00000/task.stderr" && -f "$timeout_results/host-00000/task.status" ]] \
        || fail "collector did not isolate stdout/stderr/status for the timed-out host"

    local empty_root="$TMPDIR/fleet-v2-empty-root" empty_data="$TMPDIR/fleet-v2-empty-data"
    rm -rf "$empty_root" "$empty_data"; mkdir -p "$empty_root/lib" "$empty_data"
    cp "$ROOT/cctrl" "$empty_root/cctrl"; chmod +x "$empty_root/cctrl"
    cp "$ROOT/lib/cctrl_fleet_collect.py" "$empty_root/lib/cctrl_fleet_collect.py"
    PATH="$(_test_path "$bin")" CCTRL_DATA_DIR="$empty_data" CCTRL_SESSION_METADATA_DIR="$meta" \
        CCTRL_HOST_ID_FILE="$empty_data/host-id" CODEX_HOME="$codex" CCTRL_CODEX_STATE_DB="$codex/missing.sqlite" \
        "$empty_root/cctrl" fleet --json-v2 >/dev/null
    [[ ! -e "$empty_root/data/hosts.json" ]] || fail "fleet listing initialized host registry identity state"
    echo "ok: fleet v2 federates provider-neutral tasks with stable host identity and exact legacy fallback"
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
    assert_contains "$(cat "$log")" "paste-buffer -p -r -b cctrl-say-TMUX--demo-"
    assert_contains "$(cat "$log")" "send-keys -t =TMUX--demo: Enter"
    # No mailbox file is created or touched by a direct say.
    [[ ! -e "$TMPDIR/data/messages.jsonl" ]] || fail "session say must not write messages.jsonl"

    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        "$ROOT/cctrl" session say TMUX--demo --no-submit --json -- "no enter please")"
    printf '%s\n' "$out" | jq -e '.ok == true and .submitted == false and .status == "ok"' >/dev/null \
        || fail "expected session say --no-submit result"
    assert_contains "$(cat "$log")" "paste-buffer -p -r -b cctrl-say-TMUX--demo-"
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

test_session_say_long_body_bracketed_exact() {
    # A long multi-line body must reach the pane as ONE bracketed paste with LF
    # preserved (-p -r); a plain paste turns every newline into Enter, which
    # split and mostly dropped long messages in Claude Code.
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_ps "$TMPDIR/ps"
    local log="$TMPDIR/say-long.log" bf="$TMPDIR/say-long.txt" raw="$TMPDIR/say-long.raw" out i
    for (( i = 0; i < 600; i++ )); do
        printf 'row %03d — ünïcødé ✓ "q" '\''s'\'' $HOME `bt` \\ back\ttab\n' "$i"
    done > "$bf"
    printf 'no trailing newline' >> "$bf"
    : > "$log"
    out="$(PATH="$TMPDIR:$PATH" TMUX_LOG="$log" TMUX_BUFFER_FILE="$raw" \
        TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
        "$ROOT/cctrl" session say TMUX--demo --body-file "$bf" --json)"
    printf '%s\n' "$out" | jq -e '.ok == true and .submitted == true' >/dev/null \
        || fail "expected long session say to submit: $out"
    cmp -s "$bf" "$raw" || fail "long say body was not loaded byte-for-byte"
    assert_contains "$(cat "$log")" "paste-buffer -p -r -b cctrl-say-TMUX--demo-"
    assert_contains "$(cat "$log")" "send-keys -t =TMUX--demo: Enter"

    echo "ok: session say delivers a long multi-line body exactly as one bracketed paste"
}

test_tmux_paste_buffer_names_unique_per_invocation() {
    # Concurrent senders in the same second must never share a buffer name, or
    # one pastes the other's text and then deletes it mid-paste.
    make_fake_tmux "$TMPDIR/tmux"
    make_fake_ps "$TMPDIR/ps"
    # One log per sender: the fake tmux writes each argument separately, so a
    # shared log interleaves concurrent lines.
    local names i
    for i in 1 2 3 4; do
        PATH="$TMPDIR:$PATH" TMUX_LOG="$TMPDIR/say-concurrent.$i.log" TMUX_FAKE_SESSIONS="TMUX--demo" TMUX_FAKE_HAS_SESSION="TMUX--demo" \
            "$ROOT/cctrl" session say TMUX--demo --no-submit --json -- "msg $i" > "$TMPDIR/say-concurrent.$i.out" &
    done
    wait
    names="$(cat "$TMPDIR"/say-concurrent.*.log | grep -o 'paste-buffer -p -r -b cctrl-say-TMUX--demo-[^ ]*' | sort)"
    [[ "$(printf '%s\n' "$names" | wc -l | tr -d ' ')" == 4 ]] \
        || fail "expected 4 pastes, got: $names; outputs: $(cat "$TMPDIR"/say-concurrent.*.out)"
    [[ "$(printf '%s\n' "$names" | sort -u | wc -l | tr -d ' ')" == 4 ]] || fail "paste buffer names collided: $names"

    echo "ok: concurrent session say invocations use distinct tmux buffers"
}

test_peer_socket_deliver_payload_exact() {
    # The Claude socket adapter must send the exact payload: a here-string
    # appended a newline, and the node fallback spliced the path into JS.
    local capture="$TMPDIR/socat.in" payload got
    mkdir -p "$TMPDIR/socatbin"
    cat > "$TMPDIR/socatbin/socat" <<'SH'
#!/usr/bin/env bash
cat > "${SOCAT_CAPTURE:?}"
SH
    chmod +x "$TMPDIR/socatbin/socat"
    payload=$'first line\nsecond "quoted" ✓\n\n'"$(printf 'x%.0s' {1..5000})"
    (
        CCTRL_NO_MAIN=1 source "$ROOT/cctrl"
        PATH="$TMPDIR/socatbin:$PATH" SOCAT_CAPTURE="$capture" \
            _peer_socket_deliver "$TMPDIR/fake.sock" "$payload"
    ) || fail "socket deliver returned non-zero"
    got="$(jq -j '.message.content' "$capture"; printf '.')"
    got="${got%.}"
    [[ "$got" == "$payload" ]] || fail "socket payload was altered (len ${#got} vs ${#payload})"
    jq -e '.type == "user" and .message.role == "user"' "$capture" >/dev/null || fail "bad socket frame"

    echo "ok: socket delivery sends the exact payload"
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
    assert_contains "$(cat "$log")" "paste-buffer -p -r -b cctrl-say-TMUX--demo-"
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
    assert_contains "$(cat "$log")" "paste-buffer -p -r -b cctrl-say-TMUX--demo-"
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
    assert_contains "$(cat "$log")" "attach-session -t =demo"

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
    assert_contains "$(cat "$log")" "send-keys -t =demo: Enter"
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
    assert_contains "$(cat "$log")" "send-keys -t =TMUX--comet: Enter"
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
if [[ "${1:-}" == "-u" ]]; then shift; fi
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

test_task_record_relaunch_moves_terminal_anchors() {
    # Resuming an existing task into a different tmux session must move the
    # record's terminal anchors (and name index) to the new session; an older
    # launch receipt promoted late must not move them back.
    local root="$TMPDIR/task-relaunch" meta="$TMPDIR/task-relaunch/meta" data="$TMPDIR/task-relaunch/data"
    rm -rf "$root"; mkdir -p "$meta" "$data"
    CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_session_write_metadata "TMUX--old" /tmp directory /tmp label purpose prompt cmd "" claude "shared-id" ""'
    local canonical
    canonical="$(session_record_path "TMUX--old" "$meta")"
    jq '.pane_id="%1" | .pane_pid="100" | .wrapper_pid="100" | .pane_started="old"' "$canonical" > "$canonical.tmp" && mv "$canonical.tmp" "$canonical"

    jq '
        .name="TMUX--new" | .tmux_session="TMUX--new" | .provider_task_id=null | .conversation_id=null |
        .lifecycle_state="provisional" | .provisional_launch_id="11111111-2222-3333-4444-555555555555" |
        .created_at="2999-01-01T00:00:00Z" | .pane_id="%9" | .pane_pid="900" | .wrapper_pid="900" | .pane_started="new" |
        .ownership_evidence=[]
    ' "$canonical" > "$meta/launch-11111111-2222-3333-4444-555555555555.json"
    # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
    CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_task_record_promote_legacy "$1" "shared-id" >/dev/null' "$meta/launch-11111111-2222-3333-4444-555555555555.json"
    jq -e '.name == "TMUX--new" and .tmux_session == "TMUX--new" and .pane_id == "%9" and .pane_pid == "900" and .provider_task_id == "shared-id"' \
        "$canonical" >/dev/null || fail "relaunch under a new tmux session kept the previous terminal anchors"
    [[ "$(CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval '_session_metadata_file "TMUX--new"')" == "$canonical" ]] \
        || fail "new tmux session name does not resolve to the relaunched task"

    jq '.ownership_evidence += [{source:"cctrl-launch",source_instance:"TMUX--new",source_cursor:null,authority_class:"authoritative",observed_owner:"cctrl",observed_runtime:"tmux",observed_state:"provisional",observed_at:"2999-01-01T00:00:00Z",reason:"cctrl launched the terminal writer"}]' \
        "$canonical" > "$canonical.tmp" && mv "$canonical.tmp" "$canonical"
    jq '
        .name="TMUX--stale" | .tmux_session="TMUX--stale" | .provider_task_id=null | .conversation_id=null |
        .lifecycle_state="provisional" | .provisional_launch_id="66666666-7777-8888-9999-000000000000" |
        .created_at="2000-01-01T00:00:00Z" | .ownership_evidence=[]
    ' "$canonical" > "$meta/launch-66666666-7777-8888-9999-000000000000.json"
    # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
    CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_task_record_promote_legacy "$1" "shared-id" >/dev/null' "$meta/launch-66666666-7777-8888-9999-000000000000.json"
    jq -e '.tmux_session == "TMUX--new"' "$canonical" >/dev/null || fail "an older launch receipt moved the terminal anchors back"
    echo "ok: relaunching a task moves its terminal anchors; older receipts cannot roll them back"
}

test_task_record_relaunch_moves_profile_identity() {
    # Plan 071 phase 6: resuming a task under a different profile must carry
    # that profile (and the backend/model/config-dir it implies) forward --
    # the stored record describes an earlier execution and would otherwise
    # mislabel the session now actually running under it (same reasoning as
    # the terminal-anchor move above).
    local root="$TMPDIR/task-relaunch-profile" meta="$TMPDIR/task-relaunch-profile/meta" data="$TMPDIR/task-relaunch-profile/data"
    rm -rf "$root"; mkdir -p "$meta" "$data"
    # shellcheck disable=SC2016 # literal args belong to the sourced shell
    CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_session_write_metadata "TMUX--old" /tmp directory /tmp label purpose prompt cmd "" claude "shared-id-2" "" "profile-a" "explicit" "subscription" "sonnet" "" "/profiles/a.json"'
    local canonical
    canonical="$(session_record_path "TMUX--old" "$meta")"
    jq -e '.profile == "profile-a" and .profile_source == "explicit"' "$canonical" >/dev/null \
        || fail "expected the initial record to carry profile-a"

    jq '
        .name="TMUX--new" | .tmux_session="TMUX--new" | .provider_task_id=null | .conversation_id=null |
        .lifecycle_state="provisional" | .provisional_launch_id="22222222-3333-4444-5555-666666666666" |
        .created_at="2999-01-01T00:00:00Z" |
        .profile="profile-b" | .profile_source="default" | .auth_backend="bedrock" |
        .requested_model="opus" | .claude_config_dir="/custom" | .profile_file="/profiles/b.json" |
        .ownership_evidence=[]
    ' "$canonical" > "$meta/launch-22222222-3333-4444-5555-666666666666.json"
    # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
    CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" \
        cctrl_source_eval '_task_record_promote_legacy "$1" "shared-id-2" >/dev/null' "$meta/launch-22222222-3333-4444-5555-666666666666.json"
    jq -e '.profile == "profile-b" and .profile_source == "default" and .auth_backend == "bedrock" and .requested_model == "opus" and .claude_config_dir == "/custom" and .profile_file == "/profiles/b.json"' \
        "$canonical" >/dev/null || fail "resuming under profile-b did not update the stored profile identity"
    echo "ok: relaunching a task under a new profile updates its stored profile identity"
}

test_task_record_relaunch_reclaims_and_reopens() {
    # Plan 070 S4: a cctrl terminal relaunch that is newer than the handoff to
    # the app (or than the recorded end) takes ownership back instead of
    # merging into `conflict`; an older one keeps the conservative conflict.
    local root="$TMPDIR/task-reclaim" meta="$TMPDIR/task-reclaim/meta" data="$TMPDIR/task-reclaim/data"
    rm -rf "$root"; mkdir -p "$meta" "$data"
    export_env() { CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" "$@"; }
    canonical_for() { # name task-id agent -> canonical path, handed off to the app at 2026-09-20T10:00:00Z
        # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
        export_env cctrl_source_eval '_session_write_metadata "$1" /tmp directory /tmp label purpose prompt cmd "" "$3" "$2" ""' "$1" "$2" "$3"
        local file; file="$(session_record_path "$1" "$meta")"
        jq '.control_owner="app" | .execution_runtime="app-server" | .restore_strategy="provider-managed" |
            .pane_id="%1" | .pane_pid="100" | .wrapper_pid="100" | .pane_started="old" |
            .ownership_evidence=[{source:"cctrl-launch",source_instance:"x",source_cursor:null,authority_class:"authoritative",observed_owner:"cctrl",observed_runtime:"tmux",observed_state:"active",observed_at:"2026-09-20T08:00:00Z",reason:"launch"}] |
            .ownership_observations=[{source:"cctrl-handoff",source_instance_id:"h",authority_class:"authoritative",proposed_owner:"app",proposed_runtime:"app-server",proposed_state:"active",observed_at:"2026-09-20T10:00:00Z",basis_record_digest:"d",event_fingerprint:"f",source_sequence:1,source_cursor:null}]' \
            "$file" > "$file.tmp" && mv "$file.tmp" "$file"
        printf '%s' "$file"
    }
    relaunch() { # canonical-file uuid created_at -> promote a newer/older launch receipt
        local receipt="$meta/launch-$2.json"
        jq --arg id "$2" --arg at "$3" '
            .provider_task_id=null | .conversation_id=null | .lifecycle_state="provisional" |
            .provisional_launch_id=$id | .created_at=$at | .control_owner="cctrl" | .execution_runtime="tmux" |
            .control_surface="tmux" | .restore_strategy="tmux" | .launched_by_cctrl=true | .origin="cctrl" |
            .pane_id="%9" | .pane_pid="900" | .wrapper_pid="900" | .pane_started="new" |
            .ownership_evidence=[] | del(.ownership_observations)' "$1" > "$receipt"
        # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
        export_env cctrl_source_eval '_task_record_promote_legacy "$1" "$2" >/dev/null' "$receipt" "$(jq -r '.provider_task_id' "$1")"
    }

    local newer older closed
    newer="$(canonical_for TMUX--reclaim reclaim-id codex)"
    relaunch "$newer" 11111111-2222-3333-4444-555555555555 "2026-09-23T16:33:00Z"
    jq -e '.control_owner=="cctrl" and .execution_runtime=="tmux" and .lifecycle_state=="active" and
           .restore_strategy=="tmux" and .pane_id=="%9" and any(.ownership_evidence[]; .source=="cctrl-reclaim")' \
        "$newer" >/dev/null || fail "a relaunch newer than the app handoff did not reclaim the task: $(jq -c '{control_owner,execution_runtime,lifecycle_state,restore_strategy}' "$newer")"

    older="$(canonical_for TMUX--older older-id codex)"
    relaunch "$older" 22222222-3333-4444-5555-666666666666 "2026-09-20T09:00:00Z"
    jq -e '.control_owner=="conflict" and .execution_runtime=="conflict"' "$older" >/dev/null \
        || fail "a relaunch older than the app handoff silently took ownership: $(jq -c '{control_owner,execution_runtime}' "$older")"

    # A task ended on purpose (plan 070 S3) is reopened by a newer relaunch.
    closed="$(canonical_for TMUX--closed closed-id claude)"
    jq '.control_owner="cctrl" | .execution_runtime="tmux" | .restore_strategy="tmux" | .ownership_observations=[]' \
        "$closed" > "$closed.tmp" && mv "$closed.tmp" "$closed"
    # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
    export_env cctrl_source_eval '_task_record_transition_file "$1" TMUX--closed unknown unknown closed "" cctrl-terminate authoritative "killed"' "$closed" \
        || fail "could not record the fixture task closed"
    [[ "$(jq -r '.lifecycle_state' "$closed")" == closed ]] || fail "fixture task was not closed"
    relaunch "$closed" 33333333-4444-5555-6666-777777777777 "2999-01-01T00:00:00Z"
    jq -e '.lifecycle_state=="active" and .control_owner=="cctrl" and .execution_runtime=="tmux"' "$closed" >/dev/null \
        || fail "a newer relaunch did not reopen a closed task: $(jq -c '{control_owner,execution_runtime,lifecycle_state}' "$closed")"

    # A pane-anchor receipt never promotes a legacy name-keyed record: that
    # would give an older conversation the live pane's anchor.
    cat > "$meta/TMUX--legacy.json" <<'JSON'
{"name":"TMUX--legacy","agent":"claude","cctrl_managed":true,"conversation_id":"legacy-conv","dir":"/tmp","created_at":"2026-09-06T10:00:00Z"}
JSON
    local rc=0 receipt='{"control_surface":"tmux","tmux_session":"TMUX--legacy","pane_id":"%5","pane_pid":"500","wrapper_pid":"500","pane_started":"now"}'
    # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
    export_env cctrl_source_eval '_session_update_metadata_field TMUX--legacy _terminal_anchor_receipt "$1"' "$receipt" >/dev/null 2>&1 || rc=$?
    [[ "$rc" -ne 0 ]] || fail "an anchor receipt was applied to a legacy record"
    [[ ! -e "$(export_env cctrl_source_eval '_task_record_file claude "$(_cctrl_host_id)" legacy-conv')" ]] \
        || fail "an anchor receipt promoted a legacy conversation to a canonical record"
    echo "ok: newer terminal relaunches reclaim app-handed-off or closed tasks; anchor receipts never promote legacy records"
}

test_task_resolve_conflicts_digest_guarded() {
    # Plan 070 S5: resolve-conflicts is dry-run by default, writes only what a
    # fresh evidence pass still supports, and every write is digest-guarded.
    local root="$TMPDIR/resolve-conflicts" meta="$TMPDIR/resolve-conflicts/meta" data="$TMPDIR/resolve-conflicts/data"
    local sessions="$TMPDIR/resolve-conflicts/claude-sessions" codex_id="01a0bde7-4a5f-7ba0-bbfb-a1e4e4df4af4"
    local started="Wed Sep 23 17:40:22 2026" out before rc
    rm -rf "$root"; mkdir -p "$meta" "$data" "$sessions"
    resolve_env() {
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
            CCTRL_CLAUDE_SESSIONS_DIR="$sessions" CCTRL_RESOLVE_PANES_FILE="$root/panes.json" \
            CCTRL_RESOLVE_PROCESS_FILE="$root/process.json" CCTRL_RESOLVE_CODEX_EVIDENCE_FILE="$root/codex.json" "$@"
    }
    anchored() { # name task-id agent pane_id pane_pid [owner runtime state]
        # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
        resolve_env cctrl_source_eval '_session_write_metadata "$1" /tmp directory /tmp label purpose prompt cmd "" "$3" "$2" ""' "$1" "$2" "$3"
        local file; file="$(resolve_env cctrl_source_eval '_task_record_file "$1" "$(_cctrl_host_id)" "$2"' "$3" "$2")"
        jq --arg p "$4" --arg pid "$5" --arg s "$started" --arg o "${6:-cctrl}" --arg r "${7:-tmux}" --arg l "${8:-active}" \
            '.pane_id=$p | .pane_pid=$pid | .pane_started=$s | .control_owner=$o | .execution_runtime=$r | .lifecycle_state=$l' \
            "$file" > "$file.tmp" && mv "$file.tmp" "$file"
        printf '%s' "$file"
    }
    local f_live f_old f_stale f_codex
    f_live="$(anchored TMUX--homelab live-id claude %0 100)"
    f_old="$(anchored TMUX--homelab old-id claude %0 100)"
    f_stale="$(anchored TMUX--homelab stale-id claude %47 700)"
    f_codex="$(anchored TMUX--cctrl "$codex_id" codex %15 3338 conflict conflict active)"
    cat > "$root/panes.json" <<'JSON'
{"status":"available","panes":[{"session_name":"TMUX--homelab","pane_id":"%0","pane_pid":"100"},{"session_name":"TMUX--cctrl","pane_id":"%15","pane_pid":"3338"}]}
JSON
    jq -n --arg s "$started" --arg id "$codex_id" '{status:"available",source_cursor:"c",processes:[
        {pid:100,ppid:1,started:$s,command:"bash session-wrapper.sh claude"},
        {pid:101,ppid:100,started:$s,command:"claude --resume live-id"},
        {pid:3338,ppid:1,started:$s,command:"bash session-wrapper.sh codex"},
        {pid:3339,ppid:3338,started:$s,command:("codex resume --yolo " + $id)}]}' > "$root/process.json"
    printf '{"pid":101,"sessionId":"live-id"}\n' > "$sessions/101.json"
    jq -n --arg id "$codex_id" '{records:[{provider_task_id:$id,sources:{app_server:{status:"confirmed-absence"}}}]}' > "$root/codex.json"

    before="$(cat "$f_old" "$f_stale" "$f_codex" | shasum -a 256)"
    out="$(resolve_env "$ROOT/cctrl" task resolve-conflicts --json)" || fail "resolve-conflicts dry run failed: $out"
    jq -e '.apply==false and .counts.close==2 and .counts.own==1 and
           any(.rows[]; .provider_task_id=="old-id" and .reason=="superseded-by live-id") and
           any(.rows[]; .provider_task_id=="stale-id" and .reason=="stale-anchor") and
           any(.rows[]; .provider_task_id=="live-id" and .action=="none")' <<< "$out" >/dev/null \
        || fail "resolve-conflicts dry run planned the wrong actions: $out"
    [[ "$before" == "$(cat "$f_old" "$f_stale" "$f_codex" | shasum -a 256)" ]] || fail "resolve-conflicts dry run wrote the registry"

    out="$(resolve_env "$ROOT/cctrl" task resolve-conflicts --apply --json)" || fail "resolve-conflicts --apply failed: $out"
    jq -e '[.applied[].apply_status] == ["applied","applied","applied"]' <<< "$out" >/dev/null \
        || fail "resolve-conflicts did not apply every supported action: $(jq -c '.applied' <<< "$out")"
    jq -e '.lifecycle_state=="closed" and any(.ownership_evidence[]; .source=="cctrl-resolve")' "$f_old" >/dev/null \
        || fail "superseded record was not closed"
    [[ "$(jq -r '.lifecycle_state' "$f_stale")" == closed ]] || fail "stale-anchor record was not closed"
    jq -e '.control_owner=="cctrl" and .execution_runtime=="tmux" and .lifecycle_state=="active"' "$f_codex" >/dev/null \
        || fail "live Codex owner was not restored: $(jq -c '{control_owner,execution_runtime,lifecycle_state}' "$f_codex")"
    jq -e '.control_owner=="cctrl" and .lifecycle_state=="active"' "$f_live" >/dev/null || fail "the live record was changed"

    # Without App Server evidence a Codex conflict is left alone.
    local f_codex2; f_codex2="$(anchored TMUX--cctrl2 01a0bde3-91f6-7643-8593-bdca02fb5f7d codex %17 5429 conflict conflict active)"
    printf '{"records":[]}\n' > "$root/codex.json"
    jq '.panes += [{"session_name":"TMUX--cctrl2","pane_id":"%17","pane_pid":"5429"}]' "$root/panes.json" > "$root/p.tmp" && mv "$root/p.tmp" "$root/panes.json"
    out="$(resolve_env "$ROOT/cctrl" task resolve-conflicts --apply --json)" || true
    [[ "$(jq -r '.control_owner' "$f_codex2")" == conflict ]] || fail "a Codex conflict was resolved without App Server evidence"

    # The digest guard: a transition decided against an older digest is refused.
    rc=0
    # shellcheck disable=SC2016 # positional arguments belong to the sourced shell
    resolve_env cctrl_source_eval '_task_record_transition_file "$1" TMUX--homelab unknown unknown closed "" cctrl-resolve authoritative stale "$2"' \
        "$f_live" "0000000000000000000000000000000000000000000000000000000000000000" || rc=$?
    [[ "$rc" -eq 75 ]] || fail "a digest-mismatched transition was not refused with 75 (rc=$rc)"
    [[ "$(jq -r '.lifecycle_state' "$f_live")" == active ]] || fail "a digest-mismatched transition wrote the record"
    echo "ok: resolve-conflicts is dry-run by default, evidence-gated, and digest-guarded"
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
    rg -q '^_task_registry_reduce_files\(\)' "$ROOT/cctrl" || fail "pure registry reducer boundary is missing"
    local update transition direct_rewrite
    update="$(awk '/^_session_update_metadata_field\(\)/,/^}/' "$ROOT/cctrl")"
    transition="$(awk '/^_task_record_transition\(\)/,/^}/' "$ROOT/cctrl")"
    [[ "$transition" == *'_task_record_transition_file'* ]] || fail "session-name transition bypasses the exact-file transition"
    transition="$(awk '/^_task_record_transition_file\(\)/,/^}/' "$ROOT/cctrl")"
    [[ "$update" == *'_task_registry_apply_event'* && "$transition" == *'_task_registry_apply_event'* ]] \
        || fail "schema-v2 metadata writers bypass the task registry boundary"
    direct_rewrite="mv \"\$tmp\" \"\$file\""
    [[ "$update" != *"$direct_rewrite"* && "$transition" != *"$direct_rewrite"* ]] \
        || fail "ad-hoc schema-v2 rewrite remains outside the registry"
    echo "ok: schema-v2 metadata and transition writers route through the single registry API"
}

test_codex_reconcile_ownership_evidence() {
    local root="$TMPDIR/codex-reconcile" data="$TMPDIR/codex-reconcile/data"
    local meta_a="$TMPDIR/codex-reconcile/meta-a" meta_b="$TMPDIR/codex-reconcile/meta-b"
    local codex_home="$TMPDIR/codex-reconcile/codex" app="$TMPDIR/codex-reconcile/app.json"
    local tmux_snapshot="$TMPDIR/codex-reconcile/tmux.json" process_snapshot="$TMPDIR/codex-reconcile/process.json"
    local host="11111111111111111111111111111111" before after dry default invalid rc=0
    rm -rf "$root"; mkdir -p "$data" "$meta_a" "$codex_home/thread-writer-locks"
    printf '%s\n' "$host" > "$data/host-id"

    python3 - "$meta_a" "$host" <<'PY'
import hashlib,json,sys
from pathlib import Path
root,host=Path(sys.argv[1]),sys.argv[2]
def add(task, owner="unknown", runtime="unknown", *, tmux=None, launched=False, origin="unknown", lineage=None, anchored=True):
    record={
      "schema_version":2,"provider":"codex","provider_task_id":task,"origin":origin,"host_id":host,
      "registered_by_cctrl":True,"launched_by_cctrl":launched,"execution_runtime":runtime,
      "control_owner":owner,"lifecycle_state":"active" if owner != "unknown" else "unknown",
      "restore_strategy":"tmux" if runtime == "tmux" else "provider-managed" if runtime == "app-server" else None,
      "last_observed_at":"2026-09-16T09:00:00Z","tmux_session":tmux,
      "lineage":lineage or {"forked_from_id":None,"parent_thread_id":None,"derived_root_id":None,"derived_root_basis":None},
      "ownership_evidence":[],"conversation_id":task,"control_surface":"tmux" if runtime == "tmux" else "app" if runtime == "app-server" else "unknown"
    }
    if tmux and anchored:
        record.update({"pane_id":"%1","pane_pid":"4100" if task == "tmux-task" else "4200"})
    raw=("codex\0"+host+"\0"+task).encode()
    key="task-"+hashlib.sha256(raw).hexdigest()
    (root/(key+".json")).write_text(json.dumps(record,sort_keys=True,indent=2)+"\n")
add("tmux-task",tmux="TMUX--one",launched=True,origin="cctrl")
add("unanchored-task",tmux="TMUX--legacy",launched=True,origin="cctrl",anchored=False)
add("app-task",origin="codex-app")
add("conflict-task",tmux="TMUX--two",launched=True,origin="cctrl")
add("ambiguous-task",owner="cctrl",runtime="tmux",origin="cctrl")
add("unavailable-task",owner="app",runtime="app-server",origin="codex-app")
add("direct-task",origin="external-cli")
add("stale-lock-task",origin="unknown")
add("fork-task",origin="codex-app",lineage={"forked_from_id":"fork-parent","parent_thread_id":None,"derived_root_id":"fork-root","derived_root_basis":"forked-from-traversal"})
PY
    cp -R "$meta_a" "$meta_b"
    : > "$codex_home/thread-writer-locks/stale-lock-task.lock"
    cat > "$app" <<'JSON'
{"schema_version":1,"status":"available","complete":true,"observed_at":"2026-09-17T10:00:00Z","source_cursor":"app-cursor-1","threads":[{"id":"unanchored-task","control_owner":"app"},{"id":"tmux-task","source":"appServer"},{"id":"app-task","control_owner":"app"},{"id":"conflict-task","control_owner":"app"},{"id":"ambiguous-task","source":"appServer"},{"id":"fork-task","executionRuntime":"app-server","runtimeState":"active"}],"task_errors":{"unavailable-task":{"reason":"thread/read timed out"}},"errors":[]}
JSON
    cat > "$tmux_snapshot" <<'JSON'
{"schema_version":1,"status":"available","observed_at":"2026-09-17T10:00:00Z","source_cursor":"tmux-cursor-1","panes":[{"session":"TMUX--one","pane_id":"%1","pane_pid":"4100","start_command":"codex","current_command":"codex"},{"session":"TMUX--two","pane_id":"%1","pane_pid":"4200","start_command":"codex","current_command":"codex"},{"session":"TMUX--legacy","pane_id":"%9","pane_pid":"4900","start_command":"codex","current_command":"codex"}],"error":null}
JSON
    cat > "$process_snapshot" <<'JSON'
{"schema_version":1,"status":"available","observed_at":"2026-09-17T10:00:00Z","source_cursor":"process-cursor-1","processes":[{"pid":5000,"ppid":1,"started":"Wed Sep 17 10:00:00 2026","command":"codex resume direct-task"}],"error":null}
JSON

    tree_hash() {
        python3 - "$1" <<'PY'
import hashlib,sys
from pathlib import Path
root=Path(sys.argv[1]); h=hashlib.sha256()
for p in sorted(root.rglob("*")):
    if p.is_file() and not p.is_symlink(): h.update(str(p.relative_to(root)).encode()+b"\0"+p.read_bytes())
print(h.hexdigest())
PY
    }
    before="$(tree_hash "$meta_a")"
    dry="$(CCTRL_SESSION_METADATA_DIR="$meta_a" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        CODEX_HOME="$codex_home" CCTRL_CODEX_RECONCILE_APP_SERVER_FILE="$app" \
        CCTRL_CODEX_RECONCILE_TMUX_FILE="$tmux_snapshot" CCTRL_CODEX_RECONCILE_PROCESS_FILE="$process_snapshot" \
        CCTRL_CODEX_RECONCILE_PASS_ID="fixture-pass-0001" CCTRL_CODEX_RECONCILE_OBSERVED_AT="2026-09-17T10:00:00Z" \
        "$ROOT/cctrl" session reconcile-codex --dry-run --json)"
    after="$(tree_hash "$meta_a")"
    [[ "$before" == "$after" ]] || fail "reconcile-codex --dry-run wrote registry state"

    default="$(CCTRL_SESSION_METADATA_DIR="$meta_b" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        CODEX_HOME="$codex_home" CCTRL_CODEX_RECONCILE_APP_SERVER_FILE="$app" \
        CCTRL_CODEX_RECONCILE_TMUX_FILE="$tmux_snapshot" CCTRL_CODEX_RECONCILE_PROCESS_FILE="$process_snapshot" \
        CCTRL_CODEX_RECONCILE_PASS_ID="fixture-pass-0001" CCTRL_CODEX_RECONCILE_OBSERVED_AT="2026-09-17T10:00:00Z" \
        "$ROOT/cctrl" session reconcile-codex --json)"
    [[ "$dry" == "$default" ]] || fail "dry-run and default proposed documents differ"
    jq -e '
      .schema_version == 1 and .kind == "codex_reconcile_result_v1" and .pass_id == "fixture-pass-0001" and
      ([.records[] | select(.provider_task_id == "tmux-task")][0].chosen_outcome.control_owner == "cctrl") and
      ([.records[] | select(.provider_task_id == "unanchored-task")][0].chosen_outcome.control_owner == "unknown") and
      ([.records[] | select(.provider_task_id == "unanchored-task")][0].sources.tmux.status == "ambiguous") and
      ([.records[] | select(.provider_task_id == "unanchored-task")][0].sources.app_server.status == "claimed") and
      ([.records[] | select(.provider_task_id == "tmux-task")][0].sources.app_server.status == "ambiguous") and
      ([.records[] | select(.provider_task_id == "app-task")][0].sources.tmux.status == "confirmed-absence") and
      ([.records[] | select(.provider_task_id == "app-task")][0].chosen_outcome.control_owner == "app") and
      ([.records[] | select(.provider_task_id == "conflict-task")][0].chosen_outcome.control_owner == "conflict") and
      ([.records[] | select(.provider_task_id == "ambiguous-task")][0].chosen_outcome.control_owner == "unknown") and
      ([.records[] | select(.provider_task_id == "unavailable-task")][0].chosen_outcome.control_owner == "app") and
      ([.records[] | select(.provider_task_id == "direct-task")][0].chosen_outcome.control_owner == "unknown") and
      ([.records[] | select(.provider_task_id == "stale-lock-task")][0].chosen_outcome.control_owner == "unknown") and
      ([.records[] | .expected_record_digest] | all(test("^[0-9a-f]{64}$"))) and
      ([.records[].sources | keys] | all(. == ["app_server","process_table","registry","tmux","writer_locks"]))
    ' <<< "$default" >/dev/null || fail "reconcile-codex truth table/result schema is wrong: $default"

    python3 - "$meta_b" <<'PY'
import json,sys
from pathlib import Path
records={}
for path in Path(sys.argv[1]).glob("task-*.json"):
    value=json.loads(path.read_text()); records[value["provider_task_id"]]=value
assert (records["tmux-task"]["control_owner"],records["tmux-task"]["execution_runtime"]) == ("cctrl","tmux")
assert (records["app-task"]["origin"],records["app-task"]["control_owner"],records["app-task"]["execution_runtime"]) == ("codex-app","app","app-server")
assert records["conflict-task"]["control_owner"] == "conflict"
assert records["unanchored-task"]["control_owner"] == "unknown"
assert records["ambiguous-task"]["control_owner"] == "unknown"
assert records["unavailable-task"]["control_owner"] == "app"
assert records["fork-task"]["origin"] == "codex-app"
assert records["fork-task"]["lineage"] == {"forked_from_id":"fork-parent","parent_thread_id":None,"derived_root_id":"fork-root","derived_root_basis":"forked-from-traversal"}
for value in records.values():
    evidence=value["last_reconcile"]
    assert evidence["pass_id"] == "fixture-pass-0001"
    assert evidence["expected_record_digest"]
    assert evidence["sources"]
PY
    [[ -e "$codex_home/thread-writer-locks/stale-lock-task.lock" ]] || fail "reconciliation removed a diagnostic writer lock"

    # A malformed source aborts before the first registry event is applied.
    invalid="$root/invalid.json"; printf '[]\n' > "$invalid"
    before="$(tree_hash "$meta_a")"; rc=0
    CCTRL_SESSION_METADATA_DIR="$meta_a" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        CODEX_HOME="$codex_home" CCTRL_CODEX_RECONCILE_APP_SERVER_FILE="$app" \
        CCTRL_CODEX_RECONCILE_TMUX_FILE="$invalid" CCTRL_CODEX_RECONCILE_PROCESS_FILE="$process_snapshot" \
        CCTRL_CODEX_RECONCILE_PASS_ID="fixture-pass-0002" CCTRL_CODEX_RECONCILE_OBSERVED_AT="2026-09-17T10:01:00Z" \
        "$ROOT/cctrl" session reconcile-codex --json >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 65 ]] || fail "invalid complete snapshot did not exit 65 (rc=$rc)"
    [[ "$before" == "$(tree_hash "$meta_a")" ]] || fail "failed snapshot partially mutated registry"
    echo "ok: Codex reconciliation is exact-id, single-snapshot, non-destructive, CAS-guarded, and dry-run identical"
}

test_task_inventory_provider_neutral_readonly() {
    local root="$TMPDIR/task-inventory" data="$TMPDIR/task-inventory/data" meta="$TMPDIR/task-inventory/meta"
    local codex_home="$TMPDIR/task-inventory/codex" bin="$TMPDIR/task-inventory/bin"
    local host="22222222222222222222222222222222" before after out apps all_apps unavailable rc=0
    rm -rf "$root"; mkdir -p "$data" "$meta" "$codex_home/thread-writer-locks" "$bin"
    printf '%s\n' "$host" > "$data/host-id"
    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then shift; fi
case "${1:-}" in
  list-sessions)
    printf '$1\037TMUX--owned\0371770000000\n$2\037TMUX--shared\0371770000001\n$3\037TMUX--recycled\0371770000002\n$4\037plain-shell\0371770000003\n$5\037TMUX--unanchored\0371770000004\n'
    ;;
  list-panes)
    if [[ "$*" == *pane_current_path* ]]; then printf '/tmp/shared\n'; else printf '%%1\037100\n'; fi
    ;;
  *) exit 0 ;;
esac
SH
    chmod +x "$bin/tmux"
    python3 - "$meta" "$codex_home/state_5.sqlite" "$host" <<'PY'
import hashlib,json,sqlite3,sys
from pathlib import Path
root,db,host=Path(sys.argv[1]),sys.argv[2],sys.argv[3]
def add(name, task, owner="unknown", runtime="unknown", state="unknown", *, tmux=None, pane=None, pid=None, archived=False, launch=None):
    record={"schema_version":2,"provider":"codex","provider_task_id":task,"origin":"cctrl","host_id":host,
      "registered_by_cctrl":True,"launched_by_cctrl":True,"execution_runtime":runtime,"control_owner":owner,
      "lifecycle_state":state,"restore_strategy":"tmux" if runtime=="tmux" else "provider-managed" if runtime=="app-server" else None,
      "last_observed_at":"2026-09-17T10:00:00Z","tmux_session":tmux,"provisional_launch_id":launch,
      "lineage":{"forked_from_id":None,"parent_thread_id":None,"derived_root_id":None,"derived_root_basis":None},
      "ownership_evidence":[],"cwd":"/tmp/shared","display_label":name,"name":tmux,"pane_id":pane,"pane_pid":pid}
    if task:
        filename="task-"+hashlib.sha256(("codex\0"+host+"\0"+task).encode()).hexdigest()+".json"
    else:
        filename="launch-"+launch+".json"
    (root/filename).write_text(json.dumps(record,sort_keys=True)+"\n")
add("owned","owned-task","cctrl","tmux","active",tmux="TMUX--owned",pane="%1",pid="100")
add("app","app-task","app","app-server","released")
add("unknown","unknown-task")
add("locked","lock-task")
add("archive","archive-task","app","app-server","archived")
add("conflict-a","conflict-a","cctrl","tmux","active",tmux="TMUX--shared",pane="%1",pid="100")
add("conflict-b","conflict-b","cctrl","tmux","active",tmux="TMUX--shared",pane="%1",pid="100")
add("stale","stale-task","cctrl","tmux","active",tmux="TMUX--recycled",pane="%9",pid="900")
add("unanchored","unanchored-task","cctrl","tmux","active",tmux="TMUX--unanchored")
add("provisional",None,"cctrl","tmux","provisional",tmux="TMUX--not-live",launch="launch-064")
con=sqlite3.connect(db)
con.execute("CREATE TABLE threads (id TEXT PRIMARY KEY,title TEXT,cwd TEXT,archived INTEGER,updated_at TEXT)")
for task,title,archived in [
 ("owned-task","Owned",0),("app-task","App",0),("unknown-task","Unknown",0),("lock-task","Locked",0),
 ("archive-task","Archived",1),("conflict-a","Conflict A",0),("conflict-b","Conflict B",0),
 ("stale-task","Stale",0),("unanchored-task","Unanchored",0),("discovery-a","Discovery A",0),("discovery-b","Discovery B",0)]:
    con.execute("INSERT INTO threads VALUES (?,?,?,?,?)",(task,title,"/tmp/shared",archived,"2026-09-17T11:00:00Z"))
con.commit(); con.close()

bad_task="invalid-schema-task"
bad={"schema_version":2,"provider":"codex","provider_task_id":bad_task,"origin":"cctrl","host_id":host,
  "registered_by_cctrl":True,"launched_by_cctrl":True,"execution_runtime":"tmux","control_owner":"definitely-not-an-owner",
  "lifecycle_state":"active","restore_strategy":"tmux","last_observed_at":"2026-09-17T10:00:00Z","tmux_session":None,
  "lineage":{"forked_from_id":None,"parent_thread_id":None,"derived_root_id":None,"derived_root_basis":None},"ownership_evidence":[]}
bad_name="task-"+hashlib.sha256(("codex\0"+host+"\0"+bad_task).encode()).hexdigest()+".json"
(root/bad_name).write_text(json.dumps(bad)+"\n")
PY
    cat > "$meta/TMUX--legacy-owned.json" <<'JSON'
{"name":"TMUX--legacy-owned","agent":"codex","conversation_id":"owned-task","cctrl_managed":true,"created_at":"2026-09-16T10:00:00Z","cwd":"/tmp/wrong-alias"}
JSON
    cat > "$meta/legacy-dup-a.json" <<'JSON'
{"name":"legacy-a","agent":"codex","conversation_id":"legacy-dup-task","cctrl_managed":false,"created_at":"2026-09-16T10:00:00Z","cwd":"/tmp/one"}
JSON
    cat > "$meta/legacy-dup-b.json" <<'JSON'
{"name":"legacy-b","agent":"codex","conversation_id":"legacy-dup-task","cctrl_managed":false,"created_at":"2026-09-16T10:00:01Z","cwd":"/tmp/two"}
JSON
    : > "$codex_home/thread-writer-locks/lock-task.lock"
    printf '{bad json\n' > "$meta/malformed.json"

    tree_hash() {
        python3 - "$1" <<'PY'
import hashlib,sys
from pathlib import Path
root=Path(sys.argv[1]); digest=hashlib.sha256()
for path in sorted(root.rglob("*")):
    if path.is_file() and not path.is_symlink():
        digest.update(str(path.relative_to(root)).encode()+b"\0"+path.read_bytes())
print(digest.hexdigest())
PY
    }
    before="$(tree_hash "$root")"
    out="$(PATH="$bin:$PATH" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        CCTRL_SESSION_METADATA_DIR="$meta" CODEX_HOME="$codex_home" CCTRL_CODEX_STATE_DB="$codex_home/state_5.sqlite" \
        "$ROOT/cctrl" task ls --json)"
    after="$(tree_hash "$root")"
    [[ "$before" == "$after" ]] || fail "task inventory mutated metadata or provider state"
    jq -e '
      .schema_version == 2 and .host_id_initialized == false and
      (.capabilities.handoff == {supported:false,reason:"not-implemented"}) and
      (.capabilities.cctrl_restore == {supported:false,reason:"not-implemented"}) and
      ([.rows[] | select(.provider_task_id=="owned-task")][0].action_capabilities.tmux_attach == {supported:true,reason:"available"}) and
      ([.rows[] | select(.provider_task_id=="owned-task")][0].action_capabilities.app_open == {supported:false,reason:"owned-by-cctrl"}) and
      ([.rows[] | select(.provider_task_id=="app-task")][0].action_capabilities.app_open == {supported:true,reason:"available"}) and
      ([.rows[] | select(.provider_task_id=="archive-task")][0].action_capabilities.app_open == {supported:false,reason:"archived"}) and
      ([.rows[] | select(.provider_task_id=="discovery-a")][0].registered_by_cctrl == false) and
      ([.rows[] | select(.provider_task_id=="discovery-a")][0].lifecycle_state == "unknown") and
      ([.rows[] | select(.provider_task_id=="discovery-a")][0].action_capabilities.app_open == {supported:false,reason:"unknown"}) and
      ([.rows[] | select(.provider_task_id=="lock-task")][0].control_owner == "unknown") and
      ([.rows[] | select(.provider_task_id=="lock-task")][0].diagnostic_evidence | any(.source=="codex-writer-lock")) and
      ([.rows[] | select(.provider_task_id=="conflict-b")][0].lifecycle_state == "conflict") and
      ([.rows[] | select(.provider_task_id=="stale-task")][0].lifecycle_state == "conflict") and
      ([.rows[] | select(.provider_task_id=="legacy-dup-task")][0].lifecycle_state == "conflict") and
      ([.rows[] | select(.provider_task_id=="invalid-schema-task")] | length == 0) and
      ([.rows[] | select(.provider_task_id=="unanchored-task")][0].action_capabilities.tmux_attach.supported == false) and
      ([.rows[] | select(.provider_task_id=="unanchored-task")][0].diagnostic_evidence | any(.reason=="unanchored-explicit-link")) and
      ([.rows[] | select(.task_key | startswith("launch:"))] | length == 1) and
      ([.rows[] | select(.task_key | startswith("tmux:"))] | length == 3) and
      ([.rows[] | select(.cwd=="/tmp/shared" and .provider_task_id != null)] | length >= 10) and
      (.source_errors | any(.source=="registry" and (.error|startswith("invalid-json:")))) and
      (.source_errors | any(.source=="registry" and .error=="invalid-control-owner")) and
      (all(.rows[]; has("title"))) and
      ([.rows[].action_capabilities | keys] | all(. == ["app_open","cctrl_restore","handoff","tmux_attach"]))
    ' <<< "$out" >/dev/null || fail "task inventory schema, fusion, state, or capability truth table is wrong: $out"

    apps="$(PATH="$bin:$PATH" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        CCTRL_SESSION_METADATA_DIR="$meta" CODEX_HOME="$codex_home" CCTRL_CODEX_STATE_DB="$codex_home/state_5.sqlite" \
        "$ROOT/cctrl" session app-ls --json)"
    all_apps="$(PATH="$bin:$PATH" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        CCTRL_SESSION_METADATA_DIR="$meta" CODEX_HOME="$codex_home" CCTRL_CODEX_STATE_DB="$codex_home/state_5.sqlite" \
        "$ROOT/cctrl" session app-ls --all --json)"
    jq -e 'all(.[]; .registered_by_cctrl == true and .lifecycle_state != "archived") and (any(.[]; .session_id=="app-task"))' <<< "$apps" >/dev/null \
        || fail "app-ls default is not the registered Codex task filter"
    jq -e 'any(.[]; .session_id=="discovery-a") and any(.[]; .session_id=="archive-task")' <<< "$all_apps" >/dev/null \
        || fail "app-ls --all omitted discovery-only or archived tasks"
    local human_apps human_all_apps
    human_apps="$(PATH="$bin:$PATH" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        CCTRL_SESSION_METADATA_DIR="$meta" CODEX_HOME="$codex_home" CCTRL_CODEX_STATE_DB="$codex_home/state_5.sqlite" \
        "$ROOT/cctrl" session app-ls)"
    human_all_apps="$(PATH="$bin:$PATH" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        CCTRL_SESSION_METADATA_DIR="$meta" CODEX_HOME="$codex_home" CCTRL_CODEX_STATE_DB="$codex_home/state_5.sqlite" \
        "$ROOT/cctrl" session app-ls --all)"
    [[ "$human_apps" == *"app-owned"* && "$human_apps" == *"cctrl-owned"* && "$human_apps" == *"conflict"* && "$human_apps" == *"unknown"* ]] \
        || fail "app-ls human mode did not render ownership-derived states: $human_apps"
    [[ "$human_all_apps" == *"archived"* ]] || fail "app-ls --all human mode omitted archived state"

    rm -f "$codex_home/state_5.sqlite"
    unavailable="$(PATH="$bin:$PATH" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        CCTRL_SESSION_METADATA_DIR="$meta" CODEX_HOME="$codex_home" CCTRL_CODEX_STATE_DB="$codex_home/state_5.sqlite" \
        "$ROOT/cctrl" task ls --json)"
    jq -e '(.rows|length)>0 and .source_status.codex_provider=="unavailable" and ([.rows[]|select(.provider_task_id=="app-task")][0].action_capabilities.app_open.reason=="provider-unavailable")' <<< "$unavailable" >/dev/null \
        || fail "provider source failure erased healthy rows or did not close capabilities"

    local first_data="$root/first-data" first_meta="$root/first-meta" first_codex="$root/first-codex"
    mkdir -p "$first_meta" "$first_codex"
    PATH="$bin:$PATH" CCTRL_DATA_DIR="$first_data" CCTRL_HOST_ID_FILE="$first_data/host-id" \
        CCTRL_SESSION_METADATA_DIR="$first_meta" CODEX_HOME="$first_codex" CCTRL_CODEX_STATE_DB="$first_codex/missing.sqlite" \
        "$ROOT/cctrl" task ls --json > "$root/first.json"
    [[ -f "$first_data/host-id" ]] || fail "task inventory did not initialize durable host id"
    jq -e '.host_id_initialized==true' "$root/first.json" >/dev/null || fail "host-id initialization was not reported"

    local bad_meta="$root/not-a-directory" failbin="$root/failbin"
    printf x > "$bad_meta"; mkdir -p "$failbin"
    cat > "$failbin/tmux" <<'SH'
#!/usr/bin/env bash
exit 9
SH
    chmod +x "$failbin/tmux"
    rc=0
    PATH="$failbin:$PATH" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        CCTRL_SESSION_METADATA_DIR="$bad_meta" CODEX_HOME="$first_codex" CCTRL_CODEX_STATE_DB="$first_codex/missing.sqlite" \
        "$ROOT/cctrl" task ls --json >/dev/null || rc=$?
    [[ "$rc" -eq 69 ]] || fail "total source failure should exit 69, got $rc"
    rc=0
    PATH="$failbin:$PATH" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        CCTRL_SESSION_METADATA_DIR="$bad_meta" CODEX_HOME="$first_codex" CCTRL_CODEX_STATE_DB="$first_codex/missing.sqlite" \
        "$ROOT/cctrl" session app-ls --json >/dev/null || rc=$?
    [[ "$rc" -eq 69 ]] || fail "app-ls JSON swallowed total source failure (rc=$rc)"
    rc=0
    PATH="$failbin:$PATH" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
        CCTRL_SESSION_METADATA_DIR="$bad_meta" CODEX_HOME="$first_codex" CCTRL_CODEX_STATE_DB="$first_codex/missing.sqlite" \
        "$ROOT/cctrl" session app-ls >/dev/null || rc=$?
    [[ "$rc" -eq 69 ]] || fail "app-ls human mode swallowed total source failure (rc=$rc)"
    echo "ok: task inventory is provider-neutral, stable-identity fused, capability explicit, partial, and read-only"
}


# ── Plan 100 phase 2: names, labels, the one-fleet-manager guard ───────────
# Same rules as phase 1: a rootcopy of cctrl, the fake tmux (TMUX_FAKE_STATE
# says which sessions are live), stdin from /dev/null. The guard's lock lives
# in the sandbox registry dir, never in a real one.

_p2_setup() {
    # args: tag shortcuts-json
    _rf_setup "$@"
    P2_STATE="$TMPDIR/p2-$1.state"; : > "$P2_STATE"; P2_N=0
    rm -rf "$CCTRL_SESSION_METADATA_DIR/.fleet-manager-codex.lock" "$CCTRL_SESSION_METADATA_DIR/.fleet-manager-claude.lock"
}
_p2_ok() {
    # args: message command... -> runs the command, its output lands in the caller's $out
    local msg="$1" rc=0
    shift
    out="$("$@")" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "$msg ($rc): $out"
}
_p2_live() { local n; for n in "$@"; do P2_N=$((P2_N + 1)); printf '$%s:%s\n' "$P2_N" "$n" >> "$P2_STATE"; done; }
_p2() { TMUX_FAKE_STATE="$P2_STATE" _rf "$@"; }
_p2_new_name() { grep -o 'new-session -d -s [^ ]*' "$1" | tail -n 1 | awk '{print $NF}'; }
_p2_new_count() { grep -c 'new-session -d -s' "$RF_LOG" || true; }
_p2_record() {
    # args: session role kind agent -> a record for a session this test calls live
    CCTRL_HOST_PREFIX=ms cctrl_source_eval '_session_write_metadata "$1" /tmp @x @x @x p "" cmd "" "$4" "conv-p2-${1//[^a-z0-9]/-}" "" "" "" "" "" "" "" "$2" "$3"' "$1" "$2" "$3" "$4" \
        || fail "fixture record for $1 could not be written"
}
_p2_fleet_live() {
    # Launch a fleet manager through the real launcher, then mark it live.
    local out
    _p2_ok "first fleet manager did not launch" _p2 start -d --agent codex --orch-kind fleet "$RF_PROJ"
    P2_FLEET="$(_rf_session "$out")"
    _p2_live "$P2_FLEET"
}
_p2_lock() {
    # args: runtime created-epoch pid-or-empty
    local d="$CCTRL_SESSION_METADATA_DIR/.fleet-manager-$1.lock"
    mkdir -p "$d"
    printf '%s\n' "$2" > "$d/created"
    [[ -n "$3" ]] && printf '%s\n' "$3" > "$d/pid"
    return 0
}
_p2_lock_dir() { printf '%s/.fleet-manager-%s.lock' "$CCTRL_SESSION_METADATA_DIR" "$1"; }

test_fleet_orchestrator_name_and_star_label() {
    _p2_setup fl1 '{"fm-orchestrator":{"dir":"@P@","role":"orchestrator","orch_kind":"fleet","agent":"codex"}}'
    local out
    out="$(_p2 start -d --agent codex --orch-kind fleet "$RF_PROJ")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--fleet-codex"
    assert_contains "$(cat "$RF_LOG")" "new-session -d -s TMUX--ms--fleet-codex"
    assert_contains "$(cat "$RF_LOG")" "--name TMUX--ms--fleet-codex"
    [[ "$(_rf_field "$out" purpose)" == "★★ fleet manager (codex)" ]] || fail "label: $(_rf_field "$out" purpose)"
    # The same through the @fm-orchestrator key.
    _p2_setup fl1b '{"fm-orchestrator":{"dir":"@P@","role":"orchestrator","orch_kind":"fleet","agent":"codex"}}'
    out="$(_p2 start -d @fm-orchestrator)"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--fleet-codex"
    [[ "$(_rf_field "$out" purpose)" == "★★ fleet manager (codex)" ]] || fail "key label: $(_rf_field "$out" purpose)"
    echo "ok: a fleet manager is fleet-<runtime> with the double-star label"
}

test_repo_orchestrator_name_and_star_label() {
    _p2_setup rp1 '{}'
    local out
    out="$(_p2 start -d --orch-kind repo "$RF_PROJ")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--orch-rf-rp1-proj"
    assert_contains "$(cat "$RF_LOG")" "--name TMUX--ms--orch-rf-rp1-proj"
    [[ "$(_rf_field "$out" purpose)" == "★ orchestrator: rf-rp1-proj" ]] || fail "label: $(_rf_field "$out" purpose)"
    echo "ok: a repo orchestrator is orch-<repo> with the single-star label"
}

test_repo_name_uses_dir_worker_alias_then_stripped_key_then_basename() {
    _p2_setup nm '{}'
    local a="$TMPDIR/p2-names-a" b="$TMPDIR/p2-names-b" c="$TMPDIR/p2-names-c" out
    mkdir -p "$a" "$b" "$c"
    printf '{"walias":{"dir":"%s"},"fm-viaalias":{"dir":"%s","role":"orchestrator","orch_kind":"repo"},"orch-solo":{"dir":"%s","role":"orchestrator","orch_kind":"repo"}}\n' \
        "$a" "$a" "$b" > "$RF_COPY/data/shortcuts.json"
    out="$(_p2 start -d @fm-viaalias)"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--orch-walias"
    out="$(_p2 start -d @orch-solo)"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--orch-solo"
    out="$(_p2 start -d --orch-kind repo "$c")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--orch-p2-names-c"
    out="$(_p2 start -d --orch-kind repo "$a")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--orch-walias"
    echo "ok: the repo name is the dir's worker alias, else the stripped key, else the basename"
}

test_at_legacy_orch_shortcut_launch_gets_orch_name() {
    # Plan 098 regression guard, rewritten by plan 100 phase 1 and again here:
    # an explicit `cctrl @fm-<x>` launch of a repo orchestrator is orch-<x>.
    _rf_setup atfm '{"fm-atfm":{"dir":"@P@","role":"orchestrator","orch_kind":"repo"}}'
    local out
    out="$(_rf start -d --purpose p @fm-atfm)"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--orch-atfm"
    assert_contains "$(cat "$RF_LOG")" "new-session -d -s TMUX--ms--orch-atfm"
    assert_contains "$(cat "$RF_LOG")" "--name TMUX--ms--orch-atfm"
    echo "ok: an explicit @fm-<x> repo orchestrator launch is named orch-<x>"
}

_p2_restore_row_run() {
    # args: dir flags-json -> runs a real restore of the cctrl row with those launch_flags
    local dir="$1"
    _restore_role_fixture "$dir"
    jq --argjson f "$2" '(.tasks[] | select(.tmux_session=="TMUX--cctrl") | .launch_flags) += $f' \
        "$dir/snapshots/latest.json" > "$dir/snap.tmp" && mv "$dir/snap.tmp" "$dir/snapshots/latest.json"
    if [[ -n "${P2_ROW_TMUX:-}" ]]; then
        jq --arg n "$P2_ROW_TMUX" '(.tasks[] | select(.tmux_session=="TMUX--cctrl") | .tmux_session) = $n' \
            "$dir/snapshots/latest.json" > "$dir/snap.tmp" && mv "$dir/snap.tmp" "$dir/snapshots/latest.json"
        jq --arg n "$P2_ROW_TMUX" '(.rows[] | select(.tmux_session=="TMUX--cctrl") | .tmux_session) = $n' \
            "$dir/catalogue.json" > "$dir/cat.tmp" && mv "$dir/cat.tmp" "$dir/catalogue.json"
    fi
    local rrc=0
    P2_RESTORE_OUT="$(TMUX_LOG="$dir/tmux.log" CCTRL_DEVICE_TAG=ms TMUX_FAKE_STATE="${3:-}" \
        _restore_run_real "$dir" --only cctrl --yes 2>&1 </dev/null)" || rrc=$?
    [[ "$rrc" -eq 0 ]] || fail "restore failed ($rrc): $P2_RESTORE_OUT"
    P2_RESTORE_NAME="$(_p2_new_name "$dir/tmux.log")"
}

test_unknown_kind_orchestrator_keeps_worker_name() {
    local dir="$TMPDIR/p2-restore-unknown"
    P2_ROW_TMUX=TMUX--ms--work _p2_restore_row_run "$dir" '{"role":"orchestrator"}'
    [[ "$P2_RESTORE_NAME" == TMUX--ms--work ]] || fail "unknown kind must keep its recorded name, got: $P2_RESTORE_NAME"
    echo "ok: an orchestrator of unknown kind keeps its recorded name"
}

test_orchestrator_ignores_prompt_derived_label() {
    _p2_setup pl '{}'
    local out
    out="$(_p2 start -d --orch-kind repo "$RF_PROJ" -- fix the flaky login test in the billing module today)"
    [[ "$(_rf_field "$out" purpose)" == "★ orchestrator: rf-pl-proj" ]] || fail "label: $(_rf_field "$out" purpose)"
    echo "ok: an orchestrator never takes a prompt-derived label"
}

test_orchestrator_explicit_label_gets_glyph_once() {
    _p2_setup gl '{}'
    local out
    out="$(_p2 start -d --orch-kind repo -n "release train" "$RF_PROJ")"
    [[ "$(_rf_field "$out" purpose)" == "★ release train" ]] || fail "plain -n: $(_rf_field "$out" purpose)"
    out="$(_p2 start -d --orch-kind repo --purpose "★ already starred" "$RF_PROJ")"
    [[ "$(_rf_field "$out" purpose)" == "★ already starred" ]] || fail "starred: $(_rf_field "$out" purpose)"
    out="$(_p2 start -d --orch-kind repo --purpose "☆ hollow star" "$RF_PROJ")"
    [[ "$(_rf_field "$out" purpose)" == "☆ hollow star" ]] || fail "hollow: $(_rf_field "$out" purpose)"
    out="$(_p2 start -d --agent codex --orch-kind fleet -n "the manager" "$RF_PROJ")"
    [[ "$(_rf_field "$out" purpose)" == "★★ the manager" ]] || fail "fleet: $(_rf_field "$out" purpose)"
    echo "ok: an explicit orchestrator label keeps its text and gets the star once"
}

test_rename_adds_glyph_for_known_kind_only() {
    _p2_setup rn '{}'
    local out sess wsess usess
    out="$(_p2 start -d --orch-kind repo "$RF_PROJ")"; sess="$(_rf_session "$out")"
    out="$(_p2 start -d --role worker "$RF_PROJ")"; wsess="$(_rf_session "$out")"
    usess="TMUX--ms--p2-unk"
    _p2_record "$usess" orchestrator "" codex
    _p2_live "$sess" "$wsess" "$usess"
    _p2 rename "$sess" "new words" >/dev/null
    [[ "$(session_record_json "$sess" | jq -r .purpose)" == "★ new words" ]] || fail "known kind: $(session_record_json "$sess" | jq -r .purpose)"
    _p2 rename "$sess" "☆ own glyph" >/dev/null
    [[ "$(session_record_json "$sess" | jq -r .purpose)" == "☆ own glyph" ]] || fail "own glyph was changed"
    _p2 rename "$wsess" "plain worker" >/dev/null
    [[ "$(session_record_json "$wsess" | jq -r .purpose)" == "plain worker" ]] || fail "worker got a glyph"
    _p2 rename "$usess" "unknown kind" >/dev/null
    [[ "$(session_record_json "$usess" | jq -r .purpose)" == "unknown kind" ]] || fail "unknown kind got a glyph"
    echo "ok: rename adds the star for a known-kind orchestrator only"
}

test_replay_keeps_label_verbatim() {
    local dir="$TMPDIR/p2-restore-verbatim"
    P2_ROW_TMUX=TMUX--ms--fm-verbatim _p2_restore_row_run "$dir" '{"role":"orchestrator","orch_kind":"repo"}'
    local rec
    rec="$(grep -l 'conv-aaa-111' "$dir/session-metadata"/*.json 2>/dev/null | head -n 1)"
    [[ -n "$rec" ]] || fail "no record: $(ls "$dir/session-metadata")"
    [[ "$(jq -r .purpose "$rec")" != ★* && "$(jq -r .purpose "$rec")" != ☆* ]] \
        || fail "a replayed label must stay verbatim, got: $(jq -r .purpose "$rec")"
    [[ "$P2_RESTORE_NAME" == TMUX--ms--fm-verbatim ]] || fail "a restore keeps the recorded name, got: $P2_RESTORE_NAME"
    echo "ok: a replayed label is kept verbatim and the name is not re-derived"
}

# ── Plan 100 phase 3: label bookkeeping (D11 known names, D12) ─────────────
# Reconcile runs from the sourced script against the fake tmux, a sandbox
# registry (CCTRL_SESSION_METADATA_DIR) and a fixture transcript. Nothing here
# reaches the real tmux server, registry or ~/.claude.

_p3_setup() {
    # args: tag
    _p2_setup "p3$1" '{}'
    P3_TP="$TMPDIR/p3-$1.jsonl"; : > "$P3_TP"
}

_p3_cc() {
    # args: code args... -> code runs in the sourced script with the transcript seam
    local code="$1"; shift
    TMUX_FAKE_STATE="$P2_STATE" TMUX_LOG="$RF_LOG" PATH="$TMPDIR:$PATH" CCTRL_HOST_PREFIX=ms P3_TP="$P3_TP" \
        cctrl_source_eval '_session_transcript_path() { printf %s "$P3_TP"; }; _session_id() { echo sid-p3; }; '"$code" "$@"
}

_p3_rec() {
    # args: session purpose conv(empty = fresh launch with a set) [role kind]
    CCTRL_HOST_PREFIX=ms cctrl_source_eval '_session_write_metadata "$1" /tmp @x @x @x "$2" "" cmd "" claude "$3" "" "" "" "" "" "" "" "${4:-worker}" "${5:-}"' "$1" "$2" "$3" "${4:-}" "${5:-}" \
        || fail "fixture record for $1 could not be written"
    _p2_live "$1"
}

_p3_title() {
    # args: session label [raw] -> append a custom-title line like the running process does
    local t="$2 ($1)"
    [[ -n "${3:-}" ]] && t="$2"
    jq -nc --arg t "$t" '{type:"custom-title",customTitle:$t,sessionId:"sid-p3"}' >> "$P3_TP"
}

_p3_purpose() { session_record_json "$1" | jq -r '.purpose // empty'; }
_p3_known() { session_record_json "$1" | jq -r '.label_names_known // empty'; }
_p3_rec_conv() { printf 'conv-p3-%s' "${1//[^a-z0-9]/-}"; }
_p3_reconcile() { _p3_cc '_session_reconcile_names "$@"' "$@" 2>&1; }
_p3_rename() { _p3_cc 'cmd_rename "$@"' "$1" "$2" >/dev/null 2>&1 || fail "rename $1 failed"; }
_p3_state_sum() {
    { (cd "$CCTRL_SESSION_METADATA_DIR" && find . -type f ! -path './.task-registry-locks/*' | sort | while read -r f; do echo "$f"; cat "$f"; done)
      cat "$P3_TP"; grep -c 'set-option' "$RF_LOG" || true; } | shasum | awk '{print $1}'
}

test_reconcile_names_legacy_record_without_known_names_is_not_pulled() {
    _p3_setup l1
    local s=TMUX--ms--p3-legacy out
    _p3_rec "$s" "mine" "$(_p3_rec_conv "$s")"
    _p3_title "$s" "something else"
    out="$(_p3_reconcile)"
    [[ "$(_p3_purpose "$s")" == mine ]] || fail "legacy record was pulled: $(_p3_purpose "$s") / $out"
    assert_not_contains "$(cat "$RF_LOG")" "set-option -t =$s: @cctrl_purpose"
    echo "ok: a record with no known-names set is baselined, never pulled"
}

test_reconcile_names_writes_baseline_once() {
    _p3_setup b1
    local s=TMUX--ms--p3-base out
    _p3_rec "$s" "mine" "$(_p3_rec_conv "$s")"
    _p3_title "$s" "older name"; _p3_title "$s" "latest name"
    out="$(_p3_reconcile --json)"
    [[ "$(jq '.baselines | length' <<< "$out")" == 1 ]] || fail "first run should write one baseline: $out"
    jq -e 'index("mine") != null and index("older name") != null and index("latest name") != null' <<< "$(_p3_known "$s")" >/dev/null \
        || fail "baseline must hold purpose and every title: $(_p3_known "$s")"
    local sum; sum="$(_p3_state_sum)"
    out="$(_p3_reconcile --json)"
    [[ "$(jq '.baselines | length' <<< "$out")" == 0 ]] || fail "second run wrote a baseline again: $out"
    [[ "$(_p3_state_sum)" == "$sum" ]] || fail "second run changed state"
    echo "ok: the baseline is written once"
}

test_reconcile_names_does_not_pull_launch_name_restamp() {
    _p3_setup r1
    local s=TMUX--ms--p3-restamp
    _p3_rec "$s" "launch name" ""
    _p3_title "$s" "launch name"
    _p3_rename "$s" "cctrl label"
    _p3_title "$s" "launch name"        # the running process re-stamps its in-memory name
    _p3_reconcile >/dev/null
    [[ "$(_p3_purpose "$s")" == "cctrl label" ]] || fail "launch-name re-stamp was pulled: $(_p3_purpose "$s")"
    echo "ok: a re-stamp of the launch name is not pulled"
}

test_reconcile_names_cctrl_label_stays_after_cctrl_rename() {
    _p3_setup c1
    local s=TMUX--ms--p3-stays
    _p3_rec "$s" "first" ""
    _p3_title "$s" "first"
    _p3_rename "$s" "second"
    _p3_reconcile >/dev/null
    _p3_title "$s" "first"
    _p3_reconcile >/dev/null
    [[ "$(_p3_purpose "$s")" == second ]] || fail "cctrl label did not stay: $(_p3_purpose "$s")"
    echo "ok: cctrl's label wins after cctrl rename"
}

test_reconcile_names_pulls_in_claude_rename_for_worker_and_orchestrator() {
    _p3_setup w1
    local w=TMUX--ms--p3-worker o=TMUX--ms--p3-orch
    _p3_rec "$w" "worker label" ""
    _p3_rec "$o" "★ orch label" "" orchestrator repo
    _p3_title "$w" "worker label"; _p3_title "$o" "★ orch label"
    _p3_reconcile >/dev/null
    _p3_title "$w" "typed in claude"
    _p3_reconcile >/dev/null
    [[ "$(_p3_purpose "$w")" == "typed in claude" ]] || fail "worker not pulled: $(_p3_purpose "$w")"
    assert_contains "$(cat "$RF_LOG")" "set-option -t =$w: @cctrl_purpose typed\\ in\\ claude"
    # the orchestrator session uses its own transcript title
    : > "$P3_TP"; _p3_title "$o" "★ orch label"; _p3_title "$o" "orch typed in claude"
    _p3_reconcile >/dev/null
    [[ "$(_p3_purpose "$o")" == "★ orch typed in claude" ]] || fail "orchestrator not pulled: $(_p3_purpose "$o")"
    echo "ok: a rename made inside Claude is pulled for a worker and an orchestrator"
}

test_reconcile_names_cctrl_rename_after_pull_stays() {
    _p3_setup a1
    local s=TMUX--ms--p3-afterpull
    _p3_rec "$s" "start" ""
    _p3_title "$s" "start"
    _p3_title "$s" "X from claude"
    _p3_reconcile >/dev/null
    [[ "$(_p3_purpose "$s")" == "X from claude" ]] || fail "pull failed: $(_p3_purpose "$s")"
    _p3_rename "$s" "Y from cctrl"
    _p3_title "$s" "X from claude"
    _p3_reconcile >/dev/null
    [[ "$(_p3_purpose "$s")" == "Y from cctrl" ]] || fail "Y was reverted: $(_p3_purpose "$s")"
    echo "ok: a cctrl rename after a pull stays"
}

test_reconcile_names_no_pull_when_baseline_cannot_be_written() {
    _p3_setup n1
    local s=TMUX--ms--p3-nobase out
    _p3_rec "$s" "mine" "$(_p3_rec_conv "$s")"
    _p3_title "$s" "foreign"
    out="$(_p3_cc '_session_names_known_store() { return 1; }; _session_reconcile_names --json')"
    [[ "$(_p3_purpose "$s")" == mine ]] || fail "pulled without a baseline: $(_p3_purpose "$s")"
    [[ "$(jq -r '.corrections' <<< "$out")" == 0 ]] || fail "no correction expected: $out"
    [[ -z "$(_p3_known "$s")" ]] || fail "a set appeared although the store failed"
    echo "ok: no pull when the baseline cannot be written"
}

test_restore_keeps_known_names_and_pulls_nothing() {
    local dir="$TMPDIR/p3-restore-keep" rec
    _restore_role_fixture "$dir"
    # An existing record for the restored conversation, with a known-names set.
    CCTRL_SESSION_METADATA_DIR="$dir/session-metadata" CCTRL_HOST_ID_FILE="$dir/host-id" CCTRL_HOST_PREFIX=ms \
        cctrl_source_eval '_session_write_metadata TMUX--cctrl /tmp @x @x @x "kept label" "" cmd "" claude conv-aaa-111 "" "" "" "" "" "" "" worker "" \
            && _session_update_metadata_field TMUX--cctrl label_names_known "[\"keep me\",\"and me\"]"' \
        || fail "could not seed a record with a set"
    local rout rrc=0
    rout="$(TMUX_LOG="$dir/tmux.log" CCTRL_DEVICE_TAG=ms _restore_run_real "$dir" --only cctrl --yes 2>&1 </dev/null)" || rrc=$?
    [[ "$rrc" -eq 0 ]] || fail "restore failed ($rrc): $(tail -n 6 <<< "$rout")"
    rec="$(grep -l 'conv-aaa-111' "$dir/session-metadata"/*.json | head -n 1)"
    [[ -n "$rec" ]] || fail "no record after restore"
    [[ "$(jq -r '.label_names_known // empty' "$rec")" == '["keep me","and me"]' ]] \
        || fail "restore changed the set: $(jq -r '.label_names_known' "$rec")"
    echo "ok: a restore keeps the known names"
}

test_reconcile_names_full_set_pulls_nothing() {
    _p3_setup f1
    local s=TMUX--ms--p3-full out names
    _p3_rec "$s" "mine" ""
    names="$(jq -nc '[range(0;33) | "name-\(.)"]')"
    _p3_cc '_session_update_metadata_field "$1" label_names_known "$2"' "$s" "$names" || fail "seed full set"
    _p3_title "$s" "brand new typed name"
    out="$(_p3_reconcile --json)"
    [[ "$(_p3_purpose "$s")" == mine ]] || fail "full set pulled: $(_p3_purpose "$s")"
    [[ "$(jq '.full | length' <<< "$out")" == 1 ]] || fail "full session not reported: $out"
    out="$(_p3_reconcile --dry-run --json)"
    [[ "$(jq '.full | length' <<< "$out")" == 1 ]] || fail "dry run must report the full session: $out"
    _p3_rename "$s" "still works"
    [[ "$(_p3_purpose "$s")" == "still works" ]] || fail "rename must keep working on a full set"
    echo "ok: a full set fails closed, is reported, and rename still works"
}

test_restore_of_record_without_known_names_gets_baseline_not_seed() {
    local dir="$TMPDIR/p3-restore-noset" rec
    _p2_restore_row_run "$dir" '{}'
    rec="$(grep -l 'conv-aaa-111' "$dir/session-metadata"/*.json | head -n 1)"
    [[ -n "$rec" ]] || fail "no record after restore"
    [[ "$(jq -r '.label_names_known // "none"' "$rec")" == none ]] || fail "a resumed launch must not seed the set: $(jq -r .label_names_known "$rec")"
    # and its first reconcile baselines instead of pulling
    _p3_setup rs
    local s=TMUX--ms--p3-resumed
    _p3_rec "$s" "kept" "$(_p3_rec_conv "$s")"
    _p3_title "$s" "claude says"
    _p3_reconcile >/dev/null
    [[ "$(_p3_purpose "$s")" == kept ]] || fail "pulled on the first reconcile: $(_p3_purpose "$s")"
    [[ -n "$(_p3_known "$s")" ]] || fail "no baseline written"
    # a resume with no id (-r picker, -c, --resume=<id>) is not a fresh launch either
    _p3_setup rs3
    local s2=TMUX--ms--p3-picker
    CCTRL_HOST_PREFIX=ms cctrl_source_eval '_session_write_metadata "$1" /tmp @x @x @x "lbl" "" cmd "" claude "" "" "" "" "" "" "" "" worker "" "" 1' "$s2" \
        || fail "resuming fixture"
    [[ -z "$(_p3_known "$s2")" ]] || fail "a resume without an id seeded the set: $(_p3_known "$s2")"
    echo "ok: a restored record with no set is baselined, never seeded from the purpose"
}

test_reconcile_names_restamp_after_cctrl_rename_on_legacy_record_not_pulled() {
    _p3_setup lr
    local s=TMUX--ms--p3-legrename
    _p3_rec "$s" "old label" "$(_p3_rec_conv "$s")"
    _p3_title "$s" "older name"
    _p3_rename "$s" "new label"
    _p3_reconcile >/dev/null
    _p3_title "$s" "older name"
    _p3_reconcile >/dev/null
    [[ "$(_p3_purpose "$s")" == "new label" ]] || fail "legacy re-stamp reverted the label: $(_p3_purpose "$s")"
    echo "ok: legacy record, cctrl rename, baseline, re-stamp of the older name: nothing pulled"
}

test_reconcile_names_older_restamped_title_is_never_pulled() {
    _p3_setup ol
    local s=TMUX--ms--p3-older
    _p3_rec "$s" "now" ""
    _p3_title "$s" "now"; _p3_title "$s" "mid"; _p3_title "$s" "now"
    _p3_rename "$s" "latest"
    _p3_title "$s" "mid"
    _p3_reconcile >/dev/null
    [[ "$(_p3_purpose "$s")" == latest ]] || fail "an older title was pulled: $(_p3_purpose "$s")"
    echo "ok: any title that is earlier in the transcript is never pulled"
}

test_reconcile_names_in_claude_rename_then_cctrl_rename_stays() {
    _p3_setup ic
    local s=TMUX--ms--p3-inclaude
    _p3_rec "$s" "start" ""
    _p3_title "$s" "start"
    _p3_title "$s" "X typed in claude"      # never reconciled
    _p3_rename "$s" "Y from cctrl"
    _p3_title "$s" "X typed in claude"      # re-stamped
    _p3_reconcile >/dev/null
    [[ "$(_p3_purpose "$s")" == "Y from cctrl" ]] || fail "Y was reverted: $(_p3_purpose "$s")"
    echo "ok: in-Claude rename X, cctrl rename Y, re-stamp of X: Y stays"
}

test_reconcile_names_new_in_claude_rename_after_cctrl_rename_is_pulled() {
    _p3_setup nw
    local s=TMUX--ms--p3-newname
    _p3_rec "$s" "start" ""
    _p3_title "$s" "start"
    _p3_rename "$s" "from cctrl"
    _p3_title "$s" "a brand new name"
    _p3_reconcile >/dev/null
    [[ "$(_p3_purpose "$s")" == "a brand new name" ]] || fail "new in-Claude name not pulled: $(_p3_purpose "$s")"
    echo "ok: a name in no earlier title is pulled even after a cctrl rename"
}

test_reconcile_names_strips_old_tmux_suffix_after_restore() {
    _p3_setup sf
    local s=TMUX--ms--p3-newtmux
    _p3_rec "$s" "the label" ""
    _p3_title "TMUX--ms--p3-oldtmux" "the label"
    _p3_reconcile >/dev/null
    [[ "$(_p3_purpose "$s")" == "the label" ]] || fail "old-suffix title was pulled: $(_p3_purpose "$s")"
    assert_not_contains "$(_p3_known "$s")" "TMUX--"
    echo "ok: a title carrying an older tmux name is the same name"
}

test_reconcile_names_normalises_suffix_on_store_and_compare() {
    cctrl_source_eval '
        [[ "$(_session_name_normalise "a b (TMUX--ms--x)")" == "a b" ]] || exit 1
        [[ "$(_session_name_normalise "a b (TMUX--other--y)  ")" == "a b" ]] || exit 2
        [[ "$(_session_name_normalise "  a (b) ")" == "a (b)" ]] || exit 3
        [[ -z "$(_session_name_normalise "(TMUX--only)")" ]] || exit 4
        [[ -z "$(_session_name_normalise "TMUX--ms--bare")" ]] || exit 5
        [[ "$(_session_names_known_json "[]" "n (TMUX--a)" "m" "n (TMUX--b)")" == "[\"m\",\"n\"]" ]] || exit 6' \
        || fail "normalisation check failed at step $?"
    echo "ok: names are normalised before store and compare"
}

test_reconcile_names_dry_run_writes_nothing() {
    _p3_setup dr
    local s=TMUX--ms--p3-dry t=TMUX--ms--p3-dry2 sum
    _p3_rec "$s" "mine" "$(_p3_rec_conv "$s")"   # baseline case
    _p3_title "$s" "foreign"
    sum="$(_p3_state_sum)"
    _p3_reconcile --dry-run >/dev/null; [[ "$(_p3_state_sum)" == "$sum" ]] || fail "dry run (text, baseline) wrote"
    _p3_reconcile --dry-run --json >/dev/null; [[ "$(_p3_state_sum)" == "$sum" ]] || fail "dry run (json, baseline) wrote"
    # correction case: a record with a set and a new name
    _p3_reconcile >/dev/null
    _p3_title "$s" "typed later"
    sum="$(_p3_state_sum)"
    _p3_reconcile --json --dry-run >/dev/null; [[ "$(_p3_state_sum)" == "$sum" ]] || fail "dry run (json, correction) wrote"
    _p3_reconcile --dry-run >/dev/null; [[ "$(_p3_state_sum)" == "$sum" ]] || fail "dry run (text, correction) wrote"
    echo "ok: --dry-run writes no metadata, tmux option or transcript line"
}

test_reconcile_names_dry_run_reports_would_be_corrections() {
    _p3_setup dc
    local s=TMUX--ms--p3-would out
    _p3_rec "$s" "mine" ""
    _p3_title "$s" "mine"; _p3_reconcile >/dev/null
    _p3_title "$s" "typed in claude"
    out="$(_p3_reconcile --dry-run --json)"
    jq -e '.dry_run == true and .corrections == 1 and .details[0].new == "typed in claude" and .details[0].old == "mine"' <<< "$out" >/dev/null \
        || fail "dry-run json: $out"
    [[ "$(_p3_purpose "$s")" == mine ]] || fail "dry run changed the label"
    jq -e '.dry_run == false' <<< "$(_p3_reconcile --json)" >/dev/null || fail "real json must say dry_run false"
    echo "ok: --dry-run reports the corrections it would make"
}

test_reconcile_names_help_and_unknown_flag_write_nothing() {
    _p3_setup hf
    local s=TMUX--ms--p3-help out rc=0 sum
    _p3_rec "$s" "mine" "$(_p3_rec_conv "$s")"
    _p3_title "$s" "foreign"
    sum="$(_p3_state_sum)"
    out="$(_p3_reconcile --help)" || fail "--help must exit 0"
    assert_contains "$out" "Usage: cctrl session reconcile-names"
    out="$(_p3_reconcile -h --json)" || fail "-h must exit 0"
    [[ "$(_p3_state_sum)" == "$sum" ]] || fail "--help wrote"
    _p3_cc '_session_reconcile_names "$@"' --bogus >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 64 ]] || fail "unknown flag must exit 64, got $rc"
    rc=0; _p3_cc '_session_reconcile_names "$@"' --dry-run --bogus >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 64 ]] || fail "unknown flag after --dry-run must exit 64, got $rc"
    [[ "$(_p3_state_sum)" == "$sum" ]] || fail "an unknown flag wrote"
    echo "ok: --help and an unknown flag write nothing (unknown exits 64)"
}

test_rename_self_resolves_current_session() {
    _p3_setup rs1
    local s=TMUX--ms--p3-self
    _p3_rec "$s" "before" ""
    TMUX_FAKE_STATE="$P2_STATE" TMUX_LOG="$RF_LOG" PATH="$TMPDIR:$PATH" CCTRL_HOST_PREFIX=ms CCTRL_SESSION_KIND=tmux CCTRL_SESSION_NAME="$s" \
        "$RF_COPY/cctrl" rename --self "after self" </dev/null >/dev/null 2>&1 || fail "rename --self failed"
    [[ "$(_p3_purpose "$s")" == "after self" ]] || fail "label not changed: $(_p3_purpose "$s")"
    echo "ok: rename --self resolves the current session"
}

test_rename_self_outside_session_exits_64() {
    _p3_setup rs2
    local s=TMUX--ms--p3-noself rc=0 sum
    _p3_rec "$s" "before" ""
    sum="$(_p3_state_sum)"
    TMUX_FAKE_STATE="$P2_STATE" TMUX_LOG="$RF_LOG" PATH="$TMPDIR:$PATH" CCTRL_HOST_PREFIX=ms CCTRL_SESSION_NAME="$s" \
        "$RF_COPY/cctrl" rename --self "x" </dev/null >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 64 ]] || fail "no CCTRL_SESSION_KIND must exit 64, got $rc"
    rc=0
    TMUX_FAKE_STATE="$P2_STATE" TMUX_LOG="$RF_LOG" PATH="$TMPDIR:$PATH" CCTRL_HOST_PREFIX=ms CCTRL_SESSION_KIND=codex CCTRL_SESSION_NAME="$s" \
        "$RF_COPY/cctrl" rename --self "x" </dev/null >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 64 ]] || fail "a non-tmux kind must exit 64, got $rc"
    [[ "$(_p3_state_sum)" == "$sum" ]] || fail "a refused --self changed state"
    echo "ok: rename --self outside a cctrl tmux session exits 64"
}

test_auto_label_for_handoff_prompt_uses_slug() {
    cctrl_source_eval '
        [[ "$(_generate_auto_purpose "resume from handoff smoke-x" myrepo)" == "myrepo: smoke-x" ]] || exit 1
        [[ "$(_generate_auto_purpose "Resume from handoff plan100-phase3. Then do more things" myrepo)" == "myrepo: plan100-phase3" ]] || exit 2
        [[ "$(CCTRL_TITLE_MODE=heuristic _generate_auto_purpose "fix the login bug" myrepo)" == "myrepo: fix the login bug" ]] || exit 3' \
        || fail "auto label check failed at step $?"
    _p2_setup hs '{}'
    local out
    out="$(CCTRL_TITLE_MODE=heuristic _p2 start -d "$RF_PROJ" -m "resume from handoff smoke-x")" || fail "launch failed: $out"
    [[ "$(_rf_field "$out" purpose)" == "${RF_PROJ##*/}: smoke-x" ]] || fail "launch label: $(_rf_field "$out" purpose)"
    echo "ok: a resume-from-handoff prompt is labelled <repo>: <slug>"
}

test_set_role_relabel_writes_canonical_label() {
    _p2_setup rl '{}'
    local out sess
    out="$(_p2 start -d --role worker --purpose "plain" "$RF_PROJ")"; sess="$(_rf_session "$out")"
    _p2_live "$sess"
    _p2 session set-role "$sess" orchestrator --orch-kind repo >/dev/null
    [[ "$(session_record_json "$sess" | jq -r .purpose)" == plain ]] || fail "set-role without --relabel must not relabel"
    _p2 session set-role "$sess" orchestrator --orch-kind repo --relabel >/dev/null
    [[ "$(session_record_json "$sess" | jq -r .purpose)" == "★ orchestrator: rf-rl-proj" ]] \
        || fail "relabel: $(session_record_json "$sess" | jq -r .purpose)"
    local rc=0
    _p2 session set-role "$sess" worker --relabel >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 64 ]] || fail "--relabel on a worker must exit 64, got $rc"
    assert_not_contains "$(cat "$RF_LOG")" "kill-session"
    echo "ok: set-role --relabel writes the canonical label and nothing renames the session"
}

test_codex_title_skips_repo_prefix_for_star_label() {
    local out
    out="$(cctrl_source_eval '_session_app_display_name TMUX--ms--orch-cctrl "★ orchestrator: cctrl" /x/cctrl; echo; _session_app_display_name TMUX--ms--cctrl "fix it" /x/cctrl')"
    assert_contains "$out" "★ orchestrator: cctrl (TMUX--ms--orch-cctrl)"
    assert_not_contains "$out" "cctrl: ★"
    assert_contains "$out" "cctrl: fix it (TMUX--ms--cctrl)"
    echo "ok: the Codex title skips its repo prefix for a star label"
}

test_remote_orchestrator_launch_injects_no_default_purpose() {
    _remote_role_fixture p2np
    local out
    SSH_PRE_OUT='role=orchestrator orch_kind=repo' _p2_ok "remote launch failed" _remote_role @k
    assert_not_contains "$(tail -n 1 "$RR_LOG")" "--purpose"
    : > "$RR_LOG"
    SSH_PRE_OUT='role=worker orch_kind=-' _p2_ok "remote worker launch failed" _remote_role @k
    assert_contains "$(tail -n 1 "$RR_LOG")" "--purpose"
    echo "ok: a remote orchestrator launch injects no default purpose"
}

test_second_fleet_manager_same_runtime_refused_65() {
    _p2_setup g1 '{}'
    _p2_fleet_live
    local before out rc=0
    before="$(_p2_new_count)"
    out="$(_p2 start -d --agent codex --orch-kind fleet "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 65 ]] || fail "expected 65, got $rc: $out"
    assert_contains "$out" "$P2_FLEET"
    assert_contains "$out" "--succeeds $P2_FLEET"
    assert_contains "$out" "CCTRL_ALLOW_SECOND_FLEET_MANAGER=1"
    [[ "$(_p2_new_count)" == "$before" ]] || fail "a refused launch must not create a session"
    [[ ! -d "$(_p2_lock_dir codex)" ]] || fail "a refusal must release the lock"
    echo "ok: a second fleet manager of the same runtime is refused with 65"
}

test_fleet_launch_never_gets_index_suffix() {
    _p2_setup g2 '{}'
    local out rc=0
    out="$(_p2 start -d --agent codex --orch-kind fleet "$RF_PROJ")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--fleet-codex"
    # A live NON-fleet session holds the exact name: refuse, never fleet-codex--2.
    _p2_setup g2b '{}'
    _p2_record TMUX--ms--fleet-codex worker "" codex
    _p2_live TMUX--ms--fleet-codex
    out="$(_p2 start -d --agent codex --orch-kind fleet "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 65 ]] || fail "expected 65, got $rc: $out"
    assert_contains "$out" "not a fleet manager"
    assert_not_contains "$(cat "$RF_LOG")" "fleet-codex--2"
    echo "ok: a fleet launch never gets an index suffix"
}

test_old_named_fleet_manager_with_role_blocks_new_one() {
    _p2_setup g3 '{}'
    _p2_record TMUX--ms--fm-orchestrator orchestrator fleet codex
    _p2_live TMUX--ms--fm-orchestrator
    local out rc=0
    out="$(_p2 start -d --agent codex --orch-kind fleet "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 65 ]] || fail "expected 65, got $rc: $out"
    assert_contains "$out" "TMUX--ms--fm-orchestrator"
    echo "ok: a tagged fm-orchestrator blocks a new fleet manager"
}

test_fleet_manager_other_runtime_allowed() {
    _p2_setup g4 '{}'
    _p2_record TMUX--ms--fleet-claude orchestrator fleet claude
    _p2_live TMUX--ms--fleet-claude
    local out
    _p2_ok "a codex fleet manager beside a live claude one was refused" _p2 start -d --agent codex --orch-kind fleet "$RF_PROJ"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--fleet-codex"
    echo "ok: a fleet manager of another runtime is allowed"
}

test_repo_and_unknown_kind_sessions_never_trip_guard() {
    _p2_setup g5 '{}'
    _p2_record TMUX--ms--p2-unkn orchestrator "" codex
    _p2_record TMUX--ms--orch-other orchestrator repo codex
    _p2_live TMUX--ms--p2-unkn TMUX--ms--orch-other
    local out
    _p2_ok "fleet launch tripped by repo/unknown sessions" _p2 start -d --agent codex --orch-kind fleet "$RF_PROJ"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--fleet-codex"
    _p2_ok "repo launch refused" _p2 start -d --orch-kind repo "$RF_PROJ"
    echo "ok: repo and unknown-kind orchestrators never trip the guard"
}

test_guard_runs_only_after_kind_known() {
    _p2_setup g6 '{}'
    _p2_fleet_live
    local out rc=0
    out="$(_p2 start -d --agent codex --role orchestrator "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 78 ]] || fail "an ambiguous launch must answer 78, got $rc: $out"
    echo "ok: the guard runs only after the kind is known"
}

test_concurrent_fleet_launch_refused_by_lock() {
    _p2_setup lk1 '{}'
    _p2_lock codex "$(date +%s)" "$$"
    local out rc=0
    out="$(_p2 start -d --agent codex --orch-kind fleet "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 65 ]] || fail "expected 65, got $rc: $out"
    assert_contains "$out" "in progress"
    [[ -d "$(_p2_lock_dir codex)" ]] || fail "the held lock must survive a refused launch"
    [[ "$(_p2_new_count)" == 0 ]] || fail "nothing may be created"
    echo "ok: a held fleet lock refuses a concurrent launch"
}

test_stale_fleet_lock_is_reclaimed() {
    _p2_setup lk2 '{}'
    local dead
    ( : ) & dead=$!; wait "$dead" 2>/dev/null || true
    _p2_lock codex "$(date +%s)" "$dead"
    local out
    _p2_ok "a dead-pid lock must be reclaimed" _p2 start -d --agent codex --orch-kind fleet "$RF_PROJ"
    [[ ! -d "$(_p2_lock_dir codex)" ]] || fail "the lock must be released after the launch"
    echo "ok: a lock with a dead pid is reclaimed"
}

test_fleet_lock_older_than_limit_is_reclaimed_even_with_live_pid() {
    _p2_setup lk3 '{}'
    _p2_lock codex "$(( $(date +%s) - 300 ))" "$$"
    local out
    _p2_ok "an old lock must be reclaimed" _p2 start -d --agent codex --orch-kind fleet "$RF_PROJ"
    echo "ok: a lock older than the limit is reclaimed whatever its pid"
}

test_fleet_lock_without_pid_file_is_held_only_briefly() {
    _p2_setup lk4 '{}'
    _p2_lock codex "$(date +%s)" ""
    local out rc=0
    out="$(_p2 start -d --agent codex --orch-kind fleet "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 65 ]] || fail "a fresh pid-less lock is held, got $rc: $out"
    rm -rf "$(_p2_lock_dir codex)"
    _p2_lock codex "$(( $(date +%s) - 30 ))" ""
    _p2_ok "an older pid-less lock must be reclaimed" _p2 start -d --agent codex --orch-kind fleet "$RF_PROJ"
    echo "ok: a lock without a pid file is held only briefly"
}

test_override_env_is_unset_before_tmux_new_session() {
    _p2_setup ov1 '{}'
    _p2_fleet_live
    mv "$TMPDIR/tmux" "$TMPDIR/tmux.real"
    cat > "$TMPDIR/tmux" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "new-session" ]]; then
    printf 'ENV allow=%s noinput=%s\n' "${CCTRL_ALLOW_SECOND_FLEET_MANAGER-unset}" "${CCTRL_NO_INPUT-unset}" >> "${P2_ENVLOG:?}"
fi
exec "$(dirname "$0")/tmux.real" "$@"
SH
    chmod +x "$TMPDIR/tmux"
    local envlog="$TMPDIR/p2-env.log" out
    : > "$envlog"
    P2_ENVLOG="$envlog" CCTRL_ALLOW_SECOND_FLEET_MANAGER=1 CCTRL_NO_INPUT=1 _p2_ok "override launch failed" _p2 start -d --agent codex --orch-kind fleet "$RF_PROJ"
    assert_contains "$(cat "$envlog")" "allow=unset noinput=unset"
    echo "ok: the override and no-input variables are unset before tmux new-session"
}

test_allow_second_fleet_manager_env_override() {
    _p2_setup ov2 '{}'
    _p2_fleet_live
    local out
    CCTRL_ALLOW_SECOND_FLEET_MANAGER=1 _p2_ok "override refused" _p2 start -d --agent codex --orch-kind fleet "$RF_PROJ"
    assert_contains "$out" "CCTRL_ALLOW_SECOND_FLEET_MANAGER=1"
    assert_contains "$out" "$P2_FLEET"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--fleet-codex--2"
    [[ ! -d "$(_p2_lock_dir codex)" ]] || fail "the override path must not leave a lock"
    echo "ok: CCTRL_ALLOW_SECOND_FLEET_MANAGER=1 allows a second fleet manager and says so"
}

test_succeeds_allows_one_handover_and_relabels_predecessor() {
    _p2_setup su1 '{}'
    _p2_fleet_live
    local out
    _p2_ok "handover refused" _p2 start -d --agent codex --orch-kind fleet --succeeds "$P2_FLEET" "$RF_PROJ"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--fleet-codex--2"
    [[ "$(_rf_field "$out" succeeds)" == "$P2_FLEET" ]] || fail "succeeds not recorded"
    [[ "$(session_record_json "$P2_FLEET" | jq -r .purpose)" == "☆ fleet manager (codex), handing over" ]] \
        || fail "predecessor label: $(session_record_json "$P2_FLEET" | jq -r .purpose)"
    assert_not_contains "$(cat "$RF_LOG")" "kill-session"
    # While both are live nothing else can become a fleet manager.
    _p2_live "$(_rf_session "$out")"
    local rc=0
    _p2 start -d --agent codex --orch-kind fleet --succeeds "$P2_FLEET" "$RF_PROJ" >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 65 ]] || fail "a second handover while two are live must be refused, got $rc"
    echo "ok: --succeeds allows one handover, relabels the predecessor and closes nothing"
}

test_succeeds_wrong_session_or_two_live_refused() {
    _p2_setup su2 '{}'
    _p2_fleet_live
    local out rc=0
    out="$(_p2 start -d --agent codex --orch-kind fleet --succeeds TMUX--ms--somebody-else "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 65 ]] || fail "--succeeds with the wrong session must exit 65, got $rc: $out"
    _p2_setup su3 '{}'
    rc=0
    out="$(_p2 start -d --agent codex --orch-kind fleet --succeeds TMUX--ms--fleet-codex "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 65 ]] || fail "--succeeds with no live fleet manager must exit 65, got $rc: $out"
    echo "ok: --succeeds needs exactly that one live fleet manager"
}

test_dead_fleet_manager_record_does_not_block() {
    _p2_setup dd '{}'
    _p2_record TMUX--ms--fleet-codex orchestrator fleet codex
    local out
    _p2_ok "a dead record blocked the launch" _p2 start -d --agent codex --orch-kind fleet "$RF_PROJ"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--fleet-codex"
    echo "ok: a dead fleet manager's record does not block"
}

test_set_role_fleet_goes_through_guard() {
    _p2_setup sg '{}'
    _p2_fleet_live
    local out wsess rc=0
    out="$(_p2 start -d --role worker --purpose w "$RF_PROJ")"; wsess="$(_rf_session "$out")"
    _p2_live "$wsess"
    out="$(_p2 session set-role "$wsess" orchestrator --orch-kind fleet 2>&1)" || rc=$?
    [[ "$rc" -eq 65 ]] || fail "expected 65, got $rc: $out"
    assert_contains "$out" "$P2_FLEET"
    [[ "$(session_record_json "$wsess" | jq -r .role)" == worker ]] || fail "a refused set-role must not change the role"
    # The session itself is excluded: re-tagging the live fleet manager is fine.
    _p2 session set-role "$P2_FLEET" orchestrator --orch-kind fleet >/dev/null || fail "re-tagging the live fleet manager was refused"
    echo "ok: set-role --orch-kind fleet goes through the guard"
}

test_succeeds_refused_64_unless_fleet_kind() {
    _p2_setup sk '{}'
    local out rc=0 before
    before="$(_p2_new_count)"
    out="$(_p2 start -d --agent codex --orch-kind repo --succeeds old-one --purpose p "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "--succeeds with a repo orchestrator must exit 64, got $rc: $out"
    rc=0
    out="$(_p2 start -d --agent codex --role worker --succeeds old-one --purpose p "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "--succeeds with a worker must exit 64, got $rc: $out"
    rc=0
    out="$(CCTRL_ALLOW_SECOND_FLEET_MANAGER=1 _p2 start -d --agent codex --orch-kind repo --succeeds old-one --purpose p "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "--succeeds with a repo orchestrator under the override must exit 64, got $rc: $out"
    assert_contains "$out" "--succeeds is only valid"
    rc=0
    out="$(CCTRL_ALLOW_SECOND_FLEET_MANAGER=1 _p2 start -d --agent codex --orch-kind fleet --succeeds old-one "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "--succeeds under the override must exit 64, got $rc: $out"
    [[ "$(_p2_new_count)" == "$before" ]] || fail "a refused --succeeds must not create a session"
    echo "ok: --succeeds is refused with 64 unless the kind is fleet"
}

test_failed_health_check_leaves_predecessor_label() {
    _p2_setup hc '{}'
    _p2_fleet_live
    local out rc=0 before_label
    before_label="$(session_record_json "$P2_FLEET" | jq -r .purpose)"
    mkdir -p "$RF_COPY/lib"
    printf '_health_check_run() { return 1; }\n' > "$RF_COPY/lib/health-check.sh"
    out="$(CCTRL_NO_HEALTH_CHECK= _p2 start -d --agent codex --orch-kind fleet --succeeds "$P2_FLEET" "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "a failed health check must fail the launch, got $rc: $out"
    assert_contains "$out" "did not start"
    [[ "$(session_record_json "$P2_FLEET" | jq -r .purpose)" == "$before_label" ]] \
        || fail "predecessor relabelled on a failed launch: $(session_record_json "$P2_FLEET" | jq -r .purpose)"
    [[ ! -d "$(_p2_lock_dir codex)" ]] || fail "a failed launch must release the lock"
    echo "ok: a failed health check during --succeeds leaves the predecessor label unchanged"
}

test_empty_runtime_fleet_manager_counts_as_claude() {
    _p2_setup er '{}'
    _p2_record TMUX--ms--fleet-claude orchestrator fleet ""
    _p2_live TMUX--ms--fleet-claude
    local out rc=0
    out="$(_p2 start -d --agent claude --orch-kind fleet "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 65 ]] || fail "a tagged fleet manager with no agent must block a claude launch, got $rc: $out"
    # set-role --relabel never writes an empty runtime.
    out="$(_p2 start -d --role worker --purpose w "$RF_PROJ")"
    local wsess
    wsess="$(_rf_session "$out")"
    _p2_live "$wsess"
    rc=0
    out="$(CCTRL_ALLOW_SECOND_FLEET_MANAGER=1 _p2 session set-role "$wsess" orchestrator --orch-kind fleet --relabel 2>&1)" || rc=$?
    assert_not_contains "$(session_record_json "$wsess" | jq -r .purpose)" "()"
    echo "ok: an empty runtime counts as claude and is never written into a label"
}

test_set_role_fleet_takes_launch_lock() {
    _p2_setup sl '{}'
    local out wsess rc=0
    out="$(_p2 start -d --role worker --purpose w "$RF_PROJ")"; wsess="$(_rf_session "$out")"
    _p2_live "$wsess"
    _p2_lock codex "$(date +%s)" "$$"
    out="$(_p2 session set-role "$wsess" orchestrator --orch-kind fleet 2>&1)" || rc=$?
    [[ "$rc" -eq 65 ]] || fail "set-role fleet with the lock held must exit 65, got $rc: $out"
    assert_contains "$out" "in progress"
    [[ "$(session_record_json "$wsess" | jq -r .role)" == worker ]] || fail "a locked-out set-role must not change the role"
    [[ -d "$(_p2_lock_dir codex)" ]] || fail "the other holder's lock must stay"
    rm -rf "$(_p2_lock_dir codex)"
    _p2 session set-role "$wsess" orchestrator --orch-kind fleet >/dev/null 2>&1 || fail "set-role fleet failed with no lock held"
    [[ ! -d "$(_p2_lock_dir codex)" ]] || fail "set-role must release the lock"
    echo "ok: set-role --orch-kind fleet takes and releases the launch lock"
}

test_set_role_relabel_repo_falls_back_to_pane_path() {
    _p2_setup rp '{}'
    _p2_live TMUX--ms--p2-bare
    local out
    out="$(_p2 session set-role TMUX--ms--p2-bare orchestrator --orch-kind repo 2>&1)" || fail "tag failed: $out"
    out="$(_p2 session set-role TMUX--ms--p2-bare orchestrator --orch-kind repo --relabel 2>&1)" || true
    assert_contains "$(cat "$RF_LOG")" "demo"
    assert_not_contains "$out" "★ orchestrator: "$'\n'
    # With no pane path either, it refuses instead of writing a nameless label.
    cp "$TMPDIR/tmux" "$TMPDIR/tmux.real"
    printf '#!/bin/bash\n[[ "$1" == list-panes ]] && exit 0\nexec "%s/tmux.real" "$@"\n' "$TMPDIR" > "$TMPDIR/tmux"
    local rc=0
    out="$(_p2 session set-role TMUX--ms--p2-bare orchestrator --orch-kind repo --relabel 2>&1)" || rc=$?
    cp "$TMPDIR/tmux.real" "$TMPDIR/tmux"
    [[ "$rc" -eq 64 ]] || fail "an unnameable repo must exit 64, got $rc: $out"
    assert_contains "$out" "cannot name the repo"
    echo "ok: --relabel for a repo orchestrator falls back to the pane path, else refuses"
}

test_fleet_lock_registry_dir_failure_has_own_message() {
    _p2_setup rd '{}'
    : > "$TMPDIR/rd-afile"
    local out rc=0
    out="$(CCTRL_SESSION_METADATA_DIR="$TMPDIR/rd-afile/sub" _p2 start -d --agent codex --orch-kind fleet "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 74 ]] || fail "an uncreatable registry dir must exit 74, got $rc: $out"
    assert_contains "$out" "cannot create the session registry dir"
    assert_not_contains "$out" "in progress"
    echo "ok: an uncreatable registry dir has its own exit code and message"
}

test_refusal_wording_per_caller() {
    _p2_setup wd '{}'
    _p2_fleet_live
    local out wsess rc=0
    out="$(_p2 start -d --role worker --purpose w "$RF_PROJ")"; wsess="$(_rf_session "$out")"
    _p2_live "$wsess"
    out="$(_p2 session set-role "$wsess" orchestrator --orch-kind fleet 2>&1)" || rc=$?
    assert_not_contains "$out" "Refusing to launch"
    assert_contains "$out" "Refusing to tag"
    assert_not_contains "$out" "--succeeds"
    # The exact-name refusal says what kind of session holds the name.
    _p2_setup wd2 '{}'
    _p2_record TMUX--ms--fleet-codex worker "" codex
    _p2_live TMUX--ms--fleet-codex
    rc=0
    out="$(_p2 start -d --agent codex --orch-kind fleet "$RF_PROJ")" || rc=$?
    [[ "$rc" -eq 65 ]] || fail "expected 65, got $rc: $out"
    assert_contains "$out" "held by a live worker session"
    echo "ok: refusal wording names the action and the holder"
}

test_restore_keeps_recorded_name_for_tagged_fleet_row() {
    local dir="$TMPDIR/p2-keep-fleet"
    P2_ROW_TMUX=TMUX--ms--fm-orchestrator _p2_restore_row_run "$dir" '{"role":"orchestrator","orch_kind":"fleet"}'
    [[ "$P2_RESTORE_NAME" == TMUX--ms--fm-orchestrator ]] || fail "a restore must keep the recorded fm-orchestrator name, got: $P2_RESTORE_NAME"
    echo "ok: a restored tagged fleet row keeps its recorded name"
}

test_restore_keeps_recorded_name_for_tagged_repo_row_with_index() {
    local dir="$TMPDIR/p2-keep-repo"
    P2_ROW_TMUX=TMUX--ms--fm-homelab--3 _p2_restore_row_run "$dir" '{"role":"orchestrator","orch_kind":"repo"}'
    [[ "$P2_RESTORE_NAME" == TMUX--ms--fm-homelab--3 ]] || fail "a restore must keep the recorded --3 name, got: $P2_RESTORE_NAME"
    echo "ok: a restored tagged repo row keeps its recorded name including the index"
}

test_restore_beside_live_session_of_same_name_gets_next_index() {
    local dir="$TMPDIR/p2-keep-live" state="$TMPDIR/p2-keep-live.state"
    printf '$1:TMUX--ms--fm-comet\n' > "$state"
    P2_ROW_TMUX=TMUX--ms--fm-comet _p2_restore_row_run "$dir" '{"role":"orchestrator","orch_kind":"repo"}' "$state"
    [[ "$P2_RESTORE_NAME" == TMUX--ms--fm-comet--2 ]] || fail "a collision must take the next free index, got: $P2_RESTORE_NAME"
    : > "$state"; printf '$1:TMUX--ms--fm-comet\n$2:TMUX--ms--fm-comet--2\n' > "$state"
    dir="$TMPDIR/p2-keep-live2"
    P2_ROW_TMUX=TMUX--ms--fm-comet _p2_restore_row_run "$dir" '{"role":"orchestrator","orch_kind":"repo"}' "$state"
    [[ "$P2_RESTORE_NAME" == TMUX--ms--fm-comet--3 ]] || fail "next free index after --2, got: $P2_RESTORE_NAME"
    echo "ok: a restore beside a live session of the same name takes the next free index"
}

test_restore_keeps_phase2_style_names() {
    local dir="$TMPDIR/p2-keep-new1"
    P2_ROW_TMUX=TMUX--ms--orch-rentkompass _p2_restore_row_run "$dir" '{"role":"orchestrator","orch_kind":"repo"}'
    [[ "$P2_RESTORE_NAME" == TMUX--ms--orch-rentkompass ]] || fail "orch name changed on restore: $P2_RESTORE_NAME"
    dir="$TMPDIR/p2-keep-new2"
    P2_ROW_TMUX=TMUX--ms--fleet-claude _p2_restore_row_run "$dir" '{"role":"orchestrator","orch_kind":"fleet"}'
    [[ "$P2_RESTORE_NAME" == TMUX--ms--fleet-claude ]] || fail "fleet name changed on restore: $P2_RESTORE_NAME"
    echo "ok: a row already named orch-x / fleet-claude keeps that name on restore"
}

test_realign_of_tagged_orchestrator_keeps_recorded_name() {
    local bin="$TMPDIR/rl-p2-bin" sdir="$TMPDIR/rl-p2-sessions" log="$TMPDIR/rl-p2-tmux.log"
    _doctor_realign_fixture "$bin" "$sdir" "TMUX--ms--unstructured-data-portal-" "idle"
    printf '{"target":"/tmp","cwd":"/tmp","purpose":"p","role":"orchestrator","orch_kind":"repo"}\n' > "$CCTRL_SESSION_METADATA_DIR/TMUX--ms--portal.json"
    : > "$log"
    PATH="$bin:$PATH" CCTRL_CLAUDE_SESSIONS_DIR="$sdir" TMUX_LOG="$log" TMUX_FAKE_SESSIONS="TMUX--ms--portal" TMUX_FAKE_PANE_PID=4242 \
        CCTRL_NO_HEALTH_CHECK=1 CCTRL_HOST_PREFIX=ms CCTRL_PURPOSE_PROMPT=never \
        "$ROOT/cctrl" session doctor --fix --yes --json >/dev/null 2>&1 </dev/null || true
    assert_contains "$(cat "$log")" "new-session -d -s TMUX--ms--portal"
    assert_not_contains "$(cat "$log")" "new-session -d -s TMUX--ms--orch-"
    echo "ok: a realign of a tagged orchestrator keeps the recorded tmux name"
}

test_fresh_orchestrator_launch_still_gets_role_name() {
    _p2_setup fr '{}'
    local out
    out="$(_p2 start -d --orch-kind repo --purpose p "$RF_PROJ")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--orch-"
    out="$(_p2 start -d --agent codex --orch-kind fleet "$RF_PROJ")"
    assert_contains "$out" "CCTRL_SESSION=TMUX--ms--fleet-codex"
    echo "ok: a fresh (non-replay) orchestrator launch still gets orch-<repo> / fleet-<runtime>"
}

test_restore_bypasses_guard_and_reports_predecessor() {
    local dir="$TMPDIR/p2-restore-fleet" state="$TMPDIR/p2-restore-fleet.state"
    printf '$1:TMUX--ms--fleet-claude\n' > "$state"
    P2_ROW_TMUX=TMUX--ms--fleet-claude _p2_restore_row_run "$dir" '{"role":"orchestrator","orch_kind":"fleet"}' "$state"
    [[ "$P2_RESTORE_NAME" == TMUX--ms--fleet-claude--2 ]] || fail "restored beside a live fleet manager, got: $P2_RESTORE_NAME"
    assert_contains "$P2_RESTORE_OUT" "restored=1"
    assert_contains "$P2_RESTORE_OUT" "beside the live fleet manager TMUX--ms--fleet-claude"
    echo "ok: restore bypasses the guard and reports the live predecessor"
}

test_session_ls_warns_on_two_fleet_managers_and_unknown_kind() {
    _p2_setup ls '{}'
    _p2_record TMUX--ms--fleet-codex orchestrator fleet codex
    _p2_live TMUX--ms--fleet-codex TMUX--ms--fleet-codex--2 TMUX--ms--p2-unk2
    _p2_record TMUX--ms--p2-unk2 orchestrator "" codex
    local out
    out="$(TMUX_FAKE_STATE="$P2_STATE" PATH="$TMPDIR:$PATH" CCTRL_HOST_PREFIX=ms cctrl_source_eval '_session_ls_role_footers' 2>&1)"
    assert_contains "$out" "2 codex fleet managers are live"
    assert_contains "$out" "TMUX--ms--p2-unk2"
    assert_contains "$out" "orch?"
    : > "$P2_STATE"; _p2_live TMUX--ms--fleet-codex
    out="$(TMUX_FAKE_STATE="$P2_STATE" PATH="$TMPDIR:$PATH" CCTRL_HOST_PREFIX=ms cctrl_source_eval '_session_ls_role_footers' 2>&1)"
    assert_not_contains "$out" "fleet managers are live"
    echo "ok: session ls footers warn on two fleet managers and unknown kind"
}


test_role_skills_ask_rule() {
    # Plan 100 phase 4: the orchestrator skills and cctrl-spawn state the ask
    # rule (cctrl asks, never guesses the kind; exit 78 = stop and ask).
    local skill f
    [[ -f "$ROOT/skills/cctrl-repo-orchestrator/SKILL.md" ]] \
        || fail "skills/cctrl-repo-orchestrator/SKILL.md is missing"
    for skill in cctrl-fleet-manager cctrl-repo-orchestrator cctrl-spawn; do
        f="$ROOT/skills/$skill/SKILL.md"
        grep -qF "exit 78" "$f" || grep -qF "exits **78**" "$f" \
            || fail "$skill skill does not mention exit 78"
        grep -qF "Never retry with a guessed kind" "$f" \
            || fail "$skill skill does not state the ask rule"
        grep -qF "needs-user-decision: orchestrator-kind" "$f" \
            || fail "$skill skill omits the needs-user-decision marker"
    done
    for skill in cctrl-fleet-manager cctrl-repo-orchestrator; do
        grep -qF "There are two kinds" "$ROOT/skills/$skill/SKILL.md" \
            || fail "$skill skill does not open with the two-kinds statement"
    done
    echo "ok: orchestrator skills and cctrl-spawn state the ask rule and exit 78"
}


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

    # Look entries up by label: indices shift whenever a dialog is added.
    hc_pattern() {
        local i
        for i in "${!HC_LABEL[@]}"; do
            [[ "${HC_LABEL[$i]}" == "$1" ]] && { printf '%s' "${HC_PATTERN[$i]}"; return 0; }
        done
        fail "no health-check pattern labelled $1"
    }
    # Workspace trust modal (should match)
    local trust_pane
    trust_pane="$(printf '%s\n' \
        '╭──────────────────────────────────────────────────╮' \
        '│ Do you trust the files in this folder?            │' \
        '│ ❯ 1. Yes                                         │' \
        '│   2. No                                          │' \
        '╰──────────────────────────────────────────────────╯')"
    printf '%s\n' "$trust_pane" | grep -E "$(hc_pattern workspace-trust)" >/dev/null 2>&1 \
        || fail "workspace-trust pattern should match trust modal"

    # Conversation picker (should match)
    local picker_pane
    picker_pane="$(printf '%s\n' \
        'Continue from a previous conversation?' \
        '❯ 1. Start new conversation')"
    printf '%s\n' "$picker_pane" | grep -E "$(hc_pattern conversation-picker)" >/dev/null 2>&1 \
        || fail "conversation-picker pattern should match picker modal"

    # Seeded prompt text mentioning "trust" should NOT match
    local seeded_pane
    seeded_pane="$(printf '%s\n' \
        'Your task: ensure the files are trustworthy.' \
        'Continue from a previous plan and verify.')"
    ! printf '%s\n' "$seeded_pane" | grep -E "$(hc_pattern workspace-trust)" >/dev/null 2>&1 \
        || fail "workspace-trust pattern should NOT match seeded prompt prose"

    # Codex patterns
    _hc_patterns_for_agent codex
    local codex_modal
    codex_modal="$(printf '%s\n' \
        'Allow Codex to run: npm test' \
        'tell Codex what to do differently')"
    printf '%s\n' "$codex_modal" | grep -E "$(hc_pattern codex-approval-modal)" >/dev/null 2>&1 \
        || fail "codex-approval-modal pattern should match Codex modal"

    local codex_hooks
    codex_hooks="$(printf '%s\n' 'Hooks need review' 'Press t to trust')"
    printf '%s\n' "$codex_hooks" | grep -E "$(hc_pattern codex-hooks-trust)" >/dev/null 2>&1 \
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
if [[ "${1:-}" == "-u" ]]; then shift; fi
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

_hc_readiness_fixture() {
    # Fake tmux whose visible screen comes from files: screen.N for the Nth
    # capture (last one repeats). has-session fails when $dir/gone exists.
    # Metadata writes go to $dir/meta.log.
    local dir="$1"
    mkdir -p "$dir/bin"
    echo 0 > "$dir/count"
    : > "$dir/meta.log"
    cat > "$dir/bin/tmux" <<FAKESH
#!/usr/bin/env bash
case "\${1:-}" in
    has-session) [[ -e "$dir/gone" ]] && exit 1; exit 0 ;;
    capture-pane)
        n=\$(( \$(cat "$dir/count") + 1 )); echo "\$n" > "$dir/count"
        f="$dir/screen.\$n"
        [[ -f "\$f" ]] || f="\$(ls "$dir"/screen.* | sort -t. -k2 -n | tail -1)"
        cat "\$f"; exit 0 ;;
    *) printf '%s\n' "\$*" >> "$dir/tmux.log"; exit 0 ;;
esac
FAKESH
    chmod +x "$dir/bin/tmux"
}

_hc_readiness_run() {
    local dir="$1" agent="$2" timeout="$3"
    (
        RED="" GREEN="" YELLOW="" BOLD="" DIM="" RESET=""
        _session_update_metadata_field() { printf '%s=%s\n' "$2" "$3" >> "$dir/meta.log"; }
        _tmux_run_with_timeout() { TMUX_RUN_OUTPUT="$(tmux "$@" 2>/dev/null)" || return $?; }
        _HC_SCRIPT_DIR="$ROOT/lib"; _HC_PATTERNS_LOADED=""
        source "$ROOT/lib/health-check.sh"
        PATH="$dir/bin:$PATH" CCTRL_HC_POLL_INTERVAL=0 _health_check_run "test-session" "$agent" "$timeout"
    ) 2>/dev/null
}

test_health_check_ready_requires_visible_prompt() {
    # A blank, still-booting pane is not ready; ready is reported only once
    # the composer prompt is on screen for consecutive polls.
    local dir="$TMPDIR/hcready" rc=0
    _hc_readiness_fixture "$dir"
    : > "$dir/screen.1"; : > "$dir/screen.2"; : > "$dir/screen.3"; : > "$dir/screen.4"
    printf 'Loading...\n' > "$dir/screen.5"; printf 'Loading...\n' > "$dir/screen.6"
    printf '  Claude Code\n────\n❯ \n────\n  ? for shortcuts\n' > "$dir/screen.7"
    _hc_readiness_run "$dir" claude 30 || rc=$?
    [[ "$rc" -eq 0 ]] || fail "ready path should return 0, got $rc"
    grep -qx 'health_status=ready' "$dir/meta.log" || fail "expected health_status=ready: $(cat "$dir/meta.log")"
    (( $(cat "$dir/count") >= 7 )) || fail "declared ready before the prompt was drawn (captures: $(cat "$dir/count"))"

    # Codex's update selector ("› 1. Update now") and a composer drawn behind
    # a numbered modal are never ready.
    dir="$TMPDIR/hcready-codex"
    _hc_readiness_fixture "$dir"
    printf '  Update available!\n› 1. Update now\n  2. Skip\n› Ask Codex to do anything\n' > "$dir/screen.1"
    _hc_readiness_run "$dir" codex 4 || true
    grep -qx 'health_status=timeout' "$dir/meta.log" || fail "codex selector must not be ready: $(cat "$dir/meta.log")"

    dir="$TMPDIR/hcready-codex-idle"
    _hc_readiness_fixture "$dir"
    printf '  OpenAI Codex\n› Ask Codex to do anything\n  ? for shortcuts\n' > "$dir/screen.1"
    _hc_readiness_run "$dir" codex 10 || fail "codex idle composer should be ready"
    grep -qx 'health_status=ready' "$dir/meta.log" || fail "codex idle composer should be ready: $(cat "$dir/meta.log")"

    echo "ok: health check reports ready only when the agent prompt is visible"
}

test_health_check_startup_selectors_need_human() {
    # Plan 072: unnumbered startup selectors put "❯ No, …" on screen, which
    # looks exactly like the composer line. Screens below are the real ones
    # from 2026-09-24 (folder trust, external CLAUDE.md imports) plus Codex
    # 0.153.4's directory trust. None may be ready; each is needs-human, named,
    # with the option that keeps the session; nothing is auto-answered.
    local dir screen
    assert_selector() { # agent label hint-fragment screen-text
        dir="$TMPDIR/hcsel-$2"
        _hc_readiness_fixture "$dir"
        printf '%s\n' "$4" > "$dir/screen.1"
        _hc_readiness_run "$dir" "$1" 6 || fail "$2 health check failed"
        grep -qx 'health_status=needs-human' "$dir/meta.log" || fail "$2 was not needs-human: $(cat "$dir/meta.log")"
        grep -qx "health_reason=$2" "$dir/meta.log" || fail "$2 was not named: $(cat "$dir/meta.log")"
        grep -q "^health_info=.*$3" "$dir/meta.log" || fail "$2 did not say which option keeps the session: $(cat "$dir/meta.log")"
        ! grep -q 'send-keys' "$dir/tmux.log" 2>/dev/null || fail "$2 was auto-answered: $(cat "$dir/tmux.log")"
        # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
        cctrl_source_eval '_session_pane_has_dialog "$1" "$2"' "$4" "$1" \
            || fail "_session_pane_has_dialog missed the $2 dialog"
    }

    # Folder trust (Matthew, 2026-09-25): answer it automatically, but only by
    # moving the selection to "Yes, I trust this folder" and pressing Enter
    # once the screen shows that option selected. The default "No, exit" quits.
    local trust_no trust_yes composer
    trust_no=' Accessing workspace:

 /Users/matthew/dev/tiktok-remotion

 Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open
 source project, or work from your team). If not, take a moment to review what'"'"'s in this folder first.

 Claude Code'"'"'ll be able to read, edit, and execute files here.

 Security guide

 ❯ No, exit
   Yes, I trust this folder

 Enter to confirm · Esc to cancel'
    trust_yes="${trust_no/ ❯ No, exit
   Yes, I trust this folder/   No, exit
 ❯ Yes, I trust this folder}"
    composer='  Claude Code
────
❯ 
────
  ? for shortcuts'
    dir="$TMPDIR/hcsel-folder-trust"
    _hc_readiness_fixture "$dir"
    printf '%s\n' "$trust_no" > "$dir/screen.1"; printf '%s\n' "$trust_no" > "$dir/screen.2"
    printf '%s\n' "$trust_yes" > "$dir/screen.3"; printf '%s\n' "$composer" > "$dir/screen.4"
    CCTRL_HC_SELECT_DELAY=0 _hc_readiness_run "$dir" claude 10 || fail "folder-trust auto-select failed"
    [[ "$(grep -c 'send-keys' "$dir/tmux.log")" == 2 ]] \
        && grep -n 'send-keys' "$dir/tmux.log" | head -1 | grep -q 'Down$' \
        && grep -n 'send-keys' "$dir/tmux.log" | tail -1 | grep -q 'Enter$' \
        || fail "folder trust was not answered as Down then Enter: $(cat "$dir/tmux.log")"
    grep -qx 'health_status=ready' "$dir/meta.log" || fail "session after trusting the folder was not ready: $(cat "$dir/meta.log")"
    # shellcheck disable=SC2016 # positional argument belongs to the sourced shell
    cctrl_source_eval '_session_pane_has_dialog "$1" claude' "$trust_no" || fail "_session_pane_has_dialog missed folder trust"

    # If "Yes" never becomes the selected line, nothing is confirmed.
    dir="$TMPDIR/hcsel-folder-trust-stuck"
    _hc_readiness_fixture "$dir"
    printf '%s\n' "$trust_no" > "$dir/screen.1"
    CCTRL_HC_SELECT_DELAY=0 _hc_readiness_run "$dir" claude 10 || fail "stuck folder-trust check failed"
    ! grep -q 'Enter' "$dir/tmux.log" || fail "Enter was pressed without \"Yes, I trust this folder\" selected: $(cat "$dir/tmux.log")"
    grep -qx 'health_status=needs-human' "$dir/meta.log" && grep -qx 'health_reason=folder-trust' "$dir/meta.log" \
        || fail "unselectable folder trust was not needs-human: $(cat "$dir/meta.log")"

    screen=' Allow external CLAUDE.md file imports?

 This project'"'"'s CLAUDE.md imports files outside the current working directory. Never allow this for
 third-party repositories.

 External imports:
   /Users/matthew/dev/obsidian-vault/AGENTS.md

 Important: Only use Claude Code with files you trust. Accessing untrusted files may pose security risks.

 ❯ No, disable external imports
   Yes, allow external imports

 Enter to confirm · Esc to cancel'
    assert_selector claude external-imports 'Yes, allow external imports' "$screen"

    screen='> You are in /Users/matthew/dev/new-project

  Do you trust the contents of this directory? Working with untrusted contents comes with higher risk of
  prompt injection. Trusting the directory allows project-local config, hooks, and exec policies to load.

› 1. Yes, continue
  2. No, quit

  Press enter to continue'
    assert_selector codex codex-directory-trust 'Yes, continue' "$screen"

    # An unrecognized selector is still never ready.
    screen=' Pick one

 ❯ Keep going
   Stop

 Enter to confirm · Esc to cancel'
    assert_selector claude startup-selector 'pick an option' "$screen"

    # The composer itself is still ready.
    hc_visible() { ( _HC_SCRIPT_DIR="$ROOT/lib"; _HC_PATTERNS_LOADED=""; source "$ROOT/lib/health-check.sh"; _hc_prompt_visible "$1" ); }
    hc_visible '  Claude Code
────
❯
────
  ? for shortcuts' || fail "plain composer is no longer ready"
    ! hc_visible '❯ No, exit
   Yes, I trust this folder
 Enter to confirm · Esc to cancel' || fail "a selector footer counted as a visible prompt"
    echo "ok: folder trust is answered Yes only after the selection is confirmed; import and Codex trust dialogs are needs-human, named, and never auto-answered"
}

test_health_check_detects_startup_exit() {
    # An agent that dies during startup fails the check (rc 1, exited) instead
    # of timing out or being reported ready.
    local dir="$TMPDIR/hcexit" rc=0
    _hc_readiness_fixture "$dir"
    printf 'Error: bad flag\n\ncctrl: claude exited with status 3 after 0s during startup\n' > "$dir/screen.1"
    _hc_readiness_run "$dir" claude 30 || rc=$?
    [[ "$rc" -eq 1 ]] || fail "startup exit should return 1, got $rc"
    grep -qx 'health_status=exited' "$dir/meta.log" || fail "expected exited: $(cat "$dir/meta.log")"

    dir="$TMPDIR/hcgone"; rc=0
    _hc_readiness_fixture "$dir"
    : > "$dir/screen.1"; touch "$dir/gone"
    _hc_readiness_run "$dir" claude 30 || rc=$?
    [[ "$rc" -eq 1 ]] || fail "vanished session should return 1, got $rc"
    grep -qx 'health_status=exited' "$dir/meta.log" || fail "expected exited for vanished session"

    echo "ok: health check fails fast when the agent exits during startup"
}

test_cctrl_partial_file_fails_before_running() {
    # A cctrl read mid-update (git checkout unlinks and then streams the new
    # file) must fail loudly without running anything. Truncated at a
    # function boundary, the old layout never reached `main` and exited 0.
    local dir="$TMPDIR/partial-cctrl" n out rc=0
    mkdir -p "$dir/lib" "$dir/data"
    cp -R "$ROOT/lib/." "$dir/lib/"
    n="$(grep -n '^_session_say() {' "$ROOT/cctrl" | cut -d: -f1)"
    head -n "$((n - 1))" "$ROOT/cctrl" > "$dir/cctrl"
    chmod +x "$dir/cctrl"
    out="$(CCTRL_DATA_DIR="$dir/data" "$dir/cctrl" peer send nobody --allow-unknown -- hi 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "truncated cctrl must not exit 0: $out"
    [[ ! -e "$dir/data/messages.jsonl" ]] || fail "truncated cctrl must not act before failing"
    [[ -z "$(ls -A "$dir/data")" ]] || fail "truncated cctrl wrote state: $(ls -A "$dir/data")"

    echo "ok: a partially written cctrl fails without running"
}

test_running_scripts_ignore_inplace_rewrite() {
    # A long-lived process must not execute bytes written into its script
    # after launch. The session wrapper lives as long as its session; cctrl
    # itself must stop reading at its final exit.
    local dir="$TMPDIR/inplace" pid
    mkdir -p "$dir/lib"
    cp "$ROOT/lib/session-wrapper.sh" "$dir/lib/session-wrapper.sh"
    printf '#!/usr/bin/env bash\nsleep 2\n' > "$dir/claude"
    chmod +x "$dir/claude" "$dir/lib/session-wrapper.sh"
    ( PATH="$dir:$PATH" CCTRL_EARLY_EXIT_WINDOW_SECONDS=0 \
        "$dir/lib/session-wrapper.sh" claude "$dir/marker" --x >/dev/null 2>&1 ) &
    pid=$!
    sleep 0.5
    python3 - "$dir/lib/session-wrapper.sh" "$dir/PWNED" <<'PY'
import sys
path, flag = sys.argv[1], sys.argv[2]
old = open(path).read()
with open(path, "w") as f:  # same inode, like cp or a shell redirect
    f.write("#" * len(old) + ("\ntouch %s\n" % flag) * 50)
PY
    wait "$pid" || true
    [[ ! -e "$dir/PWNED" ]] || fail "running session wrapper executed bytes rewritten into its file"

    tail -n 6 "$ROOT/cctrl" | grep -q '^    exit \$?$' || fail "cctrl must exit right after main"
    [[ "$(tail -n 1 "$ROOT/cctrl")" == "}" ]] || fail "cctrl body must be a single brace group"

    echo "ok: running wrapper and cctrl never read bytes rewritten after launch"
}

test_session_wrapper_reports_startup_exit() {
    # The wrapper propagates the agent's exit status and, for a startup death,
    # prints the marker line the health check keys on.
    local bin="$TMPDIR/wrapexit-bin" out rc=0
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\necho "Error: bad flag" >&2\nexit 3\n' > "$bin/claude"
    chmod +x "$bin/claude"
    out="$(PATH="$bin:$PATH" CCTRL_EARLY_EXIT_HOLD_SECONDS=0 \
        "$ROOT/lib/session-wrapper.sh" claude "$TMPDIR/wrapexit-marker" --flag 2>&1 </dev/null)" || rc=$?
    [[ "$rc" -eq 3 ]] || fail "wrapper should exit with the agent status 3, got $rc"
    assert_contains "$out" "cctrl: claude exited with status 3 after"

    rc=0
    out="$(PATH="$bin:$PATH" CCTRL_EARLY_EXIT_WINDOW_SECONDS=0 \
        "$ROOT/lib/session-wrapper.sh" claude "$TMPDIR/wrapexit-marker" --flag 2>&1 </dev/null)" || rc=$?
    [[ "$rc" -eq 3 ]] || fail "wrapper should still propagate status outside the window, got $rc"
    assert_not_contains "$out" "during startup"

    echo "ok: session wrapper reports startup exits and propagates status"
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

test_codex_lifecycle_ingestion() {
    local root="$TMPDIR/codex-lifecycle-062" fixtures="$ROOT/tests/fixtures/codex-lifecycle/lifecycle-sequences.json"
    local expected="$ROOT/tests/fixtures/codex-lifecycle/lifecycle-expected-records.json" observer="$ROOT/hooks/codex-session-observer.py"
    rm -rf "$root"; mkdir -p "$root"

    lifecycle_record_path() {
        local meta="$1" data="$2" task_id="$3"
        # shellcheck disable=SC2016 # evaluated inside the sourced cctrl shell
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_DATA_DIR="$data" CCTRL_HOST_ID_FILE="$data/host-id" \
            cctrl_source_eval '_task_record_file codex "$(_cctrl_host_id)" "$1"' "$task_id"
    }
    lifecycle_event() {
        local name="$1" meta="$2" data="$3" payload="$4" source_kind="${5:-}" confidence="${6:-}"
        local source_task_id="${7:-}" session_name="${8:-}" launch_id="${9:-}"
        printf '%s' "$payload" | CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" \
            CCTRL_HOST_ID_FILE="$data/host-id" CCTRL_BIN="$ROOT/cctrl" \
            CCTRL_CODEX_SOURCE_KIND="$source_kind" CCTRL_CODEX_SOURCE_CONFIDENCE="$confidence" \
            CCTRL_CODEX_SOURCE_TASK_ID="$source_task_id" CCTRL_SESSION_KIND="${session_name:+tmux}" \
            CCTRL_SESSION_NAME="$session_name" CCTRL_SESSION_LAUNCH_ID="$launch_id" python3 "$observer" \
            || fail "lifecycle observer failed open for $name"
    }
    fixture_event() {
        jq -c --arg name "$1" '.events[$name]' "$fixtures"
    }

    local meta="$root/meta" data="$root/data" payload record before after
    mkdir -p "$meta" "$data"
    payload="$(fixture_event no_id)"
    lifecycle_event no-id "$meta" "$data" "$payload"
    [[ -z "$(find "$meta" -maxdepth 1 -name 'task-*.json' -print -quit)" ]] || fail "no-id lifecycle event created a synthetic task"

    payload="$(fixture_event startup | jq -c '.cwd="<WORKSPACE>" | .model="must-not-persist" | .title="must-not-persist" | .sandbox="must-not-persist" | .approval_policy="must-not-persist" | .source_kind="codex-app" | .source_confidence="authoritative"')"
    lifecycle_event startup "$meta" "$data" "$payload"
    record="$(lifecycle_record_path "$meta" "$data" '<THREAD_ID>')"
    jq -e --slurpfile expected "$expected" '
        .origin == $expected[0].generic.origin and
        .registered_by_cctrl == true and .launched_by_cctrl == false and
        .execution_runtime == "unknown" and .control_owner == "unknown" and
        .restore_strategy == null and .lifecycle_state == "active" and
        (.cwd == null and .model == null and .title == null and .sandbox == null and .approval_policy == null)
    ' "$record" >/dev/null || fail "generic lifecycle registration guessed provenance or persisted settings"

    before="$(shasum -a 256 "$record" | awk '{print $1}')"
    lifecycle_event duplicate "$meta" "$data" "$payload"
    after="$(shasum -a 256 "$record" | awk '{print $1}')"
    [[ "$before" == "$after" ]] || fail "duplicate lifecycle replay was not idempotent"

    lifecycle_event resume "$meta" "$data" "$(fixture_event resume)"
    lifecycle_event clear "$meta" "$data" "$(fixture_event clear)"
    lifecycle_event pre-compact "$meta" "$data" "$(fixture_event pre_compact)"
    lifecycle_event post-compact "$meta" "$data" "$(fixture_event post_compact)"
    lifecycle_event end "$meta" "$data" "$(fixture_event end)"
    [[ -f "$record" ]] || fail "SessionEnd deleted the canonical task record"
    jq -e '.lifecycle_state == "closed" and .origin == "unknown" and .control_owner == "unknown" and .restore_strategy == null' "$record" >/dev/null \
        || fail "SessionEnd changed provenance, ownership, or archive state"

    lifecycle_event fork "$meta" "$data" "$(fixture_event fork)"
    lifecycle_event fork-of-fork "$meta" "$data" "$(fixture_event fork_of_fork)"
    lifecycle_event subagent "$meta" "$data" "$(fixture_event subagent)"
    local fork_record fork2_record subagent_record
    fork_record="$(lifecycle_record_path "$meta" "$data" '<FORK_THREAD_ID>')"
    fork2_record="$(lifecycle_record_path "$meta" "$data" '<FORK_OF_FORK_THREAD_ID>')"
    subagent_record="$(lifecycle_record_path "$meta" "$data" '<SUBAGENT_THREAD_ID>')"
    jq -e --slurpfile expected "$expected" '.lineage == $expected[0].fork' "$fork_record" >/dev/null || fail "fork lineage projection differed"
    jq -e --slurpfile expected "$expected" '.lineage == $expected[0].fork_of_fork' "$fork2_record" >/dev/null || fail "fork-of-fork root was not explicit traversal"
    jq -e --slurpfile expected "$expected" '.lineage == $expected[0].subagent' "$subagent_record" >/dev/null || fail "subagent ancestry was conflated with fork ancestry"

    lifecycle_event app "$meta" "$data" "$(fixture_event authoritative_app)" codex-app authoritative '<APP_THREAD_ID>'
    local app_record
    app_record="$(lifecycle_record_path "$meta" "$data" '<APP_THREAD_ID>')"
    jq -e --slurpfile expected "$expected" '
        .origin == $expected[0].authoritative_app.origin and .registered_by_cctrl == true and
        .launched_by_cctrl == false and .execution_runtime == "unknown" and
        .control_owner == "unknown" and .restore_strategy == null
    ' "$app_record" >/dev/null || fail "authoritative source-kind registration claimed control ownership"

    lifecycle_event stale-source "$meta" "$data" \
        "$(fixture_event authoritative_app | jq -c '.session_id="unbound-source-id"')" \
        codex-app authoritative different-task-id
    local stale_source_record
    stale_source_record="$(lifecycle_record_path "$meta" "$data" unbound-source-id)"
    jq -e '.origin == "unknown" and .control_owner == "unknown"' "$stale_source_record" >/dev/null \
        || fail "source classification not bound to the observed provider task id"

    # A later generic hook must not downgrade a canonical cctrl launch receipt.
    local managed_meta="$root/managed-meta" managed_data="$root/managed-data" managed_record
    mkdir -p "$managed_meta" "$managed_data"
    CCTRL_SESSION_METADATA_DIR="$managed_meta" CCTRL_DATA_DIR="$managed_data" CCTRL_HOST_ID_FILE="$managed_data/host-id" \
        cctrl_source_eval '_session_write_metadata "TMUX--managed" /tmp directory /tmp label purpose prompt cmd "" codex "managed-id" ""'
    managed_record="$(lifecycle_record_path "$managed_meta" "$managed_data" managed-id)"
    lifecycle_event managed "$managed_meta" "$managed_data" "$(fixture_event startup | jq -c '.session_id="managed-id"')"
    jq -e '.origin == "cctrl" and .launched_by_cctrl == true and .control_owner == "cctrl" and .execution_runtime == "tmux" and .restore_strategy == "tmux"' \
        "$managed_record" >/dev/null || fail "late lifecycle event overwrote cctrl launch provenance"

    # SessionStart may race provider-id discovery for a cctrl launch. The
    # inherited tmux identity must promote the provisional launch receipt.
    local provisional_meta="$root/provisional-meta" provisional_data="$root/provisional-data" provisional_record
    mkdir -p "$provisional_meta" "$provisional_data"
    CCTRL_SESSION_METADATA_DIR="$provisional_meta" CCTRL_DATA_DIR="$provisional_data" CCTRL_HOST_ID_FILE="$provisional_data/host-id" \
        cctrl_source_eval '_session_write_metadata "TMUX--provisional" /tmp directory /tmp label purpose prompt cmd "" codex "" ""'
    lifecycle_event provisional "$provisional_meta" "$provisional_data" \
        "$(fixture_event startup | jq -c '.session_id="provisional-id"')" "" "" "" "TMUX--provisional"
    provisional_record="$(lifecycle_record_path "$provisional_meta" "$provisional_data" provisional-id)"
    jq -e '.origin == "cctrl" and .launched_by_cctrl == true and .control_owner == "cctrl" and .execution_runtime == "tmux" and .restore_strategy == "tmux"' \
        "$provisional_record" >/dev/null || fail "lifecycle race lost provisional cctrl launch provenance"
    [[ -z "$(find "$provisional_meta" -maxdepth 1 -name 'launch-*.json' -print -quit)" ]] \
        || fail "lifecycle promotion left a split provisional record"

    # New launches carry an independently inherited launch token. Only that
    # exact generation may receive a lifecycle-bound identity proof; a delayed
    # hook from a reused tmux name cannot bind itself to the replacement.
    local token_meta="$root/token-meta" token_data="$root/token-data" token_launch token_record
    mkdir -p "$token_meta" "$token_data"
    CCTRL_SESSION_METADATA_DIR="$token_meta" CCTRL_DATA_DIR="$token_data" CCTRL_HOST_ID_FILE="$token_data/host-id" \
        CCTRL_PENDING_LAUNCH_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        cctrl_source_eval '_session_write_metadata "TMUX--token" /tmp directory /tmp label purpose prompt cmd "" codex "" ""'
    lifecycle_event token "$token_meta" "$token_data" \
        "$(fixture_event startup | jq -c '.session_id="token-task"')" "" "" "" "TMUX--token" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    token_record="$(lifecycle_record_path "$token_meta" "$token_data" token-task)"
    jq -e '.terminal_identity_proof.evidence_kind=="codex-lifecycle-hook-launch-binding" and
      .terminal_identity_proof.provisional_launch_id=="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$token_record" >/dev/null \
      || fail "exact lifecycle launch token was not persisted"

    CCTRL_SESSION_METADATA_DIR="$token_meta" CCTRL_DATA_DIR="$token_data" CCTRL_HOST_ID_FILE="$token_data/host-id" \
        CCTRL_PENDING_LAUNCH_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
        cctrl_source_eval '_session_write_metadata "TMUX--reused" /tmp directory /tmp label purpose prompt cmd "" codex "" ""'
    lifecycle_event delayed-old "$token_meta" "$token_data" \
        "$(fixture_event startup | jq -c '.session_id="old-task"')" "" "" "" "TMUX--reused" cccccccccccccccccccccccccccccccc
    token_launch="$token_meta/launch-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json"
    [[ -f "$token_launch" ]] || fail "wrong-generation lifecycle hook consumed the replacement launch receipt"
    jq -e '.provider_task_id==null and .provisional_launch_id=="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$token_launch" >/dev/null \
      || fail "wrong-generation lifecycle hook mutated the replacement launch"

    # Delivery order converges because lifecycle state is reduced by observed_at.
    local order_a="$root/order-a" order_b="$root/order-b" order_data_a="$root/order-data-a" order_data_b="$root/order-data-b"
    mkdir -p "$order_a" "$order_b" "$order_data_a" "$order_data_b"
    printf '0123456789abcdef0123456789abcdef\n' > "$order_data_a/host-id"
    cp "$order_data_a/host-id" "$order_data_b/host-id"; chmod 600 "$order_data_a/host-id" "$order_data_b/host-id"
    lifecycle_event order-a-start "$order_a" "$order_data_a" "$(fixture_event startup)"
    lifecycle_event order-a-end "$order_a" "$order_data_a" "$(fixture_event end)"
    lifecycle_event order-b-end "$order_b" "$order_data_b" "$(fixture_event end)"
    lifecycle_event order-b-start "$order_b" "$order_data_b" "$(fixture_event startup)"
    local order_record_a order_record_b
    order_record_a="$(lifecycle_record_path "$order_a" "$order_data_a" '<THREAD_ID>')"
    order_record_b="$(lifecycle_record_path "$order_b" "$order_data_b" '<THREAD_ID>')"
    [[ "$(jq -S '{provider,provider_task_id,origin,registered_by_cctrl,launched_by_cctrl,execution_runtime,control_owner,lifecycle_state,restore_strategy,lineage,last_observed_at}' "$order_record_a")" == \
       "$(jq -S '{provider,provider_task_id,origin,registered_by_cctrl,launched_by_cctrl,execution_runtime,control_owner,lifecycle_state,restore_strategy,lineage,last_observed_at}' "$order_record_b")" ]] \
        || fail "out-of-order lifecycle delivery did not converge"
    jq -e '.lifecycle_state == "closed"' "$order_record_b" >/dev/null || fail "SessionEnd-before-start did not converge to closed"

    # Concurrent duplicate delivery must produce one canonical valid record.
    local concurrent_meta="$root/concurrent-meta" concurrent_data="$root/concurrent-data" p1 p2 rc1=0 rc2=0
    mkdir -p "$concurrent_meta" "$concurrent_data"
    printf '%s' "$(fixture_event startup | jq -c '.session_id="concurrent-id"')" | \
        CCTRL_DATA_DIR="$concurrent_data" CCTRL_SESSION_METADATA_DIR="$concurrent_meta" CCTRL_HOST_ID_FILE="$concurrent_data/host-id" CCTRL_BIN="$ROOT/cctrl" python3 "$observer" & p1=$!
    printf '%s' "$(fixture_event startup | jq -c '.session_id="concurrent-id"')" | \
        CCTRL_DATA_DIR="$concurrent_data" CCTRL_SESSION_METADATA_DIR="$concurrent_meta" CCTRL_HOST_ID_FILE="$concurrent_data/host-id" CCTRL_BIN="$ROOT/cctrl" python3 "$observer" & p2=$!
    wait "$p1" || rc1=$?; wait "$p2" || rc2=$?
    [[ "$rc1" -eq 0 && "$rc2" -eq 0 ]] || fail "concurrent observers did not fail open"
    record="$(lifecycle_record_path "$concurrent_meta" "$concurrent_data" concurrent-id)"
    # shellcheck disable=SC2016 # positional argument belongs to the sourced cctrl shell
    CCTRL_SESSION_METADATA_DIR="$concurrent_meta" CCTRL_DATA_DIR="$concurrent_data" CCTRL_HOST_ID_FILE="$concurrent_data/host-id" \
        cctrl_source_eval '_task_record_normalize_json "$1" >/dev/null' "$record" || fail "concurrent lifecycle record is invalid"

    # Boundary failures are actionable, payload-free, and never block hooks.
    local failure_payload failure_log="$root/failure.log" fake_bin="$root/slow-cctrl"
    failure_payload="$(fixture_event startup | jq -c '.session_id="secret-payload-id"')"
    printf '%s' "$failure_payload" | CCTRL_BIN="$root/missing-cctrl" python3 "$observer" 2> "$failure_log" \
        || fail "command-not-found did not fail open"
    grep -q 'ingest-command-not-found' "$failure_log" || fail "command-not-found reason code missing"
    ! grep -q 'secret-payload-id' "$failure_log" || fail "failure log leaked lifecycle payload"
    printf '#!/usr/bin/env bash\nsleep 3\n' > "$fake_bin"; chmod +x "$fake_bin"
    printf '%s' "$failure_payload" | CCTRL_BIN="$fake_bin" python3 "$observer" 2> "$failure_log" || fail "timeout did not fail open"
    grep -q 'ingest-timeout' "$failure_log" || fail "timeout reason code missing"
    ! grep -q 'secret-payload-id' "$failure_log" || fail "timeout log leaked lifecycle payload"

    local failed_meta="$root/failed-meta" failed_data="$root/failed-data"
    mkdir -p "$failed_meta" "$failed_data"
    printf '%s' "$failure_payload" | CCTRL_TASK_REGISTRY_FAIL_BEFORE_RENAME=1 CCTRL_DATA_DIR="$failed_data" \
        CCTRL_SESSION_METADATA_DIR="$failed_meta" CCTRL_HOST_ID_FILE="$failed_data/host-id" CCTRL_BIN="$ROOT/cctrl" \
        python3 "$observer" 2> "$failure_log" || fail "persistence failure did not fail open"
    grep -q 'ingest-exit-74' "$failure_log" || fail "persistence failure reason code missing"
    [[ -z "$(find "$failed_meta" -maxdepth 1 -name 'task-*.json' -print -quit)" ]] || fail "failed persistence left a canonical record"
    [[ -z "$(find "$failed_meta" -maxdepth 1 -type f -name '*spool*' -print -quit)" ]] || fail "failure created a retry spool"

    # Hidden command accepts exactly the normalized stdin envelope and rejects extras.
    local normalized="$root/normalized.json"
    python3 - "$observer" "$fixtures" "$normalized" <<'PY'
import importlib.util,json,sys
observer,fixtures,out=sys.argv[1:]
spec=importlib.util.spec_from_file_location("observer",observer); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
payload=json.load(open(fixtures))["events"]["startup"]
json.dump(module.normalize_codex_lifecycle_event(payload),open(out,"w"))
PY
    if jq '.unexpected="rejected"' "$normalized" | CCTRL_DATA_DIR="$root/invalid-data" CCTRL_SESSION_METADATA_DIR="$root/invalid-meta" \
        CCTRL_HOST_ID_FILE="$root/invalid-data/host-id" "$ROOT/cctrl" session ingest-event >/dev/null 2>&1; then
        fail "ingest-event accepted a non-allowlisted envelope field"
    fi
    echo "ok: Codex lifecycle ingestion is bounded, conservative, convergent, lineage-aware, and fail-open"
}

test_codex_app_server_adapter() {
    local -x CCTRL_CODEX_APP_SERVER_TRANSPORT=jsonl
    local fake_root="$TMPDIR/codex-app-server" fake="$TMPDIR/codex-app-server/codex"
    local trace="$TMPDIR/codex-app-server/rpc-trace" pid_file="$TMPDIR/codex-app-server/proxy.pid"
    mkdir -p "$fake_root"
    cat > "$fake" <<'PY'
#!/usr/bin/python3
import json
import os
import signal
import sys
import time
from pathlib import Path

mode = os.environ.get("FAKE_CODEX_MODE", "success")
trace_path = os.environ.get("FAKE_CODEX_TRACE")
pid_path = os.environ.get("FAKE_CODEX_PID")
term_path = os.environ.get("FAKE_CODEX_TERM")
daemon_fail = os.environ.get("FAKE_CODEX_DAEMON_FAIL") == "1"
cli_version = os.environ.get("FAKE_CODEX_CLI_VERSION", "1.2.3")
server_version = os.environ.get("FAKE_CODEX_SERVER_VERSION", cli_version)

def trace(value):
    if trace_path:
        with open(trace_path, "a", encoding="utf-8") as handle:
            handle.write(value + "\n")

def send(value):
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()

args = sys.argv[1:]
if args == ["--version"]:
    print(f"codex-cli {cli_version}")
    raise SystemExit(0)
if args[:3] == ["app-server", "daemon", "version"]:
    if daemon_fail:
        raise SystemExit(9)
    if mode == "connect-timeout":
        time.sleep(1)
    print(json.dumps({"cliVersion": cli_version, "appServerVersion": server_version}))
    raise SystemExit(0)
if args[:2] == ["app-server", "generate-json-schema"]:
    output = Path(args[args.index("--out") + 1])
    output.mkdir(parents=True, exist_ok=True)
    methods = [] if mode == "schema-missing" else ["thread/start", "thread/read", "thread/list", "turn/start"]
    variants = [
        {"type": "object", "properties": {"method": {"type": "string", "enum": [method]}}}
        for method in methods
    ]
    schema = {"title": "ClientRequest", "oneOf": variants}
    if mode == "schema-malformed":
        schema = {"title": "not-client-requests", "methods": methods}
    (output / "ClientRequest.json").write_text(json.dumps(schema))
    raise SystemExit(0)
if args[:2] != ["app-server", "proxy"]:
    raise SystemExit(2)

if pid_path:
    Path(pid_path).write_text(str(os.getpid()))

def terminate(_signum, _frame):
    if term_path:
        Path(term_path).write_text("terminated")
    if mode == "ignore-term":
        return
    raise SystemExit(0)

signal.signal(signal.SIGTERM, terminate)

for raw in sys.stdin:
    message = json.loads(raw)
    method = message.get("method")
    if method:
        trace(method)
    elif "error" in message:
        trace(f"client-error:{message['error'].get('code')}")
    elif "result" in message:
        trace("client-result")
    if method == "initialize":
        if mode == "handshake-timeout":
            time.sleep(1)
            continue
        if mode == "crash":
            raise SystemExit(9)
        if mode == "malformed":
            sys.stdout.write("{not-json\n")
            sys.stdout.flush()
            continue
        result = {
            "userAgent": f"codex-cli/{server_version}",
            "codexHome": "/tmp/fake-codex-home",
            "platformFamily": "unix",
            "platformOs": "macos",
        }
        if mode == "protocol-mismatch":
            result["protocolVersion"] = 999
        send({"method": "server/ready", "params": {"fake": True}})
        send({"id": message["id"], "result": result})
        continue
    if method == "initialized":
        continue
    if method in {"thread/start", "thread/read", "thread/list", "turn/start"}:
        if mode in {"request-timeout", "inactivity-timeout"}:
            time.sleep(1)
            continue
        if mode == "unsupported-method":
            send({"id": message["id"], "error": {"code": -32601, "message": "unsupported"}})
            continue
        if mode == "mismatched-id":
            send({"id": f"wrong-{message['id']}", "result": {}})
            continue
        if mode == "typed-id-mismatch":
            send({"id": 1 if isinstance(message["id"], str) else "1", "result": {}})
            continue
        if mode == "server-request":
            send({"id": "approval-1", "method": "item/commandExecution/requestApproval", "params": {"command": "fake"}})
            callback_reply = json.loads(sys.stdin.readline())
            trace("callback-result" if "result" in callback_reply else "callback-error")
        if mode == "unsupported-request":
            send({"id": "mystery-1", "method": "server/mystery", "params": {}})
            callback_reply = json.loads(sys.stdin.readline())
            trace(f"client-error:{callback_reply.get('error', {}).get('code')}")
            time.sleep(1)
            continue
        if method == "thread/list" and os.environ.get("FAKE_CODEX_THREAD_LIST") == "1":
            if message.get("params", {}).get("cursor") == "cursor-one":
                send({"id": message["id"], "result": {"data": [{"id": "thread-two", "control_owner": "app"}], "nextCursor": None}})
            else:
                send({"id": message["id"], "result": {"data": [{"id": "thread-one", "control_owner": "app"}], "nextCursor": "cursor-one"}})
        else:
            send({"id": message["id"], "result": {"method": method, "ok": True}})

if mode == "ignore-term":
    while True:
        time.sleep(1)
PY
    chmod +x "$fake"

    : > "$trace"
    local out rc=0
    out="$(PATH="$(_test_path)" CCTRL_CODEX_PLATFORM_CANDIDATES="$fake" \
        FAKE_CODEX_TRACE="$trace" FAKE_CODEX_PID="$pid_file" \
        "$ROOT/cctrl" codex capabilities --json)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "capability discovery failed: $out"
    jq -e '
      .schema_version == 1 and .cli_version == "1.2.3" and .server_version == "1.2.3"
      and .transport.kind == "desktop-daemon-proxy"
      and .transport.discovery_source == "platform-installation"
      and .runtime_facts.userAgent == "codex-cli/1.2.3"
      and ([.methods[].status] | all(. == "supported"))
      and (.errors | length) == 0
    ' <<< "$out" >/dev/null || fail "unexpected capability schema: $out"
    [[ "$(sort -u "$trace" | tr '\n' ' ')" == "initialize initialized " ]] \
        || fail "capability discovery invoked a non-read-only RPC: $(cat "$trace")"

    : > "$trace"
    out="$(PATH="$(_test_path)" CCTRL_CODEX_BIN="$fake" FAKE_CODEX_SERVER_VERSION=9.9.9 \
        FAKE_CODEX_TRACE="$trace" "$ROOT/cctrl" codex capabilities --json)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "version mismatch diagnostics should complete"
    jq -e '[.methods[].status] | all(. == "unknown")' <<< "$out" >/dev/null \
        || fail "version mismatch must leave method support unknown"
    jq -e '[.methods[].evidence] | all(. == "version-mismatch")' <<< "$out" >/dev/null \
        || fail "version mismatch evidence not recorded"

    rc=0
    out="$(PATH="$(_test_path)" CCTRL_CODEX_BIN="$fake" CCTRL_CODEX_APP_SERVER_SOCKET=/tmp/fake-codex.sock \
        FAKE_CODEX_DAEMON_FAIL=1 "$ROOT/cctrl" codex capabilities --json)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "explicit socket discovery incorrectly required the default daemon: $out"
    [[ "$(jq -r '.transport.endpoint' <<< "$out")" == "/tmp/fake-codex.sock" ]] \
        || fail "explicit App Server socket was not reported"

    rc=0
    out="$(PATH="$(_test_path)" CCTRL_CODEX_BIN="$fake" FAKE_CODEX_MODE=schema-malformed \
        "$ROOT/cctrl" codex capabilities --json)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "malformed schema diagnostics should complete"
    jq -e '[.methods[].status] | all(. == "unknown")' <<< "$out" >/dev/null \
        || fail "malformed schema must leave method support unknown"

    rc=0
    out="$(PATH="$(_test_path)" CCTRL_CODEX_BIN="$fake" CCTRL_CODEX_CONNECT_TIMEOUT=invalid \
        "$ROOT/cctrl" codex capabilities --json)" || rc=$?
    [[ "$rc" -eq 64 ]] || fail "invalid timeout environment should exit 64, got $rc"
    jq -e '.errors[0].code == 64 and .errors[0].phase == "usage"' <<< "$out" >/dev/null \
        || fail "invalid timeout environment did not return normalized JSON"

    /usr/bin/python3 - "$ROOT" "$fake" "$trace" "$pid_file" <<'PY'
import errno
import importlib.util
import os
import sys
import time

root, fake, trace, pid_file = sys.argv[1:]
spec = importlib.util.spec_from_file_location("codex_app_server", os.path.join(root, "lib", "codex_app_server.py"))
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

runtime = module.Runtime(fake, "test", "1.2.3")

def set_mode(mode):
    os.environ["FAKE_CODEX_MODE"] = mode
    os.environ["FAKE_CODEX_TRACE"] = trace
    os.environ["FAKE_CODEX_PID"] = pid_file
    try:
        os.unlink(pid_file)
    except FileNotFoundError:
        pass

def assert_reaped():
    if not os.path.exists(pid_file):
        return
    pid = int(open(pid_file).read())
    try:
        os.kill(pid, 0)
    except OSError as exc:
        if exc.errno == errno.ESRCH:
            return
        raise
    raise AssertionError(f"proxy process {pid} was not reaped")

set_mode("server-request")
callbacks = []
with module.AppServerClient(
    runtime,
    timeouts=module.Timeouts(connect=.3, handshake=.3, request=.3, inactivity=.3, terminate=.1),
    server_request_callback=lambda method, params: callbacks.append((method, params)) or {"decision": "accept"},
) as client:
    client.initialize()
    client.thread_start({"ephemeral": True})
    client.thread_read("fake-thread")
    client.thread_list({"limit": 1})
    client.turn_start("fake-thread", [{"type": "text", "text": "fake"}])
    client.request("thread/list", {}, request_id="string-request-id")
assert callbacks and callbacks[0][0] == "item/commandExecution/requestApproval"
assert_reaped()

cases = [
    ("connect-timeout", module.EXIT_CONNECT, "initialize", .1, .3, .3, .3),
    ("handshake-timeout", module.EXIT_HANDSHAKE, "initialize", .3, .1, .3, .3),
    ("request-timeout", module.EXIT_REQUEST_TIMEOUT, "request", .3, .3, .1, .3),
    ("inactivity-timeout", module.EXIT_INACTIVITY_TIMEOUT, "request", .3, .3, .4, .1),
    ("crash", module.EXIT_EOF, "initialize", .3, .3, .3, .3),
    ("malformed", module.EXIT_PROTOCOL, "initialize", .3, .3, .3, .3),
    ("protocol-mismatch", module.EXIT_PROTOCOL, "initialize", .3, .3, .3, .3),
    ("mismatched-id", module.EXIT_PROTOCOL, "request", .3, .3, .3, .3),
    ("unsupported-method", module.EXIT_SERVER_ERROR, "request", .3, .3, .3, .3),
    ("unsupported-request", module.EXIT_SERVER_REQUEST, "request", .3, .3, .3, .3),
]
for mode, expected, operation, connect, handshake, request, inactivity in cases:
    set_mode(mode)
    caught = None
    try:
        with module.AppServerClient(
            runtime,
            timeouts=module.Timeouts(
                connect=connect,
                handshake=handshake,
                request=request,
                inactivity=inactivity,
                terminate=.05,
            ),
        ) as client:
            client.initialize()
            if operation == "request":
                client.thread_list()
    except module.AdapterError as exc:
        caught = exc
    assert caught is not None, f"{mode} did not fail"
    assert caught.exit_code == expected, (mode, caught.exit_code, expected, caught.reason)
    assert_reaped()

assert "client-error:-32601" in open(trace).read()

set_mode("typed-id-mismatch")
caught = None
try:
    with module.AppServerClient(
        runtime,
        timeouts=module.Timeouts(connect=.3, handshake=.3, request=.3, inactivity=.3, terminate=.05),
    ) as client:
        client.initialize()
        client.request("thread/list", {}, request_id="1")
except module.AdapterError as exc:
    caught = exc
assert caught is not None and caught.exit_code == module.EXIT_PROTOCOL
assert_reaped()

term_file = trace + ".term"
set_mode("ignore-term")
os.environ["FAKE_CODEX_TERM"] = term_file
try:
    os.unlink(term_file)
except FileNotFoundError:
    pass
with module.AppServerClient(
    runtime,
    timeouts=module.Timeouts(connect=.3, handshake=.3, request=.3, inactivity=.3, terminate=.05),
) as client:
    client.initialize()
assert os.path.exists(term_file), "SIGTERM escalation was not attempted"
assert_reaped()
os.environ.pop("FAKE_CODEX_TERM", None)

set_mode("server-request")
caught = None
try:
    with module.AppServerClient(
        runtime,
        timeouts=module.Timeouts(connect=.3, handshake=.3, request=.1, inactivity=.3, terminate=.05),
        server_request_callback=lambda _method, _params: time.sleep(1),
    ) as client:
        client.initialize()
        client.thread_list()
except module.AdapterError as exc:
    caught = exc
assert caught is not None and caught.exit_code == module.EXIT_REQUEST_TIMEOUT
assert_reaped()
PY

    out="$(PATH="$(_test_path)" "$ROOT/cctrl" codex capabilities --help)" \
        || fail "Codex capabilities help command failed"
    assert_contains "$out" "capabilities"

    rc=0
    out="$(PATH="$(_test_path)" CCTRL_CODEX_BIN="$fake" FAKE_CODEX_THREAD_LIST=1 \
        python3 "$ROOT/lib/codex_app_server.py" threads --json)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "App Server thread snapshot failed: $out"
    jq -e '.schema_version == 1 and .status == "available" and .complete == true and
      (.source_cursor | test("^[0-9a-f]{64}$")) and (.threads | map(.id)) == ["thread-one","thread-two"]' \
        <<< "$out" >/dev/null || fail "App Server thread snapshot schema is wrong: $out"
    echo "ok: Codex App Server adapter handles discovery, framing, failures, and cleanup"
}

test_codex_hook_installation_is_additive_and_observer_is_bounded() {
    local codex_root="$TMPDIR/hooks-061/codex"
    local claude_root="$TMPDIR/hooks-061/claude" config="$TMPDIR/hooks-061/codex/hooks.json"
    local original="$TMPDIR/hooks-061/original-hooks.json" out rc digest_once digest_twice
    local real_hooks_before real_hooks_after real_trust_before real_trust_after live_before live_after
    mkdir -p "$codex_root" "$claude_root"

    file_digest() {
        if [[ -f "$1" ]]; then shasum -a 256 "$1" | awk '{print $1}'; else printf 'absent'; fi
    }

    real_hooks_before="$(file_digest "$HOME/.codex/hooks.json")"
    real_trust_before="$(file_digest "$HOME/.codex/config.toml")"

    cat > "$config" <<'JSON'
{
  "theme": {"name": "user", "values": [1, {"two": true}]},
  "hooks": {
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": "cctrl hooks run pre-tool-use"}], "matcher": "Bash"},
      {"hooks": [{"type": "command", "command": "cctrl hooks run pre-tool-use"}, {"type": "command", "command": "other pre"}], "matcher": "Bash", "timeout": 9},
      {"hooks": [{"type": "command", "command": "cctrl hooks run pre-tool-use"}], "matcher": "Read"},
      {"hooks": [{"type": "command", "command": "echo cctrl hooks run pre-tool-use"}], "matcher": "Bash"}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "cctrl hooks run stop"}]},
      {"hooks": [{"type": "command", "command": "cctrl hooks run stop"}, {"type": "command", "command": "other stop"}], "async": true},
      {"hooks": [{"type": "command", "command": "/old/cctrl/hooks/notify.sh stop"}]}
    ],
    "PermissionRequest": [{"hooks": [{"type": "command", "command": "third-party permission"}], "matcher": "Shell"}],
    "SessionStart": [{"hooks": [{"type": "command", "command": "cctrl hooks run codex-observe"}], "custom": "keep"}],
    "OtherEvent": [{"hooks": [{"type": "command", "command": "cctrl hooks run stop"}]}]
  },
  "thirdParty": {"enabled": true}
}
JSON
    cp "$config" "$original"
    cat > "$claude_root/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"other claude pre"}]}],"Stop":[{"_gstack_source":true,"hooks":[{"type":"command","command":"other claude stop"}]}]}}
JSON

    out="$(CODEX_HOME="$codex_root" CLAUDE_CONFIG_DIR="$claude_root" "$ROOT/cctrl" hooks install)"
    assert_contains "$out" "Exact pre-replace backup:"
    python3 - "$config" <<'PY'
import json
import sys

cfg = json.load(open(sys.argv[1]))
hooks = cfg["hooks"]
assert cfg["theme"] == {"name": "user", "values": [1, {"two": True}]}
assert cfg["thirdParty"] == {"enabled": True}

def leaves(event):
    return [leaf for wrapper in hooks[event] for leaf in wrapper.get("hooks", [])]

def count(event, command):
    return sum(leaf == {"type": "command", "command": command} for leaf in leaves(event))

assert count("PreToolUse", "cctrl hooks run pre-tool-use") == 1
assert count("Stop", "cctrl hooks run stop") == 1
assert count("PermissionRequest", "cctrl hooks run notify") == 1
for event in ("SessionStart", "SessionEnd", "PreCompact", "PostCompact"):
    assert count(event, "cctrl hooks run codex-observe") == 1
assert any(w.get("timeout") == 9 and w["hooks"] == [{"type":"command", "command":"other pre"}] for w in hooks["PreToolUse"])
assert any(w.get("matcher") == "Read" and w["hooks"] == [] for w in hooks["PreToolUse"])
assert {"type":"command", "command":"echo cctrl hooks run pre-tool-use"} in leaves("PreToolUse")
assert any(w.get("async") is True and w["hooks"] == [{"type":"command", "command":"other stop"}] for w in hooks["Stop"])
assert {"type":"command", "command":"/old/cctrl/hooks/notify.sh stop"} in leaves("Stop")
assert hooks["OtherEvent"] == [{"hooks": [{"type":"command", "command":"cctrl hooks run stop"}]}]
assert any(w.get("custom") == "keep" and w["hooks"] == [] for w in hooks["SessionStart"])
PY
    python3 - "$claude_root/settings.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))["hooks"]
assert any(h.get("command") == "other claude pre" for w in d["PreToolUse"] for h in w["hooks"])
assert any(w.get("_gstack_source") for w in d["Stop"])
PY
    [[ "$(stat -f '%Lp' "$config")" == "600" ]] || fail "Codex hooks config mode is not 0600"
    local backup
    backup="$(find "$codex_root" -maxdepth 1 -type f -name 'hooks.json.cctrl-backup-*' -print -quit)"
    [[ -n "$backup" ]] || fail "Codex hook backup was not created"
    cmp -s "$backup" "$original" || fail "Codex hook backup did not preserve exact source bytes"
    [[ "$(stat -f '%Lp' "$backup")" == "600" ]] || fail "Codex hook backup mode is not 0600"

    digest_once="$(file_digest "$config")"
    CODEX_HOME="$codex_root" CLAUDE_CONFIG_DIR="$claude_root" "$ROOT/cctrl" hooks install >/dev/null
    digest_twice="$(file_digest "$config")"
    [[ "$digest_once" == "$digest_twice" ]] || fail "Codex hook installation is not idempotent"
    [[ "$(find "$codex_root" -maxdepth 1 -type f -name 'hooks.json.cctrl-backup-*' | wc -l | tr -d ' ')" == "1" ]] \
        || fail "idempotent installation created another backup"

    printf '{invalid' > "$config"
    digest_once="$(file_digest "$config")"
    rc=0
    out="$(CODEX_HOME="$codex_root" CLAUDE_CONFIG_DIR="$claude_root" "$ROOT/cctrl" hooks install 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "invalid Codex JSON did not fail closed"
    assert_contains "$out" "left it untouched"
    [[ "$digest_once" == "$(file_digest "$config")" ]] || fail "invalid Codex JSON was modified"

    local symlink_root="$TMPDIR/hooks-061-symlink" symlink_target="$TMPDIR/hooks-061-symlink-target.json"
    mkdir -p "$symlink_root"
    printf '{"target":true}\n' > "$symlink_target"
    ln -s "$symlink_target" "$symlink_root/hooks.json"
    digest_once="$(file_digest "$symlink_target")"
    rc=0
    out="$(CODEX_HOME="$symlink_root" CLAUDE_CONFIG_DIR="$TMPDIR/no-claude-hooks" "$ROOT/cctrl" hooks install 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "symlinked Codex destination was accepted"
    assert_contains "$out" "refusing to read"
    [[ "$digest_once" == "$(file_digest "$symlink_target")" ]] || fail "symlink target was modified"

    python3 - "$ROOT/hooks/codex-hook-config.py" "$TMPDIR/hooks-061-races" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import sys

module_path, root = sys.argv[1:]
spec = importlib.util.spec_from_file_location("codex_hook_config", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = Path(root)
root.mkdir()

changed_path = root / "changed.json"
changed_path.write_bytes(b'{"before":1}\n')
external_bytes = b'{"external":{"preserved":true}}\n'
def change_once(attempt, path):
    if attempt == 1:
        path.write_bytes(external_bytes)
changed, backup = module.install(changed_path, before_compare=change_once)
assert changed and backup is not None and backup.read_bytes() == external_bytes
assert json.loads(changed_path.read_text())["external"] == {"preserved": True}

absent_path = root / "absent.json"
def create_once(attempt, path):
    if attempt == 1:
        path.write_text('{"arrived":"during-install"}\n')
changed, backup = module.install(absent_path, before_compare=create_once)
assert changed and backup is not None
assert json.loads(absent_path.read_text())["arrived"] == "during-install"
assert not list(root.glob(".*.tmp"))
PY

    # Cooperative lock: two installers converge without duplicate leaves.
    local concurrent_root="$TMPDIR/hooks-061-concurrent" p1 p2
    mkdir -p "$concurrent_root"
    CODEX_HOME="$concurrent_root" CLAUDE_CONFIG_DIR="$TMPDIR/no-claude-hooks" "$ROOT/cctrl" hooks install >"$TMPDIR/hooks-061-p1.log" 2>&1 & p1=$!
    CODEX_HOME="$concurrent_root" CLAUDE_CONFIG_DIR="$TMPDIR/no-claude-hooks" "$ROOT/cctrl" hooks install >"$TMPDIR/hooks-061-p2.log" 2>&1 & p2=$!
    wait "$p1" || fail "first concurrent Codex hook install failed"
    wait "$p2" || fail "second concurrent Codex hook install failed"
    python3 - "$concurrent_root/hooks.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))["hooks"]
owned=[("PreToolUse","cctrl hooks run pre-tool-use"),("Stop","cctrl hooks run stop"),("PermissionRequest","cctrl hooks run notify")]
owned += [(e,"cctrl hooks run codex-observe") for e in ("SessionStart","SessionEnd","PreCompact","PostCompact")]
for event, command in owned:
    assert sum(h == {"type":"command","command":command} for w in d[event] for h in w["hooks"]) == 1
PY
    [[ -z "$(find "$concurrent_root" -maxdepth 1 -type f -name '.*.tmp' -print -quit)" ]] \
        || fail "Codex hook installer left temporary files behind"

    # Restore a valid isolated config for doctor checks.
    rm -f "$config"
    CODEX_HOME="$codex_root" CLAUDE_CONFIG_DIR="$claude_root" "$ROOT/cctrl" hooks install >/dev/null
    local doctor_bin="$TMPDIR/hooks-061-bin" trust_fixture="$TMPDIR/hooks-061-trust.json"
    mkdir -p "$doctor_bin"
    ln -s "$ROOT/cctrl" "$doctor_bin/cctrl"
    python3 - "$config" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p))
d["hooks"]["OtherEvent"]=[{"hooks":[{"type":"command","command":"/third-party/cctrl/hooks/custom.sh"}]}]
json.dump(d,open(p,"w"),indent=2); open(p,"a").write("\n")
PY
    python3 - "$config" "$trust_fixture" <<'PY'
import json, sys
path, out = sys.argv[1:]
cfg=json.load(open(path))
hooks=[]
for event, wrappers in cfg["hooks"].items():
    for wrapper in wrappers:
        for leaf in wrapper.get("hooks", []):
            command=leaf.get("command") if isinstance(leaf,dict) else None
            if command and command.startswith("cctrl hooks run "):
                hooks.append({"command":command,"sourcePath":path,"trustStatus":"trusted"})
json.dump({"data":[{"cwd":"/tmp","errors":[],"warnings":[],"hooks":hooks}]},open(out,"w"))
PY
    out="$(CODEX_HOME="$codex_root" CLAUDE_CONFIG_DIR="$claude_root" \
        CCTRL_HOOK_GUI_PATH="$doctor_bin:/usr/bin:/bin" CCTRL_CODEX_HOOKS_LIST_JSON="$trust_fixture" \
        "$ROOT/cctrl" hooks doctor)"
    assert_contains "$out" "cctrl resolves under minimal GUI PATH"
    assert_contains "$out" "trust/hash: trusted"
    assert_contains "$out" "unrelated hook leaf/leaves preserved"
    assert_contains "$out" "unrelated stale absolute path preserved"

    python3 - "$trust_fixture" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p));
d["data"][0]["hooks"][0]["trustStatus"]="modified"
d["data"][0]["hooks"]=[h for h in d["data"][0]["hooks"] if h["command"] != "cctrl hooks run notify"]
json.dump(d,open(p,"w"))
PY
    rc=0
    out="$(CODEX_HOME="$codex_root" CLAUDE_CONFIG_DIR="$claude_root" \
        CCTRL_HOOK_GUI_PATH="$doctor_bin:/usr/bin:/bin" CCTRL_CODEX_HOOKS_LIST_JSON="$trust_fixture" \
        "$ROOT/cctrl" hooks doctor 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "doctor did not fail an untrusted Codex hook"
    assert_contains "$out" "trust/hash: untrusted"
    assert_contains "$out" "trust/hash: unknown — cctrl hooks run notify"

    live_before="$(live_data_manifest)"
    local observer="$ROOT/hooks/codex-session-observer.py" payload="$TMPDIR/hooks-061-oversized"
    for body in '' 'null' '[]' '{bad' '{"hook_event_name":"Unknown","session_id":"id"}' \
        '{"hook_event_name":"SessionStart"}' '{"hook_event_name":"SessionStart","session_id":"fixture-id"}'; do
        printf '%s' "$body" | python3 "$observer" || fail "observer rejected fail-open payload: $body"
    done
    python3 - "$payload" <<'PY'
import sys
open(sys.argv[1],"wb").write(b"x" * 1_048_577)
PY
    python3 "$observer" < "$payload" || fail "observer rejected oversized payload"
    python3 - "$observer" <<'PY'
import subprocess,sys,time
p=subprocess.Popen([sys.executable,sys.argv[1]],stdin=subprocess.PIPE)
started=time.monotonic()
rc=p.wait(timeout=4)
assert rc == 0
assert time.monotonic()-started < 3.5
PY
    live_after="$(live_data_manifest)"
    assert_live_store_unchanged "$live_before" "$live_after" "isolated observer test changed the real cctrl live store" fixture-id

    real_hooks_after="$(file_digest "$HOME/.codex/hooks.json")"
    real_trust_after="$(file_digest "$HOME/.codex/config.toml")"
    [[ "$real_hooks_before" == "$real_hooks_after" ]] || fail "tests changed real Codex hooks.json"
    [[ "$real_trust_before" == "$real_trust_after" ]] || fail "tests changed real Codex trust configuration"
    echo "ok: Codex hooks install additively and observer remains bounded and fail-open"
}

test_app_owned_launch() {
    local -x CCTRL_CODEX_APP_SERVER_TRANSPORT=jsonl
    local root="$TMPDIR/app-owned-launch" bin="$TMPDIR/app-owned-launch/bin" fake="$TMPDIR/app-owned-launch/bin/codex"
    local trace="$root/trace.jsonl" counter="$root/counter" tmux_log="$root/tmux.log" data="$root/data" meta="$root/meta"
    mkdir -p "$bin" "$data" "$meta"
    cat > "$fake" <<'PY'
#!/usr/bin/python3
import datetime,hashlib,json,os,sys,time
from pathlib import Path
args=sys.argv[1:]; mode=os.environ.get("FAKE_APP_MODE","success")
trace=Path(os.environ["FAKE_APP_TRACE"]); counter=Path(os.environ["FAKE_APP_COUNTER"])
tasks=counter.with_name("tasks.json")
if args == ["--version"]: print("codex-cli 1.2.3"); raise SystemExit
if args[:3] == ["app-server","daemon","version"]: print('{"cliVersion":"1.2.3","appServerVersion":"1.2.3"}'); raise SystemExit
if args[:2] == ["app-server","generate-json-schema"]:
    time.sleep(float(os.environ.get("FAKE_APP_SCHEMA_DELAY","0")))
    out=Path(args[args.index("--out")+1]); out.mkdir(parents=True,exist_ok=True)
    methods=["thread/start","thread/read","thread/list","turn/start"]
    (out/"ClientRequest.json").write_text(json.dumps({"title":"ClientRequest","oneOf":[{"properties":{"method":{"enum":[m]}}} for m in methods]}))
    raise SystemExit
if args[:2] != ["app-server","proxy"]: raise SystemExit(2)
def send(v): print(json.dumps(v,separators=(",",":")),flush=True)
for line in sys.stdin:
    m=json.loads(line); method=m.get("method")
    if method: trace.open("a").write(json.dumps({"method":method,"params":m.get("params")})+"\n")
    if method == "initialize":
        send({"id":m["id"],"result":{"userAgent":"codex-cli/1.2.3","codexHome":"/tmp/fake","platformFamily":"unix","platformOs":"macos"}})
    elif method == "initialized": pass
    elif method == "thread/start":
        n=int(counter.read_text())+1 if counter.exists() else 1; counter.write_text(str(n))
        if mode == "thread-timeout": time.sleep(2); continue
        task_id=f"thread-{n}"; known=json.loads(tasks.read_text()) if tasks.exists() else {}
        known[task_id]=m.get("params",{}).get("cwd"); tasks.write_text(json.dumps(known))
        send({"id":m["id"],"result":{"thread":{"id":task_id,"cwd":known[task_id]}}})
    elif method == "turn/start":
        if mode == "hook-before-register":
            task_id=m["params"]["threadId"]; host=Path(os.environ["CCTRL_HOST_ID_FILE"]).read_text().strip()
            key=hashlib.sha256(("codex\0"+host+"\0"+task_id).encode()).hexdigest()
            now=datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z")
            record={"schema_version":2,"provider":"codex","provider_task_id":task_id,"origin":"codex-app","host_id":host,
              "registered_by_cctrl":False,"launched_by_cctrl":False,"execution_runtime":"unknown","control_owner":"unknown",
              "lifecycle_state":"active","restore_strategy":None,"last_observed_at":now,"tmux_session":None,
              "lineage":{"forked_from_id":None,"parent_thread_id":None,"derived_root_id":None,"derived_root_basis":None},
              "ownership_evidence":[],"lifecycle_observations":[],"registry_event_ids":[],"registry_source_high_water":{},
              "ownership_observations":[],"cwd":json.loads(tasks.read_text())[task_id],"agent":"codex","conversation_id":task_id}
            Path(os.environ["CCTRL_SESSION_METADATA_DIR"],f"task-{key}.json").write_text(json.dumps(record))
        if mode == "turn-timeout": time.sleep(2); continue
        send({"id":m["id"],"result":{"turn":{"id":"turn-1"}}})
    elif method == "thread/read":
        task_id=m["params"]["threadId"]; known=json.loads(tasks.read_text()) if tasks.exists() else {}
        send({"id":m["id"],"result":{"thread":{"id":task_id,"cwd":known.get(task_id,os.getcwd())}}})
PY
    chmod +x "$fake"
    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_TMUX_LOG:?}"
exit 91
SH
    chmod +x "$bin/tmux"
    : > "$trace"; : > "$tmux_log"
    local before after out rc=0 record
    before="$(live_data_manifest)"
    out="$(PATH="$(_test_path "$bin")" CCTRL_CODEX_BIN="$fake" FAKE_APP_TRACE="$trace" FAKE_APP_COUNTER="$counter" FAKE_TMUX_LOG="$tmux_log" \
        CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" \
        "$ROOT/cctrl" start --agent codex --app-owned "$root" --model gpt-6-astra --reasoning-effort high \
        --sandbox workspace-write --ask-for-approval on-request -m "do it" --json)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "app-owned success failed: $out"
    jq -e '.task_creation_outcome=="created" and .provider_task_id=="thread-1" and .turn_outcome=="started" and
      .owner=="app" and .runtime=="app-server" and .registry_persisted==true and .partial==false' <<< "$out" >/dev/null \
      || fail "app-owned result contract is wrong: $out"
    [[ "$(jq -s '[.[]|select(.method=="thread/start")]|length' "$trace")" == 1 ]] || fail "thread/start was not emitted exactly once"
    [[ "$(jq -s '[.[]|select(.method=="turn/start")]|length' "$trace")" == 1 ]] || fail "turn/start was not emitted exactly once"
    local canonical_root
    canonical_root="$(cd "$root" && pwd -P)"
    jq -s -e '[.[]|select(.method=="thread/start")][0].params |
      .cwd==$cwd and .model=="gpt-6-astra" and .sandbox=="workspace-write" and .approvalPolicy=="on-request" and
      .config.model_reasoning_effort=="high"' --arg cwd "$canonical_root" "$trace" >/dev/null || fail "normalized settings were not mapped: $(cat "$trace")"
    jq -s -e '[.[]|select(.method=="turn/start")][0].params.effort=="high"' "$trace" >/dev/null || fail "turn effort was not mapped"
    [[ ! -s "$tmux_log" ]] || fail "app-owned launch invoked tmux"
    record="$(find "$meta" -name 'task-*.json' -print -quit)"
    jq -e '.provider_task_id=="thread-1" and .origin=="cctrl" and .registered_by_cctrl==true and
      .launched_by_cctrl==true and .execution_runtime=="app-server" and .control_owner=="app" and
      .restore_strategy=="provider-managed" and .tmux_session==null' "$record" >/dev/null || fail "app-owned record is wrong"
    out="$(PATH="$(_test_path "$bin")" CCTRL_CODEX_BIN="$fake" FAKE_APP_TRACE="$trace" FAKE_APP_COUNTER="$counter" FAKE_TMUX_LOG="$tmux_log" \
        CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" \
        "$ROOT/cctrl" start --agent codex --app-owned "$root" --json)" || fail "second same-cwd app launch failed"
    [[ "$(jq -r '.provider_task_id' <<< "$out")" == thread-2 ]] || fail "same-cwd launch was deduplicated by cwd"
    [[ "$(find "$meta" -name 'task-*.json' | wc -l | tr -d ' ')" == 2 ]] || fail "same-cwd provider identities did not remain distinct"

    : > "$trace"; rm -f "$counter"; rm -rf "$meta"; mkdir -p "$meta"; rc=0
    out="$(PATH="$(_test_path "$bin")" CCTRL_CODEX_BIN="$fake" FAKE_APP_MODE=hook-before-register \
        FAKE_APP_TRACE="$trace" FAKE_APP_COUNTER="$counter" FAKE_TMUX_LOG="$tmux_log" CCTRL_DATA_DIR="$data" \
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" "$ROOT/cctrl" start --agent codex --app-owned "$root" -m hi --json)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "hook-race launch failed: $out"
    record="$(find "$meta" -name 'task-*.json' -print -quit)"
    jq -e '.origin=="cctrl" and .registered_by_cctrl==true and .launched_by_cctrl==true and
      .control_owner=="app" and .execution_runtime=="app-server"' "$record" >/dev/null \
      || fail "hook-before-register race lost cctrl provenance"
    local profiles="$root/profiles"
    mkdir -p "$profiles"
    printf '%s\n' '{"agents":{"codex":{"model":"profile-model","reasoningEffort":"low","args":["--sandbox","workspace-write","--ask-for-approval","untrusted"]}}}' > "$profiles/app.json"
    # shellcheck disable=SC2016
    out="$(PATH="$(_test_path "$bin")" CCTRL_CODEX_BIN="$fake" FAKE_APP_TRACE="$trace" FAKE_APP_COUNTER="$counter" FAKE_TMUX_LOG="$tmux_log" \
        CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" cctrl_source_eval \
        'CCTRL_PROFILES_DIR="$1"; shift; _launch_app_owned_codex "$@"' "$profiles" --app-owned "$root" --profile app \
        --model cli-model --reasoning-effort high --sandbox read-only --json)" || fail "profile-normalized app launch failed"
    jq -e '.task_creation_outcome=="created" and .registry_persisted==true' <<< "$out" >/dev/null || fail "profile launch result is wrong"
    jq -s -e '[.[]|select(.method=="thread/start")][-1].params |
      .model=="cli-model" and .config.model_reasoning_effort=="high" and .sandbox=="read-only" and .approvalPolicy=="untrusted"' "$trace" >/dev/null \
      || fail "CLI-over-profile precedence was not preserved"

    : > "$trace"; rm -f "$counter"; rm -rf "$meta"; mkdir -p "$meta"; rc=0
    out="$(PATH="$(_test_path "$bin")" CCTRL_CODEX_BIN="$fake" FAKE_APP_MODE=thread-timeout CCTRL_CODEX_REQUEST_TIMEOUT=.5 \
        FAKE_APP_TRACE="$trace" FAKE_APP_COUNTER="$counter" FAKE_TMUX_LOG="$tmux_log" CCTRL_DATA_DIR="$data" \
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" "$ROOT/cctrl" start --agent codex --app-owned "$root" --json)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "ambiguous thread/start unexpectedly succeeded"
    jq -e '.task_creation_outcome=="unknown" and .provider_task_id==null and .registry_persisted=="unknown" and
      (.recovery_command|contains("do not rerun creation automatically"))' <<< "$out" >/dev/null || fail "ambiguous creation result is wrong: $out"
    [[ "$(jq -s '[.[]|select(.method=="thread/start")]|length' "$trace")" == 1 ]] || fail "ambiguous thread/start was retried"
    jq -s -e '[.[]|select(.method=="thread/start")][0].params | keys == ["cwd","ephemeral"]' "$trace" >/dev/null \
      || fail "omitted app-owned settings did not retain provider defaults"

    : > "$trace"; rm -f "$counter"; rm -rf "$meta"; mkdir -p "$meta"; rc=0
    out="$(PATH="$(_test_path "$bin")" CCTRL_CODEX_BIN="$fake" FAKE_APP_MODE=turn-timeout CCTRL_CODEX_REQUEST_TIMEOUT=.5 \
        FAKE_APP_TRACE="$trace" FAKE_APP_COUNTER="$counter" FAKE_TMUX_LOG="$tmux_log" CCTRL_DATA_DIR="$data" \
        CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" "$ROOT/cctrl" start --agent codex --app-owned "$root" -m hi --json)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "ambiguous turn unexpectedly succeeded"
    jq -e '.task_creation_outcome=="created" and .provider_task_id=="thread-1" and .turn_outcome=="unknown" and .registry_persisted==true and .partial==true' <<< "$out" >/dev/null \
      || fail "ambiguous turn result is wrong: $out"
    [[ "$(jq -s '[.[]|select(.method=="turn/start")]|length' "$trace")" == 1 ]] || fail "ambiguous turn was retried"

    : > "$trace"; rm -f "$counter"; rm -rf "$meta"; mkdir -p "$meta"; rc=0
    out="$(PATH="$(_test_path "$bin")" CCTRL_CODEX_BIN="$fake" FAKE_APP_TRACE="$trace" FAKE_APP_COUNTER="$counter" FAKE_TMUX_LOG="$tmux_log" \
        CCTRL_TASK_REGISTRY_FAIL_BEFORE_RENAME=1 CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" \
        "$ROOT/cctrl" start --agent codex --app-owned "$root" --json 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "registry persistence failure unexpectedly succeeded"
    jq -e '.provider_task_id=="thread-1" and .registry_persisted==false and .recovery_command=="cctrl session recover-app-owned thread-1"' <<< "$out" >/dev/null \
      || fail "partial recovery result is wrong: $out"
    local recovery_cwd="$root/recovery-cwd"
    mkdir -p "$recovery_cwd"
    out="$(cd "$recovery_cwd" && PATH="$(_test_path "$bin")" CCTRL_CODEX_BIN="$fake" FAKE_APP_TRACE="$trace" FAKE_APP_COUNTER="$counter" \
        CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" \
        "$ROOT/cctrl" session recover-app-owned thread-1 --json)" || fail "known-id recovery failed"
    jq -e '.verified==true and .registry_persisted==true' <<< "$out" >/dev/null || fail "recovery output is wrong"
    record="$(find "$meta" -name 'task-*.json' -print -quit)"
    [[ "$(jq -r '.cwd' "$record")" == "$canonical_root" ]] || fail "recovery substituted its shell cwd"
    rc=0
    out="$(PATH="$(_test_path "$bin")" CCTRL_CODEX_BIN="$fake" FAKE_APP_TRACE="$trace" FAKE_APP_COUNTER="$counter" \
        CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" \
        "$ROOT/cctrl" session recover-app-owned native-task --json)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "unrelated native task was relabeled as cctrl-launched"
    jq -e '.verified==false and (.error|contains("no cctrl app-owned launch receipt"))' <<< "$out" >/dev/null \
      || fail "unrelated native recovery failure was not explicit: $out"

    for bad in detach foreground resume remote peer purpose name permission raw-config; do
        local -a bad_args=()
        case "$bad" in
            detach) bad_args=(--detach) ;;
            foreground) bad_args=(--foreground) ;;
            resume) bad_args=(--resume) ;;
            remote) bad_args=(--remote unix://) ;;
            peer) bad_args=(--peer peer1) ;;
            purpose) bad_args=(--purpose nope) ;;
            name) bad_args=(--name nope) ;;
            permission) bad_args=(--permission-mode bypassPermissions) ;;
            raw-config) bad_args=(-c raw=true) ;;
        esac
        if PATH="$(_test_path "$bin")" CCTRL_CODEX_BIN="$fake" FAKE_APP_TRACE="$trace" FAKE_APP_COUNTER="$counter" \
            CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" \
            "$ROOT/cctrl" start --agent codex --app-owned "$root" "${bad_args[@]}" >/dev/null 2>&1; then
            fail "incompatible app-owned args were accepted: $bad"
        fi
    done
    if CCTRL_AGENT=claude PATH="$(_test_path "$bin")" CCTRL_CODEX_BIN="$fake" FAKE_APP_TRACE="$trace" FAKE_APP_COUNTER="$counter" \
        CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" \
        "$ROOT/cctrl" start --app-owned "$root" >/dev/null 2>&1; then
        fail "CCTRL_AGENT=claude was ignored by app-owned launch"
    fi
    if PATH="$(_test_path "$bin")" CCTRL_CODEX_BIN="$fake" FAKE_APP_TRACE="$trace" FAKE_APP_COUNTER="$counter" \
        CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" \
        "$ROOT/cctrl" --agent claude start --app-owned "$root" >/dev/null 2>&1; then
        fail "global --agent claude was ignored by app-owned launch"
    fi
    if CCTRL_TEST_ONLY=app-owned-launch cctrl_source_eval '_start_requests_app_owned --message --app-owned'; then
        fail "--app-owned option value selected app-owned mode locally"
    fi
    local hosts="$root/hosts.json" ssh_log="$root/ssh.log"
    printf '{"remote":{"hostname":"example.invalid","user":"tester"}}\n' > "$hosts"
    cat > "$bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${FAKE_SSH_LOG:?}"
SH
    chmod +x "$bin/ssh"
    # Positional parameters expand inside cctrl_source_eval's child shell.
    # shellcheck disable=SC2016
    PATH="$(_test_path "$bin")" FAKE_SSH_LOG="$ssh_log" cctrl_source_eval \
      'HOSTS_FILE="$1"; _remote_exec remote start --agent codex --app-owned "$2" --json' "$hosts" "$root" >/dev/null
    assert_not_contains "$(cat "$ssh_log")" " -t "
    assert_not_contains "$(cat "$ssh_log")" "--purpose"
    assert_contains "$(cat "$ssh_log")" "CCTRL_HOST_PREFIX=remote"
    assert_contains "$(cat "$ssh_log")" "--app-owned"
    # shellcheck disable=SC2016 # positional parameter belongs to the sourced shell
    PATH="$(_test_path "$bin")" FAKE_SSH_LOG="$ssh_log" cctrl_source_eval \
      'HOSTS_FILE="$1"; _remote_exec remote start --message --app-owned --purpose fixed' "$hosts" >/dev/null
    assert_contains "$(cat "$ssh_log")" "-t tester@example.invalid"
    after="$(live_data_manifest)"
    assert_live_store_unchanged "$before" "$after" "app-owned tests changed the real cctrl live store"
    echo "ok: app-owned launch is at-most-once, writer-free, recoverable, and settings-safe"
}

test_codex_handoff_state_machine() {
    local root="$TMPDIR/codex-handoff" bin="$TMPDIR/codex-handoff/bin" data="$TMPDIR/codex-handoff/data"
    local meta="$TMPDIR/codex-handoff/meta" codex_home="$TMPDIR/codex-handoff/codex" backup="$TMPDIR/codex-handoff/backup"
    local app="$TMPDIR/codex-handoff/app.json" app_missing="$TMPDIR/codex-handoff/app-missing.json"
    local app_archived="$TMPDIR/codex-handoff/app-archived.json" app_unavailable="$TMPDIR/codex-handoff/app-unavailable.json"
    local app_conflict="$TMPDIR/codex-handoff/app-conflict.json" tmux_snapshot="$TMPDIR/codex-handoff/tmux.json"
    local proc_snapshot="$TMPDIR/codex-handoff/process.json" tmux_absent="$TMPDIR/codex-handoff/tmux-absent.json"
    local proc_absent="$TMPDIR/codex-handoff/process-absent.json" state="$TMPDIR/codex-handoff/tmux-live" proc="$TMPDIR/codex-handoff/process-live"
    local host="77777777777777777777777777777777" started="Wed Sep 17 10:00:00 2026" out rc=0 record before after
    rm -rf "$root"; mkdir -p "$bin" "$data" "$meta" "$codex_home/thread-writer-locks" "$backup"
    printf '%s\n' "$host" > "$data/host-id"
    cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
state="${FAKE_HANDOFF_TMUX_STATE:?}"; proc="${FAKE_HANDOFF_PROCESS_STATE:?}"
if [[ "${1:-}" == "-u" ]]; then shift; fi
case "${1:-}" in
  has-session) [[ -e "$state" ]] ;;
  display-message) [[ -e "$state" ]] && cat "$state" ;;
  list-panes) printf '%s:%s\n' "${FAKE_HANDOFF_PANE_ID:-%1}" "${FAKE_HANDOFF_PANE_PID:-4100}" ;;
  list-sessions) [[ -e "$state" ]] && printf 'TMUX--handoff\n' ;;
  run-shell)
    command="$2"; output="${command#*> }"; output="${output% 2>/dev/null}"
    if [[ "$command" == *'ps -ax -o pid='* ]]; then
      printf '4100 1 session-wrapper.sh\n4200 4100 codex\n' > "$output"
    elif [[ -e "$proc" ]]; then
      printf 'Wed Sep 17 10:00:00 2026\n' > "$output"
    else
      : > "$output"
    fi
    ;;
  send-keys)
    if [[ "${FAKE_HANDOFF_BLOCK_EXIT:-0}" != 1 ]]; then
      rm -f "$proc"
      if [[ "${FAKE_HANDOFF_REUSE_AFTER_SEND:-0}" == 1 ]]; then printf '\$99\n' > "$state"; else rm -f "$state"; fi
      if [[ -n "${FAKE_HANDOFF_MUTATE_RECORD:-}" ]]; then
        /usr/bin/python3 -c 'import json,sys; p=sys.argv[1]; v=json.load(open(p)); v["lifecycle_state"]=sys.argv[2]; open(p,"w").write(json.dumps(v)+"\n")' "$FAKE_HANDOFF_MUTATE_RECORD" "$FAKE_HANDOFF_MUTATE_STATE"
      fi
    fi
    ;;
  *) exit 0 ;;
esac
SH
    cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *'lstart='* && -e "${FAKE_HANDOFF_PROCESS_STATE:?}" ]]; then
  printf 'Wed Sep 17 10:00:00 2026\n'
fi
exit 0
SH
    chmod +x "$bin/tmux" "$bin/ps"
    cat > "$app" <<'JSON'
{"schema_version":1,"status":"available","complete":true,"observed_at":"2026-09-17T10:00:00Z","source_cursor":"app-handoff-1","threads":[{"id":"handoff-task","archived":false,"cwd":"/tmp/handoff"}],"errors":[]}
JSON
    cat > "$app_missing" <<'JSON'
{"schema_version":1,"status":"available","complete":true,"observed_at":"2026-09-17T10:00:00Z","source_cursor":"app-missing","threads":[],"errors":[]}
JSON
    cat > "$app_archived" <<'JSON'
{"schema_version":1,"status":"available","complete":true,"observed_at":"2026-09-17T10:00:00Z","source_cursor":"app-archived","threads":[{"id":"handoff-task","archived":true}],"errors":[]}
JSON
    cat > "$app_unavailable" <<'JSON'
{"schema_version":1,"status":"unavailable","complete":false,"observed_at":"2026-09-17T10:00:00Z","source_cursor":null,"threads":[],"errors":[{"reason":"fixture unavailable"}]}
JSON
    cat > "$app_conflict" <<'JSON'
{"schema_version":1,"status":"available","complete":true,"observed_at":"2026-09-17T10:00:00Z","source_cursor":"app-conflict","threads":[{"id":"handoff-task","archived":false,"control_owner":"app"}],"errors":[]}
JSON
    cat > "$tmux_snapshot" <<'JSON'
{"schema_version":1,"status":"available","observed_at":"2026-09-17T10:00:00Z","source_cursor":"tmux-handoff-1","panes":[{"session":"TMUX--handoff","pane_id":"%1","pane_pid":"4100","start_command":"session-wrapper.sh","current_command":"codex"}],"error":null}
JSON
    cat > "$proc_snapshot" <<'JSON'
{"schema_version":1,"status":"available","observed_at":"2026-09-17T10:00:00Z","source_cursor":"proc-handoff-1","processes":[{"pid":4100,"ppid":1,"started":"Wed Sep 17 10:00:00 2026","command":"session-wrapper.sh"},{"pid":4200,"ppid":4100,"started":"Wed Sep 17 10:00:01 2026","command":"codex"}],"error":null}
JSON
    cat > "$tmux_absent" <<'JSON'
{"schema_version":1,"status":"available","observed_at":"2026-09-17T10:00:01Z","source_cursor":"tmux-handoff-2","panes":[],"error":null}
JSON
    cat > "$proc_absent" <<'JSON'
{"schema_version":1,"status":"available","observed_at":"2026-09-17T10:00:01Z","source_cursor":"proc-handoff-2","processes":[],"error":null}
JSON
    make_record() {
        local origin="${1:-cctrl}" owner="${2:-cctrl}" runtime="${3:-tmux}"
        rm -rf "$meta"; mkdir -p "$meta"
        python3 - "$meta" "$host" "$origin" "$owner" "$runtime" "$started" <<'PY'
import hashlib,json,sys
from pathlib import Path
root,host,origin,owner,runtime,started=Path(sys.argv[1]),*sys.argv[2:]
task="handoff-task"; now="2026-09-17T10:00:00Z"
record={"schema_version":2,"provider":"codex","provider_task_id":task,"origin":origin,"host_id":host,
 "registered_by_cctrl":origin=="cctrl","launched_by_cctrl":origin=="cctrl","execution_runtime":runtime,"control_owner":owner,
 "lifecycle_state":"active","restore_strategy":"tmux" if runtime=="tmux" else "provider-managed","last_observed_at":now,
 "tmux_session":"TMUX--handoff","pane_id":"%1","pane_pid":"4100","pane_started":started,"wrapper_pid":"4100",
 "lineage":{"forked_from_id":None,"parent_thread_id":None,"derived_root_id":None,"derived_root_basis":None},
 "ownership_evidence":[{"source":"cctrl-launch","source_instance":"TMUX--handoff","source_cursor":"launch-1","authority_class":"authoritative",
 "observed_owner":owner,"observed_runtime":runtime,"observed_state":"active","observed_at":now,"reason":"fixture launch receipt"}],
 "lifecycle_observations":[],"registry_event_ids":[],"registry_source_high_water":{},"ownership_observations":[],
 "name":"TMUX--handoff","agent":"codex","conversation_id":task,"cwd":"/tmp/handoff","control_surface":"tmux","cctrl_managed":True}
key="task-"+hashlib.sha256(("codex\0"+host+"\0"+task).encode()).hexdigest()
(root/(key+".json")).write_text(json.dumps(record,sort_keys=True,indent=2)+"\n")
PY
        record="$(find "$meta" -name 'task-*.json' -print -quit)"
    }
    run_release() {
        local -a release_cmd=("$ROOT/cctrl" session release-to-app TMUX--handoff)
        [[ "${HANDOFF_NO_YES:-0}" == 1 ]] || release_cmd+=(--yes)
        release_cmd+=(--wait 0 --json)
        PATH="$(_test_path "$bin")" FAKE_HANDOFF_TMUX_STATE="$state" FAKE_HANDOFF_PROCESS_STATE="$proc" \
          CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" CODEX_HOME="$codex_home" \
          CCTRL_CODEX_LOCK_BACKUP_DIR="$backup" CCTRL_CODEX_RECONCILE_APP_SERVER_FILE="${HANDOFF_APP_FILE:-$app}" \
          CCTRL_CODEX_RECONCILE_TMUX_FILE="${HANDOFF_RECONCILE_TMUX_FILE:-$tmux_snapshot}" CCTRL_CODEX_RECONCILE_PROCESS_FILE="${HANDOFF_RECONCILE_PROCESS_FILE:-$proc_snapshot}" \
          CCTRL_CODEX_HANDOFF_POST_RECONCILE_TMUX_FILE="${HANDOFF_POST_TMUX_FILE:-$tmux_absent}" \
          CCTRL_CODEX_HANDOFF_POST_RECONCILE_PROCESS_FILE="${HANDOFF_POST_PROCESS_FILE:-$proc_absent}" \
          CCTRL_CODEX_HANDOFF_PREFLIGHT_FILE="${HANDOFF_APP_FILE:-$app}" CCTRL_CODEX_HANDOFF_POSTFLIGHT_FILE="${HANDOFF_APP_FILE:-$app}" \
          CCTRL_CODEX_HANDOFF_CONFIRM_RESPONSE="${CCTRL_CODEX_HANDOFF_CONFIRM_RESPONSE:-}" \
          CCTRL_CODEX_HANDOFF_ATTEMPT_ID="handoff-attempt-0001" "${release_cmd[@]}"
    }

    before="$(live_data_manifest)"
    make_record cctrl cctrl tmux; printf '$%s\n' 42 > "$state"; : > "$proc"; : > "$codex_home/thread-writer-locks/handoff-task.lock"
    out="$(run_release)" || fail "verified handoff failed: $out"
    jq -e 'length==1 and .[0].kind=="codex_handoff_result_v1" and .[0].status=="handed-off" and
      .[0].provider_task_id=="handoff-task" and .[0].owner_exit==true and .[0].provider_postcondition.verified==true and
      .[0].previous_state.control_owner=="cctrl" and .[0].resulting_state.control_owner=="app" and
      .[0].resulting_state.execution_runtime=="app-server"' <<< "$out" >/dev/null || fail "handoff result contract is wrong: $out"
    jq -e '.origin=="cctrl" and .provider_task_id=="handoff-task" and .control_owner=="app" and
      .execution_runtime=="app-server" and .restore_strategy=="provider-managed"' "$record" >/dev/null || fail "handoff registry transition is wrong"
    [[ "$(find "$meta" -name 'task-*.json' | wc -l | tr -d ' ')" == 1 ]] || fail "handoff created a duplicate canonical task record"
    [[ -e "$codex_home/thread-writer-locks/handoff-task.lock" && ! -e "$backup/handoff-task.lock" ]] || fail "handoff must preserve provider-owned writer lock"
    jq -e '.[0].lock_action=="none" and .[0].quarantine_path==null' <<< "$out" >/dev/null || fail "handoff must not claim provider lock cleanup"
    out="$(run_release)" || fail "app-owned retry was not idempotent"
    jq -e '.[0].status=="already-app-owned" and .[0].ok==true' <<< "$out" >/dev/null || fail "app-owned retry result is wrong: $out"

    rc=0
    out="$(PATH="$(_test_path "$bin")" FAKE_HANDOFF_TMUX_STATE="$state" FAKE_HANDOFF_PROCESS_STATE="$proc" \
      CCTRL_DATA_DIR="$data" CCTRL_SESSION_METADATA_DIR="$meta" CCTRL_HOST_ID_FILE="$data/host-id" CODEX_HOME="$codex_home" \
      "$ROOT/cctrl" session attach TMUX--handoff 2>&1)" || rc=$?
    [[ "$rc" -eq 2 && "$out" == *"app-owned"* && "$out" == *"no longer owns"* ]] || fail "attach did not guard released app-owned task: $out"

    make_record codex-app app app-server; rc=0
    out="$(run_release 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "native observed app task was transferable"
    jq -e '.[0].error=="non-transferable-origin"' <<< "$out" >/dev/null || fail "wrong-origin failure is not actionable: $out"

    make_record cctrl cctrl tmux; printf '$%s\n' 42 > "$state"; : > "$proc"; rc=0
    out="$(FAKE_HANDOFF_BLOCK_EXIT=1 run_release 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "blocked owner exit unexpectedly committed"
    jq -e '.[0].error=="owner-exit-timeout" and .[0].owner_exit==false' <<< "$out" >/dev/null || fail "timeout result is wrong: $out"
    jq -e '.control_owner=="cctrl" and .execution_runtime=="tmux"' "$record" >/dev/null || fail "timeout falsely committed app ownership"

    # Confirmation is after exact identity/provider preflight and before EOF.
    make_record cctrl cctrl tmux; printf '$%s\n' 42 > "$state"; : > "$proc"; rc=0
    out="$(HANDOFF_NO_YES=1 CCTRL_CODEX_HANDOFF_CONFIRM_RESPONSE=n run_release 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 && -e "$state" && -e "$proc" ]] || fail "confirmation decline sent EOF or unexpectedly succeeded"
    jq -e '.[0].status=="declined" and .[0].error=="confirmation-declined" and .[0].provider_task_id=="handoff-task"' <<< "$out" >/dev/null \
      || fail "confirmation decline result is wrong: $out"

    # Provider preflight fails closed for missing, archived, and unavailable.
    local provider_fixture expected_error
    for provider_fixture in "$app_missing" "$app_archived" "$app_unavailable"; do
        make_record cctrl cctrl tmux; printf '$%s\n' 42 > "$state"; : > "$proc"; rc=0
        out="$(HANDOFF_APP_FILE="$provider_fixture" run_release 2>/dev/null)" || rc=$?
        [[ "$rc" -ne 0 && -e "$state" ]] || fail "provider failure sent EOF or unexpectedly succeeded: $provider_fixture"
        case "$provider_fixture" in
          *missing*) expected_error="provider-task-missing" ;;
          *archived*) expected_error="provider-task-archived" ;;
          *) expected_error="provider-unavailable" ;;
        esac
        jq -e --arg error "$expected_error" '.[0].error==$error and .[0].owner_exit==false' <<< "$out" >/dev/null \
          || fail "provider failure result is wrong ($expected_error): $out"
    done

    # Simultaneous authoritative app and tmux claims are a conflict, not a handoff.
    make_record cctrl cctrl tmux; printf '$%s\n' 42 > "$state"; : > "$proc"; rc=0
    out="$(HANDOFF_APP_FILE="$app_conflict" run_release 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 && -e "$state" ]] || fail "ownership conflict sent EOF or unexpectedly succeeded"
    jq -e '.[0].error=="ownership-conflict"' <<< "$out" >/dev/null || fail "ownership conflict result is wrong: $out"

    # Reusing the tmux name/session identity after EOF must not authorize commit.
    make_record cctrl cctrl tmux; printf '$%s\n' 42 > "$state"; : > "$proc"; rc=0
    out="$(FAKE_HANDOFF_REUSE_AFTER_SEND=1 run_release 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "reused tmux identity unexpectedly committed"
    jq -e '.[0].error=="owner-process-mismatch" and .[0].owner_exit==false' <<< "$out" >/dev/null || fail "tmux reuse result is wrong: $out"
    jq -e '.control_owner=="cctrl"' "$record" >/dev/null || fail "tmux reuse falsely committed app ownership"

    # plan 085: a malformed pane_id must fail closed instead of falling
    # through to tmux's "current pane" default for the exit send-keys.
    # Attest only checks the record's pane_id against tmux's live pane_id by
    # plain string equality, not by format, so a fake (or corrupted) tmux
    # that happens to echo the same malformed value back would otherwise
    # sail through attestation; make that happen here (FAKE_HANDOFF_PANE_ID
    # matching the record) to prove the dedicated format check is what
    # actually stops it, not attest.
    make_record cctrl cctrl tmux
    jq '.pane_id="%abc"' "$record" > "$record.tmp" && mv "$record.tmp" "$record"
    local tmux_snapshot_bad_pane="$root/tmux-bad-pane.json"
    jq '.panes[0].pane_id="%abc"' "$tmux_snapshot" > "$tmux_snapshot_bad_pane"
    printf '$%s\n' 42 > "$state"; : > "$proc"; rc=0
    out="$(FAKE_HANDOFF_PANE_ID='%abc' HANDOFF_RECONCILE_TMUX_FILE="$tmux_snapshot_bad_pane" run_release 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "malformed pane_id unexpectedly committed"
    jq -e '.[0].error=="pane-id-invalid" and .[0].owner_exit==false' <<< "$out" >/dev/null || fail "malformed pane_id result is wrong: $out"
    [[ -e "$state" && -e "$proc" ]] || fail "malformed pane_id must not send exit input to any pane"
    jq -e '.control_owner=="cctrl"' "$record" >/dev/null || fail "malformed pane_id falsely committed app ownership"

    # A fresh postflight writer snapshot vetoes the handoff after old-owner exit.
    make_record cctrl cctrl tmux; printf '$%s\n' 42 > "$state"; : > "$proc"; rc=0
    out="$(HANDOFF_POST_TMUX_FILE="$tmux_snapshot" HANDOFF_POST_PROCESS_FILE="$proc_snapshot" run_release 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "postflight competing writer unexpectedly committed"
    jq -e '.[0].error=="postflight-competing-writer" and .[0].owner_exit==true' <<< "$out" >/dev/null || fail "postflight competing-writer result is wrong: $out"

    # Only a same-task lifecycle-hook SessionEnd delta is admissible. An
    # unrelated concurrent archive-style mutation is reported as conflict.
    make_record cctrl cctrl tmux; printf '$%s\n' 42 > "$state"; : > "$proc"; rc=0
    out="$(FAKE_HANDOFF_MUTATE_RECORD="$record" FAKE_HANDOFF_MUTATE_STATE=archived run_release 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "concurrent non-SessionEnd mutation unexpectedly committed"
    jq -e '.[0].error=="record-changed-during-shutdown" and .[0].owner_exit==true' <<< "$out" >/dev/null || fail "concurrent mutation result is wrong: $out"

    # Reducer failure occurs after verified exit but preserves the original
    # owner record for deterministic reconciliation/retry.
    make_record cctrl cctrl tmux; printf '$%s\n' 42 > "$state"; : > "$proc"; rc=0
    out="$(CCTRL_TASK_REGISTRY_FAIL_BEFORE_RENAME=1 run_release 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "injected reducer failure unexpectedly succeeded"
    jq -e '.[0].error=="registry-handoff-rejected" and .[0].owner_exit==true' <<< "$out" >/dev/null || fail "reducer failure result is wrong: $out"
    jq -e '.control_owner=="cctrl" and .origin=="cctrl"' "$record" >/dev/null || fail "reducer failure corrupted ownership/provenance"

    # Retry after interruption between owner exit and registry commit: exact
    # provider id remains, no new task is created, and the missing old process
    # is treated as a recoverable checkpoint.
    make_record cctrl cctrl tmux; rm -f "$state" "$proc"; rc=0
    out="$(HANDOFF_RECONCILE_TMUX_FILE="$tmux_absent" HANDOFF_RECONCILE_PROCESS_FILE="$proc_absent" run_release 2>/dev/null)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "interrupted handoff recovery failed: $out"
    jq -e '.[0].status=="handed-off" and .[0].owner_exit==true and .[0].provider_task_id=="handoff-task"' <<< "$out" >/dev/null \
      || fail "interrupted recovery result is wrong: $out"
    [[ "$(find "$meta" -name 'task-*.json' | wc -l | tr -d ' ')" == 1 ]] || fail "interrupted recovery duplicated provider task"

    # Cached app-owned state is not enough for an idempotent success claim.
    make_record cctrl app app-server; rc=0
    out="$(HANDOFF_APP_FILE="$app_missing" run_release 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "app-owned no-op ignored missing provider task"
    jq -e '.[0].error=="app-owned-provider-unverified"' <<< "$out" >/dev/null || fail "app-owned provider verification failure is wrong: $out"

    after="$(live_data_manifest)"
    assert_live_store_unchanged "$before" "$after" "handoff tests changed the real cctrl live store" TMUX--handoff handoff-task
    echo "ok: Codex handoff is exact-task, two-checkpoint, owner-exit-gated, idempotent, and attach-safe"
}

test_codex_ownership_matrix_contract() {
    local fixture="$ROOT/tests/fixtures/codex-ownership-matrix.json" help

    jq -e '
      .schema_version == 1 and .kind == "codex_three_path_matrix" and
      .compatibility_boundary == "codex-lifecycle-v1" and
      .fixture_versions == {"cli_version":"0.153.4","app_version":"26.908.40834 (build 8881)"} and
      (.paths | length) == 3 and
      ([.paths[].path] | sort) == ["cctrl-app-owned","cctrl-terminal-worker","native-app"] and
      (all(.paths[]; has("command") and has("origin") and has("runtime") and
        has("owner") and has("control_surface") and has("disconnect") and
        has("reboot") and has("transition") and has("unsupported") and
        (.evidence_functions | type == "array" and length > 0))) and
      ([.paths[] | select(.path=="cctrl-terminal-worker")][0] |
        .origin=="cctrl" and .owner=="cctrl" and .runtime=="tmux" and
        .transition=="release-to-app" and
        .evidence_functions==["test_detached_arg_parsing","test_start_defaults_to_tmux","test_codex_handoff_state_machine"] and
        (.unsupported | index("simultaneous-app-writer") != null)) and
      ([.paths[] | select(.path=="cctrl-app-owned")][0] |
        .origin=="cctrl" and .owner=="app" and .runtime=="app-server" and
        .evidence_functions==["test_app_owned_launch"] and
        (.unsupported | index("tmux-restore") != null)) and
      ([.paths[] | select(.path=="native-app")][0] |
        .origin=="codex-app" and .owner=="unknown-until-authoritative-app-snapshot" and
        .runtime=="unknown-until-authoritative-app-snapshot" and
        .transition=="reconcile-authoritative-app-evidence-then-observe" and
        .evidence_functions==["test_codex_lifecycle_ingestion","test_codex_reconcile_ownership_evidence","test_task_inventory_provider_neutral_readonly"] and
        (.unsupported | index("override-app-settings") != null))
    ' "$fixture" >/dev/null || fail "three-path ownership fixture contract is invalid"

    python3 "$ROOT/tests/fixtures/codex-lifecycle/validate.py" >/dev/null \
        || fail "declared codex-lifecycle-v1 compatibility boundary is invalid"
    jq -e --slurpfile matrix "$fixture" '
      ($matrix[0].fixture_versions) as $versions |
      (.fixtures | length > 0) and
      all(.fixtures[]; .cli_version==$versions.cli_version and .app_version==$versions.app_version)
    ' "$ROOT/tests/fixtures/codex-lifecycle/manifest.json" >/dev/null \
        || fail "codex-lifecycle-v1 is not bound to the declared CLI/app versions"
    rg -q "three ownership paths" "$ROOT/README.md" \
        || fail "README is not the canonical three-path decision table"
    rg -q -- "--app-owned" "$ROOT/README.md" "$ROOT/skills/cctrl-spawn/SKILL.md" "$ROOT/completions/_cctrl" \
        || fail "app-owned path is missing from an operator surface"
    rg -q "release-to-app" "$ROOT/skills/cctrl-session-end/SKILL.md" \
        || fail "session-end skill omits verified app handoff"
    rg -q "provider-neutral.*cctrl task ls|cctrl task ls.*provider-neutral" "$ROOT/skills/cctrl-fleet-manager/SKILL.md" \
        || fail "fleet-manager skill does not begin from provider-neutral task inventory"
    if ! rg -q "Peer messaging for app tasks remains deferred" "$ROOT/skills/cctrl-fleet-manager/SKILL.md" \
        || ! rg -q "plans 028/029" "$ROOT/skills/cctrl-fleet-manager/SKILL.md"; then
        fail "app-task peer identity deferral is undocumented"
    fi
    rg -q "transport.*not ownership|transport option.*not a" "$ROOT/README.md" \
        || fail "README still implies --remote is simultaneous app access"
    if rg -q "Codex app bridge|Codex app-server endpoint|Codex: launch through local app-server" \
        "$ROOT/README.md" "$ROOT/cctrl" "$ROOT/completions/_cctrl"; then
        fail "a stale --remote app-control description remains"
    fi
    help="$(CCTRL_DATA_DIR="$TMPDIR/ownership-help-data" "$ROOT/cctrl" help)"
    [[ "$help" == *"Codex ownership paths"* && "$help" == *"zero tmux writers"* && "$help" == *"release-to-app"* ]] \
        || fail "CLI help does not mirror the three-path ownership contract"

    echo "ok: canonical three-path ownership contract is aligned across operator surfaces"
}

test_codex_launch_to_app_workflow() {
    local root="$TMPDIR/launch-to-app" out rc=0 release_log recovery_log env_log
    rm -rf "$root"; mkdir -p "$root"
    release_log="$root/release.log"; recovery_log="$root/recovery.log"; env_log="$root/env.log"

    # Exercise the real detached-launch seam with only fake tmux/agent/process
    # tools. The compound workflow receives the exact launch ID from an atomic
    # private receipt, without parsing human output or searching by cwd/title.
    local seam_bin="$root/seam-bin" seam_meta="$root/seam-meta" seam_data="$root/seam-data"
    local seam_project="$root/seam-project" seam_receipt="$root/seam-receipt.json"
    mkdir -p "$seam_bin" "$seam_meta" "$seam_data" "$seam_project"
    make_fake_tmux "$seam_bin/tmux"
    make_fake_agent "$seam_bin/codex" codex
    make_fake_ps "$seam_bin/ps"
    : > "$root/seam-tmux.log"
    PATH="$seam_bin:$PATH" TMUX_LOG="$root/seam-tmux.log" CCTRL_DATA_DIR="$seam_data" CCTRL_HOST_ID_FILE="$seam_data/host-id" \
      CCTRL_SESSION_METADATA_DIR="$seam_meta" CCTRL_LAUNCH_RECEIPT_FILE="$seam_receipt" \
      CCTRL_ATTACH_PROMPT=never CCTRL_PURPOSE_PROMPT=never CCTRL_NO_HEALTH_CHECK=1 \
      CCTRL_RESUME_POLL_TIMEOUT=0 CCTRL_CODEX_TITLE_POLL_TIMEOUT=0 \
      "$ROOT/cctrl" start -d --agent codex "$seam_project" >/dev/null
    jq -e '.schema_version==1 and (.session|test("^TMUX--.*seam-project$")) and
      (.launch_id|test("^[0-9a-f-]{16,64}$")) and (.record|endswith(".json"))' "$seam_receipt" >/dev/null \
      || fail "detached launch did not emit its exact private receipt: $(cat "$seam_receipt" 2>/dev/null)"
    [[ -f "$(jq -r '.record' "$seam_receipt")" ]] || fail "launch receipt points at a missing provisional record"

    run_workflow_fixture() (
        local mode="$1"; shift
        export CCTRL_SESSION_METADATA_DIR="$root/meta-$mode"
        mkdir -p "$CCTRL_SESSION_METADATA_DIR"
        source "$ROOT/lib/codex-launch-to-app.sh"
        local fixture_launch_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" fixture_session="TMUX--fixture" fixture_task="exact-task-082"
        local provisional="$CCTRL_SESSION_METADATA_DIR/launch-$fixture_launch_id.json"
        local canonical="$CCTRL_SESSION_METADATA_DIR/task-fixture.json"

        _write_canonical() {
            cat > "$canonical" <<JSON
{"schema_version":2,"provider":"codex","provider_task_id":"$fixture_task","origin":"cctrl","host_id":"11111111111111111111111111111111","registered_by_cctrl":true,"launched_by_cctrl":true,"execution_runtime":"tmux","control_owner":"cctrl","lifecycle_state":"active","restore_strategy":"tmux","last_observed_at":"2026-09-28T20:15:00Z","lineage":{"forked_from_id":null,"parent_thread_id":null,"derived_root_id":null,"derived_root_basis":null},"ownership_evidence":[],"lifecycle_observations":[],"terminal_identity_proof":{"verified":true,"provider_task_id":"$fixture_task","evidence_kind":"live-native-codex-writable-root-rollout","receipt":{"control_surface":"tmux","tmux_session":"$fixture_session","pane_id":"%82","pane_pid":"8200","wrapper_pid":"8200","pane_started":"Sun Sep 28 20:15:00 2026"}},"provisional_launch_id":"$fixture_launch_id","name":"$fixture_session","tmux_session":"$fixture_session","agent":"codex","control_surface":"tmux","pane_id":"%82","pane_pid":"8200","wrapper_pid":"8200","pane_started":"Sun Sep 28 20:15:00 2026","health_status":"ready","cctrl_managed":true}
JSON
            if [[ "$mode" == already-promoted ]]; then
                jq '.terminal_identity_proof.evidence_kind="codex-lifecycle-hook-launch-binding" |
                    .terminal_identity_proof.lifecycle_event_id="event-082" |
                    .terminal_identity_proof.provisional_launch_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" |
                    .terminal_identity_proof.tmux_session="TMUX--fixture" |
                    .terminal_identity_proof.expected_source_digest="digest-082" |
                    .lifecycle_observations=[{"source":"lifecycle-hook","event_id":"event-082"}]' "$canonical" > "$canonical.tmp"
                mv "$canonical.tmp" "$canonical"
            elif [[ "$mode" == heuristic-promoted ]]; then
                jq 'del(.terminal_identity_proof) |
                    .lifecycle_observations=[{"source":"lifecycle-hook","event_id":"unbound-event"}]' "$canonical" > "$canonical.tmp"
                mv "$canonical.tmp" "$canonical"
            fi
        }
        _launch_detached() {
            printf '%s|%s|%s\n' "${CCTRL_ATTACH_PROMPT:-}" "${CCTRL_RESUME_POLL_TIMEOUT:-}" "${CCTRL_CODEX_TITLE_POLL_TIMEOUT:-}" >> "$env_log"
            [[ "$mode" != launch-fail ]] || return 1
            CCTRL_LAST_LAUNCH_ID="$fixture_launch_id"
            CCTRL_LAST_LAUNCH_RECORD="$provisional"
            if [[ "$mode" == boot-timeout ]]; then
                printf '{"provisional_launch_id":"%s","name":"%s","health_status":"timeout"}\n' "$fixture_launch_id" "$fixture_session" > "$provisional"
            else
                printf '{"provisional_launch_id":"%s","name":"%s","health_status":"ready"}\n' "$fixture_launch_id" "$fixture_session" > "$provisional"
            fi
            jq -n --arg session "$fixture_session" --arg launch_id "$fixture_launch_id" --arg record "$provisional" \
              '{schema_version:1,session:$session,launch_id:$launch_id,record:$record}' > "$CCTRL_LAUNCH_RECEIPT_FILE"
            [[ "$mode" != startup-exit ]] || return 1
            if [[ "$mode" == already-promoted || "$mode" == heuristic-promoted ]]; then
                _write_canonical
                rm -f "$provisional"
            fi
        }
        _session_metadata_file() {
            [[ -f "$canonical" ]] && printf '%s' "$canonical" || printf '%s' "$provisional"
        }
        _session_recover_terminal_identity() {
            printf '%s\n' "$*" >> "$recovery_log"
            if [[ "$mode" == heuristic-promoted ]]; then
                printf '{"verified":false,"applied":false}\n'
                return 65
            fi
            if [[ "$*" == *--apply* ]]; then
                [[ "$mode" != recovery-fail ]] || { printf '{"verified":true,"applied":false,"provider_task_id":"%s"}\n' "$fixture_task"; return 75; }
                _write_canonical; rm -f "$provisional"
                printf '{"verified":true,"applied":true,"provider_task_id":"%s"}\n' "$fixture_task"
            else
                printf '{"verified":true,"applied":false,"provider_task_id":"%s"}\n' "$fixture_task"
            fi
        }
        _session_attest() {
            if [[ "$mode" == attest-mismatch ]]; then
                printf '{"verified":true,"thread_id":"other-task"}\n'
            else
                printf '{"verified":true,"thread_id":"%s","pane_id":"%%82","pane_pid":8200}\n' "$fixture_task"
            fi
        }
        _session_release_to_app_one() {
            printf '%s\n' "$*" >> "$release_log"
            [[ "$5" == *'"provider_task_id":"exact-task-082"'* && "$5" == *'"provisional_launch_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'* ]] \
              || { printf '{"ok":false,"error":"missing-expected-guard"}\n'; return 75; }
            if [[ "$mode" == release-fail ]]; then
                printf '{"ok":false,"status":"incomplete","provider_task_id":"%s","owner_exit":false,"resulting_state":{"control_owner":"cctrl","execution_runtime":"tmux"},"error":"owner-exit-timeout","required_action":"Attach and resolve blocking input."}\n' "$fixture_task"
                return 75
            fi
            if [[ "$mode" == release-race ]]; then
                printf '{"ok":true,"status":"handed-off","provider_task_id":"replacement-task","owner_exit":true,"resulting_state":{"control_owner":"app","execution_runtime":"app-server"}}\n'
                return 0
            fi
            printf '{"ok":true,"status":"handed-off","provider_task_id":"%s","owner_exit":true,"provider_postcondition":{"verified":true},"resulting_state":{"control_owner":"app","execution_runtime":"app-server"}}\n' "$fixture_task"
        }
        _codex_launch_to_app --identity-timeout 0 --release-wait 0 --json /tmp/fixture "$@"
    )

    : > "$release_log"; : > "$recovery_log"; : > "$env_log"
    out="$(run_workflow_fixture success)" || fail "launch-to-app success failed: $out"
    jq -e '.ok and .status=="released-to-app" and .provider_task_id=="exact-task-082" and
      .identity.verified and .identity.recovery_applied and
      .resulting_state=={"control_owner":"app","execution_runtime":"app-server"} and
      .release.status=="handed-off"' <<< "$out" >/dev/null || fail "launch-to-app success contract is wrong: $out"
    [[ "$(wc -l < "$release_log" | tr -d ' ')" == 1 ]] || fail "compound workflow did not release exactly once"
    [[ "$(wc -l < "$recovery_log" | tr -d ' ')" == 2 ]] || fail "compound workflow did not dry-run then apply exact recovery"
    grep -qx 'never|0|0' "$env_log" || fail "compound launch did not suppress attach and heuristic identity pollers"

    : > "$release_log"; : > "$recovery_log"
    out="$(run_workflow_fixture success --keep-terminal-owned)" || fail "terminal-owned opt-out failed: $out"
    jq -e '.ok and .status=="terminal-owned" and .requested_finalization=="keep-terminal-owned" and
      .resulting_state=={"control_owner":"cctrl","execution_runtime":"tmux"}' <<< "$out" >/dev/null \
      || fail "terminal-owned opt-out contract is wrong: $out"
    [[ ! -s "$release_log" ]] || fail "--keep-terminal-owned invoked release-to-app"

    : > "$release_log"; : > "$recovery_log"; rc=0
    out="$(run_workflow_fixture attest-mismatch 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "mismatched attested provider identity unexpectedly succeeded"
    jq -e '.status=="attestation-failed" and .error=="owner-attestation-failed"' <<< "$out" >/dev/null \
      || fail "attestation mismatch result is wrong: $out"
    [[ ! -s "$release_log" ]] || fail "identity mismatch invoked release-to-app"

    : > "$release_log"; : > "$recovery_log"; rc=0
    out="$(run_workflow_fixture boot-timeout 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "non-ready boot unexpectedly proceeded"
    jq -e '.status=="boot-not-ready" and .error=="boot-not-ready" and .provider_task_id==null' <<< "$out" >/dev/null \
      || fail "boot readiness failure result is wrong: $out"
    [[ ! -s "$recovery_log" && ! -s "$release_log" ]] || fail "non-ready boot attempted identity recovery or release"

    : > "$release_log"; : > "$recovery_log"; rc=0
    out="$(run_workflow_fixture release-fail 2>/dev/null)" || rc=$?
    [[ "$rc" -eq 75 ]] || fail "release failure returned $rc instead of 75"
    jq -e '.status=="release-failed" and .error=="owner-exit-timeout" and
      .resulting_state=={"control_owner":"cctrl","execution_runtime":"tmux"} and .release.owner_exit==false' <<< "$out" >/dev/null \
      || fail "release failure did not preserve fail-closed result: $out"

    : > "$release_log"; : > "$recovery_log"; rc=0
    out="$(run_workflow_fixture release-race 2>/dev/null)" || rc=$?
    [[ "$rc" -eq 75 ]] || fail "release identity race returned $rc instead of 75"
    jq -e '.status=="identity-conflict" and .error=="release-identity-mismatch" and
      .provider_task_id=="exact-task-082" and .release.provider_task_id=="replacement-task"' <<< "$out" >/dev/null \
      || fail "release identity race was not rejected: $out"

    : > "$release_log"; : > "$recovery_log"
    out="$(run_workflow_fixture already-promoted)" || fail "authoritative pre-promotion path failed: $out"
    jq -e '.ok and .identity.verified and (.identity.recovery_applied|not)' <<< "$out" >/dev/null \
      || fail "already-promoted identity result is wrong: $out"
    [[ ! -s "$recovery_log" ]] || fail "already-promoted exact launch record was unnecessarily recovered"

    : > "$release_log"; : > "$recovery_log"; rc=0
    out="$(run_workflow_fixture heuristic-promoted 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "heuristically promoted identity unexpectedly succeeded"
    jq -e '.status=="identity-unverified" and .error=="exact-provider-identity-unavailable"' <<< "$out" >/dev/null \
      || fail "heuristic promotion was not rejected: $out"
    [[ ! -s "$release_log" ]] || fail "heuristic promotion invoked release-to-app"

    rc=0
    out="$(run_workflow_fixture launch-fail 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "failed launch unexpectedly succeeded"
    jq -e '.status=="launch-failed" and .session==null and .release==null' <<< "$out" >/dev/null \
      || fail "launch failure result is wrong: $out"

    rc=0
    out="$(CCTRL_HOST_PREFIX=studio run_workflow_fixture startup-exit 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "post-create startup failure unexpectedly succeeded"
    jq -e '.status=="launch-failed" and .session=="TMUX--fixture" and
      .launch_id=="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .resulting_state=={"control_owner":"cctrl","execution_runtime":"tmux"} and
      (.required_action|contains("cctrl --host studio session attach TMUX--fixture"))' <<< "$out" >/dev/null \
      || fail "post-create startup failure lost its exact receipt or remote hint: $out"

    echo "ok: launch-to-app composes exact recovery, attestation, opt-out, and safe handoff"
}

run_codex_ownership_matrix_paths() {
    local fixture="$ROOT/tests/fixtures/codex-ownership-matrix.json" path
    while IFS= read -r path; do
        case "$path" in
            cctrl-terminal-worker)
                _run_test test_detached_arg_parsing
                _run_test test_start_defaults_to_tmux
                _run_test test_codex_handoff_state_machine
                ;;
            cctrl-app-owned)
                _run_test test_app_owned_launch
                ;;
            native-app)
                _run_test test_codex_lifecycle_ingestion
                _run_test test_codex_reconcile_ownership_evidence
                _run_test test_task_inventory_provider_neutral_readonly
                ;;
            *) fail "unknown ownership-matrix path: $path" ;;
        esac
    done < <(jq -r '.paths[].path' "$fixture")
}

# Groups as data (plan 105 P4): `_group_tests <group>` prints the tests a
# CCTRL_TEST_ONLY group runs, in order. codex-ownership-matrix has its own
# block below (live-store manifest around the run); provider-neutral and
# codex-adapter add a python unittest step next to their tests.
_group_tests() {
    case "$1" in
        role-skills) printf '%s\n' test_role_skills_ask_rule ;;
        bash-leg) printf '%s\n' test_bash_leg_is_honest test_no_shimless_test_path test_profile_settings_gc_portable_membership ;;
        session-prune) printf '%s\n' test_session_prune_never_prompted_claude test_session_prune_fresh_active_not_candidate test_session_prune_codex_no_claude_transcript_bug_guard test_session_prune_codex_never_prompted test_session_prune_dry_run_closes_nothing test_session_prune_claude_long_transcript_user_turn_not_flagged test_session_prune_yes_caps_large_batch ;;
        codex-adapter) printf '%s\n' test_codex_app_server_adapter ;;
        provider-neutral) printf '%s\n' test_session_list_codex_default_model test_session_list_agent_not_mislabelled_by_prompt test_session_list_agent_prefers_recorded_metadata test_session_list_malformed_metadata_uses_unknown_defaults ;;
        task-inventory) printf '%s\n' test_task_inventory_provider_neutral_readonly ;;
        codex-reconcile) printf '%s\n' test_codex_reconcile_ownership_evidence ;;
        codex-lifecycle) printf '%s\n' test_codex_lifecycle_fixture_contract test_codex_lifecycle_ingestion ;;
        app-owned-launch) printf '%s\n' test_app_owned_launch ;;
        codex-handoff) printf '%s\n' test_codex_handoff_state_machine ;;
        codex-launch-to-app) printf '%s\n' test_codex_launch_to_app_workflow ;;
        codex-ownership-matrix) ;;
        session-attest) printf '%s\n' test_session_attest_live_tmux_process_matches test_session_attest_direct_metadata test_session_attest_stale_tmux_session_missing test_session_attest_malformed_metadata_fails_human_mode test_session_runtime_mcp_attests_fixed_session ;;
        session-stop-exact) printf '%s\n' test_session_stop_exact_identity test_session_terminate_records_closed test_session_close_reaps_pane_processes test_tmux_sockets_left_behind test_session_mark_closed_provisional_launch_record test_session_task_records_for_name_launch_liveness_gate test_task_record_close_provisional_honors_digest_guard test_session_record_terminated_closes_fresh_anchored_provisional ;;
        task-records) printf '%s\n' test_task_record_host_id_is_stable_exclusive_and_private test_task_record_schema_v2_and_provisional_promotion test_task_record_legacy_validation_and_lazy_promotion test_task_record_merge_conflict_preserves_evidence test_task_record_relaunch_moves_terminal_anchors test_task_record_relaunch_reclaims_and_reopens test_task_resolve_conflicts_digest_guarded test_task_record_identity_independent_close_continues test_task_registry_atomic_concurrent_updates test_task_registry_replay_order_and_guards test_task_registry_lock_stale_timeout_and_release_token test_task_registry_structural_boundary ;;
        task-record-compat) printf '%s\n' test_codex_rename_updates_app_title test_codex_rename_prefers_prompt_match_over_stale_id test_session_app_ls_codex_records test_codex_close_archives_and_resolves_rollout_identity test_session_release_to_app_quarantines_stale_codex_lock test_update_metadata_field_preserves_keys test_backfill_ids_fills_resume_flag test_backfill_ids_idempotent test_session_list_refresh_writes_on_change test_session_list_refresh_skips_when_unchanged ;;
        task-record-launch) printf '%s\n' test_detached_arg_parsing test_start_peer_env_and_metadata test_live_aware_index_picker test_launch_resume_captures_conversation_id test_resume_no_uuid_no_conversation_id test_session_write_metadata_includes_new_fields ;;
        task-record-launch-basic) printf '%s\n' test_detached_arg_parsing ;;
        task-record-launch-peer) printf '%s\n' test_start_peer_env_and_metadata test_live_aware_index_picker ;;
        task-record-launch-peer-only) printf '%s\n' test_start_peer_env_and_metadata ;;
        task-record-launch-index) printf '%s\n' test_live_aware_index_picker ;;
        task-record-launch-resume) printf '%s\n' test_launch_resume_captures_conversation_id test_resume_no_uuid_no_conversation_id test_session_write_metadata_includes_new_fields ;;
        task-record-list) printf '%s\n' test_session_list_codex_default_model test_session_list_agent_not_mislabelled_by_prompt test_session_list_agent_prefers_recorded_metadata test_session_list_malformed_metadata_uses_unknown_defaults test_session_list_refresh_writes_on_change test_session_list_refresh_skips_when_unchanged ;;
        fleet-v2) printf '%s\n' test_fleet_merges_multiple_hosts test_fleet_sorts_by_recency_across_hosts test_fleet_offline_host_non_fatal test_fleet_version_skew_missing_fields test_fleet_v2_provider_neutral_federation ;;
        health-check) printf '%s\n' test_health_check_patterns_syntax test_health_check_pattern_matching test_health_check_transition_guard test_health_check_needs_human_path test_health_check_timeout_path test_health_check_ready_requires_visible_prompt test_health_check_startup_selectors_need_human test_health_check_detects_startup_exit test_session_pane_has_dialog_refactored ;;
        pane-draft) printf '%s\n' test_session_pane_has_draft_glyph_fixtures test_session_rich_state_detects_glyph_draft test_session_autoheal_skips_glyph_draft test_pane_draft_plan086_followups test_pane_draft_plan086_hotfix_titled_divider test_strip_sgr_shared_regex ;;
        snapshot-restore-legacy) printf '%s\n' test_snapshot_header_and_session_shape test_snapshot_initial_prompt_absent test_snapshot_empty_fleet_guard_preserves test_snapshot_allow_empty_overrides test_snapshot_history_and_latest_agree test_snapshot_retention_pruning test_snapshot_no_tmux_mutation test_snapshot_tmux_absent_preserves test_snapshot_first_run_empty_writes test_snapshot_managed_matches_session_ls test_snapshot_launch_flags_round_trip test_snapshot_conversation_id_from_session_id test_restore_only_filter test_restore_cap_on_total test_restore_null_conversation_id_skipped test_restore_dry_run_spawns_nothing test_restore_gate_stops_below_threshold test_restore_limit_caps_spawns test_restore_no_tty_no_yes_refused test_restore_unknown_schema_refused test_restore_stale_snapshot_refused test_restore_host_mismatch_refused test_restore_cap_fails_closed test_restore_wave_pacing test_restore_already_live_skipped test_restore_launch_config_replay test_restore_already_live_record_join test_restore_exit_codes ;;
        role-phase1) printf '%s\n' test_role_flags_before_dir_target_with_detach test_role_flags_before_at_target_without_detach test_role_flags_never_reach_child_command test_role_flags_with_foreground_exit_64 test_role_flags_with_app_owned_and_launch_to_app_exit_64 test_remote_role_value_not_taken_as_purpose test_role_flag_recorded_in_metadata_and_tmux_option test_role_and_orch_kind_invalid_values_exit_64 test_orch_kind_flag_implies_orchestrator_role test_role_worker_with_orch_kind_exits_64 test_shortcut_role_and_kind_resolve_on_at_launch test_shortcut_orch_kind_without_role_is_orchestrator test_shortcut_invalid_role_exits_64_naming_key test_orch_kind_flag_overrides_shortcut_kind test_dir_launch_never_inherits_shortcut_role test_dir_launch_with_orch_key_and_plain_key_uses_plain_key test_dir_launch_with_only_orch_key_uses_basename test_dir_launch_matches_stored_dir_with_trailing_slash test_dir_launch_skips_role_shortcut_without_legacy_prefix test_legacy_prefixed_key_with_worker_role_is_adopted test_no_env_var_supplies_role_or_kind test_shortcut_add_preserves_role_fields test_shortcut_add_role_flags_set_and_clear test_ask_a1_role_orchestrator_without_kind_exits_78 test_ask_a2_shortcut_role_without_kind_exits_78 test_ask_a3_legacy_fm_and_orch_keys_without_role_exit_78 test_ask_a4_set_role_orchestrator_without_kind_exits_78 test_ask_a5_shortcut_add_orchestrator_without_kind_exits_78 test_non_interactive_never_reads_stdin test_no_input_flag_and_env_force_78_on_pty test_agent_env_markers_force_78_on_pty test_ask_tty_accepts_fleet test_ask_tty_accepts_repo test_ask_tty_prompts_when_stdout_is_captured test_ask_tty_three_invalid_answers_exit_78 test_ask_tty_read_timeout_exits_78 test_ask_tty_abort_exits_78_nothing_launched test_remote_preflight_forwards_resolved_role_and_kind test_remote_ambiguous_prompts_locally_and_forwards_kind test_remote_ambiguous_non_interactive_returns_78_with_message test_remote_sets_no_input_on_remote_side test_remote_old_cctrl_with_role_flags_exits_69 test_remote_dir_launch_without_role_flags_skips_preflight test_remote_preflight_exit_0_without_role_line_launches_unchanged test_remote_preflight_66_falls_through_to_launch test_remote_foreground_skips_preflight_and_role_flags test_remote_preflight_other_exit_code_is_relayed test_set_role_updates_live_session_and_keeps_label test_set_role_on_provisional_record test_set_role_clear_removes_fields test_relaunch_with_new_role_replaces_recorded_role test_roleless_relaunch_keeps_recorded_role_and_kind test_snapshot_launch_flags_carry_role_and_kind test_restore_replays_role_and_kind test_restore_legacy_row_infers_orchestrator_from_tmux_name test_restore_unknown_kind_row_never_asks test_restore_old_snapshot_does_not_erase_recorded_kind test_restore_current_record_beats_snapshot_row_role test_recorded_worker_beats_legacy_name_inference test_ask_rechecks_tty_at_read_site test_restore_prints_reason_for_failed_row test_realign_flags_carry_role_and_kind test_realign_keeps_recorded_tmux_name test_legacy_live_prefixed_session_reads_as_orchestrator_unknown_kind test_recorded_worker_beats_legacy_name_inference_live test_session_ls_json_exposes_role_and_kind ;;
        role-phase3) printf '%s\n' test_reconcile_names_legacy_record_without_known_names_is_not_pulled test_reconcile_names_writes_baseline_once test_reconcile_names_does_not_pull_launch_name_restamp test_reconcile_names_cctrl_label_stays_after_cctrl_rename test_reconcile_names_pulls_in_claude_rename_for_worker_and_orchestrator test_reconcile_names_cctrl_rename_after_pull_stays test_reconcile_names_no_pull_when_baseline_cannot_be_written test_restore_keeps_known_names_and_pulls_nothing test_reconcile_names_full_set_pulls_nothing test_restore_of_record_without_known_names_gets_baseline_not_seed test_reconcile_names_restamp_after_cctrl_rename_on_legacy_record_not_pulled test_reconcile_names_older_restamped_title_is_never_pulled test_reconcile_names_in_claude_rename_then_cctrl_rename_stays test_reconcile_names_new_in_claude_rename_after_cctrl_rename_is_pulled test_reconcile_names_strips_old_tmux_suffix_after_restore test_reconcile_names_normalises_suffix_on_store_and_compare test_reconcile_names_dry_run_writes_nothing test_reconcile_names_dry_run_reports_would_be_corrections test_reconcile_names_help_and_unknown_flag_write_nothing test_rename_self_resolves_current_session test_rename_self_outside_session_exits_64 test_auto_label_for_handoff_prompt_uses_slug ;;
        role-phase2) printf '%s\n' test_fleet_orchestrator_name_and_star_label test_repo_orchestrator_name_and_star_label test_repo_name_uses_dir_worker_alias_then_stripped_key_then_basename test_at_legacy_orch_shortcut_launch_gets_orch_name test_unknown_kind_orchestrator_keeps_worker_name test_orchestrator_ignores_prompt_derived_label test_orchestrator_explicit_label_gets_glyph_once test_rename_adds_glyph_for_known_kind_only test_replay_keeps_label_verbatim test_set_role_relabel_writes_canonical_label test_codex_title_skips_repo_prefix_for_star_label test_remote_orchestrator_launch_injects_no_default_purpose test_second_fleet_manager_same_runtime_refused_65 test_fleet_launch_never_gets_index_suffix test_old_named_fleet_manager_with_role_blocks_new_one test_fleet_manager_other_runtime_allowed test_repo_and_unknown_kind_sessions_never_trip_guard test_guard_runs_only_after_kind_known test_concurrent_fleet_launch_refused_by_lock test_stale_fleet_lock_is_reclaimed test_fleet_lock_older_than_limit_is_reclaimed_even_with_live_pid test_fleet_lock_without_pid_file_is_held_only_briefly test_override_env_is_unset_before_tmux_new_session test_allow_second_fleet_manager_env_override test_succeeds_allows_one_handover_and_relabels_predecessor test_succeeds_wrong_session_or_two_live_refused test_dead_fleet_manager_record_does_not_block test_set_role_fleet_goes_through_guard test_restore_bypasses_guard_and_reports_predecessor test_session_ls_warns_on_two_fleet_managers_and_unknown_kind test_succeeds_refused_64_unless_fleet_kind test_failed_health_check_leaves_predecessor_label test_empty_runtime_fleet_manager_counts_as_claude test_set_role_fleet_takes_launch_lock test_set_role_relabel_repo_falls_back_to_pane_path test_fleet_lock_registry_dir_failure_has_own_message test_refusal_wording_per_caller test_restore_keeps_recorded_name_for_tagged_fleet_row test_restore_keeps_recorded_name_for_tagged_repo_row_with_index test_restore_beside_live_session_of_same_name_gets_next_index test_restore_keeps_phase2_style_names test_realign_of_tagged_orchestrator_keeps_recorded_name test_fresh_orchestrator_launch_still_gets_role_name ;;
        release-prune) printf '%s\n' test_release_prune ;;
        helper-census) printf '%s\n' test_helper_census test_helper_census_never_kills_structural test_task_ls_helper_footer ;;
        snapshot-ownership) printf '%s\n' test_snapshot_ownership_policy test_snapshot_restore_default_honors_data_dir test_snapshot_tmux_row_selection test_snapshot_size_controls test_snapshot_reboot_keeps_live_latest test_restore_no_force_structural test_restore_no_pane_inference_structural test_snapshot_excludes_stale_provisional_restore_candidates ;;
        *) return 1 ;;
    esac
}

# --- Registry and run (plan 105 P4) -------------------------------------
# A test is any `test_*()` definition in this file (awk, source order; not
# `declare -F`, which sorts alphabetically on bash 3.2). Three small explicit
# lists, each entry registered with a reason:
#   RUN_FIRST  runs before everything else, also in a focused group
#   SKIP       defined but never run
#   RUN_LAST   runs after every discovered test
_RT_RUN_FIRST=""
_RT_SKIP=""
_RT_RUN_LAST=""
_rt_register() { # RUN_FIRST|SKIP|RUN_LAST <test_name> '<reason>'  (test_every_defined_test_is_registered checks the reason is there)
    case "$1" in
        RUN_FIRST) _RT_RUN_FIRST="$_RT_RUN_FIRST $2" ;;
        SKIP) _RT_SKIP="$_RT_SKIP $2" ;;
        RUN_LAST) _RT_RUN_LAST="$_RT_RUN_LAST $2" ;;
        *) echo "run-tests.sh: bad registry kind: $1" >&2; exit 64 ;;
    esac
}
_rt_register RUN_FIRST test_tmux_default_server_is_private 'before any test, focused group or not: proves a bare tmux hits the private server (plan 071 p5 incident)'
_rt_register SKIP test_peer_mailbox_concurrency_and_stale_lock 'hangs on macOS bash 3.2 (flock issue), pre-existing, not plan 051/052'
_rt_register SKIP test_task_inventory_provider_neutral_readonly 'fails at HEAD d0f93f0 too (its fake tmux list-sessions output is rejected as invalid-session-identity); it was only ever run through the task-inventory and codex-ownership-matrix groups. Plan 105 P4c: fixing the stale fixture is a follow-up'
_rt_register RUN_LAST test_tmux_sockets_left_behind 'backstop: fails if any earlier test left a socket in the private dir, so it must run after all of them'
_rt_discover() { # discovered test names in source order, minus the three lists
    awk -v special="$_RT_RUN_FIRST $_RT_SKIP $_RT_RUN_LAST" '
        BEGIN { n = split(special, a, " "); for (i = 1; i <= n; i++) sp[a[i]] = 1 }
        /^test_[A-Za-z0-9_]+\(\)/ { name = $0; sub(/\(\).*/, "", name); if (!(name in sp)) print name }
    ' "$_RT_SELF"
}

_rt_n=""
for _rt_n in $_RT_RUN_FIRST; do _run_test --always "$_rt_n"; done

if [[ -n "${CCTRL_TEST_ONLY:-}" ]]; then
    _group_tests "$CCTRL_TEST_ONLY" >/dev/null || fail "unknown focused test group: $CCTRL_TEST_ONLY"
    case "$CCTRL_TEST_ONLY" in
        provider-neutral)
            python3 -m unittest discover -s "$ROOT/tests" -p 'test_*.py'
            ;;
        codex-ownership-matrix)
            ownership_live_before="$(ownership_live_store_manifest)"
            _run_test test_codex_ownership_matrix_contract
            _run_test test_codex_lifecycle_fixture_contract
            run_codex_ownership_matrix_paths
            _run_test test_fleet_v2_provider_neutral_federation
            _run_test test_snapshot_ownership_policy
            ownership_live_after="$(ownership_live_store_manifest)"
            assert_live_store_unchanged "$ownership_live_before" "$ownership_live_after" \
                "three-path ownership matrix changed the real cctrl live store"
            echo "ok: three ownership paths are isolated, single-writer, exact-id, federated, and restore-safe"
            ;;
    esac
    for _rt_n in $(_group_tests "$CCTRL_TEST_ONLY"); do _run_test "$_rt_n"; done
    if [[ "$CCTRL_TEST_ONLY" == "codex-adapter" ]]; then
        python3 -m unittest discover -s "$ROOT/tests" -p "test_codex_websocket*.py"
    else
        echo "ok"
    fi
    _runner_report || exit 1
    exit 0
fi

for _rt_n in $(_rt_discover) $_RT_RUN_LAST; do _run_test "$_rt_n"; done
_runner_finish

echo "ok"

if [[ -z "${CCTRL_TEST_ONLY:-}" ]]; then
    python3 -m unittest discover -s "$ROOT/tests" -p 'test_*.py'
fi

_runner_report || exit 1
