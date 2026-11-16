"""Version-pinned Claude JSONL peer transport for the cctrl bridge daemon.

The listener and all sends belong to this process: Claude binds reverse receipts
to the connecting OS PID. Transfer acceptance is never a read/handling ACK.
"""
import ctypes
import hashlib
import hmac
import html
import json
import os
from pathlib import Path
import re
import secrets
import socket
import stat
import struct
import subprocess
import sys
import threading
import time
from urllib.parse import quote, unquote
import uuid

MAX_FRAME = 1024 * 1024
MAX_RECORD = 256 * 1024
_STATUSES = {'held', 'denied', 'expired', 'delivered', 'refused', 'dropped'}
_CONTROLS = {'peer_message_status', 'notify_when_idle', 'peer_idle_notice'}


class ProtocolError(ValueError):
    """An endpoint, identity or frame could not be verified."""


class CleanupError(RuntimeError):
    """Owned resources remain unresolved and must not be forgotten."""


def config_path(config_dir=None):
    return Path(config_dir or os.environ.get('CLAUDE_CONFIG_DIR') or Path.home() / '.claude').resolve()


def process_start(pid):
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 1:
        return None
    try:
        result = subprocess.run(['ps', '-o', 'lstart=', '-p', str(pid)],
                                capture_output=True, text=True, timeout=2,
                                env={**os.environ, 'LC_ALL': 'C', 'TZ': 'UTC'}, check=False)
        return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def peer_credentials(connection):
    """Return verified OS (pid, uid), failing closed on unsupported platforms."""
    if sys.platform.startswith('linux'):
        pid, uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        return pid, uid
    if sys.platform == 'darwin':
        pid = struct.unpack('i', connection.getsockopt(0, 2, 4))[0]  # SOL_LOCAL / LOCAL_PEERPID
        libc = ctypes.CDLL(None, use_errno=True)
        uid, gid = ctypes.c_uint(), ctypes.c_uint()
        if libc.getpeereid(connection.fileno(), ctypes.byref(uid), ctypes.byref(gid)) != 0:
            raise OSError(ctypes.get_errno(), 'getpeereid failed')
        return pid, uid.value
    raise ProtocolError('Verified Unix peer credentials are unavailable on this platform')


def canonical_socket(path):
    value = os.fspath(path)
    if not os.path.isabs(value) or '\x00' in value or value.startswith('//'):
        raise ProtocolError('Expected an absolute local Unix socket path')
    return os.path.abspath(value)  # Claude path.resolve; intentionally not realpath.


def key_filename(pid, path):
    return f'{pid}.{hashlib.sha256(canonical_socket(path).encode()).hexdigest()}.key'


