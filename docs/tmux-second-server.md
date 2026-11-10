# A second tmux server (tmuxServer)

Approval: mdec-1110-fleet-tmux-from-terminal. User-facing summary: README, "A second tmux
server (`tmuxServer`)" under Tmux sessions.

## Setting

| Where | Example | Notes |
|---|---|---|
| env | `CCTRL_TMUX_SERVER=fleet` | wins over every config file |
| config key | `{"tmuxServer": "fleet"}` | `data/config.local.json` > `~/.config/cctrl/config.json` > `data/config.json` |
| extra read-only servers | `{"tmuxExtraServers": ["old"]}` or `CCTRL_TMUX_EXTRA_SERVERS=old` | names or paths, comma separated (no globbing; a path may contain spaces) |
| placeholder sessions | `{"tmuxPlaceholderSessions": ["fleet-anchor"]}` or `CCTRL_TMUX_PLACEHOLDER_SESSIONS=fleet-anchor` | default `fleet-anchor`; `""` = none |
| primary-down hint | `{"tmuxPrimaryStartHint": "..."}` or `CCTRL_TMUX_PRIMARY_START_HINT=...` | the "how to start it" text in the refusal below |

`fleet` means `tmux -L fleet`, the socket `${TMUX_TMPDIR:-/tmp}/tmux-$UID/fleet`. A value
containing `/` is a socket path (`tmux -S PATH`); its directory is resolved to the physical
path (`/tmp/...` and `/private/tmp/...` are one server), and servers are deduplicated by
physical socket. `"tmuxServer": ""` in a higher-precedence
file turns it off for that host. An unusable value (whitespace, `.`) is ignored with a warning
and cctrl stays on plain tmux.

## Behaviour

Unset: cctrl defines no `tmux()` function and every call is the plain binary, with no -L/-S.

Set: `tmux` inside cctrl is a router (`_tmux_routed`, `_tmux_route` in `cctrl`):

| Call | Server |
|---|---|
| `new-session` | primary |
| `list-sessions`, `list-clients`, `list-panes -a`, `list-windows -a` | union of every live server |
| `-t NAME`, `-t =NAME[:...]` | the server that holds that session (probe primary first) |
| `-t %N`, `$N`, `@N`, untargeted | a caller pin, else the `$TMUX` server inside tmux, else the primary |
| caller's own `-L`/`-S`; the server start and stop commands | passed through untouched |

Servers read: the primary, the `$TMUX` server, the default server (`tmux-$UID/default`) and the
extras, deduplicated. Pins: `_tmux_with_pin NAME cmd...` wraps close, kill, release-to-app and the
paste paths; stop-exact pins by the `@cctrl_server_instance_id` its execution id names; the
attest probe (`_session_tmux_host_command`) runs `run-shell` on the session's server. Pane and
`$N` ids repeat across servers, so the whois pane check matches session and pane id together.
`exec tmux attach` and the perl-alarm call sites build their argv with `_tmux_argv`.

Python helpers that cctrl runs (`terminal_identity.py`, `helper_census.py`,
`release_prune.py`) read the resolved primary from `_CCTRL_TMUX_PRIMARY` through
`lib/tmux_servers.py`. cctrl removes that variable from the environment of `new-session`, so
a server cctrl starts never inherits it.

`session ls --json` rows and snapshot task rows carry `tmux_server` (`fleet`, `default` or a
path) only when a primary is set. No field = the default server.

## cctrl never starts the primary server

The primary must be started outside cctrl, from Terminal or its login item, so the server
gets that app's TCC context and a clean global environment. A server started from an agent
pane would get the pane's responsible app and inherit the pane's whole environment.

So a routed `new-session` (every launch path: `cctrl start`, spawns, shortcuts, restore)
refuses when the primary is not running. `cctrl start` checks before it writes anything; the
router checks again at `new-session`. With tmux 3.2 or later the call also carries tmux's
own `-N` ("do not start the server"), so a server that dies between the check and the call
still fails closed. Older tmux gets the check only. The refusal is one stderr line and exit
69, and no socket is created:

```
cctrl: the primary tmux server 'fleet' (/private/tmp/tmux-501/fleet) is not running and cctrl will not start it; it must be started from Terminal, not by cctrl: launchctl kickstart gui/$(id -u)/com.fleet-tmux-terminal, or double-click ~/scripts/fleet-tmux/start-fleet-tmux.command; runbook ~/dev/homelab/docs/runbooks/fleet-tmux-terminal.md
```

The text after the last colon is the default hint (the runbook lives in the homelab repo,
not here); set `tmuxPrimaryStartHint` / `CCTRL_TMUX_PRIMARY_START_HINT` to replace it.
The read paths (list, has-session, display, show-options, the python helpers'
list-sessions) never start a server. With tmuxServer unset nothing changes: plain
`tmux new-session` starts the default server as it always did.

## Placeholder sessions (server keeper)

A session such as `fleet-anchor` that only keeps the fleet server alive is a placeholder.
With a primary set, a session named in `tmuxPlaceholderSessions` (default `["fleet-anchor"]`):

- is not listed by `session ls` (human or `--json`), so it is not a worker, not in
  `peer ls`, and not snapshotted;
- does not count in the `tmux servers:` line or `session servers` counts;
- is never a prune candidate and does not count toward prune's cap;
- is never restored into (a snapshot row naming it is demoted with reason
  "tmux placeholder session (server keeper)"), and `cctrl start` refuses that name;
- is refused by `session close` and `session kill` unless `--force`, with a message that it
  is the server keeper (`prune --yes` goes through close, so it is refused there too).

`session attach fleet-anchor` still works.

## Duplicate names

New names must be free on every server, but a duplicate can still appear (a manual
`tmux -L fleet new -s X`, another TMUX_TMPDIR). When a session name exists on more than one
server, `session close NAME`, `session stop NAME` (close's alias), `session kill NAME` and
`prune --yes` refuse with rc 75 and an error naming every server that holds it. Self-close
(`cctrl close` with no name) sends every call about the caller's own session to the `$TMUX`
server, so the copy elsewhere is never touched. `stop-exact` is unaffected: its execution id
names the server instance.

## Performance

`session ls` and `prune` prime a name->server map with one `list-sessions` per server, so
each per-row named call routes with no probe. The map lives `CCTRL_TMUX_ROUTE_CACHE_SECONDS`
(default 5) and is dropped when the same shell runs `new-session`, `kill-session` or
`rename-session`, or when `$TMUX` changes. A name missing from the map is probed live on every
server. Destructive actions resolve holders live, never from the map. The server list itself
is computed once per process (again only if `$TMUX` changes).

Timeout-wrapped calls (`_tmux_run_with_timeout`) resolve the server in the background job and
then `exec` the real tmux client, so a timeout kill reaches the client itself.

## Inspect

`cctrl session servers [--json]`: the primary, its source, each server's roles (primary,
default, current, extra), whether it runs, and its session count. `session ls` ends with the
same line and `session doctor` starts with it.

## Rollback

Unset `tmuxServer` / `CCTRL_TMUX_SERVER`. While sessions still run on the named server,
`"tmuxServer": "default"` with `"tmuxExtraServers": ["fleet"]` sends new sessions back to the
default server and keeps the named one visible until it drains. cctrl never stops or restarts
a tmux server for any of this.
