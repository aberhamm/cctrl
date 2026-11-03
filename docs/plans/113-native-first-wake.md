---
id: 113
title: Native-first, per-agent opt-in wake (zero tokens while idle; mailbox stays the source of truth)
status: skipped
skipped: 2026-11-03
skipped-reason: "remaining asyncRewake wake-on-mail experiment moot: plan 114 gated push nudges an idle session in about 1 s; decision mdec-1103-cctrl-113-experiment-dropped"
blocked-by: []
priority: 30
allows-migrations: false
review-required: eng
created: 2026-10-30
approval: "mdec-1103-cctrl-113-experiment-dropped (2026-11-03, remaining experiment dropped as moot; nothing run or rolled back). Earlier: write-up under mdec-1030-cctrl-writeup-handoff, no build, install or experiment approved"
reviews: []
related: 108, 110, 111
---

## Outcome (2026-11-03, mdec-1103-cctrl-113-experiment-dropped)

The remaining asyncRewake wake-on-mail experiment (mdec-1030-cctrl-110-install-cap-113
item 5; "Next experiment" below) was SKIPPED on 2026-11-03 as moot. Plan 114's gated
push (option D, tmux paste through the plan 110 readiness checks) now reaches an idle
session: it was nudged in about 1 s (delivered ~13 s after queueing). STEP2 DELIVER
PASS, msg_20261103_000037_989991, 2026-11-03T00:00:38Z, adapter tmux. Nothing was run or rolled back for this plan; the
113 rewake hook is not installed. Option A is not built. The text below is kept as
the record of the write-up.

## Goal

Wake an agent when cctrl mail arrives, only for agents explicitly enabled, native
mechanisms first, and zero model tokens while idle. The cctrl mailbox remains the
durable source of truth (acks, per-sender attestation per plan 111, delivery
receipts). Native channels only ring the bell; the recipient reads mail with
`cctrl peer recv`.

## Findings

Sources: orch-cctrl-reports/native-messaging-research.md (docs fetched 2026-10-28,
Claude Code 2.1.290), 113-asyncrewake-design.md, 113-rewake-install.md / 113-rewake.log,
108-pilot-summary.md.

1. The 108 doorbell is a Stop hook. It fires only at the end of a turn, so it cannot
   wake an idle session; each ring costs one model turn. One ring in the pilot.
2. Claude Code inbox socket wakes idle sessions with no idle cost, but a session in
   bypass-permissions mode (every cctrl spawn) holds an unsolicited socket message
   behind an approval dialog (5 min expiry, then dropped) unless crossSessionInbound
   is `accept`. No per-sender allowlist exists.
3. asyncRewake command hooks (`async`, `asyncRewake`, exit 2 wakes even an idle
   session, stderr shown as a system reminder) work without crossSessionInbound,
   but the timeout is enforced (default 600 s), they are one-shot, and they are not
   supported on Stop/SubagentStop/TaskCompleted/TeammateIdle.
4. EXPERIMENT RESULT (2026-10-28). The hook was armed on UserPromptSubmit (script
   113-rewake.sh, self-scoped to TMUX--ms--orch-cctrl by `peer whoami`, lock file,
   540 s self-limit). It timed out twice at about 9 minutes: armed 09:25Z, timeout
   09:34:24Z; armed 09:34:58Z, timeout 09:44:02Z. A third arm happened 10-30 15:03:34Z
   and was rolled back 15:04:12Z. No mail arrived during any arm window, so
   WAKE-ON-MAIL IS STILL UNTESTED. What is established: it arms, it holds a lock,
   a second prompt does not double-arm ("skip lock-held"), and it exits cleanly at
   its limit.
5. Real limit shown by the experiment: re-arm happens only on a new prompt. After
   about 9-10 minutes with no prompt, an idle session is uncovered. Any design on
   asyncRewake alone needs a re-arm story (see options). Whether a wake turn itself
   re-fires UserPromptSubmit (and so re-arms) is undocumented and untested.
6. Codex has no asyncRewake analogue: notify is outbound-only and hooks cannot wake
   idle. The only native inbound path is app-server `turn/start` against the thread
   a `--remote` TUI is attached to (unverified that it renders and wakes).
