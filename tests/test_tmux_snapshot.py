import sys
from pathlib import Path
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'lib'))
from tmux_snapshot import parse_panes

class PaneSnapshotTests(unittest.TestCase):
    def test_opaque_session_name(self):
        name="victim|%48|83939|codex tabs\tunicode é\u2028quotes"
        row=parse_panes('%99|555|0|'+name+'\n')[0]
        self.assertEqual(row['session'],name)
        self.assertEqual(row['pane_id'],'%99')
        self.assertEqual(row['pane_pid'],'555')
        self.assertEqual(row['current_command'],'')
    def test_codex_command_fact(self):
        self.assertEqual(parse_panes('%48|83939|1|session\n')[0]['current_command'],'codex')
    def test_invalid_never_means_absent(self):
        for text in ['session\\t%48\\t83939\\tcmd\\tcodex\n',
                     'session_%48_83939_codex_cmd\n',
                     'session|%48|0|codex|cmd\n',
                     'session|%48|83939|codex|cmd\nmalformed\n']:
            with self.subTest(text=text), self.assertRaises(ValueError): parse_panes(text)
    def test_empty_inventory(self):
        self.assertEqual(parse_panes(''),[])

if __name__=='__main__': unittest.main()
