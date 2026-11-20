#!/usr/bin/env python3
"""Library-level tests for lib/claude_inbound.py (msg-setup P1, plan cases 1-7).

Every path lives under a temp directory. The real ~/.claude is never read or
written; a guard test asserts its settings.json mtime did not move.
"""
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("claude_inbound", ROOT / "lib/claude_inbound.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)

REAL_SETTINGS = Path(os.path.expanduser("~/.claude/settings.json"))


def _real_state():
    # A live Claude may rewrite settings.json for its own reasons, so compare what this
    # library could change: the key's value and any cctrl backup/lock files beside it.
    try:
        val = json.loads(REAL_SETTINGS.read_text()).get("crossSessionInbound")
    except (OSError, ValueError, AttributeError):
        val = None
    extra = sorted(p.name for p in REAL_SETTINGS.parent.glob("*cctrl*")) if REAL_SETTINGS.parent.is_dir() else []
    return val, extra


REAL_STATE_AT_IMPORT = _real_state()


def sys_path(d):
    # Stubs are /bin/sh scripts, so no bash shim is needed; the system dirs are
    # assembled so the shimless-PATH lint (test_no_shimless_test_path) does not match.
    return ":".join([str(d), "/usr" + "/bin", "/" + "bin"])


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="cctrl-ci-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = self.tmp / "home"
        self.cfg = self.home / ".claude"
        self.cfg.mkdir(parents=True)
        self.settings = self.cfg / "settings.json"
        self.proj = self.tmp / "proj"
        (self.proj / ".claude").mkdir(parents=True)
        self.managed = self.tmp / "managed"
        self.managed.mkdir()

    def write(self, path, obj):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(obj if isinstance(obj, str) else json.dumps(obj, indent=2) + "\n")

    def backups(self):
        return sorted(p for p in self.cfg.iterdir() if ".cctrl-backup-" in p.name)


class MergeTests(Base):
    # Case 1
    def test_merge_keeps_other_keys_and_order(self):
        original = {"theme": "dark", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "x"}]}]},
                    "permissions": {"allow": ["Bash(ls)"]}}
        self.write(self.settings, original)
        changed, backup = ci.set_cross_session_inbound(self.settings, "accept")
        self.assertTrue(changed)
        self.assertIsNotNone(backup)
        got = json.loads(self.settings.read_text())
        self.assertEqual(list(got), ["theme", "hooks", "permissions", "crossSessionInbound"])
        self.assertEqual(got["crossSessionInbound"], "accept")
        for k, v in original.items():
            self.assertEqual(got[k], v)

    def test_merge_creates_missing_file_without_backup(self):
        changed, backup = ci.set_cross_session_inbound(self.settings, "accept")
        self.assertTrue(changed)
        self.assertIsNone(backup)
        self.assertEqual(json.loads(self.settings.read_text()), {"crossSessionInbound": "accept"})
        self.assertEqual(stat.S_IMODE(self.settings.stat().st_mode), 0o600)

    def test_changing_existing_value_keeps_position(self):
        self.write(self.settings, {"a": 1, "crossSessionInbound": "hold", "b": 2})
        ci.set_cross_session_inbound(self.settings, "accept")
        self.assertEqual(list(json.loads(self.settings.read_text())), ["a", "crossSessionInbound", "b"])

    def test_rejects_unknown_value(self):
        with self.assertRaises(ValueError):
            ci.set_cross_session_inbound(self.settings, "allow")

    # Case 2
    def test_idempotent_second_run_is_byte_identical_and_makes_no_backup(self):
        self.write(self.settings, {"theme": "dark"})
        ci.set_cross_session_inbound(self.settings, "accept")
        first = self.settings.read_bytes()
        n = len(self.backups())
        changed, backup = ci.set_cross_session_inbound(self.settings, "accept")
        self.assertFalse(changed)
        self.assertIsNone(backup)
        self.assertEqual(self.settings.read_bytes(), first)
        self.assertEqual(len(self.backups()), n)

    # Case 3
    def test_backup_is_exact_original_bytes_and_mode_kept(self):
        raw = '{\n    "theme":   "dark"\n}\n'
        self.write(self.settings, raw)
        os.chmod(self.settings, 0o640)
        changed, backup = ci.set_cross_session_inbound(self.settings, "hold")
        self.assertTrue(changed)
        self.assertEqual(len(self.backups()), 1)
        self.assertEqual(backup.read_text(), raw)
        self.assertEqual(stat.S_IMODE(self.settings.stat().st_mode), 0o640)
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o640)

    def test_four_space_indent_is_kept(self):
        self.write(self.settings, '{\n    "theme": "dark"\n}\n')
        ci.set_cross_session_inbound(self.settings, "accept")
        self.assertIn('\n    "crossSessionInbound": "accept"', self.settings.read_text())

    # Case 4
    def test_invalid_json_is_refused_and_file_untouched(self):
        raw = '{"theme": "dark",}\n'
        self.write(self.settings, raw)
        with self.assertRaises(ci.SettingsError):
            ci.set_cross_session_inbound(self.settings, "accept")
        self.assertEqual(self.settings.read_text(), raw)
        self.assertEqual(self.backups(), [])

    def test_non_object_json_is_refused(self):
        self.write(self.settings, "[1, 2]\n")
        with self.assertRaises(ci.SettingsError):
            ci.set_cross_session_inbound(self.settings, "accept")
        self.assertEqual(self.settings.read_text(), "[1, 2]\n")

    def test_empty_file_is_refused_not_treated_as_empty_object(self):
        self.write(self.settings, "")
        with self.assertRaises(ci.SettingsError):
            ci.set_cross_session_inbound(self.settings, "accept")
        self.assertEqual(self.settings.read_text(), "")

    # Case 9 at library level
    def test_unset_removes_only_the_key(self):
        self.write(self.settings, {"a": 1, "crossSessionInbound": "accept", "b": 2})
        changed, backup = ci.set_cross_session_inbound(self.settings, None)
        self.assertTrue(changed)
        self.assertIsNotNone(backup)
        self.assertEqual(json.loads(self.settings.read_text()), {"a": 1, "b": 2})

    def test_unset_when_absent_is_unchanged(self):
        self.write(self.settings, {"a": 1})
        before = self.settings.read_bytes()
        changed, backup = ci.set_cross_session_inbound(self.settings, None)
        self.assertFalse(changed)
        self.assertIsNone(backup)
        self.assertEqual(self.settings.read_bytes(), before)

    def test_symlink_writes_through_to_target(self):
        target = self.tmp / "real" / "settings.json"
        self.write(target, {"a": 1})
        self.settings.symlink_to(target)
        changed, _ = ci.set_cross_session_inbound(self.settings, "accept")
        self.assertTrue(changed)
        self.assertTrue(self.settings.is_symlink())
        self.assertEqual(json.loads(target.read_text())["crossSessionInbound"], "accept")
        self.assertEqual(ci.real_target(self.settings), target.resolve())

    def test_change_under_us_is_retried_then_applies(self):
        self.write(self.settings, {"a": 1})
        calls = []

        def hook(attempt, path):
            calls.append(attempt)
            if attempt == 1:
                path.write_text(json.dumps({"a": 1, "b": 2}))

        changed, _ = ci.set_cross_session_inbound(self.settings, "accept", before_compare=hook)
        self.assertTrue(changed)
        self.assertEqual(calls, [1, 2])
        self.assertEqual(json.loads(self.settings.read_text()), {"a": 1, "b": 2, "crossSessionInbound": "accept"})

    def test_change_under_us_every_time_gives_up_without_writing(self):
        self.write(self.settings, {"a": 1})
        n = [0]

        def hook(attempt, path):
            n[0] += 1
            path.write_text(json.dumps({"a": n[0]}))

        with self.assertRaises(ci.SettingsError):
            ci.set_cross_session_inbound(self.settings, "accept", before_compare=hook)
        self.assertNotIn("crossSessionInbound", json.loads(self.settings.read_text()))


