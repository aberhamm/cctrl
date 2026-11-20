#!/usr/bin/env python3
"""Claude Code cross-session inbound admission: read, resolve and set `crossSessionInbound`.

Pure functions, standard library only. Nothing here prints or exits; callers
(`cctrl peer setup` / `peer doctor`) format the results.

Precedence modelled (Claude Code settings reference, `crossSessionInbound`):
  1. managed (MDM plist, else managed-settings files) wins; an unreadable
     managed value counts as refuse. Server-managed settings cannot be read
     locally and are reported as "unknown".
  2. else the --settings overlay, then user settings.
  3. a project or local value applies only when stricter (accept < hold < refuse);
     with no trusted value, a project or local hold or refuse replaces the
     per-class default.
  4. an unrecognised value in user, project, local or overlay forces hold.

Environment overrides (tests point managed paths at fixtures):
  CCTRL_CLAUDE_MANAGED_DIR         dir holding managed-settings.json / managed-settings.d
  CCTRL_CLAUDE_MANAGED_PLIST_JSON  JSON file standing in for the converted plist
"""

from __future__ import annotations

import datetime as dt
import copy
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Mapping

KEY = "crossSessionInbound"
VALUES = ("accept", "hold", "refuse")
STRICTNESS = {"accept": 0, "hold": 1, "refuse": 2}

MIN_VERSION = (2, 1, 224)        # no cross-session messaging below this
CONFIG_ROW_VERSION = (2, 1, 232)  # /config row "Messages from your other sessions"
INVALID_IGNORED_VERSION = (2, 1, 248)  # invalid value handled as documented from here

PLIST_DOMAIN = "com.anthropic.claudecode"
PLIST_DIR = Path("/Library/Managed Preferences")
PLUTIL = "/usr/bin/plutil"
MAC_MANAGED_DIR = Path("/Library/Application Support/ClaudeCode")
LINUX_MANAGED_DIR = Path("/etc/claude-code")
CONTROL_KEYS = ("wslInheritsWindowsSettings", "managedSourcesBehavior")

MAX_ATTEMPTS = 4
LOCK_TIMEOUT_SECONDS = 10.0


class SettingsError(RuntimeError):
    """A safe, user-actionable failure. The file involved was not modified."""


# --- paths -----------------------------------------------------------------

def user_settings_path(env: Mapping[str, str] | None = None) -> Path:
    env = os.environ if env is None else env
    base = env.get("CLAUDE_CONFIG_DIR")
    if base:
        return Path(base).expanduser() / "settings.json"
    return Path(env.get("HOME") or os.path.expanduser("~")) / ".claude" / "settings.json"


def project_settings_paths(directory: Path | str) -> tuple[Path, Path]:
    d = Path(directory) / ".claude"
    return d / "settings.json", d / "settings.local.json"


def real_target(path: Path) -> Path:
    """The file a write lands on: the symlink target when `path` is a link."""
    return Path(os.path.realpath(path))


def managed_dir(env: Mapping[str, str] | None = None) -> Path:
    env = os.environ if env is None else env
    override = env.get("CCTRL_CLAUDE_MANAGED_DIR")
    if override:
        return Path(override)
    return MAC_MANAGED_DIR if sys.platform == "darwin" else LINUX_MANAGED_DIR


def managed_plist_paths(username: str | None) -> list[Path]:
    """macOS managed-preferences candidates, per-user first then device level.

    Confirmed from the installed Claude Code binary (2.1.329): it builds
    /Library/Managed Preferences/<user>/com.anthropic.claudecode.plist and
    /Library/Managed Preferences/com.anthropic.claudecode.plist and converts
    with /usr/bin/plutil -convert json -o - -- <path>.
    """
    out: list[Path] = []
    if username:
        out.append(PLIST_DIR / username / f"{PLIST_DOMAIN}.plist")
    out.append(PLIST_DIR / f"{PLIST_DOMAIN}.plist")
    return out


# --- reads -----------------------------------------------------------------

@dataclass
class ReadResult:
    path: Path
    status: str  # "absent" | "ok" | "invalid"
    data: dict = field(default_factory=dict)
    error: str = ""


