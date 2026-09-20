import copy
import json
from pathlib import Path
import shlex
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from launch_event import load_event, verify_binding

class LaunchEventTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.home=Path(self.temp.name); (self.home/'sessions').mkdir()
        self.path=self.home/'sessions'/'original.jsonl'
        self.prompt="full — café 'quoted' $(literal)\nnext"
        self.args=['cctrl','start','-d','/repo','--agent','codex','-n','purpose','-m',self.prompt]
        self.record=dict(cwd='/repo',purpose='purpose',initial_prompt=self.prompt,host='host',
                         tmux_session='worker',target='@repo',created_at='2026-09-20T08:18:55Z')
        self.prefix=('cd /repo && CCTRL_TMUX_CONTEXT=1 CCTRL_AGENT=codex CCTRL_HOST_PREFIX=host '
                     'CCTRL_SESSION_KIND=tmux CCTRL_SESSION_NAME=worker CCTRL_SESSION_TARGET=@repo '
                     'CCTRL_SESSION_PURPOSE=purpose '+str(Path(__file__).resolve().parents[1]/'cctrl')+
                     ' start --foreground --name worker --agent codex')
        self.live=self.prefix+' -m '+("'"+self.prompt.replace("'", "'\\''")+"'")
        self.record['launch_command']=self.prefix+" -m $'full �\\200\\224 damaged'"
        self.header={'type':'session_meta','payload':{'source':'vscode','originator':'Codex Desktop','id':'parent-thread'}}
        self.event={'type':'event_msg','payload':{'type':'item_completed','thread_id':'parent-thread',
            'started_at_ms':1789892334500,'completed_at_ms':1789892336000,
            'item':{'id':'exec-exact','type':'CommandExecution','source':'unified_exec_startup',
                    'status':'completed','exit_code':0,'process_id':'123','stderr':'',
                    'stdout':'✓ detached session started — @repo\n  Attach:  cctrl --host host session attach worker\n',
                    'command':['/bin/zsh','-lc',' '.join("'"+arg.replace("'", "'\\''")+"'" for arg in self.args)]}}}
    def load(self,extra=None):
        self.path.write_text('\n'.join(json.dumps(x) for x in [self.header,self.event]+(extra or []))+'\n')
        return load_event(self.path,'exec-exact',self.home)
    def test_complete_artifact_exact_live_bootstrap(self):
        event,args,evidence=self.load()
        verify_binding(self.record,self.live,event,args)
        self.assertEqual(args,self.args); self.assertEqual(evidence['event_id'],'exec-exact')
        self.assertEqual(len(evidence['header_sha256']),64)
    def test_reject_event_provenance_failure_duplicate_and_shell_expansion(self):
        for key,value in [('status','failed'),('exit_code',1),('source','other')]:
            original=copy.deepcopy(self.event)
            self.event['payload']['item'][key]=value
            with self.subTest(key=key), self.assertRaises(ValueError): self.load()
            self.event=original
        with self.assertRaises(ValueError): self.load([self.event])
        self.event['payload']['thread_id']='wrong'
        with self.assertRaises(ValueError): self.load()
        self.event['payload']['thread_id']='parent-thread'
        self.event['payload']['item']['command'][2]+='; echo injected'
        with self.assertRaises(ValueError): self.load()
    def test_reject_changed_scaffold_prompt_tail_and_generation(self):
        event,args,_=self.load()
        for live in [self.live+' extra',self.live.replace('--foreground','--other'),
                     self.prefix+' -m '+("'"+(self.prompt+'different').replace("'", "'\\''")+"'")]:
            with self.subTest(live=live[:20]),self.assertRaises(ValueError):
                verify_binding(self.record,live,event,args)
        event['payload']['started_at_ms']+=10000
        with self.assertRaises(ValueError): verify_binding(self.record,self.live,event,args)
    def test_reject_wrong_session_output_and_loss_outside_prompt(self):
        event,args,_=self.load()
        event['payload']['item']['stdout']=event['payload']['item']['stdout'].replace('attach worker','attach other')
        with self.assertRaises(ValueError): verify_binding(self.record,self.live,event,args)
        event,args,_=self.load()
        self.record['launch_command']=self.record['launch_command'].replace('cd /repo','cd /re�po')
        with self.assertRaises(ValueError): verify_binding(self.record,self.live,event,args)
    def test_lossy_original_and_symlink_are_not_evidence(self):
        self.event['payload']['item']['command'][2]+='�'
        with self.assertRaises(ValueError): self.load()
        other=self.path.with_name('linked.jsonl');other.symlink_to(self.path)
        with self.assertRaises(ValueError): load_event(other,'exec-exact',self.home)

if __name__=='__main__': unittest.main()
