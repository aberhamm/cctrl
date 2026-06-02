---
id: 001
title: Add --host flag and host registry for remote cctrl execution over SSH
status: done
completed: 2026-06-01
reviewed: false
qa: automated,verified
blocked-by: []
priority:
allows-migrations: false
needs-review: none
created: 2026-05-31
---

## Requirements

When running cctrl from the MacBook, users need to execute commands on remote
machines (e.g., Mac Studio) without manually SSH-ing in. The `--host` flag
makes any cctrl command run on a named remote host transparently over SSH.

**Acceptance criteria:**

- [ ] `cctrl host add studio ms-128g-bln` saves the host to `data/hosts.json`
- [ ] `cctrl host list` shows registered hosts
- [ ] `cctrl host rm studio` removes a host
- [ ] `cctrl host doctor studio` checks SSH, remote cctrl, tmux, claude presence and offers to fix missing packages
- [ ] `cctrl --host studio start -d @homelab` creates a detached session on the remote host
- [ ] `cctrl --host studio session ls` lists remote detached sessions
- [ ] `cctrl --host studio session attach homelab` attaches interactively (TTY)
- [ ] `cctrl --host studio costs --week` shows remote cost data
- [ ] Commands fail fast with actionable error if remote cctrl is missing

## Design

Architecture: thin SSH proxy with a local host registry. `--host` is a global
pre-dispatch flag parsed before any subcommand. It resolves the host alias,
decides whether TTY is needed, quotes the remaining args, and forwards via SSH.

The remote machine owns its own shortcuts, profiles, costs, and tmux sessions.
No sync. Each machine is its own source of truth.

**Files expected to change:**

- `cctrl`: add `--host` global arg parsing at top of dispatch, `cmd_host`
  subcommand with add/list/rm/doctor, TTY detection helper
- `data/hosts.json`: new file (gitignored — machine-local)
- `completions/_cctrl`: add host subcommand completions + host name completion
- `README.md`: document the host feature
- `.gitignore`: add `data/hosts.json` if not already covered

**TTY rules:**

- Interactive commands (`session attach`, `start`, `start -d` auto-attach, `@shortcut`, `edit`) use `ssh -t`
- Non-interactive (`session ls`, `session kill`, `costs`, `usage`, `ls`) use plain `ssh`

**`host doctor` auto-fix scope:**

1. Check SSH connectivity
2. Check `brew` in PATH (fix: add to `~/.zprofile`)
3. Check `tmux` installed (fix: `brew install tmux`)
4. Check `claude` installed (fix: `brew install claude-code`)
5. Check `cctrl` available (fix: clone repo + symlink)
6. Check `~/.tmux.conf` exists (fix: scp from local)

**`hosts.json` schema:**

```json
{
  "studio": {
    "hostname": "ms-128g-bln",
    "user": ""
  }
}
```

`hostname` is the SSH target (hostname, IP, or Tailscale name). `user` is
optional (defaults to current user, uses `~/.ssh/config` when set). The
registry stores nothing sensitive.

**Arg quoting:** Use `printf '%q'` on each forwarded argument (same pattern
as the detached launch). Handles spaces, quotes, and bash specials in paths like Obsidian vault.

**Out of scope:** shortcut syncing, profile syncing, multi-hop SSH, SSH key
management, non-macOS remote hosts.

## Tasks

1. Add `data/hosts.json` to `.gitignore`
2. Add `_hosts_init`, `_host_lookup` helper functions (similar to shortcuts pattern)
3. Implement `cmd_host` with `add`, `list`, `rm`, `doctor` subcommands
4. Add `--host` parsing to the main dispatch block (before subcommand routing)
5. Implement `_remote_exec` helper: resolve host, decide TTY, quote args, ssh
6. Implement `host doctor` with connectivity checks and interactive auto-fix
7. Update zsh completions for `host` subcommand and `--host` flag
8. Update README with host feature documentation
9. Test: `cctrl host add studio ms-128g-bln && cctrl --host studio session ls`

## Verification

Checks:
- [cmd] `bash -n cctrl` (syntax check passes)
- [cmd] `grep -q 'cmd_host' cctrl` (host command exists)
- [cmd] `grep -q '\-\-host' cctrl` (global flag is parsed)
- [assert] `cctrl host add test-host localhost && cctrl host list | grep test-host` (registry works)
- [cmd] `cctrl host rm test-host` (cleanup)
- [cmd] `grep -q 'host' completions/_cctrl` (completions updated)

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | - | - |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | CLEAR | Design validated, thin-proxy architecture confirmed |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 1 issue (arg quoting), resolved |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | - | N/A (CLI tool) |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | - | - |

- **VERDICT:** ENG CLEARED. Ready to implement.
