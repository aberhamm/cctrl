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


NATIVE_TOOLS = [
    {"name": "native_" + name, "description": description,
     "inputSchema": {"type": "object", "properties": properties,
                     "required": required, "additionalProperties": False}}
    for name, description, properties, required in [
        ("enable", "Enable this actual Claude/Codex session's persistent native bridge endpoint. Never borrow another session ID.", {}, []),
        ("list", "Discover local native Claude sessions and cctrl bridge endpoints. Address targets as claude:SESSION_ID or codex:THREAD_ID.", {}, []),
        ("send", "Send through the native cross-provider bridge, recording correlation before submission. Never replay accepted, held, queued or ambiguous sends through mailbox fallback. Use id for idempotent client retry.", {"to": {"type": "string"}, "body": {"type": "string"}, "id": {"type": "string"}}, ["to", "body"]),
        ("reply", "Send a correlated native reply to an incoming bridge message. Only the actual recipient session may reply; successful submission also acknowledges handling.", {"id": {"type": "string"}, "body": {"type": "string"}, "reply_id": {"type": "string"}}, ["id", "body"]),
        ("ack", "Explicitly acknowledge handling a native bridge message and submit a receipt to its sender. Transport submission alone is not handling.", {"id": {"type": "string"}}, ["id"]),
        ("status", "Inspect a bridge message's durable transport, policy, handling and reply receipts. reconcile performs a read-only Codex queue lookup; absence never authorizes resend.", {"id": {"type": "string"}, "reconcile": {"type": "boolean"}}, ["id"]),
        ("inbox", "Read this actual session's unacknowledged native bridge messages with cursor paging. Mailbox messages have a separate receive/ACK lifecycle.", {"after": {"type": "integer", "minimum": 0}, "limit": {"type": "integer", "minimum": 1, "maximum": 100}}, []),
    ]
]

