#!/usr/bin/env python3
"""Usage and cost reporting for cctrl.

Parses Claude Code session JSONL files and Codex session JSONL files. Codex
costs are API-equivalent estimates from local token counters; ChatGPT-plan
sessions may consume included plan usage instead of API billing.
"""

from __future__ import annotations

import bisect
import glob
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo


TZ = ZoneInfo("Europe/Berlin")
HOME = str(Path.home())
LONG_CONTEXT_THRESHOLD = 272_000


ANTHROPIC_PRICING = {
    "input": {
        "opus": 15.0,
        "claude-opus": 15.0,
        "sonnet": 3.0,
        "claude-sonnet": 3.0,
        "haiku": 0.80,
        "claude-haiku": 0.80,
    },
    "output": {
        "opus": 75.0,
        "claude-opus": 75.0,
        "sonnet": 15.0,
        "claude-sonnet": 15.0,
        "haiku": 4.0,
        "claude-haiku": 4.0,
    },
    "cache_write": {
        "opus": 18.75,
        "claude-opus": 18.75,
        "sonnet": 3.75,
        "claude-sonnet": 3.75,
        "haiku": 1.0,
        "claude-haiku": 1.0,
    },
    "cache_read": {
        "opus": 1.50,
        "claude-opus": 1.50,
        "sonnet": 0.30,
        "claude-sonnet": 0.30,
        "haiku": 0.08,
        "claude-haiku": 0.08,
    },
}


# USD per 1M tokens. Keep specific aliases before broader prefixes.
OPENAI_PRICING = [
    ("gpt-5.5-pro", {"input": 30.0, "cached": None, "output": 180.0, "long_input": 60.0, "long_cached": None, "long_output": 270.0}),
    ("gpt-5.5", {"input": 5.0, "cached": 0.50, "output": 30.0, "long_input": 10.0, "long_cached": 1.0, "long_output": 45.0}),
    ("gpt-5.4-mini", {"input": 0.75, "cached": 0.075, "output": 4.50}),
    ("gpt-5.4-nano", {"input": 0.20, "cached": 0.02, "output": 1.25}),
    ("gpt-5.4-pro", {"input": 30.0, "cached": None, "output": 180.0, "long_input": 60.0, "long_cached": None, "long_output": 270.0}),
    ("gpt-5.4", {"input": 2.50, "cached": 0.25, "output": 15.0, "long_input": 5.0, "long_cached": 0.50, "long_output": 22.50}),
    ("gpt-5.3-codex", {"input": 1.75, "cached": 0.175, "output": 14.0}),
    ("gpt-5.2-codex", {"input": 1.75, "cached": 0.175, "output": 14.0}),
    ("gpt-5.1-codex-mini", {"input": 0.25, "cached": 0.025, "output": 2.0}),
    ("gpt-5.1-codex-max", {"input": 1.25, "cached": 0.125, "output": 10.0}),
    ("gpt-5.1-codex", {"input": 1.25, "cached": 0.125, "output": 10.0}),
    ("gpt-5-codex", {"input": 1.25, "cached": 0.125, "output": 10.0}),
    ("codex-mini-latest", {"input": 1.50, "cached": 0.375, "output": 6.0}),
    ("gpt-5-mini", {"input": 0.25, "cached": 0.025, "output": 2.0}),
    ("gpt-5-nano", {"input": 0.05, "cached": 0.005, "output": 0.40}),
    ("gpt-5", {"input": 1.25, "cached": 0.125, "output": 10.0}),
]


