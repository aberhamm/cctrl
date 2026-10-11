#!/usr/bin/env python3
"""Single-attempt mailbox wakeup through the existing desktop App Server."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
from contextlib import contextmanager
import sys
from codex_app_server import AppServerClient, Timeouts, discover_runtime, AdapterError



class OperationTimeout(TimeoutError):
    """The entire helper operation exhausted its bounded mailbox-lock budget."""


@contextmanager
def operation_deadline(seconds):
    if not isinstance(seconds, (int, float)) or not 0 < seconds <= 4:
        raise ValueError('overall timeout must be positive and at most 4 seconds')
    previous_handler = signal.getsignal(signal.SIGALRM)
    previous_timer = signal.getitimer(signal.ITIMER_REAL)
    def expired(signum, frame):
        raise OperationTimeout('overall desktop delivery operation timed out')
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        if previous_timer[0] or previous_timer[1]:
            signal.setitimer(signal.ITIMER_REAL, *previous_timer)


def error_detail(exc):
    if isinstance(exc, AdapterError):
        return exc.as_dict()
    if isinstance(exc, OperationTimeout):
        return {'phase': 'overall-operation', 'reason': str(exc)}
    return None


def save_receipt(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f'.{os.getpid()}.tmp')
    with temporary.open('x') as handle:
        json.dump(value, handle)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def checked_thread(response, thread_id, cwd):
    thread = response.get('thread') if isinstance(response, dict) else None
    if not isinstance(thread, dict) or thread.get('id') != thread_id:
        raise ValueError('thread/read returned a different or malformed thread')
    if not isinstance(thread.get('cwd'), str) or os.path.realpath(thread['cwd']) != os.path.realpath(cwd):
        raise ValueError('thread cwd does not match registered peer')
    if thread.get('archived') is True:
        raise ValueError('thread is archived')
    return thread


def marker_present(value, marker):
    # Only user message text is evidence of submission; agent echoes are not.
    for turn in value.get('turns', []):
        if not isinstance(turn, dict):
            raise ValueError('malformed turn history')
        for item in turn.get('items', []):
            if isinstance(item, dict) and item.get('type') == 'userMessage':
                for content in item.get('content', []):
                    if isinstance(content, dict) and content.get('type') == 'text' and marker in content.get('text', ''):
                        return True
    return False


def deliver(client, *, thread_id, cwd, body, attempt_id, receipt_file, app_owned, dry_run=False, verify_only=False, codex_home=None):
    if not app_owned:
        return {'status': 'failed', 'reason': 'verified app ownership assertion required'}
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,160}', thread_id):
        return {'status': 'failed', 'reason': 'invalid thread ID'}
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,160}', attempt_id):
        return {'status': 'failed', 'reason': 'invalid attempt ID'}
    marker = f'[cctrl-delivery:{attempt_id}]'
    receipt = {'thread_id': thread_id, 'attempt_id': attempt_id, 'body_sha256': hashlib.sha256(body.encode()).hexdigest()}
    submitted = False
    try:
        old = None
        if receipt_file and Path(receipt_file).exists():
            old = json.loads(Path(receipt_file).read_text())
            if any(old.get(key) != value for key, value in receipt.items()):
                raise ValueError('receipt identity or body mismatch')
        if codex_home is not None:
            if not isinstance(codex_home, str) or not os.path.isabs(codex_home):
                raise ValueError('connected server returned invalid codexHome')
            lock = Path(codex_home) / 'thread-writer-locks' / (thread_id + '.lock')
            if lock.exists():
                cursor = None
                seen = set()
                found = False
                for _ in range(100):
                    params = {'limit': 1000}
                    if cursor is not None:
                        params['cursor'] = cursor
                    loaded = client.request('thread/loaded/list', params)
                    ids = loaded.get('data') if isinstance(loaded, dict) else None
                    if not isinstance(ids, list) or any(not isinstance(item, str) for item in ids):
                        raise ValueError('malformed loaded-thread ownership response')
                    if thread_id in ids:
                        found = True
                        break
                    cursor = loaded.get('nextCursor')
                    if cursor is None:
                        break
                    if not isinstance(cursor, str) or not cursor or cursor in seen:
                        raise ValueError('invalid loaded-thread pagination cursor')
                    seen.add(cursor)
                if not found:
                    raise ValueError('writer lock belongs to a thread not loaded by connected desktop server')
        thread = checked_thread(client.thread_read(thread_id, include_turns=False), thread_id, cwd)
        if old and old.get('outcome') == 'accepted' and isinstance(old.get('turn_id'), str) and old['turn_id']:
            return {'status': 'accepted', 'turn_id': old['turn_id'], 'reason': 'previous submission receipt confirmed'}
        if old and old.get('outcome') in {'submitted', 'ambiguous', 'accepted'}:
            try:
                history = checked_thread(client.thread_read(thread_id, include_turns=True), thread_id, cwd)
                if marker_present(history, marker):
                    if not dry_run and receipt_file:
                        save_receipt(receipt_file, {**receipt, 'outcome': 'accepted'})
                    return {'status': 'accepted', 'reason': 'submission reconciled from user-message history'}
            except Exception as exc:
                result = {'status': 'ambiguous', 'reason': 'cannot reconcile previous submission; automatic retry prohibited: ' + str(exc)}
                if error_detail(exc) is not None:
                    result['error'] = error_detail(exc)
                return result
            return {'status': 'ambiguous', 'reason': 'previous submission is not yet visible; automatic retry prohibited'}
        status = thread.get('status')
        kind = status.get('type') if isinstance(status, dict) else None
        if verify_only:
            return {'status': 'verified' if kind in {'idle', 'notLoaded', 'active'} else 'failed', 'reason': 'exact thread and cwd checked'}
        if kind not in {'idle', 'notLoaded'}:
            return {'status': 'deferred', 'reason': f'thread status is {kind or "unknown"}'}
        if any(isinstance(turn, dict) and turn.get('status') == 'inProgress' for turn in thread.get('turns', [])):
            return {'status': 'deferred', 'reason': 'thread has an active turn'}
        if dry_run:
            return {'status': 'deferred', 'reason': 'dry run; ready for submission'}
        if not receipt_file:
            raise ValueError('receipt file required')
        if kind == 'notLoaded':
            checked_thread(client.request('thread/resume', {'threadId': thread_id, 'excludeTurns': True}), thread_id, cwd)
            thread = checked_thread(client.thread_read(thread_id, include_turns=False), thread_id, cwd)
            if thread.get('status', {}).get('type') != 'idle':
                return {'status': 'deferred', 'reason': 'resumed thread is not idle'}
        # Persist uncertainty before the only delivery mutation. Never retry here.
        save_receipt(receipt_file, {**receipt, 'outcome': 'submitted'})
        submitted = True
        response = client.turn_start(thread_id, [{'type': 'text', 'text': marker + '\n' + body}])
        turn = response.get('turn') if isinstance(response, dict) else None
        if not isinstance(turn, dict) or not isinstance(turn.get('id'), str) or not turn['id']:
            raise ValueError('malformed turn/start response')
        save_receipt(receipt_file, {**receipt, 'outcome': 'accepted', 'turn_id': turn['id']})
        return {'status': 'accepted', 'turn_id': turn['id']}
    except Exception as exc:
        if submitted:
            try:
                save_receipt(receipt_file, {**receipt, 'outcome': 'ambiguous'})
            except OSError:
                pass
        result = {'status': 'ambiguous' if submitted else 'failed', 'reason': str(exc)}
        if error_detail(exc) is not None:
            result['error'] = error_detail(exc)
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('thread-id', 'expected-cwd'):
        parser.add_argument('--' + name, required=True)
    for name in ('body-file', 'receipt-file', 'codex'):
        parser.add_argument('--' + name)
    parser.add_argument('--attempt-id', default='verify')
    for name in ('app-owned', 'dry-run', 'verify-only'):
        parser.add_argument('--' + name, action='store_true')
    parser.add_argument('--overall-timeout', type=float, default=4.0)
    args = parser.parse_args()
    result = None
    try:
        with operation_deadline(args.overall_timeout):
            if not args.verify_only and (not args.body_file or not args.receipt_file):
                raise ValueError('--body-file and --receipt-file required for delivery')
            body = Path(args.body_file).read_text() if args.body_file else ''
            runtime = discover_runtime(args.codex or os.environ.get('CCTRL_CODEX_BIN'))
            with AppServerClient(runtime, socket_path=os.environ.get('CCTRL_CODEX_APP_SERVER_SOCKET') or None, timeouts=Timeouts(terminate=0.05)) as client:
                facts = client.initialize()
                if not isinstance(facts.get('codexHome'), str) or not os.path.isabs(facts['codexHome']):
                    raise ValueError('connected server returned invalid codexHome')
                from codex_app_server import _extract_version
                if _extract_version(facts.get('userAgent', '')) != runtime.cli_version:
                    raise ValueError('Codex executable does not match connected desktop daemon')
                result = deliver(client, thread_id=args.thread_id, cwd=args.expected_cwd, body=body, attempt_id=args.attempt_id, receipt_file=args.receipt_file, app_owned=args.app_owned, dry_run=args.dry_run, verify_only=args.verify_only, codex_home=facts.get("codexHome"))
    except Exception as exc:
        # Cleanup cannot revoke a persisted submission receipt. Preserve uncertainty
        # so callers never clear its attempt identity and submit a duplicate.
        if result is not None and result.get('status') in {'accepted', 'ambiguous'}:
            result['cleanup_error'] = error_detail(exc) or {'reason': str(exc)}
        else:
            result = {'status': 'failed', 'reason': str(exc)}
            if error_detail(exc) is not None:
                result['error'] = error_detail(exc)
    print(json.dumps(result))
    return 0 if result['status'] in {'accepted', 'verified', 'deferred', 'ambiguous'} else 1

if __name__ == '__main__':
    sys.exit(main())
