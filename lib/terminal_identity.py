"""Read-only terminal launch proof. Never correlates by cwd, title, or prompt."""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import signal
import stat
import subprocess
import time

from launch_event import load_event, verify_binding


class Unproved(Exception):
    pass


def canonical_digest(value):
    body = json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
    return hashlib.sha256(body.encode()).hexdigest()


def read_json(path):
    if path.is_symlink() or not stat.S_ISREG(path.stat().st_mode):
        raise Unproved('nonregular-evidence-file')
    with path.open('rb') as stream:
        data = stream.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024:
        raise Unproved('oversized-evidence-file')
    value = json.loads(data)
    if not isinstance(value, dict):
        raise Unproved('malformed-evidence-file')
    return value


def process_rows(text):
    rows = {}
    for line in text.splitlines():
        fields = line.split(None, 7)
        if len(fields) == 8 and fields[0].isdigit() and fields[1].isdigit():
            rows[int(fields[0])] = dict(pid=int(fields[0]), ppid=int(fields[1]),
                                      started=' '.join(fields[2:7]), command=fields[7])
    return rows


def descendants(rows, root):
    found = {root}
    while True:
        extended = found | {pid for pid, row in rows.items() if row['ppid'] in found}
        if extended == found:
            return found
        found = extended


def open_rollouts(text):
    found = []
    current = {}

    def finish():
        name = current.get('n', '')
        path = Path(name)
        if path.name.startswith('rollout-') and path.suffix == '.jsonl':
            if current.get('a') not in ('w', 'u'):
                return
            if (not current.get('f', '').isdigit() or not current.get('i', '').isdigit()
                    or not re.fullmatch(r'(?:0x)?[0-9a-fA-F]+', current.get('D', ''))):
                raise Unproved('incomplete-rollout-descriptor')
            found.append(dict(path=name, fd=int(current['f']), access=current['a'],
                              device=int(current['D'], 16), inode=int(current['i'])))

    for line in text.splitlines():
        if not line:
            continue
        if line.startswith('f'):
            finish()
            current = {}
        current[line[0]] = line[1:]
    finish()
    return sorted(found, key=lambda value: value['fd'])


class Collector:
    def __init__(self):
        self.deadline = time.monotonic() + 8

    def run(self, argv):
        remaining = min(2, self.deadline - time.monotonic())
        if remaining <= 0:
            raise Unproved('probe-budget-exhausted')
        result = subprocess.run(argv, capture_output=True, text=True, encoding='utf-8', timeout=remaining,
                                env={**os.environ, 'LC_ALL': 'C'})
        if result.returncode or result.stderr.strip() or len(result.stdout) > 4 * 1024 * 1024:
            raise Unproved('probe-unavailable:' + argv[0])
        return result.stdout

    def pane(self, name):
        # C-locale tmux clients replace tabs/non-ASCII output with underscores.
        # Force UTF-8 and use printable framing. Only the five fixed header
        # fields are split: the arbitrary bootstrap command remains opaque.
        fields = '#{pane_id}|#{pane_pid}|#{session_created}|#{@cctrl_managed}|#{@cctrl_agent}|#{pane_start_command}'
        output = self.run(['tmux', '-u', 'list-panes', '-t', '=' + name, '-F', fields])
        rows = output.removesuffix('\n').split('\n')
        if len(rows) != 1:
            raise Unproved('ambiguous-pane')
        values = rows[0].split('|', 5)
        if (len(values) != 6 or not re.fullmatch(r'%[0-9]+', values[0])
                or not re.fullmatch(r'[1-9][0-9]*', values[1])
                or not values[2].isascii() or not values[2].isdigit()
                or values[3] not in ('', '0', '1')
                or not re.fullmatch(r'[a-zA-Z0-9_-]*', values[4])):
            raise Unproved('malformed-pane-snapshot')
        return dict(zip(('pane_id', 'pane_pid', 'created', 'managed', 'agent', 'command'), values))

    def processes(self):
        return process_rows(self.run(['ps', '-axo', 'pid=,ppid=,lstart=,comm=']))

    def rollouts(self, pid):
        return open_rollouts(self.run(['lsof', '-a', '-p', str(pid), '-FpfaDin']))


