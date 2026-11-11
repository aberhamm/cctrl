"""hooks/tmux_kill_guard.py + hooks/pre-tool-use.py (docs/plans/107): a Bash
command that would run `tmux kill-server` without -S/-L on that same tmux
invocation is blocked (exit 2); everything else passes.

String tests only. Nothing here starts tmux: the parser is called with text,
and the entry point is run as `python3 hooks/pre-tool-use.py` with a JSON
payload on stdin (it reads the payload and never runs the command)."""
# tmux-lint: allow-file (the table of blocked and allowed command strings; none is ever run)
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "hooks" / "pre-tool-use.py"

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("tmux_kill_guard", ROOT / "hooks" / "tmux_kill_guard.py")
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)

INCIDENT = "for l in new old; do TMUX_TMPDIR=$D/tt-$l tmux kill-server; done"

BLOCK = [
    # the incident command, and the plain form
    INCIDENT,
    "tmux kill-server",
    "tmux kill-server 2>/dev/null || true",
    # environment prefixes do not select a server
    "TMUX_TMPDIR=/tmp/x tmux kill-server",
    "TMUX= tmux kill-server",
    "TMUX= TMUX_PANE= tmux kill-server",
    "env -u TMUX tmux kill-server",
    "env -u TMUX -u TMUX_PANE TMUX_TMPDIR=$D tmux kill-server",
    "env -i tmux kill-server",
    "unset TMUX; tmux kill-server",
    # other ways to name the binary
    "/opt/homebrew/bin/tmux kill-server",
    "/usr/bin/tmux kill-server",
    "command tmux kill-server",
    "exec tmux kill-server",
    "\\tmux kill-server",
    "'tmux' kill-server",
    "\"tmux\" 'kill-server'",
    "tm''ux kill-server",
    "nohup tmux kill-server &",
    "sudo -n tmux kill-server",
    "timeout 5 tmux kill-server",
    "xargs tmux kill-server < /dev/null",
    "find . -maxdepth 0 -exec tmux kill-server \\;",
    "\"$(command -v tmux)\" kill-server",
    "\"$TMUX_BIN\" kill-server",
    "T=tmux; $T kill-server",
    "$(brew --prefix)/bin/tmux kill-server",
    # tmux's own options, command separators and prefixes
    "tmux -u -f /dev/null kill-server",
    "tmux -- kill-server",
    "tmux list-sessions \\; kill-server",
    "tmux ls ';' kill-server",
    "tmux ls\\; kill-server",
    "tmux kill-ser",
    "tmux kill-serv",
    "tmux kill\\-server",
    "tmux kill-ser\"ver\"",
    "tmux $'kill-server'",
    "tmux kill-\\\nserver",
    # chains
    "ls; tmux kill-server",
    "true && tmux kill-server",
    "false || tmux kill-server",
    "tmux ls | cat; tmux kill-server | cat",
    "cd /tmp\ntmux kill-server\n",
    "(tmux kill-server)",
    "{ tmux kill-server; }",
    "if true; then tmux kill-server; fi",
    "while false; do :; done; ! tmux kill-server",
    "cleanup() { tmux kill-server; }; cleanup",
    "echo done # ok\ntmux kill-server # cleanup",
    # a socket flag that belongs to a different tmux invocation, or to another program
    "tmux -S \"$D/sock\" ls; tmux kill-server",
    "tmux -L mine new-session -d && tmux kill-server",
    "tmux kill-server; tmux -S \"$D/sock\" ls",
    "ssh -L 8080:localhost:80 host tmux kill-server",
    "env -S 'tmux kill-server'",
    # a socket flag that still means the inherited or the default server
    "tmux -L default kill-server",
    "tmux -Ldefault kill-server",
    "tmux -S \"${TMUX%%,*}\" kill-server",
    "tmux -S $TMUX kill-server",
    "tmux -S \"$(tmux display -p '#{socket_path}')\" kill-server",
    "tmux -S /tmp/tmux-501/default kill-server",
    "tmux -S /private/tmp/tmux-501/default kill-server",
    "tmux -S '' kill-server",
    "tmux kill-server -S /tmp/x/sock",
    # a shell given the command as a string
    "sh -c 'tmux kill-server'",
    "bash -lc \"tmux kill-server\"",
    "bash -o pipefail -c 'cd /tmp && tmux kill-server'",
    "zsh -c 'TMUX_TMPDIR=/tmp/x tmux kill-server'",
    "sudo sh -c 'tmux kill-server'",
    "env X=1 bash -c 'tmux kill-server'",
    "bash -c \"bash -c 'tmux kill-server'\"",
    "eval 'tmux kill-server'",
    "eval tmux kill-server",
    "trap 'tmux kill-server' EXIT",
    "alias k='tmux kill-server'",
    "ssh localhost 'tmux kill-server'",
    "ssh -o BatchMode=yes host \"cd /x && tmux kill-server\"",
    "python3 -c \"import os; os.system('tmux kill-server')\"",
    "watch -n1 'tmux kill-server'",
    # a shell given the command on stdin
    "echo 'tmux kill-server' | sh",
    "echo tmux kill-server | bash",
    "printf '%s\\n' 'tmux kill-server' | bash -s",
    "bash <<'EOF'\ntmux kill-server\nEOF",
    "bash <<EOF\ncd /tmp\ntmux kill-server\nEOF\n",
    "cat <<'EOF' | sh\ntmux kill-server\nEOF",
    "bash <<< 'tmux kill-server'",
    "ssh host <<'EOF'\ntmux kill-server\nEOF",
    # command substitution runs even inside text
    "echo \"$(tmux kill-server)\"",
    "echo `tmux kill-server`",
    "x=$(tmux kill-server)",
    "git commit -m \"cleanup: `tmux kill-server`\"",
    "cat > note.md <<EOF\nstate: $(tmux kill-server)\nEOF",
    "cat > note.md <<EOF\nNever run `tmux kill-server`.\nEOF",
    "diff <(tmux kill-server) /dev/null",
    "echo ${X:-$(tmux kill-server)}",
    # a kill hidden in a string that tmux itself would run, on the inherited server
    "tmux run-shell 'tmux kill-server'",
    "tmux send-keys -t '=w:' 'tmux kill-server' Enter",
    "tmux new-session -d 'sleep 1; tmux kill-server'",
    "tmux if-shell true { kill-server }",
    # a variable in the tmux command position, on a line that mentions the kill
    "for c in kill-server; do tmux $c; done",
    "K=kill-server; tmux \"$K\"",
    # the kill on the stdin of a bare tmux
    "echo kill-server | tmux -C attach",
    "echo kill-server | xargs tmux",
    # found by the independent review (2026-10-11)
    "echo \"${MSG:-it's fine}\"; tmux kill-server",
    "echo \"${1:-can't find it}\" && TMUX_TMPDIR=$D tmux kill-server",
    "\"$SHELL\" -c 'tmux kill-server'",
    "\"$BASH\" -lc \"tmux kill-server\"",
    "${SHELL:-bash} -c 'tmux kill-server'",
    "bash -s -- \"$D\" <<'EOF'\ntmux kill-server\nEOF",
    "ssh studio bash -s -- arg <<'EOF'\ntmux kill-server\nEOF",
    "bash /dev/stdin <<'EOF'\ntmux kill-server\nEOF",
    "python3 - <<'EOF'\nimport subprocess\nsubprocess.run([\"tmux\", \"kill-server\"])\nEOF",
    "perl <<'EOF'\nsystem(\"tmux kill-server\");\nEOF",
    "node - <<'EOF'\nrequire('child_process').execSync('tmux kill-server')\nEOF",
    "cmd=\"tmux kill-server\"; $cmd",
    "CLEAN='tmux kill-server'; eval \"$CLEAN\"",
    "(( n = 1 << 4 ))\ntmux kill-server",
    "let n=1<<4\ntmux kill-server",
    "NOTE=$(cat <<'EOF'\n1) don't forget\nEOF\n)\ntmux kill-server",
    "tmux -S \"${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default\" kill-server",
    "for s in /tmp/tmux-$(id -u)/*; do tmux -S \"$s\" kill-server; done",
    "timeout 5 \"$TMUX_BIN\" kill-server",
    "sudo -u root \"$TMUX_BIN\" kill-server",
    "sudo -u git tmux kill-server",
    "nice -n 5 tmux kill-server",
    "flock /tmp/x.lock tmux kill-server",
    "case $x in a) tmux kill-server;; esac",
    "[[ -n \"$x\" ]] && tmux kill-server",
    "[[ -n \"$x\" && -n \"$y\" ]]; tmux kill-server",
    # found by the confirmation review (2026-10-11)
    "ssh studio 'bash -s' <<'EOF'\ntmux kill-server\nEOF",
    "ssh -T studio 'zsh -l' <<'EOF'\ntmux kill-server\nEOF",
    "ssh studio \"bash -s\" <<EOF\ntmux kill-server\nEOF",
    "cat <<'EOF' | ssh studio 'bash -s'\ntmux kill-server\nEOF",
    "ssh studio 'cd /tmp && bash -s' <<'EOF'\ntmux kill-server\nEOF",
    "ssh studio 'python3 -' <<'EOF'\nimport os\nos.system('tmux kill-server')\nEOF",
    "\"$BASH\" <<'EOF'\ntmux kill-server\nEOF",
    "echo 'tmux kill-server' | \"$SHELL\"",
    "\"$SHELL\" -s <<'EOF'\ntmux kill-server\nEOF",
    "sock=\"${TMUX%%,*}\"; tmux -S \"$sock\" kill-server",
    "S=$(echo $TMUX | cut -d, -f1); tmux -S \"$S\" kill-server",
    "S=$(tmux display-message -p '#{socket_path}'); tmux -S \"$S\" kill-server",
    "S=/tmp/tmux-501/default; tmux -S \"$S\" kill-server",
    "tmux -L \"$(basename \"${TMUX%%,*}\")\" kill-server",
    # uncertain: words after an unknown command (documented: blocks)
    "mywrapper tmux kill-server",
]

