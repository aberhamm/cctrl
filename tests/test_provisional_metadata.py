#!/usr/bin/env python3
"""Temporary launch receipts only; tmux/process probes are shell mocks."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ProvisionalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, CCTRL_NO_MAIN='1', HOME=str(self.root / 'home'),
                        CCTRL_DATA_DIR=str(self.root / 'data'),
                        CCTRL_SESSION_METADATA_DIR=str(self.root / 'sessions'),
                        CCTRL_HOST_ID_FILE=str(self.root / 'host-id'),
                        CODEX_HOME=str(self.root / 'codex'),
                        CCTRL_CODEX_TITLE_POLL_TIMEOUT='0')
        self.run_shell('_session_write_metadata fixture /repo dir /repo repo purpose prompt "codex --cd /repo" peer codex')
        self.path = next((self.root / 'sessions').glob('launch-*.json'))

    def run_shell(self, code, check=True):
        return subprocess.run(['bash', '-c', 'source "$0"; ' + code, str(ROOT / 'cctrl')],
                              env=self.env, text=True, capture_output=True, check=check, timeout=15)

    def record(self):
        return json.loads(self.path.read_text())

    def test_fresh_launch_captures_anchor_with_title_poll_disabled(self):
        self.run_shell('''tmux() { echo '%7:1234'; }
_session_tmux_host_process_started() { echo 'Sun Sep 20 12:00:00 2026'; }
_session_capture_tmux_attestation_anchor fixture
_session_update_metadata_field fixture health_status ready
''')
        record = self.record()
        self.assertEqual(record['pane_id'], '%7')
        self.assertEqual(record['pane_pid'], '1234')
        self.assertEqual(record['wrapper_pid'], '1234')
        self.assertEqual(record['pane_started'], 'Sun Sep 20 12:00:00 2026')
        self.assertEqual(record['health_status'], 'ready')
        self.assertIsNone(record['provider_task_id'])
        self.assertEqual(record['control_owner'], 'cctrl')
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_identity_and_anchor_replacement_rejected(self):
        self.run_shell('_session_update_metadata_field fixture pane_pid 1234')
        before = self.path.read_bytes()
        for field, value in [('control_owner', 'app'), ('execution_runtime', 'app-server'),
                             ('provider', 'claude'), ('pane_pid', '5555'),
                             ('control_surface', 'app'), ('tmux_session', 'other')]:
            with self.subTest(field=field):
                result = self.run_shell(f'_session_update_metadata_field fixture {field} {value}', check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.path.read_bytes(), before)

    def test_failure_before_rename_preserves_bytes_and_releases_lock(self):
        before = self.path.read_bytes()
        result = self.run_shell('CCTRL_TASK_REGISTRY_FAIL_BEFORE_RENAME=1 _session_update_metadata_field fixture health_status ready', check=False)
        self.assertEqual(result.returncode, 76)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(list((self.root / 'sessions/.task-registry-locks').glob('*.lock')), [])
        self.run_shell('_session_update_metadata_field fixture health_status ready')

    def test_concurrent_fields_survive(self):
        self.run_shell('''_session_update_metadata_field fixture health_status ready &
a=$!
_session_update_metadata_field fixture purpose updated &
b=$!
wait "$a"; wait "$b"
''')
        record = self.record()
        self.assertEqual(record['health_status'], 'ready')
        self.assertEqual(record['purpose'], 'updated')

    def proof(self, receipt, digest):
        proof = self.root / 'proof.json'
        proof.write_text(json.dumps({'verified': True, 'provider_task_id': 'thread-id',
                                     'expected_source_digest': digest,
                                     'receipt': json.loads(receipt.read_text()),
                                     'evidence_kind': 'live-native-codex-writable-root-rollout'}))
        return proof

    def test_stable_record_captures_all_anchors_in_one_registry_event(self):
        self.run_shell('_session_update_metadata_field fixture conversation_id thread-id')
        canonical = next((self.root / 'sessions').glob('task-*.json'))
        record = json.loads(canonical.read_text())
        count = len(record['registry_event_ids'])
        self.run_shell("tmux() { echo '%7:1234'; }\n_session_tmux_host_process_started() { echo started; }\n_session_capture_tmux_attestation_anchor fixture\n")
        record = json.loads(canonical.read_text())
        self.assertEqual(len(record['registry_event_ids']), count + 1)
        self.assertEqual(record['pane_id'], '%7')
        self.assertEqual(record['pane_pid'], '1234')
        self.assertEqual(record['pane_started'], 'started')
        self.assertNotIn('_terminal_anchor_receipt', record)

    def test_anchor_batch_failure_cannot_publish_partial_receipt(self):
        before = self.path.read_bytes()
        result = self.run_shell("tmux() { echo '%7:1234'; }\n_session_tmux_host_process_started() { echo started; }\nCCTRL_TASK_REGISTRY_FAIL_BEFORE_RENAME=1 _session_capture_tmux_attestation_anchor fixture\n", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.path.read_bytes(), before)
        result = self.run_shell("tmux() { echo '%7:1234'; }\n_session_tmux_host_process_started() { :; }\n_session_capture_tmux_attestation_anchor fixture\n", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.path.read_bytes(), before)

    def test_recovery_receipt_is_atomic_with_promotion(self):
        receipt = self.root / 'receipt.json'
        receipt.write_text(json.dumps({'control_surface': 'tmux', 'tmux_session': 'fixture',
                                       'pane_id': '%7', 'pane_pid': '1234', 'wrapper_pid': '1234',
                                       'pane_started': 'Sun Sep 20 12:00:00 2026'}))
        digest = self.run_shell(f'_task_registry_record_digest "{self.path}"').stdout.strip()
        before = self.path.read_bytes()
        proof = self.proof(receipt, digest)
        command = f'_task_record_promote_legacy "{self.path}" thread-id {digest} "{receipt}" "{proof}"'
        result = self.run_shell('CCTRL_TASK_REGISTRY_FAIL_BEFORE_RENAME=1 ' + command, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(list((self.root / 'sessions').glob('task-*.json')), [])
        result = self.run_shell(command)
        canonical = json.loads(Path(result.stdout.strip()).read_text())
        self.assertEqual(canonical['terminal_identity_proof'], json.loads(proof.read_text()))
        self.assertEqual(canonical['pane_id'], '%7')
        self.assertEqual(canonical['pane_pid'], '1234')
        self.assertEqual(canonical['provider_task_id'], 'thread-id')
        self.assertFalse(self.path.exists())

    def test_recovery_rejects_existing_canonical_and_mismatched_proof(self):
        receipt = self.root / 'receipt.json'
        receipt.write_text(json.dumps({'control_surface': 'tmux', 'tmux_session': 'fixture',
                                       'pane_id': '%7', 'pane_pid': '1234', 'wrapper_pid': '1234',
                                       'pane_started': 'started'}))
        digest = self.run_shell(f'_task_registry_record_digest "{self.path}"').stdout.strip()
        proof = self.proof(receipt, digest)
        command = f'_task_record_promote_legacy "{self.path}" thread-id {digest} "{receipt}" "{proof}"'
        before = self.path.read_bytes()
        data = json.loads(proof.read_text())
        data['provider_task_id'] = 'wrong-id'
        proof.write_text(json.dumps(data))
        self.assertNotEqual(self.run_shell(command, check=False).returncode, 0)
        self.assertEqual(self.path.read_bytes(), before)
        self.proof(receipt, digest)
        self.run_shell('_session_write_metadata other /repo dir /repo repo purpose prompt codex peer codex thread-id')
        canonical = next((self.root / 'sessions').glob('task-*.json'))
        canonical_before = canonical.read_bytes()
        self.assertNotEqual(self.run_shell(command, check=False).returncode, 0)
        self.assertEqual(canonical.read_bytes(), canonical_before)
        self.assertEqual(self.path.read_bytes(), before)

    def test_recovery_receipt_cannot_smuggle_owner_mutation(self):
        receipt = self.root / 'receipt.json'
        receipt.write_text(json.dumps({'control_owner': 'app'}))
        digest = self.run_shell(f'_task_registry_record_digest "{self.path}"').stdout.strip()
        before = self.path.read_bytes()
        result = self.run_shell(f'_task_record_promote_legacy "{self.path}" thread-id {digest} "{receipt}"', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.path.read_bytes(), before)

    def test_promotion_checks_receipt_digest_and_preserves_anchor(self):
        digest = self.run_shell(f'_task_registry_record_digest "{self.path}"').stdout.strip()
        self.run_shell('_session_update_metadata_field fixture pane_pid 1234')
        result = self.run_shell(f'_task_record_promote_legacy "{self.path}" thread-id {digest}', check=False)
        self.assertEqual(result.returncode, 75)
        self.assertTrue(self.path.exists())
        self.assertEqual(list((self.root / 'sessions').glob('task-*.json')), [])
        digest = self.run_shell(f'_task_registry_record_digest "{self.path}"').stdout.strip()
        result = self.run_shell(f'_task_record_promote_legacy "{self.path}" thread-id {digest}')
        canonical = json.loads(Path(result.stdout.strip()).read_text())
        self.assertEqual(canonical['provider_task_id'], 'thread-id')
        self.assertEqual(canonical['pane_pid'], '1234')
        self.assertFalse(self.path.exists())
        self.assertEqual(list((self.root / 'sessions/.task-registry-locks').glob('*.lock')), [])


if __name__ == '__main__':
    unittest.main()
