"""Single-attempt native Codex user-queue delivery through an existing server.

Queue acceptance is not execution, handling, or a reply. This adapter never
resumes a thread, acquires its history writer, or retries a mutation.

steer() adds text to a running turn of a thread that the shared app server has
loaded (Codex desktop-app threads). It never calls turn/start, turn/interrupt,
thread/resume or any queue method. Evidence: steer-p0.md and steer-p0b.md.
"""
from __future__ import annotations

import os
import re
from typing import Any, Callable

from codex_app_server import (
    AdapterError, AppServerClient, Runtime, discover_runtime, _extract_version,
    EXIT_SERVER_ERROR,
)


def _identity(thread_id: str, text: str, client_id: str) -> dict[str, Any]:
    for name, value in (("thread_id", thread_id), ("client_id", client_id)):
        if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,160}", value):
            raise ValueError(f"invalid {name}")
    if not isinstance(text, str) or not text.strip():
        raise ValueError("message text must not be empty")
    return {"thread_id": thread_id, "client_id": client_id}


def _error(exc: Exception) -> dict[str, Any]:
    return exc.as_dict() if isinstance(exc, AdapterError) else {"reason": str(exc)}


def _failed(exc: Exception, *, ambiguous: bool = False) -> dict[str, Any]:
    return {
        "status": "ambiguous" if ambiguous else "failed",
        "classification": "ambiguous" if ambiguous else "definitive",
        "reason": str(exc), "error": _error(exc),
    }


def _with_client(action: Callable[[Any], dict[str, Any]], runtime: Runtime | None,
                 client: Any) -> dict[str, Any]:
    if client is not None:
        return action(client)
    owned = None
    result = None
    try:
        runtime = runtime or discover_runtime(os.environ.get("CCTRL_CODEX_BIN") or None)
        owned = AppServerClient(
            runtime, socket_path=os.environ.get("CCTRL_CODEX_APP_SERVER_SOCKET") or None,
        )
        owned.connect()
        # The native queue methods are experimental in Codex 0.167.0.
        facts = owned.initialize(experimental=True)
        if _extract_version(facts.get("userAgent", "")) != runtime.cli_version:
            raise ValueError("Codex executable does not match connected server version")
        result = action(owned)
    except Exception as exc:
        result = _failed(exc)
    finally:
        if owned is not None:
            try:
                owned.close()
            except Exception as exc:
                if result is None:
                    result = _failed(exc)
                else:
                    # Closing the proxy cannot revoke accepted or uncertain input.
                    result["cleanup_error"] = _error(exc)
    return result


def _queued(value: Any, text: str, client_id: str) -> str:
    if not isinstance(value, dict):
        raise ValueError("malformed queued submission")
    queue_id = value.get("id")
    if not isinstance(queue_id, str) or not queue_id:
        raise ValueError("queued submission has no ID")
    if value.get("clientUserMessageId") != client_id:
        raise ValueError("queued submission client ID mismatch")
    if value.get("input") != [{"type": "text", "text": text}]:
        # Providers may include the documented default text_elements field.
        content = value.get("input")
        if (not isinstance(content, list) or len(content) != 1
                or not isinstance(content[0], dict)
                or content[0].get("type") != "text" or content[0].get("text") != text
                or content[0].get("text_elements", []) != []):
            raise ValueError("queued submission content mismatch")
    return queue_id


def enqueue(thread_id: str, text: str, client_id: str, runtime: Runtime | None = None,
            *, client: Any = None) -> dict[str, Any]:
    """Enqueue once; injected clients must already be initialized.

    Callers must persist their attempt identity before entering this function.
    An ambiguous result prohibits an automatic resend. clientUserMessageId is
    correlation data, not a provider idempotency key.
    """
    try:
        identity = _identity(thread_id, text, client_id)
    except Exception as exc:
        return _failed(exc)

    def send(connection: Any) -> dict[str, Any]:
        try:
            response = connection.request("thread/queue/add", {
                "threadId": thread_id, "clientUserMessageId": client_id,
                "input": [{"type": "text", "text": text}],
            })
            queue_id = _queued(response.get("queuedSubmission")
                               if isinstance(response, dict) else None, text, client_id)
            return {"status": "queued", "classification": "accepted",
                    "queued_submission_id": queue_id}
        except Exception as exc:
            # Only protocol-level request rejection proves that queue code did
            # not run. Internal errors can follow a committed insertion.
            rejected = (isinstance(exc, AdapterError)
                        and exc.exit_code == EXIT_SERVER_ERROR
                        and isinstance(exc.details, dict)
                        and exc.details.get("code") in {-32600, -32601, -32602})
            return _failed(exc, ambiguous=not rejected)

    return {**_with_client(send, runtime, client), **identity}