ALLOW = [
    # an explicit socket on the same invocation
    "tmux -S /tmp/x/sock kill-server",
    "tmux -S \"$D/sock\" kill-server",
    "tmux -S\"$D/sock\" kill-server",
    "tmux -S$D/sock kill-server",
    "tmux -L probe kill-server",
    "tmux -Lprobe kill-server",
    "tmux -L \"$name\" kill-server",
    "tmux -u -f /dev/null -S \"$D/sock\" kill-server",
    "tmux -uS \"$D/sock\" kill-server",
    "tmux -2uL probe kill-server",
    "TMUX_TMPDIR=$D tmux -L probe kill-server",
    "env -u TMUX -u TMUX_PANE tmux -S \"$D/sock\" kill-server",
    "/opt/homebrew/bin/tmux -S \"$D/sock\" kill-server",
    "command tmux -L probe kill-server",
    "\"$real_tmux\" -L \"$socket\" kill-server 2>/dev/null || true",
    "\"$CCTRL_TEST_TMUX_SHIM\" -S \"$_sock\" kill-server",
    "tmux -S \"$D/sock\" ls \\; kill-server",
    "tmux -S \"$TMUX_TMPDIR/tmux-501/default\" kill-server",
    "for l in new old; do tmux -S \"$D/tt-$l/sock\" kill-server; done",
    "tmux -S \"$D/a\" kill-server; tmux -S \"$D/b\" kill-server",
    "sh -c 'tmux -S /tmp/x/sock kill-server'",
    "ssh host 'tmux -L probe kill-server'",
    "bash <<'EOF'\ntmux -S \"$D/sock\" kill-server\nEOF",
    "tmux -S \"$D/sock\" new-session -d 'sleep 5; tmux kill-server'",
    # the words as text only
    "grep -rn 'tmux kill-server' docs/",
    "grep -rn \"kill-server\" . | head",
    "grep -c tmux kill-server.md",
    "rg 'tmux .*kill-server' --type sh",
    "echo 'never run tmux kill-server'",
    "echo \"never run tmux kill-server\"",
    "echo tmux kill-server is forbidden",
    "printf '%s\\n' 'tmux kill-server'",
    "git commit -m 'feat(hooks): block a bare tmux kill-server'",
    "git commit -m \"feat(hooks): block a bare tmux kill-server\"",
    "git commit -m \"docs: never run \\`tmux kill-server\\`\"",
    "git log --grep='tmux kill-server' --oneline",
    "gh pr create --title x --body 'blocks tmux kill-server without -S'",
    "cat > note.md <<'EOF'\nNever run `tmux kill-server`.\nCleanup was: $(tmux kill-server)\nEOF",
    "cat >> brief.md <<EOF\nRule: never run tmux kill-server on any socket.\nEOF",
    "cat <<'EOF'\ntmux kill-server\nEOF",
    "sed -n '/tmux kill-server/p' docs/findings/tmux-untargeted-default-server.md",
    "awk '/tmux kill-server/ {n++} END {print n}' notes.md",
    "ls # tmux kill-server",
    "# tmux kill-server\nls",
    "true # then: tmux kill-server",
    "cctrl session say '=w' 'do not run tmux kill-server'",
    "cctrl start -d . -m \"Rule: never run tmux kill-server. Use tmux -S.\"",
    "man tmux | grep -n kill-server",
    "[[ \"$cmd\" == *\"tmux kill-server\"* ]] && echo found",
    "x='tmux kill-server'; echo \"$x\"",
    "export NOTE=\"tmux kill-server is blocked\"",
    # found by the independent review (2026-10-11): everyday text-only forms
    "git commit -m \"$(cat <<'EOF'\nfeat(hooks): guard\n\n1) blocks a bare `tmux kill-server`\n2) it's fail-open :)\nEOF\n)\"",
    "msg=$(cat <<'EOF'\n1) never run tmux kill-server\nEOF\n)",
    "gh pr create --title guard --body \"$(cat <<'EOF'\nSummary :)\n- blocks `tmux kill-server`\nEOF\n)\"",
    "ssh studio \"grep -rn 'tmux kill-server' ~/dev/cctrl/docs\"",
    "ssh studio \"cd ~/dev/cctrl && git log --oneline --grep='tmux kill-server'\"",
    "find . -name '*.md' | xargs grep -n \"tmux kill-server\"",
    "find docs -name '*.md' -exec grep -l 'tmux kill-server' {} +",
    "grep -rl kill-server docs | xargs sed -i '' 's/tmux kill-server/the server kill/'",
    "gtimeout 20 rg -n \"tmux kill-server\" docs",
    "[[ -n \"$cmd\" && \"$cmd\" == *\"tmux kill-server\"* ]] && echo hit",
    "cat <<'EOF' | ssh studio 'cat > ~/brief.md'\nRule: never run tmux kill-server.\nEOF",
    "ssh studio 'cat >> ~/notes.md' <<'EOF'\nNever run tmux kill-server.\nEOF",
    "ssh -o BatchMode=yes -p 22 studio 'cat >> ~/notes.md' <<'EOF'\nNever run tmux kill-server.\nEOF",
    "python3 -c \"import subprocess; subprocess.run(['tmux','-S',sock,'kill-server'])\"",
    "echo '{\"tool_input\": {\"command\": \"tmux kill-server\"}}' | python3 hooks/pre-tool-use.py",
    "x=\"note: tmux kill-server\"; \"$EDITOR\" notes.md",
    "n=$(( 1 << 4 )); echo kill-server",
    # confirmation review: must stay allowed
    "ssh studio 'cat > ~/b.md; wc -l ~/b.md' <<'EOF'\nNever run tmux kill-server.\nEOF",
    "ssh studio 'bash -s' <<'EOF'\ntmux -S /tmp/x/sock kill-server\nEOF",
    "S=\"$D/sock\"; tmux -S \"$S\" kill-server",
    "S=$(mktemp -d)/sock; tmux -S \"$S\" new-session -d; tmux -S \"$S\" kill-server",
    "\"$PAGER\" <<'EOF'\nNever run tmux kill-server.\nEOF",
    # other programs, other tmux commands
    "adb kill-server",
    "\"$ANDROID_HOME/platform-tools/adb\" kill-server",
    "$ADB kill-server",
    "tmux kill-session -t '=mine'",
    "tmux kill-session -t kill-server-test",
    "tmux new-session -d -s kill-server-notes",
    "tmux ls",
    "tmux list-sessions; echo kill-server",
    "tmux display -p '#S #{session_created}'",
    "kill-server",
    "ls",
    "",
]


