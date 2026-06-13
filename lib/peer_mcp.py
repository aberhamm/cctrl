#!/usr/bin/env python3
"""Dependency-free stdio MCP bridge for cctrl peer messaging."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


TOOLS = [
    {
        "name": "whoami",
        "description": "Return the peer identity bound to this MCP server.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "list_peers",
        "description": "List registered and live cctrl peers.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "resolve_peer",
        "description": "Resolve a peer name or alias.",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"],
            "additionalProperties": False,
        },
    },
    {
        "name": "send_message",
        "description": "Queue a message from this server's identity to another peer.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "to": {"type": "string"},
                "subject": {"type": "string"},
                "body": {"type": "string"},
            },
            "required": ["to", "body"],
            "additionalProperties": False,
        },
    },
    {
        "name": "check_messages",
        "description": "Return unread mailbox counts for this peer.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "recv_message",
        "description": "Receive the next queued or delivered-unacked message for this peer.",
        "inputSchema": {
            "type": "object",
            "properties": {"status": {"type": "string"}},
            "additionalProperties": False,
        },
    },
    {
        "name": "show_message",
        "description": "Show a full mailbox message envelope.",
        "inputSchema": {
            "type": "object",
            "properties": {"id": {"type": "string"}},
            "required": ["id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "ack_message",
        "description": "Acknowledge a delivered message addressed to this peer.",
        "inputSchema": {
            "type": "object",
            "properties": {"id": {"type": "string"}},
            "required": ["id"],
            "additionalProperties": False,
        },
    },
]


class McpError(Exception):
    def __init__(self, code: str, message: str) -> None:
        self.code = code
        self.message = message
        super().__init__(message)


class Bridge:
    def __init__(self, cctrl: str, identity: str) -> None:
        self.cctrl = cctrl
        self.identity = identity

    def cli(self, args: list[str], stdin: str | None = None) -> Any:
        proc = subprocess.run(
            [self.cctrl, *args],
            input=stdin,
            text=True,
            capture_output=True,
            env=os.environ.copy(),
            check=False,
        )
        stdout = proc.stdout.strip()
        if proc.returncode != 0:
            parsed = parse_json(stdout)
            if isinstance(parsed, dict) and parsed.get("ok") is False:
                err = parsed.get("error") or {}
                raise McpError(str(err.get("code") or "cctrl-error"), str(err.get("message") or proc.stderr.strip() or "cctrl command failed"))
            raise McpError("cctrl-error", proc.stderr.strip() or stdout or f"cctrl exited {proc.returncode}")
        parsed = parse_json(stdout)
        if parsed is None:
            raise McpError("invalid-response", "cctrl returned non-JSON output")
        return parsed

    def call_tool(self, name: str, arguments: Any) -> dict[str, Any]:
        args = require_object(arguments)
        if name == "whoami":
            ensure_no_extra(args, set())
            return ok(self.cli(["peer", "whoami", "--as", self.identity, "--json"]))
        if name == "list_peers":
            ensure_no_extra(args, set())
            return ok(self.cli(["peer", "ls", "--json"]))
        if name == "resolve_peer":
            ensure_no_extra(args, {"name"})
            peer = require_string(args, "name")
            return ok(self.cli(["peer", "resolve", peer, "--json"]))
        if name == "send_message":
            ensure_no_extra(args, {"to", "subject", "body"})
            to = require_string(args, "to")
            body = require_string(args, "body")
            subject = optional_string(args, "subject", "")
            cmd = ["peer", "send", to, "--as", self.identity, "--body-file", "-", "--json"]
            if subject:
                cmd[3:3] = ["--subject", subject]
            return ok(self.cli(cmd, stdin=body))
        if name == "check_messages":
            ensure_no_extra(args, set())
            return ok(self.cli(["peer", "check", "--as", self.identity, "--json"]))
        if name == "recv_message":
            ensure_no_extra(args, {"status"})
            status = optional_string(args, "status", "")
            cmd = ["peer", "recv", "--as", self.identity, "--json"]
            if status:
                cmd.extend(["--status", status])
            return ok(self.cli(cmd))
        if name == "show_message":
            ensure_no_extra(args, {"id"})
            message_id = require_string(args, "id")
            message = self.cli(["peer", "show", message_id, "--json"])
            if not isinstance(message, dict):
                raise McpError("invalid-response", "cctrl returned an invalid message envelope")
            if message.get("to") != self.identity and message.get("from") != self.identity:
                raise McpError("forbidden", f"Message {message_id} is not visible to {self.identity}")
            return ok(message)
        if name == "ack_message":
            ensure_no_extra(args, {"id"})
            message_id = require_string(args, "id")
            return ok(self.cli(["peer", "ack", message_id, "--as", self.identity, "--json"]))
        raise McpError("unknown-tool", f"Unknown tool: {name}")


def parse_json(text: str) -> Any:
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def require_object(value: Any) -> dict[str, Any]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise McpError("validation", "Tool arguments must be an object")
    if "as" in value or "from" in value:
        raise McpError("validation", "Identity is fixed at server startup; tool arguments cannot include as/from")
    return value


def require_string(args: dict[str, Any], key: str) -> str:
    value = args.get(key)
    if not isinstance(value, str) or value == "":
        raise McpError("validation", f"{key} must be a non-empty string")
    return value


def optional_string(args: dict[str, Any], key: str, default: str) -> str:
    value = args.get(key, default)
    if not isinstance(value, str):
        raise McpError("validation", f"{key} must be a string")
    return value


def ensure_no_extra(args: dict[str, Any], allowed: set[str]) -> None:
    extra = sorted(set(args) - allowed)
    if extra:
        raise McpError("validation", f"Unexpected argument: {extra[0]}")


def ok(data: Any) -> dict[str, Any]:
    return {"ok": True, "data": data}


def err(error: McpError) -> dict[str, Any]:
    return {"ok": False, "error": {"code": error.code, "message": error.message}}


def tool_result(payload: dict[str, Any], is_error: bool = False) -> dict[str, Any]:
    return {
        "content": [{"type": "text", "text": json.dumps(payload, separators=(",", ":"))}],
        "structuredContent": payload,
        "isError": is_error,
    }


def response(message_id: Any, result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": message_id, "result": result}


def error_response(message_id: Any, code: int, message: str, data: Any | None = None) -> dict[str, Any]:
    error: dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    return {"jsonrpc": "2.0", "id": message_id, "error": error}


def handle_rpc(bridge: Bridge, msg: dict[str, Any]) -> dict[str, Any] | None:
    method = msg.get("method")
    message_id = msg.get("id")
    params = msg.get("params") or {}
    if method == "initialize":
        return response(
            message_id,
            {
                "protocolVersion": "2024-11-05",
                "serverInfo": {"name": "cctrl-peer", "version": "0.1.0"},
                "capabilities": {"tools": {}},
            },
        )
    if method == "notifications/initialized":
        return None
    if method == "tools/list":
        return response(message_id, {"tools": TOOLS})
    if method == "tools/call":
        if not isinstance(params, dict):
            return error_response(message_id, -32602, "Invalid params")
        name = params.get("name")
        if not isinstance(name, str):
            return error_response(message_id, -32602, "Tool name is required")
        try:
            payload = bridge.call_tool(name, params.get("arguments") or {})
            return response(message_id, tool_result(payload))
        except McpError as exc:
            return response(message_id, tool_result(err(exc), is_error=True))
    return error_response(message_id, -32601, f"Method not found: {method}")


def run(bridge: Bridge) -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as exc:
            print_json(error_response(None, -32700, "Parse error", str(exc)))
            continue
        if not isinstance(msg, dict):
            print_json(error_response(None, -32600, "Invalid request"))
            continue
        result = handle_rpc(bridge, msg)
        if result is not None:
            print_json(result)
    return 0


def print_json(value: Any) -> None:
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="cctrl peer MCP stdio bridge")
    parser.add_argument("--as", dest="identity", default=os.environ.get("CCTRL_PEER", ""))
    parser.add_argument("--cctrl", default=str(Path(__file__).resolve().parents[1] / "cctrl"))
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if not args.identity:
        print("cctrl peer mcp needs --as <peer> or CCTRL_PEER", file=sys.stderr)
        return 66
    try:
        peer = Bridge(args.cctrl, args.identity).cli(["peer", "whoami", "--as", args.identity, "--json"])
    except McpError as exc:
        print(f"cctrl peer mcp identity failed: {exc.message}", file=sys.stderr)
        return 66
    identity = peer.get("name") if isinstance(peer, dict) else ""
    if not isinstance(identity, str) or not identity:
        print("cctrl peer mcp identity failed: cctrl returned an invalid peer identity", file=sys.stderr)
        return 66
    bridge = Bridge(args.cctrl, identity)
    return run(bridge)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
