import base64, importlib.util, json, sys, tempfile, unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("outbox", HERE / "outbox.py")
outbox = importlib.util.module_from_spec(spec); sys.modules["outbox"] = outbox; spec.loader.exec_module(outbox)
gspec = importlib.util.spec_from_file_location("outbox_google", HERE.parent / "hermes-google-lite" / "google_api.py")
google = importlib.util.module_from_spec(gspec); gspec.loader.exec_module(google)
google._access_token = lambda force=False: "AT"


def b64(text): return base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")


class Resp:
    def __init__(self, status=200, payload=None): self.status_code, self._p = status, payload or {}; self.content = b"x"
    def json(self): return self._p


class Gmail:
    def __init__(self): self.calls, self.to, self.exists = [], "julie@example.com", True
    def __call__(self, method, url, **kw):
        self.calls.append((method, url, kw))
        if method == "GET" and "/drafts/r123" in url:
            if not self.exists: return Resp(404)
            return Resp(200, {"id": "r123", "message": {"id": "m9", "payload": {"mimeType": "multipart/mixed", "headers": [
                {"name": "To", "value": self.to}, {"name": "Subject", "value": "Facture"}], "parts": [
                {"mimeType": "text/plain", "body": {"data": b64("Salut Julie,\nCi-joint.\nMaxime")}},
                {"mimeType": "application/pdf", "filename": "facture.pdf", "body": {"size": 1234, "attachmentId": "a1"}}]}}})
        if method == "POST" and url.endswith("/drafts/send"): return Resp(200, {"id": "sent1", "threadId": "t1"})
        return Resp(404)


class Outbox(unittest.TestCase):
    def setUp(self):
        outbox._sent.clear(); self.gmail = Gmail(); self.home = Path(tempfile.mkdtemp())

    def test_the_draft_is_read_as_gmail_holds_it(self):
        view = outbox.read(google, "r123", http=self.gmail)
        self.assertEqual((view["to"], view["subject"], view["message_id"]), ("julie@example.com", "Facture", "m9"))
        self.assertIn("Ci-joint.", view["body"]); self.assertEqual(view["attachments"], [{"name": "facture.pdf", "type": "application/pdf", "size": 1234}])
        self.assertEqual(len(view["fingerprint"]), 64)
        with self.assertRaises(outbox.OutboxError): outbox.read(google, "../x", http=self.gmail)

    def test_it_sends_only_what_was_read_and_writes_a_journal_line(self):
        shown = outbox.read(google, "r123", http=self.gmail)["fingerprint"]
        self.gmail.to = "julie@example.com, inconnu@evil.example"                 # changed after Maxime read it
        with self.assertRaises(outbox.OutboxError) as refused: outbox.send(google, "r123", shown, self.home, http=self.gmail)
        self.assertEqual(refused.exception.status, 409)
        self.assertFalse([c for c in self.gmail.calls if c[0] == "POST"], "nothing was sent")
        self.gmail.to = "julie@example.com"
        self.assertEqual(outbox.send(google, "r123", shown, self.home, http=self.gmail)["message_id"], "sent1")
        post = [c for c in self.gmail.calls if c[0] == "POST"]
        self.assertEqual(len(post), 1); self.assertEqual(post[0][2]["json"], {"id": "r123"})
        line = json.loads((self.home / "widgets" / "envois.jsonl").read_text().splitlines()[0])
        self.assertEqual((line["to"], line["attachments"], line["message"]), ("julie@example.com", ["facture.pdf"], "sent1"))

    def test_only_reading_and_sending_a_draft_exist(self):
        for method, path in (("DELETE", "/drafts/r123"), ("POST", "/messages/send"), ("GET", "/messages/m9"), ("POST", "/drafts/r123")):
            with self.assertRaises(outbox.OutboxError): outbox._call(google, method, path, http=self.gmail)
        self.assertEqual(self.gmail.calls, [])

    def test_a_gone_draft_and_the_hourly_cap(self):
        self.gmail.exists = False
        with self.assertRaises(outbox.OutboxError) as gone: outbox.read(google, "r123", http=self.gmail)
        self.assertEqual(gone.exception.status, 404)
        self.gmail.exists = True
        shown = outbox.read(google, "r123", http=self.gmail)["fingerprint"]
        outbox._sent.extend([__import__("time").time()] * outbox.SENDS_PER_HOUR)
        with self.assertRaises(outbox.OutboxError) as capped: outbox.send(google, "r123", shown, self.home, http=self.gmail)
        self.assertEqual(capped.exception.status, 429)


if __name__ == "__main__":
    unittest.main()