# Audit 2026-11 H3 (mdec-1111): $'...' / $"..." quoting spells the kill. These
# block with no config at all (the built-in servers).
BLOCK_ANSI = [
    "tmux kill-$'server'",
    "tmux kill-se$'r'ver",
    "tmux $'kill-\\x73erver'",
    "tmux $'kill-\\163erver'",
    "tmux $'\\x6bill-server'",
    "tmux $'kill-\\u0073erver'",
    "tmux kill-$\"server\"",
    "$'tmux' kill-$'server'",
    "$'\\x74mux' kill-server",
    "bash -c $'tmux kill-\\x73erver'",
    "tmux -L $'fleet' kill-server",
    "tmux -S $'/tmp/tmux-501/fleet' kill-server",
]

# Audit 2026-11 H3: a kill-server that names one of cctrl's servers. Checked
# with FLEET_ENV below: primary "fleet", extras "spare" and a path.
FLEET_ENV = {
    "HOME": "/Users/nobody",
    "CCTRL_TMUX_SERVER": "fleet",
    "CCTRL_TMUX_EXTRA_SERVERS": "spare, /Users/nobody/socks/side",
}
BLOCK_FLEET = [
    "tmux -L fleet kill-server",
    "tmux -Lfleet kill-server",
    "tmux -L 'fleet' kill-server",
    "tmux -L fl\"ee\"t kill-server",
    "tmux -uL fleet kill-server",
    "tmux -L fleet kill-ser",
    "tmux -L fleet kill-$'server'",
    "/opt/homebrew/bin/tmux -L fleet kill-server",
    "env -u TMUX tmux -L fleet kill-server",
    "TMUX_TMPDIR=/tmp/x tmux -L fleet kill-server",
    "tmux -S /private/tmp/tmux-501/fleet kill-server",
    "tmux -S /tmp/tmux-501/fleet kill-server",
    "tmux -S /tmp//tmux-501/fleet kill-server",
    "tmux -S /tmp/tmux-501/./fleet kill-server",
    "tmux -S /tmp/x/../tmux-501/fleet kill-server",
    "tmux -S //private/tmp/tmux-501/fleet kill-server",
    "tmux -S \"${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/fleet\" kill-server",
    "S=/tmp/tmux-501/fleet; tmux -S \"$S\" kill-server",
    "N=fleet; tmux -L \"$N\" kill-server",
    "tmux -L \"${N:-fleet}\" kill-server",
    "tmux -L fle\\et kill-server",
    "tmux -S \"${SOCK:-/tmp/tmux-501/fleet}\" kill-server",
    "tmux -L spare kill-server",
    "tmux -S /tmp/tmux-501/spare kill-server",
    "tmux -S /Users/nobody/socks/side kill-server",
    "tmux -S /Users/nobody/socks//side kill-server",
    "tmux -S \"$HOME/socks/side\" kill-server",
    "bash -c 'tmux -L fleet kill-server'",
    "ssh studio 'tmux -L fleet kill-server'",
    "sh -c \"tmux -S /private/tmp/tmux-501/fleet kill-server\"",
    "python3 -c \"import os; os.system('tmux -L fleet kill-server')\"",
    # the default server's socket, unnormalised (the audit's other -S finding)
    "tmux -S /tmp//tmux-501/default kill-server",
    "tmux -S /tmp/tmux-501/./default kill-server",
]
# Must stay allowed with the fleet config: other servers, other commands, text.
ALLOW_FLEET = [
    "tmux -L probe kill-server",
    "tmux -L fleetx kill-server",
    "tmux -L \"$name\" kill-server",
    "tmux -S /tmp/tmux-501/probe kill-server",
    "tmux -S /Users/nobody/socks/other kill-server",
    "tmux -L fleet ls",
    "tmux -L fleet list-sessions",
    "tmux -L fleet kill-session -t '=mine'",
    "tmux -S /private/tmp/tmux-501/fleet list-sessions",
    "echo 'tmux -L fleet kill-server'",
    "grep -rn 'tmux -L fleet kill-server' docs/",
    "git commit -m 'guard: block tmux -L fleet kill-server'",
    "echo $'never run tmux kill-server'",
    "printf $'%s\\n' done",
]


