#!/usr/bin/env bash
# The plan 116 A0 data/config.json runbook, one checkout at a time.
#
# Why: A0 stops tracking data/config.json (the shipped default moved to
# share/config.default.json). `git rm --cached` keeps the file only in the
# clone where it ran. Every other checkout that fast-forwards past that commit
# DELETES an unmodified data/config.json (and refuses the pull if it is
# modified). New releases do not need it, but a rollback to a release older
# than A0 would run without it. So, on each checkout (each Mac's main
# checkout and any worktree that has the file):
#
#   install/data-config-runbook.sh save    <checkout>   # before the fast-forward
#   git -C <checkout> merge --ff-only <ref>            # the fast-forward itself
#   install/data-config-runbook.sh restore <checkout>   # after it
#
# `save` copies data/config.json to data/config.json.a0-keep (0600, kept as
# the backup). `restore` puts it back when the fast-forward removed it (from
# the keep copy, else from the last commit that still tracked it), refuses to
# overwrite a file that differs, and checks that the file is present,
# untracked and ignored (`git status --ignored`). `check` only reports.
#
# This script never fetches, merges, pushes or installs, and touches nothing
# but data/config.json and its keep copy in the checkout it is given.
set -euo pipefail

usage() {
    echo "Usage: data-config-runbook.sh save|restore|check <checkout>" >&2
    exit 64
}

[[ $# -eq 2 ]] || usage
action="$1"
checkout="$2"
[[ -d "$checkout" ]] || { echo "data-config-runbook: no such checkout: $checkout" >&2; exit 66; }
git -C "$checkout" rev-parse --git-dir >/dev/null 2>&1 \
    || { echo "data-config-runbook: not a git checkout: $checkout" >&2; exit 66; }

file="$checkout/data/config.json"
keep="$checkout/data/config.json.a0-keep"

tracked() { git -C "$checkout" ls-files --error-unmatch data/config.json >/dev/null 2>&1; }
ignored() { git -C "$checkout" check-ignore -q data/config.json; }

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

case "$action" in
    save)
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
        ;;
    restore)
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
        ;;
    check)
        report
        ;;
    *)
        usage
        ;;
esac