def reconcile(thread_id: str, text: str, client_id: str, runtime: Runtime | None = None,
              *, client: Any = None, steer_turn_id: str | None = None) -> dict[str, Any]:
    """Find an attempt in native queue pages without submitting anything.

    not_found does not mean unsent: the owner may already have consumed it.
    History reconciliation and the persisted attempt still belong to the caller.

    With steer_turn_id the attempt was a turn/steer, so the queue is not
    consulted. The turn's history is searched for the steered clientId instead
    (see confirm_steer). Statuses: steered (found), steer_pending (turn still
    running, not found yet), steer_lost (turn ended without it; never auto
    requeue, surface it), ambiguous (cannot tell).
    """
    try:
        identity = _identity(thread_id, text, client_id)
    except Exception as exc:
        return _failed(exc)
    if steer_turn_id is not None:
        found = confirm_steer(thread_id, client_id, steer_turn_id, runtime, client=client)
        mapping = {"confirmed": ("steered", "accepted"),
                   "pending": ("steer_pending", "ambiguous"),
                   "lost": ("steer_lost", "ambiguous")}
        status, klass = mapping.get(found["outcome"], ("ambiguous", "ambiguous"))
        out = {**found, "status": status, "classification": klass}
        out.pop("client_id", None)
        out.pop("thread_id", None)
        return {**out, **identity}

    def find(connection: Any) -> dict[str, Any]:
        cursor = None
        seen = set()
        matches = []
        try:
            for _ in range(100):
                params = {"threadId": thread_id, "limit": 100}
                if cursor is not None:
                    params["cursor"] = cursor
                response = connection.request("thread/queue/list", params)
                if not isinstance(response, dict) or not isinstance(response.get("data"), list):
                    raise ValueError("malformed native queue page")
                for item in response["data"]:
                    if not isinstance(item, dict):
                        raise ValueError("malformed queued submission")
                    if item.get("clientUserMessageId") == client_id:
                        matches.append(_queued(item, text, client_id))
                if "nextCursor" not in response:
                    raise ValueError("native queue page has no pagination state")
                cursor = response["nextCursor"]
                if cursor is None:
                    break
                if not isinstance(cursor, str) or not cursor or cursor in seen:
                    raise ValueError("invalid native queue pagination cursor")
                seen.add(cursor)
            else:
                raise ValueError("native queue pagination limit reached")
            if len(matches) > 1:
                raise ValueError("multiple queued submissions share this client ID")
            if matches:
                return {"status": "queued", "classification": "accepted",
                        "queued_submission_id": matches[0]}
            return {"status": "not_found", "classification": "ambiguous",
                    "reason": "attempt is absent from queue; it may already have been consumed"}
        except Exception as exc:
            return _failed(exc, ambiguous=True)

    return {**_with_client(find, runtime, client), **identity}


def _list_matches(connection: Any, thread_id: str, client_id: str) -> list[dict[str, Any]]:
    """Return queued submissions whose clientUserMessageId equals client_id."""
    cursor = None
    seen = set()
    matches = []
    for _ in range(100):
        params = {"threadId": thread_id, "limit": 100}
        if cursor is not None:
            params["cursor"] = cursor
        response = connection.request("thread/queue/list", params)
        if not isinstance(response, dict) or not isinstance(response.get("data"), list):
            raise ValueError("malformed native queue page")
        for entry in response["data"]:
            if not isinstance(entry, dict):
                raise ValueError("malformed queued submission")
            if entry.get("clientUserMessageId") == client_id:
                matches.append(entry)
        if "nextCursor" not in response:
            raise ValueError("native queue page has no pagination state")
        cursor = response["nextCursor"]
        if cursor is None:
            return matches
        if not isinstance(cursor, str) or not cursor or cursor in seen:
            raise ValueError("invalid native queue pagination cursor")
        seen.add(cursor)
    raise ValueError("native queue pagination limit reached")