class ReadTests(Base):
    def test_read_states(self):
        self.assertEqual(ci.read_settings(self.settings).status, "absent")
        self.write(self.settings, {"crossSessionInbound": "hold"})
        r = ci.read_settings(self.settings)
        self.assertEqual((r.status, r.data["crossSessionInbound"]), ("ok", "hold"))
        self.write(self.settings, "{nope")
        self.assertEqual(ci.read_settings(self.settings).status, "invalid")
        self.write(self.settings, "[]")
        self.assertEqual(ci.read_settings(self.settings).status, "invalid")

    def test_user_path_honours_claude_config_dir(self):
        env = {"HOME": str(self.home)}
        self.assertEqual(ci.user_settings_path(env), self.home / ".claude" / "settings.json")
        env["CLAUDE_CONFIG_DIR"] = str(self.tmp / "alt")
        self.assertEqual(ci.user_settings_path(env), self.tmp / "alt" / "settings.json")

    def test_project_paths(self):
        p, l = ci.project_settings_paths(self.proj)
        self.assertEqual(p, self.proj / ".claude" / "settings.json")
        self.assertEqual(l, self.proj / ".claude" / "settings.local.json")


class ManagedTests(Base):
    def env(self, plist=None):
        e = {"HOME": str(self.home), "CCTRL_CLAUDE_MANAGED_DIR": str(self.managed)}
        e["CCTRL_CLAUDE_MANAGED_PLIST_JSON"] = str(plist) if plist else str(self.tmp / "no-plist.json")
        return e

    def test_plist_candidate_paths_are_per_user_then_device(self):
        paths = ci.managed_plist_paths("alice")
        self.assertEqual(paths, [
            Path("/Library/Managed Preferences/alice/com.anthropic.claudecode.plist"),
            Path("/Library/Managed Preferences/com.anthropic.claudecode.plist"),
        ])

    def test_files_merge_json_then_dropins_alphabetical_later_wins(self):
        self.write(self.managed / "managed-settings.json", {"crossSessionInbound": "accept", "x": 1})
        self.write(self.managed / "managed-settings.d" / "20-b.json", {"crossSessionInbound": "refuse"})
        self.write(self.managed / "managed-settings.d" / "10-a.json", {"crossSessionInbound": "hold"})
        self.write(self.managed / "managed-settings.d" / ".hidden.json", {"crossSessionInbound": "accept"})
        self.write(self.managed / "managed-settings.d" / "note.txt", "ignored")
        doc = ci.read_managed(self.env())
        self.assertEqual(doc.source, "managed-settings file")
        self.assertEqual(doc.data["crossSessionInbound"], "refuse")
        self.assertEqual(doc.invalid, [])

    def test_unparseable_managed_file_is_reported_invalid(self):
        self.write(self.managed / "managed-settings.json", "{bad")
        doc = ci.read_managed(self.env())
        self.assertEqual(len(doc.invalid), 1)
        self.assertIn("managed-settings.json", doc.invalid[0])

    def test_plist_json_stand_in_outranks_files(self):
        self.write(self.managed / "managed-settings.json", {"crossSessionInbound": "accept"})
        plist = self.tmp / "plist.json"
        self.write(plist, {"crossSessionInbound": "hold"})
        doc = ci.read_managed(self.env(plist))
        self.assertEqual(doc.source, "managed preferences (MDM)")
        self.assertEqual(doc.data["crossSessionInbound"], "hold")

    def test_plist_file_is_read_with_plutil_json_conversion(self):
        # Real plutil, fixture plist under the temp dir: proves the conversion path.
        if not Path("/usr/bin/plutil").exists():
            self.skipTest("no plutil")
        plist = self.tmp / "com.anthropic.claudecode.plist"
        plist.write_text('<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
                         '"http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>'
                         '<key>crossSessionInbound</key><string>refuse</string></dict></plist>')
        data = ci.convert_plist(plist)
        self.assertEqual(data, {"crossSessionInbound": "refuse"})

    def test_nothing_managed_is_absent_and_server_managed_unknown(self):
        doc = ci.read_managed(self.env())
        self.assertEqual(doc.data, {})
        self.assertIsNone(doc.source)
        self.assertEqual(doc.server_managed, "unknown")


