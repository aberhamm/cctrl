"""Exact historical launch evidence; shell text is parsed as data, never executed."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import stat

from shell_literals import parse_words


def load_event(path, event_id, codex_home):
    path = Path(path)
    root = (Path(codex_home) / 'sessions').resolve()
    if path.is_symlink() or not path.resolve().is_relative_to(root):
        raise ValueError('launch-event-outside-provider-store')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    matches = []
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError('nonregular-launch-event')
        consumed = 0
        header = None
        for number in range(100000):
            line = stream.readline(8 * 1024 * 1024 + 1)
            if not line:
                break
            consumed += len(line)
            if len(line) > 8 * 1024 * 1024 or consumed > 32 * 1024 * 1024:
                raise ValueError('launch-event-budget-exhausted')
            value = json.loads(line)
            if number == 0:
                header = value
                header_digest = hashlib.sha256(line).hexdigest()
            if not isinstance(value, dict) or not isinstance(value.get('payload'), dict):
                raise ValueError('malformed-launch-event-log')
            item = value['payload'].get('item', {})
            if not isinstance(item, dict):
                raise ValueError('malformed-launch-event-item')
            if item.get('id') == event_id:
                matches.append((value, hashlib.sha256(line).hexdigest()))
        else:
            raise ValueError('launch-event-budget-exhausted')
    meta = (header or {}).get('payload', {})
    if ((header or {}).get('type') != 'session_meta'
            or meta.get('source') != 'vscode' or meta.get('originator') != 'Codex Desktop'
            or not isinstance(meta.get('id'), str)):
        raise ValueError('unsupported-launch-event-provenance')
    if len(matches) != 1:
        raise ValueError('ambiguous-or-missing-launch-event')
    event, digest = matches[0]
    payload = event.get('payload', {})
    item = payload.get('item', {})
    if (event.get('type') != 'event_msg' or payload.get('type') != 'item_completed'
            or payload.get('thread_id') != meta['id'] or item.get('type') != 'CommandExecution'
            or item.get('source') != 'unified_exec_startup' or item.get('status') != 'completed'
            or type(item.get('exit_code')) is not int or item['exit_code'] != 0
            or item.get('stderr') or not str(item.get('process_id', '')).isdigit()):
        raise ValueError('unsuccessful-or-unbound-launch-event')
    command = item.get('command')
    if (not isinstance(command, list) or len(command) != 3
            or command[:2] != ['/bin/zsh', '-lc'] or not isinstance(command[2], str)
            or '\ufffd' in command[2]):
        raise ValueError('unsupported-launch-event-command')
    args = parse_words(command[2])
    if (len(args) != 10 or args[:3] != ['cctrl', 'start', '-d']
            or args[4:7] != ['--agent', 'codex', '-n'] or args[8] != '-m'):
        raise ValueError('unsupported-launch-event-arguments')
    evidence = dict(path=str(path.resolve()), event_id=event_id, event_sha256=digest,
                    source_thread_id=meta['id'], header_sha256=header_digest, device=info.st_dev, inode=info.st_ino)
    return event, args, evidence


def verify_binding(record, live_command, event, args):
    # This narrow branch supports one complete, originally recorded invocation.
    # It never substitutes replacement characters or searches by prompt/cwd.
    if (args[3] != record.get('cwd') or args[7] != record.get('purpose')
            or args[9] != record.get('initial_prompt')):
        raise ValueError('launch-event-arguments-mismatch')
    payload = event['payload']
    start, end = payload.get('started_at_ms'), payload.get('completed_at_ms')
    created = int(dt.datetime.fromisoformat(record['created_at'].replace('Z', '+00:00')).timestamp())
    if (type(start) is not int or type(end) is not int or not 0 <= end-start <= 120000
            or not start // 1000 <= created <= end // 1000):
        raise ValueError('launch-event-generation-mismatch')
    stdout = payload['item'].get('stdout')
    if not isinstance(stdout, str):
        raise ValueError('launch-event-output-missing')
    stdout = re.sub(r'\x1b\[[0-9;]*m', '', stdout)
    name = record['tmux_session']
    attach = f'  Attach:  cctrl --host {record["host"]} session attach {name}'
    if (stdout.splitlines().count(attach) != 1
            or sum('✓ detached session started — ' in line for line in stdout.splitlines()) != 1):
        raise ValueError('launch-event-session-output-mismatch')
    stored = record.get('launch_command', '')
    marker = ' -m '
    # Require the entire undamaged scaffold, then independently recover the
    # one prompt argument from the original event. No other slot may be lost.
    if marker not in stored or marker not in live_command:
        raise ValueError('unsupported-launch-bootstrap')
    prefix, _ = stored.split(marker, 1)
    live_prefix, live_prompt = live_command.split(marker, 1)
    if '\ufffd' in prefix or prefix != live_prefix or prefix.count(' && ') != 1:
        raise ValueError('launch-bootstrap-scaffold-mismatch')
    cd, invocation = prefix.split(' && ')
    expected = ['CCTRL_TMUX_CONTEXT=1', 'CCTRL_AGENT=codex',
                'CCTRL_HOST_PREFIX=' + record['host'], 'CCTRL_SESSION_KIND=tmux',
                'CCTRL_SESSION_NAME=' + name, 'CCTRL_SESSION_TARGET=' + record['target'],
                'CCTRL_SESSION_PURPOSE=' + record['purpose'],
                str(Path(__file__).resolve().parents[1] / 'cctrl'),
                'start', '--foreground', '--name', name, '--agent', 'codex']
    if parse_words(cd, allow_ansi=True) != ['cd', args[3]] or parse_words(invocation, allow_ansi=True) != expected:
        raise ValueError('unsupported-launch-bootstrap-scaffold')
    if parse_words(live_prompt, allow_ansi=True) != [args[9]]:
        raise ValueError('launch-bootstrap-prompt-or-tail-mismatch')
