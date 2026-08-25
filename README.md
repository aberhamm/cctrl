# cctrl

A CLI for managing local coding-agent sessions, profiles, costs, and developer environment. The default runtime is configurable, and `cctrl` prompts for an agent when no default is set. Built for power users who run multiple projects, track token spend, and sometimes SSH into their Mac to kick off sessions remotely.

## What it does

- **Profile switching** — swap between settings configs (API keys, models, hooks, permissions) with one command
- **Session launching** — start Claude Code or Codex with consistent flags, resume previous sessions, jump into projects via named shortcuts, or run detached so it survives SSH disconnect
- **Session health** — a rich per-session STATE (waiting-input, blocked-dialog, unsent-draft, idle-done), plus `session doctor`/`autoheal` to repair broken remote-control bridges and `session prune` to retire stale sessions
- **Peer messaging** — sessions address each other by name: a durable local mailbox (`peer send`/`check`/`recv`/`ack`/`reply`) for async work, direct live-tmux chat (`peer say`) for a running agent, tmux doorbell nudges, and a stdio MCP bridge so tool-calling agents get the same surface
- **Fleet view** — `cctrl fleet` merges every host's sessions into one recency-sorted list; `cctrl needs-me` reports only what newly needs your attention since the last check
- **Remote hosts** — run any cctrl command on another machine over SSH; start a detached session on your Mac from your phone and auto-attach
- **Usage & cost tracking** — token spend by model/project/day, rate limit monitoring, billing week breakdowns
- **Chrome CDP** — launch Chrome with remote debugging for browser automation workflows
- **Agent status lines** — Claude Code script statusline or Codex TUI footer setup from one command
- **Plugins** — port management (`cctrl ports`) and directory scanning (`cctrl scan`) ship as drop-in plugins, not core commands

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/aberhamm/cctrl/main/install.sh | bash
```

This clones the repo, symlinks the binary to `~/.local/bin`, adds it to your PATH, and sets up zsh completions. Re-run to update.

Or manually:

```bash
git clone https://github.com/aberhamm/cctrl.git ~/.local/share/cctrl
mkdir -p ~/.local/bin
ln -s ~/.local/share/cctrl/cctrl ~/.local/bin/cctrl
```

`~/.local/bin` does not exist on a fresh machine, so create it before symlinking
and make sure it is on your `PATH`.

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

Profiles can also override the global agent default. Set `defaultAgent` to
`"claude"` or `"codex"` to choose automatically for that profile, or set it to
`null` to prompt every time that profile is active:

```json
{
  "defaultAgent": null,
  "env": {}
}
```

Legacy profiles with no `agents` block keep their old Claude behavior: top-level
`env` and `model` apply to Claude. When launching Codex with a legacy profile,
CCTRL ignores Claude-looking top-level models such as `sonnet`, `opus`, and
`haiku`, and does not export the legacy top-level env.

**Provider-prefixed model ids don't move with `model`.** A profile routing through
Bedrock or an API gateway pins full provider ids in `env` (`ANTHROPIC_MODEL`,
`ANTHROPIC_DEFAULT_OPUS_MODEL`, …). These are independent of the top-level `model`
and of each other — bumping one does not bump the rest, and a gateway may not carry
a version the first-party API already has. Verify the id against the gateway before
changing it.

**Profiles are gitignored and machine-local.** `profiles/*.json` is not tracked, so
a profile edit — switching the model, adding an env var — reaches only the machine
you made it on. Pushing does not carry it. To run the same profile elsewhere, copy
the file across (as with `data/hosts.json`, each machine is its own source of
truth).

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
| **Agent** | which CLI runs? | `--agent codex`, `--agent claude`, or the configured default |
| **Bridge** | can the app drive it? | Claude bridge on by default; Codex app bridge is experimental and opt-in |

There's **one launch verb — `start`** — and the flags above pick the behavior. Interactive starts are tmux-backed by default so local and remote agents are durable and addressable. Managing tmux sessions (list/attach/kill) lives under `cctrl session`.

```bash
cctrl start                       # tmux-backed, current dir, configured default or prompt
cctrl start --agent claude        # launch Claude instead of Codex
cctrl --agent claude start        # same, useful with global flags
cctrl start --foreground          # direct one-off launch without tmux
cctrl start --resume              # resume a session (interactive picker)
cctrl start --yolo                # full bypass: Claude bypassPermissions / Codex --yolo
cctrl start --permission-mode bypassPermissions  # also maps to Codex --yolo
cctrl start -m "fix bug"          # launch with an initial prompt
cctrl start --purpose "fix bug"   # store cleanup/review context without sending a prompt
cctrl start --no-bridge           # launch without the phone-control bridge
cctrl start --agent codex --remote unix://  # opt into Codex app-server bridge
```

`cctrl start` uses `--agent` first, then `CCTRL_AGENT`, then the active profile's `defaultAgent`, then `defaultAgent` from `data/config.json`. If no agent is selected and the command has a TTY, it prompts with the available agents; non-interactive launches should pass `--agent claude|codex` or configure a default. Multiple detached sessions in the same folder get unique suffixes (e.g. `TMUX--homelab--2`).

### Tmux sessions

By default, `cctrl start` and `cctrl @shortcut` create a **tmux** session and
ask whether to connect when launched from an interactive terminal. This gives
local and remote agents a stable session name and lets them survive SSH
disconnects. Use `--foreground` or `--no-tmux` for quick direct one-offs.

Add `-d` to start the tmux session and return without attaching. No GUI required — just tmux. An explicit detached launch requires an explicit target (a dir or `@shortcut`); defaulting to `$HOME` would drop a full-access agent into `~/.ssh`, `~/.aws`, etc.

When a directory launch (`cctrl start -d <dir>`) targets a directory that a configured shortcut points at, the session adopts that shortcut's short alias for its name — so `cctrl start -d ~/dev/unstructured-data-portal` and `cctrl start -d @portal` produce the identical `TMUX--<device>--portal` name (and therefore the identical `--remote-control` bridge prefix). If several shortcuts point at the same directory, the first match by sorted key wins (deterministic). A directory with no matching shortcut keeps its repo-folder slug (unchanged).

For tmux-backed Codex sessions, cctrl treats the tmux exit as task completion and archives the matching Codex task automatically. Restarts stay open. Set `CCTRL_CODEX_ARCHIVE_ON_EXIT=0` only when a session should remain visible after its tmux pane exits.

Detached agent app titles are reconciled to `repo: description (TMUX--...)`.
Claude gets this at launch through its `--name`/remote-control title surface.
Codex has no equivalent title flag, so cctrl resolves the Codex rollout id and
updates the local Codex app state row after the session appears. When Codex
app bridging is desired, opt in explicitly with `--remote unix://` for one launch
or `CCTRL_CODEX_REMOTE_DEFAULT=unix://` for tmux-backed Codex launches in that
environment. `--no-bridge` suppresses that default. `cctrl rename <session> "new
description"` uses the same title path for live Codex sessions.

For now, tmux is the default Codex control surface. The app-owned Codex path is
experimental and should be used deliberately. Once a Codex task has been
registered with the app-server, you can release the tmux owner and continue in
the ChatGPT/Codex app:

```bash
cctrl session release-to-app TMUX--myapp --yes
cctrl session release-to-app --all --yes
cctrl session app-ls
```

`release-to-app` sends EOF to the tmux session, waits for it to exit, preserves
the cctrl metadata record, and quarantines only stale Codex writer locks that no
live tmux session or Codex process appears to own. `app-ls` is the experimental
app-owned Codex view; `session ls` remains the default live tmux view.

```bash
cctrl start ~/dev/myapp           # tmux-backed; prompts to connect in a TTY
cctrl @myapp                      # shortcut launch, also tmux-backed
cctrl @myapp --foreground         # direct launch without tmux

cctrl start -d ~/dev/myapp        # launch detached; prompts with default "no"
cctrl start -d @myapp             # ...or via a saved shortcut
cctrl start -d @myapp --agent codex
cctrl start -d @myapp --purpose "review auth logs"

cctrl session ls                  # list sessions (see below)
cctrl session app-ls              # list released Codex app tasks
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

#### Talking to a live session directly

`cctrl session say` is the direct way to chat with an agent that is **already
running** in a known tmux session. It pastes the exact message into the session's
pane and presses Enter, the same way you would type into it yourself — no mailbox,
no queue, no delivery state. Reach for it when the session is live and you just
want it to act now; use `cctrl peer send` (below) for durable, async work that
should survive the recipient being away.

```bash
cctrl session say TMUX--myapp -- "run the test suite and report back"
cctrl session say TMUX--myapp --no-submit -- "draft reply, I'll hit enter"
printf 'multi\nline\nbody\n' | cctrl session say TMUX--myapp --body-file -
cctrl session say TMUX--myapp --json -- "status?"   # {ok, session, submitted, status}
```

Before pasting, `say` checks the pane is ready: if a Claude/Codex approval or
trust **modal** is on screen it refuses (`status: busy`, non-zero exit) rather
than injecting keystrokes into a dialog — and `--force-busy` does **not** override
a detected modal. `--force-busy` only permits pasting when the agent (and thus its
readiness) cannot be inferred from the pane. Unknown sessions, empty bodies,
body-file read errors, and tmux paste failures all fail loudly with a non-zero
exit. `session say` never reads or writes the peer mailbox.

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

`cctrl session ls` is self-describing. There is no header row — a legend line
explains the two markers, and each row reads left to right as: `✦` (cctrl
spawned it), session name, agent and model (or `shell (zsh)`), working
directory, **STATE**, attached/detached, time since last active, `rc` (the
remote-control bridge: `live` / `dead` / `off`), and the session purpose. Rows
are sorted by last-active, most recent first. Anything unmeasurable renders `-`
rather than guessing.

```
$ cctrl session ls
✦ = cctrl-managed · rc = remote-control bridge (live/dead/off). Repair: cctrl session doctor --fix
✦ TMUX--homelab   claude (opus-5)    ~/dev/homelab                  working        detached  4m     live  deploy-poll flake
✦ TMUX--api       claude (sonnet-4-6) ~/dev/api                      idle           detached  3h     live  rate-limit middleware
  scratch         shell (zsh)        ~/tmp                          -              attached  -      -
```

STATE is richer than attached/detached. Beyond the base activity states
(`working`, `idle`, `shell`) it surfaces the ones worth acting on:
`waiting-input`, `blocked-dialog` (an approval or trust modal is up),
`unsent-draft` (text is sitting in the input line, unsubmitted), and
`idle-done` (finished its turn). Every detector fails safe — an ambiguous
signal falls back to the base state instead of asserting something false.

```bash
cctrl session ls --json           # machine-readable; adds session_id, last_active, bridge, peer
cctrl session ls --recap          # add a one-line recap per session
```

`--recap` appends a compact summary of what each session was last doing, read
from the transcript's compact-summary entry. It costs a bounded transcript read
per session, so it is opt-in; sessions with no summary show `-`, and the JSON
`recap` key is absent entirely without the flag.

#### Keeping the fleet healthy

Three maintenance verbs, in increasing order of how much they touch:

```bash
cctrl session doctor                # audit remote-control bridges (read-only)
cctrl session doctor --fix          # repair them (--yes to skip prompts, --json)
cctrl session autoheal --dry-run    # show which dead bridges would be repaired
cctrl session autoheal              # repair them unattended
cctrl session prune                 # propose stale / never-prompted sessions
cctrl session prune --older-than 24h --yes   # ...and close them
```

`session doctor` classifies each Claude session's remote-control bridge as
`live`, `dead`, or `off`, and flags sessions whose bridge prefix has drifted out
of alignment with the tmux session name. `--fix` repairs what it can.

`session autoheal` is the unattended form: it repairs cleanly-dead bridges and
refuses to touch anything ambiguous. It skips a session that is busy, in copy
mode, or has an unsent draft sitting in its input line, because repairing means
relaunching and that would discard the draft. `cctrl session autoheal install
[--interval SECONDS]` registers a per-user launchd timer to run it periodically;
`uninstall` removes it. Nothing is installed automatically.

`session prune` proposes two kinds of candidate: sessions idle longer than the
staleness threshold (default 72h) and **never-prompted** ones that were launched
but never given a user turn. It is a dry run until `--yes`, always excludes the
session you are calling from, and excludes attached sessions unless you pass
`--force`.

#### Fleet snapshots

`cctrl session snapshot` captures the live fleet to a single JSON file —
every session's name, state, conversation ID, transcript path, working
directory, purpose, and launch flags. A launchd timer runs it every 5
minutes so the fleet state survives an unplanned power loss.

```bash
cctrl session snapshot                # write data/snapshots/latest.json
cctrl session snapshot --json         # also print the snapshot to stdout
cctrl session snapshot --dir /tmp/s   # custom snapshot directory
```

Snapshots are written atomically (same-dir `mktemp` + `mv`) and carry an
**empty-fleet guard**: if the capture yields zero sessions but the existing
`latest.json` has sessions in it, the file is preserved. This prevents a
snapshot taken at boot (or while the tmux server is down) from overwriting
the only record of the fleet you are trying to restore. `--allow-empty`
overrides.

**Retention:** Every history file younger than 7 days is kept at full
5-minute granularity. Older than 7 days, only the first file of each UTC
day is kept, up to 90 days. Steady-state disk usage is under 30 MB.

**Timer install** (per-user LaunchAgent, not installed automatically):

```bash
# Fill in placeholders
sed "s|@CCTRL_BIN@|$(which cctrl)|; s|@HOME@|$HOME|" \
    contrib/launchd/com.cctrl.session-snapshot.plist.template \
    > ~/Library/LaunchAgents/com.cctrl.session-snapshot.plist

# Load it
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cctrl.session-snapshot.plist
```

#### Session restore

`cctrl session restore` reads a fleet snapshot and respawns sessions by
resuming their conversations. It is the rebuild command after a power loss
or reboot — one command, gated on memory, waved, dry-runnable, and
idempotent (re-run the same command to continue where you left off).

```bash
cctrl session restore --dry-run          # show the plan; spawn nothing
cctrl session restore --yes              # run non-interactively (required for no TTY)
cctrl session restore --only homelab     # filter by name/label/purpose/cwd
cctrl session restore --from <path>      # use a specific snapshot file
cctrl session restore --limit 4          # cap spawns in this invocation
```

**Resume the conversation; never replay `initial_prompt`.** Those stored
prompts reference sibling sessions that no longer exist. A session with no
`conversation_id` is reported and skipped, full stop.

**Waves and the resource gate.** Sessions spawn in waves of
`CCTRL_RESTORE_WAVE_SIZE` (default 2). In interactive mode, the operator
releases each wave (`y` to proceed, `N` or `q` to stop at the boundary).
In non-interactive mode (`--yes`), waves advance after a fixed pause
(`CCTRL_RESTORE_WAVE_PAUSE`, default 60s) and a memory/swap re-check.
The cap stops when live managed sessions reach `CCTRL_RESTORE_MAX_ACTIVE`
(default 8).

**Answering the resume picker.** When a session has a large transcript
(above ~1 MB), Claude shows a resume picker. The restore report tells you
which sessions to expect it for, with the `tmux attach -t <name>` command.
Attach, press Enter (option 1 "Resume from summary" is preselected), and
detach. Restore itself never captures panes or injects keystrokes.

**Launch configuration replay.** Restore threads `model`, `permission-mode`,
`profile`, `peer`, `sandbox`, `--no-bridge`, and `agent` from the snapshot's
`launch_flags` back onto the spawn argv. A third of the fleet runs with
explicit `--model`; without replay every session comes back on defaults.

#### Persisted conversation_id

Each session record (`data/sessions/*.json`) carries a `conversation_id` field
(Claude's `sessionId` / transcript UUID) that survives process death. It is
populated at launch time for `--resume` launches, and by a best-effort background
poll for fresh launches. `session ls` and `session doctor` refresh the stored
value whenever they observe a non-empty live value that differs from the record.

Records created before this field existed, and sessions whose conversation could
not be resolved, carry `conversation_id: null`. A companion `transcript_path`
field records the transcript file location.

```bash
cctrl session backfill-ids              # preview: show what would be filled (dry-run, default)
cctrl session backfill-ids --apply      # actually write the backfilled ids
cctrl session backfill-ids --json       # structured output with per-record status
```

`backfill-ids` operates on all session records (live and dead). It extracts
conversation UUIDs only from `--resume`/`-r` flags in the record's
`launch_command`, never from bare UUIDs that may appear elsewhere (e.g. in
scratchpad paths). Records with no recoverable UUID remain `null`. The verb
reports three counts: filled, already-set, and unrecoverable.

#### The low-memory launch guard

Before creating another session, `cctrl start` checks free memory and refuses to
launch when the machine is genuinely low, printing the same resource line
`cctrl fleet` shows. It deliberately does not gate on session count — idle
sessions cost almost nothing, so counting them would block launches while memory
is fine. Bypass with `-f` / `--force` or `CCTRL_FORCE=1`. The thresholds are
overridable (`CCTRL_MEM_FREE_MIN_PCT`, `CCTRL_MEM_FREE_SOFT_PCT`,
`CCTRL_SWAP_USED_HI_MB`). On a platform where memory cannot be measured the
guard never fires, and the resource line renders the unavailable probe as `n/a`.

### Shortcuts

Named jump targets — cd into a directory, optionally switch profile or agent, and launch in one command.

```bash
cctrl @<name>                # cd + switch profile + start
cctrl @<name> -m "fix bug"  # with an initial prompt
cctrl @<name> --resume       # resume picker for that project
cctrl @                      # list shortcuts
cctrl shortcuts              # same listing, spelled out

cctrl @add myapp ~/dev/myapp --profile work
cctrl @add cctrl ~/dev/cctrl --agent codex
cctrl @rm myapp
```

### Peers

Peers are named coding agents that other cctrl workflows can address. The peer
registry combines manual entries from `data/peers.json` with live cctrl-managed
tmux sessions derived from `cctrl session ls --json`.

```bash
cctrl peer register comet --dir ~/dev/comet-automation --agent codex
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

Human `cctrl peer ls` shows each peer's backing `SESSION` and a live/offline
status by default, so the peer-to-session mapping is visible without `--json`.
Mailbox queue counts stay in `cctrl peer status`.

Peer names and aliases may contain letters, numbers, dots, underscores, and
dashes. Whitespace, shell metacharacters, and the reserved name `user` are
rejected. Peer state is machine-local. Tests and isolated workflows can set
`CCTRL_DATA_DIR` to move only peer-messaging runtime files; existing shortcuts,
hosts, profiles, and cost data keep using their normal cctrl paths.

#### Talking to a peer's live session

Because a peer resolves to a live tmux session, you can chat with it directly
the same way `session say` talks to a session — but addressed by peer name or
alias instead of a raw tmux target. This is **live tmux chat**, not mailbox
delivery: use `peer say` when the agent is running and you want it to act now,
and `peer send` (below) for durable, async work that should survive the
recipient being away.

```bash
cctrl peer session comet            # comet -> TMUX--comet   (its backing session)
cctrl peer session comet --json     # {ok, name, label, session, tmux_target, host, live, status}
cctrl peer attach comet             # attach to comet's live tmux session (interactive)
cctrl peer say comet -- "run the test suite and report back"
cctrl peer say comet --no-submit -- "draft reply, I'll hit enter"
cctrl peer say comet --json -- "status?"   # same result shape as session say
```

`peer say` resolves the peer/alias to a live local tmux session and delegates to
`session say`, sharing all of its flags (`--body-file PATH|-`, `--no-submit`,
`--json`, `--force-busy`) and its readiness/modal checks. Like `session say`, it
**never** writes `data/messages.jsonl`, changes mailbox status, or records nudge
metadata.

Peer host metadata is descriptive, not a transport. If a peer's `.host` is not
the current host label, `peer session`/`peer attach`/`peer say` fail with a hint
to run the command through the top-level `--host` layer
(`cctrl --host studio peer say comet -- ...`) rather than auto-SSHing from
registry metadata. `cctrl --host <host> peer attach <peer>` is forwarded as an
interactive, TTY-requesting command, the same as `session attach`. Peers with no
live session (polling/MCP-only) and stale recorded sessions fail with a clear
error.

#### Agent operating contract (`peer help-agent`)

Humans learn `peer say` from the examples above, but an agent needs a compact
contract telling it *when* to direct-chat a live peer and *when* to queue durable
async work. `cctrl peer help-agent` prints exactly that — distinguishing
`peer say` (live tmux chat), `peer send` (durable async), and the
`peer recv` / `peer ack` mailbox loop.

```bash
cctrl peer help-agent                 # generic guidance (no identity needed)
cctrl peer help-agent --as comet      # examples phrased for peer comet
CCTRL_PEER=comet cctrl peer help-agent # same, from the ambient identity
cctrl peer help-agent --json          # structured contract for prompt builders/tests
```

A bare `peer help-agent` prints generic guidance and never fails for a missing
identity; `--as NAME` and `CCTRL_PEER` canonicalize the peer through the same
resolver the mailbox and `peer say` use, then tailor the examples. The
**default rule** is: use `peer say` for a live tmux agent you want to act now,
and `peer send` for durable/offline async work.

This contract is **not** injected automatically. `cctrl start --peer` does not
add any prompt text; an agent receives the contract only when it asks
(`peer help-agent`), when a user prompt includes it, or through the MCP tool
descriptions. Automatic startup injection would change model behavior and prompt
size for every peer session, so it stays an explicit opt-in left to a future
plan rather than a hidden default here.

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

#### Sending and delivering in one step

A bare `peer send` only **queues**. Nothing reaches the recipient until a
delivery runs, and no watcher runs by default — so a send-only workflow silently
goes nowhere. Two commands close that gap:

```bash
cctrl peer send comet --as orchestrator --deliver --json -- "Please check XYZ"
cctrl peer reply msg_20260608_070000_abc123 --as comet --json -- "Checked, all green"
```

`--deliver` sends and then nudges in one command. `peer reply` goes further: it
resolves the recipient from the referenced message itself (via its `sender`
snapshot, falling back to a legacy bare `from`), sends, delivers, and acks the
original — so a replying agent never needs to know the sender's address. Pass
`--no-ack` to leave the original unacked. `--allow-unknown` cannot be combined
with `--deliver`.

Both report one of five named outcomes so a failure is never silent:

| Outcome | Exit | Meaning |
|---|---:|---|
| `sent-and-nudged` | 0 | queued and the recipient was nudged |
| `sent-and-queued` | 0 | queued; no delivery was requested |
| `send-failed` | ≠0 | nothing was written |
| `sent-but-undelivered` | ≠0 | the message is queued; delivery failed |
| `sent-but-deferred` | ≠0 | queued; delivery deferred (a modal was on screen) |

A delivery failure never rolls the send back. The message stays queued, and the
hint tells you to retry **delivery only** (`cctrl peer deliver comet`) — re-running
the whole command would send a duplicate.

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
cctrl start -d --peer comet ~/dev/comet-automation
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
because it pastes arbitrary message content into the target pane. The pasted
text is prefixed with a compact envelope carrying the sender's label and
canonical name, the message id, and ready-to-run `cctrl peer reply` and
`cctrl peer ack` commands; the original body follows verbatim. Inline delivery
also transitions the message to `delivered`, so it can then be acked. Messages
queued before the `sender` field existed carry only a bare `from` string, and
the envelope falls back to that.

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
manual-only because it sends arbitrary text into an interactive shell. Peer
names for derived peers are tmux session names, so an address can dangle once
that session closes; treat a received `sender` snapshot as historical and
verify liveness with `cctrl peer ls` before relying on it.

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
peer_overview
whoami
list_peers
resolve_peer
say_peer
send_message
check_messages
recv_message
show_message
ack_message
```

`say_peer` and `send_message` are the two ways to reach a peer, and the default
rule mirrors the CLI: use `say_peer` for a live tmux agent you want to act **now**
(direct chat, the tool-call form of `cctrl peer say`, no mailbox message), and
`send_message` for durable async work that must survive the recipient being
away/offline. `say_peer` takes `to` and `body` plus optional `submit` (defaults
to true; `submit:false` types a draft without pressing Enter) and `force_busy`
(override the readiness guard); the body is passed through
`cctrl peer say --body-file -` so multi-line and trailing-newline bodies are
preserved byte-for-byte. It fails rather than queueing when the peer has no live
local tmux session — fall back to `send_message` there.

`peer_overview` is the orientation entry point: one call returns your identity,
the reachable peers, and an unread-mailbox summary, so a model new to peer
messaging can start there instead of composing `whoami` + `list_peers` +
`check_messages`. It is a thin passthrough to the `cctrl peer overview [--as
NAME] [--json]` CLI subcommand, which serves all three answers from a single
session enumeration and is usable directly from the shell.

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
cctrl host add studio studio.local        # register a host
cctrl host add studio studio.local matt   # with explicit user
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

### Fleet view

`cctrl fleet` runs `session ls` on the local machine and on every host in
`data/hosts.json`, labels each row with its host, and sorts the merged result by
last-active, most recent first.

```bash
cctrl fleet                 # every host's sessions in one recency-sorted list
cctrl fleet --json          # same, machine-readable (adds a "host" field per row)
```

An unreachable host is marked `offline` inline and does not fail the command —
the overall exit stays 0, so a laptop that is asleep never breaks the view. A
host running an older cctrl that does not report last-active or STATE renders
those cells as `-` rather than dropping the rows. The local header also carries
a one-line resource summary (`mem … free · swap … used · load … · N sessions`),
with `n/a` for anything this platform cannot measure.

### What needs me

`cctrl needs-me` answers the narrower question: what changed since I last
looked?

```bash
cctrl needs-me              # sessions that NEWLY need attention
cctrl needs-me --json       # {name, from_state, to_state, last_active}
```

It diffs every session's current rich STATE against a snapshot from the previous
run and reports only the sessions that just entered an attention state
(`waiting-input`, `blocked-dialog`, `idle-done`). A session that was already
waiting last run is not re-flagged, so the digest stays short instead of
re-listing the same backlog every time. The first run has no snapshot and
therefore reports every current attention session, with `from_state` of `-`. It
is strictly read-only: it never closes, repairs, or otherwise mutates a session,
and the only thing it writes is its own snapshot file.

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

> Ships as the `cctrl-ports` **plugin** (`plugins/cctrl-ports`), not a core
> command. It is auto-dispatched like any other `cctrl-*` executable, so
> `cctrl ports` works out of the box, but it can be removed independently.

Track which ports have ever been in use on your machine and get clean suggestions. History accumulates across invocations.

```bash
cctrl ports                        # live scan + suggest free ports
cctrl ports --consecutive 4        # find 4 consecutive free ports
cctrl ports --check 3000,5432      # check if ports are safe to use
cctrl ports --kill 3000-3003       # kill processes on ports (SIGTERM)
cctrl ports --kill 3000 --force    # SIGKILL
cctrl ports --discover ~/dev       # scan project files for port references
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

## Directory scanning

> Also a **plugin** (`plugins/cctrl-scan`).

Survey a tree of projects: size, git state, and what is safe to delete.

```bash
cctrl scan                     # top-level subdirs, sorted by name
cctrl scan --large ~/dev       # top 20 largest dirs, up to 3 levels deep
cctrl scan --dirty             # only git repos with uncommitted changes
cctrl scan --secrets           # scan dirty repos for credential patterns
cctrl scan --clean             # find (and optionally delete) reclaimable dirs
cctrl scan --reclaimable       # also total up node_modules, .next, etc.
```

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
    peer-doorbell.sh       # Stop/Notification hook: exit 2 on queued peer mail
    session-log.py         # token tracking hook
    statusline.sh          # status bar + rate limit capture
  lib/
    usage_costs.py         # usage/cost aggregation for `cctrl usage` and `cctrl costs`
    peer_mcp.py            # stdio MCP server behind `cctrl peer mcp`
  plugins/
    cctrl-ports            # `cctrl ports` — port history and suggestions
    cctrl-scan             # `cctrl scan` — directory/repo survey
  skills/                  # bundled agent skills (cctrl-spawn, -session-end, -fleet-manager)
  completions/_cctrl       # zsh tab completion
  docs/                    # plans, debug reports, findings
  tests/run-tests.sh       # end-to-end suite (real binary, fixture dirs)
  costs/                   # session spending log (gitignored)
  data/                    # runtime data (gitignored)
```

## License

MIT
