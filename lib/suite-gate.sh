#!/usr/bin/env bash
# Suite gate helpers: a host-wide lock for full test-suite runs, and pass
# stamps that let install/self-install.sh skip re-running a suite that has
# already passed on this exact tree, on this host, with this bash and python.
#
# Sourced by tests/run-tests.sh and install/self-install.sh. Pure functions:
# sourcing it runs nothing. Bash 3.2 compatible (no associative arrays, no
# EPOCHREALTIME, no ${var,,}).
#
# State lives under $CCTRL_SUITE_STATE_DIR, else $XDG_STATE_HOME/cctrl (an
# absolute value only), else $HOME/.local/state/cctrl:
#   suite.lock/            mkdir lock for a FULL run: pid, started, started_at
#   suite-passes/<key>     one small file per recorded green full run
#
# Lock rules
#   - A full run (no test names, no CCTRL_TEST_NAMES, no CCTRL_TEST_ONLY, not
#     --list) takes the lock at start and waits, printing who holds it,
#     instead of running concurrently. The install gate runs a full suite and
#     so goes through the same lock.
#   - Filtered and group runs do NOT take the lock: they are short, and CI
#     smoke and the install smoke subset must never queue behind a 25 minute
#     run. --list never takes it either.
#   - A lock is stale when its holder pid is dead, or alive but not a
#     run-tests.sh process (pid reuse). A live run-tests.sh holder is never
#     broken, however old. A lock with no pid file yet is "starting" and is
#     only treated as stale once the directory is over a minute old.
#
# Pass stamp rules
#   - Written only by a full, green run (no filter, exit 0, python tests
#     included) whose tree is clean. The key is the git tree hash of the
#     tested content + host + bash major.minor + python major.minor.
#   - install/self-install.sh passes CCTRL_SUITE_TREE (the tree of the commit
#     being installed) because its scratch copy has no .git; both paths then
#     compute the same key.
#   - Newest 20 stamps are kept.

_SUITE_LOCK_HELD=0
_SUITE_LOCK_DIR_HELD=""

