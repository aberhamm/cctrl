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


class RetireTests(unittest.TestCase):
    def test_retire_deletes_only_the_exactly_identified_item(self):
        client = Client([{"data": [item(client="other", queue_id="o")], "nextCursor": "n"},
                         {"data": [item()], "nextCursor": None}, {"deleted": True}])
        result = bridge_codex.retire("thread", "attempt", "queued-1", client=client)
        self.assertEqual("retired", result["outcome"])
        self.assertEqual(("thread/queue/delete", {"threadId": "thread", "queuedSubmissionId": "queued-1"}), client.calls[-1])
        self.assertEqual(["thread/queue/list"] * 2 + ["thread/queue/delete"], [c[0] for c in client.calls])

    def test_thread_facts_reads_title_and_source_only(self):
        client = Client([{"thread": {"id": "t", "name": "Title", "source": "vscode"}}])
        self.assertEqual({"status": "ok", "name": "Title", "source": "vscode"}, bridge_codex.thread_facts("t", client=client))
        self.assertEqual([("thread/read", {"threadId": "t", "includeTurns": False})], client.calls)
        self.assertEqual({}, bridge_codex.thread_facts("t", client=Client([TimeoutError("x")])))
        self.assertEqual({}, bridge_codex.thread_facts("t", client=Client([{"thread": {"id": "other"}}])))

    def test_retire_absent_never_deletes(self):
        client = Client([{"data": [item(client="other")], "nextCursor": None}])
        self.assertEqual("absent", bridge_codex.retire("thread", "attempt", "queued-1", client=client)["outcome"])
        self.assertEqual(["thread/queue/list"], [c[0] for c in client.calls])

    def test_retire_refuses_identity_mismatch_without_touching_the_queue(self):
        for entries in ([item(queue_id="someone-elses")], [item(), item(queue_id="queued-2")]):
            client = Client([{"data": entries, "nextCursor": None}])
            self.assertEqual("identity_mismatch", bridge_codex.retire("thread", "attempt", "queued-1", client=client)["outcome"])
            self.assertEqual(["thread/queue/list"], [c[0] for c in client.calls])

    def test_retire_never_matches_on_text(self):
        client = Client([{"data": [item(text="other body")], "nextCursor": None}, {"deleted": True}])
        self.assertEqual("retired", bridge_codex.retire("thread", "attempt", "queued-1", client=client)["outcome"])
        client = Client([{"data": [item(client="other", text="hello")], "nextCursor": None}])
        self.assertEqual("absent", bridge_codex.retire("thread", "attempt", "queued-1", client=client)["outcome"])

    def test_retire_race_outcomes(self):
        gone = Client([{"data": [item()], "nextCursor": None}, {"deleted": False}, {"data": [], "nextCursor": None}])
        self.assertEqual("already_consumed", bridge_codex.retire("thread", "attempt", "queued-1", client=gone)["outcome"])
        still = Client([{"data": [item()], "nextCursor": None}, {"deleted": False}, {"data": [item()], "nextCursor": None}])
        self.assertEqual("race", bridge_codex.retire("thread", "attempt", "queued-1", client=still)["outcome"])

    def test_retire_transport_loss_and_bad_identity_are_unknown_not_assumed(self):
        lost = Client([{"data": [item()], "nextCursor": None}, TimeoutError("lost")])
        self.assertEqual("unknown", bridge_codex.retire("thread", "attempt", "queued-1", client=lost)["outcome"])
        bad = Client([])
        self.assertEqual("unknown", bridge_codex.retire("thread", "a/b", "queued-1", client=bad)["outcome"])
        self.assertEqual([], bad.calls)


# --- steer (P1): evidence in ~/.local/state/fleet/orch-cctrl-reports/steer-p0.md and steer-p0b.md ---

def rpc_error(message, code=-32600):
    return AdapterError(EXIT_SERVER_ERROR, "request", "App Server returned a JSON-RPC error",
                        details={"code": code, "message": message})


