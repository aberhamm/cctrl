# cctrl

Computer Controller. Switch Claude Code settings profiles, track token usage, launch sessions, and audit your project directories.

## Install

Already symlinked:

```
~/.local/bin/cctrl -> ~/_projects/cctrl/cctrl
```

A Stop hook in each profile auto-logs token usage per session.

## Commands

### Profiles

```bash
cctrl ls                  # list profiles (* = active)
cctrl use <profile>       # switch ~/.claude/settings.json
cctrl switch <profile>    # alias for use
cctrl current             # show active profile + drift detection
cctrl save <name>         # snapshot current settings as a new profile
cctrl diff <profile>      # diff current settings vs a profile
cctrl edit <profile>      # open profile in $EDITOR
```

### Sessions

```bash
cctrl start               # launch claude --permission-mode bypassPermissions
cctrl start -p "fix bug"  # extra flags passed through
```

### Usage tracking

```bash
cctrl usage               # plan usage: rate limits + billing week breakdown
cctrl usage 4             # show 4 billing weeks (default: 2)
cctrl costs --today       # token usage: daily, by model, by project
cctrl costs --week        # (default)
cctrl costs --month
cctrl costs --all django  # filter by project name
cctrl log                 # per-session entries tagged with profile
```

`cctrl usage` shows your Claude subscription rate limits (5-hour and 7-day windows) plus token spend per billing week (resets Tuesday 4pm ET). Peak rate limit usage is tracked per week so you can see how close you got to your limits. Only applies to subscription profiles (Pro/Max) — API profiles are billed per-token.

`cctrl costs` parses raw session JSONLs from `~/.claude/projects/` for detailed token breakdowns (input, output, cache write, cache read) with estimated USD. No external API calls.

## How tracking works

1. Every profile includes a `Stop` hook that runs `hooks/session-log.py` after each assistant turn
2. The hook finds the current session JSONL, sums deduplicated token usage, and upserts to `costs/spending.jsonl` (one line per session, updated in place)
3. Every profile includes a statusline script (`hooks/statusline.sh`) that captures rate limit data from Claude Code on each update, writing to `data/rate-limits.json` (latest snapshot) and `data/rate-limits-history.jsonl` (full history)
4. `cctrl use` logs profile switches to the spending log
5. `cctrl costs` reads the raw session JSONLs for aggregate reporting
6. `cctrl usage` reads rate limit snapshots + history and session data for billing week breakdowns

## Switching profiles

```bash
# exit current session cleanly (Stop hook fires, logging final tokens)
/exit          # or Ctrl+D

# switch and start new session
cctrl use <profile>
cctrl start
```

Don't use Ctrl+C to exit — it interrupts but doesn't close the session. Double Ctrl+C force-kills and may skip the hook.

## Profiles

Stored in `profiles/*.json`. Each is a complete `settings.json` snapshot. Add profiles for different providers, API keys, model defaults, plugins, etc.

```bash
cctrl save personal       # save current settings as "personal"
cctrl use personal        # switch to it later
```

## Structure

```
cctrl/
  cctrl                  # main script (symlinked to ~/.local/bin)
  profiles/*.json        # named settings configs
  hooks/session-log.py   # Stop hook for token tracking
  hooks/statusline.sh    # statusline script (context bar + rate limit capture)
  costs/spending.jsonl   # session log (auto-maintained)
  data/rate-limits.json  # latest rate limit snapshot (auto-maintained)
  data/rate-limits-history.jsonl  # rate limit history (auto-maintained)
  plugins/               # drop-in subcommands (cctrl-<name>)
```

## Directory scanning

`cctrl scan` audits any directory — shows size, git status, tech stack, and last commit for every subdirectory. Works on project folders, download dirs, or anywhere else.

```bash
cctrl scan                       # scan current directory
cctrl scan ~/projects            # scan a specific directory
cctrl scan --large               # top 20 largest subdirs (3 levels deep)
cctrl scan --dirty               # git repos with uncommitted changes
cctrl scan --secrets             # scan dirty repos for hardcoded credentials
cctrl scan --clean               # find and optionally delete node_modules/.next/etc.
cctrl scan --reclaimable         # include reclaimable space total in summary
```

The tool auto-excludes the `cctrl` directory itself from results.

**Credential patterns detected:** Algolia, AWS, Mapbox, Stripe, Shopify, Bearer tokens, and generic `API_KEY`/`SECRET_KEY` patterns.

## Port tracking

