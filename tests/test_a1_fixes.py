"""Regression tests for the plan 116 A1 review fixes (lib/locks.py, lib/mailbox.py)."""
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import locks  # noqa: E402
import mailbox  # noqa: E402


class JudgeStaleFstat(unittest.TestCase):
    def test_read_and_stat_describe_the_same_file(self):
        """S3: if the lock path is swapped for another file between the read
        and the stat, the stat must still describe the file that was read."""
        with tempfile.TemporaryDirectory() as d:
            lock = os.path.join(d, "x.lock")
            live = os.path.join(d, "live")
            with open(lock, "w") as f:
                f.write("%10d\n" % 99999999)
            with open(live, "w") as f:
                f.write("%10d\n" % os.getpid())
            old_ino = os.stat(lock).st_ino
            real_open = open

            def swapping_open(path, *a, **kw):
                fh = real_open(path, *a, **kw)
                if path == lock:
                    os.replace(live, lock)  # swap after the open
                return fh

            import builtins
            builtins.open = swapping_open
            try:
                pid, st = locks.read_pid(lock)
            finally:
                builtins.open = real_open
            self.assertEqual(pid, 99999999)
            self.assertEqual(st.st_ino, old_ino)
            self.assertNotEqual(os.stat(lock).st_ino, old_ino)


class QuarantineFailure(unittest.TestCase):
    def test_unwritable_quarantine_fails_the_read_with_65(self):
        """S2: bad lines that cannot be set aside must not be silently dropped."""
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "messages.jsonl")
            with open(path, "w") as f:
                f.write('{"id":"a"}\n{"id":"cut\n')
            os.mkdir(mailbox.quarantine_path(path))  # a directory: the append fails
            self.assertEqual(mailbox.cmd_read(path, False, False), 65)

    def test_repair_ignores_backup_and_archive(self):
        """S1: default repair never reads .bak; --from-backup skips archived ids."""
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "messages.jsonl")
            with open(path, "w") as f:
                f.write('{"id":"keep","status":"queued"}\n')
            with open(path + ".bak", "w") as f:
                f.write('{"id":"keep","status":"queued"}\n{"id":"gone","status":"queued"}\n{"id":"lost","status":"queued"}\n')
            with open(os.path.join(d, "messages-archive.jsonl"), "w") as f:
                f.write('{"id":"gone","status":"acked"}\n')
            self.assertEqual([o["id"] for o in mailbox.repair_plan(path)["merged"]], ["keep"])
            plan = mailbox.repair_plan(path, from_backup=True)
            self.assertEqual([o["id"] for o in plan["merged"]], ["keep", "lost"])
            self.assertEqual(plan["skipped_archived"], 1)


if __name__ == "__main__":
    unittest.main()