# mdec-1111 nit round (audit-opt1-2 verify NIT-1..4). Block with no config
# (the built-in servers) and with the fleet config.
UID = os.getuid()
BLOCK_NITS = [
    # NIT-1: APFS is case-insensitive, so names and paths compare casefolded
    "tmux -L FLEET kill-server",
    "tmux -L Fleet kill-server",
    "tmux -L Default kill-server",
    "tmux -LFLEET kill-server",
    "tmux -S /tmp/tmux-501/FLEET kill-server",
    "tmux -S /tmp/TMUX-501/Default kill-server",
    "tmux -S /PRIVATE/TMP/tmux-501/fleet kill-server",
    "N=FLEET; tmux -L \"$N\" kill-server",
    "tmux -L \"${N:-Fleet}\" kill-server",
    # NIT-2: a -L value with a / is a path under the socket dir
    "tmux -L ./fleet kill-server",
    "tmux -L ../tmux-%d/fleet kill-server" % UID,
    "tmux -L .//fleet/ kill-server",
    "tmux -L x/../default kill-server",
    "tmux -L ./FLEET kill-server",
    "tmux -L \"${N:-./fleet}\" kill-server",
    # NIT-3: \U in $'...' (bash 4.2+, zsh)
    "tmux kill-$'\\U00000073'erver",
    "tmux $'kill-\\U73'erver",
    "tmux -L $'\\U00000066leet' kill-server",
    # NIT-4: a relative -S whose last part names a protected server
    "cd /tmp/tmux-501 && tmux -S fleet kill-server",
    "tmux -S fleet kill-server",
    "tmux -S ./fleet kill-server",
    "tmux -S fleet/ kill-server",
    "tmux -S ../tmux-501/default kill-server",
    "tmux -S x/../FLEET kill-server",
    "tmux -S \"${S:-fleet}\" kill-server",
]
if UID != 501:
    BLOCK_NITS.append("tmux -L ../tmux-501/fleet kill-server")