`cctrl ports` tracks which ports have ever been in use on your machine and suggests clean ones — individually or as consecutive runs for multi-service projects. History accumulates across invocations and is supplemented by scanning project files.

### Live scan

```
$ cctrl ports

Port     Process              PID
────────────────────────────────────────
443      Wispr                2052
3000     node                 26975
3001     node                 6197
3002     node                 6407
3003     node                 7462
4100     node                 2716
6380     com.docke            58241
9000     com.docke            58241
────────────────────────────────────────
8 listening ports · 88 total ever seen

Free ports (never seen, 3000–9999)
────────────────────────────────────────
  3004  3005  3006  3007  3008  3009  3010  3011  3012  3013
```

### Consecutive ports

Find N consecutive free ports — useful when all your services need to run in a predictable block:

```
$ cctrl ports --consecutive 4

4 consecutive free ports (5 options, 3000–9999)
────────────────────────────────────────
  [1]  3004–3007  3004  3005  3006  3007
  [2]  3008–3011  3008  3009  3010  3011
  [3]  3012–3015  3012  3013  3014  3015
  [4]  3016–3019  3016  3017  3018  3019
  [5]  3020–3023  3020  3021  3022  3023

$ cctrl ports --consecutive 6 --options 3 --min 4000 --max 9000

6 consecutive free ports (3 options, 4000–9000)
────────────────────────────────────────
  [1]  4000–4005  4000  4001  4002  4003  4004  4005
  [2]  4006–4011  4006  4007  4008  4009  4010  4011
  [3]  4012–4017  4012  4013  4014  4015  4016  4017
```

Options are non-overlapping. Pick one and all N ports are guaranteed clear of history and well-known services.

### Discover ports from project files

Scans directories recursively for port references in `.env`, `Dockerfile`, `docker-compose.yml`, YAML/TOML configs, and source files — then adds them to history so they're never suggested:

```
$ cctrl ports --discover ~/_projects

Scanning /Users/matthew/_projects for port references...

myapp/.env
  5432   :3    DATABASE_PORT=5432
  3000   :4    PORT=3000

myapp/docker-compose.yml
  5432   :12   - '5432:5432'
  6379   :18   - '6379:6379'

myapp/src/server.ts
  3000   :41   .listen(3000, () => {

────────────────────────────────────────────────────────────
12 unique ports found across 8 files
  3000 3001 5432 6379 8080 ...

4 new (not yet in history): 5433 6400 8082 8443

Add to port history? [Y/n]
```

Use `-y` to skip the prompt (good for scripting):

```bash
cctrl ports --discover ~/_projects -y
```

**Patterns detected:**
- `PORT=3000`, `DB_PORT=5432` — env var assignments
- `EXPOSE 3000` — Dockerfile
- `"3000:3000"`, `- 3000:8080` — docker-compose port mappings
- `localhost:3000`, `127.0.0.1:8080` — URL references in source/config
- `port: 3000`, `port = 3000` — YAML/TOML/INI config keys
- `--port 3000` — CLI flag patterns in scripts
- `.listen(3000)` — Node.js source

**Skipped directories:** `node_modules`, `.git`, `__pycache__`, `.next`, `dist`, `build`, `vendor`, `target`, `.terraform`, and other generated dirs.

### Free ports from history

```
$ cctrl ports --free --ranges

Free ports (never seen, 3000–9999)
────────────────────────────────────────
  3004–3013  (10 ports)

$ cctrl ports --free --count 20 --min 8000 --max 8999
  8002  8003  8004  8005  8006  8007  8008  8009  8010  8011 ...
```

### History

```
$ cctrl ports --history

Port History  (88 unique ports across 7 scans)

  443  1024–1025  1080  1234  3000–3003  3722  4100  4321  5000
  5173  5432  6379–6380  7000  8000–8001  8080–8083  8443  8888
  9000–9001  11434  27017  ...

Recent Scans
  2026-03-20T10:32:49Z  443, 1025, 3000, 3001, 3002, 3003, ...
  2026-03-20T10:38:20Z  discover:_projects  (67 ports)
```

### Well-known ports

22 common service ports (MySQL, PostgreSQL, Redis, MongoDB, etc.) are always excluded from suggestions regardless of history. The full list:

```
$ cctrl ports --known

Well-known ports  (always excluded from suggestions)

Port    Service
───────────────────────────────────────────────
1433    SQL Server
1521    Oracle DB
3000    React/Rails dev server
3306    MySQL/MariaDB
4200    Angular dev server
5000    Flask/Sinatra
5173    Vite dev server
5432    PostgreSQL
5672    RabbitMQ
6379    Redis
6380    Redis alt
8000    Django/Python HTTP
8080    Alt HTTP/Tomcat/Jenkins
8443    Alt HTTPS
8888    Jupyter Notebook
9000    MinIO
9090    Prometheus
9200    Elasticsearch
...
───────────────────────────────────────────────
22 ports  ·  0–1023 system range also excluded
```

### Check ports

Verify whether specific ports are safe to use before committing to them. Each port is checked against all three layers:

```
$ cctrl ports --check 80,3000,3004,5432,8080,8200

Port    Status     Reason
───────────────────────────────────────────────────────────
80      avoid    root-only (0–1023)
3000    avoid    well-known: React/Rails dev server  ·  seen in history  ·  in use: node (26975)
3004    clear    not in use, history, or well-known list
5432    avoid    well-known: PostgreSQL  ·  seen in history
8080    avoid    well-known: Alt HTTP/Tomcat/Jenkins  ·  seen in history
8200    clear    not in use, history, or well-known list
───────────────────────────────────────────────────────────
Flags: root-only · well-known · seen in history · in use
```

Accepts the same port spec as `--kill`: single port, range, comma list, or mixed:

```bash
cctrl ports --check 3000
cctrl ports --check 3000-3003
cctrl ports --check 3000,5432,8080
cctrl ports --check 3000-3003,8080,9000
```

### Kill processes by port

```
$ cctrl ports --kill 3000

Port(s)              Process               PID  Signal
──────────────────────────────────────────────────────
3000                 node                26975  SIGTERM

Kill 1 process? [y/N] y

✓  node  pid 26975  port 3000

$ cctrl ports --kill 3000-3003

Port(s)              Process               PID  Signal
──────────────────────────────────────────────────────
3000                 node                26975  SIGTERM
3001, 3002           node                 6197  SIGTERM  ← same process, both ports
3003                 node                 6407  SIGTERM

Kill 3 processes? [y/N]
```

- Accepts: `3000` · `3000-3003` · `3000,3001,3005` · mixed `3000-3003,4321`
- Deduplicates PIDs — one process owning multiple ports is killed once
- Sends SIGTERM by default; use `--force` for SIGKILL
- Reports survivors after SIGTERM with a hint to use `--force`
- Use `-y` to skip confirmation

```bash
cctrl ports --kill 3000                # SIGTERM, confirm first
cctrl ports --kill 3000-3003 -y        # SIGTERM, no prompt
cctrl ports --kill 3000 --force        # SIGKILL
cctrl ports --kill 3000,3001,4321      # comma list
```

### Port ranges

Suggestions never include ports below 1024 (reserved, require root). The full userspace range is 1024–65535:

```bash
cctrl ports --free --min 1024          # full userspace range
cctrl ports --free --min 3000          # developer range (default)
cctrl ports --consecutive 4 --min 1024 --max 65535
```

### All commands

```bash
cctrl ports                              # live scan + show free ports
cctrl ports --consecutive N              # find N consecutive free ports (5 options)
cctrl ports --consecutive N --options K  # show K options instead of 5
cctrl ports --consecutive N --min M --max M  # scope the search range
cctrl ports --free                       # suggest free ports (no live scan)
cctrl ports --free --ranges              # group as contiguous ranges
cctrl ports --free --count N             # suggest N ports (default: 10)
cctrl ports --free --min M --max M       # scope the suggestion range (default: 3000–65535)
cctrl ports --check PORTS                # check if port(s) are safe: 3000  3000-3003  3000,3001
cctrl ports --kill PORTS                 # kill process(es): 3000  3000-3003  3000,3001
cctrl ports --kill PORTS --force         # SIGKILL instead of SIGTERM
cctrl ports --kill PORTS -y              # skip confirmation
cctrl ports --discover [dir]             # scan project files, add to history
cctrl ports --discover [dir] -y          # same, skip confirmation prompt
cctrl ports --history                    # show all ports ever seen
cctrl ports --known                      # list well-known exclusions
cctrl ports --reset                      # clear history
```

History is stored in `data/ports-seen.json`. Suggestions always exclude 0–1023 (root-only) and the 22 well-known service ports.

## Extending

Drop any executable named `cctrl-<cmd>` in `plugins/` or anywhere in PATH. It becomes a subcommand automatically:

```bash
# plugins/cctrl-backup → cctrl backup
```
