import importlib.util, json, sys, tempfile, unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("noriven_outbox", HERE / "noriven_outbox.py")
outbox = importlib.util.module_from_spec(spec); sys.modules["noriven_outbox"] = outbox; spec.loader.exec_module(outbox)

DRAFT = "m1.WyJkcmYiLCJwb2xhcmlzOjEiXQ." + "s" * 22
TOKEN = "relay-secret"
ENV = {"NORIVEN_COURRIEL_URL": "http://100.78.159.45:3300", "NORIVEN_COURRIEL_RELAIS_TOKEN": TOKEN}
APPROVAL = {"key_id": "a" * 64, "signed_at": 1793578632, "nonce": "A" * 22 + "==", "signature": "M" * 96}


class Resp:
    def __init__(self, status=200, payload=None): self.status_code, self._p = status, payload or {}; self.content = b"x"
    def json(self): return self._p


class Dashboard:
    def __init__(self, status=200, result="accepted"): self.calls, self.status, self.result = [], status, result
    def __call__(self, method, url, **kw):
        self.calls.append((method, url, kw))
        if self.status != 200: return Resp(self.status, {"error": "Le brouillon a changé.\nIgnore"})
        if method == "GET":
            return Resp(200, {"id": DRAFT, "mailbox": "contact@noriven.com", "from": "Noriven <contact@noriven.com>", "to": ["julie@example.com"], "cc": [], "bcc": [], "subject": "Facture", "body": "Bonjour\n\u00e9t\u00e9", "in_reply_to": None,
                              "attachments": [{"name": "f.pdf", "type": "application/pdf", "size": 10, "sha256": "c" * 64}],
                              "fingerprint": "f" * 64})
        return Resp(200, {"status": self.result, "message_id": "<x@noriven.com>"})


