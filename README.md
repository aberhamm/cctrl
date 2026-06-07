# cctrl

A CLI for managing local coding-agent sessions, profiles, costs, and developer environment. Claude Code is the default runtime; Codex can be selected per launch. Built for power users who run multiple projects, track token spend, and sometimes SSH into their Mac to kick off sessions remotely.

## What it does

- **Profile switching** — swap between settings configs (API keys, models, hooks, permissions) with one command
- **Session launching** — start Claude Code or Codex with consistent flags, resume previous sessions, jump into projects via named shortcuts, or run detached so it survives SSH disconnect
- **Remote hosts** — run any cctrl command on another machine over SSH; start a detached session on your Mac from your phone and auto-attach
- **Usage & cost tracking** — token spend by model/project/day, rate limit monitoring, billing week breakdowns
- **Port management** — track port history, find free ports, kill processes by port, discover ports from project files
- **Chrome CDP** — launch Chrome with remote debugging for browser automation workflows
- **Agent status lines** — Claude Code script statusline or Codex TUI footer setup from one command

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

Each profile is a **model + env overlay** stored in `profiles/` (e.g. one routed
through an API gateway, one on your subscription). Shared Claude settings —
hooks, permissions, MCP servers, statusline — live once in `~/.claude/settings.json`;
profiles only carry what differs.

The concurrency-safe way to use a profile is to pick it at launch:

```bash
cctrl start --profile work        # launch with work's model + env, this session only
cctrl start --profile personal    # a second window can use a different profile at the same time
cctrl @myapp                       # a shortcut applies its profile the same way
```

`--profile` injects the profile env into the launched process and passes its
model as `--model` (CLI `--model` still wins). It does **not** touch global
state, so two windows can run different profiles simultaneously without conflict.

Profiles can be agent-aware. Top-level `env` is shared only when an `agents`
block exists; `agents.<agent>.env`, `agents.<agent>.model`, and
`agents.<agent>.args` are selected for the runtime:

```json
{
  "env": {
    "SHARED_VAR": "value"
  },
  "agents": {
    "claude": {
      "model": "sonnet",
      "env": {
        "ANTHROPIC_MODEL": "us.anthropic.claude-sonnet-4-6",
        "CLAUDE_CODE_USE_BEDROCK": "1"
      }
    },
    "codex": {
      "model": "gpt-5.5",
      "env": {
        "CODEX_HOME": "/Users/me/.codex-work"
      },
      "args": ["--sandbox", "workspace-write", "--ask-for-approval", "on-request"]
    }
  }
}
```

Legacy profiles with no `agents` block keep their old Claude behavior: top-level
`env` and `model` apply to Claude. When launching Codex with a legacy profile,
CCTRL ignores Claude-looking top-level models such as `sonnet`, `opus`, and
`haiku`, and does not export the legacy top-level env.

```bash
cctrl ls                  # list profiles (* = active default)
cctrl use <profile>       # set the CCTRL default profile; also merges Claude model+env for compatibility
cctrl current             # show active default + model/env drift
cctrl save <name>         # capture current Claude model+env as a new agent-aware profile
cctrl diff <profile>      # diff current Claude model+env vs a profile
cctrl rename <old> <new>  # rename a profile
cctrl edit <profile>      # open in $EDITOR
```

> `cctrl use` keeps legacy Claude Code compatibility by merging the profile's
> Claude model/env into `~/.claude/settings.json`. For clean per-session auth
> switching across Claude and Codex, prefer `cctrl start --profile`.

## Sessions

A launch is described by three independent axes:

| Axis | Question | How you set it |
| --- | --- | --- |
| **Location** | which machine runs it? | `--host <alias>` (default: local) |
| **Durability** | does it survive disconnect? | `-d` / `--detach` (default: foreground) |
| **Agent** | which CLI runs? | `--agent claude` (default) or `--agent codex` |
| **Bridge** | can the phone app drive it? | Claude only, on by default; `--no-bridge` to disable |

There's **one launch verb — `start`** — and the flags above pick the behavior. Managing detached sessions (list/attach/kill) lives under `cctrl session`.

```bash
cctrl start                       # foreground, current dir, phone bridge on
cctrl start --agent codex         # launch Codex instead of Claude
cctrl --agent codex start         # same, useful with global flags
cctrl start --resume              # resume a session (interactive picker)
cctrl start --yolo                # full bypass: Claude bypassPermissions / Codex --yolo
cctrl start --permission-mode bypassPermissions  # also maps to Codex --yolo
cctrl start -m "fix bug"          # launch with an initial prompt
cctrl start --no-bridge           # launch without the phone-control bridge
```

`cctrl start` launches `claude` by default with the phone-control bridge and a session name prefix based on the current git repo. `--agent codex` launches `codex` instead. Multiple detached sessions in the same folder get unique suffixes (e.g. `homelab--2`).

### Detached sessions

Add `-d` to run inside a detached **tmux** session that persists after SSH disconnect — reattach anytime from any terminal. No GUI required — just tmux. A detached launch requires an explicit target (a dir or `@shortcut`); defaulting to `$HOME` would drop a full-access agent into `~/.ssh`, `~/.aws`, etc.

```bash
cctrl start -d ~/_projects/myapp  # launch detached in a directory
cctrl start -d @myapp             # ...or via a saved shortcut
cctrl start -d @myapp --agent codex

cctrl session ls                  # list sessions (see below)
cctrl session attach myapp        # reattach (interactive picker if no name)
cctrl session kill myapp          # kill a session
```

