#!/usr/bin/env python3
"""Public-repo hygiene check: block private infrastructure detail.

cctrl is a public repository. This check fails when a scanned file holds:

  private-ip    an RFC 1918 address (10/8, 172.16/12, 192.168/16), a
                tailnet/CGNAT address (100.64/10), a loopback address other
                than 127.0.0.1, a link-local address (169.254/16), or an
                address in Tailscale's IPv6 ULA /48
  tailnet       a MagicDNS name (*.ts.net)
  home-path     an absolute home path naming a user: /Users/<name>,
                /home/<name>, or the encoded -Users-<name>- form Claude Code
                uses for project directories

Use neutral placeholders instead: ~/, $HOME, /Users/<user>, <private-ip>,
<host>, example.internal, or the RFC 5737 documentation ranges (192.0.2.0/24,
198.51.100.0/24, 203.0.113.0/24), which are never flagged.

Modes:
  check-public-hygiene.py                 scan every tracked file (git ls-files)
  check-public-hygiene.py --staged        scan the staged content of added,
                                          copied, modified and renamed files
                                          (pre-commit)
  check-public-hygiene.py FILE...         scan the named files

Justified exceptions live in tests/public-hygiene-allowlist.txt (override with
--allowlist). Each entry is `CATEGORY VALUE [PATH_GLOB]`; VALUE is the address,
the full *.ts.net name, or the user name of a home path.

Matches are printed masked so the check never republishes what it caught.
Exit status: 0 clean, 1 hits found, 2 usage or git error, 3 not a git work
tree (the tracked and --staged modes need a checkout; a release tree built by
`git archive` has no .git, so callers may treat 3 as "nothing to check here").
"""
import argparse
import fnmatch
import ipaddress
import os
import re
import subprocess
import sys

# A word character may precede the address (IP_10.x), a digit or dot may not.
IPV4_RE = re.compile(r"(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\w]|\.\d)")
# Tailscale's IPv6 ULA /48. Split so this file does not match itself.
TS_IPV6_RE = re.compile(r"(?i)(?<![0-9a-f:])(fd7a:115c" r":a1e0:[0-9a-f:]*)")
TAILNET_RE = re.compile(r"(?i)(?<![a-z0-9.-])((?:[a-z0-9-]+\.)+ts\.net)\b")
HOME_RES = (
    re.compile(r"/Users/([A-Za-z][A-Za-z0-9._-]*)(?![A-Za-z0-9._-])"),
    re.compile(r"(?<![A-Za-z0-9._-])/home/([A-Za-z_][A-Za-z0-9._-]*)(?![A-Za-z0-9._-])"),
    re.compile(r"(?<![A-Za-z0-9])-Users-([A-Za-z][A-Za-z0-9._]*)(?=-|$|[^A-Za-z0-9._])"),
)
# Not a person's home: macOS's shared folder.
HOME_NOT_A_USER = {"Shared"}

# (first octet, second octet, prefix length). Built at runtime so this file
# holds no dotted-quad private address for the check to trip on.
PRIVATE_V4 = [ipaddress.ip_network("%d.%d.0.0/%d" % n) for n in (
    (10, 0, 8),        # RFC 1918
    (172, 16, 12),     # RFC 1918
    (192, 168, 16),    # RFC 1918
    (100, 64, 10),     # RFC 6598 shared/CGNAT space, used by tailnets
    (127, 0, 8),       # loopback (127.0.0.1 is allowlisted for localhost examples)
    (169, 254, 16))]   # link-local

DEFAULT_ALLOWLIST = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 "public-hygiene-allowlist.txt")


def load_allowlist(path):
    entries = []
    if not path or not os.path.exists(path):
        return entries
    with open(path, encoding="utf-8") as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) not in (2, 3) or parts[0] not in ("private-ip", "tailnet", "home-path"):
                sys.stderr.write("%s:%d: bad allowlist entry (want CATEGORY VALUE [PATH_GLOB])\n" % (path, n))
                sys.exit(2)
            entries.append((parts[0], parts[1], parts[2] if len(parts) == 3 else "*"))
    return entries


def allowed(entries, category, value, path):
    for cat, val, glob in entries:
        if cat == category and val.lower() == value.lower() and fnmatch.fnmatch(path, glob):
            return True
    return False


