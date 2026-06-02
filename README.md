# cctrl

A CLI for managing [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions, profiles, costs, and developer environment. Built for power users who run multiple projects, track token spend, and sometimes SSH into their Mac to kick off sessions remotely.

## What it does

- **Profile switching** — swap between settings configs (API keys, models, hooks, permissions) with one command
- **Session launching** — start Claude Code with consistent flags, resume previous sessions, jump into projects via named shortcuts, or run detached so it survives SSH disconnect
- **Remote hosts** — run any cctrl command on another machine over SSH; spawn a detached session on your Mac from your phone and auto-attach
- **Usage & cost tracking** — token spend by model/project/day, rate limit monitoring, billing week breakdowns
- **Port management** — track port history, find free ports, kill processes by port, discover ports from project files
- **Chrome CDP** — launch Chrome with remote debugging for browser automation workflows
- **Claude Code hooks** — smart sound notifications, commit guardrails, statusline, and session logging

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/aberhamm/cctrl/main/install.sh | bash
```

This clones the repo, symlinks the binary to `~/.local/bin`, adds it to your PATH, and sets up zsh completions. Re-run to update.

Or manually:

```bash
git clone https://github.com/aberhamm/cctrl.git ~/.local/share/cctrl
ln -s ~/.local/share/cctrl/cctrl ~/.local/bin/cctrl
```

## Profiles

Each profile is a complete `~/.claude/settings.json` snapshot stored in `profiles/`. Swap between different API keys, models, hooks, or permission sets.

```bash
cctrl ls                  # list profiles (* = active)
cctrl use <profile>       # switch to a profile
cctrl current             # show active profile + drift detection
cctrl save <name>         # snapshot current settings as a new profile
cctrl diff <profile>      # diff current settings vs a profile
cctrl rename <old> <new>  # rename a profile
cctrl edit <profile>      # open in $EDITOR
```

## Sessions

A launch is described by three independent axes:

| Axis | Question | How you set it |
| --- | --- | --- |
| **Location** | which machine runs it? | `--host <alias>` (default: local) |
| **Durability** | does it survive disconnect? | `-d` / `--detach` (default: foreground) |
| **Bridge** | can the phone app drive it? | on by default; `--no-bridge` to disable |

There's **one launch verb — `start`** — and the flags above pick the behavior. Managing detached sessions (list/attach/kill) lives under `cctrl session`.

```bash
cctrl start                       # foreground, current dir, phone bridge on
cctrl start --resume              # resume a session (interactive picker)
cctrl start -p "fix bug"          # extra flags passed through to claude
cctrl start --no-bridge           # launch without the phone-control bridge
```

`cctrl start` launches `claude` with the phone-control bridge and a session name prefix based on the current git repo. Multiple sessions in the same folder get unique suffixes (e.g. `cctrl-graceful-unicorn`), replaced by an AI-generated summary within seconds.

### Detached sessions

Add `-d` to run inside a detached **tmux** session that persists after SSH disconnect — reattach anytime from any terminal. No GUI, no iTerm2, no AppleScript. A detached launch requires an explicit target (a dir or `@shortcut`); defaulting to `$HOME` would drop bypass-permissions Claude into `~/.ssh`, `~/.aws`, etc.

```bash
cctrl start -d ~/_projects/myapp  # launch detached in a directory
cctrl start -d @myapp             # ...or via a saved shortcut

cctrl session ls                  # list detached sessions
cctrl session attach myapp        # reattach (interactive picker if no name)
cctrl session kill myapp          # kill a session
```

**Requires:** tmux (`brew install tmux`)

### Shortcuts

Named jump targets — cd into a directory, optionally switch profile, and launch claude in one command.

```bash
cctrl @<name>                # cd + switch profile + start
cctrl @<name> -m "fix bug"  # with an initial prompt
cctrl @<name> --resume       # resume picker for that project
cctrl @                      # list shortcuts

cctrl @add myapp ~/projects/myapp --profile work
cctrl @rm myapp
```

## Remote Hosts

Run any cctrl command on a named remote host over SSH. The `--host` flag transparently forwards the command — no manual SSH required.

```bash
cctrl host add studio ms-128g-bln         # register a host
cctrl host add studio ms-128g-bln matt    # with explicit user
cctrl host list                            # show registered hosts
cctrl host rm studio                       # remove a host
cctrl host doctor studio                   # check SSH, brew, tmux, claude, cctrl
```

`--host` is orthogonal — it forwards *any* command, so the three axes compose. `--host` says **where**, `-d` says **durable**:

```bash
cctrl --host studio start -d @homelab        # spawn a detached session there, then auto-attach
cctrl --host studio session ls               # list remote detached sessions
cctrl --host studio session attach homelab   # attach interactively (TTY)
cctrl --host studio costs --week             # view remote cost data
```

`cctrl --host studio start -d @homelab` is the "spawn on my Mac from my phone" workflow: it SSHes in, starts the detached session, then attaches to that exact session over a second connection. The remote prints its resolved session name so the attach targets the right one even with auto-increment suffixes.

**TTY handling:** Interactive commands (`start` foreground, `start -d` auto-attach, `@shortcut`, `session attach`, `edit`) use `ssh -t`. Non-interactive commands (`session ls`, `costs`, `usage`, `ls`) use plain `ssh`.

**Host doctor** checks SSH connectivity, brew, tmux, claude, cctrl availability, and `~/.tmux.conf` on the remote host — with interactive auto-fix offers for missing dependencies.

The host registry lives in `data/hosts.json` (gitignored, machine-local). Each machine is its own source of truth — no sync.

## Usage & cost tracking

```bash
cctrl usage               # rate limits + billing week breakdown
cctrl usage 4             # show 4 billing weeks (default: 2)
cctrl costs --today       # token spend: daily, by model, by project
cctrl costs --week        # (default)
cctrl costs --month
cctrl costs --all django  # filter by project name
cctrl log                 # per-session log tagged with profile
```

`cctrl usage` shows Claude subscription rate limits (5-hour and 7-day windows) plus token spend per billing week (resets Tuesday 4pm ET). Peak rate limit usage is tracked per week.

`cctrl costs` parses session JSONLs from `~/.claude/projects/` for detailed token breakdowns (input, output, cache write, cache read) with estimated USD. No external API calls.

### How tracking works

1. A `Stop` hook runs `hooks/session-log.py` after each assistant turn, summing deduplicated token usage per session
2. A statusline script (`hooks/statusline.sh`) captures rate limit data from Claude Code on each update
3. `cctrl usage` and `cctrl costs` read these logs for aggregate reporting

## Hooks

Included hooks for Claude Code's hook system. Configure them in your `settings.json` or in a cctrl profile.

### notify.sh — smart sound notifications

Plays different sounds based on what Claude is doing:

- **Ping** — Claude finished (no action needed)
- **Glass** — Claude asked you a question (needs input)
- **Tink** — a permission prompt is waiting

Distinguishes "done" from "needs input" by parsing the session transcript and checking whether the last message ends with a question. No arbitrary delays — all notifications are instant.

```json
{
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "/path/to/cctrl/hooks/notify.sh stop"}]}],
    "Notification": [{"hooks": [{"type": "command", "command": "/path/to/cctrl/hooks/notify.sh notification"}]}]
  }
}
```

### block-git-commit.py — commit guardrail

A `PreToolUse` hook that blocks Claude from creating git commits without explicit user approval. Catches `git commit`, `git revert`, `git cherry-pick`, and variants through `eval`/subshell.

```json
{
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 /path/to/cctrl/hooks/block-git-commit.py"}]}]
  }
}
```

### statusline.sh — context bar + rate limit capture

Displays model, project name, and token count in the Claude Code status bar. Also captures rate limit snapshots to `data/` for `cctrl usage` reporting.

### session-log.py — token tracking

Finds the current session JSONL, sums deduplicated token usage, and upserts to the spending log. Called automatically by the `Stop` hook.

## Port management

Track which ports have ever been in use on your machine and get clean suggestions. History accumulates across invocations.

```bash
cctrl ports                        # live scan + suggest free ports
cctrl ports --consecutive 4        # find 4 consecutive free ports
cctrl ports --check 3000,5432      # check if ports are safe to use
cctrl ports --kill 3000-3003       # kill processes on ports (SIGTERM)
cctrl ports --kill 3000 --force    # SIGKILL
cctrl ports --discover ~/projects  # scan project files for port references
cctrl ports --history              # all ports ever seen
cctrl ports --known                # well-known exclusions (MySQL, Redis, etc.)
```

Example output:

```
$ cctrl ports