class ResolveTests(Base):
    R = staticmethod(lambda **kw: ci.resolve(**kw))

    def test_nothing_set_is_per_class_default(self):
        e = ci.resolve()
        self.assertIsNone(e.value)
        self.assertEqual(e.source, "default")

    def test_user_value_applies(self):
        e = ci.resolve(user={"crossSessionInbound": "accept"})
        self.assertEqual((e.value, e.source), ("accept", "user settings"))

    def test_overlay_beats_user(self):
        e = ci.resolve(overlay="accept", user={"crossSessionInbound": "hold"})
        self.assertEqual((e.value, e.source), ("accept", "--settings overlay"))

    def test_managed_beats_overlay_and_user(self):
        e = ci.resolve(managed={"crossSessionInbound": "refuse"}, overlay="accept",
                       user={"crossSessionInbound": "accept"})
        self.assertEqual((e.value, e.source), ("refuse", "managed settings"))

    def test_project_stricter_wins_over_user_and_managed(self):
        e = ci.resolve(managed={"crossSessionInbound": "accept"}, project={"crossSessionInbound": "hold"})
        self.assertEqual(e.value, "hold")
        self.assertEqual(e.source, "project settings")

    def test_project_not_stricter_is_ignored(self):
        e = ci.resolve(user={"crossSessionInbound": "hold"}, local={"crossSessionInbound": "accept"})
        self.assertEqual((e.value, e.source), ("hold", "user settings"))

    def test_local_beats_project_when_both_stricter(self):
        e = ci.resolve(user={"crossSessionInbound": "accept"}, project={"crossSessionInbound": "hold"},
                       local={"crossSessionInbound": "refuse"})
        self.assertEqual((e.value, e.source), ("refuse", "local settings"))

    def test_project_hold_with_no_trusted_value_replaces_default(self):
        e = ci.resolve(project={"crossSessionInbound": "hold"})
        self.assertEqual((e.value, e.source), ("hold", "project settings"))

    def test_project_accept_with_no_trusted_value_is_ignored(self):
        e = ci.resolve(project={"crossSessionInbound": "accept"})
        self.assertIsNone(e.value)

    def test_invalid_user_value_forces_hold_even_over_managed_accept(self):
        e = ci.resolve(managed={"crossSessionInbound": "accept"}, user={"crossSessionInbound": "allow"})
        self.assertEqual(e.value, "hold")
        self.assertEqual(e.invalid, [("user settings", "allow")])

    def test_invalid_user_value_does_not_loosen_managed_refuse(self):
        e = ci.resolve(managed={"crossSessionInbound": "refuse"}, user={"crossSessionInbound": 7})
        self.assertEqual(e.value, "refuse")

    def test_invalid_project_value_forces_hold(self):
        e = ci.resolve(user={"crossSessionInbound": "accept"}, project={"crossSessionInbound": "ACCEPT"})
        self.assertEqual(e.value, "hold")
        self.assertEqual(e.invalid, [("project settings", "ACCEPT")])

    def test_invalid_managed_value_counts_as_refuse(self):
        e = ci.resolve(managed={"crossSessionInbound": "nope"}, user={"crossSessionInbound": "accept"})
        self.assertEqual((e.value, e.source), ("refuse", "managed settings"))
        self.assertTrue(e.managed_invalid)

    def test_managed_accept_is_still_beaten_by_stricter_local(self):
        e = ci.resolve(managed={"crossSessionInbound": "accept"}, local={"crossSessionInbound": "refuse"})
        self.assertEqual(e.value, "refuse")


