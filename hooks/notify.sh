#!/usr/bin/env bash
# Usage: notify.sh <stop|notification>
# Called by Claude Code hooks. Reads JSON from stdin.

EVENT="${1:-stop}"
DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
INPUT=$(cat)

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
    afplay /System/Library/Sounds/Glass.aiff &
    say -r 200 "$NAME needs input"
  else
    afplay /System/Library/Sounds/Ping.aiff &
    say -r 200 "$NAME done"
  fi

elif [ "$EVENT" = "notification" ]; then
  TYPE=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('type',''))" 2>/dev/null)

  if [ "$TYPE" = "permission_prompt" ]; then
    afplay /System/Library/Sounds/Tink.aiff &
    say -r 200 "$NAME needs permission"
  fi
fi
