#!/usr/bin/env python3
"""Messaging-readiness checks for `cctrl peer doctor` (read-only).

Prints a JSON array of checks. Each check is
  {"name", "ok", "status": "pass"|"warn"|"fail", "summary", "remedy"?}
`ok` is false only for status "fail", so a missing opt-in (warn) never fails
doctor: accept is a choice, not a requirement. Nothing here writes a file,
sends a message, or stops a process. Standard library only.

Arguments (the shell wrapper supplies them):
  --project-dir DIR      repo whose project/local settings are read (default: cwd)
  --codex-threads CSV    thread ids of live cctrl-owned Codex sessions
  --hosts CSV            other host aliases, for the remote form of each fix
  --bridge-root DIR      native-bridge state dir (ledger.sqlite3 is read read-only)
  --config-inbound V     cctrl config messaging.claude.crossSessionInbound
  --config-override B    cctrl config messaging.claude.overrideUser (true/false)
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import claude_inbound as ci  # noqa: E402

PASS, WARN, FAIL = "pass", "warn", "fail"
SETUP_USER = "cctrl peer setup --scope user"
SETUP_SPAWNED = "cctrl peer setup --scope spawned"


def check(name: str, status: str, summary: str, remedy: str | None = None, **extra) -> dict:
    out = {"name": name, "ok": status != FAIL, "status": status, "summary": summary}
    if remedy and status != PASS:
        out["remedy"] = remedy
    out.update(extra)
    return out


def remote_form(hosts: list[str], command: str = "peer setup --yes") -> str:
    """The same fix on another Mac: one `cctrl --host ALIAS ...` per known alias."""
    return "; ".join(f"on another Mac: cctrl --host {h} {command}" for h in hosts)


def _with_remote(local: str, hosts: list[str], command: str = "peer setup --yes") -> str:
    extra = remote_form(hosts, command)
    return f"{local}; {extra}" if extra else local


# --- Claude checks ----------------------------------------------------------

def _version_check(env, version, on_path: bool) -> dict:
    name = "claude_cli_version"
    fix = "update Claude Code (claude update)"
    if not on_path:
        return check(name, WARN, "claude was not found on PATH, so its version cannot be checked",
                     "install Claude Code, or put claude on PATH")
    if version is None:
        return check(name, WARN, "the Claude Code version could not be checked (claude --version printed "
                     "nothing parseable, or failed)", "run claude --version by hand and fix what it prints")
    shown = ".".join(map(str, version))
    gate = ci.version_gate(version)
    if gate.refuse:
        return check(name, FAIL, gate.warnings[0], fix, version=shown)
    if gate.warnings:
        return check(name, WARN, "; ".join(gate.warnings), fix, version=shown)
    return check(name, PASS, f"Claude Code {shown}", version=shown)


def _source_path(label: str, user_path: Path, proj: Path, loc: Path) -> str:
    return {"user settings": str(user_path), "project settings": str(proj),
            "local settings": str(loc)}.get(label, label)


def _settings_state(env, project_dir: Path):
    user_path = ci.user_settings_path(env)
    user = ci.read_settings(user_path)
    pp, lp = ci.project_settings_paths(project_dir)
    return user_path, user, pp, ci.read_settings(pp), lp, ci.read_settings(lp), ci.read_managed(env)


def _doc(r):
    return r.data if r.status == "ok" else None


def _describe(eff: ci.Effective) -> str:
    return f"{eff.value} ({eff.source})" if eff.value else "not set (Claude's per-class default decides)"


def _own_check(own: ci.Effective, hosts) -> dict:
    name = "claude_inbound_own_sessions"
    summary = f"sessions you start yourself: {_describe(own)}"
    if own.value == "accept":
        return check(name, PASS, summary, effective=own.value, source=own.source)
    if own.invalid:
        return check(name, WARN, summary + f"; this is not a deliberate hold: {ci.KEY} has an unrecognised value, "
                     "which forces hold (see claude_inbound_invalid)",
                     f"fix or remove the unrecognised {ci.KEY} value (see claude_inbound_invalid)",
                     effective=own.value, source=own.source)
    if own.value in ("hold", "refuse") and own.source != "default":
        return check(name, PASS, summary + "; set on purpose, so messages from sessions of another permission "
                     "class wait for approval or are refused", effective=own.value, source=own.source)
    return check(name, WARN, summary + "; a message from a bypass worker is held until you approve it in this "
                 "session, and Desktop, VS Code and claude -p cannot show that dialog (it expires)",
                 _with_remote(SETUP_USER, hosts), effective=own.value, source=own.source)


_RANK = {"accept": 0, "hold": 1, "refuse": 2}


def _spawn_overlay(config_inbound: str, override: bool, user: dict | None):
    """The value cctrl puts in a spawn's --settings overlay, mirroring _spawn_cross_session_inbound."""
    if config_inbound not in ci.VALUES:
        return None, ("messaging.claude.crossSessionInbound is not accept, hold or refuse; ignored"
                      if config_inbound else None)
    uv = (user or {}).get(ci.KEY)
    if not override and uv in ("hold", "refuse") and _RANK[uv] > _RANK[config_inbound]:
        return None, (f"user settings set {uv} and the overlay will not override it "
                      f"(cctrl peer setup --scope spawned --override-user)")
    return config_inbound, None


