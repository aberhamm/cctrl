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
            "processes": [dict({"pid": 100 + i, "ppid": 1, "started": "x"}, **(c if isinstance(c, dict) else {"command": c}))
                          for i, c in enumerate(commands)],
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

    def plan(self, snapshot_tasks, cat_rows, process=None, strict=False, sessions=None):
        snapshot = {"schema_version": 2, "host_id": HOST, "hostname": "fixture", "tasks": snapshot_tasks}
        args = ["plan", "--snapshot", self.write("snap.json", snapshot), "--catalogue", self.write("cat.json", catalogue(cat_rows)),
                "--process", self.write("proc.json", process or process_doc()), "--host-id", HOST, "--hostname", "fixture"]
        if strict:
            args.append("--strict")
        sessions_dir = self.root / "claude-sessions"
        sessions_dir.mkdir(exist_ok=True)
        for pid, session_id in (sessions or {}).items():
            (sessions_dir / f"{pid}.json").write_text(json.dumps({"pid": pid, "sessionId": session_id, "cwd": "/tmp/work", "procStart": "x"}))
        args += ["--claude-sessions-dir", str(sessions_dir)]
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
        decoys = ["grep conv-aaa-111", 'bash -c "cctrl start -r conv-aaa-111"', "claude --resume 99999999-9999-4999-8999-999999999999",
                  "claude --name conv-aaa-111", "python3 claude --resume conv-aaa-111",
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


class BareResumeTests(unittest.TestCase):
    """S1: a conversation resumed through the picker has no id in argv."""

    FM = "claude --name homelab --resume --chrome"

    def fixture_a(self, fx, process, sessions=None):
        tasks = [snap_task("conv-fm", "TMUX--fm-old")]
        # the live name belongs to another conversation, so the catalogue never shows conv-fm live
        rows = [claim("conv-fm", "TMUX--fm-old"), claim("conv-other", "TMUX--homelab", action_capabilities={"tmux_attach": {"supported": True}})]
        return fx.plan(tasks, rows, process=process, sessions=sessions)

    def test_session_file_names_the_conversation(self):
        fx = Fixture(self)
        rc, doc = self.fixture_a(fx, process_doc([self.FM]), sessions={100: "conv-fm"})
        self.assertEqual(doc["rows"][0]["disposition"], "already-live")
        self.assertIn("conversation already running (pid 100)", doc["rows"][0]["reason"])

    def test_unidentified_bare_resume_in_the_same_cwd_blocks_the_row(self):
        fx = Fixture(self)
        rc, doc = self.fixture_a(fx, process_doc([{"command": self.FM, "cwd": "/tmp/work"}]))
        row = doc["rows"][0]
        self.assertNotEqual(row["disposition"], "restore")
        self.assertEqual(row["attention"], "ambiguous")
        self.assertIn("unidentified live claude (pid 100", row["reason"])

    def test_unidentified_bare_resume_elsewhere_does_not_block(self):
        fx = Fixture(self)
        rc, doc = self.fixture_a(fx, process_doc([{"command": self.FM, "cwd": "/tmp/elsewhere"}]))
        self.assertEqual(doc["rows"][0]["disposition"], "restore")

    def test_unknown_cwd_fails_closed(self):
        fx = Fixture(self)
        for command in (self.FM, "claude --continue", "claude -r --chrome"):
            rc, doc = self.fixture_a(fx, process_doc([command]))
            self.assertEqual(doc["rows"][0]["attention"], "ambiguous", command)

    def test_a_session_file_for_another_conversation_clears_the_pid(self):
        fx = Fixture(self)
        rc, doc = self.fixture_a(fx, process_doc([self.FM]), sessions={100: "conv-someone-else"})
        self.assertEqual(doc["rows"][0]["disposition"], "restore")

    def test_session_file_in_a_launch_record_config_dir(self):
        fx = Fixture(self)
        config = fx.root / "profile-config"
        (config / "sessions").mkdir(parents=True)
        (config / "sessions" / "100.json").write_text(json.dumps({"pid": 100, "sessionId": "conv-fm", "procStart": "x"}))
        meta = fx.root / "meta"
        meta.mkdir()
        (meta / "r.json").write_text(json.dumps({"tmux_session": "TMUX--x", "claude_config_dir": str(config)}))
        tasks = [snap_task("conv-fm", "TMUX--fm-old")]
        args = ["plan", "--snapshot", fx.write("snap.json", {"schema_version": 2, "host_id": HOST, "tasks": tasks}),
                "--catalogue", fx.write("cat.json", catalogue([claim("conv-fm", "TMUX--fm-old")])),
                "--process", fx.write("proc.json", process_doc([self.FM])), "--host-id", HOST, "--hostname", "fixture",
                "--claude-sessions-dir", str(fx.root / "none"), "--metadata-dir", str(meta)]
        done = fx.run(*args)
        self.assertEqual(json.loads(done.stdout)["rows"][0]["disposition"], "already-live")


class BareResumeWideningTests(unittest.TestCase):
    """NEW-S1/S2/S3/N2: which argv shapes count as bare, who is blocked, and how session files are trusted."""

    def plan(self, fx, process, tasks=None, cat=None, sessions=None, session_files=None):
        tasks = tasks or [snap_task("conv-fm", "TMUX--fm-old")]
        cat = cat or [claim("conv-fm", "TMUX--fm-old")]
        sessions_dir = fx.root / "claude-sessions"
        sessions_dir.mkdir(exist_ok=True)
        for name, body in (session_files or {}).items():
            (sessions_dir / name).write_text(json.dumps(body))
        snapshot = {"schema_version": 2, "host_id": HOST, "hostname": "fixture", "tasks": tasks}
        args = ["plan", "--snapshot", fx.write("snap.json", snapshot), "--catalogue", fx.write("cat.json", catalogue(cat)),
                "--process", fx.write("proc.json", process), "--host-id", HOST, "--hostname", "fixture",
                "--claude-sessions-dir", str(sessions_dir)]
        done = fx.run(*args)
        self.assertIn(done.returncode, (0, 69), done.stderr)
        return json.loads(done.stdout)

    def test_continue_never_takes_a_value(self):
        fx = Fixture(self)
        for command in ("claude -c fix the tests", "claude --continue", "claude --model m -c --chrome"):
            doc = self.plan(fx, process_doc([{"command": command, "cwd": "/tmp/work"}]))
            self.assertEqual(doc["rows"][0]["attention"], "ambiguous", command)

    def test_resume_with_a_non_uuid_value_is_bare(self):
        fx = Fixture(self)
        for command in ("claude --resume homelab", "claude -r fix-the-tests", "claude --resume=homelab"):
            doc = self.plan(fx, process_doc([{"command": command, "cwd": "/tmp/work"}]))
            self.assertEqual(doc["rows"][0]["attention"], "ambiguous", command)
        # a UUID value names a conversation, so the process is identified and elsewhere
        doc = self.plan(fx, process_doc([{"command": "claude --resume 99999999-9999-4999-8999-999999999999", "cwd": "/tmp/work"}]))
        self.assertEqual(doc["rows"][0]["disposition"], "restore")

    def test_node_cli_js_resume_counts(self):
        fx = Fixture(self)
        doc = self.plan(fx, process_doc([{"command": "node /opt/claude/lib/cli.js --resume", "cwd": "/tmp/work"}]))
        self.assertEqual(doc["rows"][0]["attention"], "ambiguous")
        doc = self.plan(fx, process_doc([{"command": "node /opt/other/server.js --resume", "cwd": "/tmp/work"}]))
        self.assertEqual(doc["rows"][0]["disposition"], "restore")

    def test_only_rows_that_would_restore_are_demoted_and_the_pid_is_reported(self):
        fx = Fixture(self)
        tasks = [snap_task("conv-a", "TMUX--a"), snap_task("conv-old", "TMUX--old", control_owner="unknown", execution_runtime="unknown", lifecycle_state="unknown"),
                 snap_task("conv-other", "TMUX--other", cwd="/tmp/elsewhere")]
        cat = [claim("conv-a", "TMUX--a"), claim("conv-old", "TMUX--old"), claim("conv-other", "TMUX--other", cwd="/tmp/elsewhere")]
        doc = self.plan(fx, process_doc([{"command": "claude --resume", "cwd": "/tmp/work"}]), tasks=tasks, cat=cat)
        by_id = {r["provider_task_id"]: r for r in doc["rows"]}
        self.assertEqual(by_id["conv-a"]["attention"], "ambiguous")
        self.assertEqual(by_id["conv-a"]["blocked_by_pid"], 100)
        self.assertIn("pid 100", by_id["conv-a"]["reason"])
        self.assertEqual(by_id["conv-old"]["disposition"], "unknown")
        self.assertNotIn("attention", by_id["conv-old"])  # an old dead row stays informational
        self.assertEqual(by_id["conv-other"]["disposition"], "restore")

    def test_cwd_comparison_uses_realpaths(self):
        fx = Fixture(self)
        real = fx.root / "real"
        real.mkdir()
        link = fx.root / "link"
        link.symlink_to(real)
        tasks = [snap_task("conv-fm", "TMUX--fm-old", cwd=str(link))]
        doc = self.plan(fx, process_doc([{"command": "claude --resume", "cwd": str(real)}]), tasks=tasks, cat=[claim("conv-fm", "TMUX--fm-old", cwd=str(link))])
        self.assertEqual(doc["rows"][0]["attention"], "ambiguous")

    def test_session_file_is_found_for_any_argv0_when_procstart_matches(self):
        fx = Fixture(self)
        versioned = {"command": "/opt/claude/versions/2.1.9 --resume=abc", "started": "Sat Nov 14 15:22:58 2026"}
        files = {"100.json": {"pid": 100, "sessionId": "conv-fm", "procStart": "Sat Nov 14 15:22:58 2026"}}
        doc = self.plan(fx, process_doc([versioned]), session_files=files)
        self.assertEqual(doc["rows"][0]["disposition"], "already-live")
        self.assertIn("pid 100", doc["rows"][0]["reason"])

    def test_stale_or_mismatched_session_files_are_ignored(self):
        fx = Fixture(self)
        proc = {"command": "claude --chrome", "started": "Sat Nov 14 15:22:58 2026"}
        files = {"100.json": {"pid": 100, "sessionId": "conv-fm", "procStart": "Fri Nov 13 01:00:00 2026"},   # pid reused
                 "555.json": {"pid": 555, "sessionId": "conv-fm", "procStart": "Sat Nov 14 15:22:58 2026"},   # pid not alive
                 "100.key": {"pid": 100}}
        doc = self.plan(fx, process_doc([proc]), session_files=files)
        self.assertEqual(doc["rows"][0]["disposition"], "restore")

    def test_a_bare_resume_with_a_stale_session_file_still_blocks(self):
        fx = Fixture(self)
        proc = {"command": "claude --resume", "started": "Sat Nov 14 15:22:58 2026", "cwd": "/tmp/work"}
        files = {"100.json": {"pid": 100, "sessionId": "conv-someone", "procStart": "Fri Nov 13 01:00:00 2026"}}
        doc = self.plan(fx, process_doc([proc]), session_files=files)
        self.assertEqual(doc["rows"][0]["attention"], "ambiguous")


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

    def test_refuses_when_an_untimed_claim_has_a_newer_record(self):
        # Fixture D: the old claim has a 3-day-old transcript, the newer claim (record today) has none.
        fx = Fixture(self)
        projects = self.transcripts(fx, {"old-1": 3 * 86400})
        rows = [claim("old-1", "TMUX--dup", recency="2026-10-29T10:00:00Z"), claim("new-1", "TMUX--dup", recency="2099-01-01T00:00:00Z")]
        row = self.row_for(fx.capture(rows, projects=[projects]))
        self.assertIsNone(row.get("tie_break"))
        self.assertIn("newer record than the winner", row["recovery_reason"])
        # an untimed claim with an OLDER record does not stop the pick
        rows = [claim("old-1", "TMUX--dup", recency="2026-10-29T10:00:00Z"), claim("new-1", "TMUX--dup", recency="2000-01-01T00:00:00Z")]
        self.assertEqual(self.row_for(fx.capture(rows, projects=[projects]))["provider_task_id"], "old-1")

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
