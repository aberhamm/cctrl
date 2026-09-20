import sys
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
spec = importlib.util.spec_from_file_location('identity', ROOT / 'lib/terminal_identity.py')
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)


class CollectorTests(unittest.TestCase):
    def test_c_locale_tmux_preserves_framing_and_opaque_bootstrap(self):
        command = 'exec codex --model example "a|b__\t café 漢字\u2028#{} \\\"quoted\\\""'
        fields = dict(pane_id='%48', pane_pid='83939', session_created='1789892335',
                      **{'@cctrl_managed': '1', '@cctrl_agent': 'codex'},
                      pane_start_command=command)
        calls = []

        def fake_tmux(argv, **kwargs):
            calls.append((argv, kwargs))
            self.assertEqual(argv[0], 'tmux')
            self.assertEqual(kwargs['env']['LC_ALL'], 'C')
            self.assertEqual(argv[argv.index('-t') + 1], '=worker')
            output = argv[argv.index('-F') + 1]
            for key, value in fields.items():
                output = output.replace('#{' + key + '}', value)
            # Reproduce tmux's non-UTF8 client output scrubbing. The original
            # tab format without -u yields underscores and cannot be parsed.
            if '-u' not in argv:
                output = ''.join(c if ' ' <= c <= '~' else '_' for c in output)
            return subprocess.CompletedProcess(argv, 0, output + '\n', '')

        with patch.object(identity.subprocess, 'run', side_effect=fake_tmux):
            result = identity.Collector().pane('worker')
        self.assertEqual(result['command'], command)
        self.assertEqual(result['pane_id'], '%48')
        self.assertEqual(result['pane_pid'], '83939')
        self.assertEqual(result['created'], '1789892335')
        self.assertEqual(result['managed'], '1')
        self.assertEqual(result['agent'], 'codex')
        self.assertIn('-u', calls[0][0])
        self.assertNotIn('\t', calls[0][0][-1])
        self.assertEqual(calls[0][1]['encoding'], 'utf-8')

    def test_scrubbed_malformed_and_multi_pane_snapshots_fail_closed(self):
        for output, reason in [
            ('%48_83939_1789892335_1_codex_exec codex\n', 'malformed-pane'),
            ('%48|bad-pid|1789892335|1|codex|exec codex\n', 'malformed-pane'),
            ('%48|83939|1789892335|1|codex\n', 'malformed-pane'),
            ('%48|83939|1789892335|1|codex|first\n%49|20|30|1|codex|second\n', 'ambiguous-pane'),
        ]:
            with self.subTest(output=output), patch.object(identity.Collector, 'run', return_value=output):
                with self.assertRaisesRegex(identity.Unproved, reason):
                    identity.Collector().pane('worker')


class FakeCollector:
    def __init__(self, pane, rows, descriptors):
        self.snapshot = pane
        self.rows = rows
        self.descriptors = descriptors
        self.inherited = []

    def pane(self, _name):
        return copy.deepcopy(self.snapshot)

    def processes(self):
        return copy.deepcopy(self.rows)

    def rollouts(self, pid):
        return copy.deepcopy(self.descriptors if pid == 11 else self.inherited)


