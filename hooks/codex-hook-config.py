#!/usr/bin/env python3
"""Install cctrl-owned Codex hooks without rewriting unrelated configuration."""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import fcntl
import hashlib
import json
import os
import stat
import tempfile
import time
from pathlib import Path
from typing import Callable


MAX_ATTEMPTS = 4
LOCK_TIMEOUT_SECONDS = 10.0
ABSENT_VERSION = "absent"

OWNED_COMMANDS = {
    "pre-tool-use": "cctrl hooks run pre-tool-use",
    "stop": "cctrl hooks run stop",
    "notify": "cctrl hooks run notify",
    "codex-observe": "cctrl hooks run codex-observe",
}

# SessionStart and PreCompact are observed in the plan-057 fixtures. Their
# matching completion boundaries are part of the same validated Codex schema.
LIFECYCLE_EVENTS = ("SessionStart", "SessionEnd", "PreCompact", "PostCompact")

EVENT_SPECS = (
    ("PreToolUse", "pre-tool-use", {"matcher": "Bash"}),
    ("Stop", "stop", {}),
    ("PermissionRequest", "notify", {}),
    *((event, "codex-observe", {}) for event in LIFECYCLE_EVENTS),
)


class InstallError(RuntimeError):
    """A safe, user-actionable installation failure."""


def _leaf(command_name: str) -> dict[str, str]:
    return {"type": "command", "command": OWNED_COMMANDS[command_name]}


def _version(raw: bytes | None) -> str:
    if raw is None:
        return ABSENT_VERSION
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def _read_regular(path: Path) -> bytes | None:
    """Read a destination without following a final symlink."""
    try:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(path, flags)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise InstallError(f"refusing to read {path}: {exc}") from exc
    try:
        mode = os.fstat(fd).st_mode
        if not stat.S_ISREG(mode):
            raise InstallError(f"refusing non-regular Codex hook destination: {path}")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def _parse(raw: bytes | None, path: Path) -> dict:
    if raw is None:
        return {}
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise InstallError(
            f"invalid JSON in {path}; left it untouched. Repair or move the file, then retry: {exc}"
        ) from exc
    if not isinstance(value, dict):
        raise InstallError(f"invalid Codex hook config in {path}: top level must be an object")
    hooks = value.get("hooks")
    if hooks is not None and not isinstance(hooks, dict):
        raise InstallError(f"invalid Codex hook config in {path}: 'hooks' must be an object")
    return value


def _merge(source: dict) -> dict:
    """Remove only exact owned leaves, then add one canonical owned wrapper."""
    cfg = copy.deepcopy(source)
    hooks = cfg.setdefault("hooks", {})
    if not isinstance(hooks, dict):  # Defensive; _parse normally catches this.
        raise InstallError("invalid Codex hook config: 'hooks' must be an object")

    for event, command_name, canonical_metadata in EVENT_SPECS:
        entries = hooks.get(event, [])
        if not isinstance(entries, list):
            raise InstallError(f"invalid Codex hook config: hooks.{event} must be an array")
        owned = _leaf(command_name)
        merged_entries = []
        for wrapper in entries:
            if not isinstance(wrapper, dict):
                raise InstallError(f"invalid Codex hook config: hooks.{event} entries must be objects")
            leaves = wrapper.get("hooks", [])
            if not isinstance(leaves, list):
                raise InstallError(f"invalid Codex hook config: hooks.{event}[].hooks must be an array")
            remaining = [leaf for leaf in leaves if leaf != owned]
            updated = copy.deepcopy(wrapper)
            updated["hooks"] = remaining
            remaining_metadata = {key: value for key, value in updated.items() if key != "hooks"}
            # Only an otherwise-empty canonical cctrl wrapper is disposable.
            # Mixed or extended wrappers remain, even if leaf removal empties them.
            if not remaining and remaining_metadata == canonical_metadata:
                continue
            merged_entries.append(updated)

        canonical = {"hooks": [owned], **canonical_metadata}
        if event == "Stop":
            merged_entries.insert(0, canonical)
        else:
            merged_entries.append(canonical)
        hooks[event] = merged_entries
    return cfg


def _serialize(cfg: dict) -> bytes:
    raw = (json.dumps(cfg, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    # Reparse the exact candidate bytes before they can reach the destination.
    parsed = json.loads(raw.decode("utf-8"))
    if parsed != cfg:
        raise InstallError("internal error: serialized Codex hook candidate did not round-trip")
    return raw


def _write_fsynced_temp(directory: Path, prefix: str, raw: bytes) -> Path:
    fd, name = tempfile.mkstemp(prefix=prefix, suffix=".tmp", dir=directory)
    path = Path(name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb", closefd=True) as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        fd = -1
        return path
    except BaseException:
        if fd >= 0:
            os.close(fd)
        path.unlink(missing_ok=True)
        raise


def _backup_exact(path: Path, raw: bytes) -> Path:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = _write_fsynced_temp(path.parent, f"{path.name}.cctrl-backup-{stamp}-", raw)
    final = backup.with_suffix("")
    os.replace(backup, final)
    return final


def _open_lock(path: Path) -> int:
    lock_path = path.with_name(f".{path.name}.cctrl.lock")
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(lock_path, flags, 0o600)
    except OSError as exc:
        raise InstallError(f"cannot open cooperative hook-config lock {lock_path}: {exc}") from exc
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise InstallError(f"refusing non-regular hook-config lock: {lock_path}")
        os.fchmod(fd, 0o600)
        deadline = time.monotonic() + LOCK_TIMEOUT_SECONDS
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return fd
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise InstallError(f"timed out waiting for cooperative hook-config lock: {lock_path}")
                time.sleep(0.05)
    except BaseException:
        os.close(fd)
        raise


def install(
    path: Path,
    *,
    before_compare: Callable[[int, Path], None] | None = None,
) -> tuple[bool, Path | None]:
    """Install hooks, returning (changed, backup_path).

    ``before_compare`` exists for deterministic race tests and is never wired
    to CLI input or environment variables.
    """
    path = path.expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_fd = _open_lock(path)
    try:
        for attempt in range(1, MAX_ATTEMPTS + 1):
            source_raw = _read_regular(path)
            source_version = _version(source_raw)
            source_cfg = _parse(source_raw, path)
            merged = _merge(source_cfg)
            if merged == source_cfg:
                return False, None
            candidate_raw = _serialize(merged)
            candidate = _write_fsynced_temp(path.parent, f".{path.name}.cctrl-", candidate_raw)
            backup: Path | None = None
            try:
                # Ensure the on-disk temp is the candidate we validated.
                _parse(_read_regular(candidate), candidate)
                if before_compare is not None:
                    before_compare(attempt, path)
                current_raw = _read_regular(path)
                if _version(current_raw) != source_version:
                    candidate.unlink(missing_ok=True)
                    if attempt == MAX_ATTEMPTS:
                        raise InstallError(
                            f"{path} kept changing during installation; no replacement was made"
                        )
                    continue
                if current_raw is not None:
                    backup = _backup_exact(path, current_raw)
                # A non-cooperating writer can still race after the comparison.
                # The exact-byte backup above is the recovery point for that
                # documented residual window.
                os.replace(candidate, path)
                directory_fd = os.open(path.parent, os.O_RDONLY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
                return True, backup
            finally:
                candidate.unlink(missing_ok=True)
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)
    raise InstallError("unreachable hook installation state")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    try:
        changed, backup = install(args.path)
    except InstallError as exc:
        print(f"error: {exc}", file=os.sys.stderr)
        return 1
    if changed:
        print(f"changed\t{backup or '-'}")
    else:
        print("unchanged\t-")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
