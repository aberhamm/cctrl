#!/usr/bin/env python3
"""Boot-restore classification: per-row planning, process matching and the
duplicate-claim tie-break in lib/snapshot_restore.py. Synthetic fixtures only;
no tmux, no launch, no real ids."""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import no_real_tmux  # noqa: E402,F401  side effect: no real tmux is reachable when this file is run directly

LIB = ROOT / "lib" / "snapshot_restore.py"
HOST = "0123456789abcdef0123456789abcdef"
NOW = "2026-11-01T12:00:00Z"


def claim(task_id, tmux, recency="2026-11-01T10:00:00Z", cwd="/tmp/work", **extra):
    row = dict(
        provider="claude", provider_task_id=task_id, host_id=HOST, origin="cctrl", execution_runtime="tmux",
        control_owner="cctrl", lifecycle_state="active", restore_strategy="tmux", registered_by_cctrl=True,
        launched_by_cctrl=True, cwd=cwd, display_title=task_id, tmux_session=tmux, recency=recency,
        action_capabilities={"tmux_attach": {"supported": False}})
    row.update(extra)
    return row


def catalogue(rows):
    return {"schema_version": 2, "host_id": HOST, "rows": rows, "source_errors": [],
            "source_status": {"registry": "available", "tmux": "available", "codex_provider": "available"}}


def process_doc(commands=(), status="available"):
    return {"schema_version": 1, "status": status, "observed_at": NOW,
            "source_cursor": "c" if status == "available" else None,
            "processes": [{"pid": 100 + i, "ppid": 1, "started": "x", "command": c} for i, c in enumerate(commands)],
            "error": None if status == "available" else "boom"}


class Fixture:
    def __init__(self, test):
        self.test = test
        self.tmp = tempfile.TemporaryDirectory()
        test.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def write(self, name, value):
        path = self.root / name
        path.write_text(json.dumps(value))
        return str(path)

    def run(self, *args):
        env = {k: v for k, v in os.environ.items() if not k.startswith("CCTRL_")}
        return subprocess.run([sys.executable, str(LIB), *args], capture_output=True, text=True, env=env)

    def capture(self, rows, sessions=(), projects=(), margin=None):
        meta = self.root / "meta"
        meta.mkdir(exist_ok=True)
        args = ["capture", "--catalogue", self.write("cat.json", catalogue(rows)), "--sessions", self.write("sess.json", list(sessions)),
                "--process", self.write("proc.json", process_doc()), "--resources", self.write("res.json", {}),
                "--host-id", HOST, "--hostname", "fixture", "--generated-at", NOW, "--metadata-dir", str(meta)]
        for directory in projects:
            args += ["--claude-projects-dir", str(directory)]
        if margin is not None:
            args += ["--tie-margin", str(margin)]
        done = self.run(*args)
        self.test.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout)

    def plan(self, snapshot_tasks, cat_rows, process=None, strict=False):
        snapshot = {"schema_version": 2, "host_id": HOST, "hostname": "fixture", "tasks": snapshot_tasks}
        args = ["plan", "--snapshot", self.write("snap.json", snapshot), "--catalogue", self.write("cat.json", catalogue(cat_rows)),
                "--process", self.write("proc.json", process or process_doc()), "--host-id", HOST, "--hostname", "fixture"]
        if strict:
            args.append("--strict")
        done = self.run(*args)
        return done.returncode, json.loads(done.stdout) if done.stdout.strip() else None


def snap_task(task_id, tmux, **extra):
    row = dict(
        provider="claude", agent="claude", provider_task_id=task_id, host_id=HOST, origin="cctrl", execution_runtime="tmux",
        control_owner="cctrl", lifecycle_state="active", restore_strategy="tmux-resume", registered_by_cctrl=True,
        launched_by_cctrl=True, resume_identity_kind="claude-session-id", resume_identity=task_id, cwd="/tmp/work",
        tmux_session=tmux, live=False)
    row.update(extra)
    return row


