import asyncio, importlib.util, sys, unittest
from datetime import date
from pathlib import Path

spec = importlib.util.spec_from_file_location("snap", Path(__file__).resolve().parent.parent / "snapshot.py")
snap = importlib.util.module_from_spec(spec); sys.modules["snap"] = snap; spec.loader.exec_module(snap)

MONEY = {"ok": True, "data_environment": "production", "rows": [
    {"month": "2026-10-01", "estimated_net_revenue": 247.99, "confirmed_net_revenue": 0, "total_expenses": 160.97, "estimated_profit": 87.02},
    {"month": "2026-09-01", "estimated_net_revenue": 275.11, "confirmed_net_revenue": 0, "total_expenses": 28.17, "estimated_profit": 246.94}]}
MRR = {"ok": True, "rows": [{"month": "2026-09-01", "mrr": 100.5, "active_subscriptions": 40, "snapshot_date": "2026-09-30"},
                            {"month": "2026-10-01", "mrr": 120.25, "active_subscriptions": 44, "trialing_subscriptions": 7, "snapshot_date": "2026-10-19"}]}


PROJECTION = {"ok": True, "currency": "CAD", "current_month": {"month": "2026-10", "realized": 247.99, "future": 120.5, "total": 368.49},
              "next_month": {"month": "2026-11", "total": 410.1}, "twelve_months_total": 4800.25,
              "months": [{"month": "2026-10", "realized": 247.99, "future": 120.5, "total": 368.49}, {"month": "2026-11", "realized": 0, "future": 410.1, "total": 410.1}]}


class Fake:
    def __init__(self, fail_after=None, projection=PROJECTION): self.calls = []; self.fail = False; self.projection = projection
    async def __call__(self, name, args):
        self.calls.append((name, args))
        if self.fail: raise RuntimeError("secret upstream detail")
        if name == "analytics_get_finance_projection":
            if self.projection is None: raise RuntimeError("unknown tool")
            return self.projection
        return MONEY if args["dataset"] == "revenue_vs_expenses_monthly" else MRR


class Snapshot(unittest.TestCase):
    def setUp(self): snap._cache.update(at=0.0, value=None)

    def test_shape_and_values(self):
        value = asyncio.run(snap.fetch(Fake(), date(2026, 10, 20)))
        self.assertEqual(value["finance"]["label"], "octobre 2026")
        self.assertEqual(value["finance"]["current"]["estimated_profit"], 87.02)
        self.assertEqual(value["finance"]["previous"]["expenses"], 28.17)
        self.assertEqual([m["month"] for m in value["finance"]["months"]], ["2026-05", "2026-06", "2026-07", "2026-08", "2026-09", "2026-10"])
        self.assertEqual(value["finance"]["months"][0]["estimated_revenue"], 0.0)       # month without a row
        self.assertEqual(value["mrr"]["value"], 120.25); self.assertEqual(value["mrr"]["trialing_subscriptions"], 7)
        self.assertEqual(value["projection"]["month_total"], 368.49); self.assertEqual(value["projection"]["twelve_month_total"], 4800.25)
        self.assertEqual(value["projection"]["next_month_total"], 410.1); self.assertEqual(len(value["projection"]["months"]), 2)
        self.assertEqual(value["currency"], "CAD")

    def test_projection_absent_or_unknown_tool_keeps_everything_else(self):
        value = asyncio.run(snap.fetch(Fake(projection=None), date(2026, 10, 20)))
        self.assertIsNone(value["projection"]); self.assertEqual(value["finance"]["current"]["estimated_revenue"], 247.99)
        self.assertIsNone(snap._projection({"ok": False})); self.assertIsNone(snap._projection({"ok": True, "months": []}))
        partial = snap._projection({"ok": True, "current_month": {"total": None}, "twelve_months_total": None, "months": [{"month": "2026-10", "total": None}]})
        self.assertIsNone(partial["month_total"]); self.assertIsNone(partial["twelve_month_total"])

    def test_year_rollover(self):
        self.assertEqual(snap._shift("2026-01", -1), "2025-12"); self.assertEqual(snap._shift("2026-10", -5), "2026-05")
        self.assertEqual(snap.month_label("2026-01"), "janvier 2026")

    def test_window_asks_six_months(self):
        fake = Fake(); asyncio.run(snap.fetch(fake, date(2026, 10, 20)))
        self.assertEqual(fake.calls[0][1]["from"], "2026-05"); self.assertEqual(fake.calls[0][1]["to"], "2026-10")

    def test_cache_then_stale_without_leaking(self):
        fake = Fake()
        first = asyncio.run(snap.snapshot(fake, now=1000.0)); asyncio.run(snap.snapshot(fake, now=1100.0))
        self.assertEqual(len(fake.calls), 3)                                  # one fetch = 2 datasets + projection; second served from cache
        fake.fail = True
        stale = asyncio.run(snap.snapshot(fake, now=1000.0 + snap.CACHE_SECONDS + 1))
        self.assertTrue(stale["stale"]); self.assertEqual(stale["finance"], first["finance"])
        snap._cache.update(at=0.0, value=None)
        with self.assertRaises(RuntimeError): asyncio.run(snap.snapshot(fake, now=5000.0))

    def test_mrr_failure_keeps_money(self):
        class NoMrr(Fake):
            async def __call__(self, name, args):
                if args["dataset"] == "glutax_mrr_monthly": raise RuntimeError("x")
                return await super().__call__(name, args)
        value = asyncio.run(snap.fetch(NoMrr(), date(2026, 10, 20)))
        self.assertIsNone(value["mrr"]); self.assertEqual(value["finance"]["current"]["estimated_revenue"], 247.99)


if __name__ == "__main__":
    unittest.main()
