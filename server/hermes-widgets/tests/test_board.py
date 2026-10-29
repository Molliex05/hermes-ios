import importlib.util, json, sys, tempfile, unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

spec = importlib.util.spec_from_file_location("board", Path(__file__).resolve().parent.parent / "board.py")
board = importlib.util.module_from_spec(spec); sys.modules["board"] = board; spec.loader.exec_module(board)
NOW = datetime(2026, 10, 29, 10, 0, tzinfo=timezone.utc)


class Build(unittest.TestCase):
    def test_a_board_is_cleaned_and_bounded(self):
        made = board.build({"titre": "Aujourd'hui", "a_retenir": "Une chose\nà garder", "demander": "Et demain ?", "valide_heures": 3, "lignes": [
            {"texte": "Barbier", "heure": "13:45", "detail": "Don Barbero", "icone": "scissors", "ton": "POSITIVE"},
            {"texte": ""}, {"texte": "Souper", "icone": "pas un symbole!", "ton": "violet"}, "Dentiste", 7, None, {"x": 1}, {"texte": "6e"}, {"texte": "7e"}]}, NOW)
        self.assertEqual([i["text"] for i in made["items"]], ["Barbier", "Souper", "Dentiste", "7", "6e"], "empty lines dropped, five kept")
        self.assertEqual(made["items"][0]["tone"], "positive"); self.assertEqual(made["items"][0]["icon"], "scissors")
        self.assertEqual(made["items"][1]["icon"], ""); self.assertEqual(made["items"][1]["tone"], "")
        self.assertEqual(made["focus"], "Une chose à garder")
        self.assertEqual(made["expires_at"], "2026-10-29T13:00:00+00:00"); self.assertEqual(made["updated_at"], "2026-10-29T10:00:00+00:00")

    def test_validity_is_bounded_and_defaults(self):
        line = [{"texte": "x"}]
        self.assertEqual(board.build({"lignes": line}, NOW)["expires_at"], "2026-10-29T16:00:00+00:00")
        self.assertEqual(board.build({"lignes": line, "valide_heures": 9999}, NOW)["expires_at"], "2026-10-31T10:00:00+00:00")
        self.assertEqual(board.build({"lignes": line, "valide_heures": "n'importe quoi"}, NOW)["expires_at"], "2026-10-29T16:00:00+00:00")

    def test_nothing_to_show_is_refused_with_a_hint(self):
        for args in ({}, {"lignes": []}, {"lignes": [{"texte": "  "}]}, {"lignes": "texte"}):
            with self.assertRaises(ValueError) as caught:
                board.build(args, NOW)
            self.assertIn("effacer", str(caught.exception))
        self.assertTrue(board.build({"a_retenir": "Seulement ceci"}, NOW)["focus"])

    def test_bidi_and_zero_width_marks_are_removed(self):
        made = board.build({"lignes": [{"texte": "Rendez\u202evous\u200b 9h"}]}, NOW)
        self.assertEqual(made["items"][0]["text"], "Rendezvous 9h")

    def test_long_text_is_shortened_and_controls_removed(self):
        made = board.build({"lignes": [{"texte": "a\x00b" + "x" * 200}]}, NOW)
        self.assertEqual(len(made["items"][0]["text"]), 80); self.assertNotIn("\x00", made["items"][0]["text"])


class Merge(unittest.TestCase):
    def test_new_lines_go_first_without_erasing_the_rest(self):
        earlier = board.build({"titre": "Aujourd’hui", "lignes": [{"texte": "Barbier", "heure": "13:45"}, {"texte": "Souper"}], "a_retenir": "Appeler Julie", "valide_heures": 8}, NOW)
        new = board.build({"lignes": [{"texte": "Colis livré"}, {"texte": "souper", "detail": "chez Julie"}], "valide_heures": 2}, NOW)
        made = board.merge(earlier, new, NOW)
        self.assertEqual([i["text"] for i in made["items"]], ["Colis livré", "souper", "Barbier"], "same text is replaced, the new one wins")
        self.assertEqual((made["title"], made["focus"]), ("Aujourd’hui", "Appeler Julie"))
        self.assertEqual(made["expires_at"], earlier["expires_at"], "valid as long as the longer of the two")

    def test_a_note_replaces_the_note_and_a_missing_or_expired_board_is_just_the_new_one(self):
        earlier = board.build({"lignes": [{"texte": "a"}], "a_retenir": "ancien"}, NOW)
        self.assertEqual(board.merge(earlier, board.build({"a_retenir": "nouveau"}, NOW), NOW)["focus"], "nouveau")
        new = board.build({"lignes": [{"texte": "b"}]}, NOW)
        self.assertEqual(board.merge(None, new, NOW), new)
        self.assertEqual(board.merge(earlier, new, NOW + timedelta(days=2)), new)

    def test_five_lines_at_most(self):
        earlier = board.build({"lignes": [{"texte": f"a{n}"} for n in range(5)]}, NOW)
        made = board.merge(earlier, board.build({"lignes": [{"texte": "z1"}, {"texte": "z2"}]}, NOW), NOW)
        self.assertEqual([i["text"] for i in made["items"]], ["z1", "z2", "a0", "a1", "a2"])


class Storage(unittest.TestCase):
    def test_save_load_clear_and_skip_unreadable(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            for name in ("personnel", "noriven", "vide", "casse"):
                (root / name).mkdir()
            board.save(root / "personnel", board.build({"titre": "Jarvis", "lignes": [{"texte": "a"}]}, NOW))
            board.save(root / "noriven", board.build({"titre": "Serveur", "a_retenir": "Tout va bien"}, NOW))
            (root / "casse" / "widgets").mkdir(); (root / "casse" / "widgets" / "board.json").write_text("{pas du json")
            (root / "fichier.txt").write_text("not a profile")
            loaded = board.load_all(root)
            self.assertEqual(loaded["version"], 1); self.assertEqual(sorted(loaded["boards"]), ["noriven", "personnel"])
            self.assertEqual(loaded["boards"]["personnel"]["title"], "Jarvis")
            self.assertEqual(oct((root / "personnel" / "widgets" / "board.json").stat().st_mode)[-3:], "600")
            self.assertEqual([p.name for p in (root / "personnel" / "widgets").iterdir()], ["board.json"], "no temporary file is left behind")
            self.assertTrue(board.clear(root / "personnel")); self.assertFalse(board.clear(root / "personnel"))
            self.assertEqual(sorted(board.load_all(root)["boards"]), ["noriven"])
            self.assertEqual(board.load_all(root / "absent"), {"version": 1, "boards": {}})
            json.dumps(loaded)


if __name__ == "__main__":
    unittest.main()
