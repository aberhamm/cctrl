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
cctrl start               # launch claude --dangerously-skip-permissions
cctrl start -p "fix bug"  # extra flags passed through
```

### Usage tracking

```bash
cctrl costs --today       # token usage: daily, by model, by project
cctrl costs --week        # (default)
cctrl costs --month
cctrl costs --all django  # filter by project name
cctrl log                 # per-session entries tagged with profile
```

Costs are parsed from `~/.claude/projects/*/*.jsonl` session files (input, output, cache write, cache read tokens) with estimated USD. No external API calls.

## How tracking works

1. Every profile includes a `Stop` hook that runs `hooks/session-log.py` after each assistant turn
2. The hook finds the current session JSONL, sums deduplicated token usage, and upserts to `costs/spending.jsonl` (one line per session, updated in place)
3. `cctrl use` logs profile switches to the same file
4. `cctrl costs` reads the raw session JSONLs for aggregate reporting

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
  cctrl              # main script (symlinked to ~/.local/bin)
  profiles/*.json    # named settings configs
  hooks/session-log.py  # Stop hook for token tracking
  costs/spending.jsonl  # session log (auto-maintained)
  plugins/           # drop-in subcommands (cctrl-<name>)
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

## Extending

Drop any executable named `cctrl-<cmd>` in `plugins/` or anywhere in PATH. It becomes a subcommand automatically:

```bash
# plugins/cctrl-backup → cctrl backup
```
