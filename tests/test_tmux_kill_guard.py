"""hooks/tmux_kill_guard.py + hooks/pre-tool-use.py (docs/plans/107): a Bash
command that would run `tmux kill-server` without -S/-L on that same tmux
invocation is blocked (exit 2); everything else passes.

String tests only. Nothing here starts tmux: the parser is called with text,
and the entry point is run as `python3 hooks/pre-tool-use.py` with a JSON
payload on stdin (it reads the payload and never runs the command)."""
# tmux-lint: allow-file (the table of blocked and allowed command strings; none is ever run)
import importlib.util
import json
import subprocess
import sys
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


class EntryPointTests(unittest.TestCase):
    """hooks/pre-tool-use.py: the process `cctrl hooks run pre-tool-use` execs."""

    def run_hook(self, stdin_text):
        return subprocess.run(
            [sys.executable, str(HOOK)],
            input=stdin_text,
            capture_output=True,
            text=True,
            timeout=10,
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
        self.run_hook_for_command("tmux kill-server")
        self.assertFalse(list((ROOT / "hooks").glob("__pycache__/tmux_kill_guard*")))


if __name__ == "__main__":
    unittest.main()
