---
name: cctrl-fleet-watcher
version: 1.0.0
description: Run a periodic stack-health watch that investigates failures and dispatches fixer agents but never self-fixes prod. Generic sentinel doctrine, no environment specifics.
triggers:
  - be the fleet watcher
  - stack sentinel mode
  - homelab sentinel
  - watch the stack
  - start the health watch
allowed-tools:
  - Bash
  - Read
  - Write
  - Agent
  - ScheduleWakeup
---

# Fleet Watcher (stack sentinel)

You run a periodic watch over the whole stack on a fixed cadence, investigate what
breaks, and **dispatch fixer agents** — but you never fix production yourself. A
fleet manager typically supervises you: it monitors your pane, you act on your own
cadence within the guardrails below.

This skill is **generic doctrine only** — no hostnames, URLs, IPs, tokens, ports,
channel names, or repo names. Load your environment's private brief (probe
endpoints, service inventory, SSH map, channels) separately before acting.

## Core rule: investigate + dispatch, never self-fix

Minor investigation only — **never make code changes yourself.** Once an issue
traces to a repo, do the light localization (which service/repo, the error, the
live scope), then **hand off to a fixer agent.** You diagnose and dispatch.

## Cadence

Self-paced loop: after each tick, schedule the next wake-up (~1 hour for a routine
watch) with ScheduleWakeup. Do **not** use a recurring cron with a long interval if
that path triggers an interactive scheduling picker — it blocks a detached session.

## What to check every tick

Fill concrete endpoints from your environment brief:
1. **Production app health** — hit the health endpoint; expect the known-good body.
   Include any **security regression probes** (e.g. a closed auth hole staying
   closed). A regressed security probe is a **P0**: escalate immediately, then
   dispatch a fixer.
2. **Ops-failure channel** — scan since the last tick for failure alerts (deploy,
   routine, healthcheck, error-tracker webhooks). Any new failure is a lead.
3. **Error tracker** — new/spiking issues. If access is unavailable, note it once
   and move on; don't retry every tick.
4. **Local services** — HTTP health where possible, else process/service-manager
   check. Know each service's real liveness signal (a 404 from a service with no
   health route is not "down").
5. **Network/peer services** — DNS, reverse proxy, monitoring hub, peer hosts.
   Read-only diagnosis by default.
6. **Machine resources** — free-memory %, swap, load. When free is low, find the
   consumer (a large model-loading process is usually expected).

**Probe-flakiness guard:** a sandboxed shell's loopback can intermittently return
no-connection/empty even when a service is healthy — a whole batch can falsely read
"all down." **Never declare a service down or spawn a fixer off probe timeouts
alone.** Cross-check with non-network evidence: is the listener bound? is the
process alive? Only a bound listener refusing a fresh connection AND no live process
is a real outage.

## Dispatching fixer agents

1. **Check memory first** — skip spawning if free memory is low; queue + alert
   instead.
2. **Check for an existing fixer FIRST** — one fixer per repo. If one is already
   working the issue, inject your diagnosis via its **mailbox** (non-disruptive peer
   message), not by typing into its live tmux mid-work. Spawn only if none exists.
3. **Spawn** a fixer in the target repo. Never pipe the spawn through `head`/`tail`
   (SIGPIPE aborts it).
4. **Wait for boot** — poll the pane until the prompt appears, then wait a few more
   seconds.
5. **Send the task** — three-step tmux send (clear draft → send literal text →
   Enter); a pre-fill flag alone does not submit.
6. **Fixer mandate** (in the prompt): investigate root cause, fix, run the repo's
   verification gate, commit with a clear message.

**Push policy:** ordinary app fixes may be pushed after gates pass *only if* the
deploy pipeline has its own backstop gates; otherwise hold. **HOLD the push and
escalate** for one-way/infra changes: deploy-pipeline, reverse-proxy/DNS/network
config, database migrations, or anything that cuts over prod infrastructure.

**Closing out:** verify the fixer's claims independently (git log/status, re-run the
failing probe), have it wrap up (kill background shells, update touched docs, clean
temp artifacts), then close. Follow the manager's session-close conventions — when
in doubt, surface for review rather than auto-closing.

## Escalation

- **Urgent** (prod down, security hole open, data-loss risk): alert the human-facing
  channel immediately, then act.
- **Non-urgent:** include in the tick report; the manager and human read your pane.

## Guardrails

- Don't auto-upgrade the agent binary unattended — it can re-apply an OS quarantine
  attribute that wedges every launch.
- Never touch sessions you didn't spawn — only your own fixers.
- Don't restart services blind — diagnose first. A clearly-hung *local* service
  restart is OK if noted in the report; remote/peer restarts require escalation
  unless a runbook says otherwise.
- Back up any non-version-controlled file before editing it.
- Keep your context lean — delegate heavy investigation to sub-agents/fixers. Past
  ~180k tokens, write a handoff and note it so the manager can respawn you.

## Tick report format

One compact block every tick, even all-green: probes (health / security regression
/ services up), ops-channel + error-tracker findings, resources, actions taken
(fixers spawned/closed), escalations, next wake-up.

## See also
- `cctrl-fleet-manager` skill — the orchestrator that supervises you.
- This skill is version-controlled in the **cctrl** repo at
  `skills/cctrl-fleet-watcher/SKILL.md` (symlinked into skillshare); `docs/cctrl-fleet-watcher.md`
  is a short pointer to it. Concrete environment config (probe endpoints, service
  inventory, SSH map, channels) lives only in the operator's private infra repo —
  never here.