def parse_ts(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        # Claude often stores milliseconds; Codex rate-limit resets are seconds.
        if value > 10_000_000_000:
            value = value / 1000
        return datetime.fromtimestamp(value, tz=timezone.utc)
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def billing_period_start(dt):
    """Find the most recent Thursday 6:00 AM Europe/Berlin before dt."""
    dt_tz = dt.astimezone(TZ)
    days_since_thu = (dt_tz.weekday() - 3) % 7
    thu = dt_tz - timedelta(days=days_since_thu)
    reset = thu.replace(hour=6, minute=0, second=0, microsecond=0)
    if dt_tz < reset:
        reset -= timedelta(days=7)
    return reset


def fmt(n):
    return f"{int(n):,}"


def usd(n):
    return f"${n:,.2f}"


def empty_totals():
    return {
        "input": 0,
        "output": 0,
        "cache_write": 0,
        "cache_read": 0,
        "reasoning": 0,
        "cost": 0.0,
        "turns": 0,
    }


def add_to(bucket, key, usage, cost):
    if key not in bucket:
        bucket[key] = empty_totals()
    d = bucket[key]
    d["input"] += usage["input"]
    d["output"] += usage["output"]
    d["cache_write"] += usage["cache_write"]
    d["cache_read"] += usage["cache_read"]
    d["reasoning"] += usage.get("reasoning", 0)
    d["cost"] += cost
    d["turns"] += 1


def anthropic_price_key(model_name):
    m = (model_name or "").lower()
    for key in ["opus", "sonnet", "haiku"]:
        if key in m:
            return key
    return "sonnet"


def openai_rates_for(model_name, raw_input_tokens):
    m = (model_name or "").lower()
    for prefix, rates in OPENAI_PRICING:
        if m.startswith(prefix):
            if raw_input_tokens > LONG_CONTEXT_THRESHOLD and "long_input" in rates:
                return {
                    "input": rates["long_input"],
                    "cached": rates.get("long_cached"),
                    "output": rates["long_output"],
                }
            return rates
    return {"input": 1.25, "cached": 0.125, "output": 10.0}


def estimate_cost(agent, model, usage):
    if agent == "codex":
        raw_input = usage["input"] + usage["cache_read"]
        rates = openai_rates_for(model, raw_input)
        cached_rate = rates["input"] if rates.get("cached") is None else rates["cached"]
        return (
            usage["input"] * rates["input"]
            + usage["cache_read"] * cached_rate
            + usage["output"] * rates["output"]
        ) / 1_000_000

    price_key = anthropic_price_key(model)
    ip = ANTHROPIC_PRICING["input"].get(price_key, 3.0)
    op = ANTHROPIC_PRICING["output"].get(price_key, 15.0)
    cwp = ANTHROPIC_PRICING["cache_write"].get(price_key, 3.75)
    crp = ANTHROPIC_PRICING["cache_read"].get(price_key, 0.30)
    return (
        usage["input"] * ip
        + usage["output"] * op
        + usage["cache_write"] * cwp
        + usage["cache_read"] * crp
    ) / 1_000_000


def normalize_claude_usage(raw):
    return {
        "input": int(raw.get("input_tokens", 0) or 0),
        "output": int(raw.get("output_tokens", 0) or 0),
        "cache_write": int(raw.get("cache_creation_input_tokens", 0) or 0),
        "cache_read": int(raw.get("cache_read_input_tokens", 0) or 0),
        "reasoning": 0,
    }


def normalize_codex_usage(raw):
    raw_input = int(raw.get("input_tokens", 0) or 0)
    cached = int(raw.get("cached_input_tokens", 0) or 0)
    output = int(raw.get("output_tokens", 0) or 0)
    return {
        "input": max(raw_input - cached, 0),
        "output": output,
        "cache_write": 0,
        "cache_read": cached,
        "reasoning": int(raw.get("reasoning_output_tokens", 0) or 0),
    }


def load_spending_log(spending_log):
    all_switches = []
    session_profile = {}
    switches_for_display = []

    if spending_log and os.path.exists(spending_log):
        with open(spending_log) as f:
            for line in f:
                try:
                    e = json.loads(line)
                except json.JSONDecodeError:
                    continue
                event = e.get("event", "")
                if event == "switch":
                    switches_for_display.append(e)
                    ts = parse_ts(e.get("ts"))
                    if ts and e.get("to"):
                        all_switches.append((ts, e.get("from", "unknown"), e["to"]))
                elif event in ("session_update", "session_end"):
                    sid = e.get("session_id")
                    prof = e.get("profile")
                    if sid and prof:
                        session_profile[sid] = prof

    all_switches.sort(key=lambda x: x[0])
    return all_switches, [s[0] for s in all_switches], session_profile, switches_for_display


def profile_at(ts, all_switches, switch_times):
    if not all_switches:
        return "unknown"
    idx = bisect.bisect_right(switch_times, ts) - 1
    if idx < 0:
        return all_switches[0][1]
    return all_switches[idx][2]


def claude_project_name(projects_dir, session_file):
    rel = os.path.relpath(session_file, projects_dir)
    first = rel.split(os.sep)[0]
    if os.sep in rel:
        return first.replace("-Users-matthew--projects-", "").replace("-Users-matthew-", "~").replace("-", "/", 1)
    return first


def codex_project_name(cwd, session_file=None):
    if cwd:
        cwd = cwd.replace(HOME, "~", 1) if cwd.startswith(HOME) else cwd
        marker = "~/_projects/"
        if cwd.startswith(marker):
            rest = cwd[len(marker):]
            return rest.split("/", 1)[0] or "~/_projects"
        if cwd == "~":
            return "~"
        return os.path.basename(cwd.rstrip("/")) or cwd
    if session_file:
        return os.path.basename(session_file)
    return "unknown"


def iter_claude_records(projects_dir, cutoff):
    session_files = glob.glob(os.path.join(projects_dir, "**", "*.jsonl"), recursive=True)
    for sf in session_files:
        project_name = claude_project_name(projects_dir, sf)
        session_id = os.path.splitext(os.path.basename(sf))[0]

        try:
            lines = open(sf).readlines()
        except (IOError, OSError):
            continue

        prev_type = None
        last_assistant = None
        for line in lines:
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue

            msg = d.get("message", {})
            if not isinstance(msg, dict):
                continue

            if msg.get("role") == "assistant" and "usage" in msg:
                last_assistant = d
                prev_type = "assistant"
            elif prev_type == "assistant" and last_assistant is not None:
                record = claude_record_from_entry(last_assistant, project_name, session_id, cutoff)
                if record:
                    yield record
                last_assistant = None
                prev_type = d.get("type", "")
            else:
                prev_type = d.get("type", "")

        if last_assistant is not None:
            record = claude_record_from_entry(last_assistant, project_name, session_id, cutoff)
            if record:
                yield record


def claude_record_from_entry(entry, project_name, session_id, cutoff):
    msg = entry.get("message", {})
    ts = parse_ts(entry.get("timestamp"))
    if not ts or ts < cutoff:
        return None
    return {
        "agent": "claude",
        "ts": ts,
        "model": msg.get("model", "unknown"),
        "usage": normalize_claude_usage(msg.get("usage", {})),
        "project": project_name,
        "session_id": session_id,
    }


def codex_session_files(codex_sessions_dir, codex_archived_dir):
    files = []
    for root in [codex_sessions_dir, codex_archived_dir]:
        if root and os.path.isdir(root):
            files.extend(glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True))
    return sorted(set(files))


