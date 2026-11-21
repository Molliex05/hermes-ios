"""Agent calls: the guards, the timer that leaves the table alone between calls, and the ring. No Apple traffic."""
import asyncio
import importlib.util
import os
import sys
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

PLUGIN = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("push_for_calls", PLUGIN / "push_service.py")
push = importlib.util.module_from_spec(_spec); sys.modules[_spec.name] = push; _spec.loader.exec_module(push)
_spec = importlib.util.spec_from_file_location("calls_under_test", PLUGIN / "agent_calls.py")
calls = importlib.util.module_from_spec(_spec); sys.modules[_spec.name] = calls; _spec.loader.exec_module(calls)

TZ = ZoneInfo("America/Toronto")
NOW = datetime(2026, 11, 23, 8, 0, tzinfo=TZ)


class Sender:
    def __init__(self):
        self.rings = []

    async def deliver_voip(self, device, payload):
        self.rings.append((device["token"], payload))
        return 200, "", None


class AgentCalls(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = push.Store(Path(self.dir.name))
        self.store.register("I", "C", "ab" * 32, "sandbox", None, "cd" * 32)

    def tearDown(self):
        self.dir.cleanup()

    def test_guards_refuse_what_the_prompt_must_not_decide(self):
        with self.assertRaisesRegex(calls.CallRefused, "23 h"):
            calls.plan(self.store, "personnel", "Jarvis", "2026-11-23T23:30", "nuit", now=NOW)
        with self.assertRaisesRegex(calls.CallRefused, "36 heures"):
            calls.plan(self.store, "personnel", "Jarvis", "2026-11-25T09:00", "loin", now=NOW)
        with self.assertRaisesRegex(calls.CallRefused, "passée"):
            calls.plan(self.store, "personnel", "Jarvis", "2026-11-23T07:00", "passé", now=NOW)
        with self.assertRaisesRegex(calls.CallRefused, "raison"):
            calls.plan(self.store, "personnel", "Jarvis", "2026-11-23T13:00", "  ", now=NOW)
        for hour in (9, 10, 11):
            calls.plan(self.store, "personnel", "Jarvis", f"2026-11-23T{hour:02d}:00", "essai", now=NOW)
        with self.assertRaisesRegex(calls.CallRefused, "3 appels"):
            calls.plan(self.store, "personnel", "Jarvis", "2026-11-23T12:00", "un de trop", now=NOW)

    def test_the_same_key_moves_the_call(self):
        first = calls.plan(self.store, "personnel", "Jarvis", "2026-11-23T13:45", "trajet", "quart-23", now=NOW)
        moved = calls.plan(self.store, "personnel", "Jarvis", "2026-11-23T14:00", "trajet", "quart-23", now=NOW)
        self.assertEqual(first["id"], moved["id"]); self.assertTrue(moved["deplace"])
        self.assertEqual([c["quand"] for c in calls.upcoming(self.store, "personnel", NOW.timestamp())], ["2026-11-23T14:00-05:00"])
        self.assertEqual(calls.cancel(self.store, "personnel", "quart-23"), 1)
        self.assertEqual(calls.upcoming(self.store, "personnel", NOW.timestamp()), [])

    def test_the_worker_rings_once_at_the_time_and_leaves_the_table_alone_before(self):
        planned = calls.plan(self.store, "personnel", "Jarvis", "2026-11-23T13:45", "trajet vers ton quart", now=NOW)
        at = datetime(2026, 11, 23, 13, 45, tzinfo=TZ).timestamp()
        sender, timer = Sender(), calls.Timer()
        self.assertEqual(asyncio.run(calls.deliver(self.store, sender, timer, NOW.timestamp())), {"rung": 0, "other": 0})
        self.assertEqual(timer.check_at, min(at, NOW.timestamp() + calls.IDLE_RECHECK), "next look: the call, or 10 min")
        self.assertFalse(timer.due(self.store, NOW.timestamp() + 5), "nothing to do between two looks")
        asyncio.run(calls.deliver(self.store, sender, timer, at + 2))
        asyncio.run(calls.deliver(self.store, sender, calls.Timer(), at + 5))
        self.assertEqual(len(sender.rings), 1, "rung once, even by a second worker")
        token, payload = sender.rings[0]
        self.assertEqual(token, "cd" * 32)
        self.assertEqual(payload, {"hermes": {"kind": "call", "call": planned["id"], "profile": "personnel", "agent": "Jarvis"}},
                         "the push carries no reason: it crosses Apple unencrypted")
        self.assertTrue(calls.record_outcome(self.store, planned["id"], "answered"))
        self.assertFalse(calls.record_outcome(self.store, planned["id"], "missed"), "a late « missed » never overwrites « answered »")

    def test_a_call_far_past_its_time_is_dropped_not_rung(self):
        calls.plan(self.store, "personnel", "Jarvis", "2026-11-23T13:45", "trajet", now=NOW)
        at = datetime(2026, 11, 23, 13, 45, tzinfo=TZ).timestamp()
        sender = Sender()
        asyncio.run(calls.deliver(self.store, sender, calls.Timer(), at + calls.LATE + 60))
        self.assertEqual(sender.rings, [])

    def test_a_device_without_pushkit_cannot_be_rung(self):
        self.store.register("I", "C", "ab" * 32, "sandbox", None, None)
        self.assertEqual(calls.voip_devices(self.store), [])


if __name__ == "__main__":
    unittest.main()