def prove(record, codex_home, collector, launch_event=None):
    if (record.get('schema_version') != 2 or record.get('provider') != 'codex'
            or record.get('provider_task_id') is not None
            or record.get('origin') != 'cctrl' or record.get('launched_by_cctrl') is not True
            or record.get('control_owner') != 'cctrl' or record.get('execution_runtime') != 'tmux'
            or record.get('lifecycle_state') != 'provisional'):
        raise Unproved('not-provisional-cctrl-codex-launch')
    name = record.get('tmux_session')
    if not name or record.get('name') != name:
        raise Unproved('launch-name-mismatch')
    pane = collector.pane(name)
    if pane['managed'] != '1' or pane['agent'] != 'codex':
        raise Unproved('pane-not-managed-codex')
    command = pane['command']
    # tmux can return the whole bootstrap as one shell-quoted argument.
    try:
        words = shlex.split(command)
    except ValueError:
        words = []
    unwrapped = words[0] if len(words) == 1 else command
    binding = None
    if launch_event is not None:
        event, args, binding = launch_event
        verify_binding(record, unwrapped, event, args)
    elif command != record.get('launch_command') and unwrapped != record.get('launch_command'):
        if '\ufffd' in str(record.get('launch_command', '')):
            raise Unproved('lossy-launch-command-no-exact-binding')
        raise Unproved('launch-command-mismatch')
    created = dt.datetime.fromisoformat(record['created_at'].replace('Z', '+00:00')).timestamp()
    if int(pane['created']) != int(created):
        raise Unproved('session-generation-mismatch')
    pid = int(pane['pane_pid'])
    before = collector.processes()
    if pid not in before:
        raise Unproved('pane-process-missing')
    # ps lstart is local time. Require the original launch second, not merely a
    # currently live PID or a same-name session created later.
    started = time.mktime(time.strptime(before[pid]['started'], '%a %b %d %H:%M:%S %Y'))
    if int(started) != int(created):
        raise Unproved('pane-process-generation-mismatch')
    native = [p for p in descendants(before, pid)
              if p in before and Path(before[p]['command']).name == 'codex']
    if len(native) != 1:
        raise Unproved('ambiguous-native-codex-process')
    agent_pid = native[0]
    paths = collector.rollouts(agent_pid)
    # An FD inherited from the launcher is not evidence of a Codex-owned log.
    inherited = collector.rollouts(pid) if agent_pid != pid else []
    if {(p['device'], p['inode']) for p in paths} & {(p['device'], p['inode']) for p in inherited}:
        raise Unproved('inherited-rollout-descriptor')
    root = (Path(codex_home) / 'sessions').resolve()
    roots = []
    for descriptor in paths:
        path = Path(descriptor['path'])
        if path.is_symlink() or not path.resolve().is_relative_to(root):
            raise Unproved('rollout-outside-provider-store')
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_dev != descriptor['device']
                    or info.st_ino != descriptor['inode']):
                raise Unproved('open-rollout-file-identity-mismatch')
            line = stream.readline(1024 * 1024 + 1)
        if len(line) > 1024 * 1024:
            raise Unproved('oversized-rollout-header')
        header = json.loads(line)
        if not isinstance(header, dict) or not isinstance(header.get('payload'), dict):
            raise Unproved('malformed-rollout-header')
        meta = header['payload']
        if header.get('type') != 'session_meta':
            raise Unproved('missing-rollout-identity')
        source = meta.get('source')
        if isinstance(source, dict) and 'subagent' in source:
            continue
        if (source != 'cli' or meta.get('originator') != 'codex-tui'
                or meta.get('parent_thread_id') or meta.get('forked_from_id')):
            raise Unproved('unknown-root-rollout-provenance')
        task = meta.get('id')
        if not isinstance(task, str) or not re.fullmatch(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', task):
            raise Unproved('malformed-provider-task-id')
        roots.append((task, descriptor))
    if len(roots) != 1:
        raise Unproved('ambiguous-root-thread')
    after = collector.processes()
    if (collector.pane(name) != pane or after.get(pid) != before[pid]
            or after.get(agent_pid) != before[agent_pid]
            or agent_pid not in descendants(after, pid)
            or collector.rollouts(agent_pid) != paths):
        raise Unproved('live-evidence-changed')
    receipt = dict(control_surface='tmux', tmux_session=name, pane_id=pane['pane_id'],
                   pane_pid=str(pid), wrapper_pid=str(pid), pane_started=before[pid]['started'])
    for key, value in receipt.items():
        if record.get(key) not in (None, '', value):
            raise Unproved('existing-anchor-conflict')
    return dict(launch_event_binding=binding, provider_task_id=roots[0][0], agent_pid=agent_pid,
                rollout_descriptor=roots[0][1], receipt=receipt,
                process_started=before[agent_pid]['started'],
                observed_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                evidence_kind='live-native-codex-writable-root-rollout')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--metadata-dir', required=True)
    parser.add_argument('--launch-id', required=True)
    parser.add_argument('--host-id-file', required=True)
    parser.add_argument('--codex-home', required=True)
    parser.add_argument('--launch-event-file')
    parser.add_argument('--launch-event-id')
    args = parser.parse_args()
    result = dict(schema_version=1, kind='terminal_identity_proof', verified=False,
                  provider_task_id=None, reason=None, historical_collisions=[])
    try:
        def expired(*_args):
            raise Unproved('probe-budget-exhausted')
        signal.signal(signal.SIGALRM, expired)
        signal.setitimer(signal.ITIMER_REAL, 8)
        if not re.fullmatch(r'[0-9a-f-]{16,64}', args.launch_id):
            raise Unproved('invalid-launch-id')
        path = Path(args.metadata_dir) / ('launch-' + args.launch_id + '.json')
        record = read_json(path)
        if record.get('provisional_launch_id') != args.launch_id:
            raise Unproved('launch-id-mismatch')
        host_path = Path(args.host_id_file)
        if (host_path.is_symlink() or not re.fullmatch(r'[0-9a-f]{32}', record.get('host_id', ''))
                or record.get('host_id') != host_path.read_text().strip()):
            raise Unproved('host-identity-mismatch')
        # Report collisions without selecting any record by mtime/name/provider.
        for count, other in enumerate(Path(args.metadata_dir).glob('*.json')):
            if count >= 10000:
                raise Unproved('receipt-inventory-budget-exhausted')
            if other == path:
                continue
            value = read_json(other)
            if value.get('tmux_session', value.get('name')) == record.get('tmux_session'):
                result['historical_collisions'].append(other.name)
                if value.get('created_at') == record.get('created_at'):
                    raise Unproved('ambiguous-launch-receipt')
        if bool(args.launch_event_file) != bool(args.launch_event_id):
            raise Unproved('launch-event-file-and-id-required')
        artifact = (load_event(args.launch_event_file, args.launch_event_id, args.codex_home)
                    if args.launch_event_file else None)
        result.update(prove(record, args.codex_home, Collector(), artifact))
        if artifact and load_event(args.launch_event_file, args.launch_event_id, args.codex_home) != artifact:
            raise Unproved('launch-event-changed')
        if read_json(path) != record:
            raise Unproved('launch-record-changed')
        result.update(verified=True, source_record=str(path),
                      expected_source_digest=canonical_digest(record))
    except (Unproved, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as exc:
        result.update(verified=False, provider_task_id=None, reason=str(exc))
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
    print(json.dumps(result, sort_keys=True))
    return 0 if result['verified'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