def retire(thread_id: str, client_id: str, queued_id: str, runtime: Runtime | None = None,
           *, client: Any = None) -> dict[str, Any]:
    """Retire one pending native queue item that this bridge itself submitted.

    Uses the supported thread/queue/delete request, only after thread/queue/list
    shows exactly one entry whose clientUserMessageId AND queued submission ID
    both equal the persisted attempt identity. Message text is never consulted.
    Outcomes (key "outcome"):
      retired          the item was pending and the provider deleted it
      absent           not in the queue; it may already have been consumed, and
                       absence is not proof either way (never replay)
      already_consumed delete reported nothing to delete and a re-list shows the
                       item gone: the owner consumed it inside the window
      race             delete reported nothing to delete yet the item is still
                       listed; left untouched for a later explicit retry
      identity_mismatch the queue holds this client ID under a different queue
                       ID, or several entries: nothing deleted
      unknown          transport or protocol failure; deletion may or may not
                       have happened, so callers must not assume either
    """
    try:
        _identity(thread_id, "x", client_id)
        _identity(thread_id, "x", queued_id)
    except Exception as exc:
        return {"outcome": "unknown", "reason": str(exc)}

    def act(connection: Any) -> dict[str, Any]:
        try:
            matches = _list_matches(connection, thread_id, client_id)
            if not matches:
                return {"outcome": "absent",
                        "reason": "not in the native queue; it may already have been consumed"}
            if len(matches) != 1 or matches[0].get("id") != queued_id:
                return {"outcome": "identity_mismatch",
                        "reason": "queue entry does not match the persisted submission identity; nothing deleted"}
            response = connection.request("thread/queue/delete", {
                "threadId": thread_id, "queuedSubmissionId": queued_id})
            if not isinstance(response, dict) or not isinstance(response.get("deleted"), bool):
                raise ValueError("malformed queue delete response")
            if response["deleted"]:
                return {"outcome": "retired"}
            still = _list_matches(connection, thread_id, client_id)
            if still:
                return {"outcome": "race",
                        "reason": "provider reported nothing deleted but the item is still queued"}
            return {"outcome": "already_consumed",
                    "reason": "item left the queue before delete took effect"}
        except Exception as exc:
            return {"outcome": "unknown", "reason": str(exc), "error": _error(exc)}

    result = _with_client(act, runtime, client)
    if "outcome" not in result:
        result = {"outcome": "unknown", "reason": result.get("reason", "native queue unavailable"),
                  "error": result.get("error")}
    return {**result, "thread_id": thread_id, "client_id": client_id,
            "queued_submission_id": queued_id}


def thread_facts(thread_id: str, runtime: Runtime | None = None, *, client: Any = None) -> dict[str, Any]:
    """Read-only provider-reported thread title and origin (thread/read, no turns).

    Never resumes the thread or takes its history writer. Any failure returns
    {} so callers record the fields as unknown instead of guessing.
    """
    try:
        _identity(thread_id, "x", "x")
    except Exception:
        return {}

    def read(connection: Any) -> dict[str, Any]:
        try:
            response = connection.request("thread/read", {"threadId": thread_id, "includeTurns": False})
            thread = response.get("thread") if isinstance(response, dict) else None
            if not isinstance(thread, dict) or thread.get("id", thread_id) != thread_id:
                return {"status": "failed"}
            source = thread.get("source")
            if isinstance(source, dict):
                source = next(iter(source), None)
            return {"status": "ok",
                    "name": thread.get("name") if isinstance(thread.get("name"), str) else None,
                    "source": source if isinstance(source, str) else None}
        except Exception:
            return {"status": "failed"}

    result = _with_client(read, runtime, client)
    return result if result.get("status") == "ok" else {}


