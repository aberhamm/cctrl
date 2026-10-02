#!/usr/bin/env bash
# Builds a checked release of this checkout and swaps it into
# $CCTRL_HOME/current, then atomically installs the launcher at $CCTRL_BIN
# (default ~/.local/bin/cctrl). Never touches either path until every gate
# (syntax + the full test suite) passes against the release that is about
# to ship, not against the live working tree -- see docs/plans/079.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

CCTRL_HOME="${CCTRL_HOME:-$HOME/.local/lib/cctrl}"
CCTRL_BIN="${CCTRL_BIN:-$HOME/.local/bin/cctrl}"
RELEASES_DIR="$CCTRL_HOME/releases"
CURRENT_LINK="$CCTRL_HOME/current"
NEXT_LINK="$CCTRL_HOME/current.next"

mkdir -p "$RELEASES_DIR"

SCRATCH="$RELEASES_DIR/.tmp-$$"
CLEANUP_SCRATCH=1
cleanup() {
    if [[ "$CLEANUP_SCRATCH" == 1 && -e "$SCRATCH" ]]; then
        rm -rf "$SCRATCH"
    fi
    if [[ "$CLEANUP_SCRATCH" == 1 && -e "$SCRATCH.tar" ]]; then
        rm -f "$SCRATCH.tar"
    fi
}
trap cleanup EXIT

# Refuse a dirty tree: installing anything other than exactly what HEAD
# says is committed reopens the 2026-09-27 hazard this plan exists to
# close (a half-finished edit to a tracked file ending up live). Ignores
# untracked files (data/, costs/, profiles/, .active-profile are gitignored
# and irrelevant to this check) -- only tracked-file modifications count.
if [[ -n "$(cd "$ROOT" && git status --porcelain --untracked-files=no)" ]]; then
    echo "cctrl self-install: refusing to install -- $ROOT has uncommitted changes to tracked files. Commit or stash them first." >&2
    cd "$ROOT" && git status --short --untracked-files=no >&2
    exit 1
fi

SHA="$(cd "$ROOT" && git rev-parse HEAD)"
SHORT_SHA="${SHA:0:12}"

echo "cctrl self-install: building release from $ROOT at $SHORT_SHA" >&2

# Build the release from exactly what's committed at HEAD, not a hand-kept
# list of paths: `git archive` extracts every tracked file and nothing
# else, so a new lib/hooks/test/doc file is shipped automatically and
# nothing untracked (data/, costs/, profiles/, .active-profile, scratch
# files) sneaks in. Three hand-kept-list gaps found and fixed across the
# first four live installs (install.sh, install/, AGENTS.md/CLAUDE.md/
# README.md/skills/, .githooks/) are exactly the failure mode this closes.
mkdir -p "$SCRATCH"
# Archive to a file rather than piping straight into `tar -x`: macOS's
# bsdtar closes its stdin as soon as it has read the end-of-archive
# markers, before consuming git archive's trailing record padding, so
# `git archive` gets SIGPIPE and exits 141 even though extraction is
# complete -- with pipefail that failed this script on every run despite
# shipping a correct release.
git -C "$ROOT" archive --format=tar -o "$SCRATCH.tar" "$SHA"
tar -x -C "$SCRATCH" -f "$SCRATCH.tar"
rm -f "$SCRATCH.tar"
printf '%s\n' "$SHA" > "$SCRATCH/VERSION"

# data/config.json is tracked despite data/ being gitignored (it ships a
# default config for fresh installs), so the archive leaves a real
# data/config.json behind. Clear it before symlinking -- the repo's own
# data/config.json is the same file; the symlink is authoritative.
rm -rf "$SCRATCH/data" "$SCRATCH/costs" "$SCRATCH/profiles" "$SCRATCH/.active-profile"

# Mutable state lives in the repo, never duplicated into a release.
for link in data costs profiles; do
    ln -s "$ROOT/$link" "$SCRATCH/$link"
done
ln -s "$ROOT/.active-profile" "$SCRATCH/.active-profile"

echo "cctrl self-install: checking syntax" >&2
bash -n "$SCRATCH/cctrl"
[[ -f "$SCRATCH/install.sh" ]] && bash -n "$SCRATCH/install.sh"
bash -n "$SELF_DIR/self-install.sh"
bash -n "$SELF_DIR/cctrl-launcher.sh"
for f in "$SCRATCH"/lib/*.sh "$SCRATCH"/hooks/*.sh; do
    [[ -f "$f" ]] || continue
    bash -n "$f"
done
for f in "$SCRATCH"/lib/*.py "$SCRATCH"/hooks/*.py; do
    [[ -f "$f" ]] || continue
    python3 -m py_compile "$f"
done
for f in "$SCRATCH"/lib/*.pl; do
    [[ -f "$f" ]] || continue
    perl -c "$f" 2>/dev/null
done

echo "cctrl self-install: running full test suite (LANG=en_US.UTF-8)" >&2
LANG=en_US.UTF-8 bash "$SCRATCH/tests/run-tests.sh"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
RELEASE_NAME="${SHORT_SHA}-${TS}"
RELEASE_DIR="$RELEASES_DIR/$RELEASE_NAME"

mv "$SCRATCH" "$RELEASE_DIR"
CLEANUP_SCRATCH=0

echo "cctrl self-install: release ready at $RELEASE_DIR" >&2

# Atomic current swap. `-h` is required: plain `mv -f x current` on
# macOS/BSD mv follows `current` (a symlink to a directory) and moves x
# *inside* the old release instead of replacing the symlink itself.
rm -f "$NEXT_LINK"
ln -s "releases/$RELEASE_NAME" "$NEXT_LINK"
mv -fh "$NEXT_LINK" "$CURRENT_LINK"

resolved="$(readlink "$CURRENT_LINK")"
if [[ "$resolved" != "releases/$RELEASE_NAME" ]]; then
    echo "cctrl self-install: FATAL - current -> $resolved, expected releases/$RELEASE_NAME" >&2
    exit 1
fi

echo "cctrl self-install: current -> releases/$RELEASE_NAME" >&2

# Atomic launcher install.
mkdir -p "$(dirname "$CCTRL_BIN")"
LAUNCHER_TMP="$CCTRL_BIN.new"
cp "$SELF_DIR/cctrl-launcher.sh" "$LAUNCHER_TMP"
bash -n "$LAUNCHER_TMP"
chmod +x "$LAUNCHER_TMP"
mv "$LAUNCHER_TMP" "$CCTRL_BIN"

echo "cctrl self-install: installed launcher at $CCTRL_BIN" >&2
echo >&2
echo "Rollback (restores the previous symlink-into-working-tree behavior):" >&2
echo "  ln -sf $ROOT/cctrl $CCTRL_BIN" >&2
