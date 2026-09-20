"""Small RFC 6455 client codec for Codex's raw app-server proxy pipes.

The callbacks own I/O and must enforce the supplied absolute monotonic deadline:
read_exact(count, deadline) -> bytes; write(data, deadline) -> None. No sockets,
processes, settings, or provider state are opened by this module.
"""
import base64
import hashlib
import os
import struct
import time

MAX_HEADER = 16 * 1024
MAX_MESSAGE = 16 * 1024 * 1024
_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'


class ProtocolError(ValueError):
    """The peer did not speak the supported RFC 6455 text protocol."""


class WebSocket:
    def __init__(self, read_exact, write):
        self._read_exact = read_exact
        self._write_bytes = write
        self._closed = False

    @staticmethod
    def _check_deadline(deadline):
        if time.monotonic() >= deadline:
            raise TimeoutError('WebSocket deadline exceeded')

    def _read(self, count, deadline):
        self._check_deadline(deadline)
        data = self._read_exact(count, deadline)
        if len(data) != count:
            raise EOFError('WebSocket transport ended mid-frame')
        return data

    def _write(self, data, deadline):
        self._check_deadline(deadline)
        self._write_bytes(data, deadline)

    def handshake(self, deadline, path='/', host='localhost'):
        if not path.startswith('/') or any(c in path + host for c in '\r\n'):
            raise ValueError('Invalid WebSocket request target or host')
        key = base64.b64encode(os.urandom(16)).decode('ascii')
        request = (f'GET {path} HTTP/1.1\r\nHost: {host}\r\n'
                   'Upgrade: websocket\r\nConnection: Upgrade\r\n'
                   f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n')
        self._write(request.encode('ascii'), deadline)
        header = bytearray()
        while not header.endswith(b'\r\n\r\n'):
            if len(header) >= MAX_HEADER:
                raise ProtocolError('WebSocket upgrade header exceeds limit')
            header.extend(self._read(1, deadline))
        try:
            lines = bytes(header).decode('ascii').split('\r\n')
        except UnicodeDecodeError as exc:
            raise ProtocolError('Non-ASCII upgrade header') from exc
        status = lines[0].split(' ', 2)
        if len(status) < 2 or status[:2] != ['HTTP/1.1', '101']:
            raise ProtocolError('WebSocket upgrade was rejected')
        headers = {}
        for line in lines[1:-2]:
            if ':' not in line or line[:1].isspace():
                raise ProtocolError('Malformed upgrade header')
            name, value = line.split(':', 1)
            if not name or any(c.isspace() for c in name):
                raise ProtocolError('Malformed upgrade header name')
            headers.setdefault(name.lower(), []).append(value.strip())
        def tokens(name):
            return {v.strip().lower() for line in headers.get(name, []) for v in line.split(',')}
        expected = base64.b64encode(hashlib.sha1((key + _GUID).encode('ascii')).digest()).decode('ascii')
        if (tokens('upgrade') != {'websocket'} or 'upgrade' not in tokens('connection')
                or headers.get('sec-websocket-accept') != [expected]):
            raise ProtocolError('Invalid WebSocket upgrade response')
        if 'sec-websocket-extensions' in headers or 'sec-websocket-protocol' in headers:
            raise ProtocolError('Unrequested WebSocket extension or subprotocol')

    def _send_frame(self, opcode, payload, deadline):
        if self._closed:
            raise EOFError('WebSocket is closed')
        size = len(payload)
        if size > MAX_MESSAGE or (opcode >= 8 and size > 125):
            raise ProtocolError('Outgoing WebSocket frame exceeds limit')
        mask = os.urandom(4)
        if size < 126:
            header = bytes((0x80 | opcode, 0x80 | size))
        elif size <= 65535:
            header = bytes((0x80 | opcode, 0x80 | 126)) + struct.pack('!H', size)
        else:
            header = bytes((0x80 | opcode, 0x80 | 127)) + struct.pack('!Q', size)
        masked = bytes(value ^ mask[i % 4] for i, value in enumerate(payload))
        self._write(header + mask + masked, deadline)

    def send_text(self, text, deadline):
        self._send_frame(1, text.encode('utf-8'), deadline)

    def receive_text(self, deadline):
        if self._closed:
            raise EOFError('WebSocket is closed')
        message = bytearray()
        fragmented = False
        while True:
            first, second = self._read(2, deadline)
            fin, opcode = bool(first & 0x80), first & 0x0F
            if first & 0x70 or second & 0x80:
                raise ProtocolError('Unsupported RSV bits or masked server frame')
            if opcode not in (0, 1, 8, 9, 10):
                raise ProtocolError('Unsupported WebSocket opcode')
            size = second & 0x7F
            if opcode >= 8 and (not fin or size > 125):
                raise ProtocolError('Invalid WebSocket control frame')
            if size == 126:
                size = struct.unpack('!H', self._read(2, deadline))[0]
                if size < 126:
                    raise ProtocolError('Nonminimal WebSocket frame length')
            elif size == 127:
                size = struct.unpack('!Q', self._read(8, deadline))[0]
                if size < 65536 or size & (1 << 63):
                    raise ProtocolError('Invalid WebSocket frame length')
            if size > MAX_MESSAGE or (opcode < 8 and len(message) + size > MAX_MESSAGE):
                raise ProtocolError('WebSocket message exceeds limit')
            if opcode == 0 and not fragmented:
                raise ProtocolError('Unexpected continuation frame')
            if opcode == 1 and fragmented:
                raise ProtocolError('Text frame interrupted fragmented message')
            payload = self._read(size, deadline) if size else b''
            if opcode == 8:
                if len(payload) == 1:
                    raise ProtocolError('Invalid close payload')
                if payload:
                    code = struct.unpack('!H', payload[:2])[0]
                    if code not in (1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014) and not 3000 <= code <= 4999:
                        raise ProtocolError('Invalid WebSocket close code')
                    self._decode(payload[2:])
                self._send_frame(8, payload, deadline)
                self._closed = True
                raise EOFError('WebSocket peer closed the connection')
            if opcode == 9:
                self._send_frame(10, payload, deadline)
                continue
            if opcode == 10:
                continue
            message.extend(payload)
            if fin:
                return self._decode(message)
            fragmented = True

    @staticmethod
    def _decode(payload):
        try:
            return payload.decode('utf-8')
        except UnicodeDecodeError as exc:
            raise ProtocolError('WebSocket text is not valid UTF-8') from exc
