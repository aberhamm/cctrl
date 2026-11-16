"""Bridge ledger/lifecycle tests and isolated CLI/native-proxy process boundary."""
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

import no_real_tmux  # Prevent public cctrl children reaching a user's tmux server.

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
import native_bridge as bridge


class LedgerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = bridge.Store(Path(self.temp.name) / "ledger")
        self.daemon = self.make_daemon("codex:sender")
        self.deliveries = []

    def tearDown(self):
        self.temp.cleanup()

    def make_daemon(self, who):
        daemon = bridge.Daemon.__new__(bridge.Daemon)
        daemon.store = self.store
        daemon.who = who
        return daemon

    def delivery(self, recipient, body, mid):
        self.deliveries.append((recipient, body, mid))
        # Attempt must be durable before any provider mutation.
        with self.store.db() as db:
            row = db.execute("SELECT status FROM messages WHERE id=?", (mid,)).fetchone()
        self.assertEqual("submitting", row[0])
        return {"status": "queued", "queued_submission_id": "queue-1"}

    def test_stable_send_id_submits_once_and_rejects_changed_content(self):
        self.daemon.deliver = self.delivery
        mid = str(uuid.uuid4())
        first = self.daemon.send("codex:receiver", "hello", mid=mid)
        again = self.daemon.send("codex:receiver", "hello", mid=mid)
        self.assertEqual("queued", first["status"])
        self.assertEqual(first, again)
        self.assertEqual(1, len(self.deliveries))
        self.assertIn("message=" + mid, self.deliveries[0][1])
        with self.assertRaises(ValueError):
            self.daemon.send("codex:receiver", "changed", mid=mid)
        self.assertEqual(1, len(self.deliveries))

    def test_ambiguous_send_survives_new_daemon_without_replay(self):
        mid = str(uuid.uuid4())
        self.daemon.deliver = lambda *args: {"status": "ambiguous"}
        self.assertEqual("ambiguous", self.daemon.send("codex:receiver", "hello", mid=mid)["status"])
        replacement = self.make_daemon("codex:sender")
        replacement.deliver = lambda *args: self.fail("ambiguous send replayed")
        self.assertEqual("ambiguous", replacement.send("codex:receiver", "hello", mid=mid)["status"])

    def original(self):
        mid, _ = self.store.create("codex:sender", "claude:receiver", "request")
        self.store.event(mid, "submitted")
        return mid

    def test_ack_persists_receipt_before_send_and_preserves_original_state(self):
        mid = self.original()
        recipient = self.make_daemon("claude:receiver")
        calls = []
        def deliver(target, body, rid):
            with self.store.db() as db:
                attempt = db.execute("SELECT * FROM receipt_attempts WHERE original=?", (mid,)).fetchone()
            self.assertEqual((rid, "submitting", target),
                             (attempt["id"], attempt["status"], attempt["recipient"]))
            calls.append((target, body, rid))
            return {"status": "queued", "queued_submission_id": "receipt-queue"}
        recipient.deliver = deliver
        result = recipient.handle({"actor": recipient.who, "action": "ack", "id": mid})
        self.assertIsNotNone(result["received"])
        self.assertEqual("submitted", result["status"])
        recipient.handle({"actor": recipient.who, "action": "ack", "id": mid})
        self.assertEqual(1, len(calls))
        self.assertIn("No ACK of this receipt is needed", calls[0][1])

    def test_ambiguous_receipt_remains_durable_and_is_not_replayed(self):
        mid = self.original()
        recipient = self.make_daemon("claude:receiver")
        calls = []
        recipient.deliver = lambda *args: (calls.append(args) or {"status": "ambiguous"})
        recipient.handle({"actor": recipient.who, "action": "ack", "id": mid})
        with self.store.db() as db:
            before = dict(db.execute("SELECT * FROM receipt_attempts WHERE original=?", (mid,)).fetchone())
        replacement = self.make_daemon(recipient.who)
        replacement.deliver = lambda *args: self.fail("uncertain receipt replayed")
        replacement.handle({"actor": replacement.who, "action": "ack", "id": mid})
        with self.store.db() as db:
            after = dict(db.execute("SELECT * FROM receipt_attempts WHERE original=?", (mid,)).fetchone())
        self.assertEqual(before, after)
        self.assertEqual("ambiguous", after["status"])
        self.assertEqual(1, len(calls))

    def test_definitively_failed_receipt_can_retry_same_durable_id(self):
        mid = self.original()
        recipient = self.make_daemon("claude:receiver")
        calls = []
        def deliver(*args):
            calls.append(args)
            return {"status": "failed" if len(calls) == 1 else "queued"}
        recipient.deliver = deliver
        for _ in range(3):
            recipient.handle({"actor": recipient.who, "action": "ack", "id": mid})
        self.assertEqual(2, len(calls))
        self.assertEqual(calls[0][2], calls[1][2])

    def test_reply_is_correlated_and_only_recipient_can_reply_or_ack(self):
        mid = self.original()
        recipient = self.make_daemon("claude:receiver")
        recipient.deliver = self.delivery
        rid = str(uuid.uuid4())
        result = recipient.handle({"actor": recipient.who, "action": "reply", "id": mid,
                                   "body": "answer", "reply_id": rid})
        self.assertEqual((mid, "codex:sender", "claude:receiver"),
                         (result["reply_to"], result["recipient"], result["sender"]))
        self.assertIn("reply_to=" + mid, self.deliveries[0][1])
        original = self.store.get(mid, recipient.who)
        self.assertEqual(rid, original["replied"])
        self.assertIsNotNone(original["received"])
        for who in ["codex:sender", "codex:stranger"]:
            other = self.make_daemon(who)
            for action in ["reply", "ack"]:
                with self.subTest(who=who, action=action), self.assertRaises(ValueError):
                    other.handle({"actor": who, "action": action, "id": mid, "body": "forged"})
        with self.assertRaises(ValueError):
            recipient.handle({"actor": "codex:sender", "action": "ack", "id": mid})

    def test_bad_endpoint_start_identity_is_not_live(self):
        with self.store.db() as db:
            db.execute("INSERT INTO endpoints VALUES (?,?,?,?,?,?,?)",
                       ("codex:dead", 999999, None, "/unused", "/unused", "dead", "/tmp"))
        with patch.object(bridge, "start_identity", return_value=None):
            self.assertIsNone(self.store.endpoint("codex:dead"))

    def test_claim_recovers_only_persisted_work_for_its_dispatcher(self):
        mid, _ = self.store.create("claude:source", "codex:receiver", "ingress",
                                   dispatcher="codex:receiver")
        self.assertFalse(self.store.claim(mid, "claude:source"))
        replacement = self.make_daemon("codex:receiver")
        replacement.deliver = self.delivery
        replacement.dispatch(mid)
        replacement.dispatch(mid)
        self.assertEqual(1, len(self.deliveries))
        self.store.event(mid, "ambiguous")
        self.assertFalse(self.store.claim(mid, replacement.who))

    def test_cleanup_refuses_replaced_inode_retains_manifest_and_retries(self):
        path = Path(self.temp.name) / "owned"
        path.write_text("owned")
        info = path.stat()
        backup = path.with_suffix(".backup")
        path.rename(backup)
        path.write_text("replacement")
        who = "codex:dead"
        resources = [{"path": str(path), "device": info.st_dev, "inode": info.st_ino}]
        with self.store.db() as db:
            db.execute("INSERT INTO ownership VALUES (?,?,?,?)", (who, 999999, "old", json.dumps(resources)))
            db.execute("INSERT INTO endpoints VALUES (?,?,?,?,?,?,?)", (who, 999999, "old", str(path), str(path), "fixture", "/tmp"))
        with patch.object(bridge, "start_identity", return_value=None), patch.object(bridge.os, "kill", side_effect=ProcessLookupError):
            with self.assertRaisesRegex(ValueError, "manifest retained"):
                self.store.clean_exited(who)
            self.assertEqual("replacement", path.read_text())
            with self.store.db() as db:
                self.assertEqual(1, db.execute("SELECT count(*) FROM ownership").fetchone()[0])
                self.assertEqual(1, db.execute("SELECT count(*) FROM endpoints").fetchone()[0])
            path.unlink()
            backup.rename(path)
            self.store.clean_exited(who)
        self.assertFalse(path.exists())
        with self.store.db() as db:
            self.assertEqual(0, db.execute("SELECT count(*) FROM ownership").fetchone()[0])
            self.assertEqual(0, db.execute("SELECT count(*) FROM endpoints").fetchone()[0])

    def test_receipt_controls_correlate_separately_and_check_target(self):
        mid = self.original()
        rid = str(uuid.uuid4())
        daemon = self.make_daemon("claude:receiver")
        daemon.target = lambda _: {"pid": 321, "socket": "/fixture/native"}
        with self.store.db() as db:
            db.execute("INSERT INTO receipt_attempts VALUES (?,?,?,?,?,NULL)",
                       (mid, rid, "claude:receipt-target", "receipt", "submitted"))
        for status, expected in [("held", "held"), ("expired", "refused"), ("delivered", "released")]:
            frame = {"type": "control", "action": "peer_message_status", "orig_msg_id": rid,
                     "status": status, "status_detail": "refused"}
            daemon.incoming_message(frame, {"pid": 999, "socket": "/fixture/native"})
            daemon.incoming_message(frame, {"pid": 321, "socket": "/fixture/native"})
            original = self.store.get(mid, daemon.who)
            self.assertEqual("submitted", original["status"])
            self.assertEqual(expected, original["receipt_attempt"]["status"])
            self.assertEqual("receipt-" + expected, original["events"][-1]["kind"])

    def test_policy_outcomes_survive_late_transport_results(self):
        for policy in ["held", "refused", "released"]:
            mid = self.original()
            self.store.event(mid, policy)
            for transport in ["ambiguous", "failed", "submitted", "queued"]:
                self.store.event(mid, transport)
                self.assertEqual(policy, self.store.get(mid, "codex:sender")["status"])

    def test_claude_ingress_refuses_relay_and_claude_to_claude_send_is_rejected(self):
        daemon = self.make_daemon("claude:receiver")
        daemon.source_actor = lambda _: "claude:source"
        calls = []
        class Native:
            def send_control(self, *args, **kwargs):
                # No relay worker can claim the record before the refusal
                # callback, even if it runs concurrently at this boundary.
                self_outer.assertFalse(self_outer.store.claim(kwargs["orig_msg_id"], daemon.who))
                calls.append((args, kwargs))
        self_outer = self
        daemon.native = Native()
        daemon.deliver = lambda *args: self.fail("native ingress was relayed")
        mid = str(uuid.uuid4())
        daemon.receive({"type": "user", "msg_id": mid, "message": {"content": "fixture"}}, {"pid": 123})
        self.assertEqual("refused", self.store.get(mid, daemon.who)["status"])
        self.assertEqual("refused", calls[0][1]["status"])
        with self.assertRaisesRegex(ValueError, "native admission"):
            daemon.send("claude:other", "must use native tools")
        with self.store.db() as db:
            self.assertEqual(1, db.execute("SELECT count(*) FROM messages").fetchone()[0])


