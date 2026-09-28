#!/usr/bin/env bash
# Copies this repo's claude-session files into each project's
# claude-session/ folder, then shows what changed there. Never touches a
# project's claude-schedule.conf or log, and never commits — review the
# diff and commit in each project yourself.
#
# Usage:
#   ./sync.sh                     # every project listed in sync-targets.local
#   ./sync.sh /path/to/project…   # just these
#   ./sync.sh --force …           # overwrite even if the project has
#                                 # uncommitted edits to the synced files
#
# sync-targets.local (git-ignored, one project path per line, # comments
# allowed) is this machine's list of projects — paths differ per machine.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGETS_FILE="$SRC/sync-targets.local"
FILES=(setup.sh start-claude.sh README.md claude-schedule.conf.example VERSION .gitignore)
VERSION="$(cat "$SRC/VERSION")"

force=0
if [ "${1:-}" = "--force" ]; then
    force=1
    shift
fi

if [ $# -gt 0 ]; then
    targets=("$@")
elif [ -f "$TARGETS_FILE" ]; then
    mapfile -t targets < <(grep -Ev '^[[:space:]]*(#|$)' "$TARGETS_FILE")
else
    echo "No projects given and no $TARGETS_FILE."
    echo "Usage: ./sync.sh [--force] /path/to/project…"
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
    echo
done

echo "Review with 'git -C <project> diff -- claude-session', then commit in each project."
exit "$failed"
