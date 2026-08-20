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
        "name": "peer_overview",
        "description": (
            "START HERE if you have not used peer messaging before. One call answers "
            "who am I, which peers can I reach, and do I have unread mail. Returns "
            "`identity` (this server's own peer), `peers` (every reachable peer — "
            "address these by their `name` in `send_message`), and `mailbox` (unread "
            "`queued` and `delivered_unacked` counts). From here: call `send_message` "
            "to start a conversation, or `recv_message` then `ack_message` to handle "
            "incoming mail. When `mailbox.queued` or `delivered_unacked` is non-zero, "
            "read the next message with `recv_message`. Takes no arguments; the "
            "identity is fixed at server startup. If tmux peer discovery is skipped, "
            "`peers` may be empty and `derived_skipped` is true, but `identity` and "
            "`mailbox` are still returned."
        ),
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "whoami",
        "description": (
            "Return this server's own peer identity (name, agent, capabilities) — the "
            "identity every message is sent as. You rarely need this alone: "
            "`peer_overview` already includes it alongside the peer list and your "
            "mailbox counts. Reach for it only to re-confirm who you are."
        ),
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "list_peers",
        "description": (
            "List every peer you can address, registered or live. Each entry's `name` "
            "is exactly what you pass as `to` in `send_message`. For a first look "
            "prefer `peer_overview`, which returns this list plus your identity and "
            "mailbox in a single call; use `resolve_peer` to check one specific "
            "name or alias."
        ),
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "resolve_peer",
        "description": (
            "Resolve a single peer name or alias to its canonical identity before you "
            "address it — use when you are unsure a name is valid or which peer an "
            "alias points to. To browse all peers at once use `list_peers` (or "
            "`peer_overview`). The resolved `name` is what `send_message` expects "
            "as `to`."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"],
            "additionalProperties": False,
        },
    },
    {
        "name": "say_peer",
        "description": (
            "Send a DIRECT live-tmux chat message to a peer running RIGHT NOW — the "
            "tool-call form of `cctrl peer say`. DEFAULT RULE: use `say_peer` for a "
            "live tmux agent you want to act immediately; use `send_message` for "
            "durable async work that must survive the recipient being away/offline. "
            "Unlike `send_message`, this creates NO mailbox message: it types the "
            "body straight into the peer's tmux session. Address `to` with a peer "
            "`name` from `peer_overview` or `list_peers` (aliases are accepted and "
            "canonicalized). `submit` defaults to true (the message is submitted for "
            "the peer); pass submit:false to type a draft without pressing Enter. "
            "`force_busy:true` overrides the readiness guard when the peer looks busy "
            "(never a known modal). Fails (nothing typed) if the peer has no live "
            "local tmux session — fall back to `send_message` in that case."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "to": {"type": "string"},
                "body": {"type": "string"},
                "submit": {"type": "boolean"},
                "force_busy": {"type": "boolean"},
            },
            "required": ["to", "body"],
            "additionalProperties": False,
        },
    },
    {
        "name": "send_message",
        "description": (
            "Send a durable mailbox message from this server's identity to another "
            "peer and attempt delivery. Use this for async work that must survive the "
            "recipient being away/offline; for a live tmux agent you want to act now, "
            "prefer `say_peer` (direct chat, no mailbox). Address `to` with a peer "
            "`name` from `peer_overview` or "
            "`list_peers` (aliases are accepted and canonicalized). To REPLY to a "
            "message you received via `recv_message`, set `to` to that message's "
            "`sender.name`. Returns ok:true with an `outcome` field naming one of "
            "five states (sent-and-nudged, sent-and-queued, sent-but-deferred, "
            "sent-but-undelivered) whenever the message was durably queued; only "
            "send-failed (nothing queued) is ok:false. On sent-but-* the message id "
            "is returned so delivery can be retried alone — never resend, or the "
            "message duplicates. Routes transparently across machines — local "
            "and remote peers are handled identically, no special flags needed. "
            "Do NOT use Claude Code's built-in SendMessage/ListAgents for peer "
            "messaging; those are local-only and cannot reach peers on other "
            "machines."
        ),
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
        "description": (
            "Return unread mailbox counts (`queued` and `delivered_unacked`) for this "
            "peer. `peer_overview` returns the same counts alongside your identity "
            "and peer list, so prefer it for a first orientation. When either count "
            "is non-zero, call `recv_message` to read the next message."
        ),
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "recv_message",
        "description": (
            "Receive the next queued or delivered-unacked message addressed to this "
            "peer (a queued message is marked delivered). The returned message "
            "carries a `sender` object identifying who sent it: reply by calling "
            "`send_message` with `to` set to `sender.name`. After you have handled "
            "the message, call `ack_message` with its `id` — unacked messages keep "
            "reappearing here and in `check_messages`. Use `peer_overview` or "
            "`check_messages` first to see whether anything is waiting."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"status": {"type": "string"}},
            "additionalProperties": False,
        },
    },
    {
        "name": "show_message",
        "description": (
            "Show the full envelope of one message by `id` — including its `sender` "
            "object and body — without changing its state. Use it to re-read a "
            "message surfaced by `recv_message`. Only messages sent to or from this "
            "peer are visible. This does not acknowledge; call `ack_message` when "
            "you are done handling it."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"id": {"type": "string"}},
            "required": ["id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "ack_message",
        "description": (
            "Acknowledge a message (by `id`) that was delivered to this peer, marking "
            "it handled so it stops appearing in `recv_message` and "
            "`check_messages`. Acknowledge only after you have acted on the message "
            "and sent any reply via `send_message`. A message must first be received "
            "(`recv_message`) before it can be acked."
        ),
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

    def cli_send_and_deliver(self, args: list[str], stdin: str | None = None) -> Any:
        # Delivery-aware variant of cli(). `peer send --deliver` exits non-zero on
        # sent-but-undelivered / sent-but-deferred, but those states DID durably
        # queue the message — turning them into an MCP error would report a
        # perfectly good queued message as a send failure. Only send-failed
        # (nothing queued) becomes ok:false; every other outcome is ok:true with
        # the message id so the caller can retry delivery alone.
        proc = subprocess.run(
            [self.cctrl, *args],
            input=stdin,
            text=True,
            capture_output=True,
            env=os.environ.copy(),
            check=False,
        )
        stdout = proc.stdout.strip()
        parsed = parse_json(stdout)
        if isinstance(parsed, dict) and parsed.get("outcome"):
            if parsed.get("outcome") != "send-failed":
                return parsed
            err = parsed.get("error") or {}
            raise McpError(
                str(err.get("code") or "send-failed"),
                str(err.get("message") or proc.stderr.strip() or "peer send failed"),
            )
        if proc.returncode != 0:
            if isinstance(parsed, dict) and parsed.get("ok") is False:
                err = parsed.get("error") or {}
                raise McpError(str(err.get("code") or "cctrl-error"), str(err.get("message") or proc.stderr.strip() or "cctrl command failed"))
            raise McpError("cctrl-error", proc.stderr.strip() or stdout or f"cctrl exited {proc.returncode}")
        if parsed is None:
            raise McpError("invalid-response", "cctrl returned non-JSON output")
        return parsed

    def call_tool(self, name: str, arguments: Any) -> dict[str, Any]:
        args = require_object(arguments)
        if name == "peer_overview":
            # Thin passthrough to `cctrl peer overview --json`, which resolves the
            # peer+session document ONCE and derives identity + peers + mailbox from
            # that single enumeration (plan 025). Graceful degradation lives CLI-side:
            # when tmux peer discovery is skipped, `peer overview` still exits 0 with
            # identity + mailbox counts and `derived_skipped: true`, which we surface
            # unchanged. A hard document-build failure that would prevent identity
            # resolution is unreachable by construction — main() resolves whoami
            # before this bridge ever reads stdin — so there is nothing to fall back
            # to and no separate re-enumeration is attempted.
            ensure_no_extra(args, set())
            return ok(self.cli(["peer", "overview", "--as", self.identity, "--json"]))
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
        if name == "say_peer":
            # Direct live-tmux chat — the tool-call form of `cctrl peer say`. The
            # body is piped through stdin to `cctrl peer say <to> --json
            # --body-file -` so multi-line and trailing-newline bodies survive
            # byte-for-byte. This path NEVER writes data/messages.jsonl (peer say
            # owns that guarantee); a failure to reach a live session surfaces as a
            # cctrl error, not a queued message.
            ensure_no_extra(args, {"to", "body", "submit", "force_busy"})
            to = require_string(args, "to")
            body = require_string(args, "body")
            submit = require_bool(args, "submit", True)
            force_busy = require_bool(args, "force_busy", False)
            cmd = ["peer", "say", to, "--json", "--body-file", "-"]
            if not submit:
                cmd.append("--no-submit")
            if force_busy:
                cmd.append("--force-busy")
            return ok(self.cli(cmd, stdin=body))
        if name == "send_message":
            ensure_no_extra(args, {"to", "subject", "body"})
            to = require_string(args, "to")
            body = require_string(args, "body")
            subject = optional_string(args, "subject", "")
            cmd = ["peer", "send", to, "--as", self.identity, "--deliver", "--body-file", "-", "--json"]
            if subject:
                cmd[3:3] = ["--subject", subject]
            return ok(self.cli_send_and_deliver(cmd, stdin=body))
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


def require_bool(args: dict[str, Any], key: str, default: bool) -> bool:
    if key not in args:
        return default
    value = args[key]
    # isinstance(True, int) is True but bools are the only accepted type here;
    # ints/strings ("yes", 1) are rejected the same way the other tools reject
    # malformed arguments.
    if not isinstance(value, bool):
        raise McpError("validation", f"{key} must be a boolean")
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
