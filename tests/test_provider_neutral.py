import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sqlite3
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("agent_model", ROOT / "lib/agent_model.py")
model_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(model_module)


class ProviderTests(unittest.TestCase):
    def shell(self, script, *args):
        with tempfile.TemporaryDirectory() as temp:
            env = dict(os.environ, HOME=temp, CCTRL_NO_MAIN="1",
                       CCTRL_DATA_DIR=temp, CCTRL_SESSION_METADATA_DIR=temp,
                       CODEX_HOME=temp, CLAUDE_CONFIG_DIR=temp)
            return subprocess.check_output(
                ["bash", "-c", 'source "$1"; shift; ' + script,
                 str(ROOT / "cctrl"), str(ROOT / "cctrl"), *args],
                env=env, text=True, timeout=10).strip()

    def test_detached_unicode_bootstrap_is_lossless_json(self):
        with tempfile.TemporaryDirectory() as temp:
            prompt = "long handoff — café 漢字 'quotes' \\ $(literal)\nnext"
            env = dict(os.environ, HOME=temp, CCTRL_NO_MAIN='1', CCTRL_DATA_DIR=temp,
                       CCTRL_SESSION_METADATA_DIR=temp, LC_ALL='en_US.UTF-8',
                       TEST_PROMPT=prompt)
            script = r'''source "$1"
_launch_resource_guardrail() { return 0; }
_active_profile() { :; }
_resolve_agent_or_prompt() { echo codex; }
_shortcut_for_dir() { :; }
_pick_safe_session_index() { echo fixture; }
_session_write_metadata() { printf '%s' "$8" > "$HOME/receipt-command"; }
tmux() { [[ "$1" == new-session ]] && printf '%s' "$5" > "$HOME/live-command"; return 1; }
_launch_detached --force --agent codex --purpose 'unicode — purpose' "$HOME" -- "$TEST_PROMPT" >/dev/null
'''
            subprocess.run(['/bin/bash', '-c', script, 'test', str(ROOT/'cctrl')],
                           env=env, check=False, capture_output=True, timeout=10)
            command = (Path(temp)/'receipt-command').read_bytes()
            self.assertTrue(command.isascii())
            self.assertEqual(command, (Path(temp)/'live-command').read_bytes())
            encoded=subprocess.check_output(['jq','-n','--arg','command',command.decode(),
                                             '{launch_command:$command}'])
            self.assertEqual(json.loads(encoded)['launch_command'].encode(),command)
            self.assertIn(b'\\342\\200\\224',command)

    def test_model_prompt_is_not_flags(self):
        model = model_module.model_from_command
        self.assertEqual(model('codex Investigate claude --model claude-opus-4-6', 'codex'), '')
        self.assertEqual(model('claude --model claude-opus-4-6', 'codex'), '')
        self.assertEqual(model('codex --model gpt-6-astra fix --model opus', 'codex'), 'gpt-6-astra')
        self.assertEqual(model('claude --model claude-opus-4-6[1m] fix codex', 'claude'), 'opus-4-6')
        self.assertEqual(model('codex -c developer_instructions= --model opus', 'codex'), '')
        self.assertEqual(model("codex --model gpt-6-astra don't break tests", 'codex'), 'gpt-6-astra')
        self.assertEqual(model('claude -p explain --model opus', 'claude'), '')
        self.assertEqual(model('codex -m gpt-6-astra prompt --model opus', 'codex'), 'gpt-6-astra')

    def test_profiles_do_not_leak_models(self):
        script = 'printf "%s" "$1" > "$HOME/profile.json"; _resolve_model "$2" "$3" "$HOME/profile.json"'
        self.assertEqual(self.shell(script, '{"model":"legacy-model"}', 'codex', ''), '')
        self.assertEqual(self.shell(script, '{"model":"legacy-model"}', 'claude', ''), 'legacy-model')
        profile = json.dumps({'model': 'legacy', 'agents': {'codex': {'model': 'custom-opus-route'}}})
        self.assertEqual(self.shell(script, profile, 'claude', ''), '')
        self.assertEqual(self.shell(script, profile, 'codex', ''), 'custom-opus-route')
        self.assertEqual(self.shell(script, profile, 'codex', 'explicit'), 'explicit')

    def test_resource_count_never_queries_telemetry(self):
        result = self.shell('''
            _session_list() { echo forbidden >&2; return 99; }
            tmux() {
                [[ "$*" == "list-sessions -F #{@cctrl_managed}" ]] || return 99
                printf '1\n\n0\n1\n'
            }
            _active_session_count
        ''')
        self.assertEqual(result, '2')
        self.assertEqual(self.shell('tmux() { return 1; }; _active_session_count'), '0')

    def test_locked_provider_database_is_bounded_and_unknown(self):
        with tempfile.TemporaryDirectory() as temp:
            db = Path(temp) / 'state.sqlite'
            with sqlite3.connect(db) as connection:
                connection.execute('CREATE TABLE threads (id TEXT, archived INTEGER)')
                connection.execute("INSERT INTO threads VALUES ('task', 0)")
                connection.commit()
                connection.execute('BEGIN EXCLUSIVE')
                start = time.monotonic()
                result = self.shell('CCTRL_CODEX_STATE_DB="$1"; status=0; _codex_thread_is_unarchived task || status=$?; echo "$status"', str(db))
                self.assertEqual(result, '1')
                self.assertLess(time.monotonic() - start, 1)

    def test_codex_never_borrows_claude_state(self):
        result = self.shell('''
            _session_base_state() { echo idle; }
            _session_transcript_last_turn() { echo assistant; }
            tmux() { printf '0'; }
            CCTRL_STATE_DETECT_BLOCKED_DIALOG=0
            CCTRL_STATE_DETECT_UNSENT_DRAFT=0
            _session_rich_state demo codex
        ''')
        self.assertEqual(result, '-')

    def test_unresolved_prompt_cannot_mutate_stale_task(self):
        result = self.shell('''
            _session_codex_rollout_path() { :; }
            _session_metadata_field() {
                case "$2" in
                    initial_prompt) echo continue ;;
                    conversation_id) echo stale ;;
                esac
            }
            _codex_set_thread_title() { echo forbidden; }
            _codex_thread_is_unarchived() { echo forbidden; }
            status=0
            _session_codex_set_display_name demo title || status=$?
            echo "$status"
            _session_codex_thread_id demo
        ''')
        self.assertEqual(result, '2')

    def test_list_does_not_borrow_claude_model_bridge_or_recency(self):
        result = self.shell('''
            tmux() {
                if [[ "${1:-}" == "-u" ]]; then shift; fi
                case "$1" in
                    list-sessions) echo demo ;;
                    list-panes) echo /repo ;;
                    display-message|display) echo 0 ;;
                esac
            }
            _session_agent_cmd() { echo 'codex investigate claude --model claude-opus-4-6 --remote-control'; }
            _session_metadata_file() { echo "$HOME/missing"; }
            _session_codex_rollout_path() { :; }
            _session_last_active_ms() { echo 1234567890000; }
            _session_base_state() { echo idle; }
            _session_recap() { echo stale-claude-recap; }
            _session_list --json --recap
        ''')
        row = json.loads(result)[0]
        self.assertEqual(row['agent'], 'codex')
        self.assertEqual(row['model'], '?')
        self.assertEqual(row['state'], '-')
        for field in ('remote_control', 'last_active', 'recap', 'transcript'):
            self.assertIsNone(row[field], field)


if __name__ == '__main__':
    unittest.main()
