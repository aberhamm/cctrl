#!/usr/bin/env python3
"""Safe read-modify-write of a Claude Code settings.json, shared by `peer setup` and `hooks install`.

Reuses the primitives of claude_inbound (lock, same-directory fsynced temp file,
exact-bytes backup, os.replace, changed-under-us retry). Invalid JSON is refused,
never read as {}; the file is left byte-identical. Standard library only.
"""

from __future__ import annotations

import copy
import fcntl
import json
import os
import stat
import sys
from pathlib import Path
from typing import Callable

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import claude_inbound as ci  # noqa: E402


def edit_settings(path: Path, mutate: Callable[[dict], None]) -> tuple[bool, Path | None]:
    """Apply `mutate(cfg)` to the settings file. Returns (changed, backup_path).

    A missing file starts from {}. Invalid JSON, an empty file or a non-object
    top level raises claude_inbound.SettingsError and writes nothing.
    """
    path = ci.real_target(Path(path).expanduser())
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_fd = ci._lock(path)
    try:
        for attempt in range(1, ci.MAX_ATTEMPTS + 1):
            source_raw = ci._read_raw(path)
            if source_raw is None:
                cfg: dict = {}
            else:
                parsed, err = ci._parse_object(source_raw)
                if parsed is None:
                    raise ci.SettingsError(f"refusing to change {path}: {err}; fix it by hand first")
                cfg = parsed
            new = copy.deepcopy(cfg)
            mutate(new)
            if new == cfg and source_raw is not None:
                return False, None
            mode = stat.S_IMODE(path.stat().st_mode) if source_raw is not None else 0o600
            raw = (json.dumps(new, indent=ci._indent_of(source_raw), ensure_ascii=False) + "\n").encode("utf-8")
            if json.loads(raw.decode("utf-8")) != new:
                raise ci.SettingsError("internal error: candidate did not round-trip")
            candidate = ci._write_temp(path.parent, f".{path.name}.cctrl-", raw, mode)
            try:
                current_raw = ci._read_raw(path)
                if ci._version_of(current_raw) != ci._version_of(source_raw):
                    if attempt == ci.MAX_ATTEMPTS:
                        raise ci.SettingsError(f"{path} kept changing; no replacement was made")
                    continue
                backup = ci._backup(path, current_raw, mode) if current_raw is not None else None
                os.replace(candidate, path)
                dfd = os.open(path.parent, os.O_RDONLY)
                try:
                    os.fsync(dfd)
                finally:
                    os.close(dfd)
                return True, backup
            finally:
                candidate.unlink(missing_ok=True)
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)
    raise ci.SettingsError("unreachable settings merge state")
