"""Isolated raw-proxy regression: control socket speaks WebSocket, not JSONL."""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('codex_app_server', ROOT / 'lib/codex_app_server.py')
adapter = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = adapter
spec.loader.exec_module(adapter)

PROXY = r'''#!/usr/bin/env python3
import base64, hashlib, json, os, struct, sys, time
r=sys.stdin.buffer; w=sys.stdout.buffer
if os.environ.get('WS_TEST_MODE') == 'silent':
    time.sleep(3); sys.exit()
headers={}
assert r.readline() == b'GET / HTTP/1.1\r\n'
while True:
    line=r.readline()
    if line == b'\r\n': break
    k,v=line.decode().split(':',1); headers[k.lower()]=v.strip()
accept=base64.b64encode(hashlib.sha1((headers['sec-websocket-key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
if os.environ.get('WS_TEST_MODE') == 'bad-accept': accept='invalid'
w.write(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n\r\n').encode()); w.flush()
def send(value):
    data=json.dumps(value).encode(); n=len(data)
    w.write(b'\x81'+(bytes([n]) if n<126 else b'\x7e'+struct.pack('!H',n))+data); w.flush()
while True:
    head=r.read(2)
    if not head: break
    assert head[0] == 0x81 and head[1]&128
    n=head[1]&127
    if n==126: n=struct.unpack('!H',r.read(2))[0]
    if n==127: n=struct.unpack('!Q',r.read(8))[0]
    mask=r.read(4); data=r.read(n)
    msg=json.loads(bytes(c^mask[i%4] for i,c in enumerate(data)))
    if msg['method']=='initialized': continue
    if msg['method']=='initialize':
        send({'id':msg['id'],'result':{'userAgent':'fixture','codexHome':'/fixture','platformFamily':'unix','platformOs':'macos'}})
    elif msg['method']=='thread/list': send({'id':msg['id'],'result':{'data':[{'id':'exact-thread'}],'nextCursor':None}})
    else: raise AssertionError('unexpected method')
'''

class ProxyIntegrationTests(unittest.TestCase):
    def run_client(self, mode='success'):
        with tempfile.TemporaryDirectory() as td:
            proxy=Path(td)/'codex'; proxy.write_text(PROXY); proxy.chmod(0o700)
            with patch.dict(os.environ, {'CCTRL_CODEX_APP_SERVER_TRANSPORT':'websocket', 'WS_TEST_MODE':mode}):
                client=adapter.AppServerClient(adapter.Runtime(str(proxy),'fixture','0.153.4'),
                    socket_path='/fixture/no-live-socket',
                    timeouts=adapter.Timeouts(connect=.5,handshake=.25 if mode == 'silent' else 1,request=.5,inactivity=.5,terminate=.1))
                try:
                    with client:
                        process=client.process
                        client.initialize()
                        result=client.thread_list()
                finally:
                    self.assertIsNotNone(process.poll(), 'owned proxy must be reaped')
                return result

    def test_send_codec_errors_are_normalized(self):
        with patch.dict(os.environ, {'CCTRL_CODEX_APP_SERVER_TRANSPORT':'websocket'}):
            client=adapter.AppServerClient(adapter.Runtime('/unused','fixture','0.153.4'))
        for error, code in [(adapter.ProtocolError('too large'), adapter.EXIT_PROTOCOL),
                            (TimeoutError('deadline'), adapter.EXIT_HANDSHAKE),
                            (EOFError('closed'), adapter.EXIT_EOF)]:
            with self.subTest(code=code), patch.object(client._websocket, 'send_text', side_effect=error):
                with self.assertRaises(adapter.AdapterError) as caught:
                    client._send({'method':'initialize'},deadline=time.monotonic()+1,
                                 phase='handshake',timeout_exit=adapter.EXIT_HANDSHAKE)
                self.assertEqual(caught.exception.exit_code, code)

    def test_reader_transport_error_keeps_exit_code(self):
        client=adapter.AppServerClient(adapter.Runtime('/unused','fixture','0.153.4'))
        error=adapter.AdapterError(adapter.EXIT_REQUEST_TIMEOUT, 'transport', 'pong write timed out')
        client._events.put(('error', error))
        with self.assertRaises(adapter.AdapterError) as caught:
            client._wait_for_response(1,phase='request',deadline=time.monotonic()+1,
                                      timeout_exit=adapter.EXIT_REQUEST_TIMEOUT)
        self.assertIs(caught.exception, error)

    def test_websocket_initialize_and_inventory(self):
        self.assertEqual(self.run_client()['data'], [{'id':'exact-thread'}])

    def test_invalid_upgrade_fails_closed(self):
        with self.assertRaises(adapter.AdapterError) as caught: self.run_client('bad-accept')
        self.assertEqual(caught.exception.exit_code, adapter.EXIT_PROTOCOL)

    def test_silent_upgrade_shares_handshake_deadline(self):
        start=time.monotonic()
        with self.assertRaises(adapter.AdapterError) as caught: self.run_client('silent')
        self.assertEqual(caught.exception.exit_code, adapter.EXIT_HANDSHAKE)
        self.assertLess(time.monotonic()-start, 1.5)

if __name__=='__main__': unittest.main()