def mask(category, value):
    if category == "private-ip":
        if ":" in value:
            return "fd7a:****"
        return value.split(".", 1)[0] + ".*.*.*"
    if category == "tailnet":
        return "****.ts.net"
    return value[:1] + "***"


def scan_text(path, text, entries):
    hits = []
    for lineno, line in enumerate(text.splitlines(), 1):
        found = []
        for m in IPV4_RE.finditer(line):
            try:
                addr = ipaddress.ip_address(m.group(1))
            except ValueError:
                continue
            if any(addr in net for net in PRIVATE_V4):
                found.append(("private-ip", m.group(1)))
        for m in TS_IPV6_RE.finditer(line):
            found.append(("private-ip", m.group(1)))
        for m in TAILNET_RE.finditer(line):
            found.append(("tailnet", m.group(1)))
        for rx in HOME_RES:
            for m in rx.finditer(line):
                if m.group(1) not in HOME_NOT_A_USER:
                    found.append(("home-path", m.group(1)))
        for category, value in found:
            if not allowed(entries, category, value, path):
                hits.append((path, lineno, category, value))
    return hits


NOT_A_WORK_TREE = 3


def git(args, root):
    return subprocess.run(["git"] + args, cwd=root, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=True).stdout


def decode(blob):
    if b"\0" in blob[:8192]:
        return None  # binary
    return blob.decode("utf-8", errors="replace")


def main(argv):
    ap = argparse.ArgumentParser(description="Block private infrastructure detail in the public repo.")
    ap.add_argument("--staged", action="store_true", help="scan the staged content (pre-commit)")
    ap.add_argument("--allowlist", default=DEFAULT_ALLOWLIST)
    ap.add_argument("--root", default=None, help="repository root (default: git toplevel of cwd)")
    ap.add_argument("files", nargs="*")
    args = ap.parse_args(argv)
    entries = load_allowlist(args.allowlist)

    sources = []  # (display path, bytes)
    if args.files:
        for f in args.files:
            try:
                with open(f, "rb") as fh:
                    sources.append((f, fh.read()))
            except OSError as exc:
                sys.stderr.write("check-public-hygiene: cannot read %s: %s\n" % (f, exc.strerror))
                return 2
    else:
        where = args.root or os.getcwd()
        try:
            inside = git(["rev-parse", "--is-inside-work-tree"], where).decode().strip()
        except subprocess.CalledProcessError:
            inside = ""
        except OSError as exc:
            sys.stderr.write("check-public-hygiene: git failed: %s\n" % exc)
            return 2
        if inside != "true":
            sys.stderr.write("check-public-hygiene: not a git work tree: %s (tracked and --staged "
                             "modes need a checkout; exit %d)\n" % (where, NOT_A_WORK_TREE))
            return NOT_A_WORK_TREE
        try:
            root = args.root or git(["rev-parse", "--show-toplevel"], None).decode().strip()
            if args.staged:
                names = git(["diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR"], root)
            else:
                names = git(["ls-files", "-z"], root)
        except (subprocess.CalledProcessError, OSError) as exc:
            sys.stderr.write("check-public-hygiene: git failed: %s\n" % exc)
            return 2
        for name in [n for n in names.decode("utf-8", "replace").split("\0") if n]:
            if args.staged:
                try:
                    blob = git(["show", ":" + name], root)
                except subprocess.CalledProcessError:
                    continue
            else:
                full = os.path.join(root, name)
                if not os.path.isfile(full) or os.path.islink(full):
                    continue
                with open(full, "rb") as fh:
                    blob = fh.read()
            sources.append((name, blob))

    hits = []
    for name, blob in sources:
        text = decode(blob)
        if text is not None:
            hits.extend(scan_text(name, text, entries))

    for path, lineno, category, value in hits:
        print("%s:%d: %s: %s" % (path, lineno, category, mask(category, value)))
    if hits:
        sys.stderr.write(
            "check-public-hygiene: %d hit(s) of private infrastructure detail. Replace them with\n"
            "placeholders (~/, $HOME, /Users/<user>, <private-ip>, <host>, example.internal,\n"
            "RFC 5737 addresses), or add a justified entry to tests/public-hygiene-allowlist.txt.\n"
            % len(hits))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
