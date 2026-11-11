#!/usr/bin/env bash
# The plan 116 A0 data/config.json runbook, one checkout at a time.
#
# Why: A0 stops tracking data/config.json (the shipped default moved to
# share/config.default.json). `git rm --cached` keeps the file only in the
# clone where it ran. Every other checkout that fast-forwards past that commit
# DELETES an unmodified data/config.json (and refuses the pull if it is
# modified). New releases do not need it, but every release older than A0
# (the live one and each rollback target) reads it, and runs without its
# settings while it is gone.
#
# Preferred: one scripted step per checkout, with no window in which the file
# is missing:
#
#   install/data-config-runbook.sh ff <checkout> <ref>
#
# `ff` refuses a dirty tree, then runs save, `git rm --cached
# data/config.json`, `git merge --ff-only <ref>` and the restore check. The
# file stays in place the whole time (it is untracked before the merge, so
# the merge does not remove it). If the merge fails, the index entry is put
# back and nothing else has changed. Re-running `ff` after a partial or full
# run is safe: a staged removal of data/config.json from an earlier run is
# the one change it accepts, and a checkout already at or past <ref> is only
# checked.
#
# Manual fallback (it leaves a window with no file between steps 2 and 3):
#
#   install/data-config-runbook.sh save    <checkout>   # 1. before the ff
#   git -C <checkout> merge --ff-only <ref>            # 2. the ff itself
#   install/data-config-runbook.sh restore <checkout>   # 3. at once after it
#
# `save` copies data/config.json to data/config.json.a0-keep (0600, kept as
# the backup). `restore` puts it back when the fast-forward removed it (from
# the keep copy, else from the last commit that still tracked it), refuses to
# overwrite a file that differs, and checks that the file is present,
# untracked and ignored (`git status --ignored`). `check` only reports.
#
# LATER MOVES: the file is safe only while the checkout stays at or past the
# untracking commit. ANY move back across it deletes the now-ignored file
# again or blocks the move: a checkout or reset to an older commit and back,
# a bisect, a branch switch (including one made by a file sync tool in a
# shared directory). After any such move, run `check`, and `restore` if the
# file is missing. Moving back to an older commit first needs the untracked
# file out of the way (git refuses to overwrite it); `save` keeps the copy.
#
# This script never fetches, pushes or installs. `ff` merges only the
# fast-forward it is given. It touches nothing but data/config.json, its keep
# copy and (for `ff`) the checkout's HEAD.
set -euo pipefail

usage() {
    echo "Usage: data-config-runbook.sh save|restore|check <checkout>" >&2
    echo "       data-config-runbook.sh ff <checkout> <ref>   (preferred: save, rm --cached, merge --ff-only, verify)" >&2
    exit 64
}

