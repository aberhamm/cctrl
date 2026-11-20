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

    def orphans(self, threads, ps_lines=(), db=None):
        rows, err = pdm._ledger_endpoints(self.root)
        with mock.patch.object(pdm, "_ps_codex_lines", return_value=list(ps_lines)):
            return pdm._orphan_check(threads, rows, err, db=db)

    def codex_db(self, threads):
        """A temp Codex state db: {thread id: archived} (never the real ~/.codex)."""
        path = self.root / "state_5.sqlite"
        con = sqlite3.connect(path)
        con.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, archived INTEGER NOT NULL DEFAULT 0)")
        for tid, archived in threads.items():
            con.execute("INSERT INTO threads VALUES (?,?)", (tid, archived))
        con.commit()
        con.close()
        return path

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
        c = self.orphans(["other"], ["codex resume zzz"], db=self.codex_db({"T1": 1}))
        self.assertEqual(c["status"], "warn")
        self.assertTrue(c["ok"])
        self.assertEqual([o["actor"] for o in c["orphans"]], ["codex:T1"])
        self.assertIn("never stops", c["remedy"])
        self.assertNotIn("kill", c["remedy"])
        self.assertIn("env -u CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID=<thread id> cctrl bridge stop", c["remedy"])

    def test_live_app_thread_is_not_flagged(self):
        make_ledger(self.root, [("codex:T1", self.proc.pid, self.started)])
        c = self.orphans([], db=self.codex_db({"T1": 0}))
        self.assertEqual(c["status"], "pass")
        self.assertNotIn("orphans", c)
        self.assertEqual([o["actor"] for o in c["unseen"]], ["codex:T1"])
        self.assertIn("owner not visible to cctrl", c["summary"])
        self.assertNotIn("remedy", c)

    def test_missing_thread_is_flagged_and_mixed_split(self):
        make_ledger(self.root, [("codex:T1", self.proc.pid, self.started), ("codex:T2", self.proc.pid, self.started)])
        c = self.orphans([], db=self.codex_db({"T1": 0}))
        self.assertEqual(c["status"], "warn")
        self.assertEqual([o["actor"] for o in c["orphans"]], ["codex:T2"])
        self.assertEqual([o["actor"] for o in c["unseen"]], ["codex:T1"])
        self.assertNotIn("owner not visible", c["summary"])
        self.assertTrue(c["summary"].startswith("1 bridge daemon(s)"))
        rows, err = pdm._ledger_endpoints(self.root)
        with mock.patch.object(pdm, "_orphan_check", return_value=c):
            split = pdm._orphan_checks([], rows, err)
        self.assertEqual([x["name"] for x in split], ["codex_bridge_orphans", "codex_bridge_unseen_owner"])
        self.assertEqual(split[1]["status"], "pass")
        self.assertIn("owner not visible to cctrl", split[1]["summary"])

    def test_missing_or_unreadable_db_degrades_to_info(self):
        make_ledger(self.root, [("codex:T1", self.proc.pid, self.started)])
        for db in (None, self.root / "nope.sqlite"):
            c = self.orphans([], db=db)
            self.assertEqual(c["status"], "pass")
            self.assertIn("owner not visible to cctrl", c["summary"])
        bad = self.root / "state_9.sqlite"
        bad.write_bytes(b"not sqlite" * 50)
        c = self.orphans([], db=bad)
        self.assertEqual(c["status"], "pass")
        self.assertIn("could not be read", c["summary"])

    def test_state_db_is_found_by_glob_and_opened_read_only(self):
        self.codex_db({"T1": 0})
        (self.root / "state_4.sqlite").write_bytes(b"old")
        self.assertEqual(pdm.codex_state_db({"CODEX_HOME": str(self.root)}).name, "state_5.sqlite")
        self.assertIsNone(pdm.codex_state_db({"CODEX_HOME": str(self.root / "empty")}))
        real = sqlite3.connect
        seen = []

        def spy(target, *a, **kw):
            con = real(target, *a, **kw)
            seen.append(con)
            return con
        db = self.root / "state_5.sqlite"
        before = db.read_bytes()
        with mock.patch.object(pdm.sqlite3, "connect", side_effect=spy):
            self.assertEqual(pdm.thread_archive_states(db, ["T1"]), {"T1": False})
        self.assertEqual(db.read_bytes(), before)
        # The same URI form refuses writes.
        ro = real(db.resolve().as_uri() + "?mode=ro", uri=True)
        with self.assertRaises(sqlite3.OperationalError):
            ro.execute("DELETE FROM threads")
        ro.close()
        with mock.patch.object(pdm.sqlite3, "connect", wraps=real) as m:
            pdm.thread_archive_states(db, ["T1"])
        self.assertIn("mode=ro", m.call_args.args[0])
        self.assertTrue(m.call_args.kwargs.get("uri"))

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


