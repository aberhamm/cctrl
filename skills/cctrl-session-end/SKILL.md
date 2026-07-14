---
name: cctrl-session-end
version: 1.0.0
description: Gracefully wind down and close a cctrl-managed agent session — save state, check for uncommitted work, optionally hand off, then self-close. Generic doctrine, no environment specifics.
triggers:
  - end this session
  - close this session
  - wind down
  - wrap up and close
  - session is done
  - shut down this agent
allowed-tools:
  - Bash
  - Read
  - Write
  - AskUserQuestion
---

# cctrl-session-end

How to **properly** wind down a `cctrl`-managed agent session from the inside.
This is the counterpart to `cctrl-spawn` — spawn gets you in, this gets you out
cleanly. **Generic doctrine only** (no hostnames, paths, or env specifics).

## When to end a session

End when the work is **done and verified**, or when the session has hit a natural
stopping point (context limit, no further work, user said to close). Do **not**
end mid-task — finish or hand off first.

## Pre-close checklist

Run through this before closing. Every step is fast; skipping one is how work
gets lost.

### 1. Check for uncommitted work

```
git status
```

If there are uncommitted changes in the working directory:
- **Meaningful work:** commit it (with a clear message) or stash it. Never
  close with uncommitted work product sitting in the tree.
- **Scratch / experiments:** discard or stash. If uncertain, stash — it is
  cheap and reversible.
- **Not your repo / read-only session:** skip this step.

### 2. Check for unsent drafts or pending actions

If the session was drafting an email, PR, message, or any outward-facing
artifact that hasn't been sent/created yet — surface it to the user before
closing. Don't let drafts evaporate with the session.

### 3. Harvest the session (soft dependency — skip silently if absent)

Steps 1 and 2 catch what is *visible* in the tree. They cannot catch what only
this session knows: scaffolding it created that should now be deleted, work it
obsoleted, docs its own changes made wrong, a pitfall it hit and worked around,
a decision the user made that a future session would otherwise re-litigate. That
knowledge is about to be destroyed — a closing session is the last moment it
exists.

If an end-of-session harvest skill is installed, invoke it now. Probe for it;
**if it is not installed, skip this step silently** — never error, never mention
it. It is optional by design.

```bash
for _base in "${HOME}/.config/skillshare/skills" "${HOME}/.agents/skills" \
             "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -f "${_base}/mstack-wrap-up/SKILL.md" ] && { echo "harvest=available"; break; }
done
```

If it reports `harvest=available`, invoke `/mstack-wrap-up` and let it run to its
verdict. It is report-only: it never deletes, commits, or pushes, so it cannot
damage the tree you just cleaned in step 1.

**If the harvest routed a handoff, step 4 is already done — do not ask twice.**
The harvest skill offers a handoff as its own ending when it finds follow-on
work. A session that accepts that offer has already persisted its context, and
re-running `/context-save` or `/mstack-handoff` in step 4 would prompt the user
a second time for the same thing.

### 4. Save context (if there is follow-on work)

Skip this entirely if step 3's harvest already routed a handoff (see above).

Otherwise, if there is remaining work or the session was part of a larger effort:
- Use `/context-save` (if available) or `/mstack-handoff` to persist a
  resumable summary.
- If neither is available, print a concise handoff block to the console so the
  user can paste it into the next session.

If the session is truly done (all work complete, nothing to hand off), skip
this.

### 5. Report completion

State clearly what was accomplished and what (if anything) remains:
> Done — [one-line summary of what shipped/changed]. [Any follow-up needed.]

Keep it to one or two sentences. The user reads this in the pane capture after
the session is gone.

### 6. Self-close

```
cctrl close
```

This closes the tmux session the agent is running inside, with a 5-second grace
period (enough for the final output to render before the pane disappears). The
agent process terminates with the pane — no cleanup needed after this command.

**Do not use `cctrl session kill`** — that is an immediate hard kill with no
grace period, meant for external cleanup, not self-close.

## Fleet-manager integration

When running under a fleet manager, the **session-close gate** applies:

- **Work sessions** (produced code, commits, artifacts): the fleet manager
  surfaces the session as done and **leaves it open** for human review. The
  human says "close" — the fleet manager then tells you to end, or closes you
  remotely. You do not self-close without the human's word.
- **Ephemeral throwaways** (health probes, read-only scouts, validators with no
  work product): close freely — no gate needed.

If you are a fleet-managed work session that has finished: run steps 1–5 of the
checklist, report done, then **wait**. Do not `cctrl close` until the fleet
manager or human says to.

## Handoff-then-close (context limit)

When context is approaching ~200k and there is follow-on work:

1. Finish the current atomic unit of work (don't stop mid-task).
2. Run the pre-close checklist (steps 1–5).
3. Note that you are handing off due to context length.
4. `cctrl close` — the fleet manager or user spawns the continuation session
   with the handoff as its first prompt.

## Gotchas

- **`cctrl close` runs async.** The 5-second grace lets your final output
  print, but don't start new work after calling it — the pane dies in seconds.
  Make `cctrl close` the very last thing you do.
- **Check `git status` before closing.** A session labelled "spare" or
  "scratch" may have accumulated real uncommitted work. Look before you close.
- **Don't close someone else's session.** `cctrl close` (no args) is self-close
  only. To close another session, use `cctrl session close <name>` — but that
  is the fleet manager's job, not yours.
- **Pane capture is the only record.** After close, the only trace of what the
  session said is the tmux scrollback (if captured) and any commits/files it
  wrote. Make your completion report clear enough to stand alone.
