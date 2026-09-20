#!/usr/bin/env python3
"""Restore execution boundary with temporary evidence and no real launch."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOST = '0123456789abcdef0123456789abcdef'


class RestoreTests(unittest.TestCase):
    def run_restore(self, provider, count=1, switch_at=99):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            rows = []
            for i in range(count):
                tid = f'task-{i}'
                rows.append(dict(provider=provider, agent=provider, provider_task_id=tid, host_id=HOST,
                                 origin='cctrl', execution_runtime='tmux', control_owner='cctrl',
                                 lifecycle_state='active', restore_strategy='tmux-resume',
                                 registered_by_cctrl=True, launched_by_cctrl=True,
                                 resume_identity=tid, resume_identity_kind='codex-thread-id' if provider == 'codex' else 'claude-session-id',
                                 cwd=str(root), tmux_session=f'TMUX--fixture-{i}',
                                 action_capabilities={'tmux_attach': {'supported': False}}))
            (root / 'snapshot.json').write_text(json.dumps(dict(schema_version=2, hostname='fixture', tasks=rows)))
            (root / 'catalogue.json').write_text(json.dumps(dict(rows=rows, source_status=dict(registry='available', tmux='available', codex_provider='available'), source_errors=[])))
            (root / 'process.json').write_text(json.dumps(dict(status='available', source_cursor='fixture', processes=[])))
            records = [dict(provider_task_id=r['provider_task_id'], host_id=HOST,
                            chosen_outcome=dict(control_owner='unknown', execution_runtime='unknown', lifecycle_state='unknown', restore_strategy=None),
                            sources=dict(registry=dict(status='available'), app_server=dict(status='confirmed-absence'),
                                         tmux=dict(status='confirmed-absence'), process_table=dict(status='confirmed-absence', source_cursor='fixture'))) for r in rows]
            (root / 'absent.json').write_text(json.dumps(dict(records=records)))
            for r in records:
                r['chosen_outcome'].update(control_owner='app', execution_runtime='app-server', restore_strategy='provider-managed')
                r['sources']['app_server']['status'] = 'claimed'
            (root / 'app.json').write_text(json.dumps(dict(records=records)))
            env = {k: v for k, v in os.environ.items() if not k.startswith('CCTRL_')}
            env.update(HOME=str(root), CCTRL_NO_MAIN='1', CCTRL_HOST_PREFIX='fixture',
                       CCTRL_DEFAULT_AGENT='codex', CCTRL_AGENT='codex',
                       CCTRL_RESTORE_LAUNCH_LOG=str(root / 'launch.log'), CCTRL_RESTORE_WAVE_PAUSE='0',
                       CCTRL_RESTORE_WAVE_SIZE='1', TEST_ROOT=str(root), SWITCH_AT=str(switch_at))
            script = '''source "$0"
_cctrl_host_id() { echo 0123456789abcdef0123456789abcdef; }
_task_list_json() { cat "$TEST_ROOT/catalogue.json"; }
_snapshot_process_source() { cp "$TEST_ROOT/process.json" "$1"; }
_res_mem_free_pct() { echo 90; }
_res_swap_used_mb() { echo 0; }
_session_reconcile_codex() {
    local n=0
    [[ ! -f "$TEST_ROOT/calls" ]] || n="$(cat "$TEST_ROOT/calls")"
    n=$((n+1)); echo "$n" > "$TEST_ROOT/calls"
    if (( n >= SWITCH_AT )); then cat "$TEST_ROOT/app.json"; else cat "$TEST_ROOT/absent.json"; fi
}
_session_restore --from "$TEST_ROOT/snapshot.json" --yes --quiet
'''
            result = subprocess.run(['bash', '-c', script, str(ROOT / 'cctrl')], env=env,
                                    capture_output=True, text=True, timeout=15)
            log = (root / 'launch.log').read_text() if (root / 'launch.log').exists() else ''
            calls = int((root / 'calls').read_text()) if (root / 'calls').exists() else 0
            return result, log, calls

    def test_claude_restore_overrides_configured_codex(self):
        result, log, _ = self.run_restore('claude')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--agent claude', log)
        self.assertNotIn('--agent codex', log)

    def test_app_owner_appearing_after_plan_prevents_launch(self):
        result, log, calls = self.run_restore('codex', switch_at=2)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(log, '')
        self.assertEqual(calls, 2)
        self.assertIn('fresh exact-task ownership', result.stderr)

    def test_each_selected_row_refreshes_after_prior_launch(self):
        result, log, calls = self.run_restore('codex', count=2, switch_at=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, 3)
        self.assertEqual(len(log.splitlines()), 1)
        self.assertIn('-r task-0', log)
        self.assertIn('--agent codex', log)
        self.assertNotIn('task-1', log)


if __name__ == '__main__':
    unittest.main()
