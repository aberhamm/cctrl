# Claude Max Plan Rate Limits — Research & Data

**Last updated:** 2026-06-07  
**Account:** Claude Max 20x ($200/month), primarily Opus, two machines (MacBook Pro + Mac Studio)

---

## What We Found

### The core problem: no published baselines

Anthropic never publishes concrete token budgets. Rate limits are expressed as percentages (5-hour % and 7-day %) but Anthropic does not document what 100% maps to in tokens, dollars, or compute units. The "20x" in "Max 20x" is a tier multiplier vs. the Pro plan ($20/month) — it is not a dollar amount ($200 × 20 = $4,000 is wrong) and it is not tied to any published number.

This means the only way to reverse-engineer your actual limit is: **implied cap = estimated API cost ÷ (usage % / 100)**.

GitHub issue #54714 (April 2026) documents the same complaint: *"No published concrete token budgets, making it impossible to verify whether limits were actually changed."* Anthropic labeled it `stale` without responding.

---

## Data Collection Methodology

### What we track

- **`costs/spending.jsonl`** — persistent session log going back to March 10, 2026. One entry per session (upsert by session_id). Captures input, output, cache_write, cache_read tokens per session with model breakdown. As of commit `0d4fc66`, also captures subagent sessions.
- **`data/rate-limits-history.jsonl`** — rate limit % captured from Claude response headers on every assistant turn, going back to April 1, 2026. Format: `{ts, profile, five_hour, seven_day}`.
- **`data/rate-limits.json`** — current snapshot of rate limit state.

### Cost formula

Uses Anthropic published API pricing as a proxy:

| Model  | Input    | Output   | Cache Write | Cache Read |
|--------|----------|----------|-------------|------------|
| Opus   | $15/M    | $75/M    | $18.75/M    | $1.50/M    |
| Sonnet | $3/M     | $15/M    | $3.75/M     | $0.30/M    |
| Haiku  | $0.80/M  | $4/M     | $1/M        | $0.08/M    |

**Important:** Cache reads dominate cost. A typical session is 90%+ cache reads, which are cheap. The input/output numbers in the table look small; the large cache_read counts are where most of the API-equivalent value lives.

### Billing periods

Resets Thursday 6:00 AM Europe/Berlin. Implemented in `cctrl` as:
```python
from zoneinfo import ZoneInfo
TZ = ZoneInfo("Europe/Berlin")
# weekday 3 = Thursday
```

### Subagents

Subagent sessions are stored under `/subagents/` in `~/.claude/projects/`. They were silently excluded from all tracking until commit `0d4fc66` (2026-06-05), which fixed `hooks/session-log.py` to capture all recently-modified session files. Historical data in spending.jsonl (pre-fix) does not include subagents — estimated to be 10–35% of total token cost.

---

## Weekly Usage Data

All periods use Thursday 6am Berlin as the boundary. Usage % = peak 7-day rate limit reading during that period. Implied cap = Est. Cost ÷ (Usage% / 100). Rows without % have no rate-limit history data.

| Period          | Usage % | Tokens In  | Tokens Out | Est. Cost | Implied Cap |
|-----------------|---------|-----------|-----------|-----------|-------------|
| Mar 5 – 11      | —       | 67K       | 1.6M      | $206      | —           |
| Mar 12 – 18     | —       | 203K      | 6.3M      | $1,859    | —           |
| Mar 19 – 25     | —       | 161K      | 5.3M      | $4,457    | —           |
| Mar 26 – Apr 1  | 77%     | 159K      | 4.4M      | $4,538    | ~$5,890     |
| Apr 2 – 8       | 84%     | 97K       | 2.8M      | $2,515    | ~$2,990     |
| Apr 9 – 15      | 80%     | 59K       | 4.2M      | $3,235    | ~$4,040     |
| Apr 16 – 22     | 85%     | 77K       | 4.9M      | $3,535    | ~$4,160     |
| Apr 23 – 29     | 94%     | 58K       | 7.3M      | $4,782    | ~$5,090     |
| Apr 30 – May 6  | 71%     | 103K      | 8.5M      | $5,822    | ~$8,200     |
| May 7 – 13      | 75%     | 40K       | 3.7M      | $1,772    | ~$2,360     |
| May 14 – 20     | 95%     | 132K      | 9.3M      | $5,682    | ~$5,980     |
| May 21 – 27     | 100%    | 306K      | 8.7M      | $4,296    | ~$4,300     |
| May 28 – Jun 4  | ~73%    | 407K      | 9.6M      | $5,927    | ~$8,120     |
| Jun 4 – 7 (~3d) | 100%    | 420K      | 4.6M      | $2,730    | ~$2,730     |