def _json_read(path, limit=MAX_RECORD, *, private=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise ProtocolError('Peer metadata is not a private owned regular file')
        if private and info.st_mode & 0o077:
            raise ProtocolError('Peer key must be private to its owner')
        if info.st_size > limit:
            raise ProtocolError('Peer metadata exceeds size limit')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            data = stream.read(limit + 1)
        if len(data) > limit:
            raise ProtocolError('Peer metadata exceeds size limit')
        value = json.loads(data)
        if not isinstance(value, dict):
            raise ProtocolError('Expected a JSON object')
        return value
    finally:
        os.close(fd)


def _normalize_record(path, raw, verify_live=True):
    pid_text = path.stem
    if not re.fullmatch(r'[1-9][0-9]*', pid_text):
        raise ProtocolError('Noncanonical process record')
    pid = int(pid_text)
    sock = canonical_socket(raw.get('messagingSocketPath', ''))
    session_id = raw.get('sessionId')
    start = raw.get('procStart')
    if not isinstance(session_id, str) or not session_id or not isinstance(start, str) or not start:
        raise ProtocolError('Missing exact session/process identity')
    if verify_live and process_start(pid) != start:
        raise ProtocolError('Peer process exited or changed identity')
    info = os.lstat(sock)
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ProtocolError('Peer socket is not a private socket owned by this user')
    return {'pid': pid, 'session_id': session_id, 'name': raw.get('name') or session_id,
            'socket_path': sock, 'socket': sock, 'proc_start': start,
            'cwd': raw.get('cwd'), 'kind': raw.get('kind'),
            'peer_protocol': raw.get('peerProtocol'), 'peer_features': raw.get('peerFeatures', [])}


def discover_sessions(config_dir=None):
    """Read exact live local endpoints without probing or sending to their sockets."""
    directory = config_path(config_dir) / 'sessions'
    try:
        _check_directory(directory)
        paths = sorted(directory.iterdir())
    except (OSError, ValueError):
        return []
    records = []
    for path in paths:
        if not re.fullmatch(r'[1-9][0-9]*\.json', path.name):
            continue
        try:
            records.append(_normalize_record(path, _json_read(path)))
        except (OSError, ValueError, TypeError):
            continue
    return records


def _check_directory(path):
    """Existing parents may be sticky /tmp; leaves must be owned and not writable by peers."""
    path = Path(path)
    for component in [*reversed(path.parents), path]:
        info = component.lstat()
        if not stat.S_ISDIR(info.st_mode):
            raise ProtocolError('Metadata/socket directory contains a symlink or non-directory')
        if info.st_uid not in (0, os.getuid()):
            raise ProtocolError('Metadata/socket directory has a foreign owner')
        if info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX:
            raise ProtocolError('Metadata/socket directory is writable by other users')
    if path.lstat().st_uid != os.getuid() or path.lstat().st_mode & 0o022:
        raise ProtocolError('Endpoint directory is not owned and private to this user')


def _ensure_directory(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    _check_directory(path)


def _address(path):
    return 'uds:' + quote(canonical_socket(path), safe=':_/.\\-')


def _path_from_address(value):
    if not isinstance(value, str) or not value.startswith('uds:'):
        raise ProtocolError('A verified native reverse address is required')
    return canonical_socket(unquote(value[4:], errors='strict'))



def _escape_body(text):
    # The native wrapper is text, not XML: preserve literal ampersands and tags.
    # Escape ASCII closing wrapper delimiters with the native backslash marker;
    # the receiver treats every supplied character as peer content/authority.
    return re.sub(r'<(?=[^A-Za-z0-9_<>-]*/[^A-Za-z0-9_<>-]*cross[-_]session[-_]message(?:[^A-Za-z0-9_-]|$))',
                  lambda _: '<' + chr(92), text, flags=re.IGNORECASE)


def parse_frame(value):
    if not isinstance(value, dict):
        raise ProtocolError('Expected a JSON frame object')
    if value.get('type') == 'user':
        message = value.get('message')
        if not isinstance(message, dict) or not isinstance(message.get('content'), str) or not message['content']:
            raise ProtocolError('User frame requires a nonempty string content')
    elif value.get('type') == 'control':
        if value.get('action') not in _CONTROLS:
            raise ProtocolError('Unsupported native control frame')
        if value['action'] == 'peer_message_status':
            if value.get('status') not in _STATUSES or not isinstance(value.get('orig_msg_id'), str):
                raise ProtocolError('Invalid peer status receipt')
    else:
        raise ProtocolError('Unsupported native frame type')
    if not isinstance(value.get('msg_id'), str) or not value['msg_id']:
        raise ProtocolError('Native message identity is required')
    return value


class ClaudeEndpoint:
    def __init__(self, name, session_id, callback, *, config_dir=None, socket_dir=None):
        if not isinstance(name, str) or not name.startswith('cctrl-') or any(ord(c) < 32 for c in name):
            raise ValueError('Bridge name must honestly identify cctrl')
        if not isinstance(session_id, str) or not session_id.startswith('cctrl-bridge-'):
            raise ValueError('Use a bridge-specific cctrl-bridge- session identity')
        self.name, self.session_id, self.callback = name, session_id, callback
        self.config_dir = config_path(config_dir).absolute()
        location = Path(socket_dir or f'/tmp/cc-socks-{os.getuid()}').absolute()
        self.socket_dir = location.parent.resolve() / location.name
        self.pid = os.getpid()
        self.socket_path = canonical_socket(self.socket_dir / f'{self.pid}.sock')
        self.address = _address(self.socket_path)
        self.record = None
        self._token = secrets.token_hex(16)
        self._owned = {}
        self._stop = threading.Event()
        self._server = self._thread = self._connection = None
        self.errors = []

    @property
    def owned_resources(self):
        """Snapshot exact acquired identities, including resources whose cleanup failed."""
        return [{'path': str(path), 'device': identity[0], 'inode': identity[1]}
                for path, identity in self._owned.items()]

    def _error(self, error):
        self.errors.append(type(error).__name__)
        self.errors[:] = self.errors[-16:]

    def _remember(self, path):
        info = Path(path).lstat()
        self._owned[Path(path)] = (info.st_dev, info.st_ino)

    def _publish(self, path, value):
        data = json.dumps(value, ensure_ascii=True, separators=(',', ':')).encode() + b'\n'
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        info = os.fstat(fd)
        self._owned[Path(path)] = (info.st_dev, info.st_ino)
        try:
            with os.fdopen(fd, 'wb', closefd=False) as stream:
                stream.write(data)
                stream.flush()
                os.fsync(fd)
        finally:
            os.close(fd)

    def open(self):
        if self._server is not None or self._owned:
            raise RuntimeError('Endpoint already open or cleanup remains unresolved')
        if os.getpid() != self.pid:
            raise RuntimeError('Endpoint cannot be inherited across fork')
        self._stop.clear()
        try:
            _ensure_directory(self.config_dir / 'sessions')
            _ensure_directory(self.socket_dir)
            if len(os.fsencode(self.socket_path)) > 103:
                raise ProtocolError('Unix socket path exceeds supported portable length')
            start = process_start(self.pid)
            if start is None:
                raise ProtocolError('Own process identity is unavailable')
            self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self._server.bind(self.socket_path)  # Never unlink or replace a preexisting socket.
            self._remember(self.socket_path)
            os.chmod(self.socket_path, 0o600)
            self._server.listen(16)
            self._server.settimeout(0.2)
            directory = self.config_dir / 'sessions'
            self._publish(directory / key_filename(self.pid, self.socket_path),
                          {'peerToken': self._token, 'procStart': start})
            self.record = {'pid': self.pid, 'name': self.name, 'kind': 'daemon',
                           'sessionId': self.session_id, 'cwd': os.getcwd(),
                           'startedAt': int(time.time() * 1000), 'procStart': start,
                           'messagingSocketPath': self.socket_path, 'status': 'idle',
                           'peerProtocol': 1, 'peerFeatures': []}
            self._publish(directory / f'{self.pid}.json', self.record)
            self._thread = threading.Thread(target=self._serve, name='cctrl-claude-inbox', daemon=True)
            self._thread.start()
            return self
        except BaseException:
            self.close()
            raise

    def close(self):
        self._stop.set()
        for connection in (self._connection, self._server):
            if connection is not None:
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                connection.close()
        if self._thread is not None and self._thread is not threading.current_thread():
            self._thread.join(timeout=4)
            if self._thread.is_alive():
                raise CleanupError('Inbox callback remains active; endpoint ownership retained')
        self._server = self._thread = self._connection = None
        errors = []
        for path, identity in list(self._owned.items())[::-1]:
            try:
                info = path.lstat()
                if (info.st_dev, info.st_ino) != identity:
                    errors.append(f'Resource identity changed: {path}')
                    continue
                path.unlink()
                del self._owned[path]
            except FileNotFoundError:
                del self._owned[path]
            except OSError as exc:
                errors.append(f'{path}: {exc.__class__.__name__}')
        if errors:
            raise CleanupError('; '.join(errors))
        self.record = None

    def _target(self, target):
        if not isinstance(target, dict) or not isinstance(target.get('pid'), int):
            raise ProtocolError('Select an exact discovered peer record')
        path = self.config_dir / 'sessions' / f'{target["pid"]}.json'
        _check_directory(path.parent)
        live = _normalize_record(path, _json_read(path))
        expected = (target.get('session_id'), target.get('socket_path', target.get('socket')), target.get('proc_start'))
        if (live['session_id'], live['socket_path'], live['proc_start']) != expected:
            raise ProtocolError('Selected peer identity changed; discover it again')
        return live

    def _sender(self, frame, pid, uid):
        if uid != os.getuid() or pid <= 1:
            raise ProtocolError('Native peer is not a process owned by this user')
        path = self.config_dir / 'sessions' / f'{pid}.json'
        live = _normalize_record(path, _json_read(path))
        if live['socket_path'] != _path_from_address(frame.get('from')):
            raise ProtocolError('Claimed reply address does not belong to the connecting process')
        return {**live, 'uid': uid, 'verified': True, 'address': _address(live['socket_path'])}

    def _serve(self):
        while not self._stop.is_set():
            try:
                connection, _ = self._server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self._connection = connection
            try:
                with connection:
                    connection.settimeout(3)
                    pid, uid = peer_credentials(connection)
                    if uid != os.getuid():
                        raise ProtocolError('Foreign peer UID')
                    self._receive(connection, pid, uid)
            except (OSError, ValueError, TypeError) as exc:
                self._error(exc)
            except Exception as exc:
                self._error(exc)  # A failed consumer must not silently kill the listener.
            finally:
                self._connection = None

    def _receive(self, connection, pid, uid):
        buffer, authenticated, count, total = bytearray(), False, 0, 0
        deadline = time.monotonic() + 3
        def consume(line):
            nonlocal authenticated, count
            count += 1
            if count > 32:
                raise ProtocolError('Too many frames on one connection')
            value = json.loads(line.decode('utf-8'))
            if not authenticated:
                token = value.get('token') if isinstance(value, dict) else None
                if not isinstance(token, str) or value.get('type') != 'auth' or not hmac.compare_digest(token, self._token):
                    raise ProtocolError('First frame must authenticate this endpoint')
                authenticated = True
                return
            frame = parse_frame(value)
            if 'session_id' in frame and frame['session_id'] != self.session_id:
                raise ProtocolError('Recipient session identity mismatch')
            sender = self._sender(frame, pid, uid)
            self.callback(frame, sender)
        while not self._stop.is_set():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('Native connection deadline exceeded')
            connection.settimeout(remaining)
            data = connection.recv(65536)
            if not data:
                if buffer:
                    consume(bytes(buffer))
                return
            total += len(data)
            if total > MAX_FRAME:
                raise ProtocolError('Native connection exceeds 1 MiB limit')
            buffer.extend(data)
            while b'\n' in buffer:
                line, _, rest = buffer.partition(b'\n')
                buffer = bytearray(rest)
                consume(bytes(line))

    def send(self, target, text, *, msg_id=None):
        if not isinstance(text, str) or not text.strip():
            raise ValueError('Native text must be nonempty')
        identifier = msg_id or str(uuid.uuid4())
        if len(text) > MAX_FRAME:
            return {'msg_id': identifier, 'status': 'failed', 'reason': 'Native text exceeds input limit'}
        body = (f'<cross-session-message from="{html.escape(self.address, quote=True)}" '
                f'from-name="{html.escape(self.name, quote=True)}" from-mode="prompting">\n'
                f'{_escape_body(text)}\n</cross-session-message>')
        frame = {'msgV': 1, 'msg_id': identifier, 'type': 'user',
                 'message': {'role': 'user', 'content': body}, 'priority': 'next', 'from': self.address}
        return self._send(target, frame)

    def send_control(self, target, action, **fields):
        if action not in _CONTROLS or any(k in fields for k in ('type', 'from', 'msgV')):
            raise ValueError('Invalid native control')
        frame = {'msgV': 1, 'msg_id': str(uuid.uuid4()), 'type': 'control',
                 'action': action, 'from': self.address, **fields}
        parse_frame(frame)
        return self._send(target, frame)

    def _send(self, target, frame):
        result = {'msg_id': frame['msg_id']}
        writing = False
        if self._server is None or self._stop.is_set() or os.getpid() != self.pid:
            return {**result, 'status': 'failed', 'reason': 'Bridge endpoint is not active in this process'}
        try:
            live = self._target(target)
            key = _json_read(self.config_dir / 'sessions' / key_filename(live['pid'], live['socket_path']), 4096, private=True)
            token = key.get('peerToken')
            if not isinstance(token, str) or not re.fullmatch('[0-9a-f]{32}', token) or key.get('procStart') != live['proc_start']:
                raise ProtocolError('Recipient peer key does not match its current process')
            packet = (json.dumps({'type': 'auth', 'token': token}, separators=(',', ':')) + '\n' +
                      json.dumps({**frame, 'session_id': live['session_id']}, ensure_ascii=True, separators=(',', ':')) + '\n').encode()
            if len(packet) > MAX_FRAME:
                raise ProtocolError('Native frame exceeds 1 MiB encoded limit')
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(5)
                connection.connect(live['socket_path'])
                pid, uid = peer_credentials(connection)
                if (pid, uid) != (live['pid'], os.getuid()) or process_start(pid) != live['proc_start']:
                    raise ProtocolError('Connected endpoint identity differs from selected peer')
                writing = True
                connection.sendall(packet)
                if sys.platform == 'darwin':
                    time.sleep(0.15)  # Match native sender's peer-credential lifetime window.
                connection.shutdown(socket.SHUT_WR)
            return {**result, 'status': 'submitted', 'reason': 'Transferred to native inbox; handling is unconfirmed'}
        except (OSError, ValueError, TypeError) as exc:
            return {**result, 'status': 'ambiguous' if writing else 'failed', 'reason': type(exc).__name__}
