#!/usr/bin/env bash
# Usage: notify.sh <stop|notification>
# Called by Claude Code hooks. Reads JSON from stdin.

EVENT="${1:-stop}"
DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
INPUT=$(cat)

# Plan 108: the peer doorbell is making the agent continue, so the turn is
# not done; skip the "done" speech.
if [ "$EVENT" = "stop" ] && [ "${CCTRL_STOP_CONTINUING:-}" = "1" ]; then
  exit 0
fi

# Sounds on or off for this host. `cctrl hooks run stop|notify` resolves it
# (cctrl _notify_sounds_state) and passes CCTRL_NOTIFY_SOUNDS=on|off; a legacy
# hook that runs this script directly gets the same order here: the env, then
# notifySounds in data/config.local.json > user config > data/config.json,
# then on. Set it with `cctrl hooks sounds off`. Only the sound calls below
# are gated; everything else this script does runs either way.
_sounds_norm() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    on|1|true|yes) echo on ;;
    off|0|false|no) echo off ;;
    *) return 1 ;;
  esac
}
_sounds_resolve() {
  local v f raw root cfg_home
  if v=$(_sounds_norm "${CCTRL_NOTIFY_SOUNDS:-}"); then echo "$v"; return; fi
  command -v jq >/dev/null 2>&1 || { echo on; return; }
  root=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
  if [ -n "${XDG_CONFIG_HOME:-}" ] && [ "${XDG_CONFIG_HOME#/}" != "$XDG_CONFIG_HOME" ]; then
    cfg_home="$XDG_CONFIG_HOME/cctrl"
  else
    cfg_home="${HOME:-}/.config/cctrl"
  fi
  for f in "${CCTRL_CONFIG_LOCAL:-$root/data/config.local.json}" \
           "${CCTRL_USER_CONFIG:-$cfg_home/config.json}" \
           "$root/data/config.json"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    raw=$(jq -r 'if type == "object" and has("notifySounds") then (.notifySounds | tostring) else empty end' "$f" 2>/dev/null)
    if v=$(_sounds_norm "$raw"); then echo "$v"; return; fi
  done
  echo on
}
SOUNDS=$(_sounds_resolve)
_chime() { if [ "$SOUNDS" != "off" ]; then afplay "/System/Library/Sounds/$1.aiff" & fi; }
_speak() { if [ "$SOUNDS" != "off" ]; then say -r 200 "$1"; fi; }

# Prefer git repo name, fall back to directory basename
NAME=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null)
[ -z "$NAME" ] && NAME=$(basename "$DIR")
NAME="${NAME//-/ }"
NAME="${NAME//_/ }"

if [ "$EVENT" = "stop" ]; then
  TRANSCRIPT=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null)

  NEEDS_INPUT=false
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    NEEDS_INPUT=$(python3 -c "
import json, sys

last_text = ''
with open('$TRANSCRIPT') as f:
    for line in f:
        try:
            entry = json.loads(line.strip())
        except:
            continue
        if entry.get('type') != 'assistant':
            continue
        content = entry.get('message', {}).get('content', [])
        if isinstance(content, list):
            for c in reversed(content):
                if isinstance(c, dict) and c.get('type') == 'text' and c.get('text', '').strip():
                    last_text = c['text'].strip()
                    break
        elif isinstance(content, str) and content.strip():
            last_text = content.strip()

# Check the tail for a question mark (ignore trailing whitespace/markdown)
tail = last_text[-300:] if last_text else ''
import re
# Strip trailing fences, whitespace, markdown
tail_clean = re.sub(r'[\s\`]+$', '', tail)
print('true' if tail_clean.endswith('?') else 'false')
" 2>/dev/null)
  fi

  if [ "$NEEDS_INPUT" = "true" ]; then
    _chime Glass
    _speak "$NAME needs input"
  else
    _chime Ping
    _speak "$NAME done"
  fi

elif [ "$EVENT" = "notification" ]; then
  TYPE=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('type',''))" 2>/dev/null)

  if [ "$TYPE" = "permission_prompt" ]; then
    _chime Tink
    _speak "$NAME needs permission"
  fi
fi