def _spawn_check(managed, user, proj, loc, config_inbound, override, hosts, bad_override: str = "") -> dict:
    """Spawned-session readiness; the remedy depends on which file holds the value."""
    name = "claude_inbound_spawned"
    overlay, note = _spawn_overlay(config_inbound, override, _doc(user))
    eff = ci.resolve(managed=managed.data if managed.source else None, overlay=overlay,
                     user=_doc(user), project=_doc(proj), local=_doc(loc))
    summary = f"sessions cctrl spawns: {_describe(eff)}" + (f"; {note}" if note else "")
    bad_text = ""
    bad_fix = ""
    if bad_override:
        bad_text = (f"; messaging.claude.overrideUser is {bad_override}, not the JSON boolean true, so it counts as "
                    f"false")
        bad_fix = ("set messaging.claude.overrideUser to true (a JSON boolean) or remove it "
                   "(cctrl peer setup --scope spawned --override-user writes it correctly)")
    if eff.value == "accept":
        if bad_override:
            return check(name, WARN, summary + bad_text, bad_fix, effective=eff.value, source=eff.source)
        return check(name, PASS, summary, effective=eff.value, source=eff.source)
    tail = "; cctrl starts every Claude in bypass mode, so held messages wait for a person to approve them in that worker"
    if eff.source == "managed settings":
        fix = f"managed settings set {eff.value}; ask your administrator (peer setup cannot change it)"
    elif eff.source in ("project settings", "local settings") and eff.value in ("hold", "refuse") and not eff.invalid:
        path = proj.path if eff.source == "project settings" else loc.path
        fix = (f"edit {ci.KEY} in {path} ({eff.source}); peer setup does not change a project or local "
               "value, and it overrides the spawned opt-in")
    elif eff.invalid:
        fix = f"fix or remove the unrecognised {ci.KEY} value (see claude_inbound_invalid)"
    else:
        fix = _with_remote(f"{SETUP_SPAWNED} (or {SETUP_USER})", hosts,
                           "peer setup --scope spawned --yes")
    if bad_fix:
        fix = f"{fix}; also {bad_fix}"
    return check(name, WARN, summary + bad_text + tail, fix, effective=eff.value, source=eff.source)


def _managed_check(managed) -> dict:
    name = "claude_inbound_managed"
    unknown = f"server-managed settings: {managed.server_managed} (cannot be read locally)"
    if managed.invalid:
        return check(name, FAIL, "managed settings are unreadable (" + "; ".join(managed.invalid)
                     + "); Claude Code refuses an unreadable managed value", "fix the managed settings; ask your administrator")
    val = managed.data.get(ci.KEY) if managed.source else None
    if val is None:
        return check(name, PASS, "no managed crossSessionInbound value; " + unknown)
    if val not in ci.VALUES:
        return check(name, FAIL, f"managed {ci.KEY} {val!r} is not recognised and counts as refuse "
                     f"({managed.source}); {unknown}", "managed settings set an invalid value; ask your administrator")
    if val == "accept":
        return check(name, PASS, f"managed value accept ({managed.source}); {unknown}")
    return check(name, WARN, f"managed value {val} ({managed.source}) overrides; nothing you set applies; {unknown}",
                 f"managed settings set {val}; ask your administrator")