class PlanTests(unittest.TestCase):
    def test_conflict_row_is_per_row_and_strict_keeps_old_codes(self):
        fx = Fixture(self)
        tasks = [snap_task("conv-a", "TMUX--a"), snap_task("conv-b", "TMUX--b", control_owner="conflict")]
        rows = [claim("conv-a", "TMUX--a"), claim("conv-b", "TMUX--b")]
        rc, doc = fx.plan(tasks, rows)
        self.assertEqual(rc, 0)  # plan never reports a per-row problem through its exit code
        by_id = {r["provider_task_id"]: r for r in doc["rows"]}
        self.assertEqual(by_id["conv-a"]["disposition"], "restore")
        self.assertEqual(by_id["conv-b"]["disposition"], "conflict")
        self.assertEqual(by_id["conv-b"]["attention"], "conflict")
        self.assertEqual(doc["global_errors"], [])
        rc, doc = fx.plan(tasks, rows, strict=True)
        self.assertEqual(rc, 75)
        self.assertEqual({r["provider_task_id"]: r["disposition"] for r in doc["rows"]}["conv-a"], "restore")

    def test_absent_identity_is_per_row_strict_is_69(self):
        fx = Fixture(self)
        tasks = [snap_task("conv-a", "TMUX--a"), snap_task("conv-gone", "TMUX--gone")]
        rows = [claim("conv-a", "TMUX--a")]
        rc, doc = fx.plan(tasks, rows)
        self.assertEqual(rc, 0)
        by_id = {r["provider_task_id"]: r for r in doc["rows"]}
        self.assertEqual(by_id["conv-gone"]["disposition"], "insufficient-evidence")
        self.assertEqual(by_id["conv-gone"]["attention"], "ambiguous")
        self.assertEqual(by_id["conv-a"]["disposition"], "restore")
        rc, _ = fx.plan(tasks, rows, strict=True)
        self.assertEqual(rc, 69)

    def test_process_table_unavailable_is_global_69(self):
        fx = Fixture(self)
        rc, doc = fx.plan([snap_task("conv-a", "TMUX--a")], [claim("conv-a", "TMUX--a")], process=process_doc(status="unavailable"))
        self.assertEqual(rc, 69)
        self.assertEqual(doc["global_errors"][0]["source"], "process")
        self.assertEqual(doc["rows"][0]["disposition"], "insufficient-evidence")

    def test_running_conversation_beats_a_conflicted_record(self):
        fx = Fixture(self)
        tasks = [snap_task("conv-fm", "TMUX--fm", control_owner="conflict", lifecycle_state="conflict")]
        rc, doc = fx.plan(tasks, [claim("conv-fm", "TMUX--fm")], process=process_doc(["claude --model m --resume conv-fm --chrome"]))
        self.assertEqual(rc, 0)
        row = doc["rows"][0]
        self.assertEqual(row["disposition"], "already-live")
        self.assertIn("conversation already running (pid 100)", row["reason"])
        self.assertNotIn("attention", row)

    def test_process_match_is_token_exact(self):
        fx = Fixture(self)
        tasks = [snap_task("conv-aaa-111", "TMUX--a")]
        decoys = ["grep conv-aaa-111", 'bash -c "cctrl start -r conv-aaa-111"', "claude --resume conv-aaa-1110",
                  "claude --name conv-aaa-111", "claude --resume", "python3 claude --resume conv-aaa-111",
                  "/usr/bin/vim /tmp/--resume conv-aaa-111"]
        rc, doc = fx.plan(tasks, [claim("conv-aaa-111", "TMUX--a")], process=process_doc(decoys))
        self.assertEqual(rc, 0)
        self.assertEqual(doc["rows"][0]["disposition"], "restore", doc["rows"][0])
        for good in ["claude --resume conv-aaa-111 --chrome", "/opt/bin/claude -r conv-aaa-111", "claude --session-id conv-aaa-111",
                     "claude --resume=conv-aaa-111", "codex resume conv-aaa-111", "cctrl start -r conv-aaa-111"]:
            rc, doc = fx.plan(tasks, [claim("conv-aaa-111", "TMUX--a")], process=process_doc([good]))
            self.assertEqual(doc["rows"][0]["disposition"], "already-live", good)

    def test_live_under_other_name_is_already_live(self):
        fx = Fixture(self)
        live = claim("conv-a", "TMUX--other", action_capabilities={"tmux_attach": {"supported": True}})
        rc, doc = fx.plan([snap_task("conv-a", "TMUX--a")], [live])
        self.assertEqual(doc["rows"][0]["disposition"], "already-live")
        self.assertIn("live under TMUX--other", doc["rows"][0]["reason"])

    def test_sibling_running_blocks_the_name(self):
        fx = Fixture(self)
        tasks = [snap_task("conv-x", "TMUX--dup", shadowed_task_ids=["conv-y"])]
        rows = [claim("conv-x", "TMUX--dup"), claim("conv-y", "TMUX--dup")]
        rc, doc = fx.plan(tasks, rows, process=process_doc(["claude --resume conv-y"]))
        self.assertEqual(doc["rows"][0]["disposition"], "already-live")
        self.assertIn("a sibling record is running", doc["rows"][0]["reason"])

    def test_ambiguous_claim_row_needs_attention(self):
        fx = Fixture(self)
        tasks = [snap_task("conv-a", "TMUX--a", control_owner="unknown", execution_runtime="unknown", lifecycle_state="unknown",
                           recovery_reason="ambiguous-tmux-claim: no record matches the live task")]
        rc, doc = fx.plan(tasks, [claim("conv-a", "TMUX--a")])
        self.assertEqual(doc["rows"][0]["disposition"], "unknown")
        self.assertEqual(doc["rows"][0]["attention"], "ambiguous")
        self.assertTrue(doc["rows"][0]["reason"].startswith("ambiguous-tmux-claim"))

    def test_host_mismatch_row_is_skipped_alone(self):
        fx = Fixture(self)
        tasks = [snap_task("conv-a", "TMUX--a"), snap_task("conv-b", "TMUX--b", host_id="f" * 32)]
        rc, doc = fx.plan(tasks, [claim("conv-a", "TMUX--a"), claim("conv-b", "TMUX--b")])
        by_id = {r["provider_task_id"]: r for r in doc["rows"]}
        self.assertEqual(rc, 0)
        self.assertEqual(by_id["conv-b"]["reason"], "durable host id mismatch")
        self.assertEqual(by_id["conv-b"]["attention"], "conflict")
        self.assertEqual(by_id["conv-a"]["disposition"], "restore")


