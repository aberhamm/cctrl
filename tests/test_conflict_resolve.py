#!/usr/bin/env python3
"""lib/conflict_resolve.py decisions from fixture evidence (plan 070 S5)."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOST = '0123456789abcdef0123456789abcdef'
STARTED = 'Wed Sep 23 17:40:22 2026'
CODEX_ID = '01a0bde7-4a5f-7ba0-bbfb-a1e4e4df4af4'


def record(task_id, name, pane_id, pane_pid, provider='claude', owner=('cctrl', 'tmux', 'active'), started=STARTED):
    return dict(schema_version=2, provider=provider, provider_task_id=task_id, host_id=HOST,
                tmux_session=name, name=name, pane_id=pane_id, pane_pid=pane_pid, pane_started=started,
                control_owner=owner[0], execution_runtime=owner[1], lifecycle_state=owner[2])


class ConflictResolveTests(unittest.TestCase):
    def plan(self, records, panes, processes, claude=None, codex=None, panes_status='available'):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'meta').mkdir()
            for i, rec in enumerate(records):
                (root / 'meta' / f'task-{i:064d}.json').write_text(json.dumps(rec))
            (root / 'sessions').mkdir()
            for pid, session_id in (claude or {}).items():
                (root / 'sessions' / f'{pid}.json').write_text(json.dumps({'pid': pid, 'sessionId': session_id}))
            (root / 'panes.json').write_text(json.dumps({'status': panes_status, 'panes': panes}))
            (root / 'process.json').write_text(json.dumps({'status': 'available', 'source_cursor': 'c', 'processes': processes}))
            (root / 'codex.json').write_text(json.dumps(codex if codex is not None else {'records': []}))
            out = subprocess.run(['python3', str(ROOT / 'lib' / 'conflict_resolve.py'), 'plan',
                                  '--records-dir', str(root / 'meta'), '--panes', str(root / 'panes.json'),
                                  '--process', str(root / 'process.json'), '--claude-sessions', str(root / 'sessions'),
                                  '--codex', str(root / 'codex.json'), '--host-id', HOST],
                                 capture_output=True, text=True, check=True)
            return {row['provider_task_id']: row for row in json.loads(out.stdout)['rows']}

    def pane(self, name, pane_id, pid):
        return {'session_name': name, 'pane_id': pane_id, 'pane_pid': str(pid)}

    def proc(self, pid, ppid, command, started=STARTED):
        return {'pid': pid, 'ppid': ppid, 'started': started, 'command': command}

    def test_claude_pane_running_another_conversation_supersedes_the_stale_record(self):
        rows = self.plan(
            [record('live-id', 'TMUX--homelab', '%0', '100'), record('old-id', 'TMUX--homelab', '%0', '100')],
            [self.pane('TMUX--homelab', '%0', 100)],
            [self.proc(100, 1, 'bash session-wrapper.sh claude'), self.proc(101, 100, 'claude --resume live-id')],
            claude={101: 'live-id'})
        self.assertEqual(rows['old-id']['action'], 'close')
        self.assertEqual(rows['old-id']['reason'], 'superseded-by live-id')
        self.assertEqual(rows['live-id']['action'], 'none')

    def test_gone_pane_on_a_name_held_by_another_execution_is_stale(self):
        rows = self.plan(
            [record('stale-id', 'TMUX--scraper', '%47', '700')],
            [self.pane('TMUX--scraper', '%1', 100)],
            [self.proc(100, 1, 'bash wrapper')])
        self.assertEqual((rows['stale-id']['action'], rows['stale-id']['reason']), ('close', 'stale-anchor'))

    def test_a_name_with_no_live_session_is_restore_territory(self):
        rows = self.plan([record('gone-id', 'TMUX--gone', '%3', '300')],
                         [self.pane('TMUX--other', '%1', 100)], [self.proc(100, 1, 'bash')])
        self.assertEqual(rows['gone-id']['action'], 'skip')

    def test_a_process_still_referencing_the_task_blocks_close(self):
        rows = self.plan([record('stale-id', 'TMUX--scraper', '%47', '700')],
                         [self.pane('TMUX--scraper', '%1', 100)],
                         [self.proc(100, 1, 'bash'), self.proc(900, 1, 'claude --resume stale-id')])
        self.assertEqual(rows['stale-id']['action'], 'skip')

    def test_pid_reuse_with_a_different_start_time_is_not_the_same_pane(self):
        rows = self.plan([record('old-exec', 'TMUX--x', '%0', '100', started='Mon Sep  1 09:00:00 2026')],
                         [self.pane('TMUX--x', '%0', 100)],
                         [self.proc(100, 1, 'bash wrapper')])
        self.assertEqual((rows['old-exec']['action'], rows['old-exec']['reason']), ('close', 'stale-anchor'))

    def codex_rows(self, app_status):
        rec = record(CODEX_ID, 'TMUX--cctrl', '%15', '3338', provider='codex', owner=('conflict', 'conflict', 'active'))
        evidence = {'records': [{'provider_task_id': CODEX_ID, 'host_id': HOST,
                                 'sources': {'app_server': {'status': app_status}}}]}
        return self.plan([rec], [self.pane('TMUX--cctrl', '%15', 3338)],
                         [self.proc(3338, 1, 'bash session-wrapper.sh codex'),
                          self.proc(3339, 3338, f'codex resume --yolo -c x=1 {CODEX_ID}')],
                         codex=evidence)

    def test_codex_live_owner_needs_app_server_evidence_the_app_is_not_writing(self):
        # Same rule as reconcile-codex: ambiguous = the inventory answered with
        # no live app-owner fact.
        for status in ('confirmed-absence', 'ambiguous'):
            self.assertEqual(self.codex_rows(status)[CODEX_ID]['action'], 'own', status)
        for status in ('unavailable', 'claimed'):
            row = self.codex_rows(status)[CODEX_ID]
            self.assertEqual(row['action'], 'skip', status)
            self.assertIn('App Server', row['reason'])

    def test_app_owned_records_are_never_touched(self):
        rec = record('01a0bde6-dfca-0000-0000-000000000000', 'TMUX--comet', '%47', '700', provider='codex',
                     owner=('app', 'app-server', 'active'))
        evidence = {'records': [{'provider_task_id': rec['provider_task_id'], 'host_id': HOST,
                                 'sources': {'app_server': {'status': 'confirmed-absence'}}}]}
        rows = self.plan([rec], [self.pane('TMUX--comet', '%1', 100)], [self.proc(100, 1, 'bash')], codex=evidence)
        self.assertEqual(rows[rec['provider_task_id']]['action'], 'skip')
        self.assertIn('owned by the app', rows[rec['provider_task_id']]['reason'])

    def test_partial_tmux_inventory_changes_nothing(self):
        rows = self.plan([record('stale-id', 'TMUX--scraper', '%47', '700')],
                         [self.pane('TMUX--scraper', '%1', 100)], [self.proc(100, 1, 'bash')],
                         panes_status='unavailable')
        self.assertEqual(rows['stale-id']['action'], 'skip')

    def test_ended_records_are_not_considered(self):
        rows = self.plan([record('done', 'TMUX--x', '%9', '9', owner=('unknown', 'unknown', 'closed'))],
                         [self.pane('TMUX--x', '%0', 100)], [self.proc(100, 1, 'bash')])
        self.assertNotIn('done', rows)


if __name__ == '__main__':
    unittest.main()
