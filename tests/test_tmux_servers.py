"""lib/tmux_servers.py: the servers a python helper reads (mdec-1110)."""
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import tmux_servers  # noqa: E402


class TmuxServersTest(unittest.TestCase):
    def test_unset_is_plain_tmux(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(tmux_servers.argv_prefixes(), [["tmux"]])

    def test_primary_current_default_extras_deduplicated(self):
        env = {"_CCTRL_TMUX_PRIMARY": "/s/fleet", "TMUX": "/s/old,12,0",
               "_CCTRL_TMUX_EXTRA": "/s/x\n/s/fleet\n", "TMUX_TMPDIR": "/nonexistent-cctrl-dir"}
        with mock.patch.dict(os.environ, env, clear=True):
            got = tmux_servers.argv_prefixes()
        self.assertEqual(got[0], ["tmux", "-S", "/s/fleet"])
        self.assertEqual(got[1], ["tmux", "-S", "/s/old"])
        self.assertEqual(got[2], ["tmux", "-S", "/nonexistent-cctrl-dir/tmux-%d/default" % os.getuid()])
        self.assertEqual(got[3], ["tmux", "-S", "/s/x"])
        self.assertEqual(len(got), 4)


if __name__ == "__main__":
    unittest.main()