**Notes:**
- Jun 4–7: Hit 100% in ~3 days (not a full week). Monthly spend cap also exhausted (incl. $20 overage buffer).
- May 28–Jun 4: A mid-week reset was observed live on Mon Jun 1 — rate limit counter dropped to ~0 then resumed accumulating. Cause unknown.
- The two confirmed 100% hits (May 21–27 and Jun 4–7) are the most reliable implied-cap readings. They show $4,300 → $2,730, a ~37% drop — but the Jun period was only 3 days, so usage intensity may be the variable, not cap reduction.

---

## Anthropic Rate Limit Event Timeline

| Date | Event | Announced? |
|------|-------|-----------|
| Dec 2025 | Holiday 2x promotion begins | Yes |
| Jan 2026 | Holiday promotion ends, limits revert | No (silent) |
| Feb 27 | Prompt caching bug causes phantom usage drain; limits reset | Yes |
| Mar 13–28 | Temporary 2x off-peak promotion | Yes |
| Mar 23 | Peak-hours throttle introduced (5am–11am PT / 1pm–7pm GMT weekdays) | No — confirmed ~3 days later after press coverage |
| Apr 1 | Claude Code v2.1.89 — suspected token accounting change causes limits to drain in ~70 min | No |
| Apr 23 | Postmortem + v2.1.116 fix | Yes |
| May 6 | 5-hour limits doubled for Pro/Max/Team; peak-hour throttling removed. Tied to SpaceX 220K GPU deal. | Yes |
| May 13 | Additional 50% weekly limit increase, through Jul 13. Framed as anti-Codex competitive move. | Yes |
| May 15 | Manual reset of all 5-hour and weekly limits for all users | Yes |
| May 28–29 | Billing/subscription management incident on claude.ai | Yes (status page) |
| Jun 1 | Mid-week rate limit reset (observed live, cause unknown) | No |
| Jun 2 | June 15 billing split announced | Yes |
| Jun 5–7 | Elevated API errors on Opus models | Yes (status page) |

**Pattern:** Limit increases are announced proactively. Limit reductions or silent tightenings are confirmed only after users surface complaints publicly — or never confirmed at all.

---

## Community Complaints (Corroborated)

Multiple GitHub issues, press coverage, and forum posts corroborate this experience:

- **GitHub #41788** (Apr 1): Max 20x limits exhausted in ~70 minutes post v2.1.89. Never explained.
- **GitHub #54714** (Apr 28): Max 20x hitting limits with reduced usage vs prior weeks. Same workflow, same model. Issue labeled `stale`.
- **GitHub #41212**: Rate limited at 18% usage on Max 20x, non-peak hours.
- **GitHub #41084**: "Phantom usage" — 0% daily but 41% weekly, rate limited with no activity.
- Press: MacRumors, The Register, gHacks, piunikaweb all covered the March peak-hours throttle.

---

## The June 15 Billing Split (Likely Not Relevant to Interactive Claude Code)

Starting June 15, 2026, **programmatic usage** moves to a separate monthly credit pool at full API rates:
- Max 20x: $200/mo in API credits

Programmatic = Agent SDK, `claude -p` (non-interactive), Claude Code GitHub Actions, third-party agents.

Interactive Claude Code sessions (human at terminal, spawning subagents within a session) almost certainly remain on the flat subscription. This change targets automated pipelines, not interactive use. Pre-change, heavy programmatic users were reportedly extracting ~$35,000/month equivalent value for $200/mo.

---

## Key Takeaway for Post Framing

The strongest defensible claim isn't "40% reduction" (hard to prove, noisy data). It's:

> **Anthropic doesn't publish what you're paying for. The "20x" in Max 20x has no documented baseline. The only way to know your limit is to hit it — and that limit has changed multiple times in 2026 with no announcement.**

The data supports this. The GitHub issues corroborate it. The Anthropic response pattern (announce increases, go silent on decreases) reinforces it.

---

## Files

| File | Description |
|------|-------------|
| `costs/spending.jsonl` | Session token log, back to Mar 10 2026 |
| `data/rate-limits-history.jsonl` | Per-turn rate limit % history, back to Apr 1 2026 |
| `data/rate-limits.json` | Current rate limit snapshot |
| `drafts/reddit-post.html` | Dark-themed HTML table + chart for screenshot |
| `hooks/session-log.py` | Stop hook that writes to spending.jsonl (includes subagents as of 0d4fc66) |
