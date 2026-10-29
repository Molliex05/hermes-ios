import importlib.util, sys, unittest
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

here = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("weather", here / "weather.py")
weather = importlib.util.module_from_spec(spec); sys.modules["weather"] = weather; spec.loader.exec_module(weather)
ZONE = ZoneInfo("America/Toronto")
NOW = datetime(2026, 10, 29, 10, 20, tzinfo=ZONE)


def raw(**changes):
    hours = [f"2026-10-29T{h:02d}:00" for h in range(0, 24)] + [f"2026-10-30T{h:02d}:00" for h in range(0, 24)]
    answer = {
        "current": {"temperature_2m": 8.4, "apparent_temperature": 5.6, "weather_code": 3, "is_day": 1, "wind_speed_10m": 14.2},
        "hourly": {"time": hours, "temperature_2m": [float(n) for n in range(len(hours))], "precipitation_probability": [n % 100 for n in range(len(hours))],
                   "weather_code": [61] * len(hours), "is_day": [1 if 7 <= n % 24 < 18 else 0 for n in range(len(hours))]},
        "daily": {"time": ["2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01"], "weather_code": [3, 3, 61, 71, 0],
                  "temperature_2m_max": [11.2, 10.4, 7.1, 3.0, 5.0], "temperature_2m_min": [4.0, 3.2, 2.0, -1.0, -2.0],
                  "precipitation_probability_max": [10, 40, 80, 60, 0], "sunrise": ["", "2026-10-29T07:17", "", "", ""], "sunset": ["", "2026-10-29T17:48", "", "", ""]},
    }
    answer.update(changes)
    return answer


class Build(unittest.TestCase):
    def test_now_hours_and_days(self):
        made = weather.build(raw(), NOW)
        self.assertEqual((made["place"], made["temp"], made["feels"], made["wind"], made["summary"], made["symbol"]), ("Saint-Constant", 8, 6, 14, "Couvert", "cloud.fill"))
        self.assertEqual(len(made["hours"]), 8); self.assertEqual(made["hours"][0]["at"], "2026-10-29T10:00:00-04:00"); self.assertEqual(made["hours"][0]["temp"], 10)
        self.assertEqual(made["hours"][0]["symbol"], "cloud.rain.fill")
        self.assertEqual([d["date"] for d in made["days"]], ["2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01"], "yesterday is left out")
        today = made["days"][0]
        self.assertEqual((today["high"], today["low"], today["rain"], today["sunset"]), (10, 3, 40, "2026-10-29T17:48"))
        self.assertEqual(made["expires_at"], "2026-10-29T11:50:00-04:00")

    def test_night_uses_the_night_symbol(self):
        made = weather.build(raw(current={"temperature_2m": -1, "weather_code": 0, "is_day": 0}), NOW)
        self.assertEqual(made["symbol"], "moon.stars.fill"); self.assertIsNone(made["feels"])

    def test_unknown_code_and_a_broken_answer(self):
        self.assertEqual(weather.describe(1234)[1], "cloud.fill")
        self.assertIsNone(weather.build({}, NOW)); self.assertIsNone(weather.build({"current": {"temperature_2m": None}}, NOW))
        made = weather.build({"current": {"temperature_2m": 3}}, NOW)
        self.assertEqual((made["hours"], made["days"]), ([], []), "only the temperature is enough to draw something")


class Current(unittest.TestCase):
    def setUp(self): weather._cache.clear()

    def test_cached_and_a_failure_keeps_the_last_good_answer(self):
        calls = []
        def good(): calls.append(1); return raw()
        first = weather.current(NOW, good); self.assertEqual(weather.current(NOW, good), first); self.assertEqual(len(calls), 1)
        weather._cache["weather"]["at"] -= weather.CACHE_SECONDS + 1                       # the cache expires
        def broken(): raise OSError("down")
        self.assertEqual(weather.current(NOW, broken), first, "kept for a few hours")
        weather._cache["weather"]["at"] -= weather.FAILURE_SECONDS + 1; weather._cache["weather"]["good_at"] -= weather.STALE_SECONDS + 1
        self.assertIsNone(weather.current(NOW, broken), "too old to be kept")

    def test_no_answer_at_all(self):
        def broken(): raise OSError("down")
        self.assertIsNone(weather.current(NOW, broken))

    def test_with_weather_adds_nothing_when_there_is_none(self):
        self.assertEqual(weather.with_weather({"boards": {}}, lambda: None), {"boards": {}})
        self.assertEqual(weather.with_weather({"boards": {}}, lambda: {"temp": 3})["weather"], {"temp": 3})
        def explode(): raise ValueError("x")
        self.assertEqual(weather.with_weather({"boards": {}}, explode), {"boards": {}})


if __name__ == "__main__":
    unittest.main()