# Fleet-config-only blocks (FLEET_ENV names "spare" and .../socks/side).
BLOCK_NITS_FLEET = [
    "tmux -L SPARE kill-server",
    "tmux -L ./spare kill-server",
    "tmux -S spare kill-server",
    "tmux -S ./side kill-server",
    "tmux -S /users/NOBODY/socks/SIDE kill-server",
]
# Must stay allowed with no config and with the fleet config.
ALLOW_NITS = [
    "tmux -S ./x/sock kill-server",
    "tmux -S sock kill-server",
    "tmux -S x/fleetx kill-server",
    "tmux -S fleet ls",
    "tmux -S ./fleet list-sessions",
    "tmux -L ./probe kill-server",
    "tmux -L ../other/fleet kill-server",
    "tmux -L PROBE kill-server",
    "tmux -L FLEET kill-session -t '=x'",
    "echo $'\\U0001F600 kill-server'",
    "printf $'\\U00000041\\n'",
]


def fleet_servers(**extra):
    env = dict(FLEET_ENV)
    env.update(extra)
    with tempfile.TemporaryDirectory() as tmp:
        return guard.resolve_servers(environ=env, script_dir=tmp)


class ParserTests(unittest.TestCase):
    def test_blocks(self):
        for command in BLOCK:
            with self.subTest(command=command):
                reason = guard.check_command(command)
                self.assertIsInstance(reason, str, "not blocked: %r" % command)
                self.assertTrue(reason)

    def test_allows(self):
        for command in ALLOW:
            with self.subTest(command=command):
                self.assertIsNone(guard.check_command(command), "blocked: %r" % command)

    def test_no_case_is_listed_twice_or_on_both_sides(self):
        self.assertEqual(len(BLOCK), len(set(BLOCK)))
        self.assertEqual(len(ALLOW), len(set(ALLOW)))
        self.assertFalse(set(BLOCK) & set(ALLOW))
        blocked = set(BLOCK) | set(BLOCK_ANSI) | set(BLOCK_FLEET)
        self.assertEqual(len(BLOCK_ANSI) + len(BLOCK_FLEET), len(set(BLOCK_ANSI) | set(BLOCK_FLEET)))
        self.assertFalse(blocked & (set(ALLOW) | set(ALLOW_FLEET)))

    def test_ansi_c_quoting_cannot_hide_the_kill(self):
        for command in BLOCK_ANSI:
            with self.subTest(command=command):
                self.assertTrue(guard.may_mention_kill(command), "pre-check misses %r" % command)
                self.assertIsInstance(guard.check_command(command), str, "not blocked: %r" % command)

    def test_named_fleet_and_extra_servers_are_blocked(self):
        servers = fleet_servers()
        for command in BLOCK_FLEET + BLOCK + BLOCK_ANSI:
            with self.subTest(command=command):
                self.assertIsInstance(guard.check_command(command, servers), str, "not blocked: %r" % command)

    def test_other_servers_stay_allowed_with_the_fleet_config(self):
        servers = fleet_servers()
        for command in ALLOW_FLEET + ALLOW:
            with self.subTest(command=command):
                self.assertIsNone(guard.check_command(command, servers), "blocked: %r" % command)

    def test_nit_round_case_label_path_unicode_and_relative_forms_block(self):
        lists = set(BLOCK_NITS) | set(BLOCK_NITS_FLEET)
        self.assertEqual(len(lists), len(BLOCK_NITS) + len(BLOCK_NITS_FLEET))
        self.assertFalse(lists & (set(ALLOW) | set(ALLOW_FLEET) | set(ALLOW_NITS)))
        servers = fleet_servers()
        for command in BLOCK_NITS:
            with self.subTest(command=command):
                self.assertTrue(guard.may_mention_kill(command))
                self.assertIsInstance(guard.check_command(command), str, "not blocked: %r" % command)
                self.assertIsInstance(guard.check_command(command, servers), str, "not blocked: %r" % command)
        for command in BLOCK_NITS_FLEET:
            with self.subTest(command=command):
                self.assertIsInstance(guard.check_command(command, servers), str, "not blocked: %r" % command)

    def test_nit_round_private_forms_stay_allowed(self):
        servers = fleet_servers()
        for command in ALLOW_NITS:
            with self.subTest(command=command):
                self.assertIsNone(guard.check_command(command), "blocked: %r" % command)
                self.assertIsNone(guard.check_command(command, servers), "blocked: %r" % command)

    def test_ansi_decode_unicode_escapes(self):
        self.assertEqual(guard._ansi_decode("\\U00000073"), "s")
        self.assertEqual(guard._ansi_decode("\\U73x"), "sx")
        self.assertEqual(guard._ansi_decode("\\u0073"), "s")
        self.assertEqual(guard._ansi_decode("\\UFFFFFFFF!"), "!")  # past U+10FFFF: dropped, no raise

    def test_loose_fallback_covers_the_nit_forms(self):
        servers = fleet_servers()
        for command in ("tmux -L FLEET kill-server", "tmux -L ./fleet kill-server",
                        "tmux -S fleet kill-server", "tmux kill-$'\\U00000073'erver"):
            with self.subTest(command=command):
                self.assertTrue(guard._loose(command, servers))
        self.assertFalse(guard._loose("tmux -S ./x/sock kill-server", servers))

    def test_fleet_is_protected_with_no_config(self):
        # "fleet" and "default" are built in: protected even when nothing
        # could be resolved.
        for command in ("tmux -L fleet kill-server", "tmux -S /private/tmp/tmux-501/fleet kill-server",
                        "tmux -S /tmp//tmux-501/default kill-server"):
            with self.subTest(command=command):
                self.assertIsInstance(guard.check_command(command), str)
        self.assertIsNone(guard.check_command("tmux -L spare kill-server"))

    def test_parser_error_fallback_knows_the_fleet_servers(self):
        original = guard._check_text
        guard._check_text = lambda *args: 1 // 0
        try:
            servers = fleet_servers()
            for command in ("tmux -L fleet kill-server", "tmux -S /private/tmp/tmux-501/fleet kill-server",
                            "tmux -L spare kill-server", "tmux kill-$'server'"):
                with self.subTest(command=command):
                    self.assertIsInstance(guard.check_command(command, servers), str)
            self.assertIsNone(guard.check_command("tmux -L probe kill-server", servers))
            self.assertIsNone(guard.check_command("tmux -S /tmp/x/sock kill-server", servers))
        finally:
            guard._check_text = original

    def test_non_string_input_is_allowed(self):
        for value in (None, 7, ["tmux", "kill-server"], {"command": "tmux kill-server"}):
            with self.subTest(value=value):
                self.assertIsNone(guard.check_command(value))

    def test_parser_error_falls_back_to_the_regex_check(self):
        # Fail open on an error, except when the fallback itself matches.
        original = guard._check_text
        guard._check_text = lambda *args: 1 // 0
        try:
            self.assertIsInstance(guard.check_command("tmux kill-server"), str)
            self.assertIsNone(guard.check_command("tmux -S /tmp/x/sock kill-server"))
            self.assertIsNone(guard.check_command("adb kill-server"))
        finally:
            guard._check_text = original

    def test_deep_nesting_and_long_input_do_not_raise(self):
        nested = "tmux kill-server"
        for _ in range(12):
            nested = "bash -c " + json.dumps(nested)
        self.assertIsInstance(guard.check_command(nested), str)
        self.assertIsInstance(guard.check_command("tmux kill-server #" + "x" * (guard.MAX_LEN + 1)), str)
        self.assertIsNone(guard.check_command("echo kill-server " + "(" * 5000))

    def test_block_message_names_the_safe_form_and_the_reason(self):
        message = guard.block_message(guard.check_command(INCIDENT))
        self.assertIn("BLOCKED", message)
        self.assertIn("no -S/-L on this tmux invocation", message)
        self.assertIn("tmux -S \"<your socket>\" kill-server", message)
        self.assertIn("kill-session -t '=NAME'", message)
        self.assertIn("killed a", message)
        self.assertIn("$TMUX", message)
        self.assertIn("-L fleet", message)


