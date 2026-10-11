"""Imported for its side effect by the python tests that start shells (they
source cctrl with tmux mocked as a shell function): a real tmux becomes
unreachable by name from this process and from every child that inherits its
environment.

Run by the harness, the tmux on PATH is already the private-socket shim
(tests/run-tests.sh, _private_tmux_install): nothing is changed. Run directly
(`python3 -m unittest ...`, an editor), PATH holds the real tmux and TMUX may
name a live server. Then TMUX/TMUX_PANE are dropped and a stub that refuses
every call is put first on PATH (exit 97, the shim's refusal code; it never
forwards to tmux). No tmux on PATH at all: only TMUX/TMUX_PANE are dropped.

Not covered: code that calls tmux by absolute path.
"""
import atexit
import fnmatch
import os
import shutil
import tempfile

_STUB = """#!/bin/sh
echo "cctrl python tests: tmux refused (run without the harness's private-socket shim): $*" >&2
exit 97
"""


def install():
    """Returns the stub directory, or None when no stub was needed."""
    found = shutil.which("tmux")
    if found and fnmatch.fnmatch(found, "*/cctrl-test-tmux.*/bin/tmux"):
        return None
    os.environ.pop("TMUX", None)
    os.environ.pop("TMUX_PANE", None)
    if not found:
        return None
    stub_dir = tempfile.mkdtemp(prefix="cctrl-no-tmux-")
    stub = os.path.join(stub_dir, "tmux")
    with open(stub, "w", encoding="utf-8") as stream:
        stream.write(_STUB)
    os.chmod(stub, 0o755)
    os.environ["PATH"] = stub_dir + os.pathsep + os.environ.get("PATH", "")
    atexit.register(shutil.rmtree, stub_dir, True)
    return stub_dir


STUB_DIR = install()
