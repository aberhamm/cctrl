#!/usr/bin/env python3
"""The one path resolver for cctrl, Python form (plan 116, phase A0).

lib/paths.sh is the shell twin and documents the rules. Both must give the
same answer for every key; test_paths_resolver_matrix runs both on each row
of the path matrix and compares their key=value output. Change one, change
both. Standard library only.

Library use:
    import paths
    p = paths.resolve(root)          # dict, keys in paths.KEYS order
    ok, reason = paths.test_mode(p)  # the test-mode gate
    paths.fix_modes([dirs], dry_run=True)

Command line (for the shell side, tests and `cctrl state fix-modes`):
    paths.py kv [--root DIR]
    paths.py get KEY [--root DIR]
    paths.py test-mode [--root DIR]      exit 0 test mode, 1 not, 64 refused
    paths.py fix-modes [--root DIR] [--dry-run]
"""

import os
import pwd
import re
import stat
import sys

KEYS = (
    "mode", "root", "state_root", "store_data_dir", "data_dir", "data_layout",
    "costs_dir", "costs_layout", "audit_dir", "sessions_dir", "snapshots_dir",
    "host_id_file", "shortcuts_file", "hosts_file", "config_default",
    "config_legacy", "config_user", "config_local", "spending_log",
    "rate_limits_file", "rate_limits_history", "needs_me_snapshot",
    "ports_file", "migrating_file", "migrating",
)

# Same pattern as _cctrl_paths_layout2 in lib/paths.sh.
_LAYOUT2 = re.compile(r'"layout"[ \t\r\n]*:[ \t\r\n]*2(?:[^0-9.eE]|\Z)')


def default_root():
    """The cctrl tree this file belongs to (realpath)."""
    return os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


def _layout2(path):
    try:
        if not os.path.isfile(path):
            return False
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return False
    # The shell reads up to the first NUL byte; do the same.
    raw = raw.split(b"\0", 1)[0]
    return bool(_LAYOUT2.search(raw.decode("latin-1")))


def resolve(root=None, environ=None):
    """Resolve every cctrl path for the tree at root. Returns a dict whose
    keys are KEYS, all values strings. Removes CCTRL_RUNTIME_MODE from
    environ (the mode is never taken from the environment)."""
    env = os.environ if environ is None else environ
    env.pop("CCTRL_RUNTIME_MODE", None)
    root = default_root() if root is None else root
    home = env.get("HOME", "")

    def _get(name):
        return env.get(name, "")

    p = {"root": root}
    p["mode"] = "installed" if os.path.isfile(os.path.join(root, ".installed")) else "checkout"

    xdg_state = _get("XDG_STATE_HOME")
    state_home = xdg_state if xdg_state.startswith("/") else home + "/.local/state"
    state_dir = _get("CCTRL_STATE_DIR")
    p["state_root"] = state_dir if state_dir.startswith("/") else state_home + "/cctrl"

    installed = p["mode"] == "installed"
    if installed and _layout2(p["state_root"] + "/data/LAYOUT"):
        p["data_layout"] = "2"
        p["store_data_dir"] = p["state_root"] + "/data"
    else:
        p["data_layout"] = "1"
        p["store_data_dir"] = root + "/data"
    store = p["store_data_dir"]
    p["data_dir"] = _get("CCTRL_DATA_DIR") or store

    if installed and _layout2(p["state_root"] + "/costs/LAYOUT"):
        p["costs_layout"] = "2"
        p["costs_dir"] = p["state_root"] + "/costs"
    else:
        p["costs_layout"] = "1"
        p["costs_dir"] = root + "/costs"
    p["costs_dir"] = _get("CCTRL_COSTS_DIR") or p["costs_dir"]

    data = p["data_dir"]
    p["audit_dir"] = p["state_root"] + "/audit"
    p["sessions_dir"] = _get("CCTRL_SESSION_METADATA_DIR") or data + "/sessions"
    p["snapshots_dir"] = data + "/snapshots"
    p["host_id_file"] = _get("CCTRL_HOST_ID_FILE") or data + "/host-id"
    p["needs_me_snapshot"] = _get("CCTRL_NEEDS_ME_SNAPSHOT") or data + "/needs-me-snapshot.json"

    p["shortcuts_file"] = _get("CCTRL_SHORTCUTS_FILE") or store + "/shortcuts.json"
    p["hosts_file"] = _get("CCTRL_HOSTS_FILE") or store + "/hosts.json"
    p["rate_limits_file"] = store + "/rate-limits.json"
    p["rate_limits_history"] = store + "/rate-limits-history.jsonl"
    p["ports_file"] = store + "/ports-seen.json"
    p["spending_log"] = p["costs_dir"] + "/spending.jsonl"

    p["config_default"] = root + "/share/config.default.json"
    p["config_legacy"] = store + "/config.json"
    p["config_local"] = _get("CCTRL_CONFIG_LOCAL") or store + "/config.local.json"
    user = _get("CCTRL_USER_CONFIG")
    if not user and home:
        xdg_cfg = _get("XDG_CONFIG_HOME")
        cfg_home = xdg_cfg + "/cctrl" if xdg_cfg.startswith("/") else home + "/.config/cctrl"
        user = cfg_home + "/config.json"
    p["config_user"] = user

    p["migrating_file"] = p["state_root"] + "/.migrating"
    mf = p["migrating_file"]
    p["migrating"] = "1" if (os.path.lexists(mf)) else "0"
    return {k: p[k] for k in KEYS}