def iter_codex_records(codex_sessions_dir, codex_archived_dir, cutoff, rate_callback=None):
    for sf in codex_session_files(codex_sessions_dir, codex_archived_dir):
        session_id = os.path.splitext(os.path.basename(sf))[0]
        session_cwd = ""
        current_cwd = ""
        current_model = ""
        seen = set()

        try:
            f = open(sf)
        except (IOError, OSError):
            continue

        with f:
            for line in f:
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = parse_ts(d.get("timestamp"))
                payload = d.get("payload") or {}
                typ = d.get("type")

                if typ == "session_meta":
                    session_id = payload.get("id") or session_id
                    session_cwd = payload.get("cwd") or session_cwd
                    continue

                if typ == "turn_context":
                    current_cwd = payload.get("cwd") or current_cwd
                    model = payload.get("model")
                    if not model:
                        model = ((payload.get("collaboration_mode") or {}).get("settings") or {}).get("model")
                    current_model = model or current_model
                    continue

                if typ != "event_msg" or payload.get("type") != "token_count":
                    continue

                info = payload.get("info") or {}
                raw_usage = info.get("last_token_usage") or {}
                if not raw_usage:
                    continue
                dedupe_key = (
                    d.get("timestamp"),
                    json.dumps(raw_usage, sort_keys=True),
                    json.dumps(info.get("total_token_usage") or {}, sort_keys=True),
                    current_model,
                    current_cwd or session_cwd,
                )
                if dedupe_key in seen:
                    continue
                seen.add(dedupe_key)

                if ts and rate_callback:
                    rate_callback(ts, payload.get("rate_limits") or {})

                if not ts or ts < cutoff:
                    continue
                usage = normalize_codex_usage(raw_usage)
                if not any(usage[k] for k in ("input", "output", "cache_read", "cache_write")):
                    continue
                cwd = current_cwd or session_cwd
                yield {
                    "agent": "codex",
                    "ts": ts,
                    "model": current_model or "codex",
                    "usage": usage,
                    "project": codex_project_name(cwd, sf),
                    "session_id": session_id,
                }