[[ $# -ge 2 ]] || usage
action="$1"
checkout="$2"
case "$action" in
    ff) [[ $# -eq 3 ]] || usage; ref="$3" ;;
    *) [[ $# -eq 2 ]] || usage ;;
esac
[[ -d "$checkout" ]] || { echo "data-config-runbook: no such checkout: $checkout" >&2; exit 66; }
git -C "$checkout" rev-parse --git-dir >/dev/null 2>&1 \
    || { echo "data-config-runbook: not a git checkout: $checkout" >&2; exit 66; }

file="$checkout/data/config.json"
keep="$checkout/data/config.json.a0-keep"

tracked() { git -C "$checkout" ls-files --error-unmatch data/config.json >/dev/null 2>&1; }
ignored() { git -C "$checkout" check-ignore -q data/config.json; }
in_head() { git -C "$checkout" cat-file -e HEAD:data/config.json 2>/dev/null; }

report() {
    local state
    if [[ -f "$file" ]]; then
        if tracked; then state="present, tracked"
        elif ignored; then state="present, untracked, ignored"
        else state="present, untracked, NOT ignored"
        fi
    else
        state="missing"
    fi
    echo "data-config-runbook: $file: $state"
    git -C "$checkout" status --ignored --short -- data/config.json || true
}

do_save() {
    if [[ ! -f "$file" ]]; then
        echo "data-config-runbook: nothing to save: $file is missing (restore can rebuild it from git history)" >&2
        exit 1
    fi
    if [[ -f "$keep" ]] && ! cmp -s "$file" "$keep"; then
        echo "data-config-runbook: refusing: $keep exists and differs from $file; compare them by hand" >&2
        exit 1
    fi
    ( umask 077 && cp -p "$file" "$keep.tmp.$$" && chmod 600 "$keep.tmp.$$" && mv -f "$keep.tmp.$$" "$keep" )
    echo "data-config-runbook: saved $file -> $keep"
    report
}

do_restore() {
    # A fast-forward that removed the last file under data/ removes the
    # directory too; recreate only that leaf.
    [[ -d "$checkout/data" ]] || ( umask 077 && mkdir "$checkout/data" )
    if [[ -f "$file" ]]; then
        if [[ -f "$keep" ]] && ! cmp -s "$file" "$keep"; then
            echo "data-config-runbook: refusing: $file exists and differs from $keep; compare them by hand" >&2
            exit 1
        fi
        echo "data-config-runbook: $file is present; nothing to restore"
    elif [[ -f "$keep" ]]; then
        ( umask 077 && cp -p "$keep" "$file.tmp.$$" && mv -f "$file.tmp.$$" "$file" )
        echo "data-config-runbook: restored $file from $keep"
    else
        # No keep copy: take the content of the last commit that tracked it.
        local gone
        gone="$(git -C "$checkout" log -1 --format=%H --diff-filter=D -- data/config.json 2>/dev/null || true)"
        if [[ -z "$gone" ]] || ! git -C "$checkout" cat-file -e "$gone^:data/config.json" 2>/dev/null; then
            echo "data-config-runbook: cannot restore: no keep copy and no commit in history that removed data/config.json" >&2
            exit 1
        fi
        ( umask 077 && git -C "$checkout" show "$gone^:data/config.json" > "$file.tmp.$$" && mv -f "$file.tmp.$$" "$file" )
        echo "data-config-runbook: restored $file from ${gone:0:12}^ (no keep copy)"
    fi
    if tracked; then
        echo "data-config-runbook: note: data/config.json is still tracked in this checkout (fast-forward not done yet?)"
    elif ! ignored; then
        echo "data-config-runbook: WARNING: data/config.json is untracked but not ignored" >&2
        report
        exit 1
    fi
    report
}

# The checkout's status, minus the one change `ff` itself makes (a staged
# removal of data/config.json from an earlier, interrupted run).
dirty_lines() {
    git -C "$checkout" status --porcelain 2>/dev/null | grep -vxF 'D  data/config.json' || true
}

do_ff() {
    local target dirty
    target="$(git -C "$checkout" rev-parse -q --verify "$ref^{commit}" 2>/dev/null)" \
        || { echo "data-config-runbook: unknown ref: $ref" >&2; exit 66; }
    dirty="$(dirty_lines)"
    if [[ -n "$dirty" ]]; then
        echo "data-config-runbook: refusing: $checkout has local changes; commit or stash them first:" >&2
        printf '%s\n' "$dirty" >&2
        exit 1
    fi
    if git -C "$checkout" merge-base --is-ancestor "$target" HEAD; then
        # Already at or past the ref: only check (and restore if missing).
        echo "data-config-runbook: $checkout is already at or past $ref; checking only"
        if in_head; then
            echo "data-config-runbook: data/config.json is still tracked at HEAD; nothing to do"
            report
            return 0
        fi
        do_restore
        return 0
    fi
    git -C "$checkout" merge-base --is-ancestor HEAD "$target" \
        || { echo "data-config-runbook: refusing: $ref is not a fast-forward of $checkout's HEAD" >&2; exit 1; }
    if git -C "$checkout" cat-file -e "$target:data/config.json" 2>/dev/null; then
        echo "data-config-runbook: refusing: $ref still tracks data/config.json; a plain fast-forward keeps it, no runbook needed" >&2
        exit 1
    fi
    if ! in_head; then
        echo "data-config-runbook: refusing: data/config.json is not tracked at HEAD; use save/restore by hand" >&2
        exit 1
    fi
    do_save
    if tracked; then
        git -C "$checkout" rm -q --cached -- data/config.json
        echo "data-config-runbook: untracked data/config.json in the index (file left in place)"
    fi
    if ! git -C "$checkout" merge -q --ff-only "$target"; then
        git -C "$checkout" reset -q -- data/config.json || true
        echo "data-config-runbook: the fast-forward failed; data/config.json is tracked again and in place" >&2
        report
        exit 1
    fi
    echo "data-config-runbook: fast-forwarded $checkout to ${target:0:12}"
    do_restore
    if ! cmp -s "$file" "$keep"; then
        echo "data-config-runbook: WARNING: $file differs from $keep after the fast-forward" >&2
        exit 1
    fi
    dirty="$(git -C "$checkout" status --porcelain 2>/dev/null || true)"
    if [[ -n "$dirty" ]]; then
        echo "data-config-runbook: WARNING: $checkout is not clean after the fast-forward:" >&2
        printf '%s\n' "$dirty" >&2
        exit 1
    fi
    echo "data-config-runbook: ff done: data/config.json kept, untracked and ignored; tree clean"
}

case "$action" in
    save) do_save ;;
    restore) do_restore ;;
    check) report ;;
    ff) do_ff ;;
    *) usage ;;
esac