# --- steer -----------------------------------------------------------------

_STALE_TURN = (re.compile(r"no active turn to steer"),
               re.compile(r"expected active turn id `[^`]+` but found `[^`]+`"))
_NOT_FOUND = re.compile(r"thread not found: ")

STEER_REASONS = {
    "not_loaded": "recipient thread is not loaded in the shared Codex app server "
                  "(a cctrl tmux or CLI Codex runs its own server); queued instead",
    "no_direct_input": "recipient thread does not accept direct input "
                       "(for example a sub-agent thread); queued instead",
    "idle": "recipient has no running turn; queued instead (it starts on the queue)",
    "busy_flag": "recipient turn is waiting on an approval or input; queued instead",
    "turn_unknown": "cannot read the recipient's active turn; queued instead",
    "stale_turn": "the recipient's turn changed while steering; queued instead",
    "unknown": "cannot confirm the recipient is steerable; queued instead",
}


class _Skip(Exception):
    def __init__(self, outcome: str, detail: str | None = None):
        super().__init__(outcome)
        self.outcome = outcome
        self.detail = detail


def _skipped(outcome: str, detail: str | None = None) -> dict[str, Any]:
    reason = STEER_REASONS[outcome] + (f" ({detail})" if detail else "")
    return {"status": "skipped", "classification": "definitive",
            "outcome": outcome, "reason": reason}


def _rpc_error(exc: Exception) -> tuple[Any, str] | None:
    """(code, message) of a structured JSON-RPC rejection, else None."""
    if (isinstance(exc, AdapterError) and exc.exit_code == EXIT_SERVER_ERROR
            and isinstance(exc.details, dict)):
        message = exc.details.get("message")
        return exc.details.get("code"), message if isinstance(message, str) else ""
    return None


def _steer_rejection(exc: Exception) -> str | None:
    """Classify a turn/steer error: "stale", "not_loaded" or None (uncertain).

    The server uses -32600 for every error (steer-p0b), so the message text is
    matched against the measured allow-list and anything else stays uncertain.
    """
    parsed = _rpc_error(exc)
    if parsed is None or parsed[0] != -32600:
        return None
    message = parsed[1]
    if any(p.fullmatch(message) for p in _STALE_TURN):
        return "stale"
    if _NOT_FOUND.match(message):
        return "not_loaded"
    return None


def _loaded(connection: Any, thread_id: str) -> bool:
    cursor = None
    seen: set[str] = set()
    for _ in range(100):
        params: dict[str, Any] = {"limit": 1000}
        if cursor is not None:
            params["cursor"] = cursor
        page = connection.request("thread/loaded/list", params)
        ids = page.get("data") if isinstance(page, dict) else None
        if not isinstance(ids, list) or any(not isinstance(i, str) for i in ids):
            raise ValueError("malformed loaded-thread page")
        if thread_id in ids:
            return True
        if "nextCursor" not in page:
            raise ValueError("loaded-thread page has no pagination state")
        cursor = page["nextCursor"]
        if cursor is None:
            return False
        if not isinstance(cursor, str) or not cursor or cursor in seen:
            raise ValueError("invalid loaded-thread pagination cursor")
        seen.add(cursor)
    raise ValueError("loaded-thread pagination limit reached")


