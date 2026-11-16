"""Native queue contract tests, including an isolated real proxy subprocess."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import bridge_codex
from codex_app_server import AdapterError, AppServerClient, Runtime, EXIT_SERVER_ERROR, EXIT_EOF


def item(client="attempt", text="hello", queue_id="queued-1"):
    return {"id": queue_id, "clientUserMessageId": client,
            "input": [{"type": "text", "text": text, "text_elements": []}]}


class Client:
    def __init__(self, responses):
        self.responses = iter(responses)
        self.calls = []

    def request(self, method, params):
        self.calls.append((method, params))
        response = next(self.responses)
        if isinstance(response, Exception):
            raise response
        return response


class QueueTests(unittest.TestCase):
    def test_enqueue_uses_queue_only_and_preserves_exact_text(self):
        text = "hello\n$literal `content`"
        client = Client([{"queuedSubmission": item(text=text)}])
        result = bridge_codex.enqueue("thread", text, "attempt", client=client)
        self.assertEqual(("queued", "accepted", "queued-1"),
                         (result["status"], result["classification"], result["queued_submission_id"]))
        self.assertEqual([("thread/queue/add", {
            "threadId": "thread", "clientUserMessageId": "attempt",
            "input": [{"type": "text", "text": text}],
        })], client.calls)

    def test_invalid_input_never_connects_or_submits(self):
        client = Client([])
        for args in [("../thread", "hello", "attempt"), ("thread", " ", "attempt"),
                     ("thread", "hello", "a/b"), ("thread", None, "attempt")]:
            with self.subTest(args=args):
                self.assertEqual("definitive", bridge_codex.enqueue(*args, client=client)["classification"])
        self.assertEqual([], client.calls)

    def test_protocol_rejections_are_definitive_and_never_retried(self):
        for code in [-32600, -32601, -32602]:
            client = Client([AdapterError(EXIT_SERVER_ERROR, "request", "rejected", details={"code": code})])
            result = bridge_codex.enqueue("thread", "hello", "attempt", client=client)
            self.assertEqual("failed", result["status"])
            self.assertEqual("definitive", result["classification"])
            self.assertEqual(1, len(client.calls))

    def test_internal_errors_transport_loss_and_bad_receipts_are_ambiguous(self):
        values = [TimeoutError("lost response"), AdapterError(EXIT_EOF, "transport", "closed"),
                  AdapterError(EXIT_SERVER_ERROR, "request", "internal", details={"code": -32603}),
                  None, {"queuedSubmission": item(client="other")},
                  {"queuedSubmission": item(text="different")},
                  {"queuedSubmission": item(queue_id="")}]
        for value in values:
            with self.subTest(value=value):
                client = Client([value])
                result = bridge_codex.enqueue("thread", "hello", "attempt", client=client)
                self.assertEqual("ambiguous", result["status"])
                self.assertEqual(1, len(client.calls))

    def test_reconcile_pages_without_resubmitting(self):
        client = Client([{"data": [item(client="other")], "nextCursor": "next"},
                         {"data": [item()], "nextCursor": None}])
        result = bridge_codex.reconcile("thread", "hello", "attempt", client=client)
        self.assertEqual("queued-1", result["queued_submission_id"])
        self.assertEqual(["thread/queue/list"] * 2, [x[0] for x in client.calls])
        self.assertEqual("next", client.calls[1][1]["cursor"])

    def test_reconcile_absence_is_not_permission_to_resend(self):
        client = Client([{"data": [], "nextCursor": None}])
        result = bridge_codex.reconcile("thread", "hello", "attempt", client=client)
        self.assertEqual(("not_found", "ambiguous"), (result["status"], result["classification"]))

    def test_reconcile_detects_duplicates_conflicts_and_bad_pagination(self):
        cases = [[{"data": [item(), item(queue_id="queued-2")], "nextCursor": None}],
                 [{"data": [item(text="conflict")], "nextCursor": None}],
                 [{"data": [], "nextCursor": "same"}, {"data": [], "nextCursor": "same"}],
                 [{"data": []}], [{"data": [None], "nextCursor": None}]]
        for responses in cases:
            with self.subTest(responses=responses):
                client = Client(responses)
                self.assertEqual("ambiguous", bridge_codex.reconcile("thread", "hello", "attempt", client=client)["status"])

    def test_discovery_failure_precedes_submission(self):
        with patch.object(bridge_codex, "discover_runtime", side_effect=ValueError("missing")):
            self.assertEqual("definitive", bridge_codex.enqueue("thread", "hello", "attempt")["classification"])

    def test_cleanup_failure_keeps_accepted_receipt(self):
        class Owned(Client):
            def __init__(self, *args, **kwargs):
                super().__init__([{"queuedSubmission": item()}])
            def connect(self): pass
            def initialize(self, **kwargs):
                self.capabilities = kwargs
                return {"userAgent": "codex/0.167.0"}
            def close(self): raise TimeoutError("cleanup")
        with patch.object(bridge_codex, "AppServerClient", Owned):
            result = bridge_codex.enqueue("thread", "hello", "attempt", Runtime("/unused", "fixture", "0.167.0"))
        self.assertEqual("queued", result["status"])
        self.assertIn("cleanup_error", result)


PROXY = r'''#!/usr/bin/env python3
import json, os, sys
for line in sys.stdin:
    message=json.loads(line)
    with open(os.environ['BRIDGE_FIXTURE_LOG'], 'a') as handle:
        handle.write(json.dumps(message)+'\n')
    method=message['method']
    if method=='initialized': continue
    if method=='initialize':
        result={'userAgent':'codex/0.167.0','codexHome':'/fixture','platformFamily':'unix','platformOs':'macos'}
    elif method=='thread/queue/add':
        if os.environ.get('BRIDGE_FIXTURE_MODE')=='lost': sys.exit(0)
        params=message['params']
        result={'queuedSubmission':{'id':'native-queue-id','clientUserMessageId':params['clientUserMessageId'],'input':params['input']}}
    else: raise AssertionError('unexpected mutation: '+method)
    print(json.dumps({'id':message['id'],'result':result}),flush=True)
'''


class ProxyBoundaryTests(unittest.TestCase):
    def test_initialize_default_preserves_empty_capabilities(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "codex"
            executable.write_text(PROXY)
            executable.chmod(0o700)
            log = root / "calls.jsonl"
            env = {"CCTRL_CODEX_APP_SERVER_TRANSPORT": "jsonl",
                   "BRIDGE_FIXTURE_LOG": str(log)}
            with patch.dict(os.environ, env):
                with AppServerClient(Runtime(str(executable), "fixture", "0.167.0"),
                                     socket_path="/fixture/no-live-socket") as connection:
                    connection.initialize()
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual({}, calls[0]["params"]["capabilities"])

    def test_real_proxy_pipes_accept_and_lost_receipt(self):
        for mode, expected in [("accept", "queued"), ("lost", "ambiguous")]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                executable = root / "codex"
                executable.write_text(PROXY)
                executable.chmod(0o700)
                log = root / "calls.jsonl"
                env = {"CCTRL_CODEX_APP_SERVER_SOCKET": "/fixture/no-live-socket",
                       "CCTRL_CODEX_APP_SERVER_TRANSPORT": "jsonl",
                       "BRIDGE_FIXTURE_LOG": str(log), "BRIDGE_FIXTURE_MODE": mode}
                with patch.dict(os.environ, env):
                    result = bridge_codex.enqueue("thread", "hello", "attempt",
                        Runtime(str(executable), "isolated-fixture", "0.167.0"))
                self.assertEqual(expected, result["status"])
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual(["initialize", "initialized", "thread/queue/add"],
                                 [call["method"] for call in calls])
                self.assertEqual({"experimentalApi": True}, calls[0]["params"]["capabilities"])


if __name__ == "__main__":
    unittest.main()
