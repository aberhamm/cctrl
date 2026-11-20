import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import peer_doctor_messaging as pdm  # noqa: E402
from native_bridge import start_identity  # noqa: E402


def make_ledger(root: Path, rows):
    con = sqlite3.connect(root / "ledger.sqlite3")
    con.execute("CREATE TABLE endpoints (actor TEXT PRIMARY KEY, pid INTEGER, started TEXT, socket TEXT, "
                "native_socket TEXT, name TEXT, cwd TEXT)")
    for actor, pid, started in rows:
        con.execute("INSERT INTO endpoints VALUES (?,?,?,?,?,?,?)", (actor, pid, started, "", "", "", ""))
    con.commit()
    con.close()


class CodexChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.proc = subprocess.Popen(["sleep", "60"])
        self.addCleanup(self.proc.wait)
        self.addCleanup(self.proc.kill)
        self.addCleanup(self.tmp.cleanup)
        self.started = start_identity(self.proc.pid)

    def endpoints(self, threads):
        rows, err = pdm._ledger_endpoints(self.root)
        return pdm._codex_endpoint_check(threads, rows, err)

    def orphans(self, threads, ps_lines=()):
        rows, err = pdm._ledger_endpoints(self.root)
        with mock.patch.object(pdm, "_ps_codex_lines", return_value=list(ps_lines)):
            return pdm._orphan_check(threads, rows, err)

    def test_endpoints_pass_without_codex_sessions(self):
        c = self.endpoints([])
        self.assertEqual(c["status"], "pass")

    def test_endpoints_pass_when_live(self):
        make_ledger(self.root, [("codex:T1", self.proc.pid, self.started)])
        self.assertEqual(self.endpoints(["T1"])["status"], "pass")

    def test_endpoints_warn_when_missing_or_dead(self):
        make_ledger(self.root, [("codex:T1", 999999, "Thu Jan  1 00:00:00 1970")])
        c = self.endpoints(["T1", "T2"])
        self.assertEqual(c["status"], "warn")
        self.assertTrue(c["ok"])
        self.assertEqual(c["missing"], ["T1", "T2"])
        self.assertIn("cctrl bridge enable", c["remedy"])

    def test_endpoints_fail_on_unreadable_ledger(self):
        (self.root / "ledger.sqlite3").write_bytes(b"this is not sqlite" * 50)
        c = self.endpoints(["T1"])
        self.assertEqual(c["status"], "fail")
        self.assertFalse(c["ok"])

    def test_orphan_pass_when_no_daemons_or_owned(self):
        self.assertEqual(self.orphans([])["status"], "pass")
        make_ledger(self.root, [("codex:T1", self.proc.pid, self.started)])
        self.assertEqual(self.orphans(["T1"])["status"], "pass")
        self.assertEqual(self.orphans([], ["codex resume T1"])["status"], "pass")

    def test_orphan_warn_when_owner_gone(self):
        make_ledger(self.root, [("codex:T1", self.proc.pid, self.started),
                                ("claude:C1", self.proc.pid, self.started),
                                ("codex:T2", 999999, "gone")])
        c = self.orphans(["other"], ["codex resume zzz"])
        self.assertEqual(c["status"], "warn")
        self.assertTrue(c["ok"])
        self.assertEqual([o["actor"] for o in c["orphans"]], ["codex:T1"])
        self.assertIn("never stops", c["remedy"])

    def test_orphan_detection_is_read_only(self):
        make_ledger(self.root, [("codex:T1", self.proc.pid, self.started)])
        db = self.root / "ledger.sqlite3"
        before = (db.read_bytes(), db.stat().st_mtime_ns, sorted(os.listdir(self.root)))
        self.orphans([])
        self.assertEqual(before, (db.read_bytes(), db.stat().st_mtime_ns, sorted(os.listdir(self.root))))
        self.assertIsNone(self.proc.poll(), "doctor must never stop a daemon")

    def test_ps_lines_exclude_bridge_daemons(self):
        fake = "codex resume T9\npython native_bridge.py _serve codex:T1\nvim x\n"
        with mock.patch("subprocess.run", return_value=mock.Mock(stdout=fake)):
            self.assertEqual(pdm._ps_codex_lines(), ["codex resume T9"])


if __name__ == "__main__":
    unittest.main()
