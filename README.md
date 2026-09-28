# claude-session — scheduled Claude via tmux + cron

Runs an interactive `claude` session in a detached tmux session on a cron
schedule, types a starting prompt into it, and leaves it live so you can
attach (locally, over SSH, or through Remote Control) whenever you like.

A project only commits a tiny bootstrap. Running it fetches the latest
scripts from this repo and sets everything up.

## Adding it to a project

From inside the project:

**Shared with the repo** — commit it, and everyone who clones the project
just runs `./claude-session/setup.sh`:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Yuzhouboat/claude-session/main/install.sh)
git add claude-session && git commit -m "Add scheduled Claude session"
```

**Local only** — for a repo you've cloned but don't want to add this to.
`claude-session/` is hidden through that clone's `.git/info/exclude`, so it
never shows in `git status` and can't be committed by accident:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Yuzhouboat/claude-session/main/install.sh) --local
```
Refused if the repo already tracks a `claude-session/` folder. To
uninstall: `./claude-session/setup.sh remove && rm -rf claude-session`,
then delete the `/claude-session/` line from `.git/info/exclude`.

Both forms take an optional project path (default: the git repo you're
in), and work the same from a clone of this repo: `./install.sh [--local]
[project-dir]`. Either way the installer then runs setup (below).

## What lives where

In the project (committed in shared mode; hidden via `.git/info/exclude`
in local mode):
```
claude-session/
  setup.sh               bootstrap: fetch latest scripts, then run their setup
  claude-schedule.conf   this project's settings (written by setup)
  .gitignore             ignores .upstream/ and claude-tmux.log
```

On each machine (never committed):
```
claude-session/
  .upstream/             checkout of this repo (the real scripts)
  claude-tmux.log        one line per scheduled run
```

This repo:
- `install.sh` — adds `claude-session/` to a project (shared or `--local`)
  and runs setup.
- `bootstrap/setup.sh`, `bootstrap/.gitignore` — the files a project keeps.
- `setup.sh` — the real setup, run from `.upstream/` by the bootstrap.
- `start-claude.sh` — what cron runs.
- `claude-schedule.conf.example` — starting point for a new project's
  `claude-schedule.conf`.
- `VERSION` — printed by setup.

## Running setup

One-time machine prerequisites:
```bash
sudo apt-get update && sudo apt-get install -y git tmux jq
systemctl is-enabled cron   # should print "enabled"
```
Plus Claude Code itself (`claude` on your `PATH`, logged in — Remote
Control needs a claude.ai login).

Then, in the project:
```bash
./claude-session/setup.sh
```
1. **Fetches the latest scripts** into `claude-session/.upstream/` (clones
   the first time, resets to the latest `main` after that). If GitHub is
   unreachable it carries on with the copy it already has.
2. **Checks dependencies** (tmux, claude, jq).
3. **Walks through each setting** — press Enter to keep the current value:
   - **Remote Control session name** — the part after `<hostname>-`; `auto`
     tracks the project folder name.
   - **Starting prompt** typed into `claude` once it boots.
   - **Boot-wait seconds** before typing the prompt (raise it if the prompt
     gets eaten).
   - **Idle minutes** before an old, silent session is killed by a later
     run's cleanup.
   - **Cron schedule**, e.g. `0 9 * * *`; `none` removes it.
4. **Writes `claude-schedule.conf`** and adds/updates/removes the crontab
   line for `claude-session/.upstream/start-claude.sh` (never touches other
   crontab lines). A line left over from the old layout
   (`claude-session/start-claude.sh`) is migrated automatically.
5. **Workspace trust** — offers to mark the project folder as trusted in
   Claude Code (see below).

Common cron schedules:
```
0 9 * * *     # daily at 9am
0 9 * * 1-5   # weekdays 9am
0 */4 * * *   # every 4 hours
```

## Updating

Re-run `./claude-session/setup.sh`: it pulls the latest scripts, then lets
you press Enter through the settings. Cron keeps running whatever was
fetched last, so a machine only picks up a new version when setup is
re-run there.

To change the scripts, edit this repo and push to `main` — there's nothing
to copy into projects.