class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / 'sessions').mkdir()
        self.task = '01a00000-0000-0000-0000-000000000001'
        self.record = dict(schema_version=2, provider='codex', provider_task_id=None,
                           origin='cctrl', launched_by_cctrl=True, control_owner='cctrl',
                           execution_runtime='tmux', lifecycle_state='provisional',
                           name='worker', tmux_session='worker', launch_command='exec codex',
                           created_at='2026-09-20T08:18:55Z')
        self.epoch = 1789892335
        started = time.strftime('%a %b %d %H:%M:%S %Y', time.localtime(self.epoch))
        self.pane = dict(pane_id='%48', pane_pid='10', created=str(self.epoch),
                         managed='1', agent='codex', command='exec codex')
        self.rows = {10: dict(pid=10, ppid=1, started=started, command='bash'),
                     11: dict(pid=11, ppid=10, started=started, command='/bin/codex')}
        self.fd = self.rollout(self.task)
        self.collector = FakeCollector(self.pane, self.rows, [self.fd])

    def rollout(self, task, **fields):
        path = self.home / 'sessions' / ('rollout-' + task + '.jsonl')
        payload = dict(id=task, source='cli', originator='codex-tui',
                       parent_thread_id=None, forked_from_id=None, **fields)
        path.write_text(json.dumps(dict(type='session_meta', payload=payload)) + '\n')
        info = path.stat()
        return dict(path=str(path), fd=30, access='w', device=info.st_dev, inode=info.st_ino)

    def proof(self):
        return identity.prove(self.record, self.home, self.collector)

    def test_exact_open_root_with_subagent_is_proven(self):
        child = self.rollout('01a00000-0000-0000-0000-000000000002')
        path = Path(child['path'])
        value = json.loads(path.read_text())
        value['payload']['source'] = {'subagent': {'thread_spawn': {'parent_thread_id': self.task}}}
        value['payload']['parent_thread_id'] = self.task
        path.write_text(json.dumps(value))
        child['fd'] = 31
        self.collector.descriptors.append(child)
        result = self.proof()
        self.assertEqual(result['provider_task_id'], self.task)
        self.assertEqual(result['receipt']['pane_pid'], '10')

    def test_lossy_receipt_cannot_bind_even_with_exact_root_fd(self):
        self.record['launch_command'] = "exec codex '\ufffd\\200\\224'"
        self.record['initial_prompt'] = '—'
        self.pane['command'] = "exec codex '\\342\\200\\224'"
        with self.assertRaisesRegex(identity.Unproved, 'lossy-launch-command-no-exact-binding'):
            self.proof()

    def test_original_event_binding_retains_root_fd_and_generation_guards(self):
        # Exact artifact fixtures are generated independently of the damaged
        # command. Matching a saved prompt alone still fails in the prior test.
        from test_launch_event import LaunchEventTests
        fixture = LaunchEventTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        event, args, binding = fixture.load()
        self.record.update(fixture.record)
        self.record['name'] = self.record['tmux_session']
        self.collector.snapshot['command'] = fixture.live
        result = identity.prove(self.record, self.home, self.collector, (event, args, binding))
        self.assertEqual(result['provider_task_id'], self.task)
        self.assertEqual(result['launch_event_binding'], binding)
        self.collector.descriptors[0]['inode'] += 1
        with self.assertRaisesRegex(identity.Unproved, 'file-identity-mismatch'):
            identity.prove(self.record, self.home, self.collector, (event, args, binding))

    def test_inode_replacement_rejected(self):
        self.collector.descriptors[0]['inode'] += 1
        with self.assertRaisesRegex(identity.Unproved, 'file-identity-mismatch'):
            self.proof()

    def test_malformed_identity_and_header_rejected(self):
        path = Path(self.fd['path'])
        value = json.loads(path.read_text())
        value['payload']['id'] = '-' * 36
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(identity.Unproved, 'malformed-provider-task-id'):
            self.proof()
        path.write_text('[]')
        with self.assertRaisesRegex(identity.Unproved, 'malformed-rollout-header'):
            self.proof()

    def test_inherited_descriptor_rejected(self):
        self.collector.inherited = [self.fd]
        with self.assertRaisesRegex(identity.Unproved, 'inherited'):
            self.proof()

    def test_recycled_session_and_process_rejected(self):
        self.collector.snapshot['created'] = str(self.epoch + 1)
        with self.assertRaisesRegex(identity.Unproved, 'session-generation'):
            self.proof()
        self.collector.snapshot['created'] = str(self.epoch)
        self.collector.rows[10]['started'] = 'Sun Sep 20 12:00:00 2026'
        with self.assertRaisesRegex(identity.Unproved, 'process-generation'):
            self.proof()

    def test_multiple_roots_and_native_processes_rejected(self):
        second = self.rollout('01a00000-0000-0000-0000-000000000002')
        second['fd'] = 31
        self.collector.descriptors.append(second)
        with self.assertRaisesRegex(identity.Unproved, 'ambiguous-root'):
            self.proof()
        self.collector.rows[12] = dict(self.rows[11], pid=12)
        with self.assertRaisesRegex(identity.Unproved, 'ambiguous-native'):
            self.proof()

    def test_prompt_or_cwd_similarity_never_used(self):
        self.record.update(cwd='/same', initial_prompt='same prompt')
        self.collector.snapshot['command'] = 'different command same prompt /same'
        with self.assertRaisesRegex(identity.Unproved, 'launch-command'):
            self.proof()

    def test_fd_replacement_during_probe_rejected(self):
        original = self.collector.rollouts
        calls = 0

        def changing(pid):
            nonlocal calls
            values = original(pid)
            if pid == 11:
                calls += 1
                if calls > 1:
                    values[0]['fd'] += 1
            return values

        self.collector.rollouts = changing
        with self.assertRaisesRegex(identity.Unproved, 'live-evidence-changed'):
            self.proof()

    def test_lsof_numeric_identity_required(self):
        text = 'p11\nf30\naw\nD0x10\ni123\nn/tmp/rollout-root.jsonl\n'
        self.assertEqual(identity.open_rollouts(text)[0]['inode'], 123)
        with self.assertRaisesRegex(identity.Unproved, 'incomplete'):
            identity.open_rollouts(text.replace('i123\n', ''))


class RecoveryCommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, CCTRL_NO_MAIN='1', HOME=str(self.root / 'home'),
                        CCTRL_DATA_DIR=str(self.root / 'data'),
                        CCTRL_SESSION_METADATA_DIR=str(self.root / 'sessions'),
                        CCTRL_HOST_ID_FILE=str(self.root / 'host-id'),
                        CODEX_HOME=str(self.root / 'codex'))
        self.shell('_session_write_metadata fixture /repo dir /repo repo purpose prompt codex peer codex')
        self.record_path = next((self.root / 'sessions').glob('launch-*.json'))
        record = json.loads(self.record_path.read_text())
        self.launch_id = record['provisional_launch_id']
        self.task = '01a00000-0000-0000-0000-000000000001'
        self.proof_path = self.root / 'proof.json'
        self.proof_path.write_text(json.dumps(dict(
            schema_version=1, kind='terminal_identity_proof', verified=True,
            provider_task_id=self.task, expected_source_digest=identity.canonical_digest(record),
            evidence_kind='live-native-codex-writable-root-rollout',
            source_record=str(self.record_path), historical_collisions=[],
            receipt=dict(control_surface='tmux', tmux_session='fixture', pane_id='%7',
                         pane_pid='1234', wrapper_pid='1234', pane_started='Sun Sep 20 12:00:00 2026'),
            agent_pid=1235, process_started='Sun Sep 20 12:00:01 2026',
            observed_at='2026-09-20T10:00:05Z',
            rollout_descriptor=dict(path=str(self.root / 'rollout.jsonl'), fd=30,
                                    access='w', device=1, inode=123))))

    def shell(self, script, check=True):
        return subprocess.run(['bash', '-c', 'source "$0"; ' + script, str(ROOT / 'cctrl')],
                              env=self.env, capture_output=True, text=True, timeout=20, check=check)

    def recover(self, flag='', prefix='', check=True):
        return self.shell(f'''_session_terminal_identity_proof() {{
{prefix}
cat '{self.proof_path}'
}}
_session_recover_terminal_identity --launch-id {self.launch_id} --json {flag}
''', check=check)

    def test_preview_leaves_receipt_bytes_untouched(self):
        before = self.record_path.read_bytes()
        result = json.loads(self.recover().stdout)
        self.assertTrue(result['verified'])
        self.assertFalse(result['applied'])
        self.assertEqual(self.record_path.read_bytes(), before)
        self.assertEqual(list((self.root / 'sessions').glob('task-*.json')), [])

    def test_apply_keeps_terminal_owner_and_persists_proof(self):
        result = json.loads(self.recover('--apply').stdout)
        self.assertTrue(result['applied'])
        record = json.loads(Path(result['record']).read_text())
        self.assertEqual(record['control_owner'], 'cctrl')
        self.assertEqual(record['execution_runtime'], 'tmux')
        self.assertEqual(record['provider_task_id'], self.task)
        self.assertEqual(record['pane_id'], '%7')
        self.assertEqual(record['terminal_identity_proof']['provider_task_id'], self.task)
        self.assertFalse(self.record_path.exists())

    def test_changed_source_rejects_promotion(self):
        result = self.recover('--apply', f'''python3 - <<'PYFIXTURE'
import json
p={str(self.record_path)!r}
d=json.load(open(p));d['purpose']='concurrent edit'
open(p,'w').write(json.dumps(d))
PYFIXTURE''', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)['applied'])
        self.assertTrue(self.record_path.exists())
        self.assertEqual(list((self.root / 'sessions').glob('task-*.json')), [])

    def test_existing_canonical_record_is_not_overwritten(self):
        canonical = self.shell(f'_task_record_file codex "$(cat "$CCTRL_HOST_ID_FILE")" {self.task}').stdout.strip()
        Path(canonical).write_text('{"sentinel": true}')
        before = self.record_path.read_bytes()
        result = self.recover('--apply', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)['reason'], 'canonical-task-already-exists')
        self.assertEqual(Path(canonical).read_text(), '{"sentinel": true}')
        self.assertEqual(self.record_path.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