def config_layers(p):
    """Config files, lowest precedence first (default < legacy < user < local)."""
    return [f for f in (p["config_default"], p["config_legacy"],
                        p["config_user"], p["config_local"]) if f]


# ── Test-mode gate (see lib/paths.sh for the rules) ────────────────────────

SANDBOX_MARKER = ".cctrl-test-sandbox"


def live_seal_key_path():
    """The live user's seal key path, from the password database (never HOME)."""
    return os.path.join(pwd.getpwuid(os.getuid()).pw_dir, ".local", "state",
                        "cctrl", "peer-seal.key")


def seal_key_path(environ=None):
    """The effective seal key path, as lib/peer_seal.py picks it."""
    env = os.environ if environ is None else environ
    return env.get("CCTRL_PEER_SEAL_KEY_FILE") or \
        env.get("HOME", "") + "/.local/state/cctrl/peer-seal.key"


def _inside(path, top):
    return path == top or path.startswith(top.rstrip("/") + "/")


def test_mode(p, environ=None):
    """(state, reason): state is True in test mode, False when not, and the
    string "refused" when test mode is asked for with the live seal key."""
    env = os.environ if environ is None else environ
    if env.get("CCTRL_TEST_MODE") != "1":
        return False, "CCTRL_TEST_MODE is not 1"
    key = seal_key_path(env)
    try:
        live = live_seal_key_path()
    except (KeyError, OSError):
        return "refused", "the seal key is the live key"
    if key == live or os.path.realpath(key) == os.path.realpath(live):
        return "refused", "the seal key is the live key"
    tmux_tmpdir = env.get("TMUX_TMPDIR", "")
    if not tmux_tmpdir:
        return False, "TMUX_TMPDIR is not set"
    sandbox = os.path.realpath(p["state_root"])
    while not os.path.isfile(os.path.join(sandbox, SANDBOX_MARKER)):
        if sandbox == "/":
            sandbox = ""
            break
        sandbox = os.path.dirname(sandbox)
    if not sandbox or sandbox == "/":
        return False, "no .cctrl-test-sandbox above the state root"
    for path in (p["state_root"], p["data_dir"], p["store_data_dir"], p["costs_dir"],
                 p["audit_dir"], p["config_user"], p["config_local"],
                 p["sessions_dir"], p["snapshots_dir"], p["host_id_file"],
                 tmux_tmpdir, key):
        if not path:
            return False, "a state path is empty"
        if not _inside(os.path.realpath(path), sandbox):
            return False, "outside the sandbox: " + path
    return True, "sandbox " + sandbox


# ── Private modes (plan 116 A0) ─────────────────────────────────────────────

def fix_modes(dirs, dry_run=False):
    """Remove group and other bits under each dir: directories end at 0700 or
    tighter, files keep their owner bits and lose the rest. Never follows a
    symlink below the top (the top itself may be the compat link). Returns a
    list of (path, old_mode, new_mode)."""
    changes = []

    def _fix(path, st):
        mode = stat.S_IMODE(st.st_mode)
        if stat.S_ISDIR(st.st_mode):
            new = (mode & 0o700) | 0o700
        else:
            new = mode & 0o700
        if new != mode:
            changes.append((path, mode, new))
            if not dry_run:
                os.chmod(path, new)

    for top in dirs:
        if not top or not os.path.isdir(top):
            continue
        real_top = os.path.realpath(top)
        if os.stat(real_top).st_uid != os.geteuid():
            continue
        _fix(real_top, os.stat(real_top))
        for dirpath, dirnames, filenames in os.walk(real_top, followlinks=False):
            for name in dirnames + filenames:
                path = os.path.join(dirpath, name)
                try:
                    st = os.lstat(path)
                except OSError:
                    continue
                if stat.S_ISLNK(st.st_mode) or st.st_uid != os.geteuid():
                    continue
                if stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode):
                    _fix(path, st)
    return changes


def _main(argv):
    args = list(argv)
    root = None
    dry_run = False
    if "--root" in args:
        i = args.index("--root")
        if i + 1 >= len(args):
            print("paths.py: --root needs a directory", file=sys.stderr)
            return 64
        root = args[i + 1]
        del args[i:i + 2]
    if "--dry-run" in args:
        dry_run = True
        args.remove("--dry-run")
    cmd = args[0] if args else "kv"
    p = resolve(root)
    if cmd == "kv" and len(args) <= 1:
        for k in KEYS:
            sys.stdout.write("%s=%s\n" % (k, p[k]))
        return 0
    if cmd == "get" and len(args) == 2 and args[1] in p:
        sys.stdout.write(p[args[1]] + "\n")
        return 0
    if cmd == "test-mode" and len(args) == 1:
        state, reason = test_mode(p)
        print(reason)
        if state == "refused":
            return 64
        return 0 if state is True else 1
    if cmd == "fix-modes" and len(args) == 1:
        for path, old, new in fix_modes([p["store_data_dir"], p["data_dir"],
                                         p["costs_dir"]], dry_run=dry_run):
            print("%s %04o -> %04o%s" % (path, old, new, " (dry run)" if dry_run else ""))
        return 0
    print("usage: paths.py kv|get KEY|test-mode|fix-modes [--root DIR] [--dry-run]",
          file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
