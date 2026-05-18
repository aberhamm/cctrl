#!/usr/bin/env bash
# Statusline script for Claude Code
# Displays context window bar + captures rate_limits to disk

CCTRL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="$CCTRL_DIR/data"

input=$(cat)

# ── Display: context window ──────────────────────────────────────────
model=$(echo "$input" | jq -r '.model.display_name // "?"')
project_path=$(echo "$input" | jq -r '.workspace.project_dir // .cwd // ""')
project_leaf="${project_path##*/}"
project_parent_path="${project_path%/*}"
project_parent="${project_parent_path##*/}"
if [[ "$project_parent" == "Obsidian Vault" ]]; then
    project="Obsidian/$project_leaf"
else
    project="$project_leaf"
fi
tokens=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
tokens_fmt=$(awk -v t="$tokens" 'BEGIN {
    if (t >= 1000000) printf "%.1fM", t/1000000
    else if (t >= 1000) printf "%.1fk", t/1000
    else printf "%d", t
}')

# Add rate limit hint if available
five_hr=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
seven_day=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

if [[ -n "$five_hr" && -n "$seven_day" ]]; then
    printf "%s | %s | %s | 5h: %s%% 7d: %s%%" "$model" "$project" "$tokens_fmt" "${five_hr%.*}" "${seven_day%.*}"
else
    printf "%s | %s | %s" "$model" "$project" "$tokens_fmt"
fi

# ── Capture: rate_limits to file (if present) ────────────────────────
rate_limits=$(echo "$input" | jq '.rate_limits // empty')

if [[ -n "$rate_limits" ]]; then
    mkdir -p "$DATA_DIR"

    # Enrich with capture timestamp and profile
    profile=""
    [[ -f "$CCTRL_DIR/.active-profile" ]] && profile=$(cat "$CCTRL_DIR/.active-profile")

    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Latest snapshot (overwritten each time)
    echo "$input" | jq --arg ts "$ts" --arg profile "$profile" '{
        captured_at: $ts,
        profile: $profile,
        five_hour: .rate_limits.five_hour,
        seven_day: .rate_limits.seven_day
    }' > "$DATA_DIR/rate-limits.json"

    # Append to history (one line per reading, compact)
    echo "$input" | jq -c --arg ts "$ts" --arg profile "$profile" '{
        ts: $ts,
        profile: $profile,
        five_hour: .rate_limits.five_hour.used_percentage,
        seven_day: .rate_limits.seven_day.used_percentage
    }' >> "$DATA_DIR/rate-limits-history.jsonl"
fi