class Nits(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = {"HOME": self.tmp.name, "PATH": os.environ.get("PATH", ""),
                    "CCTRL_CLAUDE_MANAGED_PLIST_JSON": str(Path(self.tmp.name) / "none.json")}
        (Path(self.tmp.name) / ".claude").mkdir()
        self.proj = Path(self.tmp.name) / "proj"
        (self.proj / ".claude").mkdir(parents=True)

    def checks(self, user=None, project=None, local=None, hosts=(), managed=None, **kw):
        import json as _j
        if user is not None:
            (Path(self.tmp.name) / ".claude/settings.json").write_text(_j.dumps(user))
        if project is not None:
            (self.proj / ".claude/settings.json").write_text(_j.dumps(project))
        if local is not None:
            (self.proj / ".claude/settings.local.json").write_text(_j.dumps(local))
        env = dict(self.env)
        if managed is not None:
            m = Path(self.tmp.name) / "managed.json"
            m.write_text(_j.dumps(managed))
            env["CCTRL_CLAUDE_MANAGED_PLIST_JSON"] = str(m)
        with mock.patch.object(pdm.ci, "detect_claude_version", return_value=(2, 1, 329)):
            return {c["name"]: c for c in pdm.run(env, self.proj, [], list(hosts), None, **kw)}

    def test_invalid_value_is_not_described_as_deliberate(self):
        c = self.checks(user={"crossSessionInbound": "yes"})["claude_inbound_own_sessions"]
        self.assertEqual(c["status"], "warn")
        self.assertNotIn("set on purpose", c["summary"])
        self.assertIn("unrecognised", c["summary"])

    def test_spawned_remedy_names_the_holding_file(self):
        c = self.checks(user={"crossSessionInbound": "accept"}, project={"crossSessionInbound": "refuse"},
                        hosts=["mbp"])["claude_inbound_spawned"]
        self.assertIn("settings.json", c["remedy"])
        self.assertIn("project settings", c["remedy"])
        self.assertNotIn("another Mac", c["remedy"])
        c = self.checks(project={}, local={"crossSessionInbound": "hold"})["claude_inbound_spawned"]
        self.assertIn("settings.local.json", c["remedy"])

    def test_spawned_managed_hold_says_ask_administrator(self):
        c = self.checks(managed={"crossSessionInbound": "hold"})["claude_inbound_spawned"]
        self.assertIn("ask your administrator", c["remedy"])
        self.assertNotIn("cctrl peer setup", c["remedy"])

    def test_bad_override_keeps_the_holding_scope_remedy(self):
        cases = [({"managed": {"crossSessionInbound": "hold"}}, "ask your administrator"),
                 ({"project": {"crossSessionInbound": "refuse"}}, "project settings"),
                 ({"project": {}, "local": {"crossSessionInbound": "hold"}}, "settings.local.json")]
        for kw, expect in cases:
            c = self.checks(bad_override="'yes'", **kw)["claude_inbound_spawned"]
            self.assertEqual(c["status"], "warn", kw)
            self.assertIn("overrideUser", c["remedy"], kw)
            self.assertIn(expect, c["remedy"], kw)
        c = self.checks(bad_override="'yes'")["claude_inbound_spawned"]
        self.assertIn("overrideUser", c["remedy"])

    def test_spawned_remote_form_uses_spawned_scope(self):
        c = self.checks(hosts=["mbp"])["claude_inbound_spawned"]
        self.assertTrue(c["remedy"].endswith("on another Mac: cctrl --host mbp peer setup --scope spawned --yes"),
                        c["remedy"])
        o = self.checks(hosts=["mbp"])["claude_inbound_own_sessions"]
        self.assertTrue(o["remedy"].endswith("cctrl --host mbp peer setup --yes"))

    def test_managed_isolate_says_ask_administrator(self):
        c = self.checks(managed={"isolatePeerMachines": True})["claude_isolate_peer_machines"]
        self.assertEqual(c["status"], "warn")
        self.assertIn("ask your administrator", c["remedy"])
        self.assertNotIn("remove isolatePeerMachines", c["remedy"])


if __name__ == "__main__":
    unittest.main()
