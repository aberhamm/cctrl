"""hooks/block-git-commit.py is advisory-only: it exits 1 (non-blocking
warning) on a matched git commit/revert/cherry-pick/am command, and its
stderr message must be honest about that -- it must NOT claim to have
"Blocked" anything, since Claude Code only treats exit 2 as an actual
block. See docs/plans/083."""
import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "hooks" / "block-git-commit.py"


class BlockGitCommitHookTests(unittest.TestCase):
    def run_hook(self, stdin_text):
        return subprocess.run(
            ["python3", str(HOOK)],
            input=stdin_text,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def run_hook_for_command(self, command):
        payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
        return self.run_hook(payload)

    def test_matched_command_exits_1_with_honest_non_blocked_wording(self):
        result = self.run_hook_for_command("git commit -m 'wip'")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Blocked", result.stderr)
        self.assertIn("advisory", result.stderr.lower())

    def test_non_matching_command_exits_0(self):
        result = self.run_hook_for_command("ls -la")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")

    def test_invalid_stdin_json_exits_0(self):
        result = self.run_hook("not valid json {{{")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
