#!/usr/bin/env bash
# Compare shellcheck findings with a recorded baseline (plan 121 E0).
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
shellcheck --version >/dev/null 2>&1 || { echo "ci-shellcheck: shellcheck is installed but broken" >&2; exit 2; }

files=(cctrl)
while IFS= read -r f; do files+=("$f"); done < <(git ls-files '*.sh' | sort)

now="$(mktemp "${TMPDIR:-/tmp}/ci-shellcheck.XXXXXX")"
# rc 0 = clean, rc 1 = findings; rc >= 2 means shellcheck itself failed: fatal.
out="$(mktemp "${TMPDIR:-/tmp}/ci-shellcheck-out.XXXXXX")"
trap 'rm -f "$now" "$out"' EXIT
for f in "${files[@]}"; do
    src=0
    # Extended analysis is off for memory: about 34 GB peak with it, about 2 GB without (CI runner has 7 GB).
    shellcheck --extended-analysis=false -S warning -f gcc -x "$f" >> "$out" || src=$?
    if (( src >= 2 )); then
        echo "ci-shellcheck: shellcheck failed (rc $src) on $f" >&2
        exit 2
    fi
done
sed -n 's/^\([^:]*\):[0-9]*:[0-9]*: .*\[\(SC[0-9]*\)\]$/\1 \2/p' "$out" \
    | sort | uniq -c | sed 's/^ *//' > "$now"

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
