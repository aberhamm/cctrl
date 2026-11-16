#!/usr/bin/env python3
"""Describe the caller's provider session without granting runtime ownership.

Only selected identity variables or an ancestor's Claude PID registry are read.
No transcript, credential, or ambient environment snapshot is persisted.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def session_value(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,159}", value):
        raise ValueError("provider session ID must be 1..160 letters, digits, dots, underscores or hyphens")
    return value


def identity_name(identity: dict) -> str:
    key = json.dumps([identity["host_id"], identity["provider"], identity["session_id"]], separators=(",", ":"))
    return f"external-{identity['provider']}-{hashlib.sha256(key.encode()).hexdigest()}"


def origin_peer(raw: str, name: str, host: str) -> dict:
    if not raw or len(raw) > 4096:
        raise ValueError("invalid external origin envelope size")
    peer = json.loads(base64.b64decode(raw, validate=True))
    if not isinstance(peer, dict) or set(peer) != {"name", "host", "agent", "external_identity"}:
        raise ValueError("invalid external origin envelope")
    identity = peer["external_identity"]
    if not isinstance(identity, dict) or set(identity) != {"provider", "session_id", "host_id", "basis"}:
        raise ValueError("invalid external origin session")
    if identity["provider"] not in {"claude", "codex"} or peer["agent"] != identity["provider"]:
        raise ValueError("invalid external origin provider")
    for key in ("session_id", "host_id"):
        if not isinstance(identity[key], str):
            raise ValueError("invalid external origin identity")
        session_value(identity[key])
    if peer["name"] != name or identity_name(identity) != name or peer["host"] != host or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", host):
        raise ValueError("external origin identity or host mismatch")
    return {**peer, "external_identity": {**identity, "basis": "remote-session-claimed"}}


def environment_identity(env: dict[str, str]) -> dict | None:
    codex = env.get("CODEX_THREAD_ID") or env.get("CODEX_SESSION_ID")
    claude = env.get("CLAUDE_CODE_SESSION_ID")
    if env.get("CODEX_THREAD_ID") and env.get("CODEX_SESSION_ID") and env["CODEX_THREAD_ID"] != env["CODEX_SESSION_ID"]:
        raise ValueError("CODEX_THREAD_ID and CODEX_SESSION_ID disagree")
    if codex and claude:
        raise ValueError("both Claude and Codex session identities are present; remove stale inherited identity variables")
    if codex or claude:
        return {"provider": "codex" if codex else "claude", "session_id": session_value(codex or claude),
                "basis": "environment-claimed"}
    return None


def claude_ancestor_identity(directory: Path) -> dict | None:
    # Read only records for actual ancestors, never a cwd/title or latest-file
    # match. A PID registry is evidence of a session, not authenticated authority.
    pid = os.getppid()
    for _ in range(32):
        if pid <= 1:
            break
        row = subprocess.run(["ps", "-p", str(pid), "-o", "ppid=", "-o", "comm="],
                             capture_output=True, text=True, timeout=1)
        fields = row.stdout.strip().split(None, 1)
        if row.returncode or len(fields) != 2 or not fields[0].isdigit():
            break
        executable = fields[1]
        name = Path(executable).name
        if name in {"claude", "claude.exe"} or "/claude/versions/" in executable:
            path = directory / f"{pid}.json"
            if path.is_symlink():
                raise ValueError("Claude ancestor session registry is a symlink")
            try:
                if path.stat().st_size > 65536:
                    raise ValueError("Claude ancestor session registry is too large")
                with path.open() as handle:
                    record = json.load(handle)
            except FileNotFoundError:
                return None
            if not isinstance(record, dict) or record.get("pid") != pid:
                raise ValueError("Claude ancestor session registry has a different PID")
            started = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="],
                                     env={**os.environ, "LC_ALL": "C", "TZ": "UTC"},
                                     capture_output=True, text=True, timeout=1)
            expected = record.get("procStart")
            if started.returncode or not isinstance(expected, str) or not expected.strip() or " ".join(started.stdout.split()) != " ".join(expected.split()):
                raise ValueError("Claude ancestor registry process-start identity is missing or stale")
            value = record.get("sessionId")
            if not isinstance(value, str):
                raise ValueError("Claude ancestor session registry has no sessionId")
            return {"provider": "claude", "session_id": session_value(value), "basis": "ancestor-registry"}
        pid = int(fields[0])
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", choices=("claude", "codex"))
    parser.add_argument("--session-id")
    parser.add_argument("--sessions-dir", type=Path)
    parser.add_argument("--host-id")
    parser.add_argument("--origin-base64")
    parser.add_argument("--origin-name")
    parser.add_argument("--origin-host")
    args = parser.parse_args()
    try:
        if args.origin_base64 is not None:
            print(json.dumps(origin_peer(args.origin_base64, args.origin_name or "", args.origin_host or "")))
            return 0
        identity = environment_identity(os.environ)
        if args.agent or args.session_id:
            if not args.agent or not args.session_id:
                raise ValueError("--agent and --session-id must be supplied together")
            requested = {"provider": args.agent, "session_id": session_value(args.session_id)}
            if identity and any(identity[key] != value for key, value in requested.items()):
                raise ValueError("explicit provider session disagrees with the current session environment")
            identity = identity or {**requested, "basis": "explicit-session-claimed"}
        if identity is None and os.environ.get("CLAUDECODE"):
            directory = args.sessions_dir or Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))) / "sessions"
            identity = claude_ancestor_identity(directory)
        if identity is None:
            raise ValueError("no provider session identity; use cctrl peer identify --agent claude|codex --session-id <your actual native session ID>")
        if args.host_id:
            identity["host_id"] = args.host_id
            identity["name"] = identity_name(identity)
        print(json.dumps(identity))
        return 0
    except (ValueError, OSError, subprocess.TimeoutExpired, TypeError, KeyError) as exc:
        print(str(exc), file=sys.stderr)
        return 66


if __name__ == "__main__":
    sys.exit(main())
