import datetime as dt
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import paie  # noqa: E402
import service  # noqa: E402


class Classement(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name) / "Paye"
        (self.root / "2026" / "08 - Aout").mkdir(parents=True)
        (self.root / "2026" / "08 - Aout" / "Paye (2026-08-06).pdf").write_bytes(b"%PDF-1.4")

    def tearDown(self):
        self.dir.cleanup()

    def test_uses_the_existing_month_folder_or_the_same_convention(self):
        self.assertEqual(paie.target(self.root, dt.date(2026, 8, 13)), self.root / "2026/08 - Aout/Paye (2026-08-13).pdf")
        self.assertEqual(paie.target(self.root, dt.date(2027, 2, 4)), self.root / "2027/02 - Fevrier/Paye (2027-02-04).pdf")

    def test_files_once_and_never_overwrites(self):
        path = paie.file_pdf(self.root, dt.date(2026, 11, 12), b"%PDF-1.7 talon")
        self.assertEqual(path, self.root / "2026/11 - Novembre/Paye (2026-11-12).pdf")
        self.assertIsNone(paie.file_pdf(self.root, dt.date(2026, 11, 12), b"%PDF-1.7 autre"))
        self.assertEqual(path.read_bytes(), b"%PDF-1.7 talon")
        self.assertFalse(list(self.root.rglob("*.partiel")))
        with self.assertRaises(paie.PaieError):
            paie.file_pdf(self.root, dt.date(2026, 11, 19), b"<html>session expiree</html>")

    def test_a_file_icloud_moved_off_the_mac_still_counts(self):
        (self.root / "2026" / "08 - Aout" / ".Paye (2026-08-13).pdf.icloud").write_bytes(b"")
        self.assertIn(dt.date(2026, 8, 13), paie.filed(self.root))

    def test_reads_the_worked_weeks_and_spots_adjustments(self):
        text = ("Période travaillée 2026-20 du 10 mai 2026 au 16 mai 2026   No. de l'employé: 1\n"
                "Période travaillée 2026-28 du 5 juil. 2026 au 11 juil. 2026\n"
                "Période travaillée 2026-31 du 26 juil. 2026 au 1 août 2026\n")
        self.assertEqual([w[0] for w in paie.periods(text)], ["2026-20", "2026-28", "2026-31"])
        weeks = paie.weeks_of(dt.date(2026, 7, 23), text)
        self.assertEqual(weeks["semaine_payee"], {"semaine": "2026-28", "du": "2026-07-05", "au": "2026-07-11"})
        self.assertEqual([w["semaine"] for w in weeks["ajustements"]], ["2026-20", "2026-31"])

    def test_parses_the_list_of_published_payslips(self):
        html = ('<a href="/fr/compte">Accueil</a><ul><li><a href="/fr/compte/detail-talon/456112"> 2026-11-19 </a></li>'
                '<li><a class="x" href="/fr/compte/detail-talon/455259">2026-11-12</a></li><a href="/fr/compte/detail-talon/1">voir</a></ul>')
        self.assertEqual(paie.parse_list(html), {dt.date(2026, 11, 19): "456112", dt.date(2026, 11, 12): "455259"})


class FakeSession:
    def __init__(self, published, refuse=False):
        self.published, self.refuse, self.downloaded, self.closed = published, refuse, [], False

    def login(self):
        if self.refuse:
            raise paie.LoginRefused("refusé")

    def talons(self):
        return self.published

    def pdf(self, number):
        self.downloaded.append(number)
        return b"%PDF-1.7 " + number.encode()

    def logout(self):
        self.closed = True


