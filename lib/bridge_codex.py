"""Single-attempt native Codex user-queue delivery through an existing server.

Queue acceptance is not execution, handling, or a reply. This adapter never
resumes a thread, acquires its history writer, or retries a mutation.
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
              *, client: Any = None) -> dict[str, Any]:
    """Find an attempt in native queue pages without submitting anything.

    not_found does not mean unsent: the owner may already have consumed it.
    History reconciliation and the persisted attempt still belong to the caller.
    """
    try:
        identity = _identity(thread_id, text, client_id)
    except Exception as exc:
        return _failed(exc)

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
