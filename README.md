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
| **Durability** | does it survive disconnect? | tmux-backed by default; `--foreground` for direct one-offs; `-d` / `--detach` to start detached and return |
| **Agent** | which CLI runs? | `--agent codex` (default for now) or `--agent claude` |
| **Bridge** | can the phone app drive it? | Claude only, on by default; `--no-bridge` to disable |

There's **one launch verb — `start`** — and the flags above pick the behavior. Interactive starts are tmux-backed by default so local and remote agents are durable and addressable. Managing tmux sessions (list/attach/kill) lives under `cctrl session`.

```bash
cctrl start                       # tmux-backed, current dir, Codex by default
cctrl start --agent claude        # launch Claude instead of Codex
cctrl --agent claude start        # same, useful with global flags
cctrl start --foreground          # direct one-off launch without tmux
cctrl start --resume              # resume a session (interactive picker)
cctrl start --yolo                # full bypass: Claude bypassPermissions / Codex --yolo
cctrl start --permission-mode bypassPermissions  # also maps to Codex --yolo
cctrl start -m "fix bug"          # launch with an initial prompt
cctrl start --purpose "fix bug"   # store cleanup/review context without sending a prompt
cctrl start --no-bridge           # launch without the phone-control bridge
cctrl start --agent codex --remote unix://  # connect Codex TUI to local app-server
```

`cctrl start` launches the default agent from `data/config.json`; it is currently set to `codex`. Use `--agent claude` when you want Claude Code and its phone-control bridge. Multiple detached sessions in the same folder get unique suffixes (e.g. `TMUX--homelab--2`).

### Tmux sessions

By default, `cctrl start` and `cctrl @shortcut` create a **tmux** session and
ask whether to connect when launched from an interactive terminal. This gives
local and remote agents a stable session name and lets them survive SSH
disconnects. Use `--foreground` or `--no-tmux` for quick direct one-offs.

Add `-d` to start the tmux session and return without attaching. No GUI required — just tmux. An explicit detached launch requires an explicit target (a dir or `@shortcut`); defaulting to `$HOME` would drop a full-access agent into `~/.ssh`, `~/.aws`, etc.

```bash
cctrl start ~/_projects/myapp     # tmux-backed; prompts to connect in a TTY
cctrl @myapp                      # shortcut launch, also tmux-backed
cctrl @myapp --foreground         # direct launch without tmux

cctrl start -d ~/_projects/myapp  # launch detached; prompts with default "no"
cctrl start -d @myapp             # ...or via a saved shortcut
cctrl start -d @myapp --agent codex
cctrl start -d @myapp --purpose "review auth logs"

cctrl session ls                  # list sessions (see below)
cctrl session current --json      # machine-readable identity for the current agent/process
cctrl session attach myapp        # partial names work; full name is TMUX--myapp
cctrl session close TMUX--myapp   # gracefully close a session
cctrl session kill TMUX--myapp    # kill a session immediately
```

#### Letting the agent close its own session

`cctrl session current --json` tells an agent exactly what kind of cctrl launch
it is running under, the verified tmux session name if there is one, and whether
`cctrl close` can safely close the current session. `cctrl session close` (alias:
`cctrl close`) run with no arguments only self-closes after cctrl verifies the
caller is actually inside the cctrl tmux session's pane tree. When verified, it
schedules the kill a few seconds out so the calling process can finish its
output before the pane disappears.

```bash
cctrl close                       # inside a session: close it after a 5s grace period
cctrl close --in 15               # longer grace period
cctrl close --now                 # no grace period
cctrl close TMUX--myapp           # close a specific session (immediate from outside)
```

Sessions not started by cctrl are refused unless you add `--force`. Stale or
inherited tmux-looking environment is refused for no-arg self-close; pass an
explicit session name only when you intentionally want to close another session.
The default grace period is 5 seconds (override per call with `--in`, or
globally with `CCTRL_CLOSE_GRACE`).

When a tmux-backed launch runs in an interactive terminal, `cctrl` asks for a
session purpose before creating the session. Press Enter to accept the inferred
default, usually the initial `-m` prompt, shortcut name, or project folder. The
purpose is stored as local metadata for `cctrl session ls` and future cleanup
commands; it is not sent to Claude or Codex unless you also pass it as
`-m/--message`.

**Requires:** tmux (`brew install tmux`)

