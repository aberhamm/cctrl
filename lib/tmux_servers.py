"""Which tmux servers a cctrl python helper reads (mdec-1110).

cctrl resolves the primary server (env CCTRL_TMUX_SERVER, config tmuxServer)
and exports it as _CCTRL_TMUX_PRIMARY (a socket path) plus _CCTRL_TMUX_EXTRA
(newline-separated socket paths) for the helpers it runs. Unset means plain
`tmux`, exactly as before: one server, no -L/-S.
"""
import os


def _socket_dir():
    base = os.environ.get("TMUX_TMPDIR") or "/tmp"
    if base != "/":
        base = base.rstrip("/")
    try:
        base = os.path.realpath(base) if os.path.isdir(base) else base
    except OSError:
        pass
    return "%s/tmux-%d" % (base, os.getuid())


def primary():
    return os.environ.get("_CCTRL_TMUX_PRIMARY") or ""


def argv_prefixes():
    """A list of argv prefixes, one per server to read, primary first.

    Routing off: [["tmux"]]. Routing on: ["tmux", "-S", sock] for the primary,
    the $TMUX server, the default server and any extras, deduplicated.
    """
    first = primary()
    if not first:
        return [["tmux"]]
    socks = [first]
    current = (os.environ.get("TMUX") or "").split(",", 1)[0]
    if current:
        socks.append(current)
    socks.append(_socket_dir() + "/default")
    socks.extend(s for s in (os.environ.get("_CCTRL_TMUX_EXTRA") or "").split("\n") if s)
    out, seen = [], set()
    for sock in socks:
        if sock not in seen:
            seen.add(sock)
            out.append(["tmux", "-S", sock])
    return out