def _check_steerable(connection: Any, thread_id: str, *, check_loaded: bool = True) -> None:
    """Raise _Skip unless the thread is loaded, direct-input, active with no flags."""
    try:
        if check_loaded and not _loaded(connection, thread_id):
            raise _Skip("not_loaded")
        response = connection.request("thread/read", {"threadId": thread_id, "includeTurns": False})
    except _Skip:
        raise
    except Exception as exc:
        raise _Skip("unknown", str(exc))
    thread = response.get("thread") if isinstance(response, dict) else None
    if not isinstance(thread, dict) or thread.get("id") != thread_id:
        raise _Skip("unknown", "thread/read did not return this thread")
    status = thread.get("status")
    kind = status.get("type") if isinstance(status, dict) else None
    if kind == "notLoaded":
        raise _Skip("not_loaded")
    if thread.get("canAcceptDirectInput") is not True:
        raise _Skip("no_direct_input")
    if kind == "idle":
        raise _Skip("idle")
    if kind != "active":
        raise _Skip("unknown", f"thread status {kind!r}")
    flags = status.get("activeFlags")
    # Flags must be positively known to be empty: the server accepts a steer
    # while waitingOnApproval and may silently drop it (steer-p0b).
    if not isinstance(flags, list):
        raise _Skip("unknown", "thread status has no activeFlags list")
    if flags:
        raise _Skip("busy_flag")


def _turn_id(turns: Any) -> str | None:
    if isinstance(turns, list) and turns:
        last = turns[-1]
        if (isinstance(last, dict) and last.get("status") == "inProgress"
                and isinstance(last.get("id"), str) and last["id"]):
            return last["id"]
    return None


