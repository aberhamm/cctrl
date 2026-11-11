"""The pre-commit hook must run the public-repo hygiene check on staged content."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]


class PublicHygieneHookTests(unittest.TestCase):
    def run_hook(self, content):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bindir = root / 'bin'; bindir.mkdir()
            scan = bindir / 'gitleaks'
            scan.write_text('#!/bin/sh\nexit 0\n'); scan.chmod(0o700)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / 'tests').mkdir()
            for name in ('check-public-hygiene.py', 'public-hygiene-allowlist.txt'):
                shutil.copy(ROOT / 'tests' / name, root / 'tests' / name)
            (root / 'doc.md').write_text(content)
            subprocess.run(['git', 'add', 'doc.md'], cwd=root, check=True)
            env = dict(os.environ, HOME=str(root), PATH=str(bindir) + ':' + os.environ['PATH'])
            result = subprocess.run(['bash', str(ROOT / '.githooks/pre-commit')], cwd=root, env=env,
                                    capture_output=True, text=True, timeout=20)
            return result.returncode, result.stderr

    def test_staged_private_detail_blocks(self):
        # Assembled at runtime so this file never holds a private value.
        rc, err = self.run_hook('db at http://' + '10.' + '1.2.3:5984\n')
        self.assertEqual(rc, 1, err)
        self.assertIn('public-repo hygiene check failed', err)
        self.assertNotIn('10.' + '1.2.3', err)

    def test_clean_staged_content_passes(self):
        rc, err = self.run_hook('docs use 192.0.2.10 and ~/dev\n')
        self.assertEqual(rc, 0, err)


if __name__ == '__main__':
    unittest.main()