def thread_read(status="active", flags=(), direct=True, thread_id="thread", turns=None):
    thread = {"id": thread_id, "status": {"type": status}, "canAcceptDirectInput": direct}
    if status == "active":
        thread["status"]["activeFlags"] = list(flags)
    if turns is not None:
        thread["turns"] = turns
    return {"thread": thread}


def turn(turn_id="T1", status="inProgress", items=(), completed=None):
    return {"id": turn_id, "status": status, "completedAt": completed, "items": list(items)}


STEER_OK = {"turnId": "T1"}
MUTATING = {"thread/resume", "turn/start", "turn/interrupt", "thread/queue/start", "thread/queue/add"}


class Scripted:
    """Per-method scripted fake: each method has a list; the last entry repeats."""

    def __init__(self, **scripts):
        self.scripts = {k.replace("__", "/"): list(v) for k, v in scripts.items()}
        self.calls = []

    def request(self, method, params):
        self.calls.append((method, params))
        script = self.scripts.get(method)
        if not script:
            raise AssertionError("unscripted call: " + method)
        value = script.pop(0) if len(script) > 1 else script[0]
        if isinstance(value, Exception):
            raise value
        return value

    def methods(self):
        return [c[0] for c in self.calls]


def healthy(**over):
    base = dict(thread__loaded__list=[{"data": ["other", "thread"], "nextCursor": None}],
                thread__read=[thread_read()],
                thread__turns__list=[{"data": [turn()], "nextCursor": None}],
                turn__steer=[STEER_OK])
    base.update(over)
    return Scripted(**base)


