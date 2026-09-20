#!/usr/bin/env python3
"""Pure in-memory protocol fixtures: no live processes or connections."""
import base64
import hashlib
import importlib.util
from pathlib import Path
import struct
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('codex_websocket', Path(__file__).resolve().parents[1] / 'lib/codex_websocket.py')
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)


def frame(payload=b'', opcode=1, fin=True):
    size = len(payload)
    first = (0x80 if fin else 0) | opcode
    if size < 126:
        return bytes((first, size)) + payload
    if size < 65536:
        return bytes((first, 126)) + struct.pack('!H', size) + payload
    return bytes((first, 127)) + struct.pack('!Q', size) + payload


def unmask(data):
    assert data[1] & 0x80
    size, offset = data[1] & 127, 2
    if size == 126:
        size, offset = struct.unpack('!H', data[2:4])[0], 4
    elif size == 127:
        size, offset = struct.unpack('!Q', data[2:10])[0], 10
    mask = data[offset:offset + 4]
    payload = data[offset + 4:]
    assert len(payload) == size
    return data[0] & 15, bytes(v ^ mask[i % 4] for i, v in enumerate(payload))


class Memory:
    def __init__(self, data=b''):
        self.data = data
        self.writes = []
        self.read_sizes = []

    def read(self, count, deadline):
        self.read_sizes.append(count)
        data, self.data = self.data[:count], self.data[count:]
        return data

    def write(self, data, deadline):
        self.writes.append(data)

    def client(self):
        return ws.WebSocket(self.read, self.write)


class WebSocketTests(unittest.TestCase):
    def setUp(self):
        self.deadline = time.monotonic() + 10

    def upgrade(self, change=None, tail=b''):
        mem = Memory()
        def write(request, deadline):
            mem.write(request, deadline)
            key = request.split(b'Sec-WebSocket-Key: ')[1].split(b'\r\n')[0]
            self.assertEqual(len(base64.b64decode(key)), 16)
            accept = base64.b64encode(hashlib.sha1(key + ws._GUID.encode()).digest())
            response = (b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n'
                        b'Connection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
            mem.data = (change(response) if change else response) + tail
        return mem, ws.WebSocket(mem.read, write)

    def test_upgrade_validates_challenge_and_preserves_first_frame(self):
        mem, client = self.upgrade(tail=frame(b'{"id":1}'))
        client.handshake(self.deadline)
        self.assertEqual(client.receive_text(self.deadline), '{"id":1}')
        self.assertIn(b'Sec-WebSocket-Version: 13\r\n', mem.writes[0])

    def test_upgrade_rejects_status_bad_accept_and_extensions(self):
        changes = [lambda h: h.replace(b'101', b'200', 1),
                   lambda h: h.replace(b'Sec-WebSocket-Accept: ', b'Sec-WebSocket-Accept: invalid'),
                   lambda h: h.replace(b'\r\n\r\n', b'\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n'),
                   lambda h: h.replace(b'Upgrade: websocket', b'Upgrade: other'),
                   lambda h: h.replace(b'Connection: keep-alive, Upgrade', b'Connection: close')]
        for change in changes:
            with self.subTest(change=change):
                _, client = self.upgrade(change)
                with self.assertRaises(ws.ProtocolError):
                    client.handshake(self.deadline)

    def test_upgrade_header_cap_and_truncation(self):
        mem = Memory(b'x' * (ws.MAX_HEADER + 1))
        with self.assertRaises(ws.ProtocolError):
            mem.client().handshake(self.deadline)
        self.assertEqual(len(mem.read_sizes), ws.MAX_HEADER)
        with self.assertRaises(EOFError):
            Memory(b'HTTP/1.1').client().handshake(self.deadline)

    def test_client_masking_and_all_length_encodings(self):
        for size in (0, 125, 126, 65535, 65536):
            with self.subTest(size=size):
                mem = Memory()
                mem.client().send_text('x' * size, self.deadline)
                self.assertEqual(unmask(mem.writes[0]), (1, b'x' * size))

    def test_receive_length_encodings_and_multiple_messages(self):
        mem = Memory(b''.join(frame(b'x' * size) for size in (0, 125, 126, 65535, 65536)))
        client = mem.client()
        for size in (0, 125, 126, 65535, 65536):
            self.assertEqual(client.receive_text(self.deadline), 'x' * size)

    def test_fragmented_utf8_with_interleaved_ping_and_pong(self):
        payload = '{"text":"☺"}'.encode()
        mem = Memory(frame(payload[:10], fin=False) + frame(b'probe', opcode=9)
                     + frame(b'pong', opcode=10) + frame(payload[10:], opcode=0))
        self.assertEqual(mem.client().receive_text(self.deadline), payload.decode())
        self.assertEqual(unmask(mem.writes[0]), (10, b'probe'))

    def test_close_echo_and_closed_state(self):
        payload = struct.pack('!H', 1000) + b'bye'
        mem = Memory(frame(payload, opcode=8))
        client = mem.client()
        with self.assertRaises(EOFError):
            client.receive_text(self.deadline)
        self.assertEqual(unmask(mem.writes[0]), (8, payload))
        with self.assertRaises(EOFError):
            client.send_text('after close', self.deadline)

    def test_rejects_bad_framing_and_text(self):
        invalid = [b'\xc1\x00', b'\x81\x80', frame(b'', opcode=2), frame(b'', opcode=0),
                   frame(b'a', fin=False) + frame(b'b'), frame(b'', opcode=9, fin=False),
                   b'\x89\x7e', b'\x81\x7e\x00\x01', b'\x81\x7f' + struct.pack('!Q', 1 << 63),
                   frame(b'\xff'), frame(b'x', opcode=8), frame(struct.pack('!H', 1005), opcode=8),
                   frame(struct.pack('!H', 1000) + b'\xff', opcode=8)]
        for data in invalid:
            with self.subTest(data=data):
                with self.assertRaises(ws.ProtocolError):
                    Memory(data).client().receive_text(self.deadline)

    def test_caps_before_payload_read_and_aggregate_fragments(self):
        mem = Memory(b'\x81\x7f' + struct.pack('!Q', ws.MAX_MESSAGE + 1))
        with self.assertRaises(ws.ProtocolError):
            mem.client().receive_text(self.deadline)
        self.assertEqual(mem.read_sizes, [2, 8])
        with patch.object(ws, 'MAX_MESSAGE', 4):
            with self.assertRaises(ws.ProtocolError):
                Memory(frame(b'abc', fin=False) + frame(b'de', opcode=0)).client().receive_text(self.deadline)
            with self.assertRaises(ws.ProtocolError):
                Memory().client().send_text('abcde', self.deadline)

    def test_truncation_and_deadline_fail_closed(self):
        with self.assertRaises(EOFError):
            Memory(b'\x81\x03a').client().receive_text(self.deadline)
        mem = Memory(frame(b'json'))
        with self.assertRaises(TimeoutError):
            mem.client().receive_text(time.monotonic() - 1)
        self.assertEqual(mem.read_sizes, [])


if __name__ == '__main__':
    unittest.main()