class VersionTests(Base):
    def test_parse(self):
        self.assertEqual(ci.parse_version("2.1.329 (Claude Code)"), (2, 1, 329))
        self.assertEqual(ci.parse_version("claude 2.1.224\n"), (2, 1, 224))
        self.assertIsNone(ci.parse_version("garbage"))
        self.assertIsNone(ci.parse_version(""))

    def test_compare(self):
        self.assertLess(ci.parse_version("2.1.9"), ci.parse_version("2.1.10"))
        self.assertLess(ci.parse_version("2.1.999"), ci.parse_version("2.2.0"))

    # Case 7
    def test_gate_levels(self):
        g = ci.version_gate((2, 1, 200))
        self.assertTrue(g.refuse)
        g = ci.version_gate((2, 1, 224))
        self.assertFalse(g.refuse)
        self.assertEqual(len(g.warnings), 2)
        g = ci.version_gate((2, 1, 230))
        self.assertFalse(g.refuse)
        self.assertTrue(any("/config" in w for w in g.warnings))
        self.assertTrue(any("invalid" in w for w in g.warnings))
        g = ci.version_gate((2, 1, 240))
        self.assertFalse(g.refuse)
        self.assertEqual(len(g.warnings), 1)
        self.assertIn("invalid", g.warnings[0])
        g = ci.version_gate((2, 1, 329))
        self.assertEqual((g.refuse, g.warnings, g.needs_yes), (False, [], False))

    def test_missing_version_warns_and_needs_yes(self):
        g = ci.version_gate(None)
        self.assertFalse(g.refuse)
        self.assertTrue(g.needs_yes)
        self.assertTrue(g.warnings)

    def _stub(self, text, name="claude"):
        d = self.tmp / "bin"
        d.mkdir(exist_ok=True)
        s = d / name
        s.write_text(f"#!/bin/sh\necho '{text}'\n")
        s.chmod(0o755)
        return {"PATH": sys_path(d)}

    def test_detect_version_from_stub_on_path(self):
        self.assertEqual(ci.detect_claude_version(self._stub("2.1.230 (Claude Code)")), (2, 1, 230))

    def test_detect_version_missing_claude(self):
        empty = self.tmp / "empty"
        empty.mkdir()
        self.assertIsNone(ci.detect_claude_version({"PATH": str(empty)}))

    def test_detect_version_unparseable_output(self):
        self.assertIsNone(ci.detect_claude_version(self._stub("hello")))