class Aggregates:
    def __init__(self, spending_log):
        self.all_switches, self.switch_times, self.session_profile, self.switches_for_display = load_spending_log(spending_log)
        self.by_period = {}
        self.by_model = {}
        self.by_project = {}
        self.by_profile = {}
        self.by_agent = {}
        self.total = empty_totals()

    def record(self, rec):
        usage = rec["usage"]
        cost = estimate_cost(rec["agent"], rec["model"], usage)
        period_key = billing_period_start(rec["ts"]).strftime("%Y-%m-%d")
        prof = self.session_profile.get(rec["session_id"]) or profile_at(rec["ts"], self.all_switches, self.switch_times)

        add_to(self.by_period, period_key, usage, cost)
        add_to(self.by_model, f"{rec['agent']}/{rec['model']}", usage, cost)
        add_to(self.by_project, rec["project"], usage, cost)
        add_to(self.by_profile, prof, usage, cost)
        add_to(self.by_agent, rec["agent"], usage, cost)
        add_to({"total": self.total}, "total", usage, cost)


def print_costs(argv):
    projects_dir, codex_sessions_dir, codex_archived_dir = argv[0], argv[1], argv[2]
    num_periods = int(argv[3])
    project_filter = argv[4] if len(argv) > 4 else ""
    spending_log = argv[5] if len(argv) > 5 else ""

    now = datetime.now(timezone.utc)
    current_period = billing_period_start(now)
    cutoff = current_period - timedelta(weeks=max(num_periods - 1, 0))
    agg = Aggregates(spending_log)

    for rec in iter_claude_records(projects_dir, cutoff):
        if project_filter and project_filter not in rec["project"]:
            continue
        agg.record(rec)
    for rec in iter_codex_records(codex_sessions_dir, codex_archived_dir, cutoff):
        if project_filter and project_filter not in rec["project"]:
            continue
        agg.record(rec)

    current_period_key = current_period.strftime("%Y-%m-%d")
    period_label = f"{num_periods} billing period{'s' if num_periods != 1 else ''}" if num_periods < 9999 else "all billing periods"
    print(f"\033[1mAgent Token Usage\033[0m  \033[2m({period_label}, resets Thu 6am)\033[0m")
    print()

    if agg.by_period:
        print(f"\033[0;36m{'Period':<22} {'Input':>12} {'Output':>12} {'Cache Write':>12} {'Cache Read':>12} {'Est. Cost':>10} {'Turns':>6}\033[0m")
        print("-" * 88)
        for pkey in sorted(agg.by_period.keys(), reverse=True):
            d = agg.by_period[pkey]
            p_start = datetime.strptime(pkey, "%Y-%m-%d").replace(tzinfo=TZ)
            p_end = p_start + timedelta(weeks=1)
            start_label = p_start.strftime("%b %d")
            if pkey == current_period_key:
                end_label = "now"
                marker = "\033[1m>\033[0m"
            else:
                end_label = (p_end - timedelta(days=1)).strftime("%b %d")
                marker = " "
            label = f"{marker} {start_label} - {end_label}"
            pad = 22 if pkey != current_period_key else 30
            print(f"{label:<{pad}} {fmt(d['input']):>12} {fmt(d['output']):>12} {fmt(d['cache_write']):>12} {fmt(d['cache_read']):>12} {usd(d['cost']):>10} {d['turns']:>6}")
        print("-" * 88)
        t = agg.total
        print(f"\033[1m{'Total':<22} {fmt(t['input']):>12} {fmt(t['output']):>12} {fmt(t['cache_write']):>12} {fmt(t['cache_read']):>12} {usd(t['cost']):>10} {t['turns']:>6}\033[0m")
        print()

    print_breakdown("By Agent", agg.by_agent)
    print_breakdown("By Model", agg.by_model)
    print_breakdown("By Profile", agg.by_profile)
    print_projects(agg.by_project)

    if agg.switches_for_display:
        print("\033[1mRecent Profile Switches\033[0m")
        for s in agg.switches_for_display[-10:]:
            print(f"  \033[2m{s['ts']}\033[0m  {s['from']} -> \033[1m{s['to']}\033[0m")
        print()

    if not agg.by_period:
        print("\033[2mNo session data found for this period.\033[0m")
    else:
        print("\033[2mCodex costs are API-equivalent estimates. ChatGPT-plan sessions may consume included plan usage instead of API billing.\033[0m")


