#!/usr/bin/env python3
"""Validate lifecycle fixture completeness, provenance, lineage, and privacy."""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parent
MANIFEST = ROOT / "manifest.json"
IGNORED = {
    "manifest.json",
    "fixture-manifest.schema.json",
    "lifecycle-matrix.schema.json",
}
STATUSES = {"observed", "derived", "unsupported"}
CLASSES = {"authoritative", "corroborating", "diagnostic-only"}
REQUIRED_SCENARIOS = {
    "native-app-empty-plus",
    "native-app-first-prompt",
    "cctrl-tmux-launch",
    "remote-unix",
    "direct-cli-resume",
    "cctrl-app-owned-launch",
    "app-restart",
    "host-reboot",
    "clear",
    "compact",
    "fork",
    "fork-of-fork",
    "subagent-thread",
    "release-to-app",
}
REQUIRED_HOOK_SOURCES = {"startup", "resume", "clear", "compact", "fork", "app-server", "cli"}
SECRET_PATTERNS = {
    "OpenAI-style token": re.compile(r"\bsk-[A-Za-z0-9_-]{12,}"),
    "GitHub-style token": re.compile(r"\b(?:ghp|github_pat)_[A-Za-z0-9_]{12,}"),
    "bearer token": re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._-]{12,}"),
    "email/account identifier": re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.I),
    "UUID/account-like id": re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b", re.I),
    "home-directory path": re.compile(r"(?:/Users/|/home/|~/(?:\.|[A-Za-z]))"),
}
ABSOLUTE_PATH = re.compile(
    r"(?<![:/A-Za-z0-9._-])/(?!/)[A-Za-z0-9._~+-]+(?:/[A-Za-z0-9._~+-]+)+"
)
ALLOWED_ABSOLUTE_PATHS = frozenset()


def fail(message: str) -> None:
    raise ValueError(message)


def load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"{path.name}: invalid JSON: {exc}")


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def schema_type_matches(value, expected: str) -> bool:
    """Return whether a JSON value has the requested JSON Schema type."""
    return {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
        "boolean": isinstance(value, bool),
        "null": value is None,
    }.get(expected, False)