Detached sessions use segmented names so tmux, remote hosts, and Claude Code
display/bridge names line up:

```text
TMUX--myapp              # local detached session
TMUX--studio--myapp      # detached session launched with --host studio
```

`cctrl session ls` is self-describing — for each tmux session it shows the working
directory, whether it's a live agent process (and which model) or a plain shell,
and attached/detached state. A `✦` marks sessions cctrl spawned. Add `--json` for
machine-readable output:

```
$ cctrl session ls
✦ = cctrl-managed agent session
✦ TMUX--homelab    claude (opus-4-6)  ~/_projects/homelab   detached
✦ TMUX--cctrl      codex (?)          ~/_projects/cctrl      detached
  scratch          shell (zsh)        ~/tmp                 attached
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

### Peers

Peers are named coding agents that other cctrl workflows can address. The peer
registry combines manual entries from `data/peers.json` with live cctrl-managed
tmux sessions derived from `cctrl session ls --json`.

```bash
cctrl peer register comet --dir /Users/matthew/_projects/comet-automation --agent codex
cctrl peer register reviewer --agent codex --capability polling
cctrl peer alias comet comet-agent

cctrl peer ls
cctrl peer ls --json
cctrl peer resolve comet-agent --json
cctrl peer whoami --as comet --json
CCTRL_PEER=comet cctrl peer whoami --json
cctrl peer unregister comet
```

Manual peers can carry `--host`, `--dir`, `--agent`, `--session`,
`--purpose`, and repeated `--capability` metadata. Live tmux peers are derived
at read time and include `mailbox` and `tmux` capabilities plus a computed
`tmux_target`; pane targets are not stored because they go stale. If a manual
peer has the same name as a live session, the manual entry wins and `peer ls
--json` marks it with `shadows`.

Peer names and aliases may contain letters, numbers, dots, underscores, and
dashes. Whitespace, shell metacharacters, and the reserved name `user` are
rejected. Peer state is machine-local. Tests and isolated workflows can set
`CCTRL_DATA_DIR` to move only peer-messaging runtime files; existing shortcuts,
hosts, profiles, and cost data keep using their normal cctrl paths.

Mailbox messages are stored as JSON Lines in `data/messages.jsonl` under the
same peer data root. The lifecycle is intentionally small:
`queued -> delivered -> acked`. Sending creates `queued` messages; later receive
commands mark messages `delivered`; `ack` only succeeds for delivered messages
addressed to the acking peer.

```bash
cctrl peer send comet --from orchestrator --subject "Check" -- "Please check XYZ"
cctrl peer send comet --from orchestrator --body-file prompt.txt --json
printf 'Handle this\n' | cctrl peer send comet --from orchestrator --body-file - --json
cctrl peer inbox --as comet --json          # queued + delivered messages for comet
cctrl peer check --as comet --json          # compact unread summary
cctrl peer recv --as comet --json           # deliver/read the next message
cctrl peer outbox --as orchestrator --json  # messages sent by orchestrator
cctrl peer show msg_20260608_070000_abc123 --json
cctrl peer ack msg_20260608_070000_abc123 --as comet --json
```

Senders and recipients must resolve to known peers unless `peer send` is given
`--allow-unknown`, which marks the message with `unknown_peer: true`. `--from`
can be omitted when `--as` or `CCTRL_PEER` identifies the sender; JSON sends
without an identity fail instead of silently defaulting. Mailbox writes use an
exclusive lock and atomic rewrites for state transitions; stale fallback lock
directories record their holder PID and are reclaimed automatically.

Agents that do not have a tmux session can poll the mailbox directly:

```bash
export CCTRL_PEER=comet

if cctrl peer check --json --exit-on-empty >/tmp/cctrl-check.json; then
  msg_json="$(cctrl peer recv --json)"
  msg_id="$(printf '%s\n' "$msg_json" | jq -r '.message.id')"
  msg_body="$(printf '%s\n' "$msg_json" | jq -r '.message.body')"
  # handle "$msg_body"
  cctrl peer ack "$msg_id" --json >/dev/null
elif [ "$?" -eq 2 ]; then
  : # no queued or delivered-unacked messages