def _project_check(project_dir: Path, proj, loc) -> dict:
    name = "claude_inbound_project_stricter"
    hits = [(label, r) for label, r in (("project settings", proj), ("local settings", loc))
            if r.status == "ok" and r.data.get(ci.KEY) in ("hold", "refuse")]
    if not hits:
        return check(name, PASS, f"no stricter value in {project_dir}")
    text = "; ".join(f"{r.data[ci.KEY]} in {label} ({r.path})" for label, r in hits)
    return check(name, WARN, f"applies in this repo only: {text}",
                 f"edit {project_dir}/.claude/settings.json or settings.local.json")


def _invalid_check(managed, user_path, user, proj, loc) -> dict:
    name = "claude_inbound_invalid"
    bad: list[str] = []
    first_file = None
    for label, r in (("user settings", user), ("project settings", proj), ("local settings", loc)):
        if r.status == "invalid":
            bad.append(f"{r.path} is not valid JSON ({r.error}); Claude Code skips the file")
            first_file = first_file or str(r.path)
        elif r.status == "ok" and ci.KEY in r.data and not ci._valid(r.data[ci.KEY]):
            bad.append(f"unrecognised {ci.KEY} value {r.data[ci.KEY]!r} in {r.path}: inbound mail is forced to hold")
            first_file = first_file or str(r.path)
    if not bad:
        return check(name, PASS, f"no unrecognised {ci.KEY} value and no unreadable settings file")
    return check(name, FAIL, "; ".join(bad), f"fix or remove {ci.KEY} in {first_file}")


def _isolate_check(managed, user, proj, loc) -> dict:
    name = "claude_isolate_peer_machines"
    files = [str(r.path) for r in (user, proj, loc) if r.status == "ok" and r.data.get("isolatePeerMachines") is True]
    is_managed = managed.data.get("isolatePeerMachines") is True
    where = files + (["managed settings"] if is_managed else [])
    if not where:
        return check(name, PASS, "isolatePeerMachines is not set to true")
    fixes = ([f"remove isolatePeerMachines from {files[0]}"] if files else []) + (
        ["managed settings set isolatePeerMachines; ask your administrator"] if is_managed else [])
    return check(name, WARN, "isolatePeerMachines is true in " + ", ".join(where)
                 + ": unattended bypass workers stall on the cross-machine approval prompt", "; ".join(fixes))


def _dialog_check(env, managed, user, proj, loc) -> dict:
    name = "claude_dialog_expiry"
    seen = []
    for label, d in (("managed", managed.data if managed.source else {}), ("user", _doc(user) or {}),
                     ("project", _doc(proj) or {}), ("local", _doc(loc) or {})):
        if "dialogExpiry" in d:
            seen.append((label, d["dialogExpiry"]))
    envv = env.get("CLAUDE_CODE_USER_DIALOG_TIMEOUT_MS")
    parts = [f"dialogExpiry {v!r} in {label} settings" for label, v in seen]
    if envv:
        parts.append(f"CLAUDE_CODE_USER_DIALOG_TIMEOUT_MS={envv}")
    if not parts:
        return check(name, PASS, "dialogExpiry not set: a held message is dropped after Claude's default (5 minutes)")
    bad = [f"{label} dialogExpiry {v!r}" for label, v in seen
           if isinstance(v, bool) or not isinstance(v, (int, float, str)) or (isinstance(v, (int, float)) and v <= 0)]
    if envv:
        try:
            if int(envv) <= 0:
                bad.append(f"CLAUDE_CODE_USER_DIALOG_TIMEOUT_MS={envv}")
        except ValueError:
            bad.append(f"CLAUDE_CODE_USER_DIALOG_TIMEOUT_MS={envv}")
    if bad:
        return check(name, WARN, "; ".join(parts) + "; " + ", ".join(bad) + " is not a positive value, so held "
                     "messages may be dropped at once", "set dialogExpiry to a positive value or remove it")
    return check(name, PASS, "; ".join(parts) + " (informational; held messages are dropped when it runs out)")


