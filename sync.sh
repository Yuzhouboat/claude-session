#!/usr/bin/env bash
# Copies this repo's claude-session files into each project's
# claude-session/ folder, then shows what changed there. Never touches a
# project's claude-schedule.conf or log. By default it stops there — review
# the diff and commit yourself — or pass --commit / --push to finish the job.
#
# Usage:
#   ./sync.sh                     # every project listed in sync-targets.local
#   ./sync.sh /path/to/project…   # just these
#
# Options (any order, before the paths):
#   --force    overwrite even if a project has uncommitted edits to the
#              synced files
#   --commit   commit the synced files in each project ("Sync
#              claude-session <version> (<upstream commit>)")
#   --push     --commit, then push each project
#
# --commit/--push only commit the synced files (never claude-schedule.conf
# or anything else), and skip a project that has other changes already
# staged or isn't on its default branch. They also refuse to run while this
# repo has uncommitted changes, so the version/commit in the message is real.
#
# Note: cron runs the files on disk, so a sync is live on this machine at
# the next scheduled run even without --commit. Try risky changes on one
# project first: ./sync.sh ~/Y_Know
#
# sync-targets.local (git-ignored, one project path per line, # comments
# allowed) is this machine's list of projects — paths differ per machine.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGETS_FILE="$SRC/sync-targets.local"
FILES=(setup.sh start-claude.sh README.md claude-schedule.conf.example VERSION .gitignore)
VERSION="$(cat "$SRC/VERSION")"

force=0
commit=0
push=0
while [ $# -gt 0 ]; do
    case "$1" in
        --force)  force=1 ;;
        --commit) commit=1 ;;
        --push)   commit=1; push=1 ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1"; echo "Usage: ./sync.sh [--force] [--commit|--push] [/path/to/project…]"; exit 1 ;;
        *) break ;;
    esac
    shift
done

if [ "$commit" = 1 ]; then
    if [ -n "$(git -C "$SRC" status --porcelain --untracked-files=no)" ]; then
        echo "claude-session has uncommitted changes — commit (and push) them first,"
        echo "so projects record a real upstream version:"
        git -C "$SRC" status --short --untracked-files=no | sed 's/^/   /'
        exit 1
    fi
    UPSTREAM_SHA="$(git -C "$SRC" rev-parse --short HEAD)"
    if [ "$push" = 1 ] && [ -n "$(git -C "$SRC" log --oneline '@{u}..' 2>/dev/null)" ]; then
        echo "note: claude-session has unpushed commits — projects will reference $UPSTREAM_SHA before it's on GitHub."
        echo
    fi
fi

if [ $# -gt 0 ]; then
    targets=("$@")
elif [ -f "$TARGETS_FILE" ]; then
    mapfile -t targets < <(grep -Ev '^[[:space:]]*(#|$)' "$TARGETS_FILE")
else
    echo "No projects given and no $TARGETS_FILE."
    echo "Usage: ./sync.sh [--force] [--commit|--push] /path/to/project…"
    exit 1
fi

failed=0
for t in "${targets[@]}"; do
    t="${t/#\~/$HOME}"
    if [ ! -d "$t" ]; then
        echo "!! $t: not a directory — skipped"
        failed=1
        continue
    fi
    # Resolve symlinks, so the copy lands at (and diffs against) the real path.
    proj="$(cd "$t" && pwd -P)"
    dest="$proj/claude-session"
    echo "== $proj"

    in_git=0
    git -C "$proj" rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=1

    # Don't silently clobber edits someone made to a project's copy: a file
    # counts only if it has uncommitted changes AND differs from upstream
    # (an uncommitted but identical copy, e.g. from a previous sync, is fine).
    if [ "$in_git" = 1 ] && [ "$force" = 0 ]; then
        dirty=""
        for f in "${FILES[@]}"; do
            [ -f "$dest/$f" ] || continue
            cmp -s "$SRC/$f" "$dest/$f" && continue
            st="$(cd "$proj" && git status --porcelain -- "claude-session/$f")"
            [ -n "$st" ] && dirty+="$st"$'\n'
        done
        dirty="${dirty%$'\n'}"
        if [ -n "$dirty" ]; then
            echo "!! uncommitted changes to synced files — skipped (commit them, or re-run with --force):"
            echo "$dirty" | sed 's/^/   /'
            failed=1
            echo
            continue
        fi
    fi

    old_version="$(cat "$dest/VERSION" 2>/dev/null || echo none)"
    mkdir -p "$dest"
    for f in "${FILES[@]}"; do
        cp "$SRC/$f" "$dest/$f"
    done
    chmod +x "$dest/setup.sh" "$dest/start-claude.sh"
    echo "   version: $old_version -> $VERSION"

    if [ "$in_git" = 1 ]; then
        changes="$(cd "$proj" && git status --short -- claude-session)"
        if [ -n "$changes" ]; then
            echo "$changes" | sed 's/^/   /'
        else
            echo "   (already up to date)"
        fi
        if (cd "$proj" && git ls-files --error-unmatch claude-session/claude-tmux.log >/dev/null 2>&1); then
            echo "   note: claude-tmux.log is still tracked — untrack it with:"
            echo "         git -C '$proj' rm --cached claude-session/claude-tmux.log"
        fi
    else
        echo "   (not a git repo — nothing to diff)"
    fi
    [ -f "$dest/claude-schedule.conf" ] || echo "   note: no claude-schedule.conf yet — run $dest/setup.sh"

    # --- Optional: commit (and push) just the synced files -----------------
    if [ "$commit" = 1 ] && [ "$in_git" = 1 ]; then
        synced_paths=("${FILES[@]/#/claude-session/}")
        branch="$(git -C "$proj" branch --show-current)"
        default="$(git -C "$proj" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
        default="${default#origin/}"
        if [ "$branch" != "$default" ]; then
            echo "!! on branch '$branch', not '$default' — not committing (commit it yourself)"
            failed=1
        elif [ -n "$(cd "$proj" && git diff --cached --name-only -- . "${synced_paths[@]/#/:!}")" ]; then
            echo "!! other changes are already staged — not committing, so they aren't swept in:"
            (cd "$proj" && git diff --cached --name-status -- . "${synced_paths[@]/#/:!}") | sed 's/^/   /'
            failed=1
        else
            (cd "$proj" && git add -- "${synced_paths[@]}")
            if (cd "$proj" && git diff --cached --quiet); then
                echo "   nothing to commit"
            else
                (cd "$proj" && git commit -q -m "Sync claude-session $VERSION ($UPSTREAM_SHA)" \
                    -m "From https://github.com/Yuzhouboat/claude-session at $UPSTREAM_SHA.")
                echo "   committed: $(git -C "$proj" log --oneline -1)"
            fi
            if [ "$push" = 1 ]; then
                if [ -z "$(git -C "$proj" log --oneline '@{u}..' 2>/dev/null)" ]; then
                    echo "   nothing to push"
                elif git -C "$proj" push -q 2>&1 | sed 's/^/   /'; [ "${PIPESTATUS[0]}" = 0 ]; then
                    echo "   pushed to origin/$branch"
                else
                    echo "!! push failed — commit is local; push it yourself"
                    failed=1
                fi
            fi
        fi
    fi
    echo
done

if [ "$commit" = 0 ]; then
    echo "Review with 'git -C <project> diff -- claude-session', then commit in each project"
    echo "(or re-run with --commit / --push)."
fi
exit "$failed"
