#!/usr/bin/env bash
# shellcheck against a recorded baseline (plan 121 E0).
#   tests/ci-shellcheck.sh           compare with tests/shellcheck-baseline.txt, rc 1 on any increase
#   tests/ci-shellcheck.sh --update  rewrite the baseline from the current tree
# The baseline holds "<count> <file> <SCcode>" lines (severity warning and above),
# not line numbers, so unrelated edits do not churn it. Fewer findings than the
# baseline is a pass with a note: run --update to lock the improvement in.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE="tests/shellcheck-baseline.txt"
command -v shellcheck >/dev/null || { echo "ci-shellcheck: shellcheck not installed" >&2; exit 127; }

files=(cctrl)
while IFS= read -r f; do files+=("$f"); done < <(git ls-files '*.sh' | sort)

now="$(mktemp "${TMPDIR:-/tmp}/ci-shellcheck.XXXXXX")"
trap 'rm -f "$now"' EXIT
for f in "${files[@]}"; do
    shellcheck -S warning -f gcc -x "$f" 2>/dev/null \
        | sed -n 's/^\([^:]*\):[0-9]*:[0-9]*: .*\[\(SC[0-9]*\)\]$/\1 \2/p' || true
done | sort | uniq -c | sed 's/^ *//' > "$now"

if [[ "${1:-}" == "--update" ]]; then
    { echo "# shellcheck -S warning baseline (plan 121 E0): count file code. Regenerate: tests/ci-shellcheck.sh --update"
      cat "$now"; } > "$BASE"
    echo "ci-shellcheck: baseline written ($(wc -l < "$now" | tr -d ' ') entries)"
    exit 0
fi

rc=0
while read -r cnt file code; do
    old="$(awk -v f="$file" -v c="$code" '$2==f && $3==c {print $1}' "$BASE")"
    old="${old:-0}"
    if (( cnt > old )); then
        echo "ci-shellcheck: NEW $code in $file: $cnt now, $old in the baseline" >&2
        rc=1
    elif (( cnt < old )); then
        echo "ci-shellcheck: note: $code in $file dropped from $old to $cnt (run --update)"
    fi
done < "$now"
[[ "$rc" -eq 0 ]] && echo "ci-shellcheck: ok (no findings above the baseline)"
exit "$rc"