7. Other native paths: plugin monitors (idle-wake unstated, test needed), Channels
   (per-sender auth first-class, but research preview and a dev-flag dialog), agent
   teams (not usable as a fleet bus).

## Options

A. asyncRewake blocked on the mailbox.
   Pro: zero idle tokens, no crossSessionInbound change, no security prompt, fully
   cctrl-controlled. Con: 600 s bound; arms only on a prompt; needs a re-arm design
   (candidates: re-arm from the wake turn's own UserPromptSubmit, a SessionStart arm
   for new spawns, or a cheap external re-prompt, each needs testing); hook config
   must be per-agent (project-local settings reach every session in that directory,
   so the script has to self-scope as the experiment did).
B. Inbox socket with per-spawn `--settings '{"crossSessionInbound":"accept"}'`.
   NOT PURSUED: Matthew declined crossSessionInbound for now. Noted for the record:
   it would give true idle wake, but any same-uid process could then wake that
   session, so the message would have to be a short notice with no authority.
C. Stop-hook doorbell (current, plan 108). Works, cheap, pilot-proven once. Covers
   mail that arrives during a turn only; cannot wake idle. Keep as the belt-and-braces
   layer.
D. Fleet-manager pane nudge (tmux paste into an idle pane, plan 110 readiness gated).
   Works today and wakes idle, but it costs a turn per nudge and depends on pane
   state; must follow plan 110 (no pushes into non-enabled panes).
E. Codex app-server (`--remote` TUI plus a cctrl-owned long-lived server). Zero idle
   tokens and real token auth, but requires launching every Codex session with
   `--remote` and an unverified wake path. Codex-only, later.

## Recommendation

Make the mailbox the only truth and add wake as a per-agent opt-in layered in this
order: (1) keep the Stop-hook doorbell (C) for in-turn mail; (2) for idle wake, run
the asyncRewake experiment properly (A), because it is the only native path that
needs no setting change and no dialog; (3) use the plan 110 gated pane nudge (D) as
the fallback for agents that never prompt; (4) leave B off. Opt-in is explicit: a
`cctrl peer doorbell enable --peer X` style switch that also installs the per-agent
wake hook, and `disable` that removes it. Do not build until the next experiment
shows wake-on-mail works and the re-arm story holds.

## Open questions

- Does exit 2 from an armed asyncRewake wake a genuinely idle session (not just one
  mid-turn), and does the wake turn re-fire UserPromptSubmit (self re-arm)?
- Is the timeout really enforced (the experiment says yes, the docs say not on async)?
- How to scope hooks to one agent without a shared project settings file (spawn-time
  `--settings` is the clean way; running sessions cannot be changed).
- Poll cost: the experiment script polled `cctrl peer check` every 5 s (about 108 cctrl
  invocations per 9 minutes); a fifo or `cctrl peer wait` would be cheaper.
- Does an unattended session stay idle past 10 minutes often enough to matter?
- Hourly ring cap (proposal in 108-pilot-summary.md: 4 per rolling hour per recipient)
  applies to wake rings as well.

## Next experiment (SKIPPED 2026-11-03 as moot; see Outcome)

Wake-on-mail inside an armed window. Re-create the 113 hook for one named agent, arm it
with one prompt, then within the 9-minute window send exactly one test message to that
agent, from a sender that did not use `--deliver`, and record: wake time, whether the
stderr text reached the model, whether a re-arm occurred, tokens used. Roll back
immediately afterwards (the rollback is in 113-rewake-install.md). Then repeat once
with the session idle for more than 10 minutes to confirm the documented uncovered gap.

## Dependencies

- Plan 110 install: D4 deferred until this plan is drafted and Matthew clicks. 110
  makes every push (including the fallback nudge) follow doorbell enablement.
- Plan 111 attestation: the mailbox read after a wake must verify the sender; the wake
  notice itself carries no authority.
- cctrl-spawn skill: add the step "enable doorbell/wake for this agent" (opt-in at
  spawn, off by default).
- No install, no widening of the bell, no crossSessionInbound change are part of this
  draft.
