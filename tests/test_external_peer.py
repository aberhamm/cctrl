"""Public CLI/MCP regressions for external-session identity and route guidance."""
import concurrent.futures
import base64
import json
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import no_real_tmux  # noqa: F401 -- refuse all live tmux access outside the harness

ROOT = Path(os.environ.get("CCTRL_TEST_REPO", Path(__file__).resolve().parents[1]))
SPEC = importlib.util.spec_from_file_location("peer_identity", Path(__file__).resolve().parents[1] / "lib/peer_identity.py")
IDENTITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IDENTITY)


class ExternalPeerTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="cctrl-external-peer-")
        self.addCleanup(self.scratch.cleanup)
        self.home = Path(self.scratch.name)
        self.data = self.home / "data"
        self.env = dict(PATH=os.environ["PATH"], HOME=str(self.home), LANG="en_US.UTF-8",
                        XDG_CONFIG_HOME=str(self.home / "config"),
                        XDG_STATE_HOME=str(self.home / "state"),
                        CCTRL_DATA_DIR=str(self.data),
                        CCTRL_HOST_ID_FILE=str(self.data / "host-id"),
                        CCTRL_PEER_SEAL_KEY_FILE=str(self.home / "seal.key"),
                        CCTRL_SESSION_METADATA_DIR=str(self.home / "sessions"),
                        CLAUDE_CONFIG_DIR=str(self.home / "claude"), CODEX_HOME=str(self.home / "codex"))

    def run_cli(self, *args, identity=None, stdin=None, check=True):
        result = subprocess.run([str(ROOT / "cctrl"), *args], env={**self.env, **(identity or {})},
                                input=stdin, text=True, capture_output=True, timeout=30)
        if check:
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        return result

    def cli(self, *args, **kwargs):
        return json.loads(self.run_cli(*args, **kwargs).stdout)

    def manager(self):
        self.run_cli("peer", "register", "manager", "--agent", "codex")

    def test_outside_sessions_have_stable_distinct_replyable_identities(self):
        for variable, provider in [("CODEX_THREAD_ID", "codex"), ("CLAUDE_CODE_SESSION_ID", "claude")]:
            with self.subTest(provider=provider):
                first = self.cli("peer", "whoami", "--json", identity={variable: "native-a"})
                again = self.cli("peer", "whoami", "--json", identity={variable: "native-a"})
                other = self.cli("peer", "whoami", "--json", identity={variable: "native-b"})
                self.assertEqual(first, again)
                self.assertNotEqual(first["name"], other["name"])
                self.assertEqual(provider, first["agent"])
                self.assertEqual("native-a", first["external_identity"]["session_id"])
                self.assertEqual(["mailbox"], first["capabilities"])
                self.assertNotIn("provider_task_id", first)
                self.assertEqual("external-session", first["source"])

    def test_first_send_needs_no_registration_and_supports_reply_receive_ack(self):
        self.manager()
        session = {"CODEX_THREAD_ID": "outside-chat"}
        sent = self.cli("peer", "send", "manager", "--deliver", "--json", "--", "status report", identity=session)
        self.assertNotEqual("send-failed", sent["outcome"])
        sender = sent["from"]
        self.assertTrue(sender.startswith("external-codex-"), sent)
        received = self.cli("peer", "recv", "--as", "manager", "--json")
        message = received["message"]
        self.assertEqual(sender, message["sender"]["name"])
        self.assertEqual("outside-chat", message["sender"]["external_identity"]["session_id"])
        self.cli("peer", "reply", message["id"], "--as", "manager", "--no-deliver", "--json", "--", "received")
        answer = self.cli("peer", "recv", "--json", identity=session)["message"]
        self.assertEqual("received", answer["body"])
        self.cli("peer", "ack", answer["id"], "--json", identity=session)
        counts = self.cli("peer", "check", "--json", identity=session)
        self.assertEqual(0, counts["delivered_unacked"])

    def test_external_binding_cannot_be_used_by_a_different_session(self):
        own = self.cli("peer", "whoami", "--json", identity={"CODEX_THREAD_ID": "own"})
        self.manager()
        for verb in [("whoami",), ("overview",), ("recv",), ("send", "manager", "--", "wrong")]:
            # Flags precede the send body's --.
            args = ["peer", *verb]
            i = args.index("--") if "--" in args else len(args)
            args[i:i] = ["--as", own["name"], "--json"]
            result = self.run_cli(*args, identity={"CODEX_THREAD_ID": "other"}, check=False)
            self.assertNotEqual(0, result.returncode, result.stdout)
        self.assertFalse((self.data / "messages.jsonl").exists() and (self.data / "messages.jsonl").read_text().strip())

    def test_conflicting_identity_fails_without_registering_a_peer(self):
        result = self.run_cli("peer", "identify", "--json", identity={"CODEX_THREAD_ID": "one", "CODEX_SESSION_ID": "two"}, check=False)
        self.assertEqual(66, result.returncode)
        self.assertIn("disagree", result.stderr)
        self.assertEqual({}, json.loads((self.data / "peers.json").read_text()))

    def test_explicit_real_session_claim_is_available_when_environment_is_missing(self):
        own = self.cli("peer", "identify", "--agent", "claude", "--session-id", "actual-native-id", "--json")
        self.assertEqual("explicit-session-claimed", own["external_identity"]["basis"])
        self.assertEqual("actual-native-id", own["external_identity"]["session_id"])
        self.assertNotIn("provider_task_id", own)

    def test_route_guidance_prefers_same_provider_but_does_not_send(self):
        self.manager()
        self.run_cli("peer", "register", "claude-peer", "--agent", "claude")
        own = {"CODEX_THREAD_ID": "outside"}
        same = self.cli("peer", "route", "manager", "--json", identity=own)
        self.assertEqual("native-if-addressable", same["preferred_transport"])
        self.assertFalse(same["sent"])
        self.assertTrue(same["native"]["requires_exact_runtime_target"])
        self.assertIn("Independent Codex CLI", same["native"]["note"])
        cross = self.cli("peer", "route", "claude-peer", "--json", identity=own)
        self.assertEqual("native-bridge-if-available", cross["preferred_transport"])
        self.assertTrue(cross["bridge"]["local_only"])
        self.assertEqual(["cctrl", "bridge", "list", "--json"], cross["bridge"]["discovery"])
        self.assertIsNone(cross["native"])
        self.assertFalse((self.data / "messages.jsonl").exists())

    def test_unconfigured_mcp_initializes_and_binds_on_first_tool_use(self):
        self.manager()
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "route_message", "arguments": {"to": "manager"}}},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "send_message", "arguments": {"to": "manager", "body": "outside status"}}},
        ]
        out = self.run_cli("peer", "mcp", identity={"CODEX_THREAD_ID": "outside-mcp"},
                           stdin="".join(json.dumps(r) + "\n" for r in requests))
        replies = [json.loads(line) for line in out.stdout.splitlines()]
        self.assertIn("protocolVersion", replies[0]["result"])
        for reply in replies[1:]:
            self.assertTrue(reply["result"]["structuredContent"]["ok"], reply)
        self.assertEqual("native-if-addressable", replies[1]["result"]["structuredContent"]["data"]["preferred_transport"])
        queued = json.loads((self.data / "messages.jsonl").read_text())
        self.assertEqual("outside-mcp", queued["sender"]["external_identity"]["session_id"])

    def test_concurrent_first_registration_preserves_all_sessions(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            names = list(pool.map(lambda n: self.cli("peer", "whoami", "--json", identity={"CODEX_THREAD_ID": f"thread-{n}"})["name"], range(4)))
        stored = json.loads((self.data / "peers.json").read_text())
        self.assertEqual(set(names), set(stored))
        self.assertEqual(0o600, (self.data / "peers.json").stat().st_mode & 0o777)

    def test_remote_origin_import_keeps_reply_address_without_granting_ownership(self):
        own = self.cli("peer", "whoami", "--json", identity={"CODEX_THREAD_ID": "outside-origin"})
        peer = {key: own[key] for key in ("name", "agent", "external_identity")}
        peer["host"] = "origin"
        encoded = base64.b64encode(json.dumps(peer).encode()).decode()
        remote_data = self.home / "remote-data"
        remote_env = {"CCTRL_DATA_DIR": str(remote_data), "CCTRL_HOST_ID_FILE": str(remote_data / "host-id"),
                      "CCTRL_HOST_PREFIX": "remote", "CCTRL_ORIGIN_EXTERNAL": encoded}
        self.run_cli("peer", "register", "manager", "--agent", "codex", identity=remote_env)
        sent = self.cli("peer", "send", "manager", "--as", own["name"], "--sender-host", "origin", "--deliver", "--json", "--", "remote status", identity=remote_env)
        self.assertNotEqual("send-failed", sent["outcome"])
        stored = json.loads((remote_data / "peers.json").read_text())[own["name"]]
        self.assertEqual("origin", stored["host"])
        self.assertEqual("remote-session-claimed", stored["external_identity"]["basis"])
        self.assertEqual(["mailbox"], stored["capabilities"])
        self.assertNotIn("provider_task_id", stored)
        message = json.loads((remote_data / "messages.jsonl").read_text())
        self.assertEqual("origin", message["sender"]["host"])
        # The imported sender is a reply route, not an identity another local
        # chat can claim by passing its public peer name.
        bad = self.run_cli("peer", "send", "manager", "--as", own["name"], "--json", "--", "forged", identity={**remote_env, "CCTRL_ORIGIN_EXTERNAL": "", "CODEX_THREAD_ID": "other"}, check=False)
        self.assertEqual(66, bad.returncode)
        self.assertEqual(1, len((remote_data / "messages.jsonl").read_text().splitlines()))

    def test_origin_envelope_cannot_import_a_role_or_replace_a_local_peer(self):
        own = self.cli("peer", "whoami", "--json", identity={"CODEX_THREAD_ID": "outside-origin"})
        self.manager()
        peer = {key: own[key] for key in ("name", "agent", "external_identity")}
        peer["host"] = "other-host"
        for extra in ({"role": "orchestrator"}, {}):
            encoded = base64.b64encode(json.dumps({**peer, **extra}).encode()).decode()
            result = self.run_cli("peer", "send", "manager", "--as", own["name"], "--sender-host", "other-host", "--json", "--", "bad", identity={"CCTRL_ORIGIN_EXTERNAL": encoded}, check=False)
            self.assertEqual(66, result.returncode)
        after = json.loads((self.data / "peers.json").read_text())[own["name"]]
        self.assertEqual(own["external_identity"], after["external_identity"])
        self.assertNotIn("role", after)

    def test_claude_ancestor_registry_requires_matching_process_start(self):
        directory = self.home / "claude" / "sessions"
        directory.mkdir(parents=True)
        pid = os.getppid()
        record = directory / f"{pid}.json"
        record.write_text(json.dumps({"pid": pid, "sessionId": "claude-native", "procStart": "Mon Nov 16 12:00:00 2026"}))
        def ps(args, **kwargs):
            output = "Mon Nov 16 12:00:00 2026\n" if "lstart=" in args else "1 /bin/claude\n"
            return subprocess.CompletedProcess(args, 0, output, "")
        with patch.object(IDENTITY.subprocess, "run", side_effect=ps):
            self.assertEqual("claude-native", IDENTITY.claude_ancestor_identity(directory)["session_id"])
            record.write_text(json.dumps({"pid": pid, "sessionId": "old-session", "procStart": "old"}))
            with self.assertRaisesRegex(ValueError, "stale"):
                IDENTITY.claude_ancestor_identity(directory)

    def test_real_process_probe_does_not_infer_session_from_cwd(self):
        # Pair the ps fixture above with the actual primitive on this host.
        row = subprocess.run(["ps", "-p", str(os.getpid()), "-o", "ppid=", "-o", "comm="],
                             capture_output=True, text=True, timeout=2, check=True)
        self.assertTrue(row.stdout.strip().split(None, 1)[0].isdigit())
        self.assertIsNone(IDENTITY.claude_ancestor_identity(self.home / "no-session-records"))

    def test_remote_delivery_emits_the_actual_external_sender_envelope(self):
        self.run_cli("peer", "register", "manager", "--host", "remote", "--agent", "codex")
        script = r'''source "$1"
_host_lookup() { printf 'fixture.invalid user\n'; }
_peer_origin_host_label() { printf 'origin\n'; }
ssh() {
    printf '%s\n' "${@: -1}" > "$HOME/ssh-command"
    cat > "$HOME/ssh-body"
    printf '%s\n' '{"ok":true,"outcome":"sent-and-queued","to":"manager","id":"remote-msg"}'
}
_peer_cmd_send manager --deliver --json -- 'outside remote status'
'''
        result = subprocess.run(["bash", "-c", script, str(ROOT / "cctrl"), str(ROOT / "cctrl")],
                                env={**self.env, "CCTRL_NO_MAIN": "1", "CODEX_THREAD_ID": "outside-remote"},
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        command = (self.home / "ssh-command").read_text()
        encoded = command.split("CCTRL_ORIGIN_EXTERNAL=", 1)[1].split()[0]
        origin = json.loads(base64.b64decode(encoded))
        self.assertEqual("outside-remote", origin["external_identity"]["session_id"])
        self.assertEqual("origin", origin["host"])
        self.assertIn("--as " + origin["name"], command)
        self.assertEqual("outside remote status", (self.home / "ssh-body").read_text())


if __name__ == "__main__":
    unittest.main()
