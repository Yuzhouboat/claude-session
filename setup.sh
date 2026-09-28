#!/usr/bin/env bash
# The real setup for a project's scheduled Claude session:
#   1. check dependencies (tmux, claude, jq)
#   2. walk through each claude-schedule.conf setting (Enter keeps it)
#   3. write claude-schedule.conf
#   4. add/replace/remove this project's crontab line for start-claude.sh
#   5. offer to mark the project folder as trusted in Claude Code
# `remove` instead tears down the crontab line and this project's tmux
# sessions. Safe to re-run any time. See README.md.
#
# Not run directly: the project's claude-session/setup.sh (the bootstrap)
# fetches this repo into claude-session/.upstream/ and execs this script
# from there. Project-owned files (claude-schedule.conf, claude-tmux.log)
# live one level up, in <project>/claude-session/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(basename "$SCRIPT_DIR")" != ".upstream" ]; then
    echo "Run this through a project's claude-session/setup.sh (see README.md),"
    echo "not from the claude-session repo itself."
    exit 1
fi
SESSION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(cd "$SESSION_DIR/.." && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/start-claude.sh"
CONFIG_FILE="$SESSION_DIR/claude-schedule.conf"
# Where start-claude.sh lived before the bootstrap layout (claude-session
# 1.x committed full copies into each project). A crontab line pointing
# there is ours too, and gets migrated to SCRIPT_PATH.
LEGACY_SCRIPT_PATH="$SESSION_DIR/start-claude.sh"
TMUX_BASE="$(printf '%s' "$PROJECT_DIR" | tr '/' '-' | sed 's/^-//')"

# This project's crontab line(s), current or legacy path.
our_cron_lines() {
    crontab -l 2>/dev/null | grep -F -e "$SCRIPT_PATH" -e "$LEGACY_SCRIPT_PATH" || true
}
# The crontab minus this project's line(s).
other_cron_lines() {
    crontab -l 2>/dev/null | grep -Fv -e "$SCRIPT_PATH" -e "$LEGACY_SCRIPT_PATH" || true
}

# --- Quick remove: `setup.sh remove` tears down the crontab line and this
# project's tmux sessions without the wizard. claude-schedule.conf is left
# alone, so running setup again later brings it back as it was.
if [ "${1:-}" = "remove" ] || [ "${1:-}" = "--remove" ]; then
    existing="$(our_cron_lines)"

    matching_sessions=()
    if command -v tmux >/dev/null 2>&1; then
        while IFS= read -r s; do
            [ -z "$s" ] && continue
            case "$s" in
                "${TMUX_BASE}-"*) matching_sessions+=("$s") ;;
            esac
        done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
    fi

    if [ -z "$existing" ] && [ "${#matching_sessions[@]}" -eq 0 ]; then
        echo "Nothing to remove: no crontab entry and no running '$TMUX_BASE-*' sessions."
        exit 0
    fi

    echo "This will:"
    if [ -n "$existing" ]; then
        echo "  - remove crontab entry: $existing"
    else
        echo "  - (no crontab entry found for this script)"
    fi
    if [ "${#matching_sessions[@]}" -gt 0 ]; then
        echo "  - kill tmux session(s): ${matching_sessions[*]}"
    else
        echo "  - (no running '$TMUX_BASE-*' sessions)"
    fi
    echo
    read -rp "Proceed? [y/N] " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi

    if [ -n "$existing" ]; then
        other_cron_lines | crontab -
        echo "Removed crontab entry."
    fi
    for s in "${matching_sessions[@]}"; do
        tmux kill-session -t "$s"
        echo "Killed tmux session '$s'."
    done
    echo
    echo "Done. claude-schedule.conf is untouched — run claude-session/setup.sh again any time to re-enable."
    exit 0
fi

echo "Setting up scheduled Claude for: $PROJECT_DIR"
echo "claude-session version: $(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo unknown)"
echo

# --- Sanity check ------------------------------------------------------------
if [ ! -f "$SCRIPT_PATH" ]; then
    echo "Missing: $SCRIPT_PATH — the fetched copy in .upstream/ looks incomplete."
    echo "Delete $SCRIPT_DIR and run claude-session/setup.sh again to re-fetch it."
    exit 1
fi
# First setup in a project: start from the example (the wizard below
# rewrites it with this project's answers anyway).
if [ ! -f "$CONFIG_FILE" ]; then
    cp "$SCRIPT_DIR/claude-schedule.conf.example" "$CONFIG_FILE"
    echo "Created $CONFIG_FILE for this project."
    echo
fi

# --- Dependency check --------------------------------------------------
missing=()
command -v tmux >/dev/null 2>&1 || missing+=(tmux)
command -v claude >/dev/null 2>&1 || missing+=(claude)
command -v jq >/dev/null 2>&1 || missing+=(jq)
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing on this machine: ${missing[*]}"
    if [[ " ${missing[*]} " == *" tmux "* ]]; then
        echo "  Install tmux:   sudo apt-get update && sudo apt-get install -y tmux"
    fi
    if [[ " ${missing[*]} " == *" jq "* ]]; then
        echo "  Install jq:     sudo apt-get update && sudo apt-get install -y jq"
    fi
    if [[ " ${missing[*]} " == *" claude "* ]]; then
        echo "  Install claude: https://docs.claude.com/claude-code"
    fi
    echo
    read -rp "Continue anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 1
    echo