suite_gate_dir() {
    if [[ -n "${CCTRL_SUITE_STATE_DIR:-}" ]]; then
        printf '%s' "$CCTRL_SUITE_STATE_DIR"
    elif [[ -n "${XDG_STATE_HOME:-}" && "$XDG_STATE_HOME" == /* ]]; then
        printf '%s/cctrl' "$XDG_STATE_HOME"
    else
        printf '%s/.local/state/cctrl' "${HOME:?HOME must be set}"
    fi
}

suite_lock_path() { printf '%s/suite.lock' "$(suite_gate_dir)"; }
suite_pass_dir() { printf '%s/suite-passes' "$(suite_gate_dir)"; }

# 0 when PID is alive and its command line is a run-tests.sh process.
_suite_lock_holder_live() {
    local pid="${1:-}" cmd
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ -n "$cmd" ]] || return 1
    case "$cmd" in
        *run-tests.sh*) return 0 ;;
    esac
    return 1
}

_suite_fmt_epoch() {
    local e="${1:-}"
    if [[ "$e" =~ ^[0-9]+$ ]]; then
        date -r "$e" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$e" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$e"
    else
        printf 'unknown'
    fi
}

# Move a stale lock aside and delete it. Two waiters may both judge the same
# lock stale; only one mv wins. If the lock we moved is not the one we judged
# (the holder changed between the check and the mv), put it back.
_suite_lock_break_stale() { # lock-path judged-pid
    local lock="$1" pid="$2" aside moved
    aside="$lock.stale.$$.$RANDOM"
    mv "$lock" "$aside" 2>/dev/null || return 1
    moved="$(cat "$aside/pid" 2>/dev/null || true)"
    if [[ "$moved" != "$pid" ]]; then
        if ! mv "$aside" "$lock" 2>/dev/null; then
            echo "suite lock: warning: displaced a lock whose holder changed while it was being judged stale ($aside)" >&2
        fi
        return 1
    fi
    rm -rf "$aside"
    return 0
}

# Take the host-wide lock, waiting while a live run-tests.sh holds it.
suite_lock_acquire() {
    local lock pid started announced=0 poll="${CCTRL_SUITE_LOCK_POLL:-5}" tries=0
    lock="$(suite_lock_path)"
    mkdir -p "$(dirname "$lock")"
    while :; do
        if mkdir "$lock" 2>/dev/null; then
            date +%s > "$lock/started_at"
            date '+%Y-%m-%d %H:%M:%S' > "$lock/started"
            # pid last and via mv: its presence means the lock is complete.
            printf '%s\n' "$$" > "$lock/pid.tmp"
            mv "$lock/pid.tmp" "$lock/pid"
            _SUITE_LOCK_HELD=1
            _SUITE_LOCK_DIR_HELD="$lock"
            return 0
        fi
        pid="$(cat "$lock/pid" 2>/dev/null || true)"
        if [[ -z "$pid" ]]; then
            # Holder is between mkdir and writing its pid, or died there.
            if [[ -d "$lock" && -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
                _suite_lock_break_stale "$lock" "" || true
            fi
        elif ! _suite_lock_holder_live "$pid"; then
            echo "suite lock: breaking stale lock (holder pid $pid is not a live run-tests.sh)" >&2
            _suite_lock_break_stale "$lock" "$pid" || true
        else
            started="$(cat "$lock/started" 2>/dev/null || true)"
            if [[ "$announced" -eq 0 ]]; then
                echo "run-tests.sh: waiting for suite lock held by PID $pid since ${started:-unknown} ($lock)" >&2
                announced=1
            fi
            tries=$(( tries + 1 ))
            if (( tries % 120 == 0 )); then
                echo "run-tests.sh: still waiting for suite lock held by PID $pid since ${started:-unknown}" >&2
            fi
            sleep "$poll"
        fi
    done
}

# Release only a lock we hold and that still names us.
suite_lock_release() {
    [[ "$_SUITE_LOCK_HELD" -eq 1 && -n "$_SUITE_LOCK_DIR_HELD" ]] || return 0
    local cur
    cur="$(cat "$_SUITE_LOCK_DIR_HELD/pid" 2>/dev/null || true)"
    if [[ "$cur" == "$$" ]]; then
        rm -rf "$_SUITE_LOCK_DIR_HELD"
    fi
    _SUITE_LOCK_HELD=0
    _SUITE_LOCK_DIR_HELD=""
    return 0
}

# ---- pass stamps -------------------------------------------------------

suite_gate_host() { hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown-host; }

suite_gate_bash_mm() { # [bash-binary]
    local b="${1:-bash}"
    "$b" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null || printf 'unknown'
}

suite_gate_py_mm() {
    python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || printf 'none'
}

# Print the git tree hash of the content under ROOT, or nothing when the key
# cannot be trusted. CCTRL_SUITE_TREE (set by self-install for its .git-less
# scratch copy) wins. Otherwise ROOT must be the top of a git work tree with
# no tracked modifications and no untracked, non-ignored files.
suite_gate_tree() { # root
    local root="$1" top phys
    if [[ -n "${CCTRL_SUITE_TREE:-}" ]]; then
        [[ "$CCTRL_SUITE_TREE" =~ ^[0-9a-f]{40,64}$ ]] || return 1
        printf '%s' "$CCTRL_SUITE_TREE"
        return 0
    fi
    top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || return 1
    top="$(cd "$top" 2>/dev/null && pwd -P)" || return 1
    phys="$(cd "$root" 2>/dev/null && pwd -P)" || return 1
    [[ "$top" == "$phys" ]] || return 1
    [[ -z "$(git -C "$root" status --porcelain 2>/dev/null)" ]] || return 1
    git -C "$root" rev-parse --verify -q 'HEAD^{tree}' 2>/dev/null
}

# Stamp file name for tree + this host + bash major.minor + python major.minor.
suite_stamp_key() { # tree bash-mm py-mm [host]
    local host="${4:-$(suite_gate_host)}" k
    k="$1.$host.bash$2.py$3"
    printf '%s' "$k" | tr -c 'A-Za-z0-9._-' '_'
}

suite_stamp_path() { printf '%s/%s' "$(suite_pass_dir)" "$(suite_stamp_key "$@")"; }

suite_stamp_check() { # tree bash-mm py-mm  -> 0 when a stamp exists
    local p
    p="$(suite_stamp_path "$@")"
    [[ -f "$p" ]]
}

suite_stamp_write() { # tree bash-mm py-mm
    local tree="$1" bmm="$2" pmm="$3" dir p tmp
    dir="$(suite_pass_dir)"
    mkdir -p "$dir"
    p="$(suite_stamp_path "$tree" "$bmm" "$pmm")"
    tmp="$p.tmp.$$"
    {
        printf 'tree=%s\n' "$tree"
        printf 'host=%s\n' "$(suite_gate_host)"
        printf 'bash=%s\n' "$bmm"
        printf 'python=%s\n' "$pmm"
        printf 'recorded=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$tmp"
    mv "$tmp" "$p"
    suite_stamp_prune "${CCTRL_SUITE_STAMP_KEEP:-20}"
    printf '%s' "$p"
}

suite_stamp_prune() { # keep-count
    local keep="${1:-20}" dir f n=0
    dir="$(suite_pass_dir)"
    [[ -d "$dir" ]] || return 0
    # Newest first; names are made only of [A-Za-z0-9._-], so word splitting
    # on ls output is safe.
    for f in $(ls -1t "$dir" 2>/dev/null); do
        n=$(( n + 1 ))
        if (( n > keep )); then rm -f "$dir/$f"; fi
    done
    return 0
}

suite_stamp_recorded() { # stamp-path -> the recorded= value
    sed -n 's/^recorded=//p' "$1" 2>/dev/null | head -1
}

# End-of-run hook: record a pass stamp only for a full, green, clean-tree run.
# The caller invokes it after every gate (shell tests, python tests, report)
# has passed; a filtered or failed run never reaches here, and the checks
# below make a misuse harmless too. Prints the reason when nothing is written.
suite_record_pass() { # root full(1|0) tree-at-start bash-mm py-mm
    local root="$1" full="$2" tree0="$3" bmm="$4" pmm="$5" tree1 p
    if [[ "$full" != 1 ]]; then
        echo "suite pass stamp: not recorded (filtered or group run)" >&2
        return 1
    fi
    if [[ -z "$tree0" ]]; then
        echo "suite pass stamp: not recorded (tree was not a clean git tree at start, and no CCTRL_SUITE_TREE)" >&2
        return 1
    fi
    tree1="$(suite_gate_tree "$root" || true)"
    if [[ "$tree1" != "$tree0" ]]; then
        echo "suite pass stamp: not recorded (tree changed during the run)" >&2
        return 1
    fi
    p="$(suite_stamp_write "$tree0" "$bmm" "$pmm")" || return 1
    echo "suite pass stamp: recorded $p" >&2
    return 0
}
