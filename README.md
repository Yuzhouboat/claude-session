# claude-session — scheduled Claude via tmux + cron

Runs `claude` in a detached tmux session on a cron schedule, so it's live
and waiting whenever you attach (locally or over SSH). This whole folder is
self-contained: clone the project, run `./setup.sh`, done.

> **These files are synced from
> [Yuzhouboat/claude-session](https://github.com/Yuzhouboat/claude-session).**
> Edit them there and run its `sync.sh` — changes made directly in a
> project's copy get overwritten on the next sync. The only project-owned
> files here are `claude-schedule.conf` and `claude-tmux.log`.
> Installed version: see `VERSION`.

## Files

- `start-claude.sh` — the wrapper cron calls. Auto-detects its own project
  directory (its parent folder). **The tmux session name and the Remote
  Control session name are deliberately different strings:**
  - **tmux session name** = `$TMUX_BASE-<timestamp>`, where `$TMUX_BASE`
    is the full absolute project path with `/` replaced by `-` (and the
    leading `-` trimmed). Fixed in the script, not configurable — this
    guarantees the tmux name can never collide with another project's,
    even one with the exact same folder name sitting somewhere else on
    disk.
  - **Remote Control session name** = `$HOST-$SESSION-<timestamp>`, where
    `$HOST` is this machine's hostname (fixed, not configurable) and
    `$SESSION` is the human-friendly label from `claude-schedule.conf`
    below. This is the name you'll actually recognize when connecting
    from another device.

  Every run: sweeps existing `$TMUX_BASE-*` tmux sessions and kills any
  that have been silent (no pane output) for `IDLE_MINUTES` or longer —
  a session still actively producing output is left running untouched,
  no matter how long it's been up. If any remaining `$TMUX_BASE-*`
  session is still in the middle of a turn (its footer shows
  `esc to interrupt`), this run is **skipped** so two runs never work on
  the same thing at once. Otherwise it starts a brand-new tmux session
  named `$TMUX_BASE-<timestamp>` (`HHMM-mmddyyyy`; a finished session
  waiting at the input box doesn't block this), waits for the TUI to
  boot, and types a starting prompt into it. Always launches
  `claude --remote-control --remote-control-session-name-prefix
  "$HOST-$SESSION-<timestamp>"`.
- `claude-schedule.conf` — this project's settings: `SESSION` (just the
  human-friendly part of the *Remote Control* session name — it has no
  effect on the tmux session name, which is always the path-based
  `$TMUX_BASE` above; the hostname is always prepended in front of
  `SESSION`, and each run appends a `-HHMM-mmddyyyy` timestamp after
  it), `PROMPT`, `BOOT_WAIT`,
  `IDLE_MINUTES`, `CRON_SCHEDULE`. Sourced by `start-claude.sh` (except
  `CRON_SCHEDULE`, which only `setup.sh` reads/writes — it just
  remembers what schedule *should* be installed). Hand-editable, but
  `setup.sh` is usually easier.
- `setup.sh` — checks tmux/claude/jq are installed, walks through each config
  setting one at a time (Enter keeps the current value), then
  installs/updates/removes the crontab entry to match, and offers to mark
  the project folder as trusted in Claude Code (see "Workspace trust"
  below). Safe to re-run any time. Run as `./setup.sh remove` to skip the wizard and just tear
  everything down (see "Quick remove" below).
- `claude-tmux.log` — created automatically; one line per run
  (started / killed idle / `skipped: ... still running a turn` /
  `ERROR: ... does not trust ...`). Git-ignored (via `.gitignore` in this
  folder) — it holds your hostname and prompts and changes every hour.
- `claude-schedule.conf.example` — starting point `setup.sh` copies to
  `claude-schedule.conf` the first time it runs in a project.
- `VERSION` — which `claude-session` release this copy is.

## Setting it up

One-time setup on the machine (needs your password, run it yourself):
```bash
sudo apt-get update && sudo apt-get install -y tmux
systemctl is-enabled cron   # should print "enabled"
```

From inside this folder:
```bash
./setup.sh
```
It walks through, in order:
1. **Remote Control session name** — shown as `[<hostname>-<folder-name>]`
   (auto) or `[<hostname>-<current-value>]` (pinned); the `<hostname>-`
   part is always prepended by `start-claude.sh` and isn't something you
   type in here — you're only ever setting `SESSION`, the part *after*
   the hostname. Each run also appends a `-HHMM-mmddyyyy` timestamp
   after that. **This does not affect the tmux session name** — that's
   always the path-based `$TMUX_BASE` (see Files above), fixed and not
   editable through setup.sh.
   - Press Enter to keep it as-is.
   - Type `auto` to un-pin it and go back to tracking the project folder's
     name (so it keeps up automatically if the folder is renamed later).
   - Type anything else to pin that exact value for `SESSION`.
2. **Starting prompt** typed into `claude` once it boots.
3. **Boot-wait seconds** — how long to wait after launching `claude` before
   typing the prompt. Raise this if the TUI is slow to boot and the prompt
   gets eaten.
4. **Idle minutes** — how long a `$TMUX_BASE-<timestamp>` tmux session's pane can go without
   producing any output before the *next* cron run kills it during its
   sweep. Doesn't affect whether a new session gets started — that always
   happens. A session still actively producing output is never touched,
   no matter how long it's been running.
5. **Cron schedule** — shown as `[current-schedule]` if one is already set,
   or `[none]` if not.
   - Press Enter to keep it as-is.
   - Type a new crontab schedule (e.g. `0 9 * * *`) to set/change it.
   - Type `none` to clear it (you'll then be asked whether to also remove
     the crontab line, if one exists).
6. **Workspace trust** — if Claude Code doesn't trust this project folder
   yet, asks `Mark it as trusted in ~/.claude.json? [y/N]`. Skipped
   silently if it's already trusted.

Every answer gets written back to `claude-schedule.conf` immediately, then
`setup.sh` adds, replaces, or removes the crontab entry for `start-claude.sh`
to match — it never touches unrelated crontab lines.

## Workspace trust

The first time `claude` opens a folder it asks "Do you trust this folder?",
with **No, exit** preselected. Trust is remembered per exact path in
`~/.claude.json` (`projects["<path>"].hasTrustDialogAccepted`) — trusting a
parent folder does not cover its subfolders. Under cron nobody answers that
dialog: `start-claude.sh`'s Enter lands on "No, exit" and the run dies.

So:
- `setup.sh` offers to set that flag for this project (the same thing the
  dialog's "Yes" does). Answer `y` once and cron runs never see the dialog.
- `start-claude.sh` checks the flag before launching. If the folder isn't
  trusted it logs `ERROR: Claude Code does not trust '<path>' ...` to
  `claude-tmux.log` and exits without starting a session.

**Moved or renamed the project?** The path changed, so both the crontab
line and the trust flag are stale. Re-run `./setup.sh` in the new location
— it updates the crontab entry and offers to trust the new path. (Or open
`claude` in the folder once and choose "Yes, I trust this folder", then fix
the crontab line.)

Common cron schedules:
```
0 9 * * *     # daily at 9am
0 9 * * 1-5   # weekdays 9am
0 */4 * * *   # every 4 hours
```

## Quick remove

To stop everything — the cron schedule and every currently running
`$TMUX_BASE-*` tmux session — without going through the wizard:
```bash
./setup.sh remove
```
It shows exactly what it's about to do (crontab line, list of matching
tmux sessions), asks for confirmation once, then removes the crontab entry
and kills all matching sessions. `claude-schedule.conf` is left untouched,
so running `./setup.sh` again later brings it back with the same settings.

## Using it in another project

From a clone of the `claude-session` repo:
```bash
./sync.sh /path/to/other-project   # copies the scripts into other-project/claude-session/
cd /path/to/other-project/claude-session && ./setup.sh
```
Then commit `claude-session/` (including your `claude-schedule.conf`) in
that project. `setup.sh` creates `claude-schedule.conf` from the example,
picks up the project's folder name for the auto session default, and walks
you through the rest, including trusting the new folder.

## Updating the scripts

Edit in the `claude-session` repo, bump `VERSION`, commit, then run
`./sync.sh` there. It copies the synced files into every project listed in
`sync-targets.local` (or the paths you pass it), never touches
`claude-schedule.conf`, and prints each project's `git diff` — review and
commit in each project yourself.

## Using it day to day

Each run creates a new `$TMUX_BASE-<timestamp>` tmux session — use `tmux ls`
to see which ones are currently up before attaching to one. `$TMUX_BASE`
is printed by `setup.sh` (and logged in `claude-tmux.log`); it's the full
absolute project path with `/` replaced by `-`, e.g.
`home-yuzhou-Projects-orim-data-airflow-dags`.

- Check in / drive it live:
  ```bash
  tmux ls | grep '^home-yuzhou-Projects-orim-data-airflow-dags-'   # find the current session name(s)
  tmux attach -t <session-name>
  ```
  Detach without killing it: `Ctrl-b` then `d`.

- Peek without attaching:
  ```bash
  tmux capture-pane -t <session-name> -p
  ```

- See run history (starts, kills, sweeps):
  ```bash
  cat claude-tmux.log
  ```

- Test the script by hand before trusting it to cron:
  ```bash
  ./start-claude.sh
  tmux ls | grep '^home-yuzhou-Projects-orim-data-airflow-dags-'
  tmux attach -t <session-name>
  ```

## Managing tmux sessions

**Checking what's running:**
```bash
tmux ls                        # list all sessions (name, windows, size, dates)
tmux ls | grep '^home-yuzhou-Projects-orim-data-airflow-dags-'   # just this project's sessions
tmux has-session -t <session-name>; echo $?   # 0 = exists, 1 = doesn't
```

**Attaching / detaching:**
```bash
tmux attach -t <session-name>     # or: tmux a -t <session-name>
```
Inside a session, everything starts with the prefix `Ctrl-b`, then a key:
| Keys | Effect |
|---|---|
| `Ctrl-b d` | detach (session keeps running in the background) |
| `Ctrl-b $` | rename the current session |
| `Ctrl-b [` | enter scroll/copy mode (arrow keys or `PgUp` to scroll, `q` to exit) |
| `Ctrl-b c` | new window in this session |
| `Ctrl-b n` / `Ctrl-b p` | next / previous window |
| `Ctrl-b w` | interactive window picker |

**Ending a session:**
```bash
tmux kill-session -t <session-name>   # kill just this one
tmux kill-server                      # kill tmux entirely (all sessions)
```
Or from inside the session: exit `claude` normally, then `exit` the shell —
tmux closes the pane/session once nothing is left running in it.

**A few can coexist** — a cron run starts a new `$TMUX_BASE-<timestamp>`
whenever no existing one is mid-turn, and finished ones only get swept once
idle past `IDLE_MINUTES` on a *later* run. If several are genuinely stuck/unwanted before that:
```bash
tmux ls | grep '^home-yuzhou-Projects-orim-data-airflow-dags-'   # see what's there
tmux kill-session -t <name>                             # clean up the ones you don't need
```
Or `./setup.sh remove` to kill all of this project's sessions at once.

## Notes

- If your machine is off/asleep at the scheduled minute, plain cron just
  skips that run — it doesn't run it late. Add an `@reboot` cron line too
  (by hand, via `crontab -e`) if you also want a run every time the machine
  starts up.
- A reboot kills the tmux session (expected) but not the crontab entry —
  the next scheduled run starts a fresh session normally.
- Real conversation history lives in Claude Code's own transcripts
  (`~/.claude/projects/...`, resumable with `claude --resume`), not in
  tmux — tmux is just the live window into it.
