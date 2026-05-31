# cctrl

A CLI for managing [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions, profiles, costs, and developer environment. Built for power users who run multiple projects, track token spend, and sometimes SSH into their Mac to kick off sessions remotely.

## What it does

- **Profile switching** — swap between settings configs (API keys, models, hooks, permissions) with one command
- **Session launching** — start Claude Code with consistent flags, resume previous sessions, jump into projects via named shortcuts
- **Remote spawning** — SSH into your Mac and launch a Claude Code session in a new iTerm2 window that persists after you disconnect
- **Usage & cost tracking** — token spend by model/project/day, rate limit monitoring, billing week breakdowns
- **Port management** — track port history, find free ports, kill processes by port, discover ports from project files
- **Chrome CDP** — launch Chrome with remote debugging for browser automation workflows
- **Claude Code hooks** — smart sound notifications, commit guardrails, statusline, and session logging

## Install

```bash
git clone https://github.com/aberhamm/cctrl.git
ln -s "$(pwd)/cctrl/cctrl" ~/.local/bin/cctrl
```

Optional: add zsh completions:

```bash
# Add to your .zshrc (adjust path as needed)
fpath=(~/path/to/cctrl/completions $fpath)
autoload -Uz compinit && compinit
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

```bash
cctrl start                       # launch claude with Remote Control enabled
cctrl start --resume              # resume a session (interactive picker)
cctrl start -p "fix bug"          # extra flags passed through
```

`cctrl start` launches `claude` with `--remote-control` and a session name prefix based on the current git repo. Multiple sessions in the same folder get unique suffixes (e.g. `cctrl-graceful-unicorn`), replaced by an AI-generated summary within seconds.

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

### Spawn (remote launch over SSH)

```bash
cctrl spawn ~/_projects/myapp     # launch in a detached tmux session
cctrl spawn @myapp                # use a saved shortcut
cctrl spawn --list                # list active sessions
cctrl spawn --attach myapp        # reattach to a session
cctrl spawn --kill myapp          # kill a session
```

Launches a cctrl session inside a detached **tmux** session. The session persists after SSH disconnect — reattach anytime from any terminal. No GUI, no iTerm2, no AppleScript required.

```bash
# From your phone over SSH:
ssh mac 'cctrl spawn @homelab'

# Later, from any terminal:
cctrl spawn --attach homelab
```

**Requires:** tmux (`brew install tmux`)

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
