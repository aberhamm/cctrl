#!/usr/bin/env python3
"""Read-only, bounded Codex rollout correlation. Empty output means unknown.

Explicit resume IDs are authoritative (including old threads). Fresh launches
with a prompt require a unique time/prompt match; otherwise use a unique cwd match; an incomplete scan cannot prove uniqueness.
"""
import json
import os
from pathlib import Path
import signal
import shlex
import sqlite3
import sys
import time

MAX_FILES = 10000
MAX_BYTES = 16 * 1024 * 1024
MAX_LINE = 1024 * 1024


class BudgetExceeded(Exception):
    pass


def find_rollout(root, metadata, db='', cwd='', timeout=2.0):
    deadline = time.monotonic() + timeout
    remaining = MAX_BYTES
    stored_id = metadata.get('conversation_id') or metadata.get('provider_task_id')
    cwd = metadata.get('cwd') or cwd
    prompt = metadata.get('initial_prompt') or ''
    created = metadata.get('created_at') or ''
    matches = []
    try:
        command = shlex.split(metadata.get('launch_command') or '')
    except ValueError:
        command = []
    resumed = any(command[i] in ('resume', '--resume', '-r') and command[i + 1] == stored_id
                  for i in range(len(command) - 1))
    con = None

    def check():
        if time.monotonic() >= deadline:
            raise BudgetExceeded()

    def read_line(stream):
        nonlocal remaining
        check()
        line = stream.readline(min(MAX_LINE, remaining) + 1)
        remaining -= len(line)
        if len(line) > MAX_LINE or remaining < 0:
            raise BudgetExceeded()
        try:
            value = json.loads(line)
            return value if isinstance(value, dict) else {}
        except (ValueError, UnicodeError):
            return {}

    def unarchived(tid):
        if not con:
            return True
        check()
        row = con.execute(f'SELECT {field} FROM threads WHERE id = ?', (tid,)).fetchone()
        return bool(row and row[0] in (0, None, ''))

    try:
        if db and Path(db).is_file():
            con = sqlite3.connect(Path(db).resolve().as_uri() + '?mode=ro', uri=True, timeout=0.05)
            con.set_progress_handler(lambda: int(time.monotonic() >= deadline), 1000)
            columns = {r[1] for r in con.execute('PRAGMA table_info(threads)')}
            field = 'archived' if 'archived' in columns else '0'
        paths = []
        for directory, _, files in os.walk(root):
            check()
            for name in files:
                check()
                if name.startswith('rollout-') and name.endswith('.jsonl'):
                    paths.append(os.path.join(directory, name))
                    if len(paths) > MAX_FILES:
                        raise BudgetExceeded()
        # Filename ID narrows the normal resume path, but session_meta remains
        # authoritative. Other names stay eligible for older rollout formats.
        paths.sort(key=lambda p: (bool(stored_id and stored_id in Path(p).name), p), reverse=True)
        for path in paths:
            check()
            with open(path, 'rb') as stream:
                record = read_line(stream)
                if record.get('type') != 'session_meta':
                    continue
                meta = record.get('payload') or {}
                tid = meta.get('id') or meta.get('session_id')
                if not tid:
                    continue
                if stored_id and (resumed or not prompt):
                    if tid == stored_id and unarchived(tid):
                        return path
                    continue
                timestamp = meta.get('timestamp') or record.get('timestamp') or ''
                # Reject historical files before prompt parsing or SQLite work.
                timestamp = timestamp.split('.')[0] + 'Z' if '.' in timestamp else timestamp
                if created and (not timestamp or timestamp < created):
                    continue
                if not cwd or meta.get('cwd') != cwd:
                    continue
                if prompt:
                    found = False
                    for _ in range(80):
                        item = read_line(stream)
                        payload = item.get('payload') or {}
                        texts = []
                        if item.get('type') == 'response_item' and payload.get('role') == 'user':
                            texts = [p.get('text') for p in payload.get('content') or [] if isinstance(p, dict)]
                        elif item.get('type') == 'event_msg':
                            if payload.get('type') == 'user_message':
                                texts = [payload.get('message')]
                            nested = payload.get('item') or {}
                            if nested.get('type') == 'UserMessage':
                                texts += [p.get('text') for p in nested.get('content') or [] if isinstance(p, dict)]
                        if prompt in texts:
                            found = True
                            break
                    if not found:
                        continue
                if unarchived(tid):
                    matches.append(path)
                    if len(matches) > 1:
                        return ''
        return matches[0] if len(matches) == 1 else ''
    except (OSError, ValueError, TypeError, AttributeError, sqlite3.Error, BudgetExceeded):
        return ''
    finally:
        if con:
            con.close()


def main():
    root, metadata_path, db, cwd = sys.argv[1:5]
    try:
        timeout = max(0.0, min(float(os.environ.get('CCTRL_CODEX_LOOKUP_TIMEOUT', '2')), 2.0))
        if timeout == 0:
            return
        # Bound blocked filesystem calls too, not just Python loop iterations.
        signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(BudgetExceeded()))
        signal.setitimer(signal.ITIMER_REAL, timeout)
        with open(metadata_path, 'rb') as stream:
            metadata = json.loads(stream.read(MAX_LINE + 1))
        result = find_rollout(root, metadata, db, cwd, timeout)
        if result:
            print(result)
    except (OSError, ValueError, TypeError, BudgetExceeded):
        pass
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


if __name__ == '__main__':
    main()