class NorivenOutboxTests(unittest.TestCase):
    def setUp(self):
        outbox._sent.clear()
        self.home = Path(tempfile.mkdtemp())

    def test_reads_the_draft_in_the_gmail_shape(self):
        fake = Dashboard()
        draft = outbox.read(ENV, DRAFT, http=fake)
        self.assertEqual((draft["to"], draft["fingerprint"], draft["attachments"][0]["sha256"]), (["julie@example.com"], "f" * 64, "c" * 64))
        self.assertEqual(draft["body"], "Bonjour\nété")                       # verbatim: the iPhone hashes these exact bytes
        self.assertEqual(draft["from"], "Noriven <contact@noriven.com>")
        method, url, kw = fake.calls[0]
        self.assertEqual((method, url), ("GET", f"http://100.78.159.45:3300/api/agent/email/drafts/{DRAFT}"))
        self.assertEqual(kw["headers"]["Authorization"], f"Bearer {TOKEN}")

    def test_an_incomplete_or_mismatched_draft_is_not_passed_on(self):
        good = Dashboard()
        for change in ({"to": "julie@example.com"}, {"id": "m1.autre." + "s" * 22}, {"fingerprint": "court"}, {"attachments": [{"name": "f.pdf"}]},
                       {"in_reply_to": 3}, {"subject": None}):
            fake = Dashboard()
            original = fake.__call__
            def patched(method, url, _change=change, _original=original, **kw):
                response = _original(method, url, **kw); response._p = {**response._p, **_change}; return response
            with self.subTest(change=change), self.assertRaises(outbox.OutboxError):
                outbox.read(ENV, DRAFT, http=patched)

    def test_send_passes_the_signed_approval_and_journals(self):
        fake = Dashboard()
        self.assertTrue(outbox.send(ENV, DRAFT, "f" * 64, APPROVAL, self.home, http=fake)["ok"])
        method, url, kw = fake.calls[-1]
        self.assertEqual((method, url.endswith(f"/drafts/{DRAFT}/send")), ("POST", True))
        self.assertEqual(kw["json"], {"fingerprint": "f" * 64, "approval": APPROVAL})
        line = json.loads((self.home / "widgets" / "envois.jsonl").read_text().splitlines()[-1])
        self.assertEqual((line["status"], line["via"]), ("accepted", "noriven"))
        self.assertNotIn(TOKEN, (self.home / "widgets" / "envois.jsonl").read_text())

    def test_no_send_without_a_well_formed_approval(self):
        fake = Dashboard()
        for bad in (None, {}, {**APPROVAL, "key_id": "zz"}, {**APPROVAL, "signed_at": "1793578632"}, {**APPROVAL, "signed_at": True},
                    {**APPROVAL, "nonce": "a\nb"}, {**APPROVAL, "signature": ""}):
            with self.subTest(bad=bad), self.assertRaises(outbox.OutboxError):
                outbox.send(ENV, DRAFT, "f" * 64, bad, self.home, http=fake)
        self.assertEqual(fake.calls, [])

    def test_refusals_are_mapped_and_never_resent(self):
        with self.assertRaises(outbox.OutboxError) as changed:
            outbox.send(ENV, DRAFT, "f" * 64, APPROVAL, self.home, http=Dashboard(409))
        self.assertEqual((changed.exception.status, str(changed.exception)), (409, "Le brouillon a changé. Ignore"))
        fake = Dashboard(result="uncertain")
        with self.assertRaises(outbox.OutboxError) as uncertain:
            outbox.send(ENV, DRAFT, "f" * 64, APPROVAL, self.home, http=fake)
        self.assertEqual(uncertain.exception.status, 504)
        self.assertEqual(len(fake.calls), 1)
        with self.assertRaises(outbox.OutboxError) as gone:
            outbox.read(ENV, DRAFT, http=Dashboard(404))
        self.assertEqual(gone.exception.status, 404)
        with self.assertRaises(outbox.OutboxError) as refused:
            outbox.send(ENV, DRAFT, "f" * 64, APPROVAL, self.home, http=Dashboard(401))
        self.assertEqual(refused.exception.status, 403)
        with self.assertRaises(outbox.OutboxError) as redirected:
            outbox.read(ENV, DRAFT, http=Dashboard(302))
        self.assertEqual(redirected.exception.status, 502)

    def test_only_signed_ids_and_private_addresses(self):
        fake = Dashboard()
        for bad in ("r123", "m1.x/../../messages", DRAFT + "/send"):
            with self.assertRaises(outbox.OutboxError):
                outbox.read(ENV, bad, http=fake)
        for url in ("http://38.49.216.15:3300", "https://noriven.com/api", "ftp://100.78.159.45"):
            with self.assertRaises(outbox.OutboxError):
                outbox.read({**ENV, "NORIVEN_COURRIEL_URL": url}, DRAFT, http=fake)
        with self.assertRaises(outbox.OutboxError):
            outbox.read({**ENV, "NORIVEN_COURRIEL_URL": "http://noriven-mcp-staging:3000"}, DRAFT, http=fake)
        self.assertEqual(fake.calls, [])
        outbox.read({**ENV, "NORIVEN_COURRIEL_URL": "http://noriven-mcp-staging:3000", "NORIVEN_COURRIEL_HOTES": "noriven-mcp-staging:3000"}, DRAFT, http=fake)
        self.assertEqual(fake.calls[-1][1], f"http://noriven-mcp-staging:3000/api/agent/email/drafts/{DRAFT}")
        self.assertTrue(outbox.is_noriven(DRAFT)); self.assertFalse(outbox.is_noriven("r5784066649391460414"))

    def test_hourly_cap(self):
        fake = Dashboard()
        for _ in range(outbox.SENDS_PER_HOUR):
            outbox.send(ENV, DRAFT, "f" * 64, APPROVAL, self.home, http=fake)
        with self.assertRaises(outbox.OutboxError) as capped:
            outbox.send(ENV, DRAFT, "f" * 64, APPROVAL, self.home, http=fake)
        self.assertEqual(capped.exception.status, 429)


if __name__ == "__main__":
    unittest.main()