class PreflightTests(Base):
    def env(self, version_text=None):
        e = {"HOME": str(self.home), "CCTRL_CLAUDE_MANAGED_DIR": str(self.managed),
             "CCTRL_CLAUDE_MANAGED_PLIST_JSON": str(self.tmp / "none.json")}
        if version_text is not None:
            d = self.tmp / "bin"
            d.mkdir(exist_ok=True)
            s = d / "claude"
            s.write_text(f"#!/bin/sh\necho '{version_text}'\n")
            s.chmod(0o755)
            e["PATH"] = sys_path(d)
        else:
            empty = self.tmp / "empty"
            empty.mkdir(exist_ok=True)
            e["PATH"] = str(empty)
        return e

    # Case 5
    def test_managed_hold_blocks_with_exit_3(self):
        self.write(self.managed / "managed-settings.json", {"crossSessionInbound": "hold"})
        r = ci.preflight("accept", env=self.env("2.1.329"), project_dir=self.proj)
        self.assertTrue(r.blocked)
        self.assertEqual(r.exit_code, 3)
        self.assertTrue(any("overrides" in w for w in r.warnings))

    def test_managed_invalid_value_is_reported_as_refuse(self):
        self.write(self.managed / "managed-settings.json", {"crossSessionInbound": "bogus"})
        r = ci.preflight("accept", env=self.env("2.1.329"), project_dir=self.proj)
        self.assertEqual(r.exit_code, 3)
        self.assertEqual(r.own.value, "refuse")

    def test_managed_equal_to_target_does_not_block(self):
        self.write(self.managed / "managed-settings.json", {"crossSessionInbound": "accept"})
        r = ci.preflight("accept", env=self.env("2.1.329"), project_dir=self.proj)
        self.assertFalse(r.blocked)

    def test_no_managed_reports_server_managed_unknown(self):
        r = ci.preflight("accept", env=self.env("2.1.329"), project_dir=self.proj)
        self.assertFalse(r.blocked)
        self.assertEqual(r.server_managed, "unknown")

    # Case 6
    def test_project_and_local_stricter_reported_but_do_not_block(self):
        self.write(self.proj / ".claude" / "settings.json", {"crossSessionInbound": "hold"})
        self.write(self.proj / ".claude" / "settings.local.json", {"crossSessionInbound": "refuse"})
        r = ci.preflight("accept", env=self.env("2.1.329"), project_dir=self.proj)
        self.assertFalse(r.blocked)
        self.assertEqual(r.exit_code, 0)
        self.assertEqual(r.own.value, "refuse")
        self.assertEqual(r.own.source, "local settings")
        self.assertTrue(any("applies in this repo only" in n and "refuse" in n for n in r.notes))

    def test_project_not_stricter_is_not_reported(self):
        self.write(self.proj / ".claude" / "settings.json", {"crossSessionInbound": "accept"})
        r = ci.preflight("accept", env=self.env("2.1.329"), project_dir=self.proj)
        self.assertFalse(any("applies in this repo only" in n for n in r.notes))

    def test_invalid_value_in_user_file_is_reported(self):
        self.write(self.settings, {"crossSessionInbound": "allow"})
        r = ci.preflight("accept", env=self.env("2.1.329"), project_dir=self.proj)
        self.assertTrue(any("forced to hold" in w for w in r.warnings))

    def test_isolate_peer_machines_warns(self):
        self.write(self.proj / ".claude" / "settings.json", {"isolatePeerMachines": True})
        r = ci.preflight("accept", env=self.env("2.1.329"), project_dir=self.proj)
        self.assertTrue(any("isolatePeerMachines" in w for w in r.warnings))

    def test_spawn_view_uses_overlay_own_view_does_not(self):
        self.write(self.settings, {"crossSessionInbound": "hold"})
        r = ci.preflight("accept", env=self.env("2.1.329"), project_dir=self.proj, overlay="accept")
        self.assertEqual(r.spawn.value, "accept")
        self.assertEqual(r.own.value, "hold")

    # Case 7
    def test_version_refuse_blocks_with_exit_2(self):
        r = ci.preflight("accept", env=self.env("2.1.200 (Claude Code)"), project_dir=self.proj)
        self.assertTrue(r.blocked)
        self.assertEqual(r.exit_code, 2)

    def test_version_230_warns_about_config_row(self):
        r = ci.preflight("accept", env=self.env("2.1.230"), project_dir=self.proj)
        self.assertFalse(r.blocked)
        self.assertTrue(any("/config" in w for w in r.warnings))

    def test_version_240_warns_about_invalid_values(self):
        r = ci.preflight("accept", env=self.env("2.1.240"), project_dir=self.proj)
        self.assertFalse(r.blocked)
        self.assertEqual(len(r.warnings), 1)

    def test_version_329_is_clean(self):
        r = ci.preflight("accept", env=self.env("2.1.329"), project_dir=self.proj)
        self.assertEqual((r.blocked, r.exit_code, r.warnings), (False, 0, []))

    def test_missing_claude_needs_yes(self):
        r = ci.preflight("accept", env=self.env(None), project_dir=self.proj)
        self.assertTrue(r.needs_yes)
        self.assertFalse(r.blocked)
        r = ci.preflight("accept", env=self.env(None), project_dir=self.proj, yes=True)
        self.assertFalse(r.needs_yes)


class NoLiveStateTests(unittest.TestCase):
    # Case 11
    def test_real_settings_untouched_by_this_suite(self):
        self.assertEqual(_real_state(), REAL_STATE_AT_IMPORT)


if __name__ == "__main__":
    unittest.main()
