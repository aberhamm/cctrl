#!/usr/bin/env bash
# Plan 108 §5.12: per-Stop cost of the peer doorbell. Not part of the suite.
#
#   tests/bench-doorbell.sh [SRC_DATA_DIR] [RUNS]
#   CCTRL_BIN=~/.local/bin/cctrl tests/bench-doorbell.sh [SRC_DATA_DIR] [RUNS]
#
# CCTRL_BIN picks the cctrl under test (default: this checkout's ./cctrl). Set
# it to the installed launcher to time the INSTALLED release.
#
# Copies messages.jsonl and peers.json from SRC_DATA_DIR (default: the repo's
# data/) into a mktemp -d CCTRL_DATA_DIR, starts ONE private tmux session on
# its own socket (tmux -S "$D/sock"), and times `cctrl peer doorbell --hook
# claude` (the same code `hooks run stop` runs first) for four cases:
#   noncctrl   no cctrl env (every non-cctrl Claude session)
#   disabled   cctrl env, no doorbell.json
#   quiet      enabled, no new mail (the common path)
#   ring       enabled, one new message, rung state cleared each run
# Reports p50/p95 wall ms per case (whole process, so cctrl's own startup is
# included). Never touches the real mailbox, settings, or the live tmux
# server; cleanup is kill-session by exact name only (no server-wide kill).
set -euo pipefail
unset TMUX TMUX_PANE CCTRL_PEER CCTRL_SESSION_KIND CCTRL_SESSION_NAME
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/data}"
RUNS="${2:-50}"
[[ -n "${EPOCHREALTIME:-}" ]] || { echo "bench needs bash >= 5 (EPOCHREALTIME)" >&2; exit 1; }
REAL_TMUX="$(command -v tmux)" || { echo "tmux not found" >&2; exit 1; }

D="$(mktemp -d /tmp/cctrl-bench.XXXXXX)"
SESSION="TMUX--bench-doorbell"
cleanup() {
    "$REAL_TMUX" -S "$D/sock" kill-session -t "=$SESSION" 2>/dev/null || true
    rm -rf -- "$D"
}
trap cleanup EXIT

mkdir -p "$D/data" "$D/bin" "$D/sessions" "$D/meta" "$D/home/.claude"
for f in messages.jsonl peers.json; do
    if [[ -f "$SRC/$f" ]]; then cp "$SRC/$f" "$D/data/$f"; fi
done
[[ -f "$D/data/peers.json" ]] || echo '{}' > "$D/data/peers.json"
touch "$D/data/messages.jsonl"
printf '#!/usr/bin/env bash\nexec "%s" -S "%s/sock" "$@"\n' "$REAL_TMUX" "$D" > "$D/bin/tmux"
chmod +x "$D/bin/tmux"

"$REAL_TMUX" -S "$D/sock" new-session -d -s "$SESSION" 'sleep 3600'
"$REAL_TMUX" -S "$D/sock" set-option -t "=$SESSION:" -q @cctrl_managed 1
IFS='|' read -r PANE PANE_PID < <("$REAL_TMUX" -S "$D/sock" display-message -p -t "=$SESSION:" '#{pane_id}|#{pane_pid}')
echo '{"sessionId":"bench-session"}' > "$D/sessions/$PANE_PID.json"
printf '{"role":"orchestrator","orch_kind":"repo","cctrl_managed":true}\n' > "$D/meta/$SESSION.json"
# The ring path walks the hook's ancestry to the first Claude process; a fake
# ps answers that walk with the bench pane pid and names that pid `claude`.
cat > "$D/bin/ps" <<PS
#!/usr/bin/env bash
if [[ "\$1" == "-o" && "\$2" == "ppid=" ]]; then echo " $PANE_PID"; exit 0; fi
if [[ "\$1" == "-o" && ( "\$2" == "comm=" || "\$2" == "args=" ) && "\$3" == "-p" ]]; then
    [[ "\$4" == "$PANE_PID" ]] && echo claude || echo bash
    exit 0
fi
exec /bin/ps "\$@"
PS
chmod +x "$D/bin/ps"

# The installed launcher (~/.local/bin/cctrl) finds its release under
# $CCTRL_HOME; resolve it from the REAL home before HOME is overridden.
export CCTRL_HOME="${CCTRL_HOME:-$HOME/.local/lib/cctrl}"
export HOME="$D/home" CCTRL_DATA_DIR="$D/data" CCTRL_SESSION_METADATA_DIR="$D/meta" \
    CCTRL_CLAUDE_SESSIONS_DIR="$D/sessions" CCTRL_CLAUDE_SETTINGS="$D/home/.claude/settings.json" \
    PATH="$D/bin:$PATH"
CCTRL="${CCTRL_BIN:-$ROOT/cctrl}"
[[ -x "$CCTRL" ]] || { echo "cctrl not executable: $CCTRL" >&2; exit 1; }
"$CCTRL" peer register bench-sender >/dev/null 2>&1 || true

stats() { # label, then ms values on stdin
    sort -n | awk -v l="$1" '{a[NR]=$1} END {p50=a[int((NR+1)/2)]; i=int(NR*0.95+0.999); if (i<1) i=1; if (i>NR) i=NR; printf "%-10s n=%d p50=%.1fms p95=%.1fms max=%.1fms\n", l, NR, p50, a[i], a[NR]}'
}
run_case() { # label envmode
    local label="$1" mode="$2" i t0 t1 rc
    for ((i = 0; i < RUNS; i++)); do
        [[ "$label" == "ring" ]] && rm -rf "$D/data/doorbell/state"
        t0=$EPOCHREALTIME; rc=0
        if [[ "$mode" == "cctrl" ]]; then
            printf '{"session_id":"bench-session"}' | CCTRL_SESSION_KIND=tmux CCTRL_SESSION_NAME="$SESSION" TMUX="$D/sock,1,0" TMUX_PANE="$PANE" \
                "$CCTRL" peer doorbell --hook claude >/dev/null 2>&1 || rc=$?
        else
            printf '{}' | "$CCTRL" peer doorbell --hook claude >/dev/null 2>&1 || rc=$?
        fi
        t1=$EPOCHREALTIME
        if [[ "$label" == "ring" && "$rc" -ne 2 ]]; then echo "ring case did not ring (rc=$rc)" >&2; exit 1; fi
        if [[ "$label" != "ring" && "$rc" -ne 0 ]]; then echo "$label case rc=$rc" >&2; exit 1; fi
        awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f\n", (b - a) * 1000 }'
    done | stats "$label"
}

echo "bench: cctrl=$CCTRL"
echo "bench: $(wc -l < "$D/data/messages.jsonl" | tr -d ' ') messages, $(wc -c < "$D/data/messages.jsonl" | tr -d ' ') bytes, $RUNS runs per case"
run_case noncctrl plain
rm -f "$D/data/doorbell.json"
run_case disabled cctrl
printf '{"enabled":true,"baseline_at":"2099-01-01T00:00:00Z","peers":[],"roles":["orchestrator"],"mode":"blocking"}\n' > "$D/data/doorbell.json"
run_case quiet cctrl
printf '{"enabled":true,"baseline_at":"2000-01-01T00:00:00Z","peers":[],"roles":["orchestrator"],"mode":"blocking"}\n' > "$D/data/doorbell.json"
"$CCTRL" peer send "$SESSION" --from bench-sender --no-deliver -- "bench mail" >/dev/null
run_case ring cctrl
