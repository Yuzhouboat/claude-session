#!/usr/bin/env bash
# One scheduled run of this project's Claude session:
#   1. kill this project's tmux sessions idle (no pane output) for
#      IDLE_MINUTES or more — sessions still producing output are left alone
#   2. skip the run if one of them is still mid-turn
#   3. refuse to launch if Claude Code doesn't trust the project folder
#   4. start a new timestamped tmux session running an interactive `claude`
#   5. type PROMPT into it and make sure the turn actually started
# Every outcome is one line in claude-session/claude-tmux.log.
#
# The tmux session name and the Remote Control session name are DIFFERENT
# strings, deliberately:
#   - tmux session name = $TMUX_BASE-<timestamp>. $TMUX_BASE is this
#     project's full absolute path with "/" replaced by "-", so it's
#     guaranteed unique even if another project on this machine happens to
#     share the same folder name — no collision, no manual naming needed.
#   - Remote Control session name = $REMOTE_BASE-<timestamp>, where
#     REMOTE_BASE = $HOST-$SESSION (hostname always prepended, fixed;
#     SESSION is the human-friendly label from claude-schedule.conf). This
#     is the name you'll recognize when connecting from another device.
#
# Meant to be called from cron; set up via the project's
# claude-session/setup.sh. See README.md for full instructions.
#
# Lives in <project>/claude-session/.upstream/ — a checkout of
# https://github.com/Yuzhouboat/claude-session that the project's setup.sh
# fetches. Project-owned files (claude-schedule.conf, claude-tmux.log) sit
# one level up, in <project>/claude-session/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(cd "$SESSION_DIR/.." && pwd)"
CONFIG_FILE="$SESSION_DIR/claude-schedule.conf"

# Hostname is always prepended to the Remote Control session base — fixed
# here, not configurable via claude-schedule.conf — so SESSION only ever
# needs to hold the project-specific part.
HOST="$(hostname -s 2>/dev/null || hostname)"

# Defaults — normally overridden by claude-schedule.conf (written by setup.sh).
SESSION="$(basename "$PROJECT_DIR")"
PROMPT="hello"
BOOT_WAIT=5
IDLE_MINUTES=30

# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# Remote Control session base: hostname (always) + SESSION (the
# configurable label). Not used for the tmux session name — see TMUX_BASE
# below.
REMOTE_BASE="${HOST}-${SESSION}"

# tmux session base: this project's full absolute path with "/" replaced
# by "-" (and the leading "-" trimmed), so it's collision-proof regardless
# of what SESSION is set to, or whether two different projects share a
# folder name. Deterministic — the same project directory always maps to
# the same value, so the idle-sweep below keeps matching this project's
# own past sessions.
TMUX_BASE="$(printf '%s' "$PROJECT_DIR" | tr '/' '-' | sed 's/^-//')"

LOG="$SESSION_DIR/claude-tmux.log"

export PATH="$HOME/.local/bin:$PATH"

log() {
    local line="$(date '+%F %T'): $1"
    echo "$line" >> "$LOG"
    # Also show on the terminal when run interactively (cron has no tty).
    if [ -t 1 ]; then
        echo "$line"
    fi
}

# --- Sweep $TMUX_BASE-* sessions: kill any idle >= IDLE_MINUTES. -----------
idle_threshold=$(( IDLE_MINUTES * 60 ))
now="$(date +%s)"

while IFS= read -r s; do
    [ -z "$s" ] && continue
    case "$s" in
        "${TMUX_BASE}-"*)
            last_activity="$(tmux display-message -p -t "$s" '#{session_activity}' 2>/dev/null || echo "$now")"
            idle_seconds=$(( now - last_activity ))
            if [ "$idle_seconds" -ge "$idle_threshold" ]; then
                tmux kill-session -t "$s"
                log "killed idle session '$s' (idle ${idle_seconds}s >= ${idle_threshold}s threshold)"
            fi
            ;;
    esac
done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

# --- Skip this run if a previous one is still working -----------------------
# Two runs of the same prompt at once (e.g. two /issue-fixer passes) can
# pick up the same work. "Busy" = claude's footer shows "esc to interrupt",
# which only appears while a turn is running — a session that finished and
# is just sitting at the input box doesn't block a new run.
while IFS= read -r s; do
    case "$s" in
        "${TMUX_BASE}-"*)
            if tmux capture-pane -t "$s" -p 2>/dev/null | grep -q "esc to interrupt"; then
                log "skipped: previous session '$s' is still running a turn"
                exit 0
            fi
            ;;
    esac
done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