class SteerTests(unittest.TestCase):
    def run_steer(self, client, text="stop now"):
        result = bridge_codex.steer("thread", text, "msg-1", client=client)
        self.assertFalse(MUTATING & set(client.methods()), client.methods())
        return result

    def test_steer_call_sequence_and_exact_arguments(self):
        text = "stop\n$literal `content`"
        client = healthy()
        result = self.run_steer(client, text)
        self.assertEqual(["thread/loaded/list", "thread/read", "thread/turns/list", "turn/steer"],
                         client.methods())
        self.assertEqual(("turn/steer", {
            "threadId": "thread", "expectedTurnId": "T1", "clientUserMessageId": "msg-1",
            "input": [{"type": "text", "text": text}]}), client.calls[-1])
        self.assertEqual(("steered", "accepted", "T1", "T1"),
                         (result["status"], result["classification"], result["turn_id"],
                          result["expected_turn_id"]))
        self.assertEqual(("thread", "msg-1"), (result["thread_id"], result["client_id"]))
        self.assertEqual({"threadId": "thread", "includeTurns": False}, client.calls[1][1])
        self.assertEqual({"threadId": "thread", "limit": 1, "sortDirection": "desc",
                          "itemsView": "notLoaded"}, client.calls[2][1])

    def test_loaded_list_is_paged(self):
        client = healthy(thread__loaded__list=[{"data": ["a"], "nextCursor": "c1"},
                                               {"data": ["thread"], "nextCursor": None}])
        self.assertEqual("steered", self.run_steer(client)["status"])
        self.assertEqual("c1", client.calls[1][1]["cursor"])

    def test_loaded_list_bad_pagination_is_unknown_and_never_steers(self):
        for pages in ([{"data": [], "nextCursor": "x"}, {"data": [], "nextCursor": "x"}],
                      [{"data": "nope", "nextCursor": None}], [{"data": ["a"]}]):
            with self.subTest(pages=pages):
                client = healthy(thread__loaded__list=pages)
                result = self.run_steer(client)
                self.assertEqual(("skipped", "unknown"), (result["status"], result["outcome"]))
                self.assertNotIn("turn/steer", client.methods())

    def test_absent_from_loaded_list_is_not_loaded(self):
        client = healthy(thread__loaded__list=[{"data": ["other"], "nextCursor": None}])
        result = self.run_steer(client)
        self.assertEqual(("skipped", "not_loaded", "definitive"),
                         (result["status"], result["outcome"], result["classification"]))
        self.assertIn("not loaded", result["reason"])
        self.assertEqual(["thread/loaded/list"], client.methods())

    def test_not_loaded_status_is_not_loaded(self):
        client = healthy(thread__read=[thread_read(status="notLoaded", direct=None)])
        result = self.run_steer(client)
        self.assertEqual("not_loaded", result["outcome"])
        self.assertNotIn("turn/steer", client.methods())

    def test_no_direct_input_for_false_or_null(self):
        for direct in (False, None):
            with self.subTest(direct=direct):
                client = healthy(thread__read=[thread_read(direct=direct)])
                result = self.run_steer(client)
                self.assertEqual("no_direct_input", result["outcome"])
                self.assertNotIn("turn/steer", client.methods())

    def test_idle_thread_never_steers_or_starts_a_turn(self):
        client = healthy(thread__read=[thread_read(status="idle")])
        result = self.run_steer(client)
        self.assertEqual(("skipped", "idle"), (result["status"], result["outcome"]))
        self.assertEqual(["thread/loaded/list", "thread/read"], client.methods())

    def test_system_error_and_odd_status_are_unknown(self):
        for status in ("systemError", "weird"):
            with self.subTest(status=status):
                client = healthy(thread__read=[thread_read(status=status)])
                self.assertEqual("unknown", self.run_steer(client)["outcome"])
                self.assertNotIn("turn/steer", client.methods())

    def test_any_active_flag_is_busy_flag(self):
        for flags in (["waitingOnApproval"], ["waitingOnUserInput"], ["waitingOnApproval", "x"]):
            with self.subTest(flags=flags):
                client = healthy(thread__read=[thread_read(flags=flags)])
                result = self.run_steer(client)
                self.assertEqual("busy_flag", result["outcome"])
                self.assertNotIn("turn/steer", client.methods())
                self.assertNotIn("thread/turns/list", client.methods())

    def test_missing_or_malformed_flags_do_not_count_as_clear(self):
        # steer-p0b: the server ACCEPTS a steer while waitingOnApproval and may drop it.
        for status in ({"type": "active"}, {"type": "active", "activeFlags": None},
                       {"type": "active", "activeFlags": "x"}):
            with self.subTest(status=status):
                read = thread_read()
                read["thread"]["status"] = status
                client = healthy(thread__read=[read])
                self.assertEqual("unknown", self.run_steer(client)["outcome"])
                self.assertNotIn("turn/steer", client.methods())

    def test_thread_read_identity_mismatch_is_unknown(self):
        client = healthy(thread__read=[thread_read(thread_id="someone-else")])
        self.assertEqual("unknown", self.run_steer(client)["outcome"])
        self.assertNotIn("turn/steer", client.methods())

    def test_pre_steer_transport_failure_skips_safely(self):
        for method in ("thread__loaded__list", "thread__read", "thread__turns__list"):
            with self.subTest(method=method):
                over = {method: [TimeoutError("lost")]}
                if method == "thread__turns__list":
                    over["thread__read"] = [thread_read(), thread_read(turns=[])]
                client = healthy(**over)
                result = self.run_steer(client)
                self.assertEqual("skipped", result["status"])
                self.assertNotIn("turn/steer", client.methods())

    def test_turns_list_unsupported_falls_back_to_thread_read_with_turns(self):
        client = healthy(thread__turns__list=[rpc_error("method not found", -32601)],
                         thread__read=[thread_read(), thread_read(turns=[turn("T0", "completed"), turn("T1")])])
        result = self.run_steer(client)
        self.assertEqual("steered", result["status"])
        self.assertEqual(["thread/loaded/list", "thread/read", "thread/turns/list",
                          "thread/read", "turn/steer"], client.methods())
        self.assertEqual({"threadId": "thread", "includeTurns": True}, client.calls[3][1])

    def test_fallback_uses_only_the_last_turn(self):
        client = healthy(thread__turns__list=[rpc_error("method not found", -32601)],
                         thread__read=[thread_read(), thread_read(turns=[turn("T0"), turn("T1", "completed")])])
        result = self.run_steer(client)
        self.assertEqual("turn_unknown", result["outcome"])
        self.assertNotIn("turn/steer", client.methods())

    def test_both_turn_sources_failing_is_turn_unknown(self):
        client = healthy(thread__turns__list=[rpc_error("method not found", -32601)],
                         thread__read=[thread_read(), TimeoutError("lost")])
        result = self.run_steer(client)
        self.assertEqual(("skipped", "turn_unknown"), (result["status"], result["outcome"]))
        self.assertNotIn("turn/steer", client.methods())

    def test_interrupted_null_completed_while_active_is_turn_unknown(self):
        # steer-p0 TUI shape: a running turn from another process reads as interrupted.
        client = healthy(thread__turns__list=[{"data": [turn("T1", "interrupted", completed=None)],
                                               "nextCursor": None}])
        result = self.run_steer(client)
        self.assertEqual("turn_unknown", result["outcome"])
        self.assertNotIn("turn/steer", client.methods())

    def test_empty_or_malformed_turns_page_is_turn_unknown(self):
        for page in ({"data": [], "nextCursor": None}, {"data": [{"status": "inProgress"}]},
                     {"data": "x"}, None):
            with self.subTest(page=page):
                client = healthy(thread__turns__list=[page])
                self.assertEqual("turn_unknown", self.run_steer(client)["outcome"])
                self.assertNotIn("turn/steer", client.methods())

    def test_stale_turn_once_then_success_rereads_and_steers_again(self):
        stale = rpc_error("expected active turn id `T0` but found `T1`")
        client = healthy(thread__turns__list=[{"data": [turn("T0")], "nextCursor": None},
                                              {"data": [turn("T1")], "nextCursor": None}],
                         turn__steer=[stale, STEER_OK])
        result = self.run_steer(client)
        self.assertEqual(("steered", "T1"), (result["status"], result["turn_id"]))
        steers = [c for c in client.calls if c[0] == "turn/steer"]
        self.assertEqual(["T0", "T1"], [c[1]["expectedTurnId"] for c in steers])
        self.assertEqual(["msg-1", "msg-1"], [c[1]["clientUserMessageId"] for c in steers])

    def test_stale_turn_twice_is_stale_turn_after_exactly_two_steers(self):
        stale = rpc_error("expected active turn id `T0` but found `T1`")
        client = healthy(turn__steer=[stale, stale])
        result = self.run_steer(client)
        self.assertEqual(("skipped", "stale_turn", "definitive"),
                         (result["status"], result["outcome"], result["classification"]))
        self.assertEqual(2, client.methods().count("turn/steer"))

    def test_no_active_turn_error_is_stale_and_retried_once(self):
        client = healthy(turn__steer=[rpc_error("no active turn to steer")])
        result = self.run_steer(client)
        self.assertEqual("stale_turn", result["outcome"])
        self.assertEqual(2, client.methods().count("turn/steer"))

    def test_retry_that_finds_no_running_turn_is_stale_turn_without_second_steer(self):
        client = healthy(thread__turns__list=[{"data": [turn("T1")], "nextCursor": None},
                                              {"data": [turn("T1", "completed")], "nextCursor": None}],
                         turn__steer=[rpc_error("no active turn to steer")])
        result = self.run_steer(client)
        self.assertEqual("stale_turn", result["outcome"])
        self.assertEqual(1, client.methods().count("turn/steer"))

    def test_retry_rechecks_active_flags_before_the_second_steer(self):
        client = healthy(thread__read=[thread_read(), thread_read(flags=["waitingOnApproval"])],
                         turn__steer=[rpc_error("no active turn to steer"), STEER_OK])
        result = self.run_steer(client)
        self.assertEqual("busy_flag", result["outcome"])
        self.assertEqual(1, client.methods().count("turn/steer"))

    def test_thread_not_found_from_steer_is_not_loaded_with_no_retry(self):
        client = healthy(turn__steer=[rpc_error("thread not found: thread")])
        result = self.run_steer(client)
        self.assertEqual(("skipped", "not_loaded"), (result["status"], result["outcome"]))
        self.assertEqual(1, client.methods().count("turn/steer"))

    def test_other_32600_text_stays_ambiguous_and_is_not_retried(self):
        for message in ("invalid request", "", None, "no active turn to steer, sorry",
                        "expected active turn id missing"):
            with self.subTest(message=message):
                client = healthy(turn__steer=[rpc_error(message)])
                result = self.run_steer(client)
                self.assertEqual("ambiguous", result["status"])
                self.assertEqual(1, client.methods().count("turn/steer"))

    def test_allow_listed_text_requires_code_32600(self):
        client = healthy(turn__steer=[rpc_error("no active turn to steer", code=-32603)])
        self.assertEqual("ambiguous", self.run_steer(client)["status"])
        self.assertEqual(1, client.methods().count("turn/steer"))

    def test_transport_loss_after_the_steer_write_is_ambiguous_without_retry(self):
        for exc in (TimeoutError("lost"), AdapterError(EXIT_EOF, "transport", "closed"),
                    rpc_error("internal", code=-32603)):
            with self.subTest(exc=exc):
                client = healthy(turn__steer=[exc])
                result = self.run_steer(client)
                self.assertEqual(("ambiguous", "ambiguous"), (result["status"], result["classification"]))
                self.assertEqual(1, client.methods().count("turn/steer"))

    def test_malformed_or_mismatched_steer_responses_are_ambiguous(self):
        for value in ({"turnId": "OTHER"}, {"turnId": ""}, {}, None, "x"):
            with self.subTest(value=value):
                client = healthy(turn__steer=[value])
                result = self.run_steer(client)
                self.assertEqual("ambiguous", result["status"])
                self.assertEqual(1, client.methods().count("turn/steer"))

    def test_invalid_input_never_calls_the_server(self):
        client = healthy()
        for args in [("../t", "hi", "m"), ("thread", " ", "m"), ("thread", "hi", "a/b"),
                     ("thread", None, "m")]:
            with self.subTest(args=args):
                self.assertEqual("definitive", bridge_codex.steer(*args, client=client)["classification"])
        self.assertEqual([], client.calls)

    def test_discovery_failure_precedes_steer(self):
        with patch.object(bridge_codex, "discover_runtime", side_effect=ValueError("missing")):
            result = bridge_codex.steer("thread", "hi", "m")
        self.assertEqual(("failed", "definitive"), (result["status"], result["classification"]))

    def test_cleanup_failure_keeps_accepted_steer(self):
        class Owned(Scripted):
            def __init__(self, *args, **kwargs):
                super().__init__()
                self.scripts = healthy().scripts
            def connect(self): pass
            def initialize(self, **kwargs): return {"userAgent": "codex/0.167.0"}
            def close(self): raise TimeoutError("cleanup")
        with patch.object(bridge_codex, "AppServerClient", Owned):
            result = bridge_codex.steer("thread", "hi", "m", Runtime("/unused", "fixture", "0.167.0"))
        self.assertEqual("steered", result["status"])
        self.assertIn("cleanup_error", result)

    def test_active_turn_helper(self):
        client = healthy()
        result = bridge_codex.active_turn("thread", client=client)
        self.assertEqual(("ok", "T1", "turns/list"), (result["status"], result["turn_id"], result["source"]))
        none = bridge_codex.active_turn("thread", client=healthy(
            thread__turns__list=[{"data": [turn("T1", "completed")], "nextCursor": None}]))
        self.assertEqual("none", none["status"])
        self.assertEqual("failed", bridge_codex.active_turn("../x", client=healthy())["status"])


