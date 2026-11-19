"""Offline: a fake Mac service answers like hermes-paie's service.py."""
import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("hermes_paie", ROOT / "__init__.py", submodule_search_locations=[str(ROOT)])
paie = importlib.util.module_from_spec(spec); sys.modules["hermes_paie"] = paie; spec.loader.exec_module(paie)


class Response:
    def __init__(self, status, body):
        self.status_code = status
        self.content = body if isinstance(body, bytes) else json.dumps(body).encode()

    def json(self):
        return json.loads(self.content)


class Tools(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        sys.modules["hermes_constants"] = types.SimpleNamespace(get_hermes_home=lambda: self.home.name)
        self.env = mock.patch.dict(os.environ, {"HERMES_PAIE_TOKEN": "jeton"})
        self.env.start()
        self.calls = []

    def tearDown(self):
        self.env.stop(); self.home.cleanup(); sys.modules.pop("hermes_constants", None)

    def answer(self, response):
        def call(method, path, timeout):
            self.calls.append((method, path)); return response
        return mock.patch.object(paie, "_call", side_effect=call)

    def test_synchronize_returns_the_macs_report(self):
        with self.answer(Response(200, {"ok": True, "nouveaux": [{"date": "2026-11-19"}]})):
            result = json.loads(paie.synchronize({}))
        self.assertEqual(result["nouveaux"][0]["date"], "2026-11-19")
        self.assertEqual(self.calls, [("POST", "/synchroniser")])

    def test_a_refused_login_is_told_plainly(self):
        with self.answer(Response(502, {"ok": False, "erreur": "MaPaie.net a refusé la connexion"})):
            result = json.loads(paie.synchronize({}))
        self.assertEqual(result, {"ok": False, "erreur": "MaPaie.net a refusé la connexion"})

    def test_read_saves_the_pdf_in_the_profile_and_asks_by_date_only(self):
        with self.answer(Response(200, b"%PDF-1.7 talon")), mock.patch.object(paie, "_text", return_value="Période travaillée 2026-45"):
            result = json.loads(paie.read({"date": "2026-11-19"}))
        self.assertEqual(self.calls, [("GET", "/talon/2026-11-19")])
        self.assertTrue(result["ok"]); self.assertIn("2026-45", result["texte"])
        self.assertEqual(Path(result["fichier"]).read_bytes(), b"%PDF-1.7 talon")
        self.assertEqual(Path(result["fichier"]).parent, Path(self.home.name) / "paie")

    def test_read_refuses_anything_but_a_date(self):
        for bad in ("../../etc/passwd", "2026-11-19/../x", "", "2026-13-45"):
            with self.answer(Response(200, b"%PDF-")):
                self.assertFalse(json.loads(paie.read({"date": bad}))["ok"], bad)
        self.assertEqual(self.calls, [])

    def test_no_token_means_a_clear_error(self):
        with mock.patch.dict(os.environ, {"HERMES_PAIE_TOKEN": ""}):
            result = json.loads(paie.synchronize({}))
        self.assertIn("HERMES_PAIE_TOKEN", result["erreur"])


if __name__ == "__main__":
    unittest.main()