fi
```

`peer recv` transitions the oldest queued message for the peer to
`delivered` and leaves it unacked. If no queued message exists, it returns the
oldest delivered-but-unacked message without changing it, which lets a crashed
agent retry before calling `ack`. JSON errors use
`{"ok":false,"error":{"code":"...","message":"..."}}`.

The preferred setup is an idle doorbell: launch the session with a peer
identity, then let the agent check its mailbox at natural pause points.

```bash
cctrl start -d --peer comet ~/projects/comet-automation
cctrl start --foreground --peer comet --agent codex
```

`--peer` exports `CCTRL_PEER` into the agent process and stores the peer in
session metadata. Commands such as `cctrl peer recv --json`, `cctrl peer ack
<id> --json`, and `cctrl peer mcp` can then resolve the identity without
manual `--as` flags. Detached launches may use a new valid peer name because
the tmux session metadata makes it discoverable; direct foreground launches
should use an already registered peer name.

Claude Code can use the blocking hook:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/cctrl/hooks/peer-doorbell.sh"
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/cctrl/hooks/peer-doorbell.sh"
          }
        ]
      }
    ]
  }
}
```

The hook exits 0 when `CCTRL_PEER` is unset, the inbox is empty, dependencies
are missing, or only delivered-but-unacked messages remain. It exits 2 only
for queued messages, printing the same doorbell text as tmux nudges so Claude
immediately sees the instruction to run `peer recv`.

Codex has notification-only `notify` semantics, so it cannot force the model to
run `peer recv`, but it can surface the same doorbell:

```toml
notify = ["/path/to/cctrl/hooks/peer-doorbell.sh", "codex"]
```

If you already use a Codex `notify` command, wrap both notifications in a small
local script and configure `notify` to call that wrapper.

Tmux-backed peers can also be nudged when they have queued messages. This is a
fallback for sessions without hooks, not message transport: the pasted text is
a fixed one-line command that tells the agent to poll its mailbox, and message
bodies stay in `peer recv`.

```bash
cctrl peer deliver comet --dry-run       # show the nudge without mutation
cctrl peer deliver comet                 # paste and submit one nudge
cctrl peer deliver comet --no-submit     # paste without pressing Enter
cctrl peer deliver --all --json          # nudge every queued tmux-capable peer
```

The nudge format is constant:

```text
[cctrl] N new peer message(s) for comet. Run: cctrl peer recv --as comet --json
```

Before pasting, cctrl captures the last lines of the target pane and defers
delivery when it sees known Claude/Codex approval or permission prompts. A
deferred nudge leaves messages queued for the next pass. Successful and failed
nudge attempts update `nudge_count`, `last_nudge_at`, `last_nudge_error`, and
message history without changing message status.

`--inline <message-id>` is explicit paste-only delivery for a full message
body. It never presses Enter and should not be used for unattended sessions,
because it pastes arbitrary message content into the target pane.

### Peer Orchestrator Workflow

An orchestrator can queue work for peers, watch who needs attention, and nudge
only the peers that can receive tmux doorbells. Polling-only or MCP-only peers
stay queued for their own `peer check`/`peer recv` loop.

```bash
cctrl peer status --json
cctrl peer send comet --from orchestrator --subject "Check" -- "Please check XYZ"
cctrl peer nudge comet
cctrl peer nudge --stale --older-than 15m --json
cctrl peer watch --once --dry-run --json
cctrl peer watch --interval 5 --renudge-after 15m --backoff 10m
cctrl peer gc --older-than 7d --status acked --dry-run --json
cctrl peer doctor comet --json
```

A durable orchestrator session can run with a short operating prompt:

```text
You are the peer-message orchestrator. Periodically run cctrl peer status
--json, send concise work requests with cctrl peer send, use cctrl peer watch
--once --json to nudge tmux peers, and leave polling-only peers queued. Do not
paste message bodies into tmux sessions unless explicitly asked.
```

`peer watch` is singleton-locked per peer data directory. If another watcher is
running, a second watcher exits instead of double-nudging. `--once --force`
bypasses the lock for manual inspection. Backoff is based on consecutive failed
nudge history so a dead tmux target is not hammered on every pass.

Cross-host usage composes with the normal host forwarding layer:

```bash
cctrl --host studio peer status --json
cctrl --host studio peer send comet --from orchestrator -- "Check the deploy log"
cctrl --host studio peer watch --once --json
```

