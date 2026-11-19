"""Offline: the app's PDF route checks its profile and date and never takes a path."""
import base64
import importlib.util
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

try:
    import fastapi  # noqa: F401
except ImportError:
    fastapi = None

ROOT = Path(__file__).resolve().parent.parent


@unittest.skipIf(fastapi is None, "fastapi absent (present on the server)")
class Route(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.profiles = Path(self.dir.name)
        (self.profiles / "personnel" / "paie").mkdir(parents=True)
        (self.profiles / "personnel" / "paie" / "Paye (2026-11-19).pdf").write_bytes(b"%PDF-1.7 talon")
        self.env = mock.patch.dict(os.environ, {"HERMES_PROFILES_DIR": str(self.profiles)}); self.env.start()
        spec = importlib.util.spec_from_file_location("hermes_paie_api", ROOT / "dashboard" / "plugin_api.py")
        self.api = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.api)

    def tearDown(self):
        self.env.stop(); self.dir.cleanup()

    def test_returns_the_profiles_copy(self):
        answer = self.api.payslip("personnel", "2026-11-19")
        self.assertEqual(base64.b64decode(answer["pdf"]), b"%PDF-1.7 talon")

    def test_refuses_odd_profiles_and_dates(self):
        from fastapi import HTTPException
        for profile, date in (("../x", "2026-11-19"), ("inconnu", "2026-11-19"), ("personnel", "2026-02-30"), ("personnel", "..%2F..")):
            with self.assertRaises(HTTPException, msg=f"{profile} {date}"):
                self.api.payslip(profile, date)


if __name__ == "__main__":
    unittest.main()
