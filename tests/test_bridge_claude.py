#!/usr/bin/env python3
"""Isolated native socket/process fixtures; never inspect existing user sessions."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / 'lib/bridge_claude.py'
spec = importlib.util.spec_from_file_location('bridge_claude', MODULE)
bc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bc)


class ClaudeTransportTests(unittest.TestCase):
    def setUp(self):
        base = '/private/tmp' if sys.platform == 'darwin' else '/tmp'
        self.tmp = tempfile.TemporaryDirectory(prefix='cctrl-claude-', dir=base)
        self.root = Path(self.tmp.name)
        self.received = queue.Queue()
        self.endpoint = bc.ClaudeEndpoint('cctrl-test', 'cctrl-bridge-test',
                                         lambda frame, sender: self.received.put((frame, sender)),
                                         config_dir=self.root / 'config', socket_dir=self.root / 's')
        self.endpoint.open()

    def tearDown(self):
        self.endpoint.close()
        self.tmp.cleanup()

    def own_target(self):
        return bc.discover_sessions(self.root / 'config')[0]

    def raw_send(self, frames):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.connect(self.endpoint.socket_path)
            for frame in frames:
                connection.sendall((json.dumps(frame) + '\n').encode())
            if sys.platform == 'darwin':
                time.sleep(0.15)
            try:
                connection.shutdown(socket.SHUT_WR)
            except OSError:
                pass  # A rejecting server may have already closed the connection.

    def frame(self, **extra):
        return {'msgV': 1, 'msg_id': str(uuid.uuid4()), 'type': 'user',
                'message': {'role': 'user', 'content': 'fixture'},
                'from': self.endpoint.address, **extra}

    def wait_error(self):
        until = time.monotonic() + 2
        while not self.endpoint.errors and time.monotonic() < until:
            time.sleep(0.01)
        self.assertTrue(self.endpoint.errors)
        self.assertTrue(self.received.empty())

    def test_real_process_discovery_and_private_owned_lifecycle(self):
        records = bc.discover_sessions(self.root / 'config')
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]['pid'], os.getpid())
        self.assertEqual(records[0]['proc_start'], bc.process_start(os.getpid()))
        for path in self.endpoint._owned:
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        resources = self.endpoint.owned_resources
        self.assertEqual({row['path'] for row in resources}, {str(p) for p in self.endpoint._owned})
        self.assertTrue(all(row['inode'] > 0 and row['device'] >= 0 for row in resources))
        resources.clear()
        self.assertTrue(self.endpoint.owned_resources)  # Caller mutation cannot erase ownership.
        paths = list(self.endpoint._owned)
        self.endpoint.close()
        self.assertEqual(self.endpoint.owned_resources, [])
        self.assertTrue(all(not p.exists() for p in paths))
        self.endpoint.close()  # Idempotent after completed cleanup.

    def test_authenticated_self_fixture_transfers_and_preserves_verifiable_origin(self):
        result = self.endpoint.send(self.own_target(), 'hello <tag> & goodbye')
        self.assertEqual(result['status'], 'submitted')
        frame, sender = self.received.get(timeout=2)
        self.assertEqual(frame['msg_id'], result['msg_id'])
        self.assertEqual(frame['session_id'], 'cctrl-bridge-test')
        self.assertEqual(sender['pid'], os.getpid())
        self.assertEqual(sender['uid'], os.getuid())
        self.assertTrue(sender['verified'])
        self.assertIn('from-mode="prompting"', frame['message']['content'])
        self.assertIn('hello <tag> & goodbye', frame['message']['content'])

    def test_missing_auth_and_wrong_auth_are_rejected(self):
        self.raw_send([self.frame()])
        self.wait_error()
        self.endpoint.errors.clear()
        self.raw_send([{'type': 'auth', 'token': '0' * 32}, self.frame()])
        self.wait_error()

    def test_forged_reply_address_is_rejected_after_auth(self):
        self.raw_send([{'type': 'auth', 'token': self.endpoint._token},
                       self.frame(**{'from': 'uds:/tmp/unowned-fixture.sock'})])
        self.wait_error()

    def test_recipient_session_mismatch_is_rejected(self):
        self.raw_send([{'type': 'auth', 'token': self.endpoint._token},
                       self.frame(session_id='some-other-session')])
        self.wait_error()

    def test_control_receipt_is_delivered_as_control_not_chat(self):
        original = str(uuid.uuid4())
        result = self.endpoint.send_control(self.own_target(), 'peer_message_status',
                                            status='held', orig_msg_id=original)
        self.assertEqual(result['status'], 'submitted')
        frame, sender = self.received.get(timeout=2)
        self.assertEqual(frame['type'], 'control')
        self.assertEqual(frame['orig_msg_id'], original)
        self.assertEqual(sender['session_id'], 'cctrl-bridge-test')

    def test_unknown_control_rejected_without_consumer_call(self):
        self.raw_send([{'type': 'auth', 'token': self.endpoint._token},
                       {'msg_id': str(uuid.uuid4()), 'type': 'control', 'action': 'rename',
                        'from': self.endpoint.address}])
        self.wait_error()

    def test_oversized_frame_fails_before_connect(self):
        with patch.object(bc, 'MAX_FRAME', 200):
            result = self.endpoint.send(self.own_target(), 'x' * 1000)
        self.assertEqual(result['status'], 'failed')
        self.assertTrue(self.received.empty())

    def test_incoming_connection_bound(self):
        with patch.object(bc, 'MAX_FRAME', 100):
            self.raw_send([{'type': 'auth', 'token': self.endpoint._token}, self.frame()])
            self.wait_error()

    def test_changed_session_identity_prevents_send(self):
        target = self.own_target()
        target['session_id'] = 'changed'
        self.assertEqual(self.endpoint.send(target, 'fixture')['status'], 'failed')
        self.assertTrue(self.received.empty())

    def test_wrong_connected_endpoint_identity_prevents_writing(self):
        with patch.object(bc, 'peer_credentials', return_value=(os.getpid() + 1, os.getuid())):
            result = self.endpoint.send(self.own_target(), 'fixture')
        self.assertEqual(result['status'], 'failed')
        self.assertTrue(self.received.empty())

    def test_send_error_after_write_starts_is_ambiguous_never_retried(self):
        target = self.own_target()
        real_socket = socket.socket
        class FailingSend:
            def __init__(self, *args):
                self.connection = real_socket(*args)
                self.calls = 0
            def __enter__(self):
                return self
            def __exit__(self, *args):
                self.connection.close()
            def __getattr__(self, name):
                return getattr(self.connection, name)
            def sendall(self, packet):
                self.calls += 1
                self.connection.sendall(packet[:20])
                raise OSError('fixture lost write completion')
        created = []
        def construct(*args, **kwargs):
            if "fileno" in kwargs:
                return real_socket(*args, **kwargs)
            item = FailingSend(*args)
            created.append(item)
            return item
        with patch.object(bc.socket, 'socket', side_effect=construct):
            result = self.endpoint.send(target, 'fixture')
        self.assertEqual(result['status'], 'ambiguous')
        self.assertEqual(sum(item.calls for item in created), 1)

    def test_existing_record_is_not_overwritten_and_own_partial_start_is_cleaned(self):
        # A second endpoint in this real process must not take over its registry.
        other = bc.ClaudeEndpoint('cctrl-other', 'cctrl-bridge-other', lambda *_: None,
                                 config_dir=self.root / 'config', socket_dir=self.root / 'other')
        with self.assertRaises(FileExistsError):
            other.open()
        self.assertFalse(Path(other.socket_path).exists())
        self.assertEqual(self.own_target()['name'], 'cctrl-test')

    def test_cleanup_preserves_replaced_resource_and_retains_ownership(self):
        path = self.root / 'config' / 'sessions' / f'{os.getpid()}.json'
        original = path.with_suffix('.saved')
        path.rename(original)
        path.write_text('{}')
        with self.assertRaises(bc.CleanupError):
            self.endpoint.close()
        self.assertEqual(path.read_text(), '{}')
        self.assertIn(path, self.endpoint._owned)
        self.assertIn(str(path), [row['path'] for row in self.endpoint.owned_resources])
        path.unlink()
        original.rename(path)
        self.endpoint.close()

    def test_symlink_record_and_stale_process_are_ignored(self):
        path = self.root / 'config' / 'sessions' / f'{os.getpid()}.json'
        saved = path.with_suffix('.saved')
        path.rename(saved)
        path.symlink_to(saved)
        self.assertEqual(bc.discover_sessions(self.root / 'config'), [])
        path.unlink()
        saved.rename(path)
        with patch.object(bc, 'process_start', return_value='different-start'):
            self.assertEqual(bc.discover_sessions(self.root / 'config'), [])

    def test_live_second_process_bidirectional_native_messages_and_receipts(self):
        script = r'''
import importlib.util,json,sys,time
from pathlib import Path
spec=importlib.util.spec_from_file_location('fixture_transport',sys.argv[1])
bc=importlib.util.module_from_spec(spec);spec.loader.exec_module(bc)
def received(frame,sender):
    if frame['type']=='user':
        endpoint.send_control(sender,'peer_message_status',status='held',orig_msg_id=frame['msg_id'])
        endpoint.send(sender,'child reply')
endpoint=bc.ClaudeEndpoint('cctrl-child','cctrl-bridge-child',received,config_dir=sys.argv[2],socket_dir=sys.argv[3]).open()
print(json.dumps({'pid':endpoint.pid}),flush=True)
try: sys.stdin.readline()
finally: endpoint.close()
'''
        child = subprocess.Popen([sys.executable, '-u', '-c', script, str(MODULE),
                                  str(self.root / 'config'), str(self.root / 's')],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
        try:
            ready = json.loads(child.stdout.readline())
            target = next(row for row in bc.discover_sessions(self.root / 'config') if row['pid'] == ready['pid'])
            result = self.endpoint.send(target, 'parent fixture')
            self.assertEqual(result['status'], 'submitted')
            frames = [self.received.get(timeout=4), self.received.get(timeout=4)]
            self.assertTrue(all(sender['pid'] == child.pid for _, sender in frames))
            receipt = next(frame for frame, _ in frames if frame['type'] == 'control')
            self.assertEqual(receipt['orig_msg_id'], result['msg_id'])
            reply = next(frame for frame, _ in frames if frame['type'] == 'user')
            self.assertIn('child reply', reply['message']['content'])
        finally:
            child.communicate('\n', timeout=8)
        self.assertEqual(child.returncode, 0)
        self.assertEqual(len(bc.discover_sessions(self.root / 'config')), 1)


class PureProtocolTests(unittest.TestCase):
    def test_key_hash_uses_lexical_raw_path_without_uds_or_realpath(self):
        self.assertEqual(bc.key_filename(123, '/tmp/a/../peer.sock'),
                         '123.' + hashlib.sha256(b'/tmp/peer.sock').hexdigest() + '.key')
        self.assertNotEqual(bc.key_filename(123, '/tmp/peer.sock'),
                            bc.key_filename(123, '/private/tmp/peer.sock'))

    def test_body_preserves_literal_text_and_escapes_closing_wrapper(self):
        self.assertEqual(bc._escape_body('a < b &amp; <tag>'), 'a < b &amp; <tag>')
        self.assertEqual(bc._escape_body('</Cross-Session-Message>'), '<' + chr(92) + '/Cross-Session-Message>')

    def test_unavailable_or_wrong_os_peer_uid_fails_closed(self):
        with patch.object(bc.sys, 'platform', 'unsupported'):
            with self.assertRaises(bc.ProtocolError):
                bc.peer_credentials(None)

    def test_controls_and_content_arrays_do_not_become_chat(self):
        invalid = [{'type': 'user', 'msg_id': 'a', 'message': {'content': []}},
                   {'type': 'control', 'msg_id': 'a', 'action': 'peer_message_status', 'status': 'held'},
                   {'type': 'other', 'msg_id': 'a'}]
        for frame in invalid:
            with self.subTest(frame=frame), self.assertRaises(bc.ProtocolError):
                bc.parse_frame(frame)


if __name__ == '__main__':
    unittest.main()