TOOLS = NATIVE_TOOLS + [
    {
        "name": "route_message",
        "description": (
            "Choose messaging before sending to a cctrl peer. For local cross-provider traffic use native_list/native_send. Prefer native Claude-to-Claude "
            "or Codex-to-Codex tools when your runtime exposes them and the exact recipient "
            "is discovered/addressable there. Returns canonical identities, native discovery "
            "guidance and a cctrl fallback command; DOES NOT SEND or verify native capability. "
            "Use native_send for local Claude/Codex traffic; send_message is mailbox fallback when native is unavailable/definitively "
            "not sent. Never duplicate an accepted, held or ambiguous native send. Independent "
            "Codex CLI sessions do not share a collaboration tree. Sessions launched outside "
            "cctrl acquire their own session-derived mailbox identity lazily."
        ),
        "inputSchema": {"type": "object", "properties": {"to": {"type": "string"}},
                        "required": ["to"], "additionalProperties": False},
    },
    {
        "name": "peer_overview",
        "description": (
            "START HERE if you have not used peer messaging before. One call answers "
            "who am I, which peers can I reach, and do I have unread mail. Returns "
            "`identity` (this server's own peer), `peers` (every reachable peer — "
            "address these by their `name` in `send_message`), and `mailbox` (unread "
            "`queued` and `delivered_unacked` counts). Prefer native tools for exact "
            "addressable same-provider targets; use `route_message` for guidance or "
            "`send_message` as fallback. Use `recv_message` then `ack_message` to handle "
            "incoming mail. When `mailbox.queued` is non-zero, read every queued "
            "message at once with `recv_message` `{\"all\": true}`. Takes no arguments; the "
            "identity is explicitly bound at startup or resolved lazily from the caller session. If tmux peer discovery is skipped, "
            "`peers` may be empty and `derived_skipped` is true, but `identity` and "
            "`mailbox` are still returned."
        ),
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "whoami",
        "description": (
            "Return this server's own peer identity (name, agent, capabilities) — the "
            "identity every fallback mailbox message is sent as. External sessions "
            "auto-register from their provider session on first use. You rarely need this alone: "
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
            "tool-call form of `cctrl peer say`. Only for a recipient that has the "
            "doorbell enabled: any other tmux peer returns error code "
            "recipient-not-doorbell-enabled (use send_message). Prefer "
            "native same-provider tools when addressable, with `send_message` as fallback. "
            "For tmux peers this creates NO mailbox message: it types the "
            "body straight into the peer's tmux session. For a verified app-owned "
            "Codex peer, it queues durable mailbox mail and attempts app delivery; "
            "submit:false queues without waking the app task. Address `to` with a peer "
            "`name` from `peer_overview` or `list_peers` (aliases are accepted and "
            "canonicalized). `submit` defaults to true (the message is submitted for "
            "the peer); pass submit:false to type a draft without pressing Enter. "
            "`force_busy:true` overrides the readiness guard when the peer looks busy "
            "(never a known modal; app tasks still defer while busy). Fails if a "
            "terminal peer has no live local tmux session — fall back to "
            "`send_message` in that case."
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
            "peer. Queues a durable message; cctrl delivers it into the recipient's "
            "pane only if the recipient has the doorbell enabled and is idle, "
            "otherwise it stays queued (outcome sent-and-queued, delivery_reason "
            "recipient-not-doorbell-enabled) and the recipient picks it up. Never "
            "retry or resend. This is the fallback after native same-provider routing "
            "is unavailable or definitively not sent; use route_message for guidance. "
            "Address `to` with a peer "
            "`name` from `peer_overview` or "
            "`list_peers` (aliases are accepted and canonicalized). To REPLY to a "
            "message you received via `recv_message`, set `to` to that message's "
            "`sender.name`. Returns ok:true with an `outcome` field naming one of "
            "five states (sent-and-nudged, sent-and-queued, sent-but-deferred, "
            "sent-but-undelivered) whenever the message was durably queued; only "
            "send-failed (nothing queued) is ok:false. On every other outcome the "
            "message is queued: never resend, or the message duplicates. Routes transparently across machines — local "
            "and remote peers are handled identically, no special flags needed. "
            "Prefer exposed native tools for exact addressable Claude-to-Claude or "
            "Codex-to-Codex targets. cctrl does not invoke model-owned native tools on your behalf."
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
            "is non-zero, call `recv_message` with `all: true` to read them all."
        ),
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "recv_message",
        "description": (
            "Receive queued messages addressed to this peer; each one returned is "
            "marked delivered. `all: true` returns EVERY queued message in one call "
            "(`{messages, count, empty}`, oldest first); `limit: N` returns at most N. "
            "With neither, it returns the next one (`{message, empty}`). Once the "
            "queue is empty it returns empty: it never re-returns delivered mail "
            "unless you pass `status: \"delivered\"`, so do not loop on it. Each "
            "message carries a `sender` object: reply with `send_message` `to` = "
            "`sender.name`. When handled, ack them all at once with `ack_message` "
            "`{\"all\": true}` or `{\"ids\": [...]}`."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "status": {"type": "string"},
                "all": {"type": "boolean"},
                "limit": {"type": "integer", "minimum": 1},
            },
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
            "Acknowledge delivered messages, marking them handled so they leave "
            "`check_messages`. Pass one `id`, several `ids`, or `all: true` (every "
            "delivered message for this peer). A batch (2+ ids or all) returns `{acked, noop, errors}` "
            "per id and still acks the valid ones. Acknowledge only after you have "
            "acted on the mail and sent any reply. A message must be received "
            "(`recv_message`) before it can be acked."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "ids": {"type": "array", "items": {"type": "string"}},
                "all": {"type": "boolean"},
            },
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
        self._canonical = ""

    def canonical_identity(self) -> str:
        # Resolved lazily (plan 106 P3b): startup no longer waits on discovery,
        # so tools that compare names themselves (show_message) resolve the
        # identity on first use. An unknown identity raises the cctrl error.
        if not self._canonical:
            peer = self.cli(["peer", "whoami", *(["--as", self.identity] if self.identity else []), "--json"])
            name = peer.get("name") if isinstance(peer, dict) else ""
            if not isinstance(name, str) or not name:
                raise McpError("unknown-peer", f"Cannot resolve peer identity: {self.identity}")
            self._canonical = name
        return self._canonical

    def cli(self, args: list[str], stdin: str | None = None, batch_report: bool = False,
            extra_env: dict[str, str] | None = None) -> Any:
        proc = subprocess.run(
            [self.cctrl, *args],
            input=stdin,
            text=True,
            capture_output=True,
            env={**os.environ, **(extra_env or {})},
            check=False,
        )
        stdout = proc.stdout.strip()
        if proc.returncode != 0:
            parsed = parse_json(stdout)
            # A batch ack exits 64 on a partial failure but still acked the
            # valid ids; its per-id report is the result, not an error.
            if batch_report and isinstance(parsed, dict) and "acked" in parsed and "errors" in parsed:
                return parsed
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
        # sent-but-undelivered (sent-but-deferred and sent-and-queued exit 0 since
        # plan 110), but every one of those states DID durably queue the message;
        # turning a non-zero exit into an MCP error would report a perfectly good
        # queued message as a send failure. This keys off `outcome`, not the exit
        # code: only send-failed (nothing queued) becomes ok:false; every other
        # outcome is ok:true with the message id. The message stays queued for
        # the recipient to collect; do not re-send it.
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
        if name not in {tool["name"] for tool in TOOLS}:
            raise McpError("unknown-tool", f"Unknown tool: {name}")
        if name.startswith("native_"):
            contract = next(tool for tool in NATIVE_TOOLS if tool["name"] == name)
            ensure_no_extra(args, set(contract["inputSchema"]["properties"]))
            for key in contract["inputSchema"]["required"]:
                require_string(args, key)
            action = name.removeprefix("native_")
            command = ["bridge", action]
            if action in {"send", "reply", "ack", "status"}:
                command.append(require_string(args, "to" if action == "send" else "id"))
            command.append("--json")
            if action == "status" and require_bool(args, "reconcile", False):
                command.append("--reconcile")
            if action == "inbox":
                for key, minimum, maximum in (("after", 0, None), ("limit", 1, 100)):
                    if key in args:
                        value = args[key]
                        if type(value) is not int or value < minimum or (maximum is not None and value > maximum):
                            raise McpError("validation", f"invalid {key}")
                        command.extend(["--" + key, str(value)])
            retry_id = args.get("id") if action == "send" else args.get("reply_id")
            if action in {"send", "reply"}:
                if retry_id is not None:
                    command.extend(["--id", require_string(args, "id" if action == "send" else "reply_id")])
                command.extend(["--", require_string(args, "body")])
            return ok(self.cli(command))
        if not self.identity and name not in {"list_peers", "resolve_peer"}:
            self.identity = self.canonical_identity()
        if name == "route_message":
            ensure_no_extra(args, {"to"})
            return ok(self.cli(["peer", "route", require_string(args, "to"), "--as", self.identity, "--json"]))
        if name == "peer_overview":
            # Thin passthrough to `cctrl peer overview --json`, which resolves the
            # peer+session document ONCE and derives identity + peers + mailbox from
            # that single enumeration (plan 025). Graceful degradation lives CLI-side:
            # when tmux peer discovery is skipped, `peer overview` still exits 0 with
            # identity + mailbox counts and `derived_skipped: true`, which we surface
            # unchanged. A hard document-build failure that would prevent identity
            # resolution surfaces here as a tool error (main() no longer resolves
            # whoami before reading stdin), and no re-enumeration is attempted.
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
            # Plan 110 D1: refuse a tmux recipient the doorbell is not enabled for.
            return ok(self.cli(cmd, stdin=body, extra_env={"CCTRL_SAY_REQUIRE_DOORBELL": "1"}))
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
            ensure_no_extra(args, {"status", "all", "limit"})
            status = optional_string(args, "status", "")
            take_all = require_bool(args, "all", False)
            limit = args.get("limit")
            if limit is not None and (isinstance(limit, bool) or not isinstance(limit, int) or limit < 1):
                raise McpError("validation", "limit must be an integer >= 1")
            if take_all and limit is not None:
                raise McpError("validation", "Use either all or limit, not both.")
            cmd = ["peer", "recv", "--as", self.identity, "--json"]
            if status:
                cmd.extend(["--status", status])
            if take_all:
                cmd.append("--all")
            elif limit is not None:
                cmd.extend(["--limit", str(limit)])
            return ok(self.cli(cmd))
        if name == "show_message":
            ensure_no_extra(args, {"id"})
            message_id = require_string(args, "id")
            message = self.cli(["peer", "show", message_id, "--json"])
            if not isinstance(message, dict):
                raise McpError("invalid-response", "cctrl returned an invalid message envelope")
            me = self.canonical_identity()
            if message.get("to") != me and message.get("from") != me:
                raise McpError("forbidden", f"Message {message_id} is not visible to {self.identity}")
            return ok(message)
        if name == "ack_message":
            ensure_no_extra(args, {"id", "ids", "all"})
            take_all = require_bool(args, "all", False)
            ids = args.get("ids")
            single = args.get("id")
            if ids is not None and (not isinstance(ids, list) or not ids or not all(isinstance(i, str) and i and not i.startswith("-") for i in ids)):
                raise McpError("validation", "ids must be a non-empty list of message ids")
            given = sum(x is not None and x is not False for x in (single, ids, take_all or None))
            if given != 1:
                raise McpError("validation", "Pass exactly one of id, ids, or all: true.")
            if take_all:
                return ok(self.cli(["peer", "ack", "--all", "--as", self.identity, "--json"], batch_report=True))
            # Ids go after `--` so the CLI can never read one as a flag; an id
            # that looks like a flag ("--all") is refused outright.
            if ids is not None:
                return ok(self.cli(["peer", "ack", "--as", self.identity, "--json", "--", *ids], batch_report=True))
            message_id = require_string(args, "id")
            if message_id.startswith("-"):
                raise McpError("validation", "id must be a message id, not a flag")
            return ok(self.cli(["peer", "ack", "--as", self.identity, "--json", "--", message_id]))
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
    # Plan 106 P3b: answer `initialize` without waiting on session discovery
    # (`peer whoami` costs ~22 s on a big fleet; Claude gives up after 30 s). The
    # identity is passed to cctrl on every tool call, and cctrl resolves it and
    # applies the sender-binding rules there (unknown peer: exit 66 / unknown-peer;
    # sender mismatch: refused), so a stale identity still cannot send.
    bridge = Bridge(args.cctrl, args.identity)
    return run(bridge)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
