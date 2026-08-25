#!/usr/bin/env python3
"""Read-only MCP runtime attestation bridge for one cctrl-managed session."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


TOOLS = [
    {
        "name": "runtime_context",
        "description": (
            "Verify this task's runtime control surface through cctrl's host-side "
            "attestation. Use this when asked whether the task is tmux-managed. "
            "Do not inspect $TMUX: command sandboxes may intentionally hide it. "
            "A result is definitive only when verified is true."
        ),
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    }
]


class McpError(Exception):
    pass


class Bridge:
    def __init__(self, cctrl: str, session: str) -> None:
        self.cctrl = cctrl
        self.session = session

    def runtime_context(self) -> dict[str, Any]:
        proc = subprocess.run(
            [self.cctrl, "session", "attest", self.session, "--json"],
            text=True,
            capture_output=True,
            check=False,
        )
        try:
            payload = json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            detail = proc.stderr.strip() or proc.stdout.strip() or str(exc)
            raise McpError(f"cctrl runtime attestation failed: {detail}") from exc
        if not isinstance(payload, dict):
            raise McpError("cctrl runtime attestation returned invalid JSON")
        return payload


def tool_result(payload: dict[str, Any], is_error: bool = False) -> dict[str, Any]:
    return {
        "content": [{"type": "text", "text": json.dumps(payload, separators=(",", ":"))}],
        "structuredContent": payload,
        "isError": is_error,
    }


def response(message_id: Any, result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": message_id, "result": result}


def error_response(message_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": message_id, "error": {"code": code, "message": message}}


def handle_rpc(bridge: Bridge, message: dict[str, Any]) -> dict[str, Any] | None:
    method = message.get("method")
    message_id = message.get("id")
    params = message.get("params") or {}
    if method == "initialize":
        return response(
            message_id,
            {
                "protocolVersion": "2024-11-05",
                "serverInfo": {"name": "cctrl-runtime", "version": "0.1.0"},
                "capabilities": {"tools": {}},
            },
        )
    if method == "notifications/initialized":
        return None
    if method == "tools/list":
        return response(message_id, {"tools": TOOLS})
    if method == "tools/call":
        if not isinstance(params, dict) or params.get("name") != "runtime_context":
            return error_response(message_id, -32602, "Unknown runtime tool")
        arguments = params.get("arguments") or {}
        if not isinstance(arguments, dict) or arguments:
            return error_response(message_id, -32602, "runtime_context takes no arguments")
        try:
            return response(message_id, tool_result({"ok": True, "data": bridge.runtime_context()}))
        except McpError as exc:
            return response(message_id, tool_result({"ok": False, "error": str(exc)}, is_error=True))
    return error_response(message_id, -32601, "Method not found")


def run(bridge: Bridge) -> int:
    for line in sys.stdin:
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            print(json.dumps(error_response(None, -32700, "Parse error")), flush=True)
            continue
        if not isinstance(message, dict):
            print(json.dumps(error_response(None, -32600, "Invalid request")), flush=True)
            continue
        result = handle_rpc(bridge, message)
        if result is not None:
            print(json.dumps(result, separators=(",", ":")), flush=True)
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="cctrl runtime MCP stdio bridge")
    parser.add_argument("--session", required=True)
    parser.add_argument("--cctrl", default=str(Path(__file__).resolve().parents[1] / "cctrl"))
    args = parser.parse_args(argv)
    return run(Bridge(args.cctrl, args.session))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