# --- Codex checks -----------------------------------------------------------

def _ledger_endpoints(root: Path):
    """Read-only read of the bridge ledger: (rows, error). A missing ledger is no rows, no error."""
    db = root / "ledger.sqlite3"
    if not db.exists():
        return [], None
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2)
        try:
            rows = [{"actor": a, "pid": p, "started": s} for a, p, s in
                    con.execute("SELECT actor, pid, started FROM endpoints")]
        finally:
            con.close()
        return rows, None
    except sqlite3.Error as exc:
        return [], f"bridge ledger {db} is unreadable: {exc}"


def _endpoint_alive(row) -> bool:
    from native_bridge import start_identity
    pid = row["pid"]
    if not isinstance(pid, int) or pid <= 1 or not row["started"]:
        return False
    try:
        return start_identity(pid) == row["started"]
    except (OSError, subprocess.SubprocessError):
        return False


def _codex_endpoint_check(threads: list[str], rows, err) -> dict:
    name = "codex_bridge_endpoints"
    if err:
        return check(name, FAIL, err + "; Codex endpoints cannot be checked", "inspect or move aside the bridge ledger")
    if not threads:
        return check(name, PASS, "no live cctrl Codex sessions to check")
    live = {r["actor"] for r in rows if _endpoint_alive(r)}
    missing = [t for t in threads if f"codex:{t}" not in live]
    if not missing:
        return check(name, PASS, f"all {len(threads)} live Codex session(s) have a bridge endpoint")
    return check(name, WARN, f"{len(missing)} of {len(threads)} live Codex session(s) have no bridge endpoint, so "
                 "Claude cannot find them: " + ", ".join(missing),
                 "run cctrl bridge enable inside that Codex session", missing=missing)


def _ps_codex_lines() -> list[str]:
    try:
        out = subprocess.run(["ps", "-axo", "command"], capture_output=True, text=True, timeout=10, check=False).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    # A bridge daemon's own argv names its actor; it must not count as its owner.
    return [ln for ln in out.splitlines() if "codex" in ln and "native_bridge.py" not in ln]


def codex_state_db(env) -> Path | None:
    """Newest state_*.sqlite under $CODEX_HOME (default ~/.codex), or None."""
    home = Path(env.get("CODEX_HOME") or Path.home() / ".codex")
    try:
        dbs = [p for p in home.glob("state_*.sqlite") if p.is_file()]
    except OSError:
        return None

    def rank(p: Path):
        tail = p.stem.split("_", 1)[1]
        return (int(tail) if tail.isdigit() else -1, p.name)
    return max(dbs, key=rank) if dbs else None


def thread_archive_states(db: Path | None, ids: list[str]) -> dict[str, bool | None] | None:
    """{thread id: archived?} from the Codex state db, opened read-only; a missing id maps to None.
    Returns None when the db is absent or unreadable (the caller degrades to INFO)."""
    if db is None:
        return None
    try:
        con = sqlite3.connect(db.resolve().as_uri() + "?mode=ro", uri=True, timeout=2)
        try:
            cols = {r[1] for r in con.execute("PRAGMA table_info(threads)")}
            if "id" not in cols:
                return None
            field = "archived" if "archived" in cols else "0"
            out: dict[str, bool | None] = {}
            for tid in ids:
                row = con.execute(f"SELECT {field} FROM threads WHERE id = ?", (tid,)).fetchone()
                out[tid] = None if row is None else row[0] not in (0, None, "")
            return out
        finally:
            con.close()
    except (sqlite3.Error, OSError):
        return None


