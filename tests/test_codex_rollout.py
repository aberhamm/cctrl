#!/usr/bin/env python3
"""All lookup fixtures are isolated; never opens the operator's Codex state."""
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('codex_rollout', Path(__file__).resolve().parents[1] / 'lib/codex_rollout.py')
lookup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lookup)


class LookupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.meta = {'cwd': '/repo', 'created_at': '2026-09-20T10:00:00Z'}

    def rollout(self, tid, prompt='', cwd='/repo', ts='2026-09-20T10:01:00.123Z'):
        path = self.root / f'rollout-{tid}.jsonl'
        path.write_text(json.dumps({'type': 'session_meta', 'timestamp': ts, 'payload': {'id': tid, 'cwd': cwd}}) + '\n' + json.dumps({'type': 'event_msg', 'payload': {'type': 'user_message', 'message': prompt}}) + '\n')
        return str(path)

    def test_unique_and_ambiguous_cwd(self):
        path = self.rollout('a')
        self.assertEqual(lookup.find_rollout(self.root, self.meta), path)
        self.rollout('b')
        self.assertEqual(lookup.find_rollout(self.root, self.meta), '')

    def test_stable_id_cannot_fall_back_to_other_thread(self):
        self.rollout('other')
        self.assertEqual(lookup.find_rollout(self.root, dict(self.meta, conversation_id='missing')), '')

    def test_explicit_resume_accepts_old_thread_and_changed_prompt(self):
        path = self.rollout('old', 'first', ts='2025-01-01T10:00:00Z')
        self.rollout('new', 'resume prompt')
        meta = dict(self.meta, conversation_id='old', initial_prompt='resume prompt', launch_command='codex resume old')
        self.assertEqual(lookup.find_rollout(self.root, meta), path)

    def test_unique_new_prompt_repairs_stale_id_in_launch_cwd(self):
        self.rollout('old', 'old prompt')
        path = self.rollout('new', 'new prompt')
        meta = dict(self.meta, conversation_id='old', initial_prompt='new prompt')
        self.assertEqual(lookup.find_rollout(self.root, meta), path)
        self.rollout('duplicate', 'new prompt')
        self.assertEqual(lookup.find_rollout(self.root, meta), '')

    def test_identical_prompt_in_other_repo_is_not_this_launch(self):
        self.rollout('other', 'continue', cwd='/other')
        self.assertEqual(lookup.find_rollout(self.root, dict(self.meta, initial_prompt='continue')), '')

    def test_historical_files_filtered_before_large_prompt_reads(self):
        for i in range(1888):
            path = self.rollout(str(i), ts='2025-01-01T10:00:00Z')
            with open(path, 'a') as stream:
                stream.write('x' * 10000)
        path = self.rollout('current', 'new prompt')
        start = time.monotonic()
        self.assertEqual(lookup.find_rollout(self.root, dict(self.meta, initial_prompt='new prompt')), path)
        self.assertLess(time.monotonic() - start, 2)

    def test_archived_and_missing_rows_excluded_read_only(self):
        db = self.root / 'state.sqlite'
        with sqlite3.connect(db) as con:
            con.execute('CREATE TABLE threads (id TEXT, archived INTEGER)')
            con.execute("INSERT INTO threads VALUES ('a', 1)")
        self.rollout('a')
        self.rollout('missing')
        before = db.read_bytes()
        self.assertEqual(lookup.find_rollout(self.root, self.meta, str(db)), '')
        self.assertEqual(db.read_bytes(), before)

    def test_exhausted_budget_cannot_return_partial_unique_match(self):
        self.rollout('z')
        self.rollout('a')
        with patch.object(lookup, 'MAX_BYTES', 250):
            self.assertEqual(lookup.find_rollout(self.root, self.meta), '')
        with patch.object(lookup, 'MAX_FILES', 1):
            self.assertEqual(lookup.find_rollout(self.root, self.meta), '')
        self.assertEqual(lookup.find_rollout(self.root, self.meta, timeout=0), '')

    def test_title_poll_counts_lookup_elapsed_time(self):
        source = (Path(__file__).resolve().parents[1] / 'cctrl').read_text()
        start = source.index('_session_codex_schedule_display_name_sync() {')
        end = source.index('\n_session_never_prompted()', start)
        script = source[start:end] + '\n' + """
_session_metadata_field() { echo created; }
_session_codex_set_display_name() { sleep 2; return 1; }
sleep() { command sleep "$@"; }
disown() { :; }
CCTRL_CODEX_TITLE_POLL_TIMEOUT=3
CCTRL_CODEX_TITLE_POLL_INTERVAL=1
_session_codex_schedule_display_name_sync fixture label created
wait
"""
        start = time.monotonic()
        subprocess.run(['bash', '-c', script], check=True, timeout=5)
        self.assertLess(time.monotonic() - start, 4.5)

    def test_oversized_line_is_bounded(self):
        path = self.rollout('a')
        with open(path, 'a') as stream:
            stream.write('x' * (lookup.MAX_LINE + 100))
        self.assertEqual(lookup.find_rollout(self.root, dict(self.meta, initial_prompt='absent')), '')


if __name__ == '__main__':
    unittest.main()
