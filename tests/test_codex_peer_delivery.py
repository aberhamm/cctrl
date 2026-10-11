import json
import io
from contextlib import redirect_stdout
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from codex_peer_delivery import deliver, operation_deadline, OperationTimeout, main
from codex_app_server import discover_runtime, Runtime, AdapterError

class Fake:
    def __init__(self, kind='idle'):
        self.thread = {'id':'thread', 'cwd':'/tmp/project', 'status':{'type':kind}, 'turns':[]}
        self.calls=[]
        self.fail=False
    def thread_read(self, *args, **kwargs):
        return {'thread':self.thread}
    def request(self, method, params):
        self.calls.append((method, params))
        self.thread['status']={'type':'idle'}
        return {'thread':self.thread}
    def turn_start(self, thread_id, inputs, **options):
        self.calls.append(('turn/start', {'threadId':thread_id, 'input':inputs, **options}))
        if self.fail:
            raise TimeoutError('lost response')
        return {'turn':{'id':'turn'}}

class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.receipt=Path(self.tmp.name)/'receipt.json'
        self.client=Fake()
    def tearDown(self):
        self.tmp.cleanup()
    def run_delivery(self, **overrides):
        params=dict(thread_id='thread', cwd='/tmp/project', body='wake mailbox', attempt_id='attempt', receipt_file=str(self.receipt), app_owned=True)
        params.update(overrides)
        return deliver(self.client, **params)
    def test_busy_and_unknown_defer_without_mutation(self):
        for kind in ['active','systemError',None]:
            self.client.thread['status']={'type':kind}
            self.assertEqual('deferred', self.run_delivery()['status'])
        self.assertEqual([],self.client.calls)
    def test_modal_approval_and_archived_refused(self):
        self.client.thread['status']={'type':'active','activeFlags':['waitingOnApproval','waitingOnUserInput']}
        self.assertEqual('deferred', self.run_delivery()['status'])
        self.client.thread['status']={'type':'idle'}
        self.client.thread['archived']=True
        self.assertEqual('failed', self.run_delivery()['status'])
        self.assertEqual([],self.client.calls)
    def test_dry_run_does_not_resume_or_write(self):
        self.client.thread['status']={'type':'notLoaded'}
        self.assertEqual('deferred',self.run_delivery(dry_run=True)['status'])
        self.assertEqual([],self.client.calls)
        self.assertFalse(self.receipt.exists())
    def test_locked_loaded_thread_owned_by_connected_server(self):
        lockdir=Path(self.tmp.name)/'thread-writer-locks'
        lockdir.mkdir()
        (lockdir/'thread.lock').touch()
        self.client.request=lambda *args: {'data':['thread']}
        self.assertEqual('verified', self.run_delivery(verify_only=True,codex_home=self.tmp.name)['status'])
    def test_locked_other_or_malformed_loaded_list_rejected(self):
        lockdir=Path(self.tmp.name)/'thread-writer-locks'
        lockdir.mkdir()
        (lockdir/'thread.lock').touch()
        for result in [{'data':['other']},{'data':{}},None]:
            self.client.request=lambda *args: result
            self.assertEqual('failed', self.run_delivery(codex_home=self.tmp.name)['status'])
        self.assertFalse(self.receipt.exists())
    def test_invalid_home_rejected(self):
        self.assertEqual('failed', self.run_delivery(codex_home='relative')['status'])
    def test_exact_id_and_cwd(self):
        self.client.thread['id']='different'
        self.assertEqual('failed',self.run_delivery()['status'])
        self.client.thread['id']='thread'
        self.assertEqual('failed',self.run_delivery(cwd='/tmp/other')['status'])
    def test_defaults_omitted_and_receipt_written(self):
        self.client.thread['status']={'type':'notLoaded'}
        self.assertEqual('accepted', self.run_delivery()['status'])
        self.assertEqual(('thread/resume',{'threadId':'thread','excludeTurns':True}),self.client.calls[0])
        self.assertEqual({'threadId','input'},set(self.client.calls[1][1]))
        self.assertEqual('accepted', json.loads(self.receipt.read_text())['outcome'])
    def test_timeout_never_retried(self):
        self.client.fail=True
        self.assertEqual('ambiguous',self.run_delivery()['status'])
        self.assertEqual('ambiguous',self.run_delivery()['status'])
        self.assertEqual(1,len(self.client.calls))
    def test_user_marker_reconciles_without_mutation(self):
        self.client.fail=True
        self.run_delivery()
        self.client.calls=[]
        self.client.thread['turns']=[{'items':[{'type':'userMessage','content':[{'type':'text','text':'[cctrl-delivery:attempt]\nwake mailbox'}]}]}]
        self.assertEqual('accepted',self.run_delivery()['status'])
        self.assertEqual([],self.client.calls)
    def test_paginated_history_first_delivery_and_verify(self):
        original=self.client.thread_read
        def read(thread_id, include_turns=False):
            if include_turns:
                raise AdapterError(72,'request','server error',details={'code':-32601,'message':'list_turns is not supported yet'})
            return original(thread_id,include_turns=include_turns)
        self.client.thread_read=read
        self.assertEqual('verified',self.run_delivery(verify_only=True)['status'])
        self.assertEqual('accepted',self.run_delivery()['status'])
        self.assertEqual('accepted',self.run_delivery()['status'])
        self.assertEqual(1,len(self.client.calls))
    def test_paginated_history_ambiguous_does_not_retry(self):
        self.client.fail=True
        self.run_delivery()
        original=self.client.thread_read
        def read(thread_id, include_turns=False):
            if include_turns:
                raise AdapterError(72,'request','server error',details={'code':-32601,'message':'list_turns is not supported yet'})
            return original(thread_id,include_turns=include_turns)
        self.client.thread_read=read
        result=self.run_delivery()
        self.assertEqual('ambiguous',result['status'])
        self.assertEqual(-32601,result['error']['details']['code'])
        self.assertEqual(1,len(self.client.calls))
    def test_agent_echo_does_not_reconcile(self):
        self.client.thread['turns']=[{'items':[{'type':'agentMessage','text':'[cctrl-delivery:attempt]'}]}]
        self.assertEqual('accepted',self.run_delivery()['status'])
        self.assertEqual(1,len(self.client.calls))
    def test_ownership_required(self):
        self.assertEqual('failed',self.run_delivery(app_owned=False)['status'])
        self.assertEqual([], self.client.calls)
    def test_malformed_response_ambiguous(self):
        self.client.turn_start=lambda *args,**kwargs: {'turn':{}}
        self.assertEqual('ambiguous',self.run_delivery()['status'])
    def test_whole_deadline_during_mutation_is_ambiguous(self):
        self.client.turn_start=lambda *args,**kwargs: time.sleep(1)
        with operation_deadline(0.02):
            result=self.run_delivery()
        self.assertEqual('ambiguous',result['status'])
        self.assertEqual('overall-operation',result['error']['phase'])
        self.assertEqual('ambiguous',json.loads(self.receipt.read_text())['outcome'])
    def test_whole_deadline_before_submission_is_failed(self):
        self.client.thread_read=lambda *args,**kwargs: time.sleep(1)
        with operation_deadline(0.02):
            result=self.run_delivery()
        self.assertEqual('failed',result['status'])
        self.assertFalse(self.receipt.exists())
    def test_deadline_budget_cannot_exceed_mailbox_budget(self):
        for seconds in (0,-1,5,float('nan')):
            with self.assertRaises(ValueError):
                with operation_deadline(seconds): pass
    def test_changed_body_rejected(self):
        self.run_delivery()
        self.assertEqual('failed',self.run_delivery(body='changed')['status'])