class Synchronisation(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        base = Path(self.dir.name)
        self.root = base / "Paye"
        (self.root / "2026" / "11 - Novembre").mkdir(parents=True)
        (self.root / "2026" / "11 - Novembre" / "Paye (2026-11-05).pdf").write_bytes(b"%PDF-1.4")
        self.state = mock.patch.object(paie, "STATE", base / "etat")
        self.state.start()
        self.first = mock.patch.object(paie, "FIRST_PAY", dt.date(2026, 11, 5))
        self.first.start()

    def tearDown(self):
        self.state.stop(); self.first.stop(); self.dir.cleanup()

    def test_downloads_only_what_is_missing_and_logs_out(self):
        session = FakeSession({dt.date(2026, 11, 5): "1", dt.date(2026, 11, 12): "2", dt.date(2026, 11, 19): "3"})
        report = paie.synchronize(self.root, today=dt.date(2026, 11, 19), session=session)
        self.assertEqual(session.downloaded, ["2", "3"])
        self.assertTrue(session.closed)
        self.assertEqual([n["date"] for n in report["nouveaux"]], ["2026-11-12", "2026-11-19"])
        self.assertEqual(report["jeudis_sans_talon_classe"], [])
        self.assertTrue((self.root / "2026/11 - Novembre/Paye (2026-11-19).pdf").is_file())

    def test_a_thursday_without_a_published_payslip_is_reported(self):
        report = paie.synchronize(self.root, today=dt.date(2026, 11, 19), session=FakeSession({dt.date(2026, 11, 5): "1"}))
        self.assertEqual(report["jeudis_sans_talon_publie"], ["2026-11-12", "2026-11-19"])

    def test_a_refused_login_pauses_further_attempts(self):
        with self.assertRaises(paie.LoginRefused):
            paie.synchronize(self.root, session=FakeSession({}, refuse=True))
        with self.assertRaisesRegex(paie.PaieError, "Pas de nouvel essai"):
            paie.synchronize(self.root, session=FakeSession({dt.date(2026, 11, 5): "1"}))

    def test_reads_a_filed_payslip_by_date_only(self):
        self.assertEqual(paie.read(self.root, dt.date(2026, 11, 5)), b"%PDF-1.4")
        with self.assertRaises(paie.PaieError):
            paie.read(self.root, dt.date(2026, 11, 12))


class Service(unittest.TestCase):
    def call(self, method="GET", path="/etat", auth="Bearer secret", peer=service.SERVER_TAILSCALE, local=service.MAC_TAILSCALE):
        return service.respond(method, path, {"authorization": auth}, peer, local, "secret")

    def test_only_the_server_over_tailscale_with_the_token(self):
        with mock.patch.object(paie, "status", return_value={"ok": True}):
            self.assertEqual(self.call()[0], 200)
            self.assertEqual(self.call(peer="100.91.78.17")[0], 403, "another tailnet device")
            self.assertEqual(self.call(local="192.168.1.20", peer=service.SERVER_TAILSCALE)[0], 403, "not through Tailscale")
            self.assertEqual(self.call(auth="Bearer autre")[0], 401)
            self.assertEqual(service.respond("GET", "/etat", {}, service.SERVER_TAILSCALE, service.MAC_TAILSCALE, "")[0], 401, "no token set up")

    def test_a_payslip_is_asked_for_by_date_never_by_path(self):
        self.assertEqual(self.call(path="/talon/../../.ssh/id_ed25519")[0], 404)
        self.assertEqual(self.call(path="/talon/2026-13-40")[0], 400)
        with mock.patch.object(paie, "read", return_value=b"%PDF-1.7"):
            status, kind, body = self.call(path="/talon/2026-11-12")
        self.assertEqual((status, kind, body), (200, "application/pdf", b"%PDF-1.7"))

    def test_the_layout_text_of_a_payslip_by_date(self):
        with mock.patch.object(paie, "read_text", return_value="Période travaillée 2026-45   40,00"):
            status, kind, body = self.call(path="/texte/2026-11-19")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["texte"], "Période travaillée 2026-45   40,00")
        self.assertEqual(self.call(path="/texte/../x")[0], 404)

    def test_failures_are_told_plainly(self):
        with mock.patch.object(paie, "synchronize", side_effect=paie.LoginRefused("MaPaie.net a refusé la connexion")):
            status, _, body = self.call(method="POST", path="/synchroniser")
        self.assertEqual(status, 502)
        self.assertIn("refusé", json.loads(body)["erreur"])


if __name__ == "__main__":
    unittest.main()