fi

# --- Load current settings (same defaults + sourcing order as start-claude.sh) --
HOST="$(hostname -s 2>/dev/null || hostname)"
SESSION_AUTO_DEFAULT="$(basename "$PROJECT_DIR")"
SESSION="$SESSION_AUTO_DEFAULT"
PROMPT="hello"
BOOT_WAIT=5
IDLE_MINUTES=30
CRON_SCHEDULE=""
# Whether claude-schedule.conf pins SESSION itself vs. leaving it to the
# auto default, checked before sourcing (sourcing can't tell us that).
if grep -Eq '^[[:space:]]*SESSION=' "$CONFIG_FILE"; then
    session_pinned=1
else
    session_pinned=0
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# --- Review / update each setting, one at a time ---------------------------
echo "Review settings for this project — press Enter to keep each default:"
echo

echo "(The tmux session name itself is always '$TMUX_BASE-<timestamp>' —"
echo " this project's full path with \"/\" replaced by \"-\", so it can never"
echo " collide with another project. Not editable. SESSION below only"
echo " controls the Remote Control session name.)"
if [ "$session_pinned" = 1 ]; then
    read -rp "Remote Control session name [${HOST}-$SESSION] (hostname '$HOST-' is always prepended, not editable here; each run appends a timestamp; or 'auto' to track the folder name): " new_session
else
    read -rp "Remote Control session name [auto: ${HOST}-$SESSION] (hostname '$HOST-' is always prepended, not editable here; each run appends a timestamp): " new_session
fi
if [ -n "$new_session" ]; then
    if [ "${new_session,,}" = "auto" ]; then
        session_pinned=0
        SESSION="$SESSION_AUTO_DEFAULT"
    else
        session_pinned=1
        SESSION="$new_session"
    fi
fi
REMOTE_BASE="${HOST}-${SESSION}"

read -rp "Starting prompt to type into claude [$PROMPT]: " new_prompt
[ -n "$new_prompt" ] && PROMPT="$new_prompt"

read -rp "Seconds to wait for claude to boot [$BOOT_WAIT]: " new_boot_wait
[ -n "$new_boot_wait" ] && BOOT_WAIT="$new_boot_wait"

read -rp "Minutes of no pane output before an existing '$TMUX_BASE-<timestamp>' session is treated as idle and killed [$IDLE_MINUTES]: " new_idle_minutes
[ -n "$new_idle_minutes" ] && IDLE_MINUTES="$new_idle_minutes"

echo
echo "Cron schedule examples:"
echo "  0 9 * * *      daily at 9am"
echo "  0 9 * * 1-5    weekdays at 9am"
echo "  0 */4 * * *    every 4 hours"
cron_cleared=0
if [ -n "$CRON_SCHEDULE" ]; then
    read -rp "Cron schedule [$CRON_SCHEDULE] (or 'none' to remove it): " new_cron
    if [ -n "$new_cron" ]; then
        if [ "${new_cron,,}" = "none" ]; then
            CRON_SCHEDULE=""
            cron_cleared=1
        else
            CRON_SCHEDULE="$new_cron"
        fi
    fi
else
    read -rp "Cron schedule to install [none] (blank = skip): " new_cron
    [ -n "$new_cron" ] && CRON_SCHEDULE="$new_cron"
fi
echo

# --- Write the settings back out --------------------------------------------
# Same layout and wording as claude-schedule.conf.example.
{
    echo "# Settings for this project's scheduled Claude session."
    echo "# Edit freely, or run claude-session/setup.sh to be walked through"
    echo "# each one (it rewrites this file)."
    echo
    echo "# Human-friendly part of the Remote Control session name"
    echo "# (\"<hostname>-<SESSION>-<timestamp>\"). Commented out = use the"
    echo "# project folder name. Does not affect the tmux session name, which is"
    echo "# always the project path with \"/\" replaced by \"-\" ($TMUX_BASE)."
    if [ "$session_pinned" = 1 ]; then
        echo "SESSION=\"$SESSION\""
    else
        echo "# SESSION=\"$SESSION\""
    fi
    echo
    echo "# Text typed into the claude session once it boots."
    echo "PROMPT=\"$PROMPT\""
    echo
    echo "# Seconds to wait after launching claude before typing PROMPT."
    echo "# Raise this if the prompt gets eaten while claude is still booting."
    echo "BOOT_WAIT=$BOOT_WAIT"
    echo
    echo "# Minutes of no pane output before an old session from this project"
    echo "# is killed by a later run's cleanup. Sessions still producing output"
    echo "# are never killed."
    echo "IDLE_MINUTES=$IDLE_MINUTES"
    echo
    echo "# Cron schedule (crontab syntax). setup installs/updates the crontab"
    echo "# line from this; editing it here alone doesn't change the crontab."
    if [ -n "$CRON_SCHEDULE" ]; then
        echo "CRON_SCHEDULE=\"$CRON_SCHEDULE\""
    else
        echo "# CRON_SCHEDULE=\"0 9 * * *\""
    fi
} > "$CONFIG_FILE"
echo "Wrote $CONFIG_FILE:"
echo "  SESSION       = $SESSION $([ "$session_pinned" = 1 ] || echo '(auto)')  ->  Remote Control base: $REMOTE_BASE"
echo "  tmux session base (fixed, path-based): $TMUX_BASE"
echo "  PROMPT        = $PROMPT"
echo "  BOOT_WAIT     = $BOOT_WAIT"
echo "  IDLE_MINUTES  = $IDLE_MINUTES"
echo "  CRON_SCHEDULE = ${CRON_SCHEDULE:-<none>}"
echo