def validate_against_schema(value, schema, root_schema, location="$"):
    """Apply the JSON Schema subset used by the two checked-in contracts."""
    if "$ref" in schema:
        reference = schema["$ref"]
        if not reference.startswith("#/"):
            fail(f"{location}: unsupported schema reference {reference!r}")
        target = root_schema
        for component in reference[2:].split("/"):
            target = target[component.replace("~1", "/").replace("~0", "~")]
        validate_against_schema(value, target, root_schema, location)
        return

    expected_types = schema.get("type")
    if expected_types is not None:
        if isinstance(expected_types, str):
            expected_types = [expected_types]
        if not any(schema_type_matches(value, expected) for expected in expected_types):
            fail(f"{location}: expected schema type {expected_types}, got {type(value).__name__}")

    if "const" in schema and value != schema["const"]:
        fail(f"{location}: expected constant {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        fail(f"{location}: value {value!r} is outside enum {schema['enum']!r}")

    if isinstance(value, dict):
        required = set(schema.get("required", []))
        missing = required - set(value)
        if missing:
            fail(f"{location}: missing required properties {sorted(missing)}")
        if len(value) < schema.get("minProperties", 0):
            fail(f"{location}: expected at least {schema['minProperties']} properties")
        properties = schema.get("properties", {})
        extras = set(value) - set(properties)
        additional = schema.get("additionalProperties", True)
        if extras and additional is False:
            fail(f"{location}: unexpected properties {sorted(extras)}")
        for key, item in value.items():
            child_schema = properties.get(key)
            if child_schema is None and isinstance(additional, dict):
                child_schema = additional
            if child_schema is not None:
                validate_against_schema(item, child_schema, root_schema, f"{location}.{key}")

    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            fail(f"{location}: expected at least {schema['minItems']} items")
        if "items" in schema:
            for index, item in enumerate(value):
                validate_against_schema(item, schema["items"], root_schema, f"{location}[{index}]")

    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            fail(f"{location}: string is shorter than {schema['minLength']}")
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            fail(f"{location}: string does not match {schema['pattern']!r}")
        if schema.get("format") == "date-time":
            try:
                datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError:
                fail(f"{location}: value is not an ISO-8601 date-time")


def apply_schema(data, schema_path: Path, label: str) -> None:
    schema = load_json(schema_path)
    try:
        validate_against_schema(data, schema, schema)
    except (KeyError, TypeError) as exc:
        fail(f"{label}: malformed schema: {exc}")


def validate_manifest(manifest):
    if manifest.get("schema_version") != 1 or not isinstance(manifest.get("fixtures"), list):
        fail("manifest: expected schema_version 1 and a fixtures array")
    required = {
        "path", "cli_version", "app_version", "source", "capture_method",
        "observed_at", "scenario", "field_status", "sanitization", "refresh_rule",
    }
    seen = set()
    for entry in manifest["fixtures"]:
        missing = required - set(entry)
        if missing:
            fail(f"manifest {entry.get('path', '<unknown>')}: missing {sorted(missing)}")
        path = entry["path"]
        if path in seen:
            fail(f"manifest: duplicate fixture entry {path}")
        seen.add(path)
        if Path(path).name != path or not (ROOT / path).is_file():
            fail(f"manifest: fixture path must name an existing file: {path}")
        if not entry["cli_version"] or not entry["app_version"] or not entry["capture_method"]:
            fail(f"manifest {path}: version and capture provenance must be non-empty")
        try:
            datetime.fromisoformat(entry["observed_at"].replace("Z", "+00:00"))
        except (TypeError, ValueError):
            fail(f"manifest {path}: observed_at is not ISO-8601")
        if not entry["field_status"] or set(entry["field_status"].values()) - STATUSES:
            fail(f"manifest {path}: field_status values must use {sorted(STATUSES)}")
        if not entry["sanitization"]:
            fail(f"manifest {path}: sanitization placeholders are required")
        for placeholder in entry["sanitization"].values():
            if not re.fullmatch(r"<[A-Z0-9_]+>", placeholder):
                fail(f"manifest {path}: invalid sanitization placeholder {placeholder!r}")
        if not entry["refresh_rule"]:
            fail(f"manifest {path}: refresh_rule is empty")

    actual = {path.name for path in ROOT.glob("*.json") if path.name not in IGNORED}
    if seen != actual:
        fail(f"manifest coverage differs: missing={sorted(actual-seen)}, stale={sorted(seen-actual)}")
    return seen


def validate_matrix(matrix):
    if matrix.get("schema_version") != 1 or not isinstance(matrix.get("entries"), list):
        fail("matrix: expected schema_version 1 and entries array")
    by_scenario = {entry.get("scenario"): entry for entry in matrix["entries"]}
    if len(by_scenario) != len(matrix["entries"]):
        fail("matrix: scenario names must be unique")
    if set(by_scenario) != REQUIRED_SCENARIOS:
        fail(f"matrix scenarios differ: missing={sorted(REQUIRED_SCENARIOS-set(by_scenario))}")
    for scenario, entry in by_scenario.items():
        for field in ("provider_task_id", "forkedFromId", "parentThreadId", "derivedRootId"):
            if entry.get(field, {}).get("status") not in STATUSES:
                fail(f"matrix {scenario}: invalid {field} status")
        if entry["derivedRootId"]["status"] == "observed":
            fail(f"matrix {scenario}: root lineage must never be provider-observed")
        classes = {item.get("classification") for item in entry.get("evidence", [])}
        if not classes or classes - CLASSES:
            fail(f"matrix {scenario}: invalid evidence classification")
        if entry.get("ownership_outcome") not in {"app", "terminal", "unchanged", "unknown", "conflict"}:
            fail(f"matrix {scenario}: invalid ownership outcome")
    if by_scenario["native-app-empty-plus"]["provider_task_id"] != {"status": "unsupported", "value": None}:
        fail("matrix: empty native app + must not have a provider task id")
    fork = by_scenario["fork"]
    fork_of_fork = by_scenario["fork-of-fork"]
    subagent = by_scenario["subagent-thread"]
    if fork["forkedFromId"] != {"status": "observed", "value": "<THREAD_ID>"}:
        fail("matrix: fork must name its immediate source in forkedFromId")
    if fork["parentThreadId"] != {"status": "observed", "value": None}:
        fail("matrix: fork must not reuse parentThreadId")
    if fork["derivedRootId"] != {"status": "derived", "value": "<THREAD_ID>"}:
        fail("matrix: fork root must be derived from the immediate source")
    if fork_of_fork["forkedFromId"] != {
        "status": "observed", "value": fork["provider_task_id"]["value"]
    }:
        fail("matrix: fork-of-fork must name the fork as its immediate source")
    if fork_of_fork["parentThreadId"] != {"status": "observed", "value": None}:
        fail("matrix: fork-of-fork must not reuse parentThreadId")
    if fork_of_fork["derivedRootId"] != fork["derivedRootId"]:
        fail("matrix: fork-of-fork root must be derived by traversing forkedFromId")
    if subagent["forkedFromId"] != {"status": "observed", "value": None}:
        fail("matrix: subagent must not reuse forkedFromId")
    if subagent["parentThreadId"] != {"status": "observed", "value": "<THREAD_ID>"}:
        fail("matrix: subagent ancestry must come from parentThreadId")
    if subagent["derivedRootId"] != {"status": "derived", "value": "<THREAD_ID>"}:
        fail("matrix: subagent root must be derived through parentThreadId")


def validate_hooks(hooks):
    sources = {event.get("source") for event in hooks.get("events", [])}
    if sources != REQUIRED_HOOK_SOURCES:
        fail(f"hook source coverage differs: missing={sorted(REQUIRED_HOOK_SOURCES-sources)}")


def validate_probe(probe):
    env = probe.get("environment", {})
    if set(env) != {"CCTRL_DATA_DIR", "CCTRL_SESSION_METADATA_DIR"}:
        fail("probe: temporary CCTRL_DATA_DIR and CCTRL_SESSION_METADATA_DIR are required")
    live_store = probe.get("live_store", {})
    for key in ("before_digest", "after_digest"):
        if not re.fullmatch(r"sha256:<[A-Z_]+>", live_store.get(key, "")):
            fail(f"probe: {key} must be a sanitized sha256 digest")
    if not live_store.get("expected_codex_delta") or not probe.get("cleanup"):
        fail("probe: expected Codex delta and cleanup instructions are required")


def privacy_scan(manifest):
    allowed = {
        placeholder
        for entry in manifest["fixtures"]
        for placeholder in entry["sanitization"].values()
    }
    for path in sorted(ROOT.glob("*.json")):
        data = load_json(path)
        for value in strings(data):
            for label, pattern in SECRET_PATTERNS.items():
                if pattern.search(value):
                    fail(f"privacy scan {path.name}: rejected {label}")
            for absolute_path in ABSOLUTE_PATH.findall(value):
                if absolute_path not in ALLOWED_ABSOLUTE_PATHS:
                    fail(f"privacy scan {path.name}: unapproved absolute path {absolute_path!r}")
            for placeholder in re.findall(r"<[A-Z0-9_]+>", value):
                if placeholder not in allowed:
                    fail(f"privacy scan {path.name}: placeholder not allowlisted: {placeholder}")


def main() -> int:
    manifest = load_json(MANIFEST)
    matrix = load_json(ROOT / "matrix.json")
    apply_schema(manifest, ROOT / "fixture-manifest.schema.json", "manifest schema")
    apply_schema(matrix, ROOT / "lifecycle-matrix.schema.json", "matrix schema")
    paths = validate_manifest(manifest)
    validate_matrix(matrix)
    validate_hooks(load_json(ROOT / "hook-events.json"))
    validate_probe(load_json(ROOT / "probe-protocol.json"))
    privacy_scan(manifest)
    print(f"ok: Codex lifecycle fixtures ({len(paths)} fixtures)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ValueError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