class CleanupTests(unittest.TestCase):
    def test_cleanup_timeout_preserves_submission_outcome(self):
        class Client:
            def __init__(self,*args,**kwargs): pass
            def __enter__(self): return self
            def initialize(self): return {'codexHome':'/tmp/codex','userAgent':'codex/1.2.3'}
            def __exit__(self,*args): raise OperationTimeout('cleanup deadline')
        args=['helper','--thread-id','thread','--expected-cwd','/tmp/project','--verify-only','--app-owned']
        for outcome in ('accepted','ambiguous'):
            output=io.StringIO()
            with patch.object(sys,'argv',args), patch('codex_peer_delivery.discover_runtime',return_value=Runtime('/fake','fake','1.2.3')), patch('codex_peer_delivery.AppServerClient',Client), patch('codex_peer_delivery.deliver',return_value={'status':outcome}), redirect_stdout(output):
                self.assertEqual(0,main())
            result=json.loads(output.getvalue())
            self.assertEqual(outcome,result['status'])
            self.assertEqual('overall-operation',result['cleanup_error']['phase'])

class RuntimeTests(unittest.TestCase):
    def test_managed_current_precedes_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)/'packages/app-server-daemon'
            release=root/'releases/test'
            (release/'bin').mkdir(parents=True)
            (release/'bin/codex').touch()
            (release/'codex-package.json').write_text(json.dumps({'layoutVersion':1,'version':'1.2.3','variant':'codex','entrypoint':'bin/codex'}))
            (root/'current').symlink_to(release)
            with patch.dict(os.environ,{'CODEX_HOME':tmp}), patch('codex_app_server._validated_runtime',return_value=Runtime(str(release/'bin/codex'),'managed-desktop-package','1.2.3')):
                self.assertEqual('managed-desktop-package',discover_runtime().discovery_source)
                (release/'codex-package.json').write_text('{}')
                with self.assertRaises(AdapterError): discover_runtime()
    def test_invalid_explicit_override_fails_closed(self):
        with patch('codex_app_server._validated_runtime',return_value=None):
            with self.assertRaises(AdapterError): discover_runtime('/invalid')

if __name__=='__main__': unittest.main()
