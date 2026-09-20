"""The modern secret result must survive legacy CLI fallback handling."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]

class SecretHookTests(unittest.TestCase):
    def run_hook(self,modern,legacy):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); bin=root/'bin'; bin.mkdir()
            scan=bin/'gitleaks'
            scan.write_text('#!/bin/sh\necho "$1" >> "$SCAN_TRACE"\nif [ "$1" = git ]; then exit "$MODERN_RC"; fi\nexit "$LEGACY_RC"\n');scan.chmod(0o700)
            subprocess.run(['git','init','-q',str(root)],check=True)
            env=dict(os.environ,HOME=str(root),PATH=str(bin)+':'+os.environ['PATH'],
                     SCAN_TRACE=str(root/'trace'),MODERN_RC=str(modern),LEGACY_RC=str(legacy))
            result=subprocess.run(['bash',str(ROOT/'.githooks/pre-commit')],cwd=root,env=env,capture_output=True,text=True,timeout=10)
            return result.returncode,(root/'trace').read_text().splitlines()
    def test_modern_secret_never_runs_fallback(self):
        for legacy in [0,1,2]:
            with self.subTest(legacy=legacy):self.assertEqual(self.run_hook(1,legacy),(1,['git']))
    def test_legacy_secret_blocks_when_modern_unavailable(self):
        self.assertEqual(self.run_hook(2,1),(1,['git','protect']))
    def test_clean_modern_does_not_run_fallback(self):
        self.assertEqual(self.run_hook(0,1),(0,['git']))

if __name__=='__main__':unittest.main()
