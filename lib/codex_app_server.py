#!/usr/bin/env python3
"""Narrow client for the Codex desktop App Server protocol.

The public CLI in this module only performs read-only capability discovery.
The mutating method wrappers are an internal seam for later cctrl plans; merely
importing this module or running ``capabilities`` never calls them.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence


CAPABILITY_SCHEMA_VERSION = 1
PROTOCOL_VERSION = 2
REQUIRED_METHODS = ("thread/start", "thread/read", "thread/list", "turn/start")

EXIT_USAGE = 64
EXIT_RUNTIME = 65
EXIT_CONNECT = 66
EXIT_HANDSHAKE = 67
EXIT_REQUEST_TIMEOUT = 68
EXIT_INACTIVITY_TIMEOUT = 69
EXIT_EOF = 70
EXIT_PROTOCOL = 71
EXIT_SERVER_ERROR = 72
EXIT_SERVER_REQUEST = 73
EXIT_INTERNAL = 74

EXIT_CODES = {
    0: "capability discovery completed against the connected desktop App Server",
    EXIT_USAGE: "invalid command-line usage",
    EXIT_RUNTIME: "Codex runtime was not found or failed validation",
    EXIT_CONNECT: "desktop App Server connection failed or timed out",
    EXIT_HANDSHAKE: "initialize handshake failed or timed out",
    EXIT_REQUEST_TIMEOUT: "an App Server request exceeded its phase deadline",
    EXIT_INACTIVITY_TIMEOUT: "the App Server connection became inactive",
    EXIT_EOF: "the App Server proxy exited or closed its output",
    EXIT_PROTOCOL: "the server sent malformed or uncorrelated protocol data",
    EXIT_SERVER_ERROR: "the server returned a structured JSON-RPC error",
    EXIT_SERVER_REQUEST: "the server made a request that the caller could not handle",
    EXIT_INTERNAL: "unexpected adapter failure",
}

SUPPORTED_SERVER_REQUESTS = frozenset(
    {
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
        "item/permissions/requestApproval",
        "item/tool/call",
        "item/tool/requestUserInput",
        "mcpServer/elicitation/request",
        "applyPatchApproval",
        "execCommandApproval",
    }
)

ServerRequestCallback = Callable[[str, Mapping[str, Any]], Any]
NotificationCallback = Callable[[str, Mapping[str, Any]], None]


class AdapterError(RuntimeError):
    """Stable, JSON-serializable adapter failure."""

    def __init__(
        self,
        exit_code: int,
        phase: str,
        reason: str,
        *,
        details: Any | None = None,
    ) -> None:
        super().__init__(reason)
        self.exit_code = exit_code
        self.phase = phase
        self.reason = reason
        self.details = details

    def as_dict(self) -> dict[str, Any]:
        value: dict[str, Any] = {
            "code": self.exit_code,
            "phase": self.phase,
            "reason": self.reason,
        }
        if self.details is not None:
            value["details"] = self.details
        return value


@dataclass(frozen=True)
class Timeouts:
    connect: float = 3.0
    handshake: float = 5.0
    request: float = 15.0
    inactivity: float = 10.0
    terminate: float = 0.5

    def validate(self) -> None:
        for name, value in vars(self).items():
            if value <= 0:
                raise AdapterError(EXIT_USAGE, "usage", f"{name} timeout must be positive")


@dataclass(frozen=True)
class Runtime:
    executable: str
    discovery_source: str
    cli_version: str


def _extract_version(value: str) -> str | None:
    match = re.search(r"(?<!\d)(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)", value)
    return match.group(1) if match else None


def _validated_runtime(candidate: str, source: str, timeout: float) -> Runtime | None:
    path = os.path.realpath(os.path.expanduser(candidate))
    if not os.path.isfile(path) or not os.access(path, os.X_OK):
        return None
    try:
        proc = subprocess.run(
            [path, "--version"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    version = _extract_version(f"{proc.stdout}\n{proc.stderr}")
    if version is None:
        return None
    return Runtime(path, source, version)


def _platform_candidates(extra: Sequence[str] = ()) -> list[str]:
    candidates = list(extra)
    if sys.platform == "darwin":
        candidates.extend(
            [
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/Applications/Codex.app/Contents/Resources/codex",
                "/System/Applications/ChatGPT.app/Contents/Resources/codex",
            ]
        )
    else:
        candidates.extend(["/usr/local/bin/codex", "/opt/codex/bin/codex"])
    return candidates


def discover_runtime(
    override: str | None = None,
    *,
    validation_timeout: float = 2.0,
    platform_candidates: Sequence[str] = (),
) -> Runtime:
    """Discover Codex in override -> PATH -> platform-installation order."""

    if override:
        runtime = _validated_runtime(override, "configured-override", validation_timeout)
        if runtime is None:
            raise AdapterError(
                EXIT_RUNTIME,
                "runtime-discovery",
                f"configured Codex executable is not runnable: {override}",
            )
        return runtime

    path_candidate = shutil.which("codex")
    if path_candidate:
        runtime = _validated_runtime(path_candidate, "path", validation_timeout)
        if runtime is not None:
            return runtime

    env_candidates = [
        value
        for value in os.environ.get("CCTRL_CODEX_PLATFORM_CANDIDATES", "").split(os.pathsep)
        if value
    ]
    seen: set[str] = set()
    for candidate in _platform_candidates((*platform_candidates, *env_candidates)):
        real = os.path.realpath(os.path.expanduser(candidate))
        if real in seen:
            continue
        seen.add(real)
        runtime = _validated_runtime(candidate, "platform-installation", validation_timeout)
        if runtime is not None:
            return runtime

    raise AdapterError(
        EXIT_RUNTIME,
        "runtime-discovery",
        "Codex was not found; set CCTRL_CODEX_BIN or codex.appServerExecutable",
    )


class AppServerClient:
    """Synchronous newline-delimited JSON-RPC client for one App Server proxy."""

    def __init__(
        self,
        runtime: Runtime,
        *,
        socket_path: str | None = None,
        timeouts: Timeouts | None = None,
        server_request_callback: ServerRequestCallback | None = None,
        notification_callback: NotificationCallback | None = None,
    ) -> None:
        self.runtime = runtime
        self.socket_path = socket_path
        self.timeouts = timeouts or Timeouts()
        self.timeouts.validate()
        self.server_request_callback = server_request_callback
        self.notification_callback = notification_callback
        self.process: subprocess.Popen[str] | None = None
        self._events: queue.Queue[tuple[str, Any]] = queue.Queue()
        self._stderr: list[str] = []
        self._reader: threading.Thread | None = None
        self._stderr_reader: threading.Thread | None = None
        self._next_id = 1
        self.initialized = False
        self.runtime_facts: dict[str, Any] = {}
        self.daemon_version: dict[str, Any] | None = None
        self.notifications: list[dict[str, Any]] = []

    @property
    def transport_endpoint(self) -> str:
        return self.socket_path or "managed-control-socket"

    def __enter__(self) -> "AppServerClient":
        self.connect()
        return self

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        self.close()

    def _run_daemon_version(self) -> None:
        command = [self.runtime.executable, "app-server", "daemon", "version"]
        try:
            proc = subprocess.run(
                command,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=self.timeouts.connect,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise AdapterError(
                EXIT_CONNECT,
                "connect",
                "timed out checking the desktop App Server control socket",
            ) from exc
        except OSError as exc:
            raise AdapterError(EXIT_CONNECT, "connect", f"could not execute Codex: {exc}") from exc
        if proc.returncode != 0:
            reason = (proc.stderr or proc.stdout).strip()
            raise AdapterError(
                EXIT_CONNECT,
                "connect",
                "desktop App Server daemon is unavailable"
                + (f": {reason}" if reason else ""),
            )
        try:
            parsed = json.loads(proc.stdout)
            self.daemon_version = parsed if isinstance(parsed, dict) else None
        except json.JSONDecodeError:
            self.daemon_version = None

    def connect(self) -> None:
        if self.process is not None:
            return
        # ``daemon version`` only probes the managed default control socket and
        # has no --sock option. An explicit socket must therefore be tested by
        # the proxy itself rather than rejected by an unrelated preflight.
        if self.socket_path is None:
            self._run_daemon_version()
        command = [self.runtime.executable, "app-server", "proxy"]
        if self.socket_path:
            command.extend(["--sock", self.socket_path])
        try:
            self.process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
                start_new_session=True,
            )
        except OSError as exc:
            raise AdapterError(EXIT_CONNECT, "connect", f"failed to start App Server proxy: {exc}") from exc
        assert self.process.stdin is not None
        os.set_blocking(self.process.stdin.fileno(), False)
        self._reader = threading.Thread(target=self._read_stdout, name="codex-app-server-stdout", daemon=True)
        self._stderr_reader = threading.Thread(
            target=self._read_stderr, name="codex-app-server-stderr", daemon=True
        )
        self._reader.start()
        self._stderr_reader.start()

    def _read_stdout(self) -> None:
        assert self.process is not None and self.process.stdout is not None
        try:
            for line in self.process.stdout:
                if not line.strip():
                    continue
                try:
                    value = json.loads(line)
                except json.JSONDecodeError as exc:
                    self._events.put(("malformed", {"line": line.rstrip("\n"), "error": str(exc)}))
                    return
                if not isinstance(value, dict):
                    self._events.put(("malformed", {"line": line.rstrip("\n"), "error": "not an object"}))
                    return
                self._events.put(("message", value))
        finally:
            self._events.put(("eof", None))

    def _read_stderr(self) -> None:
        assert self.process is not None and self.process.stderr is not None
        for line in self.process.stderr:
            if sum(map(len, self._stderr)) < 16_384:
                self._stderr.append(line)

    def _stderr_text(self) -> str:
        return "".join(self._stderr).strip()

    @staticmethod
    def _id_key(value: Any) -> tuple[str, Any]:
        if isinstance(value, bool) or not isinstance(value, (int, str)):
            raise AdapterError(EXIT_PROTOCOL, "protocol", "request id must be an integer or string")
        return ("int" if isinstance(value, int) else "str", value)

    def _send(
        self,
        message: Mapping[str, Any],
        *,
        deadline: float,
        phase: str,
        timeout_exit: int,
    ) -> None:
        if self.process is None or self.process.stdin is None:
            raise AdapterError(EXIT_CONNECT, "connect", "App Server proxy is not connected")
        payload = (json.dumps(message, separators=(",", ":")) + "\n").encode("utf-8")
        fd = self.process.stdin.fileno()
        offset = 0
        while offset < len(payload):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AdapterError(timeout_exit, phase, f"{phase} timeout expired while writing")
            try:
                _, writable, _ = select.select([], [fd], [], remaining)
                if not writable:
                    raise AdapterError(timeout_exit, phase, f"{phase} timeout expired while writing")
                offset += os.write(fd, payload[offset:])
            except (BrokenPipeError, OSError) as exc:
                raise AdapterError(EXIT_EOF, "transport", "App Server proxy closed its input") from exc

    def notify(
        self,
        method: str,
        params: Mapping[str, Any] | None = None,
        *,
        timeout: float | None = None,
    ) -> None:
        duration = self.timeouts.request if timeout is None else timeout
        self._send(
            {"method": method, "params": dict(params or {})},
            deadline=time.monotonic() + duration,
            phase="request",
            timeout_exit=EXIT_REQUEST_TIMEOUT,
        )

    @staticmethod
    def _invoke_callback(
        callback: Callable[..., Any],
        args: tuple[Any, ...],
        *,
        timeout: float,
        phase: str,
        timeout_exit: int,
    ) -> Any:
        completed: queue.Queue[tuple[str, Any]] = queue.Queue(maxsize=1)

        def run() -> None:
            try:
                completed.put(("result", callback(*args)))
            except BaseException as exc:
                completed.put(("error", exc))

        threading.Thread(target=run, name="codex-app-server-callback", daemon=True).start()
        try:
            kind, value = completed.get(timeout=max(0.0, timeout))
        except queue.Empty as exc:
            raise AdapterError(timeout_exit, phase, f"{phase} timeout expired in caller callback") from exc
        if kind == "error":
            raise value
        return value

    def _reply_to_server_request(
        self,
        message: Mapping[str, Any],
        *,
        deadline: float,
        phase: str,
        timeout_exit: int,
    ) -> None:
        request_id = message["id"]
        self._id_key(request_id)
        method = message.get("method")
        params = message.get("params", {})
        if not isinstance(method, str) or not isinstance(params, dict):
            raise AdapterError(EXIT_PROTOCOL, "protocol", "malformed server request")
        if method not in SUPPORTED_SERVER_REQUESTS or self.server_request_callback is None:
            self._send(
                {
                    "id": request_id,
                    "error": {
                        "code": -32601,
                        "message": f"client has no handler for server request: {method}",
                    },
                },
                deadline=deadline,
                phase=phase,
                timeout_exit=timeout_exit,
            )
            raise AdapterError(
                EXIT_SERVER_REQUEST,
                "server-request",
                f"server request requires an explicit caller callback: {method}",
            )
        try:
            result = self._invoke_callback(
                self.server_request_callback,
                (method, params),
                timeout=deadline - time.monotonic(),
                phase=phase,
                timeout_exit=timeout_exit,
            )
        except AdapterError:
            raise
        except Exception as exc:
            self._send(
                {
                    "id": request_id,
                    "error": {"code": -32603, "message": f"caller callback failed: {exc}"},
                },
                deadline=deadline,
                phase=phase,
                timeout_exit=timeout_exit,
            )
            raise AdapterError(
                EXIT_SERVER_REQUEST,
                "server-request",
                f"caller callback failed for {method}: {exc}",
            ) from exc
        self._send(
            {"id": request_id, "result": result},
            deadline=deadline,
            phase=phase,
            timeout_exit=timeout_exit,
        )

    def _wait_for_response(
        self,
        request_id: int | str,
        *,
        phase: str,
        deadline: float,
        timeout_exit: int,
    ) -> Any:
        expected = self._id_key(request_id)
        last_activity = time.monotonic()
        while True:
            now = time.monotonic()
            hard_remaining = deadline - now
            idle_remaining = self.timeouts.inactivity - (now - last_activity)
            if hard_remaining <= 0:
                raise AdapterError(timeout_exit, phase, f"{phase} timeout expired")
            if idle_remaining <= 0:
                raise AdapterError(
                    EXIT_INACTIVITY_TIMEOUT,
                    "inactivity",
                    f"no App Server activity while waiting for {phase}",
                )
            try:
                event, value = self._events.get(timeout=min(hard_remaining, idle_remaining))
            except queue.Empty:
                continue
            if event == "malformed":
                raise AdapterError(EXIT_PROTOCOL, "protocol", "malformed JSON from App Server", details=value)
            if event == "eof":
                reason = self._stderr_text()
                raise AdapterError(
                    EXIT_EOF,
                    "transport",
                    "App Server proxy exited before replying" + (f": {reason}" if reason else ""),
                )
            last_activity = time.monotonic()
            message = value
            if "method" in message:
                if "id" in message:
                    callback_deadline = min(deadline, last_activity + self.timeouts.inactivity)
                    callback_exit = (
                        timeout_exit
                        if deadline <= last_activity + self.timeouts.inactivity
                        else EXIT_INACTIVITY_TIMEOUT
                    )
                    self._reply_to_server_request(
                        message,
                        deadline=callback_deadline,
                        phase=phase if callback_exit == timeout_exit else "inactivity",
                        timeout_exit=callback_exit,
                    )
                else:
                    method = message.get("method")
                    params = message.get("params", {})
                    if not isinstance(method, str) or not isinstance(params, dict):
                        raise AdapterError(EXIT_PROTOCOL, "protocol", "malformed server notification")
                    self.notifications.append(dict(message))
                    if self.notification_callback is not None:
                        callback_deadline = min(deadline, last_activity + self.timeouts.inactivity)
                        callback_exit = (
                            timeout_exit
                            if deadline <= last_activity + self.timeouts.inactivity
                            else EXIT_INACTIVITY_TIMEOUT
                        )
                        try:
                            self._invoke_callback(
                                self.notification_callback,
                                (method, params),
                                timeout=callback_deadline - time.monotonic(),
                                phase=phase if callback_exit == timeout_exit else "inactivity",
                                timeout_exit=callback_exit,
                            )
                        except AdapterError:
                            raise
                        except Exception as exc:
                            raise AdapterError(
                                EXIT_SERVER_REQUEST,
                                "notification-callback",
                                f"caller notification callback failed for {method}: {exc}",
                            ) from exc
                continue
            if "id" not in message or not ({"result", "error"} & message.keys()):
                raise AdapterError(EXIT_PROTOCOL, "protocol", "unrecognized App Server message")
            actual = self._id_key(message["id"])
            if actual != expected:
                raise AdapterError(
                    EXIT_PROTOCOL,
                    "protocol",
                    f"mismatched response id: expected {request_id!r}, received {message['id']!r}",
                )
            if "error" in message:
                error = message["error"]
                raise AdapterError(
                    EXIT_SERVER_ERROR,
                    phase,
                    "App Server returned a JSON-RPC error",
                    details=error,
                )
            return message.get("result")

    def request(
        self,
        method: str,
        params: Mapping[str, Any] | None = None,
        *,
        request_id: int | str | None = None,
        timeout: float | None = None,
    ) -> Any:
        if method != "initialize" and not self.initialized:
            raise AdapterError(EXIT_HANDSHAKE, "handshake", "client is not initialized")
        if request_id is None:
            request_id = self._next_id
            self._next_id += 1
        self._id_key(request_id)
        duration = self.timeouts.request if timeout is None else timeout
        if duration <= 0:
            raise AdapterError(EXIT_USAGE, "usage", "request timeout must be positive")
        deadline = time.monotonic() + duration
        self._send(
            {"id": request_id, "method": method, "params": dict(params or {})},
            deadline=deadline,
            phase="request",
            timeout_exit=EXIT_REQUEST_TIMEOUT,
        )
        return self._wait_for_response(
            request_id,
            phase="request",
            deadline=deadline,
            timeout_exit=EXIT_REQUEST_TIMEOUT,
        )

    def initialize(self) -> dict[str, Any]:
        if self.process is None:
            self.connect()
        request_id = self._next_id
        self._next_id += 1
        deadline = time.monotonic() + self.timeouts.handshake
        self._send(
            {
                "id": request_id,
                "method": "initialize",
                "params": {
                    "clientInfo": {"name": "cctrl", "version": "1"},
                    "capabilities": {},
                },
            },
            deadline=deadline,
            phase="handshake",
            timeout_exit=EXIT_HANDSHAKE,
        )
        result = self._wait_for_response(
            request_id,
            phase="handshake",
            deadline=deadline,
            timeout_exit=EXIT_HANDSHAKE,
        )
        if not isinstance(result, dict):
            raise AdapterError(EXIT_PROTOCOL, "handshake", "initialize result must be an object")
        advertised_protocol = result.get("protocolVersion")
        if advertised_protocol is not None and advertised_protocol != PROTOCOL_VERSION:
            raise AdapterError(
                EXIT_PROTOCOL,
                "handshake",
                f"protocol version mismatch: client={PROTOCOL_VERSION}, server={advertised_protocol}",
            )
        missing = [key for key in ("userAgent", "codexHome", "platformFamily", "platformOs") if key not in result]
        if missing:
            raise AdapterError(
                EXIT_PROTOCOL,
                "handshake",
                f"initialize result is missing runtime facts: {', '.join(missing)}",
            )
        self.runtime_facts = {
            "userAgent": result["userAgent"],
            "codexHome": result["codexHome"],
            "platform": {"family": result["platformFamily"], "os": result["platformOs"]},
            "transportEndpoint": self.transport_endpoint,
        }
        self._send(
            {"method": "initialized", "params": {}},
            deadline=deadline,
            phase="handshake",
            timeout_exit=EXIT_HANDSHAKE,
        )
        self.initialized = True
        return dict(result)

    def thread_start(self, params: Mapping[str, Any] | None = None) -> Any:
        return self.request("thread/start", params)

    def thread_read(self, thread_id: str, *, include_turns: bool = False) -> Any:
        return self.request("thread/read", {"threadId": thread_id, "includeTurns": include_turns})

    def thread_list(self, params: Mapping[str, Any] | None = None) -> Any:
        return self.request("thread/list", params)

    def turn_start(self, thread_id: str, input_items: Sequence[Mapping[str, Any]], **options: Any) -> Any:
        params = {"threadId": thread_id, "input": list(input_items), **options}
        return self.request("turn/start", params)

    def close(self) -> None:
        process = self.process
        if process is None:
            return
        if process.stdin is not None:
            try:
                process.stdin.close()
            except OSError:
                pass
        try:
            process.wait(timeout=self.timeouts.terminate)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=self.timeouts.terminate)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=self.timeouts.terminate)
        finally:
            self.process = None


def _schema_evidence(runtime: Runtime, timeout: float) -> tuple[set[str] | None, str | None]:
    with tempfile.TemporaryDirectory(prefix="cctrl-codex-schema-") as temp_dir:
        try:
            proc = subprocess.run(
                [
                    runtime.executable,
                    "app-server",
                    "generate-json-schema",
                    "--experimental",
                    "--out",
                    temp_dir,
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=timeout,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return None, f"schema generation failed: {exc}"
        if proc.returncode != 0:
            reason = (proc.stderr or proc.stdout).strip()
            return None, f"schema generation failed" + (f": {reason}" if reason else "")
        schema_path = Path(temp_dir) / "ClientRequest.json"
        try:
            schema = json.loads(schema_path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None, "generated schema did not contain ClientRequest.json"
        except (OSError, json.JSONDecodeError) as exc:
            return None, f"generated schema could not be read: {exc}"
        if not isinstance(schema, dict) or schema.get("title") != "ClientRequest":
            return None, "generated ClientRequest schema has an unexpected root"
        variants = schema.get("oneOf")
        if not isinstance(variants, list):
            return None, "generated ClientRequest schema has no oneOf request variants"
        methods: set[str] = set()
        for variant in variants:
            if not isinstance(variant, dict):
                return None, "generated ClientRequest schema contains a malformed request variant"
            properties = variant.get("properties")
            method_schema = properties.get("method") if isinstance(properties, dict) else None
            enum = method_schema.get("enum") if isinstance(method_schema, dict) else None
            if not isinstance(enum, list) or not enum or not all(isinstance(item, str) for item in enum):
                return None, "generated ClientRequest schema contains a malformed method discriminator"
            methods.update(item for item in enum if item in REQUIRED_METHODS)
        return methods, None


def _empty_report(runtime: Runtime | None = None) -> dict[str, Any]:
    return {
        "schema_version": CAPABILITY_SCHEMA_VERSION,
        "cli_version": runtime.cli_version if runtime else None,
        "server_version": None,
        "transport": {
            "kind": "desktop-daemon-proxy",
            "endpoint": os.environ.get("CCTRL_CODEX_APP_SERVER_SOCKET") or "managed-control-socket",
            "executable": runtime.executable if runtime else None,
            "discovery_source": runtime.discovery_source if runtime else None,
        },
        "runtime_facts": {
            "userAgent": None,
            "codexHome": None,
            "platform": {"family": None, "os": None},
            "transportEndpoint": os.environ.get("CCTRL_CODEX_APP_SERVER_SOCKET")
            or "managed-control-socket",
        },
        "methods": {
            method: {
                "status": "unknown",
                "evidence": "connection-unavailable",
                "reason": "desktop App Server capabilities were not established",
            }
            for method in REQUIRED_METHODS
        },
        "errors": [],
    }


def capability_report(
    *,
    executable_override: str | None,
    timeouts: Timeouts,
) -> tuple[dict[str, Any], int]:
    runtime: Runtime | None = None
    try:
        runtime = discover_runtime(executable_override, validation_timeout=timeouts.connect)
        report = _empty_report(runtime)
        with AppServerClient(
            runtime,
            socket_path=os.environ.get("CCTRL_CODEX_APP_SERVER_SOCKET") or None,
            timeouts=timeouts,
        ) as client:
            initialize_result = client.initialize()
            report["runtime_facts"] = dict(client.runtime_facts)
            user_agent = str(initialize_result.get("userAgent", ""))
            server_version = _extract_version(user_agent)
            report["server_version"] = server_version
            methods, schema_error = _schema_evidence(runtime, timeouts.request)
            versions_match = server_version is not None and server_version == runtime.cli_version
            for method in REQUIRED_METHODS:
                if not versions_match:
                    report["methods"][method] = {
                        "status": "unknown",
                        "evidence": "version-mismatch",
                        "reason": (
                            f"generated schema is from CLI {runtime.cli_version}, but connected "
                            f"server userAgent reports {server_version or 'an unknown version'}"
                        ),
                    }
                elif methods is None:
                    report["methods"][method] = {
                        "status": "unknown",
                        "evidence": "schema-generation",
                        "reason": schema_error,
                    }
                elif method in methods:
                    report["methods"][method] = {
                        "status": "supported",
                        "evidence": "version-matched-generated-schema",
                        "reason": f"method is present in schema generated by CLI {runtime.cli_version}",
                    }
                else:
                    report["methods"][method] = {
                        "status": "unsupported",
                        "evidence": "version-matched-generated-schema",
                        "reason": f"method is absent from schema generated by CLI {runtime.cli_version}",
                    }
        return report, 0
    except AdapterError as exc:
        report = _empty_report(runtime)
        report["errors"].append(exc.as_dict())
        for method in REQUIRED_METHODS:
            report["methods"][method]["reason"] = exc.reason
        return report, exc.exit_code
    except Exception as exc:
        report = _empty_report(runtime)
        error = AdapterError(EXIT_INTERNAL, "internal", f"unexpected adapter failure: {exc}")
        report["errors"].append(error.as_dict())
        return report, EXIT_INTERNAL


def _human_report(report: Mapping[str, Any]) -> str:
    lines = [
        f"Codex CLI: {report.get('cli_version') or 'unknown'}",
        f"App Server: {report.get('server_version') or 'unknown'}",
        f"Transport: {report['transport']['kind']} ({report['transport']['endpoint']})",
    ]
    for method, fact in report["methods"].items():
        lines.append(f"  {method}: {fact['status']} — {fact['reason']}")
    for error in report["errors"]:
        lines.append(f"Error [{error['phase']}]: {error['reason']}")
    return "\n".join(lines)


def _positive_float(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a number") from exc
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


class StableArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise AdapterError(EXIT_USAGE, "usage", message)


def build_parser() -> argparse.ArgumentParser:
    parser = StableArgumentParser(description="cctrl Codex App Server adapter")
    subparsers = parser.add_subparsers(dest="command", required=True)
    capabilities = subparsers.add_parser(
        "capabilities",
        help="report read-only Codex App Server capabilities",
        description="Discover read-only Codex App Server capabilities without mutating tasks.",
    )
    capabilities.add_argument("--json", action="store_true", help="emit codex_capabilities_v1 JSON")
    capabilities.add_argument("--codex", help=argparse.SUPPRESS)
    capabilities.add_argument(
        "--connect-timeout",
        type=_positive_float,
        default=os.environ.get("CCTRL_CODEX_CONNECT_TIMEOUT", "3"),
    )
    capabilities.add_argument(
        "--handshake-timeout",
        type=_positive_float,
        default=os.environ.get("CCTRL_CODEX_HANDSHAKE_TIMEOUT", "5"),
    )
    capabilities.add_argument(
        "--request-timeout",
        type=_positive_float,
        default=os.environ.get("CCTRL_CODEX_REQUEST_TIMEOUT", "15"),
    )
    capabilities.add_argument(
        "--inactivity-timeout",
        type=_positive_float,
        default=os.environ.get("CCTRL_CODEX_INACTIVITY_TIMEOUT", "10"),
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    try:
        args = build_parser().parse_args(raw_argv)
    except AdapterError as exc:
        report = _empty_report()
        report["errors"].append(exc.as_dict())
        if "--json" in raw_argv:
            json.dump(report, sys.stdout, sort_keys=True, separators=(",", ":"))
            sys.stdout.write("\n")
        else:
            print(f"Error [{exc.phase}]: {exc.reason}", file=sys.stderr)
        return exc.exit_code
    if args.command == "capabilities":
        timeouts = Timeouts(
            connect=args.connect_timeout,
            handshake=args.handshake_timeout,
            request=args.request_timeout,
            inactivity=args.inactivity_timeout,
        )
        report, exit_code = capability_report(
            executable_override=args.codex or os.environ.get("CCTRL_CODEX_BIN") or None,
            timeouts=timeouts,
        )
        if args.json:
            json.dump(report, sys.stdout, sort_keys=True, separators=(",", ":"))
            sys.stdout.write("\n")
        else:
            print(_human_report(report))
        return exit_code
    return EXIT_USAGE


if __name__ == "__main__":
    raise SystemExit(main())