PROXY = r'''#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:]==['--version']:
    print('codex-cli 0.167.0'); sys.exit(0)
assert sys.argv[1:3]==['app-server','proxy'],sys.argv
for line in sys.stdin:
    message=json.loads(line)
    with open(os.environ['BRIDGE_FIXTURE_LOG'],'a') as handle:
        handle.write(json.dumps(message)+'\n'); handle.flush()
    method=message['method']
    if method=='initialized':continue
    if method=='initialize':
        assert message['params']['capabilities']=={'experimentalApi':True}
        result={'userAgent':'codex/0.167.0','codexHome':os.environ['CODEX_HOME'],'platformFamily':'unix','platformOs':'macos'}
    elif method=='thread/queue/add':
        assert 'threadId' in message['params']
        if open(os.environ['BRIDGE_FIXTURE_MODE']).read().strip()=='lost':sys.exit(0)
        p=message['params']
        result={'queuedSubmission':{'id':'native-'+p['clientUserMessageId'],'clientUserMessageId':p['clientUserMessageId'],'input':p['input']}}
    else:raise AssertionError('unexpected provider action: '+method)
    print(json.dumps({'id':message['id'],'result':result}),flush=True)
'''


class CliProcessTests(unittest.TestCase):
    def setUp(self):
        base = "/private/tmp" if sys.platform == "darwin" else "/tmp"
        self.temp = tempfile.TemporaryDirectory(prefix="nb-", dir=base)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ)
        for key in ["CODEX_THREAD_ID", "CODEX_SESSION_ID", "CLAUDE_CODE_SESSION_ID", "CLAUDECODE",
                    "CCTRL_EXTERNAL_IDENTITY", "CCTRL_CALLER_UMASK"]:
            self.env.pop(key, None)
        self.proxy = self.root / "codex"
        self.proxy.write_text(PROXY)
        self.proxy.chmod(0o700)
        self.log = self.root / "calls.jsonl"
        self.mode = self.root / "mode"
        self.mode.write_text("accept")
        self.env.update({"HOME": str(self.root / "home"), "CODEX_HOME": str(self.root / "codex-home"),
                         "CLAUDE_CONFIG_DIR": str(self.root / "claude"),
                         "CCTRL_NATIVE_BRIDGE_DIR": str(self.root / "ledger"),
                         "CCTRL_NATIVE_BRIDGE_SOCKET_DIR": str(self.root / "s"),
                         "CCTRL_STATE_DIR": str(self.root / "state"),
                         "CCTRL_CODEX_BIN": str(self.proxy),
                         "CCTRL_CODEX_APP_SERVER_SOCKET": "/fixture/no-live-socket",
                         "CCTRL_CODEX_APP_SERVER_TRANSPORT": "jsonl",
                         "BRIDGE_FIXTURE_LOG": str(self.log), "BRIDGE_FIXTURE_MODE": str(self.mode),
                         "CODEX_THREAD_ID": str(uuid.uuid4())})
        self.rows = []

    def cli(self, *args):
        proc = subprocess.run([sys.executable, str(ROOT / "lib/native_bridge.py"), *args],
                              cwd=ROOT, env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(0, proc.returncode, proc.stdout + proc.stderr)
        return json.loads(proc.stdout)

    def enable(self):
        row = self.cli("enable", "--json")
        self.rows.append(row)
        return row

    def stop(self):
        self.cli("stop", "--json")
        until = time.monotonic() + 5
        while time.monotonic() < until:
            if not (self.root / "ledger").exists():return
            store = bridge.Store(self.root / "ledger")
            if store.endpoint("codex:" + self.env["CODEX_THREAD_ID"]) is None:return
            time.sleep(.05)
        self.fail("owned bridge daemon did not stop")

    def queue_calls(self):
        if not self.log.exists():return []
        return [v for line in self.log.read_text().splitlines()
                if (v := json.loads(line)).get("method") == "thread/queue/add"]

    def tearDown(self):
        try:
            if self.rows:
                self.stop()
        finally:
            # Stop only processes whose exact startup identity was returned by
            # this test's daemon; never a default server or unrelated session.
            for row in self.rows:
                if row.get("started") and bridge.start_identity(row["pid"]) == row["started"]:
                    os.kill(row["pid"], signal.SIGTERM)
            self.temp.cleanup()

    def test_cli_enable_send_stable_retry_and_stop_uses_owned_proxy(self):
        row = self.enable()
        self.assertEqual("codex:" + self.env["CODEX_THREAD_ID"], row["actor"])
        self.assertTrue(Path(row["socket"]).is_socket())
        target = "codex:" + str(uuid.uuid4())
        mid = str(uuid.uuid4())
        first = self.cli("send", target, "--json", "--id", mid, "--", "hello from fixture")
        again = self.cli("send", target, "--json", "--id", mid, "--", "hello from fixture")
        self.assertEqual((mid, "queued"), (first["id"], first["status"]))
        self.assertEqual(first, again)
        calls = self.queue_calls()
        self.assertEqual(1, len(calls))
        self.assertEqual(mid, calls[0]["params"]["clientUserMessageId"])
        self.assertEqual(target.split(":", 1)[1], calls[0]["params"]["threadId"])
        self.stop()
        self.assertFalse(Path(row["socket"]).exists())

    def test_cli_restart_preserves_ambiguous_send_without_extra_enqueue(self):
        self.mode.write_text("lost")
        self.enable()
        target = "codex:" + str(uuid.uuid4())
        mid = str(uuid.uuid4())
        first = self.cli("send", target, "--json", "--id", mid, "--", "uncertain fixture")
        self.assertEqual("ambiguous", first["status"])
        self.assertEqual(1, len(self.queue_calls()))
        self.stop()
        self.mode.write_text("accept")
        self.enable()
        again = self.cli("send", target, "--json", "--id", mid, "--", "uncertain fixture")
        self.assertEqual("ambiguous", again["status"])
        self.assertEqual(1, len(self.queue_calls()))

    def test_mcp_native_public_entry_uses_actual_session_and_rejects_impersonation(self):
        from peer_mcp import Bridge, McpError
        mid = str(uuid.uuid4())
        target = "codex:" + str(uuid.uuid4())
        # An old mailbox --as binding must not become native sender identity.
        mcp = Bridge(str(ROOT / "cctrl"), "unrelated-mailbox-identity")
        with patch.dict(os.environ, self.env, clear=True):
            endpoint = mcp.call_tool("native_enable", {})["data"]
            self.rows.append(endpoint)
            args = {"to": target, "body": "MCP native fixture", "id": mid}
            first = mcp.call_tool("native_send", args)["data"]
            second = mcp.call_tool("native_send", args)["data"]
            status = mcp.call_tool("native_status", {"id": mid})["data"]
            self.assertEqual(first, second)
            self.assertEqual(mid, status["id"])
            self.assertEqual("codex:" + self.env["CODEX_THREAD_ID"], first["sender"])
            self.assertEqual("queued", status["status"])
            for field in ["from", "as"]:
                with self.subTest(field=field), self.assertRaises(McpError):
                    mcp.call_tool("native_send", {**args, field: "borrowed-session"})
        self.assertEqual(1, len(self.queue_calls()))
    def test_isolated_native_socket_to_claude_and_back_to_codex_queue(self):
        from bridge_claude import ClaudeEndpoint, discover_sessions
        row = self.enable()
        received = queue.Queue()
        # This is an honest cctrl endpoint emulating protocol transport, not
        # evidence that a real Claude model consumed or replied to the input.
        fixture_session = "fixture-native-session"
        endpoint = ClaudeEndpoint("cctrl-fixture", "cctrl-bridge-fixture",
                                  lambda frame, sender: received.put((frame, sender)),
                                  config_dir=self.root / "claude", socket_dir=self.root / "peer")
        endpoint.open()
        try:
            # Only the private fixture registry emulates a provider session.
            # Its display name remains cctrl-fixture; no installed provider or
            # live user record is changed or used as verification evidence.
            endpoint.session_id = fixture_session
            endpoint.record["sessionId"] = fixture_session
            (self.root / "claude" / "sessions" / f"{os.getpid()}.json").write_text(
                json.dumps(endpoint.record))
            store = bridge.Store(self.root / "ledger")
            fixture_actor = "claude:" + fixture_session
            with store.db() as db:
                db.execute("INSERT INTO endpoints VALUES (?,?,?,?,?,?,?)", (
                    fixture_actor, os.getpid(), bridge.start_identity(os.getpid()),
                    "/fixture/no-control-socket", endpoint.socket_path, "cctrl-fixture", str(self.root)))
            outbound_id = str(uuid.uuid4())
            outbound = self.cli("send", fixture_actor, "--json", "--id", outbound_id,
                                "--", "Codex to native Claude fixture")
            self.assertEqual("submitted", outbound["status"], outbound)
            frame, sender = received.get(timeout=3)
            self.assertEqual(outbound_id, frame["msg_id"])
            self.assertEqual(row["pid"], sender["pid"])
            self.assertIn("Codex to native Claude fixture", frame["message"]["content"])
            daemon_target = next(record for record in discover_sessions(self.root / "claude")
                                 if record["pid"] == row["pid"])
            inbound_id = str(uuid.uuid4())
            reverse = endpoint.send(daemon_target, "Native Claude fixture to Codex", msg_id=inbound_id)
            self.assertEqual("submitted", reverse["status"])
            until = time.monotonic() + 5
            while time.monotonic() < until and not self.queue_calls():
                time.sleep(.05)
            calls = self.queue_calls()
            self.assertEqual(1, len(calls))
            self.assertEqual(inbound_id, calls[0]["params"]["clientUserMessageId"])
            self.assertEqual(self.env["CODEX_THREAD_ID"], calls[0]["params"]["threadId"])
            self.assertIn("Native Claude fixture to Codex", calls[0]["params"]["input"][0]["text"])
            record = self.cli("status", inbound_id, "--json")
            self.assertEqual((fixture_actor, row["actor"], "queued"),
                             (record["sender"], record["recipient"], record["status"]))
        finally:
            endpoint.close()


if __name__ == "__main__":
    unittest.main()
