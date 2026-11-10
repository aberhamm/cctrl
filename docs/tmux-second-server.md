# A second tmux server (tmuxServer)

Approval: mdec-1110-fleet-tmux-from-terminal. User-facing summary: README, "A second tmux
server (`tmuxServer`)" under Tmux sessions.

## Setting

| Where | Example | Notes |
|---|---|---|
| env | `CCTRL_TMUX_SERVER=fleet` | wins over every config file |
| config key | `{"tmuxServer": "fleet"}` | `data/config.local.json` > `~/.config/cctrl/config.json` > `data/config.json` |
| extra read-only servers | `{"tmuxExtraServers": ["old"]}` or `CCTRL_TMUX_EXTRA_SERVERS=old` | names or paths, comma separated |

`fleet` means `tmux -L fleet`, the socket `${TMUX_TMPDIR:-/tmp}/tmux-$UID/fleet`. A value
containing `/` is a socket path (`tmux -S PATH`). `"tmuxServer": ""` in a higher-precedence
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

## Inspect

`cctrl session servers [--json]`: the primary, its source, each server's roles (primary,
default, current, extra), whether it runs, and its session count. `session ls` ends with the
same line and `session doctor` starts with it.

## Rollback

Unset `tmuxServer` / `CCTRL_TMUX_SERVER`. While sessions still run on the named server,
`"tmuxServer": "default"` with `"tmuxExtraServers": ["fleet"]` sends new sessions back to the
default server and keeps the named one visible until it drains. cctrl never stops or restarts
a tmux server for any of this.