def print_breakdown(title, bucket):
    if not bucket:
        return
    print(f"\033[1m{title}\033[0m")
    for key, d in sorted(bucket.items(), key=lambda x: x[1]["cost"], reverse=True):
        print(f"  {key:<40} {fmt(d['input']):>10} in  {fmt(d['output']):>10} out  {usd(d['cost']):>10}  {d['turns']:>5} turns")
    print()


def print_projects(bucket):
    if not bucket:
        return
    print("\033[1mBy Project\033[0m \033[2m(top 10)\033[0m")
    for proj, d in sorted(bucket.items(), key=lambda x: x[1]["cost"], reverse=True)[:10]:
        label = proj[:45]
        tokens = d["input"] + d["output"] + d["cache_write"] + d["cache_read"]
        print(f"  {label:<46} {fmt(tokens):>12} tokens  {usd(d['cost']):>10}  {d['turns']:>5} turns")
    print()


def bar(pct, width=30):
    filled = int(pct * width / 100)
    empty = width - filled
    if pct >= 80:
        color = "\033[0;31m"
    elif pct >= 50:
        color = "\033[0;33m"
    else:
        color = "\033[0;32m"
    return f"{color}{'#' * filled}{'.' * empty}\033[0m"


def fmt_reset(resets_at, now):
    if not resets_at:
        return ""
    dt = parse_ts(resets_at)
    if not dt:
        return ""
    local_dt = dt.astimezone()
    delta = dt - now
    hours = delta.total_seconds() / 3600
    if hours < 0:
        return "reset overdue"
    if hours < 1:
        return f"resets in {int(delta.total_seconds() / 60)}m"
    if hours < 24:
        return f"resets in {hours:.1f}h"
    return f"resets {local_dt.strftime('%a %I:%M%p').lower()}"


def rate_age(captured, now):
    cap_dt = parse_ts(captured)
    if not cap_dt:
        return ""
    delta = now - cap_dt
    mins = int(delta.total_seconds() / 60)
    if mins < 1:
        return "just now"
    if mins < 60:
        return f"{mins}m ago"
    if mins < 1440:
        return f"{mins // 60}h ago"
    return f"{mins // 1440}d ago"


def print_claude_rate_limits(rate_file, now):
    if not os.path.exists(rate_file):
        return False
    try:
        rate_data = json.load(open(rate_file))
    except (json.JSONDecodeError, IOError):
        return False

    header = "\033[1mClaude Plan Usage\033[0m"
    profile = rate_data.get("profile", "")
    if profile:
        header += f"  \033[2m({profile})\033[0m"
    age = rate_age(rate_data.get("captured_at"), now)
    if age:
        header += f"  \033[2mupdated {age}\033[0m"
    print(header)
    print()

    printed = False
    for label, key in [("5-hour window", "five_hour"), ("7-day window", "seven_day")]:
        data = rate_data.get(key)
        if not data:
            continue
        pct = float(data.get("used_percentage", 0) or 0)
        print(f"  {label:<15} {bar(pct)}  {pct:5.1f}%  \033[2m{fmt_reset(data.get('resets_at'), now)}\033[0m")
        printed = True
    if not printed:
        print("  \033[2mNo Claude subscription rate-limit snapshot available.\033[0m")
    print()
    return True