def _orphan_check(threads: list[str], rows, err, env=None, db: Path | None | str = "auto") -> dict:
    """A daemon is an orphan only when its Codex thread is archived or gone from the Codex state db.
    A thread that is live there but invisible in tmux/ps (a Codex app thread, a hand-started codex)
    is "owner not visible to cctrl": information, never a warning and never a kill remedy."""
    name = "codex_bridge_orphans"
    if err:
        return check(name, WARN, err + "; orphan daemons cannot be checked", "inspect or move aside the bridge ledger")
    lines = _ps_codex_lines()
    unowned = []
    for r in rows:
        actor = str(r["actor"])
        if not actor.startswith("codex:") or not _endpoint_alive(r):
            continue
        thread = actor.split(":", 1)[1]
        if thread in threads or any(thread in ln for ln in lines):
            continue
        unowned.append({"actor": actor, "pid": r["pid"], "thread": thread})
    if not unowned:
        return check(name, PASS, "no bridge daemon is left without its Codex session")
    if db == "auto":
        db = codex_state_db(env if env is not None else dict(os.environ))
    states = thread_archive_states(db, [o["thread"] for o in unowned])
    orphans, unseen = [], []
    for o in unowned:
        item = {"actor": o["actor"], "pid": o["pid"]}
        if states is not None and (o["thread"] not in states or states[o["thread"]] is None or states[o["thread"]]):
            orphans.append(item)
        else:
            unseen.append(item)
    info = ""
    if unseen:
        why = ("the Codex state database could not be read, so liveness is unknown"
               if states is None else "their Codex threads are not archived")
        info = (f"{len(unseen)} bridge daemon(s) have an owner not visible to cctrl (a Codex app thread or a "
                f"hand-started codex; {why}): informational, no action")
    if not orphans:
        return check(name, PASS, info, unseen=unseen)
    text = ", ".join(f"pid {o['pid']} ({o['actor']})" for o in orphans)
    summary = (f"{len(orphans)} bridge daemon(s) belong to a Codex thread that is archived or missing from the "
               f"Codex state database: {text}")
    return check(name, WARN, summary,
                 "doctor never stops a daemon; check the thread is really gone first, then run "
                 "env -u CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID=<thread id> cctrl bridge stop (the id is the part after codex: in the actor; the env -u part lets it run from inside a Claude session too)",
                 orphans=orphans, unseen=unseen, info=info)


def _orphan_checks(threads, rows, err) -> list[dict]:
    """The orphan check, plus a separate passing INFO check for daemons whose owner is not visible,
    so the WARN line counts only the real orphans."""
    c = _orphan_check(threads, rows, err)
    if c["status"] == WARN and c.get("info"):
        return [c, check("codex_bridge_unseen_owner", PASS, c["info"], unseen=c.get("unseen", []))]
    return [c]


# --- entry ------------------------------------------------------------------

def run(env, project_dir: Path, threads: list[str], hosts: list[str], bridge_root: Path | None,
        config_inbound: str = "", config_override: bool = False, bad_override: str = "") -> list[dict]:
    version = ci.detect_claude_version(env)
    on_path = shutil.which("claude", path=env.get("PATH")) is not None
    user_path, user, pp, proj, lp, loc, managed = _settings_state(env, project_dir)
    own = ci.resolve(managed=managed.data if managed.source else None, user=_doc(user),
                     project=_doc(proj), local=_doc(loc))
    rows, err = _ledger_endpoints(bridge_root) if bridge_root else ([], None)
    return [
        _version_check(env, version, on_path),
        _own_check(own, hosts),
        _spawn_check(managed, user, proj, loc, config_inbound, config_override, hosts, bad_override),
        _managed_check(managed),
        _project_check(project_dir, proj, loc),
        _invalid_check(managed, user_path, user, proj, loc),
        _isolate_check(managed, user, proj, loc),
        _dialog_check(env, managed, user, proj, loc),
        _codex_endpoint_check(threads, rows, err),
        *_orphan_checks(threads, rows, err),
    ]


def _csv(v: str) -> list[str]:
    return [x for x in (v or "").split(",") if x]


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="peer_doctor_messaging", add_help=False)
    p.add_argument("--project-dir", default=None)
    p.add_argument("--codex-threads", default="")
    p.add_argument("--hosts", default="")
    p.add_argument("--bridge-root", default=None)
    p.add_argument("--config-inbound", default="")
    p.add_argument("--config-override", default="false")
    p.add_argument("--config-override-invalid", default="")
    a = p.parse_args(argv)
    checks = run(dict(os.environ), Path(a.project_dir or os.getcwd()), _csv(a.codex_threads), _csv(a.hosts),
                 Path(a.bridge_root) if a.bridge_root else None, a.config_inbound, a.config_override == "true",
                 a.config_override_invalid)
    print(json.dumps(checks))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