# --- Apply the cron schedule -----------------------------------------------
existing="$(our_cron_lines)"

if [ -n "$CRON_SCHEDULE" ]; then
    CRON_LINE="$CRON_SCHEDULE $SCRIPT_PATH"
    if [ "$existing" = "$CRON_LINE" ]; then
        echo "Crontab already has this exact entry — nothing to do."
    elif [ -n "$existing" ] && ! printf '%s\n' "$existing" | grep -qF "$SCRIPT_PATH"; then
        # Only legacy-path line(s): that script no longer exists, so moving
        # the entry to the new path is the only sensible choice — no prompt.
        (other_cron_lines; echo "$CRON_LINE") | crontab -
        echo "Migrated crontab entry to the new script path:"
        echo "  was: $existing"
        echo "  now: $CRON_LINE"
    elif [ -n "$existing" ]; then
        echo "Existing crontab entry for this script:"
        echo "  $existing"
        echo "Replace it with:"
        echo "  $CRON_LINE"
        read -rp "Replace it? [y/N] " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            (other_cron_lines; echo "$CRON_LINE") | crontab -
            echo "Replaced crontab entry."
        else
            echo "Left existing entry unchanged."
        fi
    else
        echo "About to add this crontab entry:"
        echo "  $CRON_LINE"
        read -rp "Add it now? [y/N] " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            # `crontab -l` fails when there's no crontab yet (fresh machine).
            (crontab -l 2>/dev/null || true; echo "$CRON_LINE") | crontab -
            echo "Added to crontab."
        else
            echo "Skipped. Add it later with: crontab -e"
            echo "  $CRON_LINE"
        fi
    fi
elif [ -n "$existing" ]; then
    echo "Existing crontab entry for this script:"
    echo "  $existing"
    if [ "$cron_cleared" = 1 ]; then
        read -rp "Remove it from crontab too? [y/N] " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            other_cron_lines | crontab -
            echo "Removed from crontab."
        else
            echo "Left it in crontab, even though claude-schedule.conf no longer tracks a schedule."
        fi
    else
        echo "(claude-schedule.conf has no CRON_SCHEDULE set, but this crontab line runs anyway.)"
    fi
fi

# --- Workspace trust ---------------------------------------------------------
# Claude Code shows a "Do you trust this folder?" dialog the first time it
# opens a directory, keyed by exact path in ~/.claude.json. Under cron,
# start-claude.sh's Enter lands on the default "No, exit", so an untrusted
# (e.g. newly moved) project silently never runs. Record trust here, once,
# with your explicit OK — the same flag the dialog's "Yes" writes.
CLAUDE_JSON="$HOME/.claude.json"
echo
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not installed — skipping workspace trust. Open claude in $PROJECT_DIR"
    echo "once and choose \"Yes, I trust this folder\" before cron runs it."
elif [ -f "$CLAUDE_JSON" ] && [ "$(jq --arg p "$PROJECT_DIR" '.projects[$p].hasTrustDialogAccepted // false' "$CLAUDE_JSON")" = "true" ]; then
    echo "Claude Code already trusts $PROJECT_DIR."
else
    echo "Claude Code has not trusted $PROJECT_DIR yet; the cron-launched"
    echo "session would stop at the trust dialog and exit."
    read -rp "Mark it as trusted in $CLAUDE_JSON? [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        [ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"
        tmp="$(mktemp "$CLAUDE_JSON.XXXXXX")"
        if jq --arg p "$PROJECT_DIR" '.projects[$p].hasTrustDialogAccepted = true' "$CLAUDE_JSON" > "$tmp"; then
            chmod 600 "$tmp"
            mv "$tmp" "$CLAUDE_JSON"
            echo "Trusted."
        else
            rm -f "$tmp"
            echo "Failed to update $CLAUDE_JSON — open claude in $PROJECT_DIR once and trust it by hand."
        fi
    else
        echo "Skipped. start-claude.sh will log an error and not launch until it's trusted."
    fi
fi

echo
echo "Setup complete."
echo
echo "Test it by hand:"
echo "  $SCRIPT_PATH"
echo "  tmux ls | grep '^$TMUX_BASE-'   # find the session start-claude.sh just created"
echo
echo "Log file: $SESSION_DIR/claude-tmux.log"