class SteerDeliveryTests(unittest.TestCase):
    """An accepted steer is not proof of delivery (steer-p0b: dropped during waitingOnApproval)."""

    def history(self, items, status="inProgress", turn_id="T1"):
        return Scripted(thread__read=[thread_read(turns=[turn("T0", "completed"), turn(turn_id, status, items)])])

    def user(self, client_id="msg-1"):
        return {"type": "userMessage", "clientId": client_id, "content": [{"type": "text", "text": "x"}]}

    def test_confirmed_when_client_id_is_in_the_steered_turn(self):
        client = self.history([{"type": "agentMessage"}, self.user()])
        result = bridge_codex.confirm_steer("thread", "msg-1", "T1", client=client)
        self.assertEqual("confirmed", result["outcome"])
        self.assertEqual([("thread/read", {"threadId": "thread", "includeTurns": True})], client.calls)

    def test_in_progress_turn_without_it_is_pending(self):
        result = bridge_codex.confirm_steer("thread", "msg-1", "T1", client=self.history([self.user("other")]))
        self.assertEqual("pending", result["outcome"])

    def test_ended_turn_without_it_is_lost_and_never_requeued_here(self):
        for status in ("completed", "interrupted", "failed"):
            with self.subTest(status=status):
                client = self.history([{"type": "agentMessage"}], status=status)
                result = bridge_codex.confirm_steer("thread", "msg-1", "T1", client=client)
                self.assertEqual("lost", result["outcome"])
                self.assertEqual(["thread/read"], [c[0] for c in client.calls])

    def test_match_is_by_client_id_in_that_turn_only_never_text(self):
        other_turn = Scripted(thread__read=[thread_read(turns=[
            turn("T0", "completed", [self.user()]), turn("T1", "completed", [])])])
        self.assertEqual("lost", bridge_codex.confirm_steer("thread", "msg-1", "T1", client=other_turn)["outcome"])
        same_text = self.history([{"type": "userMessage", "content": [{"type": "text", "text": "stop now"}]}], "completed")
        self.assertEqual("lost", bridge_codex.confirm_steer("thread", "msg-1", "T1", client=same_text)["outcome"])

    def test_duplicates_missing_turn_and_failures_are_unknown(self):
        cases = [self.history([self.user(), self.user()]),
                 Scripted(thread__read=[thread_read(turns=[turn("T9", "completed")])]),
                 Scripted(thread__read=[thread_read(thread_id="x", turns=[])]),
                 Scripted(thread__read=[{"thread": {"id": "thread"}}]),
                 Scripted(thread__read=[rpc_error("method not found", -32601)]),
                 Scripted(thread__read=[TimeoutError("lost")])]
        for client in cases:
            with self.subTest(calls=client.scripts):
                result = bridge_codex.confirm_steer("thread", "msg-1", "T1", client=client)
                self.assertEqual("unknown", result["outcome"])

    def test_invalid_identity_is_unknown_without_a_call(self):
        client = Scripted()
        self.assertEqual("unknown", bridge_codex.confirm_steer("thread", "a/b", "T1", client=client)["outcome"])
        self.assertEqual("unknown", bridge_codex.confirm_steer("thread", "msg-1", "", client=client)["outcome"])
        self.assertEqual([], client.calls)

    def test_reconcile_steer_branch_never_lists_the_queue(self):
        cases = [("confirmed", [self.user()], "inProgress", "steered", "accepted"),
                 ("pending", [], "inProgress", "steer_pending", "ambiguous"),
                 ("lost", [], "completed", "steer_lost", "ambiguous")]
        for outcome, items, status, expect, klass in cases:
            with self.subTest(outcome=outcome):
                client = self.history(items, status)
                result = bridge_codex.reconcile("thread", "stop now", "msg-1", client=client,
                                                steer_turn_id="T1")
                self.assertEqual((expect, klass, outcome), (result["status"], result["classification"],
                                                            result["outcome"]))
                self.assertEqual(["thread/read"], [c[0] for c in client.calls])

    def test_reconcile_steer_branch_reports_unreconcilable_on_error(self):
        client = Scripted(thread__read=[rpc_error("method not found", -32601)])
        result = bridge_codex.reconcile("thread", "x", "msg-1", client=client, steer_turn_id="T1")
        self.assertEqual(("ambiguous", "ambiguous"), (result["status"], result["classification"]))

    def test_reconcile_without_steer_turn_id_is_unchanged(self):
        client = Client([{"data": [], "nextCursor": None}])
        self.assertEqual("not_found", bridge_codex.reconcile("thread", "hello", "attempt", client=client)["status"])
        self.assertEqual(["thread/queue/list"], [c[0] for c in client.calls])



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