Peer mailboxes are machine-local and are not replicated across hosts. A
`--host studio` command reads and writes the Studio's `data/messages.jsonl`;
the same command without `--host` uses this machine's mailbox. Register peers
on the host where their mailbox and tmux session live.

Retention is explicit. `peer gc` only archives statuses you name, defaults to
`acked`, and writes archived JSONL records to `data/messages-archive.jsonl`
before removing them from the active mailbox. Use `--dry-run` first for
retention jobs. If the archive append fails, GC leaves the active mailbox
unchanged and exits non-zero.

Trust model and limitations: cctrl authenticates peers by local registry name,
not cryptographic identity. The mailbox is local filesystem state protected by
normal file permissions. Tmux nudges are only doorbells; they do not prove the
agent read or completed the work. Full-body inline paste is intentionally
manual-only because it sends arbitrary text into an interactive shell.

Polling exit codes:

| Code | Meaning |
|---:|---|
| 0 | Command succeeded |
| 2 | No messages for `check`/`recv` with `--exit-on-empty` |
| 64 | Usage or validation error |
| 65 | Corrupted mailbox JSONL |
| 66 | Unknown peer or unresolved identity |

### Peer MCP Bridge

Tool-calling agents can use the same mailbox through a stdio MCP server:

```bash
cctrl peer mcp --as comet
CCTRL_PEER=comet cctrl peer mcp
```

Each server is bound to one peer identity at startup. Tools do not accept
`as` or `from` arguments; `send_message` always sends from the configured
identity, and `recv_message`/`ack_message` always operate as that identity.

Exposed tools:

```text
whoami
list_peers
resolve_peer
send_message
check_messages
recv_message
show_message
ack_message
```

Codex global config in `~/.codex/config.toml`:

```toml
[mcp_servers.cctrl-peer-comet]
command = "/path/to/cctrl"
args = ["peer", "mcp"]
env = { CCTRL_PEER = "comet" }
```

Claude Code project config in `.mcp.json`:

```json
{
  "mcpServers": {
    "cctrl-peer-comet": {
      "command": "/path/to/cctrl",
      "args": ["peer", "mcp"],
      "env": {
        "CCTRL_PEER": "comet"
      }
    }
  }
}
```

For a user-scoped Claude Code server:

```bash
claude mcp add -s user cctrl-peer-comet -- /path/to/cctrl peer mcp
```

Then add the peer identity env var to that server entry in `~/.claude.json`:

```json
{
  "mcpServers": {
    "cctrl-peer-comet": {
      "command": "/path/to/cctrl",
      "args": ["peer", "mcp"],
      "env": {
        "CCTRL_PEER": "comet"
      }
    }
  }
}
```

## Remote Hosts

Run any cctrl command on a named host over SSH. The `--host` flag transparently forwards the command — no manual SSH required.

```bash
cctrl whoami                              # which machine am I? which aliases mean "local"?
cctrl host add studio ms-128g-bln         # register a host
cctrl host add studio ms-128g-bln matt    # with explicit user
cctrl host list                            # show registered hosts (marks the local one)
cctrl host rm studio                       # remove a host
cctrl host doctor studio                   # check SSH, tmux, cctrl, agent, shared skills
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
cctrl --host studio session attach homelab   # partial match for TMUX--studio--homelab
cctrl --host studio costs --week             # view remote cost data
```

`cctrl --host studio start -d @homelab` is the "start a session on my Mac from my phone" workflow: it SSHes in, starts the detached session, then attaches to that exact session over a second connection. The remote prints its resolved session name so the attach targets the right one even with auto-increment suffixes.

**TTY handling:** Interactive commands (`start` foreground, `start -d` auto-attach, `@shortcut`, `session attach`, `edit`) use `ssh -t`. Non-interactive commands (`session ls`, `costs`, `usage`, `ls`) use plain `ssh`.

**Host doctor** checks SSH connectivity, brew, tmux, the selected agent, cctrl availability, `~/.tmux.conf`, shared Skillshare targets, and the selected agent's common instruction file (`~/.codex/AGENTS.md` or `~/.claude/CLAUDE.md`) — with interactive auto-fix offers for missing dependencies.

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

`cctrl usage` shows Claude and Codex rate-limit snapshots when local data is available, plus token spend/API-equivalent value per billing week split by agent. Peak rate limit usage is tracked per week per agent.

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
| App-server-backed TUI | n/a | `--remote unix://` passthrough |
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
