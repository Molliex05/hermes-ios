import importlib.util, pathlib, sys, tempfile, unittest

HERE = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("push_service", HERE / "push_service.py")
service = importlib.util.module_from_spec(spec); sys.modules["push_service"] = service; spec.loader.exec_module(service)


def member(seq, who, text): return {"seq": seq, "kind": "message.member", "payload": {"member_id": who, "text": text}}
def settled(seq, status="settled"): return {"seq": seq, "kind": "room.activity", "payload": {"status": status}}


class Rooms:
    room = {"room_id": "ROOM-1", "name": "Test", "members": [{"member_id": "noriven", "profile": "noriven", "display_name": "Hermès"},
                                                             {"member_id": "personnel", "profile": "personnel", "display_name": "Jarvis"}]}
    def __init__(self, events): self.events = events
    def default_db_path(self): return "db"
    def list_rooms(self, path): return [self.room]
    def read_events(self, path, *, room_id, since_seq, limit):
        rows = [event for event in self.events if event["seq"] > since_seq]
        return {"events": rows[:limit], "cursor": rows[-1]["seq"] if rows else since_seq, "latest_seq": self.events[-1]["seq"] if self.events else 0, "has_more": False}


class Store:
    def __init__(self): self.cursors, self.sent = {}, []
    def room_cursor(self, room): return self.cursors.get(room)
    def set_room_cursor(self, room, seq): self.cursors[room] = seq
    def enqueue(self, event, profile, session, kind, content): self.sent.append((event, profile, session, kind, content))


class GroupNotifications(unittest.TestCase):
    def test_a_room_seen_for_the_first_time_brings_back_nothing(self):
        store = Store()
        service.scan_rooms(store, Rooms([member(1, "noriven", "Salut"), settled(2)]), ["db"])
        self.assertEqual(store.sent, []); self.assertEqual(store.cursors["ROOM-1"], 2)

    def test_a_discussion_is_told_once_when_it_settles(self):
        store = Store(); store.cursors["ROOM-1"] = 0
        rooms = Rooms([member(1, "noriven", "Bonjour"), member(2, "personnel", "Salut Hermès")])
        service.scan_rooms(store, rooms, ["db"])
        self.assertEqual(store.sent, [], "still talking: nothing yet")
        rooms.events.append(settled(3))
        service.scan_rooms(store, rooms, ["db"]); service.scan_rooms(store, rooms, ["db"])
        self.assertEqual(len(store.sent), 1)
        _, profile, session, kind, content = store.sent[0]
        self.assertEqual((profile, session, kind), ("personnel", "ROOM-1", "room"))
        self.assertEqual(content["agent"], "Hermès et Jarvis"); self.assertEqual(content["conversation"], "Test")
        self.assertEqual(content["preview"], "Salut Hermès")

    def test_one_unreadable_store_does_not_hide_the_other(self):
        class Broken(Rooms):
            def list_rooms(self, path):
                if path == "bad": raise OSError("no such table")
                return super().list_rooms(path)
        store = Store(); store.cursors["ROOM-1"] = 0
        service.scan_rooms(store, Broken([member(1, "noriven", "Bonjour"), settled(2)]), ["bad", "db"])
        self.assertEqual(len(store.sent), 1)

    def test_a_silent_round_says_nothing(self):
        store = Store(); store.cursors["ROOM-1"] = 0
        service.scan_rooms(store, Rooms([member(1, "noriven", "(pass)"), settled(2, "bounded")]), ["db"])
        self.assertEqual(store.sent, []); self.assertEqual(store.cursors["ROOM-1"], 2)

    def test_a_group_alert_opens_the_group_and_offers_no_reply(self):
        payload = service.notification_payload({"event": "e", "connection": "c", "profile": "noriven", "session": "ROOM-1", "kind": "room", "enc": "x"})
        self.assertEqual(payload["hermes"]["kind"], "room"); self.assertEqual(payload["hermes"]["session_id"], "ROOM-1")
        self.assertNotIn("category", payload["aps"])

    def test_presence_in_the_room_quiets_it_whichever_agent_spoke(self):
        store = service.Store(pathlib.Path(tempfile.mkdtemp()))
        store.set_presence("i", "c", "personnel", "ROOM-1", 60)
        row = {"event": "e", "installation": "i", "connection": "c", "profile": "noriven", "session": "ROOM-1", "kind": "room"}
        self.assertTrue(store.suppress_if_present(row))
        self.assertFalse(store.suppress_if_present({**row, "session": "ROOM-2"}))
        store.set_room_cursor("ROOM-1", 7); self.assertEqual(store.room_cursor("ROOM-1"), 7)