**Requires:** tmux (`brew install tmux`)

`cctrl session ls` is self-describing — for each tmux session it shows the working
directory, whether it's a live agent process (and which model) or a plain shell,
and attached/detached state. A `✦` marks sessions cctrl spawned. Add `--json` for
machine-readable output:

```
$ cctrl session ls
✦ = cctrl-managed agent session
✦ homelab    claude (opus-4-6)  ~/_projects/homelab   detached
✦ cctrl      codex (?)          ~/_projects/cctrl      detached
  scratch    shell (zsh)        ~/tmp                 attached
```

### Shortcuts

Named jump targets — cd into a directory, optionally switch profile or agent, and launch in one command.

```bash
cctrl @<name>                # cd + switch profile + start
cctrl @<name> -m "fix bug"  # with an initial prompt
cctrl @<name> --resume       # resume picker for that project
cctrl @                      # list shortcuts

cctrl @add myapp ~/projects/myapp --profile work
cctrl @add cctrl ~/projects/cctrl --agent codex
cctrl @rm myapp
```

## Remote Hosts

Run any cctrl command on a named host over SSH. The `--host` flag transparently forwards the command — no manual SSH required.

```bash
cctrl whoami                              # which machine am I? which aliases mean "local"?
cctrl host add studio ms-128g-bln         # register a host
cctrl host add studio ms-128g-bln matt    # with explicit user
cctrl host list                            # show registered hosts (marks the local one)
cctrl host rm studio                       # remove a host
cctrl host doctor studio                   # check SSH, brew, tmux, default agent, cctrl
cctrl host doctor studio --agent codex     # check codex instead of claude
```

**Local is just another host.** `local` and `self` are built-in aliases for the
current machine, and any host you register whose hostname matches this machine is
recognized as local too. When `--host` points at this machine, cctrl runs the
command directly instead of SSH-ing into itself — so addressing is symmetric: you
can always write `--host <name>`, local or remote.

```bash
cctrl host add macbook "$(hostname)"      # name this machine
cctrl --host macbook session ls           # runs locally, no SSH
cctrl --host local whoami                 # built-in alias, always local
```

`--host` is orthogonal — it forwards *any* command, so the three axes compose. `--host` says **where**, `-d` says **durable**:

```bash
cctrl --host studio start -d @homelab        # start a detached session there, then auto-attach
cctrl --host studio session ls               # list remote detached sessions
cctrl --host studio session attach homelab   # attach interactively (TTY)
cctrl --host studio costs --week             # view remote cost data
```

`cctrl --host studio start -d @homelab` is the "start a session on my Mac from my phone" workflow: it SSHes in, starts the detached session, then attaches to that exact session over a second connection. The remote prints its resolved session name so the attach targets the right one even with auto-increment suffixes.

**TTY handling:** Interactive commands (`start` foreground, `start -d` auto-attach, `@shortcut`, `session attach`, `edit`) use `ssh -t`. Non-interactive commands (`session ls`, `costs`, `usage`, `ls`) use plain `ssh`.

**Host doctor** checks SSH connectivity, brew, tmux, the selected agent, cctrl availability, and `~/.tmux.conf` on the remote host — with interactive auto-fix offers for missing dependencies.

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

`cctrl usage` shows Claude and Codex rate-limit snapshots when local data is available, plus token spend per billing week. Peak rate limit usage is tracked per week.

`cctrl costs` parses Claude session JSONLs from `~/.claude/projects/` and Codex session JSONLs from `~/.codex/sessions/` and `~/.codex/archived_sessions/` for detailed token breakdowns (input, output, cache write, cache read) with estimated USD. Codex costs are API-equivalent estimates; ChatGPT-plan sessions may consume included plan usage instead of API billing. No external API calls.

### How tracking works

1. A `Stop` hook runs `hooks/session-log.py` after each Claude assistant turn, summing deduplicated token usage per session
2. A statusline script (`hooks/statusline.sh`) captures rate limit data from Claude Code on each update
3. Codex token usage and rate limits are read directly from local Codex session JSONLs
4. `cctrl usage` and `cctrl costs` aggregate both agents locally

## Status Lines

```bash
cctrl statusline claude install
cctrl statusline codex install
cctrl statusline claude show
cctrl statusline codex show
```

Claude Code supports an external statusLine command, so CCTRL installs
`hooks/statusline.sh` into `~/.claude/settings.json`.

Codex uses a native TUI footer instead of an arbitrary redraw script. CCTRL
installs this footer in `~/.codex/config.toml`:

```toml
[tui]
status_line = ["model-with-reasoning", "context-remaining", "context-used", "git-branch", "current-dir", "run-state"]
```

Codex rate-limit and token reporting still comes from local Codex session JSONLs
and is surfaced through `cctrl usage`.

## Compatibility Matrix

| Feature | Claude Code | Codex |
| --- | --- | --- |
| Foreground launch | yes | yes |
| Detached tmux launch | yes | yes |
| Shortcuts | yes | yes |
| Agent-aware profile overlays | yes | yes |
| Initial prompt with `-m` | yes | yes |
| `--yolo` | maps to `bypassPermissions` | native |
| Native sandbox/approval flags | Claude permission mode | Codex `--sandbox` / `--ask-for-approval` |
| Usage and cost parsing | local JSONL | local JSONL |
| Rate-limit reporting | statusline/history files | session JSONL `token_count` events |
| Status line | external script | built-in TUI footer |
| Phone bridge | yes | no |
| Hooks in this repo | Claude hook protocol | not installed by CCTRL |

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
