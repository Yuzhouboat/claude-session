#!/usr/bin/env bash
# Always launches a new timestamped tmux session with an interactive
# `claude` session inside it, then types a starting prompt into it. Before
# doing that, sweeps existing sessions for this project and kills any that
# have been idle (no pane output) for IDLE_MINUTES or more — active ones
# are left running untouched, so several can coexist. If one of them is
# still in the middle of a turn, this run is skipped instead.
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
# Meant to be called from cron; set up via ./setup.sh. See README.md in
# this folder for full instructions.
#
# Synced from https://github.com/Yuzhouboat/claude-session — edit it there
# and run its sync.sh, not in a project's copy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/claude-schedule.conf"

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

LOG="$SCRIPT_DIR/claude-tmux.log"

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
        log "ERROR: Claude Code does not trust '$PROJECT_DIR' (folder moved?) — not launching. Run ./setup.sh here, or open claude in this folder once and choose \"Yes, I trust this folder\"."
        exit 1
    fi
fi

# --- Always start a new timestamped session ---------------------------------
TIMESTAMP="$(date +%H%M-%m%d%Y)"
NEW_SESSION="${TMUX_BASE}-${TIMESTAMP}"
REMOTE_PREFIX="${REMOTE_BASE}-${TIMESTAMP}"

# Credentials (GH token, Airflow DB creds, etc.) for skills like
# auditing-dags/debugging-dags. Cron doesn't inherit your interactive
# shell's exports, so source them from ~/.env (shared across projects)
# inside the tmux pane itself, right before exec'ing claude.
ENV_FILE="$HOME/.env"

tmux new-session -d -s "$NEW_SESSION" -c "$PROJECT_DIR" \
    bash -c "[ -f '$ENV_FILE' ] && { set -a; source '$ENV_FILE'; set +a; }; exec claude --remote-control --remote-control-session-name-prefix '${REMOTE_PREFIX}' --permission-mode auto"

# Give the TUI time to boot before typing into it. Bump BOOT_WAIT in
# claude-schedule.conf if the machine is slow and the prompt gets eaten.
sleep "$BOOT_WAIT"

tmux send-keys -t "$NEW_SESSION" "$PROMPT" Enter

# One Enter is often not enough to actually submit: a PROMPT starting with
# "/" opens claude's slash-command autocomplete dropdown, which eats the
# first Enter instead of submitting, and remote-control's first-run
# screens can eat a second one too — leaving $PROMPT sitting unsubmitted
# in the input box indefinitely. Keep resending Enter until the footer
# shows "esc to interrupt" (only appears once a turn is actually running),
# or give up after a few tries and log it so a stuck session is visible.
submitted=0
for attempt in 1 2 3 4 5 6; do
    sleep 1
    if tmux capture-pane -t "$NEW_SESSION" -p 2>/dev/null | grep -q "esc to interrupt"; then
        submitted=1
        break
    fi
    tmux send-keys -t "$NEW_SESSION" Enter
done

if [ "$submitted" = 1 ]; then
    log "started tmux session '$NEW_SESSION' (remote-control name '$REMOTE_PREFIX') with prompt: $PROMPT"
else
    log "WARNING: '$NEW_SESSION' still not showing signs of a running turn after $attempt attempts — prompt may be stuck unsubmitted: $PROMPT"
fi