Port     Process              PID
────────────────────────────────────────
443      Wispr                2052
3000     node                 26975
3001     node                 6197
6379     com.docke            58241
────────────────────────────────────────
4 listening ports · 88 total ever seen

Free ports (never seen, 3000–9999)
────────────────────────────────────────
  3004  3005  3006  3007  3008  3009  3010
```

Port discovery scans `.env`, `Dockerfile`, `docker-compose.yml`, YAML/TOML configs, and source files for port references — then adds them to history so they're never suggested. 22 well-known service ports (PostgreSQL, Redis, MySQL, etc.) are always excluded.

## Chrome CDP

Launch Chrome with Chrome DevTools Protocol enabled for browser automation.

```bash
cctrl chrome                    # kill Chrome, relaunch with CDP on :9222
cctrl chrome --status           # check if CDP is active
cctrl chrome --port 9333        # use a different port
cctrl chrome --kill             # kill Chrome without relaunching
```

## Extending

Drop any executable named `cctrl-<cmd>` in `plugins/` or anywhere in `$PATH`:

```bash
# plugins/cctrl-backup → cctrl backup
```

## Structure

```
cctrl/
  cctrl                    # main script
  profiles/*.json          # named settings configs (gitignored)
  hooks/
    notify.sh              # sound notifications (stop/needs-input/permission)
    block-git-commit.py    # commit guardrail hook
    session-log.py         # token tracking hook
    statusline.sh          # status bar + rate limit capture
  completions/_cctrl       # zsh tab completion
  costs/                   # session spending log (gitignored)
  data/                    # runtime data (gitignored)
  plugins/                 # drop-in subcommands
```

## License

MIT
