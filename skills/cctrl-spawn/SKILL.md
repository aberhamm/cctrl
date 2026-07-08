---
name: cctrl-spawn
version: 1.0.0
description: Properly spin up a new cctrl-managed agent session from any repo — pick the runtime, create it detached, seed a brief, verify boot, and (optionally) open it in a terminal tab. Generic doctrine, no environment specifics.
triggers:
  - spin up a new session
  - spin up a session
  - launch a new agent session
  - open a new cctrl session
  - start a background agent
  - hand this off to a new session
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - AskUserQuestion
---

# cctrl-spawn

How to **properly** spin up a new `cctrl`-managed agent session — from whatever
repo you happen to be in. This is the reusable procedure; it is **generic
doctrine only** (no hostnames, aliases, ports, or GUI specifics).

Concrete environment bits — how to open a session in a terminal **tab**, the SSH
alias to reach the orchestrator host, the tmux socket setup, and the local
resource gate — live in a **private env brief**. Load it before the tab step:

> **Private env brief:** `~/dev/homelab/fleet/spawn-env.md` (adjust path to your
> setup). If it is missing, do the create step below and hand the user the
> `cctrl session attach <id>` command instead of opening a tab yourself.

## When a new session is the right tool

Spin up a session when the work is **durable, parallel, and human-watchable** —
something the user will consult with or that runs long. Do **not** spin up a
session for a quick, self-contained lookup or a one-shot transform: use a
sub-agent (the `Agent` tool) for that, or just do it inline. Sessions are
heavier than sub-agents; each one is a live tmux + agent process that consumes
memory and attention. One session = one purpose.

## The procedure

1. **Decide runtime + placement.** Pick the agent (`claude` for consultative /
   general work; `codex` when the user asks for it or wants an independent
   second engine). Pick the **explicit target directory** — the repo the work
   belongs to, not `$HOME`. Pick a short, descriptive `-n` label (the *purpose*;
   the tmux id is derived from the dir, not the label).

2. **Resource gate.** Before spawning, check memory pressure on the host (see the
   private env brief for the exact command). Gate on **free RAM %**, not session
   count — too many heavy sessions thrashed memory before. If pressure is high,
   say so and ask before adding another.

3. **Create it detached.** This is the robust path — create detached, then attach
   *after* it boots. Never launch an agent interactively straight into a tab (see
   Gotchas):

   ```
   cctrl start -d <dir> --agent <claude|codex> -n "<label>" [-m "<brief>"]
   ```

   - `-d` **requires** an explicit dir/shortcut — it refuses to default to
     `$HOME` (guardrail against dropping a full-access agent into `~/.ssh` etc.).
   - `-m "<brief>"` **auto-submits on boot**, so the session starts working
     immediately. Seed a brief to make it act; **omit `-m`** to leave it idle at
     the prompt for the user to drive.
   - A good brief states the task, the key files/context, the approach
     (investigate → propose → implement for anything non-trivial), and — for any
     **prod/live service** — a hard constraint: *edit freely, but do not
     restart/deploy/push without explicit go-ahead.*

4. **Verify boot.** Confirm it came up: `cctrl session ls` (or capture the pane).
   A live session shows a real state (`working`/`idle`/`waiting-input`). `codex`
   sessions report `(?)` model and `-` state with no telemetry — that is normal,
   not a failure. If the session vanished within ~15s, see Gotchas.

5. **Open it in a tab (optional).** If a human will watch/consult it, open a
   terminal tab that **attaches** to the now-live session, using the mechanism in
   your private env brief. Attaching to an already-booted session is rock-solid;
   confirm with `tmux list-clients -t <id>` afterward.

## Gotchas (generic — learned the hard way)

- **Detached-create + attach beats launch-in-tab, always.** Launching an agent
  interactively inside a fresh tab can have it exit the instant you attach mid-
  boot (especially `codex` — its TUI quits on a controlling TTY that changes
  under it at startup), and the session evaporates silently. Create detached, let
  it settle, then attach.
- **`-d` needs a dir.** No dir → guardrail refuses. Pass the repo path.
- **`-m` auto-submits.** It does not merely pre-fill — a seeded brief starts the
  agent. If you want the user to review before it runs, omit `-m`.
- **Never pipe `cctrl start` through `head`/`tail`** — SIGPIPE aborts the spawn.
- **Long briefs / apostrophes:** pass via a quoted heredoc into a shell var, or
  write to a file and load it — inline quoting breaks on apostrophes.
- **tmux ops may need the right socket** sourced first (env brief has the how).

## Discipline (make "properly" mean disciplined)

- One purpose per session; a clear `-n` label. Don't reuse a session for
  unrelated work.
- Prefer a sub-agent to a full session when the task is short and self-contained.
- Put prod-safety constraints in the brief for anything touching a live service.
- Clean up: `cctrl session prune` proposes stale sessions; close mis-spawns —
  but **look before you close** (check `git status` in its dir first; a session
  labelled "spare" may have accumulated uncommitted work).
