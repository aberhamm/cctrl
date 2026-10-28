"""Focused app peer binding tests; no live tmux/app server is touched."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class AppPeerShellTests(unittest.TestCase):
    def run_shell(self, code):
        with tempfile.TemporaryDirectory(prefix='cctrl-app-peer-') as scratch:
            env = dict(os.environ, CCTRL_NO_MAIN='1', CCTRL_DATA_DIR=scratch,
                       CCTRL_SESSION_METADATA_DIR=scratch+'/sessions')
            for key in ('TMUX', 'CODEX_THREAD_ID', 'CODEX_SESSION_ID', 'CCTRL_PEER'):
                env.pop(key, None)
            return subprocess.run(['bash', '-c', 'source "$1"; SCRIPT_DIR="$2"; '+code,
                                   'test', str(ROOT/'cctrl'), str(ROOT)], env=env,
                                  text=True, capture_output=True)

    def test_exact_sender_binding_and_unknown_owner(self):
        result=self.run_shell('''
_peer_app_owned_verify() { return 0; }
p='{"name":"a","provider_task_id":"thread-a","dir":"/tmp"}'
CODEX_THREAD_ID=thread-b
if _peer_sender_binding_mismatch a "$p" '' false false; then exit 10; fi
CODEX_THREAD_ID=thread-a; unset CODEX_SESSION_ID
_peer_sender_binding_mismatch a "$p" '' false false
_peer_app_owned_verify() { return 1; }
if _peer_sender_binding_mismatch a "$p" '' false false; then exit 11; fi
''')
        self.assertEqual(result.returncode,0,result.stderr)

    def test_registration_whitelist_and_immutable_identity(self):
        result=self.run_shell('''
_peer_app_owned_verify() { return 0; }
_peer_derived_json() { printf '%s' '{"peers":[],"skipped":false}'; }
_peer_cmd_register a --thread-id thread-a --dir /tmp --agent codex
_peer_all_json_build | jq -e '.peers[0].provider_task_id=="thread-a" and (.peers[0].capabilities|index("app-server")!=null)'
if _peer_cmd_register a --thread-id thread-b --dir /tmp --agent codex; then exit 10; fi
''')
        self.assertEqual(result.returncode,0,result.stderr)

    def test_release_preserves_identity_and_created_stamp(self):
        result=self.run_shell('''
_peer_init
printf '%s' '{"a":{"name":"a","session":"old","created_at":"2026-01-01T00:00:00Z","capabilities":["tmux"]}}' > "$PEERS_FILE"
r='{"peer":"a","provider_task_id":"thread-a","cwd":"/tmp"}'
_peer_preserve_app_binding old "$r"
jq -e '.a.provider_task_id=="thread-a" and .a.created_at=="2026-01-01T00:00:00Z" and (.a|has("session")|not)' "$PEERS_FILE"
''')
        self.assertEqual(result.returncode,0,result.stderr)

    def test_delivery_persists_attempt_before_bounded_helper(self):
        result=self.run_shell('''
_peer_init
_peer_app_owned_verify() { return 0; }
_mailbox_rewrite_json_locked() { printf '%s' "$1" > "$MESSAGES_FILE"; }
python3() {
    jq -e '.[0].app_delivery_attempt | test("^[0-9a-f]{32}$")' "$MESSAGES_FILE" >/dev/null || return 10
    printf '%s' '{"status":"accepted","turn_id":"turn-a"}'
}
PEER_DELIVER_PEER=a; PEER_DELIVER_QUEUED=1; PEER_DELIVER_DRY_RUN=false; PEER_DELIVER_INLINE=false
p='{"name":"a","provider_task_id":"thread-a","dir":"/tmp"}'
m='[{"id":"msg-a","to":"a","from":"user","status":"queued","created_at":"2026-01-01T00:00:00Z"}]'
_peer_app_deliver_locked "$p" "$m" 'Read your mailbox' '' | jq -e '.status=="nudged" and .submitted==true'
jq -e '.[0] | has("app_delivery_attempt") | not' "$MESSAGES_FILE"
''')
        self.assertEqual(result.returncode,0,result.stderr)

    def test_provider_pin_survives_name_reuse(self):
        result=self.run_shell('''
g="$(_peer_guard_defs)"
printf '%s' '{"recipient_provider_task_id":"old-thread","created_at":"2026-10-11T00:00:00Z"}' | jq -e "$g"'deliverable_provider("";"new-thread") | not'
printf '%s' '{"recipient_provider_task_id":"same-thread","created_at":"2026-10-11T00:00:00Z"}' | jq -e "$g"'deliverable_provider("2026-10-11T00:00:00Z";"same-thread")'
''')
        self.assertEqual(result.returncode,0,result.stderr)

    def test_say_no_submit_queues_without_delivery(self):
        result=self.run_shell('''
_peer_resolve_json() { printf '%s' '{"name":"a","capabilities":["app-server"]}'; }
_peer_cmd_send() { printf '%s\\n' "$@"; }
_peer_cmd_say a --no-submit --json -- 'hello body' > "$PEER_DATA_DIR/args"
! rg -- '--deliver' "$PEER_DATA_DIR/args"
rg -- 'hello body' "$PEER_DATA_DIR/args"
''')
        self.assertEqual(result.returncode,0,result.stderr)

    def test_ambiguous_retry_preserves_body_and_covered_messages(self):
        result=self.run_shell('''
_peer_init
_peer_app_owned_verify() { return 0; }
_mailbox_rewrite_json_locked() { printf '%s' "$1" > "$MESSAGES_FILE"; }
python3() { printf '%s' '{"status":"ambiguous","reason":"timeout"}'; }
PEER_DELIVER_PEER=a; PEER_DELIVER_QUEUED=1; PEER_DELIVER_DRY_RUN=false; PEER_DELIVER_INLINE=false
p='{"name":"a","provider_task_id":"thread-a","dir":"/tmp"}'
m='[{"id":"old","to":"a","status":"queued"}]'
_peer_app_deliver_locked "$p" "$m" original '' || true
m="$(jq '. + [{id:"new",to:"a",status:"queued"}]' "$MESSAGES_FILE")"
_peer_app_deliver_locked "$p" "$m" changed '' || true
jq -e '.[0].app_delivery_attempt != null and .[1].app_delivery_attempt == null' "$MESSAGES_FILE"
a="$(jq -r '.[0].app_delivery_attempt' "$MESSAGES_FILE")"
[[ "$(cat "$PEER_DATA_DIR/app-delivery/$a.body")" == original ]]
''')
        self.assertEqual(result.returncode,0,result.stderr)

    def test_watch_retries_deferred_app_peer_and_reports_live(self):
        result=self.run_shell('''
_peer_init
# Plan 110 D2: app peers are pushed to only when the bell is enabled for them.
printf '%s' '{"enabled":true,"peers":["a"],"roles":[],"deliver_default_roles":[]}' > "$PEER_DATA_DIR/doorbell.json"
_peer_app_owned_verify() { return 0; }
p='{"name":"a","provider_task_id":"thread-a","dir":"/tmp","capabilities":["mailbox","app-server"]}'
_peer_resolve_json() { printf '%s' "$p"; }
[[ "$(_peer_reachability_class "$p")" == live ]]
_mailbox_rewrite_json_locked() { printf '%s' "$1" > "$MESSAGES_FILE"; }
_mailbox_read_json() { cat "$MESSAGES_FILE"; }
python3() { printf '%s' '{"status":"deferred","reason":"busy"}'; }
m='[{"id":"msg-a","to":"a","status":"queued"}]'
_peer_orchestrate_recipients_locked "$m" '["a"]' false false false false 3 60 true
jq -e '.[0].status=="deferred"' <<< "$PEER_ORCH_RESULTS"
python3() { printf '%s' '{"status":"accepted","turn_id":"turn-a"}'; }
_peer_orchestrate_recipients_locked "$PEER_ORCH_MESSAGES" '["a"]' false false true false 3 60 true
jq -e '.[0].status=="nudged"' <<< "$PEER_ORCH_RESULTS"
_peer_app_owned_verify() { return 1; }
[[ "$(_peer_reachability_class "$p")" == unreachable ]]
''')
        self.assertEqual(result.returncode,0,result.stderr)

    def test_app_peer_not_doorbell_enabled_is_queued_only(self):
        # Plan 110 D2: no doorbell.json (or a bell for someone else) means no
        # app wake-up at all: the helper is never run, the mail stays queued.
        result=self.run_shell('''
_peer_init
_peer_app_owned_verify() { return 0; }
p='{"name":"a","provider_task_id":"thread-a","dir":"/tmp","capabilities":["mailbox","app-server"]}'
_peer_resolve_json() { printf '%s' "$p"; }
_mailbox_rewrite_json_locked() { printf '%s' "$1" > "$MESSAGES_FILE"; }
_mailbox_read_json() { cat "$MESSAGES_FILE"; }
python3() { echo CALLED >> "$PEER_DATA_DIR/helper.log"; printf '%s' '{"status":"accepted"}'; }
m='[{"id":"msg-a","to":"a","status":"queued"}]'
for bell in '' '{"enabled":true,"peers":["someone-else"],"roles":[]}'; do
    rm -f "$PEER_DATA_DIR/doorbell.json"
    [[ -n "$bell" ]] && printf '%s' "$bell" > "$PEER_DATA_DIR/doorbell.json"
    _peer_orchestrate_recipients_locked "$m" '["a"]' false false true false 3 60 true
    jq -e '.[0].status=="queued-only" and .[0].reason=="recipient-not-doorbell-enabled"' <<< "$PEER_ORCH_RESULTS"
done
[[ ! -e "$PEER_DATA_DIR/helper.log" ]]
''')
        self.assertEqual(result.returncode,0,result.stderr+result.stdout)

    def test_real_send_deliver_discovers_app_sender_without_as(self):
        result=self.run_shell('''
_peer_app_owned_verify() { return 0; }
_peer_derived_json() { printf '%s' '{"peers":[],"skipped":false}'; }
_peer_cmd_register a --thread-id thread-a --dir /tmp --agent codex
_peer_cmd_register b --thread-id thread-b --dir /tmp --agent codex
CODEX_THREAD_ID=thread-a
python3() { printf '%s' '{"status":"accepted","turn_id":"turn-a"}'; }
_peer_cmd_send b --deliver --json -- 'hello' > "$PEER_DATA_DIR/send-output"
jq -s -e '.[0].from=="a" and .[0].recipient_provider_task_id=="thread-b"' "$MESSAGES_FILE"
''')
        self.assertEqual(result.returncode,0,result.stderr)

    def test_inline_app_delivery_never_submits_or_mutates_pending_attempt(self):
        result=self.run_shell('''
_peer_init
python3() { exit 99; }
p='{"name":"a","provider_task_id":"thread-a","dir":"/tmp","capabilities":["app-server"]}'
m='[{"id":"old","to":"a","status":"queued","app_delivery_attempt":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"id":"new","to":"a","status":"queued"}]'
printf '%s' "$m" > "$MESSAGES_FILE"
_peer_deliver_one_locked "$p" "$m" false true false false new | jq -e '.status=="deferred" and .reason=="app-inline-unsupported" and .submitted==false'
[[ "$(cat "$MESSAGES_FILE")" == "$m" ]]
''')
        self.assertEqual(result.returncode,0,result.stderr)

    def test_malformed_helper_keeps_attempt_ambiguous(self):
        result=self.run_shell('''
_peer_init
_peer_app_owned_verify() { return 0; }
_mailbox_rewrite_json_locked() { printf '%s' "$1" > "$MESSAGES_FILE"; }
python3() { printf '%s' 'not-json'; return 1; }
PEER_DELIVER_PEER=a; PEER_DELIVER_QUEUED=1; PEER_DELIVER_DRY_RUN=false; PEER_DELIVER_INLINE=false
p='{"name":"a","provider_task_id":"thread-a","dir":"/tmp"}'
m='[{"id":"old","to":"a","status":"queued"}]'
_peer_app_deliver_locked "$p" "$m" body '' > "$PEER_DATA_DIR/result" || true
jq -e '.status=="ambiguous"' "$PEER_DATA_DIR/result"
jq -e '.[0].app_delivery_attempt != null and .[0].status=="queued"' "$MESSAGES_FILE"
''')
        self.assertEqual(result.returncode,0,result.stderr)

if __name__=='__main__': unittest.main()
