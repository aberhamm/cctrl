import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))
import refresh_prices as rp  # noqa: E402
import usage_costs as u  # noqa: E402


def lite_doc(models):
    return {"_meta": {"fetched": "2026-11-16"}, "models": models}


class PriceTables(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.pf = Path(self.tmp.name) / "prices.json"
        self._old = os.environ.get("CCTRL_PRICE_FILE")
        os.environ["CCTRL_PRICE_FILE"] = str(self.pf)
        u._LITELLM_CACHE.clear()
        self.addCleanup(self._restore)

    def _restore(self):
        if self._old is None:
            os.environ.pop("CCTRL_PRICE_FILE", None)
        else:
            os.environ["CCTRL_PRICE_FILE"] = self._old
        u._LITELLM_CACHE.clear()

    def test_official_current_models(self):
        for model, inp, cached, out in [
            ("gpt-6.1-sol", 2.0, 0.10, 10.0),
            ("gpt-6.1-terra", 1.0, 0.05, 5.0),
            ("gpt-6-astra", 10.0, 1.0, 50.0),
        ]:
            rates, src = u.openai_rates_and_source(model, 1000)
            self.assertEqual(src, "official", model)
            self.assertEqual((rates["input"], rates["cached"], rates["output"]), (inp, cached, out))
        rates, _ = u.openai_rates_and_source("gpt-6.1-sol", 300_000)
        self.assertEqual((rates["input"], rates["cached"], rates["output"]), (4.0, 0.20, 15.0))

    def test_not_on_official_page_is_unpriced_then_fallback(self):
        for model in ("codex-auto-review", "gpt-daybreak-blue-latest"):
            rates, src = u.openai_rates_and_source(model, 10)
            self.assertEqual(src, "fallback", model)
            self.assertEqual(rates["input"], 1.25)

    def test_litellm_file_used_when_not_official(self):
        self.pf.write_text(json.dumps(lite_doc({
            "codex-auto-review": {"input_cost_per_token": 3e-06, "output_cost_per_token": 1.2e-05,
                                  "cache_read_input_token_cost": 3e-07},
        })))
        rates, src = u.openai_rates_and_source("codex-auto-review", 10)
        self.assertEqual(src, "litellm")
        self.assertAlmostEqual(rates["input"], 3.0)
        self.assertAlmostEqual(rates["cached"], 0.3)
        self.assertAlmostEqual(rates["output"], 12.0)

    def test_official_beats_litellm(self):
        self.pf.write_text(json.dumps(lite_doc({
            "gpt-6.1-sol": {"input_cost_per_token": 9e-06, "output_cost_per_token": 9e-06},
        })))
        rates, src = u.openai_rates_and_source("gpt-6.1-sol", 10)
        self.assertEqual((src, rates["input"]), ("official", 2.0))

    def test_missing_or_corrupt_file_falls_back(self):
        self.assertEqual(u.load_litellm_prices(), {})
        self.assertEqual(u.openai_rates_and_source("codex-auto-review", 1)[1], "fallback")
        self.pf.write_text("{not json")
        u._LITELLM_CACHE.clear()
        self.assertEqual(u.load_litellm_prices(), {})
        self.assertEqual(u.openai_rates_and_source("gpt-5.4", 1)[1], "official")
        self.pf.write_text(json.dumps({"models": []}))
        u._LITELLM_CACHE.clear()
        self.assertEqual(u.load_litellm_prices(), {})

    def test_checked_in_file_loads(self):
        del os.environ["CCTRL_PRICE_FILE"]
        u._LITELLM_CACHE.clear()
        lite = u.load_litellm_prices()
        self.assertIn("gpt-daybreak-blue-latest", lite)
        doc = json.loads((ROOT / "share" / "litellm-openai-prices.json").read_text())
        self.assertIn("MIT", doc["_meta"]["licence"])
        self.assertTrue(doc["_meta"]["source"].startswith("https://raw.githubusercontent.com/BerriAI/litellm/"))

    def test_fallback_counted_in_aggregates(self):
        agg = u.Aggregates("")
        from datetime import datetime, timezone
        ts = datetime.now(timezone.utc)
        usage = {"input": 1000, "output": 100, "cache_write": 0, "cache_read": 0, "reasoning": 0}
        agg.record({"agent": "codex", "ts": ts, "model": "mystery-model", "usage": usage, "project": "p", "session_id": "s"})
        agg.record({"agent": "codex", "ts": ts, "model": "gpt-6.1-sol", "usage": usage, "project": "p", "session_id": "s"})
        fb = agg.fallback
        self.assertEqual((fb["turns"], fb["tokens"]), (1, 1100))
        self.assertEqual(list(fb["models"]), ["codex/mystery-model"])
        self.assertGreater(fb["cost"], 0)

    def test_unlisted_gpt5_names_are_not_official(self):
        for name in ["gpt-5.6", "gpt-5.6-cyber", "gpt-5.5-cyber", "gpt-5.7", "gpt-5.4-foo", "gpt-5-future"]:
            _, src = u.openai_rates_and_source(name, 1000)
            self.assertEqual(src, "fallback", name)
        for name in ["gpt-5", "gpt-5.5", "gpt-5.4", "gpt-5.5-2026-04-23", "gpt-5-2025-08-07"]:
            _, src = u.openai_rates_and_source(name, 1000)
            self.assertEqual(src, "official", name)

    def test_unlisted_gpt5_goes_to_litellm(self):
        self.pf.write_text(json.dumps(lite_doc({"gpt-5.6": {"input_cost_per_token": 4e-6, "output_cost_per_token": 2e-5}})))
        rates, src = u.openai_rates_and_source("gpt-5.6", 1000)
        self.assertEqual((src, rates["input"]), ("litellm", 4.0))

    def test_new_official_gpt5_rows(self):
        for model, inp, out in [("gpt-5.2", 1.75, 14.0), ("gpt-5-pro", 15.0, 120.0), ("gpt-5.2-pro", 21.0, 168.0)]:
            rates, src = u.openai_rates_and_source(model, 1000)
            self.assertEqual((src, rates["input"], rates["output"]), ("official", inp, out), model)

    def test_fable_official_rates_and_unlisted_fallback(self):
        from datetime import datetime, timezone
        usage = {"input": 1_000_000, "output": 1_000_000, "cache_write": 1_000_000, "cache_read": 1_000_000, "reasoning": 0}
        for model, total in [
            ("claude-fable-5-2", 8.0 + 40.0 + 10.0 + 0.20),
            ("claude-fable-5-2[1m]", 8.0 + 40.0 + 10.0 + 0.20),
            ("claude-fable-5-1", 10.0 + 50.0 + 12.5 + 0.25),
            ("claude-fable-5-1[1m]", 10.0 + 50.0 + 12.5 + 0.25),
        ]:
            cost, fb = u.estimate_cost_ex("claude", model, usage)
            self.assertFalse(fb, model)
            self.assertAlmostEqual(cost, total, places=6, msg=model)
        for model in ("claude-fable-5-9", "claude-fable-5-20", "claude-fable-5-2x"):
            self.assertTrue(u.estimate_cost_ex("claude", model, usage)[1], model)
        agg = u.Aggregates("")
        ts = datetime.now(timezone.utc)
        for model in ("claude-fable-5-2", "claude-fable-5-1", "claude-fable-5-9"):
            agg.record({"agent": "claude", "ts": ts, "model": model, "usage": usage, "project": "p", "session_id": "s"})
        self.assertEqual(list(agg.fallback["models"]), ["claude/claude-fable-5-9"])
        self.assertEqual(agg.fallback["turns"], 1)

    def test_fallback_skips_zero_token_and_synthetic(self):
        agg = u.Aggregates("")
        from datetime import datetime, timezone
        ts = datetime.now(timezone.utc)
        z = {"input": 0, "output": 0, "cache_write": 0, "cache_read": 0, "reasoning": 0}
        agg.record({"agent": "claude", "ts": ts, "model": "<synthetic>", "usage": z, "project": "p", "session_id": "s"})
        agg.record({"agent": "codex", "ts": ts, "model": "mystery", "usage": z, "project": "p", "session_id": "s"})
        self.assertEqual(agg.fallback["turns"], 0)
        self.assertEqual(agg.fallback["models"], {})

    def test_litellm_rejects_nan_inf_negative(self):
        def row(i):
            return {"input_cost_per_token": i, "output_cost_per_token": 1e-6}
        self.pf.write_text(json.dumps(lite_doc({"nan": row("NaN"), "inf": row("Infinity"), "neg": row(-1e-6), "ok": row(1e-6)})))
        self.assertEqual(list(u.load_litellm_prices()), ["ok"])

    def test_print_fallback_none_prints_zero_line(self):
        import io, contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            u.print_fallback({"tokens": 0, "cost": 0.0, "turns": 0, "models": {}})
        self.assertIn("none", buf.getvalue())
        self.assertIn("0 turns", buf.getvalue())

    def test_refresh_prices_refuses_outside_git_checkout(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            import shutil
            shutil.copy(ROOT / "cctrl", d / "cctrl")
            shutil.copytree(ROOT / "lib", d / "lib")
            r = subprocess.run(["bash", str(d / "cctrl"), "costs", "--refresh-prices"], capture_output=True, text=True,
                               env={k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")})
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("git checkout", r.stderr)
            self.assertFalse((d / "share").exists())


class Refresh(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

    def raw(self, n=25):
        d = {f"gpt-x{i}": {"litellm_provider": "openai", "input_cost_per_token": 1e-06,
                           "output_cost_per_token": 2e-06, "junk": 1} for i in range(n)}
        d["claude-x"] = {"litellm_provider": "anthropic", "input_cost_per_token": 1, "output_cost_per_token": 1}
        return d

    def test_refresh_from_file_writes_subset(self):
        src, out = self.dir / "raw.json", self.dir / "out.json"
        src.write_text(json.dumps(self.raw()))
        self.assertEqual(rp.main(["--from-file", str(src), "--out", str(out)]), 0)
        doc = json.loads(out.read_text())
        self.assertEqual(len(doc["models"]), 25)
        self.assertNotIn("claude-x", doc["models"])
        self.assertNotIn("junk", doc["models"]["gpt-x1"])
        self.assertEqual(list(self.dir.glob("*.tmp")), [])

    def test_invalid_input_keeps_existing_file(self):
        src, out = self.dir / "raw.json", self.dir / "out.json"
        out.write_text("KEEP")
        for bad in (json.dumps(self.raw(3)), "[]", "{nope"):
            src.write_text(bad)
            self.assertEqual(rp.main(["--from-file", str(src), "--out", str(out)]), 1)
            self.assertEqual(out.read_text(), "KEEP")
        raw = self.raw()
        raw["gpt-x1"]["input_cost_per_token_above_272k_tokens"] = -1
        src.write_text(json.dumps(raw))
        self.assertEqual(rp.main(["--from-file", str(src), "--out", str(out)]), 1)
        self.assertEqual(out.read_text(), "KEEP")
        self.assertEqual(list(self.dir.glob("*.tmp")), [])

    def test_only_litellm_url_may_be_fetched(self):
        with self.assertRaises(ValueError):
            rp.fetch_raw("https://example.com/prices.json")


class CostsCli(unittest.TestCase):
    def test_text_and_json_report_fallback(self):
        from datetime import datetime, timezone
        with tempfile.TemporaryDirectory() as t:
            base = Path(t)
            codex = base / "codex" / "sessions" / "2026" / "11" / "16"
            codex.mkdir(parents=True)
            (base / "claude").mkdir()
            (base / "archive").mkdir()
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            tok = {"input_tokens": 1000, "cached_input_tokens": 0, "output_tokens": 100, "reasoning_output_tokens": 0}
            lines = [
                {"timestamp": now, "type": "session_meta", "payload": {"id": "s1", "cwd": "/x/demo"}},
                {"timestamp": now, "type": "turn_context", "payload": {"cwd": "/x/demo", "model": "mystery-model"}},
                {"timestamp": now, "type": "event_msg", "payload": {"type": "token_count",
                    "info": {"last_token_usage": tok, "total_token_usage": tok}}},
            ]
            (codex / "s.jsonl").write_text("\n".join(json.dumps(x) for x in lines) + "\n")
            env = dict(os.environ, CCTRL_PRICE_FILE=str(base / "none.json"))
            args = [sys.executable, str(ROOT / "lib" / "usage_costs.py"), "costs",
                    str(base / "claude"), str(base / "codex" / "sessions"), str(base / "archive"), "1", "", ""]
            text = subprocess.run(args, env=env, capture_output=True, text=True, check=True).stdout
            self.assertIn("Priced at fallback rate", text)
            self.assertIn("codex/mystery-model", text)
            js = json.loads(subprocess.run(args + ["json"], env=env, capture_output=True, text=True, check=True).stdout)
            fb = js["fallback_pricing"]
            self.assertEqual((fb["turns"], fb["tokens"]), (1, 1100))
            self.assertIn("codex/mystery-model", fb["models"])
            self.assertGreater(fb["cost"], 0)


if __name__ == "__main__":
    unittest.main()