def _parse_object(raw: bytes) -> tuple[dict | None, str]:
    try:
        obj = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        return None, f"not valid JSON: {exc}"
    if not isinstance(obj, dict):
        return None, "top level is not a JSON object"
    return obj, ""


def read_settings(path: Path) -> ReadResult:
    """Read one settings file. Invalid JSON is reported, never treated as {}."""
    try:
        raw = Path(path).read_bytes()
    except FileNotFoundError:
        return ReadResult(Path(path), "absent")
    except OSError as exc:
        return ReadResult(Path(path), "invalid", error=f"unreadable: {exc}")
    obj, err = _parse_object(raw)
    if obj is None:
        return ReadResult(Path(path), "invalid", error=err)
    return ReadResult(Path(path), "ok", obj)


def convert_plist(path: Path) -> dict:
    """plutil -convert json of one plist. Raises SettingsError when malformed."""
    try:
        proc = subprocess.run([PLUTIL, "-convert", "json", "-o", "-", "--", str(path)],
                              capture_output=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise SettingsError(f"cannot run plutil on {path}: {exc}") from exc
    if proc.returncode != 0:
        raise SettingsError(f"plutil rejected {path}: {proc.stderr.decode('utf-8', 'replace').strip()}")
    obj, err = _parse_object(proc.stdout)
    if obj is None:
        raise SettingsError(f"{path}: {err}")
    return obj


@dataclass
class ManagedDoc:
    data: dict = field(default_factory=dict)
    source: str | None = None
    invalid: list[str] = field(default_factory=list)
    server_managed: str = "unknown"  # cannot be read locally; never "clear"
    unknown: list[str] = field(default_factory=list)  # sources present but not readable here


def _has_policy_key(d: dict) -> bool:
    return any(k not in CONTROL_KEYS and v is not None for k, v in d.items())


def _read_plist_doc(env: Mapping[str, str]) -> tuple[dict | None, list[str]]:
    override = env.get("CCTRL_CLAUDE_MANAGED_PLIST_JSON")
    if override is not None:
        r = read_settings(Path(override))
        if r.status == "ok":
            return r.data, []
        if r.status == "invalid":
            return None, [f"{override}: {r.error}"]
        return None, []
    if sys.platform != "darwin":
        return None, []
    try:
        import pwd
        user = pwd.getpwuid(os.getuid()).pw_name
    except (KeyError, ImportError):
        user = None
    for p in managed_plist_paths(user):
        if p.exists():
            try:
                return convert_plist(p), []
            except SettingsError as exc:
                return None, [str(exc)]
    return None, []


def _read_managed_one(p: Path) -> ReadResult:
    # An empty managed settings file counts as {} (managed-settings.md); user files do not.
    try:
        if p.read_bytes().strip() == b"":
            return ReadResult(p, "ok", {})
    except OSError:
        pass
    return read_settings(p)


def _read_managed_files(base: Path) -> tuple[dict | None, list[str]]:
    invalid: list[str] = []
    merged: dict = {}
    present = False
    files = [base / "managed-settings.json"]
    dropin = base / "managed-settings.d"
    try:
        files += sorted(p for p in dropin.iterdir()
                        if p.is_file() and p.suffix == ".json" and not p.name.startswith("."))
    except (FileNotFoundError, NotADirectoryError):
        pass
    for p in files:
        r = _read_managed_one(p)
        if r.status == "absent":
            continue
        present = True
        if r.status == "invalid":
            invalid.append(f"{p}: {r.error}")
            continue
        merged.update(r.data)  # later file replaces single values
    return (merged if present else None), invalid


def read_managed(env: Mapping[str, str] | None = None) -> ManagedDoc:
    """Managed policy as Claude ranks it: MDM plist first, then files (first-wins)."""
    env = os.environ if env is None else env
    doc = ManagedDoc()
    plist, bad = _read_plist_doc(env)
    doc.invalid += bad
    files, bad = _read_managed_files(managed_dir(env))
    doc.invalid += bad
    for label, d in (("MDM", plist), ("managed-settings file", files)):
        if d and "policyHelper" in d:
            doc.unknown.append(f"policyHelper in {label} cannot be read locally; its policy is unknown")
    if plist is not None and _has_policy_key(plist):
        if plist.get("managedSourcesBehavior") == "merge" and files is not None:
            # merge: the higher source wins per key; lower sources fill what it leaves unset
            merged = dict(files)
            merged.update({k: v for k, v in plist.items() if v is not None})
            doc.data, doc.source = merged, "managed preferences (MDM) merged with managed-settings file"
            return doc
        doc.data, doc.source = plist, "managed preferences (MDM)"
        return doc
    if files is not None:
        doc.data, doc.source = files, "managed-settings file"
    return doc


# --- resolution ------------------------------------------------------------

@dataclass
class Effective:
    value: str | None  # None = no value applies; per-class default decides
    source: str
    invalid: list[tuple[str, object]] = field(default_factory=list)
    managed_invalid: bool = False


def _valid(v: object) -> bool:
    return isinstance(v, str) and v in VALUES


def resolve(*, managed: dict | None = None, overlay: object = None, user: dict | None = None,
            project: dict | None = None, local: dict | None = None) -> Effective:
    """Effective crossSessionInbound for one session. See the module docstring."""
    value: str | None = None
    source = "default"
    invalid: list[tuple[str, object]] = []
    managed_invalid = False

    managed_set = managed is not None and KEY in managed and managed[KEY] is not None
    if managed_set:
        if _valid(managed[KEY]):
            value, source = managed[KEY], "managed settings"
        else:
            value, source, managed_invalid = "refuse", "managed settings", True
    for label, raw, present in (("--settings overlay", overlay, overlay is not None),
                                ("user settings", (user or {}).get(KEY), user is not None and KEY in user)):
        if not present:
            continue
        if not _valid(raw):
            invalid.append((label, raw))
        elif value is None:
            value, source = raw, label

    # Project and local: honoured only when stricter than what is trusted so far.
    for label, doc in (("project settings", project), ("local settings", local)):
        if doc is None or KEY not in doc:
            continue
        v = doc[KEY]
        if not _valid(v):
            invalid.append((label, v))
            continue
        if v == "accept":
            continue
        if value is None or STRICTNESS[v] > STRICTNESS[value] or (
                STRICTNESS[v] == STRICTNESS[value] and source in ("project settings",) and label == "local settings"):
            value, source = v, label

    # An unrecognised value forces hold; it never loosens a stricter value.
    if invalid and (value is None or STRICTNESS[value] < STRICTNESS["hold"]):
        value = "hold"
        source = invalid[0][0]
    return Effective(value, source, invalid, managed_invalid)


# --- versions --------------------------------------------------------------

Version = tuple[int, int, int]


def parse_version(text: str | None) -> Version | None:
    # First line only, leading X.Y.Z (optionally "v" or "claude " before it) followed by
    # whitespace or the end. A "-rc" suffix, a fourth number or a later line is not accepted.
    lines = (text or "").strip().splitlines()
    m = re.match(r"\s*(?:claude\s+|v)?(\d+)\.(\d+)\.(\d+)(?=\s|$)", lines[0]) if lines else None
    return (int(m[1]), int(m[2]), int(m[3])) if m else None


def _fmt(v: Version) -> str:
    return ".".join(map(str, v))


@dataclass
class VersionGate:
    refuse: bool = False
    needs_yes: bool = False
    warnings: list[str] = field(default_factory=list)


def version_gate(version: Version | None) -> VersionGate:
    g = VersionGate()
    if version is None:
        g.needs_yes = True
        g.warnings.append("could not determine the Claude Code version (claude not on PATH, "
                          "unparseable, or a pre-release such as -rc); confirm with --yes")
        return g
    if version < MIN_VERSION:
        g.refuse = True
        g.warnings.append(f"Claude Code {_fmt(version)} has no cross-session messaging; "
                          f"need {_fmt(MIN_VERSION)} or later (claude update)")
        return g
    if version < CONFIG_ROW_VERSION:
        g.warnings.append(f"Claude Code {_fmt(version)} has no /config row for {KEY}; "
                          f"the settings file still works ({_fmt(CONFIG_ROW_VERSION)}+ adds the row)")
    if version < INVALID_IGNORED_VERSION:
        g.warnings.append(f"Claude Code {_fmt(version)} may silently ignore an invalid {KEY} value; "
                          f"{_fmt(INVALID_IGNORED_VERSION)}+ handles it as documented")
    return g


def detect_claude_version(env: Mapping[str, str] | None = None) -> Version | None:
    env = dict(os.environ if env is None else env)
    try:
        proc = subprocess.run(["claude", "--version"], capture_output=True, text=True, timeout=15,
                              check=False, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return parse_version(proc.stdout) if proc.returncode == 0 else None


# --- preflight -------------------------------------------------------------

@dataclass
class Preflight:
    own: Effective
    spawn: Effective
    warnings: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    blocked: bool = False
    exit_code: int = 0
    needs_yes: bool = False
    server_managed: str = "unknown"
    version: Version | None = None


def preflight(target: str | None, *, env: Mapping[str, str] | None = None,
              project_dir: Path | str | None = None, overlay: object = None,
              yes: bool = False) -> Preflight:
    """Everything setup and doctor check before a write. Exit 2 = version, 3 = managed override."""
    env = os.environ if env is None else env
    if target is not None and target not in VALUES:
        raise ValueError(f"value must be one of {VALUES} or None")
    project_dir = Path(project_dir) if project_dir else Path.cwd()

    version = detect_claude_version(env)
    gate = version_gate(version)
    managed = read_managed(env)
    user = read_settings(user_settings_path(env))
    pp, lp = project_settings_paths(project_dir)
    proj, loc = read_settings(pp), read_settings(lp)

    def doc(r: ReadResult) -> dict | None:
        return r.data if r.status == "ok" else None

    kw = dict(managed=managed.data if managed.source else None,
              user=doc(user), project=doc(proj), local=doc(loc))
    own = resolve(**kw)
    spawn = resolve(overlay=overlay, **kw)

    pf = Preflight(own, spawn, list(gate.warnings), server_managed=managed.server_managed, version=version)
    pf.needs_yes = gate.needs_yes and not yes

    for text in managed.invalid:
        pf.warnings.append(f"managed settings unreadable ({text}); Claude Code refuses to start with it")
    for r in (user, proj, loc):
        if r.status == "invalid":
            pf.warnings.append(f"{r.path} is not valid JSON ({r.error}); Claude Code skips the file")
    for label, val in own.invalid + [i for i in spawn.invalid if i not in own.invalid]:
        pf.warnings.append(f"unrecognised {KEY} value {val!r} in {label}: inbound mail is forced to hold")
    for r in (user, proj, loc):
        if r.status == "ok" and r.data.get("isolatePeerMachines") is True:
            pf.warnings.append(f"isolatePeerMachines is true in {r.path}: unattended bypass workers "
                               f"would stall on the cross-machine approval prompt")
    if managed.data.get("isolatePeerMachines") is True:
        pf.warnings.append("isolatePeerMachines is true in managed settings")

    for label, r in (("project settings", proj), ("local settings", loc)):
        if r.status == "ok" and _valid(r.data.get(KEY)) and r.data[KEY] != "accept":
            pf.notes.append(f"applies in this repo only: {r.data[KEY]} ({label}, {r.path})")

    pf.notes.extend(managed.unknown)
    pf.notes.append(f"server-managed settings: {managed.server_managed} (cannot be read locally)")

    if gate.refuse:
        pf.blocked, pf.exit_code = True, 2
    elif managed.source and KEY in managed.data and managed.data[KEY] is not None:
        mval = "refuse" if own.managed_invalid else managed.data[KEY]
        if target is None or mval != target:
            pf.warnings.append(f"managed value {mval} overrides; nothing you set applies "
                               f"(source: {managed.source})")
            pf.blocked, pf.exit_code = True, 3
        else:
            pf.notes.append(f"managed value already {mval} ({managed.source})")
    return pf


# --- atomic merge ----------------------------------------------------------

def _version_of(raw: bytes | None) -> str:
    return "absent" if raw is None else "sha256:" + hashlib.sha256(raw).hexdigest()


def _read_raw(path: Path) -> bytes | None:
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise SettingsError(f"cannot read {path}: {exc}") from exc


def _indent_of(raw: bytes | None):
    if raw:
        m = re.search(rb"\n([ \t]+)\"", raw)
        if m:
            ws = m[1]
            return "\t" if ws.startswith(b"\t") else len(ws)
    return 2


def _write_temp(directory: Path, prefix: str, raw: bytes, mode: int) -> Path:
    fd, name = tempfile.mkstemp(prefix=prefix, suffix=".tmp", dir=directory)
    p = Path(name)
    try:
        os.fchmod(fd, mode)
        s = os.fdopen(fd, "wb", closefd=True)
        fd = -1  # the file object owns the descriptor now; it closes it exactly once
        with s:
            s.write(raw)
            s.flush()
            os.fsync(s.fileno())
        return p
    except BaseException:
        if fd >= 0:
            os.close(fd)
        p.unlink(missing_ok=True)
        raise


def _backup(path: Path, raw: bytes, mode: int) -> Path:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    final = path.parent / f"{path.name}.cctrl-backup-{stamp}"
    tmp = _write_temp(path.parent, f"{path.name}.cctrl-backup-{stamp}-", raw, mode)
    os.replace(tmp, final)
    return final


def _lock(path: Path) -> int:
    lock_path = path.with_name(f".{path.name}.cctrl.lock")
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        deadline = time.monotonic() + LOCK_TIMEOUT_SECONDS
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return fd
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise SettingsError(f"timed out waiting for the settings lock: {lock_path}")
                time.sleep(0.05)
    except BaseException:
        os.close(fd)
        raise


def edit_settings(path: Path, mutate: Callable[[dict], None], *,
                  before_compare: Callable[[int, Path], None] | None = None,
                              ) -> tuple[bool, Path | None]:
    """Apply `mutate(cfg)` to a settings file (locked, atomic, backed up).

    Returns (changed, backup_path). Other keys and their order untouched. Invalid JSON, a non-object top level or an empty file is refused
    with SettingsError and the file is left as it was. A symlink is written
    through to its target. `before_compare` exists for deterministic race tests.
    """
    path = real_target(Path(path).expanduser())
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_fd = _lock(path)
    try:
        for attempt in range(1, MAX_ATTEMPTS + 1):
            source_raw = _read_raw(path)
            if source_raw is None:
                cfg: dict = {}
            else:
                parsed, err = _parse_object(source_raw)
                if parsed is None:
                    raise SettingsError(f"refusing to change {path}: {err}; fix it by hand first")
                cfg = parsed
            new = copy.deepcopy(cfg)
            mutate(new)
            if new == cfg and list(new) == list(cfg):
                return False, None
            mode = stat.S_IMODE(path.stat().st_mode) if source_raw is not None else 0o600
            indent = _indent_of(source_raw)
            candidate_raw = (json.dumps(new, indent=indent, ensure_ascii=False) + "\n").encode("utf-8")
            if json.loads(candidate_raw.decode("utf-8")) != new:
                raise SettingsError("internal error: candidate did not round-trip")
            candidate = _write_temp(path.parent, f".{path.name}.cctrl-", candidate_raw, mode)
            try:
                if before_compare is not None:
                    before_compare(attempt, path)
                current_raw = _read_raw(path)
                if _version_of(current_raw) != _version_of(source_raw):
                    if attempt == MAX_ATTEMPTS:
                        raise SettingsError(f"{path} kept changing; no replacement was made")
                    continue
                backup = _backup(path, current_raw, mode) if current_raw is not None else None
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
    raise SettingsError("unreachable settings merge state")


def set_cross_session_inbound(path: Path, value: str | None, *,
                              before_compare: Callable[[int, Path], None] | None = None,
                              ) -> tuple[bool, Path | None]:
    """Set (or, with value None, remove) crossSessionInbound in a settings file."""
    if value is not None and value not in VALUES:
        raise ValueError(f"value must be one of {VALUES} or None")

    def mutate(cfg: dict) -> None:
        if value is None:
            cfg.pop(KEY, None)
        else:
            cfg[KEY] = value

    return edit_settings(path, mutate, before_compare=before_compare)
