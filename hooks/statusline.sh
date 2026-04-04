#!/usr/bin/env bash
# Statusline script for Claude Code
# Displays context window bar + captures rate_limits to disk

CCTRL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="$CCTRL_DIR/data"

input=$(cat)

# ── Display: context window bar ──────────────────────────────────────
model=$(echo "$input" | jq -r '.model.display_name // "?"')
project=$(echo "$input" | jq -r '.workspace.project_dir // .cwd // ""' | xargs basename 2>/dev/null)
used=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
bar_length=20
filled=$((used * bar_length / 100))
empty=$((bar_length - filled))
bar=$(printf '█%.0s' $(seq 1 $filled 2>/dev/null))$(printf '░%.0s' $(seq 1 $empty 2>/dev/null))

# Add rate limit hint if available
five_hr=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
seven_day=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

if [[ -n "$five_hr" && -n "$seven_day" ]]; then
    printf "%s | %s | %s %d%% | 5h: %s%% 7d: %s%%" "$model" "$project" "$bar" "$used" "${five_hr%.*}" "${seven_day%.*}"
else
    printf "%s | %s | %s %d%%" "$model" "$project" "$bar" "$used"
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
