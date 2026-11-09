import importlib.util, sys, tempfile, unittest
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

here = Path(__file__).resolve().parent.parent
def load(name):
    spec = importlib.util.spec_from_file_location(name, here / f"{name}.py")
    module = importlib.util.module_from_spec(spec); sys.modules[name] = module; spec.loader.exec_module(module); return module
agenda, board = load("agenda"), load("board")
ZONE = ZoneInfo("America/Toronto")
NOW = datetime(2026, 10, 29, 10, 0, tzinfo=ZONE)


def event(title, start, end=None, **extra):
    return {"titre": title, "debut": start, "fin": end or start, "lieu": "", "calendrier": "Personnel", **extra}


class Build(unittest.TestCase):
    def test_today_then_tomorrow_with_places_and_labels(self):
        events = [event("Souper chez Julie", "2026-10-29T18:30:00-04:00"), event("Quart de jour", "2026-10-29T06:45:00-04:00", "2026-10-29T15:00:00-04:00", calendrier="Police"),
                  event("Barbier", "2026-10-29T13:45:00-04:00", "2026-10-29T14:30:00-04:00", lieu="Don Barbero, Saint-Constant"),
                  event("Dentiste", "2026-10-30T09:00:00-04:00")]
        made = agenda.build(events, NOW)
        self.assertEqual([i["text"] for i in made["items"]], ["Quart de jour", "Barbier", "Souper chez Julie", "Dentiste"])
        self.assertEqual(made["items"][0]["detail"], "jusqu’à 15:00 · Police", "in progress at 10:00"); self.assertEqual(made["items"][1]["detail"], "Don Barbero, Saint-Constant")
        self.assertEqual(made["items"][3]["detail"], "Demain · Personnel"); self.assertEqual(made["items"][3]["time"], "09:00")
        self.assertEqual(made["items"][1]["at"], "2026-10-29T13:45:00-04:00"); self.assertEqual(made["title"], "Aujourd’hui")
        self.assertEqual(made["expires_at"], "2026-10-29T12:00:00-04:00")

    def test_finished_cancelled_and_untitled_events_are_left_out_and_five_is_the_cap(self):
        events = [event("Fini", "2026-10-29T07:00:00-04:00", "2026-10-29T08:00:00-04:00"), event("Annulé", "2026-10-29T11:00:00-04:00", statut="cancelled"),
                  event("", "2026-10-29T12:00:00-04:00"), event("En cours", "2026-10-29T09:30:00-04:00", "2026-10-29T10:30:00-04:00")]
        events += [event(f"Plus tard {n}", f"2026-10-29T{13 + n}:00:00-04:00") for n in range(7)]
        made = agenda.build(events, NOW)
        self.assertEqual(made["items"][0]["text"], "En cours"); self.assertEqual(len(made["items"]), 5)
        self.assertNotIn("Fini", [i["text"] for i in made["items"]])

    def test_all_day_events_are_a_line_without_a_time_and_only_for_today(self):
        made = agenda.build([event("Jour férié", "2026-10-29"), event("Demain férié", "2026-10-30")], NOW)
        self.assertEqual([(i["text"], i["time"], i["detail"]) for i in made["items"]], [("Jour férié", "", "Toute la journée")])

    def test_a_free_day_is_an_empty_board_not_nothing(self):
        made = agenda.build([], NOW)
        self.assertEqual(made["items"], []); self.assertTrue(made["expires_at"])


class NightsAndDays(unittest.TestCase):
    def test_a_night_shift_in_progress_says_until_when_and_keeps_its_end(self):
        at3 = datetime(2026, 10, 29, 3, 0, tzinfo=ZONE)
        made = agenda.build([event("Quart de nuit", "2026-10-28T22:00:00-04:00", "2026-10-29T06:00:00-04:00", calendrier="Police")], at3)
        item = made["items"][0]
        self.assertEqual((item["time"], item["detail"], item["until"]), ("22:00", "jusqu’à 06:00 · Police", "2026-10-29T06:00:00-04:00"))
        self.assertEqual(made["title"], "Aujourd’hui")

    def test_a_several_day_all_day_event_shows_on_each_of_its_days_and_not_after(self):
        week = event("Vacances", "2026-10-26", "2026-10-31")      # Google's end date is exclusive
        self.assertEqual(len(agenda.build([week], NOW)["items"]), 1)
        self.assertEqual(len(agenda.build([week], datetime(2026, 10, 31, 10, 0, tzinfo=ZONE))["items"]), 0)

    def test_months_are_french(self):
        made = agenda.build([event("Loin", "2026-11-03T09:00:00-05:00")], NOW)
        self.assertEqual(made["items"][0]["detail"], "3 nov · Personnel"); self.assertEqual(made["title"], "Prochainement")


class Route(unittest.TestCase):
    def test_only_profiles_with_google_get_an_agenda_and_failures_are_quiet(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            (root / "personnel").mkdir(); (root / "personnel" / ".env").write_text("# note\nGOOGLE_CLIENT_ID=a\nGOOGLE_CLIENT_SECRET='b'\nGOOGLE_REFRESH_TOKEN=c\n")
            (root / "noriven").mkdir(); (root / "noriven" / ".env").write_text("OTHER=1\n")
            self.assertTrue(agenda.has_google(root, "personnel")); self.assertFalse(agenda.has_google(root, "noriven"))
            self.assertEqual(agenda.read_env(root, "personnel")["GOOGLE_CLIENT_SECRET"], "b", "quotes are removed")
            (root / "personnel" / ".env").write_text("export GOOGLE_CLIENT_ID=a # note\nGOOGLE_CLIENT_SECRET=\"b # not a comment\"\nGOOGLE_REFRESH_TOKEN=c\nOTHER=secret\n")
            env = agenda.read_env(root, "personnel")
            self.assertEqual((env["GOOGLE_CLIENT_ID"], env["GOOGLE_CLIENT_SECRET"]), ("a", "b # not a comment"))
            self.assertNotIn("OTHER", env, "only the three credentials are kept")
            payload = board.with_agendas({"version": 1, "boards": {}}, root, source=agenda.upcoming)
            self.assertEqual(payload["agendas"], {}, "Google unreachable: no agenda, no error (nothing to reach in a test)")
            fake = board.with_agendas({"version": 1, "boards": {}}, root, source=lambda r, p: {"items": []} if p == "personnel" else None)
            self.assertEqual(list(fake["agendas"]), ["personnel"])


if __name__ == "__main__":
    unittest.main()