class ResolveServersTests(unittest.TestCase):
    """resolve_servers() reads the servers the way cctrl's _tmux_srv_init does."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.script_dir = Path(self.tmp) / "release"
        (self.script_dir / "data").mkdir(parents=True)
        self.user = Path(self.tmp) / "user-config.json"
        self.local = Path(self.tmp) / "local-config.json"
        self.env = {"HOME": self.tmp, "CCTRL_USER_CONFIG": str(self.user), "CCTRL_CONFIG_LOCAL": str(self.local)}

    def resolve(self, **extra):
        env = dict(self.env)
        env.update(extra)
        return guard.resolve_servers(environ=env, script_dir=str(self.script_dir))

    def blocked(self, command, servers):
        return isinstance(guard.check_command(command, servers), str)

    def test_config_key_names_the_primary(self):
        self.user.write_text(json.dumps({"tmuxServer": "main"}))
        servers = self.resolve()
        self.assertTrue(servers.known)
        self.assertTrue(self.blocked("tmux -L main kill-server", servers))
        self.assertTrue(self.blocked("tmux -S /private/tmp/tmux-501/main kill-server", servers))
        self.assertFalse(self.blocked("tmux -L probe kill-server", servers))

    def test_env_wins_over_config_and_config_precedence(self):
        self.user.write_text(json.dumps({"tmuxServer": "fromuser"}))
        (self.script_dir / "data" / "config.json").write_text(json.dumps({"tmuxServer": "fromrepo"}))
        self.local.write_text(json.dumps({"tmuxServer": "fromlocal"}))
        servers = self.resolve()
        self.assertTrue(self.blocked("tmux -L fromlocal kill-server", servers))
        self.assertFalse(self.blocked("tmux -L fromuser kill-server", servers))
        servers = self.resolve(CCTRL_TMUX_SERVER="fromenv")
        self.assertTrue(self.blocked("tmux -L fromenv kill-server", servers))
        self.assertFalse(self.blocked("tmux -L fromlocal kill-server", servers))
        # A null value stops the search (explicitly unset), as in cctrl.
        self.local.write_text(json.dumps({"tmuxServer": None}))
        self.assertFalse(self.blocked("tmux -L fromuser kill-server", self.resolve()))
        # The repo config is the last resort.
        self.local.unlink()
        self.user.unlink()
        self.assertTrue(self.blocked("tmux -L fromrepo kill-server", self.resolve()))

    def test_extra_servers_list_names_and_paths(self):
        side = Path(self.tmp) / "socks" / "side"
        self.user.write_text(json.dumps({"tmuxServer": "main", "tmuxExtraServers": ["spare", str(side), "~/socks/home"]}))
        servers = self.resolve()
        for command in ("tmux -L spare kill-server", "tmux -S %s kill-server" % side,
                        "tmux -S %s/socks//side kill-server" % self.tmp, "tmux -S ~/socks/home kill-server",
                        "tmux -S %s/socks/home kill-server" % self.tmp):
            with self.subTest(command=command):
                self.assertTrue(self.blocked(command, servers))
        self.assertFalse(self.blocked("tmux -S %s/socks/other kill-server" % self.tmp, servers))
        servers = self.resolve(CCTRL_TMUX_EXTRA_SERVERS="envextra")
        self.assertTrue(self.blocked("tmux -L envextra kill-server", servers))
        self.assertFalse(self.blocked("tmux -L spare kill-server", servers))

    def test_exported_primary_and_the_tmux_socket_are_protected(self):
        sock = Path(self.tmp) / "srv" / "primary.sock"
        sock.parent.mkdir()
        servers = self.resolve(_CCTRL_TMUX_PRIMARY=str(sock), _CCTRL_TMUX_EXTRA="%s/srv/x\n" % self.tmp,
                               TMUX="/private/tmp/tmux-501/mine,123,0")
        self.assertTrue(self.blocked("tmux -S %s kill-server" % sock, servers))
        self.assertTrue(self.blocked("tmux -S %s/srv/./x kill-server" % self.tmp, servers))
        self.assertTrue(self.blocked("tmux -S /tmp/tmux-501/mine kill-server", servers))
        self.assertTrue(self.blocked("tmux -L mine kill-server", servers))
        self.assertFalse(self.blocked("tmux -S %s/srv/y kill-server" % self.tmp, servers))

    def test_physical_path_dedupe(self):
        # A configured path through a symlinked directory is the same socket
        # as its physical path (cctrl _tmux_physical_sock).
        real = Path(self.tmp) / "real"
        real.mkdir()
        link = Path(self.tmp) / "link"
        link.symlink_to(real)
        self.user.write_text(json.dumps({"tmuxServer": str(link / "srv")}))
        servers = self.resolve()
        self.assertTrue(self.blocked("tmux -S %s kill-server" % (real / "srv"), servers))
        self.assertTrue(self.blocked("tmux -S %s kill-server" % (link / "srv"), servers))

    def test_unreadable_config_fails_safe(self):
        self.user.write_text('{"tmuxServer": ')
        servers = self.resolve()
        self.assertFalse(servers.known)
        for command in ("tmux -L probe kill-server", "tmux -L \"$name\" kill-server",
                        "tmux -S /tmp/tmux-501/probe kill-server", "tmux -S /private/tmp/tmux-501/x kill-server",
                        "tmux -L fleet kill-server", "tmux kill-server"):
            with self.subTest(command=command):
                self.assertTrue(self.blocked(command, servers))
        # private sockets outside a tmux socket dir stay allowed (the suite's)
        for command in ("tmux -S \"$D/sock\" kill-server", "tmux -S /tmp/x/sock kill-server",
                        "S=$(mktemp -d)/sock; tmux -S \"$S\" new-session -d; tmux -S \"$S\" kill-server",
                        "tmux -L probe ls", "tmux -S ./x/sock kill-server"):
            with self.subTest(command=command):
                self.assertFalse(self.blocked(command, servers))
        # a relative -S: the cwd is unknown, like -L (nit round NIT-4)
        for command in ("tmux -S sock kill-server", "tmux -S ../tmux-501/probe kill-server",
                        "tmux -L ./probe kill-server", "tmux -L PROBE kill-server"):
            with self.subTest(command=command):
                self.assertTrue(self.blocked(command, servers))

    def test_resolve_never_raises(self):
        servers = guard.resolve_servers(environ={"HOME": 7}, script_dir=self.tmp)
        self.assertFalse(servers.known)
        self.assertTrue(self.blocked("tmux -L probe kill-server", servers))


# The entry point resolves servers from its environment and config: run it
# with no inherited cctrl tmux settings and no user config.
_SCRUB = ("CCTRL_TMUX_SERVER", "CCTRL_TMUX_EXTRA_SERVERS", "_CCTRL_TMUX_PRIMARY", "_CCTRL_TMUX_EXTRA",
          "TMUX", "TMUX_PANE", "TMUX_TMPDIR", "XDG_CONFIG_HOME")


def hook_env(tmp, **extra):
    env = {k: v for k, v in os.environ.items() if k not in _SCRUB}
    env["CCTRL_USER_CONFIG"] = str(Path(tmp) / "no-user-config.json")
    env["CCTRL_CONFIG_LOCAL"] = str(Path(tmp) / "no-local-config.json")
    env.update(extra)
    return env


class EntryPointTests(unittest.TestCase):
    """hooks/pre-tool-use.py: the process `cctrl hooks run pre-tool-use` execs."""

    def run_hook(self, stdin_text):
        with tempfile.TemporaryDirectory() as tmp:
            return subprocess.run(
                [sys.executable, str(HOOK)],
                input=stdin_text,
                capture_output=True,
                text=True,
                timeout=10,
                env=hook_env(tmp),
            )

    def run_hook_for_command(self, command):
        return self.run_hook(json.dumps({"tool_name": "Bash", "tool_input": {"command": command}}))

    def test_incident_command_is_denied_with_exit_2(self):
        result = self.run_hook_for_command(INCIDENT)
        self.assertEqual(result.returncode, 2)
        self.assertIn("BLOCKED", result.stderr)
        self.assertIn("tmux -S \"<your socket>\" kill-server", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_explicit_socket_is_allowed(self):
        result = self.run_hook_for_command("tmux -S \"$D/sock\" kill-server")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")

    def test_argv_list_command_is_checked(self):
        payload = {"tool_name": "Bash", "tool_input": {"command": ["bash", "-lc", "tmux kill-server"]}}
        self.assertEqual(self.run_hook(json.dumps(payload)).returncode, 2)
        payload["tool_input"]["command"] = ["bash", "-lc", "tmux -L probe kill-server"]
        self.assertEqual(self.run_hook(json.dumps(payload)).returncode, 0)

    def test_git_commit_warning_still_exits_1_and_does_not_block(self):
        result = self.run_hook_for_command("git commit -m 'wip'")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Blocked", result.stderr)
        self.assertIn("advisory", result.stderr.lower())

    def test_commit_message_that_mentions_the_kill_is_not_blocked(self):
        result = self.run_hook_for_command("git commit -m 'block a bare tmux kill-server'")
        self.assertEqual(result.returncode, 1)  # the advisory warning only
        self.assertNotIn("BLOCKED", result.stderr)

    def test_plain_command_exits_0(self):
        result = self.run_hook_for_command("ls -la")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")

    def test_malformed_input_fails_open(self):
        for stdin_text in ("", "not valid json {{{", "[]", "null", "{\"tool_input\": 3}",
                           "{\"tool_input\": {\"command\": 3}}", "{\"tool_input\": {}}"):
            with self.subTest(stdin_text=stdin_text):
                result = self.run_hook(stdin_text)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stderr, "")

    def test_no_bytecode_is_written_next_to_the_hook(self):
        # Run a copy: test_syntax's py_compile of hooks/*.py writes hooks/__pycache__ earlier in a full run.
        with tempfile.TemporaryDirectory() as tmp:
            for source in (ROOT / "hooks").glob("*.py"):
                shutil.copy(source, tmp)
            payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": "tmux kill-server"}})
            result = subprocess.run(
                [sys.executable, str(Path(tmp) / "pre-tool-use.py")],
                input=payload,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 2)  # the guard really ran from the copy
            self.assertEqual(list(Path(tmp).rglob("__pycache__")), [])


class FleetEntryPointTests(unittest.TestCase):
    """Audit 2026-11 H3 end to end: a copy of the hooks in a release-shaped
    dir whose data/config.json names the fleet server, run as the hook runs."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        release = Path(self.tmp) / "release"
        (release / "hooks").mkdir(parents=True)
        (release / "data").mkdir()
        for source in (ROOT / "hooks").glob("*.py"):
            shutil.copy(source, release / "hooks")
        self.hook = release / "hooks" / "pre-tool-use.py"
        self.config = release / "data" / "config.json"
        self.config.write_text(json.dumps({"tmuxServer": "fleet", "tmuxExtraServers": ["spare"]}))

    def run_for(self, command, **env):
        return subprocess.run(
            [sys.executable, str(self.hook)],
            input=json.dumps({"tool_name": "Bash", "tool_input": {"command": command}}),
            capture_output=True,
            text=True,
            timeout=10,
            env=hook_env(self.tmp, **env),
        )

    def test_named_fleet_and_extra_servers_exit_2(self):
        for command in ("tmux -L fleet kill-server",
                        "tmux -S /private/tmp/tmux-501/fleet kill-server",
                        "tmux -S /tmp//tmux-501/fleet kill-server",
                        "tmux -L spare kill-server",
                        "tmux kill-$'server'",
                        "tmux $'kill-\\x73erver'",
                        "tmux -L fleet kill-$'serv'er",
                        "tmux -L FLEET kill-server",
                        "tmux -L ./fleet kill-server",
                        "tmux -S fleet kill-server",
                        "tmux kill-$'\\U00000073'erver"):
            with self.subTest(command=command):
                result = self.run_for(command)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("BLOCKED", result.stderr)

    def test_extra_server_from_env(self):
        self.assertEqual(self.run_for("tmux -L other kill-server").returncode, 0)
        self.assertEqual(self.run_for("tmux -L other kill-server", CCTRL_TMUX_EXTRA_SERVERS="other").returncode, 2)
        # what cctrl exports to the hook counts too
        self.assertEqual(self.run_for("tmux -S /tmp/elsewhere/sock kill-server",
                                      _CCTRL_TMUX_PRIMARY="/tmp/elsewhere/sock").returncode, 2)

    def test_private_sockets_and_other_commands_still_pass(self):
        for command in ("tmux -S \"$D/sock\" kill-server", "tmux -L probe kill-server",
                        "tmux -L fleet ls", "tmux -L fleet kill-session -t '=x'",
                        "echo $'hello'", "printf $'a\\tb\\n'"):
            with self.subTest(command=command):
                result = self.run_for(command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")

    def test_unreadable_config_blocks_ambiguous_names_only(self):
        self.config.write_text('{"tmuxServer": "fleet",')
        self.assertEqual(self.run_for("tmux -L probe kill-server").returncode, 2)
        self.assertEqual(self.run_for("tmux -S /private/tmp/tmux-501/x kill-server").returncode, 2)
        self.assertEqual(self.run_for("tmux -S \"$D/sock\" kill-server").returncode, 0)
        self.assertEqual(self.run_for("tmux -S /tmp/x/sock kill-server").returncode, 0)


if __name__ == "__main__":
    unittest.main()