The bootstrap itself (`bootstrap/setup.sh`, `bootstrap/.gitignore`) is the
one piece projects keep a copy of. It rarely changes; when it does, re-run
`install.sh` (with `--local` for local installs) in each project to refresh
it, and commit the result in shared projects.

## Quick remove

```bash
./claude-session/setup.sh remove
```
Shows the crontab line and this project's tmux sessions, asks once, then
removes them. `claude-schedule.conf` is left alone, so running setup again
brings it back with the same settings.

## What each scheduled run does

`start-claude.sh`:
1. **Cleans up** this project's tmux sessions that have produced no output
   for `IDLE_MINUTES`. Sessions still producing output are left alone.
2. **Skips the run** if one of this project's sessions is still in the
   middle of a turn (footer shows `esc to interrupt`), so two runs never
   work on the same thing. A finished session waiting at the input box
   doesn't block.
3. **Refuses to launch** if Claude Code doesn't trust the project folder
   (logs an `ERROR` line instead of dying silently at the trust dialog).
4. **Starts a new tmux session** that loads `~/.env` (cron doesn't inherit
   your shell's exports) and runs
   `claude --remote-control --permission-mode auto`.
5. **Types the prompt**, pressing Enter until the turn is actually running.
6. **Logs** the outcome to `claude-tmux.log`.

### Log lines

| Line starts with | Meaning |
|---|---|
| `started tmux session …` | Run launched and the prompt is running |
| `killed idle session …` | Cleanup removed an old, silent session |
| `skipped: previous session … still running a turn` | Previous run still busy; this run did nothing |
| `ERROR: Claude Code does not trust …` | Project folder not trusted — re-run setup |
| `ERROR: claude exited during startup …` | `claude` quit right away (PATH, login, …) — run `start-claude.sh` by hand to see why |
| `WARNING: … prompt may be stuck unsubmitted` | Session is up but the prompt never started; attach and check |

### Session names

- **tmux session** = `$TMUX_BASE-<HHMM-mmddyyyy>`, where `$TMUX_BASE` is
  the project's absolute path with `/` replaced by `-` — e.g.
  `home-me-Projects-my-project`. Fixed, so it can't collide with another
  project.
- **Remote Control session** = `<hostname>-<SESSION>-<HHMM-mmddyyyy>`,
  where `SESSION` comes from `claude-schedule.conf`. This is the name you'll
  see when connecting from another device.

## Workspace trust

The first time `claude` opens a folder it asks "Do you trust this folder?",
with **No, exit** preselected. Trust is remembered per exact path in
`~/.claude.json` (`projects["<path>"].hasTrustDialogAccepted`) — trusting a
parent folder does not cover its subfolders. Under cron nobody answers, so
the run dies. Hence:
- setup offers to set that flag for the project (what the dialog's "Yes"
  does);
- `start-claude.sh` checks it before launching and logs
  `ERROR: Claude Code does not trust '<path>' ...` if it's missing.

**Moved or renamed the project?** The path changed, so the crontab line
and the trust flag are stale. Re-run `./claude-session/setup.sh` in the new
location.

## Using it day to day

```bash
tmux ls | grep '^home-me-Projects-my-project-'   # this project's sessions
tmux attach -t <session-name>                    # drive it live; Ctrl-b d detaches
tmux capture-pane -t <session-name> -p           # peek without attaching
cat claude-session/claude-tmux.log               # run history
./claude-session/.upstream/start-claude.sh       # trigger a run by hand
```

| Keys (inside tmux) | Effect |
|---|---|
| `Ctrl-b d` | detach (session keeps running) |
| `Ctrl-b [` | scroll mode (`q` to exit) |

Don't rename these sessions: cleanup and the busy check find them by name.

End a session with `tmux kill-session -t <name>`, or
`./claude-session/setup.sh remove` to stop everything for the project.

## Notes

- If the machine is off or asleep at the scheduled minute, cron skips that
  run. Add an `@reboot` line by hand (`crontab -e`) if you also want a run
  at startup.
- A reboot kills the tmux sessions but not the crontab line; the next
  scheduled run starts fresh.
- Conversation history lives in Claude Code's own transcripts
  (`~/.claude/projects/...`, resumable with `claude --resume`); tmux is
  just the live window into it.
