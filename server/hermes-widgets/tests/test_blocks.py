import importlib.util, json, sys, tempfile, unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

spec = importlib.util.spec_from_file_location("blocks", Path(__file__).resolve().parent.parent / "blocks.py")
blocks = importlib.util.module_from_spec(spec); sys.modules["blocks"] = blocks; spec.loader.exec_module(blocks)
NOW = datetime(2026, 11, 2, 12, 0, tzinfo=timezone.utc)


def metrics(*values):
    return {"type": "metrics", "items": [{"label": f"L{i}", "value": v} for i, v in enumerate(values)]}


class Card(unittest.TestCase):
    def test_each_kind_is_cut_to_size(self):
        made = blocks.card({"type": "METRICS", "title": "Trésorerie" * 9, "icon": "banknote", "reply": "Détaille", "items": [
            {"label": "Solde", "value": "8 420,00 $", "delta": "+3 %", "tone": "positive"}, {"label": "", "value": "x"},
            {"label": "a", "value": "1"}, {"label": "b", "value": "2"}, {"label": "c", "value": "3"}, {"label": "d", "value": "4"}]})
        self.assertEqual(len(made["items"]), 4); self.assertEqual(len(made["title"]), 30)
        self.assertEqual(made["ask"], "Détaille"); self.assertEqual(made["items"][0]["tone"], "positive")
        rings = blocks.card({"type": "progress", "items": [{"label": "Calories", "value": "1 850", "goal": 2400, "unit": "kcal"},
                                                           {"label": "Zéro", "value": 3, "goal": 0}, {"label": "Inf", "value": float("inf"), "goal": 2}]})
        self.assertEqual(rings["items"], [{"label": "Calories", "value": 1850.0, "goal": 2400.0, "unit": "kcal"}])
        chart = blocks.card({"type": "chart", "style": "bar", "points": [{"label": str(i), "value": i} for i in range(30)] + [{"value": "x"}]})
        self.assertEqual(len(chart["points"]), 24); self.assertEqual(chart["points"][-1]["value"], 29.0); self.assertEqual(chart["style"], "bar")
        self.assertEqual(blocks.card({"type": "meteo"})["type"], "meteo")

    def test_empty_or_unknown_cards_are_refused_with_a_hint(self):
        for raw in ("texte", {"type": "brief"}, {"type": "metrics", "items": []}, {"type": "chart", "points": [{"value": 1}]},
                    {"type": "note", "text": " "}, {"type": "list", "items": [{"title": ""}]}, {"type": "progress", "items": [{"label": "x", "value": True, "goal": 2}]}):
            with self.assertRaises(ValueError):
                blocks.card(raw)

    def test_hidden_marks_and_huge_numbers_are_dropped(self):
        made = blocks.card({"type": "note", "text": "Pay‮er​\nmaintenant"})
        self.assertEqual(made["text"], "Payer maintenant")
        with self.assertRaises(ValueError):
            blocks.card({"type": "progress", "items": [{"label": "x", "value": 1e13, "goal": 2}]})


class Slots(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())

    def test_a_slot_is_replaced_and_others_are_kept(self):
        blocks.publish(self.home, {"blocs": [{"emplacement": "journee", "ordre": 1, "carte": {"type": "meteo"}},
                                             {"emplacement": "finances", "ordre": 3, "carte": metrics("1 $")}]}, NOW)
        done = blocks.publish(self.home, {"blocs": [{"emplacement": "finances", "ordre": 2, "carte": metrics("2 $")}]}, NOW)
        live = blocks.read(self.home, NOW)
        self.assertEqual([b["slot"] for b in live], ["journee", "finances"])
        self.assertEqual(live[1]["card"]["items"][0]["value"], "2 $")
        self.assertEqual([row["emplacement"] for row in done["widget"]], ["journee", "finances"])

    def test_order_then_name_and_expiry(self):
        blocks.publish(self.home, {"blocs": [{"emplacement": "b", "carte": metrics("1"), "valide_heures": 1},
                                             {"emplacement": "a", "carte": metrics("2"), "ordre": 99}]}, NOW)
        self.assertEqual([(b["slot"], b["order"]) for b in blocks.read(self.home, NOW)], [("b", 5), ("a", 9)])
        later = blocks.read(self.home, NOW + timedelta(hours=2))
        self.assertEqual([b["slot"] for b in later], ["a"])
        self.assertFalse((self.home / "widgets" / "blocs" / "b.json").exists(), "an expired block is removed")

    def test_erase_one_or_all(self):
        blocks.publish(self.home, {"blocs": [{"emplacement": "a", "carte": metrics("1")}, {"emplacement": "b", "carte": metrics("2")}]}, NOW)
        self.assertEqual(blocks.publish(self.home, {"effacer": ["a", "../x"]}, NOW)["effaces"], ["a"])
        blocks.publish(self.home, {"effacer": "tout"}, NOW)
        self.assertEqual(blocks.read(self.home, NOW), [])

    def test_a_bad_block_writes_nothing(self):
        with self.assertRaises(ValueError):
            blocks.publish(self.home, {"blocs": [{"emplacement": "a", "carte": metrics("1")}, {"emplacement": "b", "carte": {"type": "x"}}]}, NOW)
        self.assertEqual(blocks.read(self.home, NOW), [])
        for slot in ("../etc", "", "A" * 30, "deux mots"):
            with self.assertRaises(ValueError):
                blocks.publish(self.home, {"blocs": [{"emplacement": slot, "carte": metrics("1")}]}, NOW)
        with self.assertRaises(ValueError):
            blocks.publish(self.home, {"blocs": [{"emplacement": str(i), "carte": metrics("1")} for i in range(5)]}, NOW)
        with self.assertRaises(ValueError):
            blocks.publish(self.home, {}, NOW)

    def test_at_most_six_slots(self):
        for i in range(6):
            blocks.publish(self.home, {"blocs": [{"emplacement": f"s{i}", "carte": metrics("1")}]}, NOW)
        with self.assertRaises(ValueError) as caught:
            blocks.publish(self.home, {"blocs": [{"emplacement": "s7", "carte": metrics("1")}]}, NOW)
        self.assertIn("efface", str(caught.exception))
        blocks.publish(self.home, {"blocs": [{"emplacement": "s0", "carte": metrics("2")}]}, NOW)     # reusing one is fine

    def test_with_blocks_serves_each_profile(self):
        root = Path(tempfile.mkdtemp())
        blocks.publish(root / "personnel", {"blocs": [{"emplacement": "journee", "carte": {"type": "affiche"}}]}, NOW)
        (root / "noriven").mkdir()
        (root / "personnel" / "widgets" / "blocs" / "casse.json").write_text("{pas du json")
        payload = blocks.with_blocks({"version": 1}, root, NOW)
        self.assertEqual(list(payload["blocks"]), ["personnel"]); self.assertEqual(payload["version"], 1)
        self.assertEqual(json.loads(json.dumps(payload))["blocks"]["personnel"][0]["card"]["type"], "affiche")


if __name__ == "__main__":
    unittest.main()
