#!/usr/bin/env bash
# Scheduled Claude session for this project — bootstrap.
#
# Fetches the latest claude-session scripts from
# https://github.com/Yuzhouboat/claude-session into .upstream/ (next to this
# file, git-ignored), then runs their setup: settings wizard, crontab entry,
# Claude Code workspace trust. Re-run any time to pull the latest scripts
# and review settings. `./setup.sh remove` tears it all down.
#
# This file, claude-schedule.conf and .gitignore are the only
# claude-session files a project keeps. Don't edit this file per project;
# to update it, re-run install.sh (see the claude-session README).
set -euo pipefail

REPO_URL="${CLAUDE_SESSION_REPO:-https://github.com/Yuzhouboat/claude-session.git}"
BRANCH="${CLAUDE_SESSION_BRANCH:-main}"

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM="$SESSION_DIR/.upstream"

if ! command -v git >/dev/null 2>&1; then
    echo "git is required: sudo apt-get update && sudo apt-get install -y git"
    exit 1
fi

# `remove` works with whatever is already fetched — no need to update first.
if [ "${1:-}" = "remove" ] || [ "${1:-}" = "--remove" ]; then
    if [ ! -x "$UPSTREAM/setup.sh" ]; then
        echo "Nothing fetched in $UPSTREAM — nothing to remove."
        exit 0
    fi
    exec "$UPSTREAM/setup.sh" "$@"
fi

if [ -d "$UPSTREAM/.git" ]; then
    echo "Updating claude-session scripts from $REPO_URL ($BRANCH)…"
    # .upstream/ is a managed copy: always reset it to the latest upstream.
    if git -C "$UPSTREAM" fetch -q --depth 1 origin "$BRANCH" \
        && git -C "$UPSTREAM" reset -q --hard FETCH_HEAD; then
        :
    else
        echo "!! Couldn't update — continuing with the copy already in $UPSTREAM."
    fi
else
    echo "Fetching claude-session scripts from $REPO_URL ($BRANCH)…"
    rm -rf "$UPSTREAM"
    git clone -q --depth 1 --branch "$BRANCH" "$REPO_URL" "$UPSTREAM"
fi
echo

exec "$UPSTREAM/setup.sh" "$@"
