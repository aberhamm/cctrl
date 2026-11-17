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
NOW = '2026-11-17T12:00:00Z'
CODEX_ID = '01a0bde7-4a5f-7ba0-bbfb-a1e4e4df4af4'


def record(task_id, name, pane_id, pane_pid, provider='claude', owner=('cctrl', 'tmux', 'active'), started=STARTED):
    return dict(schema_version=2, provider=provider, provider_task_id=task_id, host_id=HOST,
                tmux_session=name, name=name, pane_id=pane_id, pane_pid=pane_pid, pane_started=started,
                control_owner=owner[0], execution_runtime=owner[1], lifecycle_state=owner[2])


class ConflictResolveTests(unittest.TestCase):
    def plan(self, records, panes, processes, claude=None, codex=None, panes_status='available', protect=None,
             command='plan', extra=None, launch=None, proc_start=None):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'meta').mkdir()
            for i, rec in enumerate(records):
                (root / 'meta' / f'task-{i:064d}.json').write_text(json.dumps(rec))
            for i, rec in enumerate(launch or []):
                (root / 'meta' / f'launch-{rec.get("provisional_launch_id", i)}.json').write_text(json.dumps(rec))
            (root / 'sessions').mkdir()
            for pid, session_id in (claude or {}).items():
                body = {'pid': pid, 'sessionId': session_id}
                if proc_start and pid in proc_start:
                    body['procStart'] = proc_start[pid]
                (root / 'sessions' / f'{pid}.json').write_text(json.dumps(body))
            (root / 'panes.json').write_text(json.dumps({'status': panes_status, 'panes': panes}))
            (root / 'process.json').write_text(json.dumps({'status': 'available', 'source_cursor': 'c', 'processes': processes}))
            (root / 'codex.json').write_text(json.dumps(codex if codex is not None else {'records': []}))
            args_extra = list(extra or [])
            if protect is not None:
                (root / 'protect.json').write_text(json.dumps(protect))
                args_extra += ['--protect', str(root / 'protect.json')]
            out = subprocess.run(['python3', str(ROOT / 'lib' / 'conflict_resolve.py'), command,
                                  '--records-dir', str(root / 'meta'), '--panes', str(root / 'panes.json'),
                                  '--process', str(root / 'process.json'), '--claude-sessions', str(root / 'sessions'),
                                  '--codex', str(root / 'codex.json'), '--host-id', HOST] + args_extra,
                                 capture_output=True, text=True, check=True)
            doc = json.loads(out.stdout)
            if command == 'plan-predecessors':
                return doc
            return {row['provider_task_id']: row for row in doc['rows']}

    def predecessors(self, records, panes, processes, name='TMUX--n', expect='x-id', **kw):
        doc = self.plan(records, panes, processes, command='plan-predecessors',
                        extra=['--name', name, '--expect-task', expect, '--provider', 'claude',
                               '--now', NOW] + kw.pop('extra', []), **kw)
        doc['by'] = {row['provider_task_id'] or row['record']: row for row in doc['rows']}
        return doc

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

    def test_a_conversation_resumed_elsewhere_is_never_closed(self):
        # /resume in another pane: no id on any command line, only the
        # session file of the other Claude process proves it is live.
        rows = self.plan(
            [record('moved-id', 'TMUX--old', '%47', '700'),
             record('moved-too', 'TMUX--homelab', '%0', '100'), record('live-id', 'TMUX--homelab', '%0', '100')],
            [self.pane('TMUX--old', '%1', 50), self.pane('TMUX--homelab', '%0', 100), self.pane('TMUX--other', '%5', 500)],
            [self.proc(50, 1, 'bash'), self.proc(100, 1, 'bash wrapper'), self.proc(101, 100, 'claude'),
             self.proc(500, 1, 'bash wrapper'), self.proc(501, 500, 'claude'), self.proc(502, 500, 'claude')],
            claude={101: 'live-id', 501: 'moved-id', 502: 'moved-too'})
        self.assertEqual(rows['moved-id']['action'], 'skip')
        self.assertIn('running', rows['moved-id']['reason'])
        self.assertEqual(rows['moved-too']['action'], 'skip')
        self.assertIn('elsewhere', rows['moved-too']['reason'])

    def test_an_unreadable_claude_session_file_blocks_close(self):
        # A live Claude process without a readable session file might be
        # running the task; closing must fail closed. Node-launched Claude counts.
        for command in ('claude', 'node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js'):
            rows = self.plan(
                [record('maybe-id', 'TMUX--old', '%47', '700')],
                [self.pane('TMUX--old', '%1', 50)],
                [self.proc(50, 1, 'bash'), self.proc(600, 1, command)],
                claude={})
            self.assertEqual(rows['maybe-id']['action'], 'skip', command)
            self.assertIn('may be running', rows['maybe-id']['reason'])

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

    def test_codex_close_needs_confirmed_absence(self):
        rec = record('01a0bde5-95ce-0000-0000-000000000000', 'TMUX--scraper', '%47', '700', provider='codex',
                     owner=('conflict', 'conflict', 'active'))
        for status, action in (('confirmed-absence', 'close'), ('ambiguous', 'skip'), ('unavailable', 'skip')):
            evidence = {'records': [{'provider_task_id': rec['provider_task_id'], 'host_id': HOST,
                                     'sources': {'app_server': {'status': status}}}]}
            rows = self.plan([rec], [self.pane('TMUX--scraper', '%1', 100)], [self.proc(100, 1, 'bash')], codex=evidence)
            self.assertEqual(rows[rec['provider_task_id']]['action'], action, status)

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

    # --- plan-predecessors (D10a) -------------------------------------------------
    def live_x(self, extra_procs=(), claude=None):
        procs = [self.proc(100, 1, 'bash wrapper'), self.proc(101, 100, 'claude --resume x-id')] + list(extra_procs)
        return [self.pane('TMUX--n', '%0', 100)], procs, {101: 'x-id', **(claude or {})}

    def test_predecessor_dead_record_on_the_name_is_superseded_and_x_is_not_listed(self):
        panes, procs, claude = self.live_x()
        doc = self.predecessors([record('x-id', 'TMUX--n', '%0', '100'), record('p-id', 'TMUX--n', '%9', '900')],
                                panes, procs, claude=claude)
        self.assertTrue(doc['proved'])
        self.assertEqual((doc['by']['p-id']['action'], doc['by']['p-id']['reason']), ('close', 'superseded-by x-id'))
        self.assertNotIn('x-id', doc['by'])

    def test_predecessor_protected_record_is_skipped_with_the_snapshot_name(self):
        panes, procs, claude = self.live_x()
        doc = self.predecessors([record('p-id', 'TMUX--n', '%9', '900')], panes, procs, claude=claude,
                                protect=[{'id': 'p-id', 'snapshot': 'snap-1.json', 'generated_at': '2026-11-14T10:00:00Z'}])
        self.assertEqual(doc['by']['p-id']['action'], 'skip')
        self.assertIn('snap-1.json', doc['by']['p-id']['reason'])

    def test_predecessor_running_by_argv_or_session_file_is_skipped(self):
        panes, procs, claude = self.live_x([self.proc(700, 1, 'tool --resume p-id')])
        doc = self.predecessors([record('p-id', 'TMUX--n', '%9', '900')], panes, procs, claude=claude)
        self.assertEqual(doc['by']['p-id']['action'], 'skip')
        panes, procs, claude = self.live_x([self.proc(700, 1, 'bash'), self.proc(701, 700, 'claude')], claude={701: 'p-id'})
        doc = self.predecessors([record('p-id', 'TMUX--n', '%9', '900')], panes, procs, claude=claude)
        self.assertEqual(doc['by']['p-id']['action'], 'skip')

    def test_predecessor_versioned_binary_with_a_matching_session_file_blocks_the_close(self):
        # argv0 is a versioned binary, not "claude": only the session-file walk sees it.
        panes, procs, claude = self.live_x([self.proc(700, 1, '/x/versions/2.1.9 --flag')], claude={700: 'p-id'})
        for plan_kw in ({'command': 'plan-predecessors'},):
            doc = self.predecessors([record('p-id', 'TMUX--n', '%9', '900')], panes, procs, claude=claude,
                                    proc_start={700: STARTED})
            self.assertEqual(doc['by']['p-id']['action'], 'skip')
            self.assertIn('may be running', doc['by']['p-id']['reason'])

    def test_a_session_file_with_a_mismatched_procstart_never_marks_the_task_running(self):
        panes, procs, claude = self.live_x([self.proc(700, 1, 'bash')], claude={700: 'p-id'})
        doc = self.predecessors([record('p-id', 'TMUX--n', '%9', '900')], panes, procs, claude=claude,
                                proc_start={700: 'Mon Sep  1 09:00:00 2026'})
        self.assertEqual(doc['by']['p-id']['action'], 'close')

    def test_predecessor_proof_failures_close_nothing(self):
        recs = [record('p-id', 'TMUX--n', '%9', '900')]
        # no session file for the pane's claude
        doc = self.predecessors(recs, [self.pane('TMUX--n', '%0', 100)],
                                [self.proc(100, 1, 'bash'), self.proc(101, 100, 'claude')], claude={})
        self.assertFalse(doc['proved']); self.assertEqual(doc['rows'], [])
        # two agents under the pane
        doc = self.predecessors(recs, [self.pane('TMUX--n', '%0', 100)],
                                [self.proc(100, 1, 'bash'), self.proc(101, 100, 'claude'), self.proc(102, 100, 'claude')],
                                claude={101: 'x-id', 102: 'x-id'})
        self.assertFalse(doc['proved'])
        # the pane runs another conversation
        doc = self.predecessors(recs, [self.pane('TMUX--n', '%0', 100)],
                                [self.proc(100, 1, 'bash'), self.proc(101, 100, 'claude')], claude={101: 'y-id'})
        self.assertFalse(doc['proved']); self.assertIn('y-id', doc['global_skip']); self.assertEqual(doc['rows'], [])

    def test_predecessor_provisional_receipts(self):
        panes, procs, claude = self.live_x()
        def receipt(lid, created, pane=('%9', '900'), name='TMUX--n'):
            return dict(schema_version=2, provider='claude', provider_task_id=None, host_id=HOST, tmux_session=name,
                        name=name, pane_id=pane[0], pane_pid=pane[1], created_at=created, last_observed_at=created,
                        control_owner='cctrl', execution_runtime='tmux', lifecycle_state='active', provisional_launch_id=lid)
        doc = self.predecessors([], panes, procs, claude=claude, launch=[
            receipt('old', '2026-11-17T11:00:00Z'), receipt('new', '2026-11-17T11:58:00Z'),
            receipt('same', '2026-11-17T11:00:00Z', pane=('%0', '100')), receipt('own', '2026-11-17T11:00:00Z')],
            extra=['--exclude-record', 'launch-own.json'])
        by = doc['by']
        self.assertEqual(by['launch-old.json']['action'], 'close')
        self.assertTrue(by['launch-old.json']['provisional'])
        self.assertIn('grace', by['launch-new.json']['reason'])
        self.assertEqual(by['launch-same.json']['reason'], 'shares the live pane')
        self.assertNotIn('launch-own.json', by)

    def test_predecessor_codex_needs_confirmed_absence(self):
        for status, action in (('confirmed-absence', 'close'), ('ambiguous', 'skip'), ('unavailable', 'skip')):
            panes, procs, claude = self.live_x()
            rec = record(CODEX_ID, 'TMUX--n', '%9', '900', provider='codex')
            evidence = {'records': [{'provider_task_id': CODEX_ID, 'host_id': HOST, 'sources': {'app_server': {'status': status}}}]}
            doc = self.predecessors([rec], panes, procs, claude=claude, codex=evidence)
            self.assertEqual(doc['by'][CODEX_ID]['action'], action, status)

    def test_predecessor_other_hosts_app_owned_ended_and_other_names_are_not_closed(self):
        panes, procs, claude = self.live_x()
        other_host = dict(record('h-id', 'TMUX--n', '%9', '900'), host_id='f' * 32)
        app = record('a-id', 'TMUX--n', '%9', '900', owner=('app', 'app-server', 'active'))
        ended = record('e-id', 'TMUX--n', '%9', '900', owner=('unknown', 'unknown', 'closed'))
        elsewhere = record('o-id', 'TMUX--other', '%9', '900')
        doc = self.predecessors([other_host, app, ended, elsewhere], panes, procs, claude=claude)
        self.assertEqual(set(doc['by']), {'a-id'})
        self.assertEqual(doc['by']['a-id']['action'], 'skip')

    def test_anchorless_predecessor_closes_in_scoped_mode_but_not_in_the_global_plan(self):
        panes, procs, claude = self.live_x()
        anchorless = record('p-id', 'TMUX--n', None, None)
        doc = self.predecessors([anchorless], panes, procs, claude=claude)
        self.assertEqual(doc['by']['p-id']['action'], 'close')
        rows = self.plan([anchorless], panes, procs, claude=claude)
        self.assertEqual((rows['p-id']['action'], rows['p-id']['reason']), ('skip', 'record has no pane anchor'))

    def test_global_plan_never_closes_a_protected_record(self):
        protect = [{'id': 'stale-id', 'snapshot': 'snap-2.json', 'generated_at': '2026-11-14T10:00:00Z'}]
        rows = self.plan([record('stale-id', 'TMUX--scraper', '%47', '700')],
                         [self.pane('TMUX--scraper', '%1', 100)], [self.proc(100, 1, 'bash')], protect=protect)
        self.assertEqual(rows['stale-id']['action'], 'skip')
        self.assertEqual(rows['stale-id']['reason'], 'protected: live in snap-2.json at 2026-11-14T10:00:00Z')

    def test_predecessor_evidence_unavailable_is_a_global_skip(self):
        panes, procs, claude = self.live_x()
        doc = self.predecessors([record('p-id', 'TMUX--n', '%9', '900')], panes, procs, claude=claude, panes_status='unavailable')
        self.assertFalse(doc['proved']); self.assertEqual(doc['rows'], [])
        self.assertIn('evidence unavailable', doc['global_skip'])


if __name__ == '__main__':
    unittest.main()
