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
from unittest import mock
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
        self.store.event(mid, "released")  # native delivery admitted it
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
        self.assertEqual("released", result["status"])
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
            self.assertEqual("released", original["status"])
            self.assertEqual(expected, original["receipt_attempt"]["status"])
            self.assertEqual("receipt-" + expected, original["events"][-1]["kind"])

    def test_policy_outcomes_survive_late_transport_results(self):
        for policy in ["held", "refused", "released"]:
            mid = self.original()
            self.store.event(mid, policy)
            for transport in ["ambiguous", "failed", "submitted", "queued"]:
                self.store.event(mid, transport)
                self.assertEqual(policy, self.store.get(mid, "codex:sender")["status"])

    # ---- mdec-1116 items 2+3: delivery vs inbox vs history, retirement, receipts, envelope ----
    def accepted(self, status="queued", recipient="codex:receiver", detail=None, body="work", sender="claude:sender"):
        mid, _ = self.store.create(sender, recipient, body)
        self.store.event(mid, status, detail if detail is not None else {"queued_submission_id": "queue-1"})
        return mid

    def ids(self, who, view="actionable"):
        return [m["id"] for m in self.store.inbox(who, view)["messages"]]

    def test_native_accepted_messages_are_never_actionable_in_inbox(self):
        queued = self.accepted("queued")
        submitted = self.accepted("submitted", "claude:receiver", {})
        released = self.accepted("released", "claude:receiver", {})
        held = self.accepted("held", "claude:receiver", {})
        for who in ("codex:receiver", "claude:receiver"):
            self.assertEqual([], self.ids(who), who)
        self.assertEqual([held], self.ids("claude:receiver", "stranded"))
        self.assertEqual([], self.ids("codex:receiver", "stranded"))
        self.assertEqual([queued], self.ids("codex:receiver", "history"))
        self.assertCountEqual([submitted, released, held], self.ids("claude:receiver", "history"))
        failed = self.accepted("failed", "codex:receiver", {"reason": "rejected"})
        self.assertEqual([failed], self.ids("codex:receiver"))
        with self.assertRaises(ValueError):
            self.store.inbox("codex:receiver", "everything")

    def test_ack_retires_pending_native_queue_item_by_persisted_identity(self):
        mid = self.accepted("queued")
        recipient = self.make_daemon("codex:receiver")
        recipient.deliver = lambda *args: {"status": "queued"}
        calls = []
        recipient.retire_queue = lambda *args: (calls.append(args) or {"outcome": "retired"})
        result = recipient.handle({"actor": recipient.who, "action": "ack", "id": mid})
        self.assertEqual([("receiver", mid, "queue-1")], calls)
        self.assertEqual("retired", result["native_retirement"]["outcome"])
        self.assertTrue(result["handled"])
        recipient.handle({"actor": recipient.who, "action": "ack", "id": mid})
        self.assertEqual(1, len(calls), "a final retirement is never repeated")

    def test_reply_retires_original_and_reports_outcome(self):
        mid = self.accepted("queued", detail={"queued_submission_id": "queue-9"})
        recipient = self.make_daemon("codex:receiver")
        recipient.deliver = self.delivery
        recipient.retire_queue = lambda *args: {"outcome": "already_consumed"}
        result = recipient.handle({"actor": recipient.who, "action": "reply", "id": mid, "body": "done"})
        self.assertEqual("already_consumed", result["original"]["native_retirement"]["outcome"])
        self.assertEqual(mid, result["reply_to"])

    def test_unresolved_retirements_stay_retryable_and_final_ones_do_not(self):
        mid = self.accepted("queued")
        recipient = self.make_daemon("codex:receiver")
        recipient.deliver = lambda *args: {"status": "queued"}
        outcomes = iter(["race", "unknown", "identity_mismatch", "absent"])
        calls = []
        recipient.retire_queue = lambda *args: (calls.append(1) or {"outcome": next(outcomes)})
        for _ in range(6):
            recipient.handle({"actor": recipient.who, "action": "ack", "id": mid})
        self.assertEqual(4, len(calls))

    def test_retirement_needs_a_persisted_queue_identity_and_never_guesses(self):
        mid = self.accepted("ambiguous", detail={"status": "ambiguous"})
        recipient = self.make_daemon("codex:receiver")
        recipient.deliver = lambda *args: {"status": "queued"}
        recipient.retire_queue = lambda *args: self.fail("retired without a persisted queue identity")
        result = recipient.handle({"actor": recipient.who, "action": "ack", "id": mid})
        self.assertEqual("unknown_identity", result["native_retirement"]["outcome"])

    def test_failed_message_has_nothing_to_retire(self):
        mid = self.accepted("failed", detail={"reason": "x"})
        recipient = self.make_daemon("codex:receiver")
        recipient.deliver = lambda *args: {"status": "queued"}
        recipient.retire_queue = lambda *args: self.fail("retire attempted for unaccepted message")
        result = recipient.handle({"actor": recipient.who, "action": "ack", "id": mid})
        self.assertEqual("not_applicable", result["native_retirement"]["outcome"])

    def test_held_and_unadmitted_items_cannot_be_acked_or_replied_from_the_ledger(self):
        cases = [("held", "claude:receiver"), ("refused", "claude:receiver"), ("denied", "claude:receiver"),
                 ("expired", "claude:receiver"), ("dropped", "claude:receiver"),
                 ("held", "codex:receiver")]
        for status, who in cases:
            for action in ("ack", "reply"):
                with self.subTest(status=status, who=who, action=action):
                    mid = self.accepted(status, who, {})
                    recipient = self.make_daemon(who)
                    recipient.deliver = lambda *args: self.fail("no receipt or reply may be sent for an unadmitted message")
                    recipient.retire_queue = lambda *args: self.fail("nothing to retire")
                    with self.assertRaisesRegex(ValueError, "(?i)no receipt was sent"):
                        recipient.handle({"actor": who, "action": action, "id": mid, "body": "answer"})
                    row = self.store.get(mid, who)
                    self.assertFalse(row["handled"])
                    self.assertIsNone(row["replied"])
                    self.assertEqual(status, row["status"])

    def test_claude_submitted_message_is_admitted_and_can_be_acked_and_replied(self):
        for action in ("ack", "reply"):
            with self.subTest(action=action):
                mid = self.accepted("submitted", "claude:receiver", {}, sender="codex:sender")
                recipient = self.make_daemon("claude:receiver")
                recipient.deliver = lambda *args: {"status": "submitted"}
                result = recipient.handle({"actor": recipient.who, "action": action, "id": mid, "body": "answer"})
                self.assertTrue(self.store.get(mid, "claude:receiver")["handled"])
                self.assertNotIn("warning", result)

    def test_late_held_callback_during_reply_does_not_mark_handled(self):
        mid = self.accepted("submitted", "claude:receiver", {}, sender="codex:sender")
        recipient = self.make_daemon("claude:receiver")
        def deliver(*args):
            self.store.event(mid, "held", {"status": "held"})
            return {"status": "submitted"}
        recipient.deliver = deliver
        result = recipient.handle({"actor": recipient.who, "action": "reply", "id": mid, "body": "answer"})
        self.assertIs(False, result["handled"])
        self.assertFalse(self.store.get(mid, "claude:receiver")["handled"])

    def test_client_supplied_provider_bases_are_rederived_not_trusted(self):
        raw = {"display_name": {"value": "Fleet Manager", "basis": "provider-registry"},
               "harness": {"value": "claude-code", "basis": "provider-reported:thread/read"},
               "reported_source": {"value": "cli", "basis": "provider-registry"},
               "host": {"value": "evilhost", "basis": "observed:local-host"}}
        with mock.patch.object(bridge, "own_registry", return_value=None):
            env = bridge.envelope_from_request(raw, "codex:abc")
        self.assertEqual("claimed", env["display_name"]["basis"])
        self.assertEqual("claimed", env["harness"]["basis"])
        self.assertEqual("claimed", env["reported_source"]["basis"])
        self.assertEqual("claimed", env["host"]["basis"])
        with mock.patch.object(bridge, "own_registry", return_value={"name": "Fleet Manager", "kind": "cli", "basis": "provider-registry"}):
            env = bridge.envelope_from_request(raw, "codex:abc")
        self.assertEqual("provider-registry", env["display_name"]["basis"])
        self.assertEqual("provider-registry", env["reported_source"]["basis"])
        self.assertEqual("claimed", env["harness"]["basis"])

    def test_stranded_view_withholds_the_body_of_unadmitted_items(self):
        mid = self.accepted("held", "claude:receiver", {}, body="secret task result")
        rows = self.store.inbox("claude:receiver", "stranded")["messages"]
        self.assertEqual([mid], [r["id"] for r in rows])
        self.assertNotIn("secret task result", json.dumps(rows))
        self.assertIn("NOT ADMITTED", rows[0]["body"])
        self.assertIs(False, rows[0]["admitted"])
        self.assertFalse(rows[0]["actionable"])
        self.assertIn("secret task result", json.dumps(self.store.inbox("claude:receiver", "history")["messages"]))

    def test_claude_has_no_retraction_so_handling_after_release_reports_unsupported(self):
        mid = self.accepted("held", "claude:receiver", {"status": "held"})
        recipient = self.make_daemon("claude:receiver")
        recipient.deliver = lambda *args: {"status": "submitted"}
        with self.assertRaises(ValueError):
            recipient.handle({"actor": recipient.who, "action": "ack", "id": mid})
        recipient.target = lambda who: {"pid": 7, "socket": "/s"}
        recipient.incoming_message({"type": "control", "action": "peer_message_status", "orig_msg_id": mid, "status": "delivered"},
                                   {"pid": 7, "socket": "/s"})
        self.assertEqual("released", self.store.get(mid, "claude:receiver")["status"])
        self.assertEqual([], self.ids("claude:receiver", "stranded"))
        result = recipient.handle({"actor": recipient.who, "action": "ack", "id": mid})
        self.assertEqual("unsupported", result["native_retirement"]["outcome"])
        self.assertTrue(result["handled"])

    def test_receipts_are_control_facts_never_inbox_work_never_acked_or_replied(self):
        text = "[cctrl-bridge receipt message=%s status=received by=codex:receiver control=true]\nx" % uuid.uuid4()
        rid, _ = self.store.create("codex:receiver", "codex:sender", text)
        row = self.store.get(rid, "codex:sender")
        self.assertEqual(("receipt", "receipt"), (row["kind"], row["status"]))
        self.assertTrue(row["handled"])
        for view in ("actionable", "stranded"):
            self.assertEqual([], self.ids("codex:sender", view))
        self.assertEqual([rid], self.ids("codex:sender", "history"))
        sender = self.make_daemon("codex:sender")
        sender.deliver = lambda *args: self.fail("a receipt must never produce traffic")
        for action in ("ack", "reply"):
            with self.subTest(action=action), self.assertRaises(ValueError):
                sender.handle({"actor": sender.who, "action": action, "id": rid, "body": "re"})
        with self.assertRaises(ValueError):
            sender.send("codex:receiver", text)
        self.assertEqual(1, len([1 for _ in self.store.get(rid, "codex:sender")["events"] if _["kind"] == "receipt"]))

    def test_receipt_wire_text_is_marked_control_and_ack_does_not_loop(self):
        mid = self.original()
        recipient = self.make_daemon("claude:receiver")
        sent = []
        recipient.deliver = lambda target, body, rid: (sent.append(body) or {"status": "queued"})
        recipient.handle({"actor": recipient.who, "action": "ack", "id": mid})
        self.assertIn("control=true", sent[0])
        self.assertIn("do not reply", sent[0])
        # The receipt's own text, if ingested by a daemon, is a control fact.
        rid, _ = self.store.create("claude:receiver", "codex:sender", sent[0])
        self.assertEqual("receipt", self.store.get(rid, "codex:sender")["kind"])

    def test_sender_envelope_is_one_snapshot_with_provenance_and_no_inference(self):
        env = {"CCTRL_SESSION_NAME": "Review\nSession", "CCTRL_HARNESS": "codex-cli", "HOME": "/secret/home", "API_KEY": "hunter2"}
        snap = bridge.sender_envelope("codex:abc", "environment-claimed", env=env)
        self.assertEqual(("codex", "abc"), (snap["provider"], snap["session_id"]))
        self.assertEqual({"value": "Review Session", "basis": "claimed:CCTRL_SESSION_NAME"}, snap["display_name"])
        self.assertEqual({"value": "codex-cli", "basis": "claimed:CCTRL_HARNESS"}, snap["harness"])
        self.assertEqual({"value": None, "basis": "unknown"}, snap["reported_source"])
        self.assertEqual("environment-claimed", snap["identity_basis"])
        self.assertNotIn("hunter2", json.dumps(snap))
        self.assertNotIn("/secret/home", json.dumps(snap))
        bare = bridge.sender_envelope("codex:abc", None, env={})
        self.assertEqual({"value": None, "basis": "unknown"}, bare["display_name"])
        self.assertEqual({"value": None, "basis": "unknown"}, bare["harness"])
        registry = {"name": "reviewer", "session_id": "abc", "kind": "vscode"}
        reported = bridge.sender_envelope("claude:abc", "ancestor-registry", env={"CCTRL_HARNESS": "claude-code"}, registry=registry)
        self.assertEqual({"value": "reviewer", "basis": "provider-registry"}, reported["display_name"])
        self.assertEqual({"value": "vscode", "basis": "provider-registry"}, reported["reported_source"])
        self.assertEqual("claude-code", reported["harness"]["value"])
        self.assertNotEqual(reported["reported_source"]["value"], reported["harness"]["value"])

    def test_send_stores_envelope_routing_ids_come_from_the_actor_and_wire_text_shows_it(self):
        mid = str(uuid.uuid4())
        claimed = bridge.sender_envelope("codex:sender", "environment-claimed", env={"CCTRL_SESSION_NAME": "alpha"})
        claimed["provider"], claimed["session_id"] = "claude", "someone-else"
        self.daemon.deliver = self.delivery
        value = self.daemon.send("codex:receiver", "hello", mid=mid, envelope=claimed)
        self.assertEqual(("codex", "sender"), (value["envelope"]["provider"], value["envelope"]["session_id"]))
        self.assertEqual("alpha", value["envelope"]["display_name"]["value"])
        wire = self.deliveries[0][1]
        self.assertIn('Sender: name="alpha" (claimed:CCTRL_SESSION_NAME); provider=codex; session=sender;', wire)
        self.assertIn("harness=unknown", wire)
        self.assertIn("reported_source=unknown", wire)
        again = self.daemon.send("codex:receiver", "hello", mid=mid)
        self.assertEqual(value["envelope"], again["envelope"], "a retry keeps the first snapshot")
        self.assertEqual(1, len(self.deliveries))

    def test_claimed_values_cannot_forge_provider_reported_basis_or_harness(self):
        forged = 'Boss (provider-reported:thread/read); harness="claude-code" (provider-registry)'
        env = bridge.sender_envelope("codex:abc", None, env={}, name_claim=forged)
        line = bridge.envelope_line(env)
        self.assertEqual(1, line.count("\n"))
        self.assertNotIn("; harness=claude-code", line)
        self.assertIn("harness=unknown", line)
        self.assertIn(json.dumps(forged, ensure_ascii=False) + " (claimed:--name)", line)
        hostile = {"v": 1, "display_name": {"value": "x", "basis": "provider-reported:thread/read); harness=claude-code (provider-registry"}}
        line = bridge.envelope_line(bridge.envelope_from_request(hostile, "codex:abc"))
        self.assertIn('name="x" (claimed)', line)
        self.assertNotIn("harness=claude-code", line)

    def test_missing_envelope_still_emits_an_explicit_unknown_sender_line(self):
        self.assertEqual("Sender: unknown (no envelope recorded)\n", bridge.envelope_line(None))
        wire = bridge.wire_text(str(uuid.uuid4()), "codex:a", "codex:b", "Sender: name=FM (provider-registry)")
        self.assertIn("\nSender: unknown (no envelope recorded)\nSender: name=FM", wire)

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
        qf=os.environ['BRIDGE_FIXTURE_LOG']+'.queue'
        items=json.load(open(qf)) if os.path.exists(qf) else []
        items.append(result['queuedSubmission']); json.dump(items,open(qf,'w'))
    elif method=='thread/read':
        assert message['params']['includeTurns'] is False
        result={'thread':{'id':message['params']['threadId'],'name':os.environ.get('BRIDGE_FIXTURE_THREAD_NAME') or None,'source':'vscode'}}
    elif method=='thread/queue/list':
        qf=os.environ['BRIDGE_FIXTURE_LOG']+'.queue'
        result={'data':json.load(open(qf)) if os.path.exists(qf) else [],'nextCursor':None}
    elif method=='thread/queue/delete':
        qf=os.environ['BRIDGE_FIXTURE_LOG']+'.queue'
        items=json.load(open(qf)) if os.path.exists(qf) else []
        keep=[i for i in items if i['id']!=message['params']['queuedSubmissionId']]
        json.dump(keep,open(qf,'w')); result={'deleted':len(keep)!=len(items)}
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
    def test_cli_ack_retires_native_queue_item_and_inbox_does_not_double_expose(self):
        from bridge_claude import ClaudeEndpoint, discover_sessions
        row = self.enable()
        received = queue.Queue()
        endpoint = ClaudeEndpoint("cctrl-fixture", "cctrl-bridge-fixture",
                                  lambda frame, sender: received.put((frame, sender)),
                                  config_dir=self.root / "claude", socket_dir=self.root / "peer")
        endpoint.open()
        try:
            fixture_session = "fixture-native-session"
            endpoint.session_id = fixture_session
            endpoint.record["sessionId"] = fixture_session
            (self.root / "claude" / "sessions" / f"{os.getpid()}.json").write_text(json.dumps(endpoint.record))
            store = bridge.Store(self.root / "ledger")
            fixture_actor = "claude:" + fixture_session
            with store.db() as db:
                db.execute("INSERT INTO endpoints VALUES (?,?,?,?,?,?,?)", (
                    fixture_actor, os.getpid(), bridge.start_identity(os.getpid()),
                    "/fixture/no-control-socket", endpoint.socket_path, "cctrl-fixture", str(self.root)))
            target = next(r for r in discover_sessions(self.root / "claude") if r["pid"] == row["pid"])
            inbound = str(uuid.uuid4())
            self.assertEqual("submitted", endpoint.send(target, "Native Claude fixture work", msg_id=inbound)["status"])
            until = time.monotonic() + 5
            while time.monotonic() < until and not self.queue_calls():
                time.sleep(.05)
            self.assertEqual("queued", self.cli("status", inbound, "--json")["status"])
            self.assertEqual([], self.cli("inbox", "--json")["messages"])
            self.assertEqual([], self.cli("inbox", "--json", "--view", "stranded")["messages"])
            history = self.cli("inbox", "--json", "--view", "history")["messages"]
            self.assertEqual([inbound], [m["id"] for m in history])
            self.assertEqual("native-" + inbound, history[0]["queued_submission_id"])
            self.assertEqual("verified-native-socket", history[0]["envelope"]["identity_basis"])
            self.assertEqual("unknown", history[0]["envelope"]["harness"]["basis"])
            acked = self.cli("ack", inbound, "--json")
            self.assertEqual("retired", acked["native_retirement"]["outcome"])
            queue_file = Path(str(self.log) + ".queue")
            self.assertEqual([], json.loads(queue_file.read_text()))
            methods = [json.loads(l)["method"] for l in self.log.read_text().splitlines()]
            self.assertIn("thread/queue/delete", methods)
            again = self.cli("ack", inbound, "--json")
            self.assertEqual(1, methods.count("thread/queue/delete"))
            self.assertEqual(1, len([1 for l in self.log.read_text().splitlines() if json.loads(l)["method"] == "thread/queue/delete"]))
            self.assertTrue(again["handled"])
        finally:
            endpoint.close()

    def test_cli_codex_envelope_uses_provider_thread_name_and_keeps_harness_separate(self):
        self.env.update({"BRIDGE_FIXTURE_THREAD_NAME": "Provider Title", "CCTRL_SESSION_NAME": "claimed title"})
        self.enable()
        target = "codex:" + str(uuid.uuid4())
        sent = self.cli("send", target, "--json", "--harness", "codex-cli", "--", "hello")
        env = sent["envelope"]
        self.assertEqual({"value": "Provider Title", "basis": "provider-reported:thread/read"}, env["display_name"])
        self.assertEqual({"value": "vscode", "basis": "provider-reported:thread/read"}, env["reported_source"])
        self.assertEqual({"value": "codex-cli", "basis": "claimed:--harness"}, env["harness"])
        calls = [json.loads(l) for l in self.log.read_text().splitlines()]
        # the client reads once; the daemon re-derives the provider-reported fields once
        self.assertEqual(2, len([c for c in calls if c["method"] == "thread/read"]))
        self.assertTrue(all(c["method"] != "thread/resume" for c in calls))

    def test_cli_explicit_name_claim_is_marked_claimed_when_provider_has_no_title(self):
        self.enable()
        sent = self.cli("send", "codex:" + str(uuid.uuid4()), "--json", "--name", "ops reviewer", "--", "hello")
        self.assertEqual({"value": "ops reviewer", "basis": "claimed:--name"}, sent["envelope"]["display_name"])
        self.assertEqual("unknown", sent["envelope"]["harness"]["basis"])

    def test_cli_send_snapshots_envelope_once_and_shows_unknowns(self):
        self.env.update({"CCTRL_SESSION_NAME": "alpha session", "CCTRL_HARNESS": "codex-cli", "API_TOKEN": "must-not-leak"})
        self.enable()
        target = "codex:" + str(uuid.uuid4())
        mid = str(uuid.uuid4())
        first = self.cli("send", target, "--json", "--id", mid, "--", "hello")
        env = first["envelope"]
        self.assertEqual("codex:" + self.env["CODEX_THREAD_ID"], first["sender"])
        self.assertEqual((("codex", self.env["CODEX_THREAD_ID"]), "alpha session", "codex-cli"),
                         ((env["provider"], env["session_id"]), env["display_name"]["value"], env["harness"]["value"]))
        self.assertEqual("provider-reported:thread/read", env["reported_source"]["basis"])
        self.assertEqual("environment-claimed", env["identity_basis"])
        text = self.queue_calls()[0]["params"]["input"][0]["text"]
        self.assertIn('Sender: name="alpha session" (claimed:CCTRL_SESSION_NAME)', text)
        self.assertNotIn("must-not-leak", json.dumps(first) + text)
        self.assertEqual(first["envelope"], self.cli("status", mid, "--json")["envelope"])

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
