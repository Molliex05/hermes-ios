"""Offline: a fake geocoder that answers like Open-Meteo for « Saint-Constant » (France first, then Québec)."""
import importlib.util, sys, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("hermes_meteo", ROOT / "__init__.py", submodule_search_locations=[str(ROOT)])
meteo = importlib.util.module_from_spec(spec); sys.modules["hermes_meteo"] = meteo; spec.loader.exec_module(meteo)

RESULTS = [
    {"name": "Saint-Constant", "country": "France", "country_code": "FR", "admin1": "Auvergne-Rhône-Alpes"},
    {"name": "Saint-Constant", "country": "Canada", "country_code": "CA", "admin1": "Québec"},
    {"name": "Saint-Constant", "country": "France", "country_code": "FR", "admin1": "Nouvelle-Aquitaine"},
]


class Locate(unittest.TestCase):
    def setUp(self):
        meteo._get = lambda url, params: {"results": list(RESULTS)}
        meteo._preferred_country = lambda: "CA"

    def test_bare_name_prefers_the_home_country(self):
        self.assertEqual(meteo._locate("Saint-Constant")["country_code"], "CA")

    def test_several_hints_are_matched_one_by_one(self):
        self.assertEqual(meteo._locate("Saint-Constant, Québec, Canada")["country_code"], "CA")
        self.assertEqual(meteo._locate("Saint-Constant, Québec")["country_code"], "CA")

    def test_an_explicit_other_country_still_wins(self):
        self.assertEqual(meteo._locate("Saint-Constant, France")["country_code"], "FR")
        self.assertEqual(meteo._locate("Saint-Constant, Nouvelle-Aquitaine")["admin1"], "Nouvelle-Aquitaine")

    def test_an_unknown_hint_falls_back_to_the_home_country(self):
        self.assertEqual(meteo._locate("Saint-Constant, Atlantide")["country_code"], "CA")


if __name__ == "__main__":
    unittest.main()