# --- Refuse to launch into the trust dialog ---------------------------------
# An untrusted directory (e.g. the project was moved) makes claude show
# "Do you trust this folder?" with "No, exit" preselected; the Enter below
# picks it and the run dies silently. Log it loudly instead. Skipped if jq
# is unavailable.
CLAUDE_JSON="$HOME/.claude.json"
if command -v jq >/dev/null 2>&1 && [ -f "$CLAUDE_JSON" ]; then
    trusted="$(jq --arg p "$PROJECT_DIR" '.projects[$p].hasTrustDialogAccepted // false' "$CLAUDE_JSON" 2>/dev/null || echo unknown)"
    if [ "$trusted" = "false" ]; then
        log "ERROR: Claude Code does not trust '$PROJECT_DIR' (folder moved?) — not launching. Run claude-session/setup.sh there, or open claude in that folder once and choose \"Yes, I trust this folder\"."
        exit 1
    fi
fi

# --- Start a new timestamped session ----------------------------------------
TIMESTAMP="$(date +%H%M-%m%d%Y)"
NEW_SESSION="${TMUX_BASE}-${TIMESTAMP}"
REMOTE_PREFIX="${REMOTE_BASE}-${TIMESTAMP}"

# Credentials (API tokens, database creds, etc.) the project's skills need.
# Cron doesn't inherit your interactive shell's exports, so source them from
# ~/.env (shared across projects) inside the tmux pane, right before
# exec'ing claude.
ENV_FILE="$HOME/.env"

tmux new-session -d -s "$NEW_SESSION" -c "$PROJECT_DIR" \
    bash -c "[ -f '$ENV_FILE' ] && { set -a; source '$ENV_FILE'; set +a; }; exec claude --remote-control --remote-control-session-name-prefix '${REMOTE_PREFIX}' --permission-mode auto"

# Give the TUI time to boot before typing into it (a minimum — see the
# readiness wait below).
sleep "$BOOT_WAIT"

# If claude exited during startup (not on cron's PATH, not logged in, …)
# the session is already gone; say so instead of dying on send-keys below.
if ! tmux has-session -t "$NEW_SESSION" 2>/dev/null; then
    log "ERROR: claude exited during startup — session '$NEW_SESSION' is gone. Run $SCRIPT_DIR/start-claude.sh by hand and watch the tmux pane to see why."
    exit 1
fi

pane() { tmux capture-pane -t "$NEW_SESSION" -p 2>/dev/null; }

# BOOT_WAIT is only a minimum: also wait (up to READY_TIMEOUT seconds) for
# the input box's footer, so a slow boot — e.g. several projects launching
# in the same minute — doesn't swallow the typed prompt.
READY_TIMEOUT=30
for _ in $(seq "$READY_TIMEOUT"); do
    pane | grep -q "shift+tab to cycle" && break
    sleep 1
done

tmux send-keys -t "$NEW_SESSION" "$PROMPT" Enter

# Keep going until the footer shows "esc to interrupt" (only there while a
# turn is running). Two ways the first try can fail:
# - The prompt sits unsubmitted: a PROMPT starting with "/" opens the
#   slash-command dropdown, which eats the first Enter, and
#   remote-control's first-run screens can eat another. Press Enter again.
# - The prompt was lost: typed while claude was still drawing, leaving an
#   empty input box. Pressing Enter can't fix that, so clear the box and
#   type it again.
# A long prompt wraps across lines in the input box, so compare with all
# whitespace removed. Clearing takes several C-u presses, since each one
# only clears the current line of a multi-line input.
# Give up after a few tries and log it so a stuck session is visible.
squash() { tr -d '[:space:]'; }
PROMPT_HEAD="$(printf '%s' "$PROMPT" | squash | cut -c1-40)"
submitted=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    if pane | grep -q "esc to interrupt"; then
        submitted=1
        break
    fi
    if pane | squash | grep -qF -- "$PROMPT_HEAD"; then
        tmux send-keys -t "$NEW_SESSION" Enter
    else
        tmux send-keys -t "$NEW_SESSION" Escape
        for _ in 1 2 3 4 5 6 7 8; do tmux send-keys -t "$NEW_SESSION" C-u; done
        tmux send-keys -t "$NEW_SESSION" "$PROMPT" Enter
    fi
done

if [ "$submitted" = 1 ]; then
    log "started tmux session '$NEW_SESSION' (remote-control name '$REMOTE_PREFIX') with prompt: $PROMPT"
else
    log "WARNING: '$NEW_SESSION' still not showing signs of a running turn after $attempt attempts — prompt may be stuck unsubmitted: $PROMPT"
fi