class TieBreakTests(unittest.TestCase):
    def transcripts(self, fx, ages):
        """ages: {task_id: seconds old}; one <projects>/<slug>/<id>.jsonl each."""
        projects = fx.root / "projects"
        (projects / "slug").mkdir(parents=True, exist_ok=True)
        now = time.time()
        for task_id, age in ages.items():
            path = projects / "slug" / f"{task_id}.jsonl"
            path.write_text("{}\n")
            os.utime(path, (now - age, now - age))
        return projects

    def dup_rows(self, cwd_b="/tmp/work"):
        return [claim("old-1", "TMUX--dup"), claim("new-1", "TMUX--dup", cwd=cwd_b)]

    def row_for(self, doc, name="TMUX--dup"):
        found = [t for t in doc["tasks"] if t["tmux_session"] == name]
        self.assertEqual(len(found), 1, found)
        return found[0]

    def test_newest_transcript_wins_with_evidence(self):
        fx = Fixture(self)
        projects = self.transcripts(fx, {"old-1": 3600, "new-1": 60})
        row = self.row_for(fx.capture(self.dup_rows(), projects=[projects]))
        self.assertEqual(row["provider_task_id"], "new-1")
        self.assertEqual(row["shadowed_task_ids"], ["old-1"])
        self.assertEqual(row["recovery_action"], "insufficient-evidence")  # restorable pending current evidence, not unknown
        self.assertEqual(row["control_owner"], "cctrl")
        tie = row["tie_break"]
        self.assertEqual(tie["basis"], "transcript-mtime")
        self.assertEqual(tie["chosen"], "new-1")
        self.assertGreaterEqual(tie["margin_s"], 3000)
        self.assertEqual({c["id"] for c in tie["candidates"]}, {"old-1", "new-1"})
        self.assertTrue(all(c["transcript_mtime"] and c["transcript_bytes"] for c in tie["candidates"]))

    def test_sole_transcript_wins_over_a_claim_with_none(self):
        fx = Fixture(self)
        projects = self.transcripts(fx, {"new-1": 60})
        row = self.row_for(fx.capture(self.dup_rows(), projects=[projects]))
        self.assertEqual(row["provider_task_id"], "new-1")
        self.assertIsNone(row["tie_break"]["margin_s"])

    def test_refuses_when_close_cwd_differs_or_no_transcripts(self):
        fx = Fixture(self)
        reason = "ambiguous-tmux-claim: several open records claim a tmux name that is not live"
        # Two minutes apart is the margin: 30 s is refused.
        projects = self.transcripts(fx, {"old-1": 90, "new-1": 60})
        row = self.row_for(fx.capture(self.dup_rows(), projects=[projects]))
        self.assertEqual(row["recovery_action"], "unknown")
        self.assertEqual(row["control_owner"], "unknown")
        self.assertTrue(row["recovery_reason"].startswith(reason))
        self.assertIn("within 120s", row["recovery_reason"])
        self.assertNotIn("tie_break", row)
        # A wide gap but a different cwd is refused too.
        projects = self.transcripts(fx, {"old-1": 3600, "new-1": 60})
        row = self.row_for(fx.capture(self.dup_rows(cwd_b="/tmp/elsewhere"), projects=[projects]))
        self.assertEqual(row["recovery_action"], "unknown")
        self.assertIn("different cwds", row["recovery_reason"])
        # No transcripts at all (and no projects dir) is refused.
        row = self.row_for(fx.capture(self.dup_rows()))
        self.assertEqual(row["recovery_action"], "unknown")
        self.assertIn("no candidate has a transcript", row["recovery_reason"])
        # The row is still represented once, by the first claim, with the rest shadowed.
        self.assertEqual(row["provider_task_id"], "old-1")
        self.assertEqual(row["shadowed_task_ids"], ["new-1"])

    def test_margin_is_configurable(self):
        fx = Fixture(self)
        projects = self.transcripts(fx, {"old-1": 90, "new-1": 60})
        row = self.row_for(fx.capture(self.dup_rows(), projects=[projects], margin=10))
        self.assertEqual(row["provider_task_id"], "new-1")

    def test_ineligible_claims_are_not_candidates(self):
        fx = Fixture(self)
        rows = [claim("old-1", "TMUX--dup", launched_by_cctrl=False), claim("new-1", "TMUX--dup")]
        # Only one eligible claim, and it has a transcript: picked. Without one: refused.
        projects = self.transcripts(fx, {"new-1": 60, "old-1": 10})
        row = self.row_for(fx.capture(rows, projects=[projects]))
        self.assertEqual(row["provider_task_id"], "new-1")
        row = self.row_for(fx.capture(rows))
        self.assertEqual(row["recovery_action"], "unknown")

    def test_live_name_branch_is_unchanged(self):
        fx = Fixture(self)
        rows = [claim("old-1", "TMUX--dup"), claim("live-1", "TMUX--dup")]
        sessions = [{"name": "TMUX--dup", "agent": "claude", "session_id": "live-1", "dir": "/tmp/work"}]
        row = self.row_for(fx.capture(rows, sessions=sessions))
        self.assertEqual(row["provider_task_id"], "live-1")
        self.assertEqual(row["recovery_action"], "already-live")
        self.assertNotIn("tie_break", row)


if __name__ == "__main__":
    unittest.main()