def _active_turn(connection: Any, thread_id: str) -> tuple[str | None, str | None]:
    """(turn id, source) of the thread's running turn, or (None, None).

    Primary is thread/turns/list. thread/read includeTurns is used only when
    turns/list errors, and only its last turn counts. A TUI-owned turn reads as
    interrupted (steer-p0), which yields no id.
    """
    try:
        page = connection.request("thread/turns/list", {
            "threadId": thread_id, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded"})
        data = page.get("data") if isinstance(page, dict) else None
        return (_turn_id(data), "turns/list") if isinstance(data, list) else (None, None)
    except Exception:
        pass
    try:
        response = connection.request("thread/read", {"threadId": thread_id, "includeTurns": True})
        thread = response.get("thread") if isinstance(response, dict) else None
        if not isinstance(thread, dict) or thread.get("id") != thread_id:
            return None, None
        return _turn_id(thread.get("turns")), "thread/read"
    except Exception:
        return None, None


def active_turn(thread_id: str, runtime: Runtime | None = None, *, client: Any = None) -> dict[str, Any]:
    """Read-only: the running turn id. status ok (turn_id, source), none, or failed."""
    try:
        _identity(thread_id, "x", "x")
    except Exception as exc:
        return _failed(exc)

    def read(connection: Any) -> dict[str, Any]:
        turn_id, source = _active_turn(connection, thread_id)
        if turn_id is None:
            return {"status": "none", "classification": "definitive"}
        return {"status": "ok", "classification": "definitive", "turn_id": turn_id, "source": source}

    return _with_client(read, runtime, client)


def steer(thread_id: str, text: str, client_id: str, runtime: Runtime | None = None,
          *, client: Any = None) -> dict[str, Any]:
    """Steer the thread's running turn once; never queue, resume, start or interrupt.

    Returns status:
      steered   turn/steer accepted for the expected turn (turn_id,
                expected_turn_id). Acceptance is NOT proof of delivery; use
                confirm_steer to look for client_id in the turn's history.
      skipped   nothing was committed (definitive); outcome is one of not_loaded,
                no_direct_input, idle, busy_flag, turn_unknown, stale_turn,
                unknown, with a reason for the sender. The caller may queue.
      ambiguous the steer may or may not have landed: no retry, no queue fallback.
      failed    invalid input or no runtime (definitive).
    Checks run in order on one connection: loaded list, thread/read (id, direct
    input, active, empty activeFlags), then the active turn. A stale-turn or
    no-active-turn rejection re-checks and steers once more.
    """
    try:
        identity = _identity(thread_id, text, client_id)
    except Exception as exc:
        return _failed(exc)

    def attempt(connection: Any, expected: str) -> tuple[str, Any]:
        """("steered", turn_id) | ("stale", None) | ("not_loaded", None) | ("ambiguous", result)."""
        try:
            response = connection.request("turn/steer", {
                "threadId": thread_id, "expectedTurnId": expected,
                "clientUserMessageId": client_id,
                "input": [{"type": "text", "text": text}]})
            turn_id = response.get("turnId") if isinstance(response, dict) else None
            if not isinstance(turn_id, str) or not turn_id:
                raise ValueError("malformed steer response")
            if turn_id != expected:
                raise ValueError("steer response turn does not match the expected turn")
            return "steered", turn_id
        except Exception as exc:
            rejection = _steer_rejection(exc)
            if rejection is not None:
                return rejection, None
            return "ambiguous", _failed(exc, ambiguous=True)

    def act(connection: Any) -> dict[str, Any]:
        try:
            _check_steerable(connection, thread_id)
            expected, _ = _active_turn(connection, thread_id)
            if expected is None:
                return _skipped("turn_unknown")
            for round_ in (1, 2):
                kind, value = attempt(connection, expected)
                if kind == "steered":
                    return {"status": "steered", "classification": "accepted",
                            "turn_id": value, "expected_turn_id": expected}
                if kind == "ambiguous":
                    return value
                if kind == "not_loaded":
                    return _skipped("not_loaded", "steer reported thread not found")
                # Definitive precondition rejection: nothing was committed.
                if round_ == 2:
                    return _skipped("stale_turn")
                _check_steerable(connection, thread_id, check_loaded=False)
                expected, _ = _active_turn(connection, thread_id)
                if expected is None:
                    return _skipped("stale_turn")
            return _skipped("stale_turn")
        except _Skip as skip:
            return _skipped(skip.outcome, skip.detail)

    return {**_with_client(act, runtime, client), **identity}


def confirm_steer(thread_id: str, client_id: str, turn_id: str, runtime: Runtime | None = None,
                  *, client: Any = None) -> dict[str, Any]:
    """Read-only delivery check for an accepted steer.

    Looks in the steered turn's items for exactly one userMessage whose
    clientId equals client_id (text is never consulted). outcome:
      confirmed  found
      pending    not found and the turn is still inProgress; check again later
      lost       not found and the turn has ended (the server accepted the steer
                 and dropped it, steer-p0b). Never auto-requeue: surface it.
      unknown    turn missing, duplicate matches, or any read failure
    """
    try:
        _identity(thread_id, "x", client_id)
        _identity(thread_id, "x", turn_id)
    except Exception as exc:
        return {"outcome": "unknown", "reason": str(exc)}

    def check(connection: Any) -> dict[str, Any]:
        try:
            response = connection.request("thread/read", {"threadId": thread_id, "includeTurns": True})
            thread = response.get("thread") if isinstance(response, dict) else None
            if not isinstance(thread, dict) or thread.get("id") != thread_id \
                    or not isinstance(thread.get("turns"), list):
                return {"outcome": "unknown", "reason": "thread/read returned no turn history"}
            turns = [t for t in thread["turns"] if isinstance(t, dict) and t.get("id") == turn_id]
            if len(turns) != 1:
                return {"outcome": "unknown", "reason": "steered turn is absent or duplicated in history"}
            items = turns[0].get("items")
            if not isinstance(items, list):
                return {"outcome": "unknown", "reason": "steered turn has no item list"}
            hits = [i for i in items if isinstance(i, dict) and i.get("type") == "userMessage"
                    and i.get("clientId") == client_id]
            if len(hits) > 1:
                return {"outcome": "unknown", "reason": "multiple user messages share this client ID"}
            if hits:
                return {"outcome": "confirmed"}
            if turns[0].get("status") == "inProgress":
                return {"outcome": "pending", "reason": "steered turn is still running"}
            if turns[0].get("status") in {"completed", "interrupted", "failed"}:
                return {"outcome": "lost",
                        "reason": "steered turn ended without the steered message in its history"}
            return {"outcome": "unknown", "reason": "unrecognised turn status"}
        except Exception as exc:
            return {"outcome": "unknown", "reason": str(exc), "error": _error(exc)}

    result = _with_client(check, runtime, client)
    if "outcome" not in result:
        result = {"outcome": "unknown", "reason": result.get("reason", "native history unavailable"),
                  "error": result.get("error")}
    return {**result, "thread_id": thread_id, "client_id": client_id, "turn_id": turn_id}