def print_codex_rate_limits(latest, now):
    if not latest:
        return False
    ts, data = latest
    plan = data.get("plan_type") or ""
    header = "\033[1mCodex Plan Usage\033[0m"
    if plan:
        header += f"  \033[2m({plan})\033[0m"
    age = rate_age(ts.isoformat(), now)
    if age:
        header += f"  \033[2mupdated {age}\033[0m"
    print(header)
    print()

    for label, key in [("5-hour window", "primary"), ("7-day window", "secondary")]:
        item = data.get(key) or {}
        pct = float(item.get("used_percent", 0) or 0)
        print(f"  {label:<15} {bar(pct)}  {pct:5.1f}%  \033[2m{fmt_reset(item.get('resets_at'), now)}\033[0m")

    credits = data.get("credits") or {}
    if credits.get("has_credits") or credits.get("balance") not in (None, "", "0E-10"):
        print(f"  \033[2mcredits balance: {credits.get('balance', 'unknown')}\033[0m")
    print()
    return True


def print_usage(argv):
    rate_file, history_file, projects_dir = argv[0], argv[1], argv[2]
    codex_sessions_dir, codex_archived_dir = argv[3], argv[4]
    num_weeks = int(argv[5])

    now = datetime.now(timezone.utc)
    current_week_start = billing_period_start(now)
    weeks = []
    for i in range(num_weeks):
        w_start = current_week_start - timedelta(weeks=i)
        weeks.append((w_start, w_start + timedelta(weeks=1)))
    oldest_cutoff = weeks[-1][0]

    week_data = {}
    week_peaks = {}
    for w_start, w_end in weeks:
        key = w_start.strftime("%Y-%m-%d")
        week_data[key] = {**empty_totals(), "start": w_start, "end": w_end}
        week_peaks[key] = {"peak_five_hour": None, "peak_seven_day": None}

    def record(rec):
        usage = rec["usage"]
        cost = estimate_cost(rec["agent"], rec["model"], usage)
        for key, wd in week_data.items():
            if wd["start"] <= rec["ts"] < wd["end"]:
                wd["input"] += usage["input"]
                wd["output"] += usage["output"]
                wd["cache_write"] += usage["cache_write"]
                wd["cache_read"] += usage["cache_read"]
                wd["reasoning"] += usage.get("reasoning", 0)
                wd["cost"] += cost
                wd["turns"] += 1
                return

    latest_codex_rate = [None]

    def record_codex_rate(ts, rate_limits):
        if not rate_limits:
            return
        if latest_codex_rate[0] is None or ts > latest_codex_rate[0][0]:
            latest_codex_rate[0] = (ts, rate_limits)
        for key, wd in week_data.items():
            if not (wd["start"] <= ts < wd["end"]):
                continue
            primary = rate_limits.get("primary") or {}
            secondary = rate_limits.get("secondary") or {}
            if primary.get("used_percent") is not None:
                cur = week_peaks[key]["peak_five_hour"]
                val = float(primary.get("used_percent") or 0)
                week_peaks[key]["peak_five_hour"] = max(cur, val) if cur is not None else val
            if secondary.get("used_percent") is not None:
                cur = week_peaks[key]["peak_seven_day"]
                val = float(secondary.get("used_percent") or 0)
                week_peaks[key]["peak_seven_day"] = max(cur, val) if cur is not None else val
            break

    load_claude_peak_history(history_file, week_data, week_peaks, oldest_cutoff)

    for rec in iter_claude_records(projects_dir, oldest_cutoff):
        record(rec)
    for rec in iter_codex_records(codex_sessions_dir, codex_archived_dir, oldest_cutoff, record_codex_rate):
        record(rec)

    printed_limits = print_claude_rate_limits(rate_file, now)
    printed_limits = print_codex_rate_limits(latest_codex_rate[0], now) or printed_limits
    if not printed_limits:
        print("\033[1mPlan Usage\033[0m")
        print()
        print("  \033[2mNo local Claude or Codex rate-limit snapshots found yet.\033[0m")
        print()

    has_peaks = any(
        wp["peak_five_hour"] is not None or wp["peak_seven_day"] is not None
        for wp in week_peaks.values()
    )

    print("\033[1mBilling Weeks\033[0m  \033[2m(resets Thu 6am)\033[0m")
    print()
    if has_peaks:
        print(f"\033[0;36m{'Week':<28} {'Peak 5h':>8} {'Peak 7d':>8} {'Output':>12} {'Est. Cost':>10} {'Turns':>6}\033[0m")
        print("-" * 76)
    else:
        print(f"\033[0;36m{'Week':<28} {'Output':>12} {'Input':>12} {'Cache Read':>12} {'Est. Cost':>10} {'Turns':>6}\033[0m")
        print("-" * 84)

    sorted_weeks = sorted(week_data.items(), key=lambda x: x[0], reverse=True)
    for _, wd in sorted_weeks:
        start_tz = wd["start"].astimezone(TZ)
        end_tz = wd["end"].astimezone(TZ)
        if wd["start"] <= now < wd["end"]:
            label = f"> {start_tz.strftime('%b %d')} - now"
        else:
            label = f"  {start_tz.strftime('%b %d')} - {(end_tz - timedelta(days=1)).strftime('%b %d')}"

        if has_peaks:
            peaks = week_peaks[wd["start"].strftime("%Y-%m-%d")]
            p5 = f"{peaks['peak_five_hour']:.0f}%" if peaks["peak_five_hour"] is not None else "-"
            p7 = f"{peaks['peak_seven_day']:.0f}%" if peaks["peak_seven_day"] is not None else "-"
            print(f"{label:<28} {p5:>8} {p7:>8} {fmt(wd['output']):>12} {usd(wd['cost']):>10} {wd['turns']:>6}")
        else:
            print(f"{label:<28} {fmt(wd['output']):>12} {fmt(wd['input']):>12} {fmt(wd['cache_read']):>12} {usd(wd['cost']):>10} {wd['turns']:>6}")

    print()
    total_output = sum(wd["output"] for _, wd in sorted_weeks)
    total_cost = sum(wd["cost"] for _, wd in sorted_weeks)
    total_turns = sum(wd["turns"] for _, wd in sorted_weeks)
    print(f"\033[2mShown: {fmt(total_output)} output tokens, {usd(total_cost)} estimated API-equivalent cost, {total_turns} turns.\033[0m")
    print("\033[2mCodex ChatGPT-plan sessions may consume included plan usage instead of API billing.\033[0m")


def load_claude_peak_history(history_file, week_data, week_peaks, oldest_cutoff):
    if not os.path.exists(history_file):
        return
    try:
        f = open(history_file)
    except IOError:
        return
    with f:
        for line in f:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = parse_ts(entry.get("ts"))
            if not ts or ts < oldest_cutoff:
                continue
            for key, wd in week_data.items():
                if not (wd["start"] <= ts < wd["end"]):
                    continue
                fh = entry.get("five_hour")
                sd = entry.get("seven_day")
                if fh is not None:
                    cur = week_peaks[key]["peak_five_hour"]
                    week_peaks[key]["peak_five_hour"] = max(cur, fh) if cur is not None else fh
                if sd is not None:
                    cur = week_peaks[key]["peak_seven_day"]
                    week_peaks[key]["peak_seven_day"] = max(cur, sd) if cur is not None else sd
                break


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: usage_costs.py <costs|usage> ...")
    mode = sys.argv[1]
    if mode == "costs":
        print_costs(sys.argv[2:])
    elif mode == "usage":
        print_usage(sys.argv[2:])
    else:
        raise SystemExit(f"unknown mode: {mode}")


if __name__ == "__main__":
    main()
