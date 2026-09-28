#!/usr/bin/env bash
# Adds claude-session to a project and runs its setup.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Yuzhouboat/claude-session/main/install.sh) [--local] [project-dir]
#   ./install.sh [--local] [project-dir]        # from a clone of this repo
#
# project-dir defaults to the git repo you're in (or the current directory).
#
# Default: writes claude-session/setup.sh (the bootstrap) and
#   claude-session/.gitignore for you to commit, so everyone who clones the
#   project gets it.
# --local: same files, but hidden from git through this clone's
#   .git/info/exclude — nothing shows in `git status`, nothing to commit.
#   For repos you use but don't want to add this to. Only this clone has it.
#
# Either way, setup.sh then fetches the latest scripts into
# claude-session/.upstream/ and walks through the settings. Re-running it
# on an existing install refreshes the bootstrap files and runs setup again.
set -euo pipefail

BRANCH="${CLAUDE_SESSION_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/Yuzhouboat/claude-session/$BRANCH"

local_mode=0
while [ $# -gt 0 ]; do
    case "$1" in
        --local) local_mode=1 ;;
        -h|--help)
            echo "Usage: install.sh [--local] [project-dir]"
            echo "  (default)  add claude-session/ for committing to the project"
            echo "  --local    add it hidden via .git/info/exclude — nothing to commit"
            echo "project-dir defaults to the git repo you're in. Then runs setup."
            exit 0 ;;
        -*) echo "Unknown option: $1 (usage: install.sh [--local] [project-dir])"; exit 1 ;;
        *) break ;;
    esac
    shift
done

if [ $# -gt 0 ]; then
    PROJECT="$1"
else
    PROJECT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
PROJECT="$(cd "$PROJECT" && pwd -P)"
DEST="$PROJECT/claude-session"

in_git=0
git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=1

if [ "$local_mode" = 1 ]; then
    if [ "$in_git" = 0 ]; then
        echo "--local needs a git repo (it hides claude-session/ via .git/info/exclude)."
        echo "$PROJECT isn't one — run without --local instead."
        exit 1
    fi
    if [ -n "$(git -C "$PROJECT" ls-files -- claude-session)" ]; then
        echo "This repo already tracks files in claude-session/:"
        git -C "$PROJECT" ls-files -- claude-session | sed 's/^/  /'
        echo "A local-only install would clash with them. Use that committed setup"
        echo "(./claude-session/setup.sh if it has one), or remove it from the repo first."
        exit 1
    fi
fi

echo "Installing claude-session into $PROJECT$([ "$local_mode" = 1 ] && echo ' (local only)')"
mkdir -p "$DEST"

# Bootstrap files: from this clone if we're running from one, else GitHub.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
for f in setup.sh .gitignore; do
    if [ -n "$HERE" ] && [ -f "$HERE/bootstrap/$f" ]; then
        cp "$HERE/bootstrap/$f" "$DEST/$f"
    else
        curl -fsSL "$RAW_BASE/bootstrap/$f" -o "$DEST/$f"
    fi
done
chmod +x "$DEST/setup.sh"

if [ "$local_mode" = 1 ]; then
    exclude="$(cd "$PROJECT" && git rev-parse --path-format=absolute --git-path info/exclude)"
    mkdir -p "$(dirname "$exclude")"
    if ! grep -qxF "/claude-session/" "$exclude" 2>/dev/null; then
        printf '\n# claude-session, installed locally (not part of this repo)\n/claude-session/\n' >> "$exclude"
    fi
    echo "Hidden from git via $exclude"
fi
echo

# Setup asks questions; when this script was piped in, read them from the
# terminal rather than from the pipe.
if [ ! -t 0 ] && (exec </dev/tty) 2>/dev/null; then
    exec </dev/tty
fi
"$DEST/setup.sh"

echo
if [ "$local_mode" = 1 ]; then
    echo "Local install done — nothing to commit; git status stays clean."
    echo "To uninstall: $DEST/setup.sh remove && rm -rf '$DEST'"
    echo "  (and delete the /claude-session/ line from $exclude)"
elif [ "$in_git" = 1 ]; then
    echo "Commit it so everyone who clones the project gets it:"
    echo "  git -C '$PROJECT' add claude-session && git -C '$PROJECT' commit -m 'Add scheduled Claude session'"
fi
