import importlib.util, pathlib, sys, tempfile, unittest

HERE = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("hermes_widgets_seen", HERE / "seen.py")
seen = importlib.util.module_from_spec(spec); sys.modules[spec.name] = seen; spec.loader.exec_module(seen)


class Script:
    KEYS = ("A",)
    def __init__(self): self.calls = []
    def archive_seen(self, api, folder): self.calls.append((api, folder)); return 2
    def load_api(self, env): return ("noriven", env)


class Agenda:
    def __init__(self, google): self.google = google
    def has_google(self, root, profile): return self.google
    def _google(self, root, profile): return "gmail"
    def read_env(self, root, profile, keys): return {"A": "1"}


class Seen(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp())
        self.folder = self.root / "p" / "widgets" / "a_classer"

    def test_nothing_waiting_touches_no_mailbox(self):
        self.assertEqual(seen.archive(self.root, "p", Agenda(True), load=lambda path: self.fail("no script needed")), 0)

    def test_gmail_and_noriven_each_archive_with_their_own_api(self):
        self.folder.mkdir(parents=True); (self.folder / "1.json").write_text('{"ids":["abcdef"]}')
        for google, script, api in ((True, seen.GMAIL_SCRIPT, "gmail"), (False, self.root / "p" / seen.NORIVEN_SCRIPT, ("noriven", {"A": "1"}))):
            fake, asked = Script(), []
            self.assertEqual(seen.archive(self.root, "p", Agenda(google), load=lambda path: asked.append(path) or fake), 2)
            self.assertEqual(asked, [script]); self.assertEqual(fake.calls, [(api, self.folder)])

    def test_a_noriven_message_reads_whole_without_being_marked_read(self):
        asked = []
        class Api:
            def message_path(self, message_id): return "/m/" + message_id
            def request(self, method, path, **kwargs): asked.append((method, path, kwargs)); return {"text": "Bonjour", "truncated": True, "from": "x"}
        class Loaded(Script):
            def load_api(self, env): return Api()
        read = seen.read_noriven(self.root, "noriven", Agenda(False), "m1.a.b", load=lambda path: Loaded())
        self.assertEqual(read, {"id": "m1.a.b", "texte": "Bonjour", "tronque": True})
        self.assertEqual(asked, [("GET", "/m/m1.a.b", {})])
