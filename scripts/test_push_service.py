"""Hermes notification outbox + APNs contract tests; no real device or Apple traffic.

PLUGIN_DIR=<dir> runs the same tests against another copy of the plugin (e.g. a review bundle)."""
import asyncio
import base64
import importlib.util
import json
import logging
import os
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
import unittest
from unittest import mock
import uuid

import httpx
import jwt
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import Encoding, PrivateFormat, NoEncryption

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = Path(os.environ.get('PLUGIN_DIR') or ROOT / 'server/hermes-ios-push').resolve()
VECTOR = json.loads((ROOT / 'HermesIOSTests/Fixtures/notification-vector.json').read_text())
spec = importlib.util.spec_from_file_location('push', PLUGIN / 'push_service.py')
push = importlib.util.module_from_spec(spec); spec.loader.exec_module(push)
KEY = bytes(range(32))


class Notifications(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.store = push.Store(self.home)
        self.installation, self.connection, self.event = [str(uuid.uuid4()) for _ in range(3)]
        self.token = 'ab' * 32
        self.store.register(self.installation, self.connection, self.token, 'sandbox')

    def tearDown(self):
        self.temp.cleanup()

    def enqueue(self):
        self.store.enqueue(self.event, 'research', 'native-session')
        return self.store.pending()[0]

    def test_deduplication_and_private_payload(self):
        row = self.enqueue(); self.enqueue()
        self.assertEqual(len(self.store.pending()), 1)
        payload = push.notification_payload(row)
        self.assertEqual(payload['hermes']['connection_id'], self.connection)
        self.assertEqual(payload['hermes']['session_id'], 'native-session')
        self.assertEqual(payload['hermes']['profile'], 'research')
        self.assertNotIn('assistant_response', json.dumps(payload))
        self.store.resolve(row, 200)
        self.assertEqual(self.store.pending(), [])
        self.store.enqueue(self.event, 'research', 'native-session')
        self.assertEqual(self.store.pending(), [])

    def test_rotation_revoke_and_delayed_invalidation(self):
        row = self.enqueue()
        self.store.register(self.installation, self.connection, 'cd' * 32, 'production')
        self.store.resolve(row, 410, 'Unregistered', int((time.time() - 5) * 1000))
        with self.store.connect() as db:
            device = db.execute('SELECT * FROM devices').fetchone()
        self.assertEqual(device['token'], 'cd' * 32)
        self.store.revoke(self.installation, self.connection)
        self.store.enqueue(str(uuid.uuid4()), 'research', 'another')
        self.assertEqual(self.store.pending(), [])

    def test_transient_error_retries_without_duplicate_outbox(self):
        row = self.enqueue()
        self.store.resolve(row, 503, 'ServiceUnavailable')
        self.assertEqual(self.store.pending(), [])
        with self.store.connect() as db:
            item = db.execute('SELECT * FROM outbox').fetchone()
            self.assertEqual(item['state'], 'pending')
            self.assertEqual(item['attempts'], 1)
            db.execute('UPDATE outbox SET next_attempt=0')
        self.assertEqual(len(self.store.pending()), 1)

    def test_different_connections_never_share_thread_or_target(self):
        second = str(uuid.uuid4())
        self.store.register(self.installation, second, 'cd' * 32, 'sandbox')
        self.enqueue()
        rows = self.store.pending()
        self.assertEqual(len(rows), 2)
        payloads = [push.notification_payload(r) for r in rows]
        self.assertNotEqual(payloads[0]['aps']['thread-id'], payloads[1]['aps']['thread-id'])

    def test_apns_wire_auth_and_environment(self):
        key = ec.generate_private_key(ec.SECP256R1())
        path = self.home / 'fixture.p8'
        path.write_bytes(key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption()))
        config = {'key_path':str(path), 'key_id':'TESTKEY', 'team_id':'TESTTEAM'}
        (self.home / 'apns.json').write_text(json.dumps(config))
        self.assertIsNotNone(push.load_settings(self.home))
        row = self.enqueue()
        requests = []
        def handle(request):
            requests.append(request)
            self.assertEqual(request.headers['apns-topic'], push.TOPIC)
            self.assertEqual(request.headers['apns-push-type'], 'alert')
            token = request.headers['authorization'].removeprefix('bearer ')
            self.assertEqual(jwt.decode(token, key.public_key(), algorithms=['ES256'])['iss'], 'TESTTEAM')
            self.assertEqual(json.loads(request.content)['hermes']['session_id'], 'native-session')
            return httpx.Response(200)
        async def run():
            async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
                sender = push.APNs(config, client)
                self.assertEqual((await sender.deliver(row))[0], 200)
                row['environment'] = 'production'
                self.assertEqual((await sender.deliver(row))[0], 200)
        asyncio.run(run())
        self.assertEqual(requests[0].url.host, 'api.sandbox.push.apple.com')
        self.assertEqual(requests[1].url.host, 'api.push.apple.com')

    def test_missing_or_invalid_key_is_not_ready(self):
        self.assertIsNone(push.load_settings(self.home))
        (self.home / 'broken.p8').write_text('invalid')
        (self.home / 'apns.json').write_text(json.dumps({'key_path':str(self.home/'broken.p8'),'team_id':'test','key_id':'test'}))
        self.assertIsNone(push.load_settings(self.home))


def row_for(store, **filters):
    with store.connect() as db:
        return [dict(r) for r in db.execute('SELECT * FROM outbox ORDER BY created')]


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.store = push.Store(self.home)
        self.installation, self.connection = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
        self.store.register(self.installation, self.connection, 'ab' * 32, 'sandbox', KEY)

    def tearDown(self):
        self.temp.cleanup()

    def content(self, preview='Le rapport est prêt.'):
        return {'agent': 'Hermès', 'conversation': 'Rapport SEO', 'preview': preview}

    def pending(self):
        return self.store.pending()


class Encryption(Fixture):
    def test_vector_both_directions(self):
        key = base64.b64decode(VECTOR['key_b64']); nonce = base64.b64decode(VECTOR['nonce_b64'])
        plain = json.loads(VECTOR['plaintext_json'])
        self.assertEqual(push.decrypt_content(key, VECTOR['event_id'], VECTOR['enc_b64']), plain)
        self.assertEqual(push.encrypt_content(key, VECTOR['event_id'], plain, nonce), VECTOR['enc_b64'])
        with self.assertRaises(Exception):      # AAD is the event id
            push.decrypt_content(key, str(uuid.uuid4()), VECTOR['enc_b64'])

    def test_key_validation_never_echoes_value(self):
        self.assertEqual(push.decode_key(VECTOR['key_b64']), base64.b64decode(VECTOR['key_b64']))
        secret = base64.b64encode(b'x' * 16).decode()
        for bad in [secret, 'not base64!', '', None, 12, base64.b64encode(b'x' * 33).decode(), 'A' * 200]:
            with self.assertRaises(ValueError) as caught:
                push.decode_key(bad)
            self.assertNotIn(secret, str(caught.exception))

    def test_sealed_payload_shape_and_decryption(self):
        self.store.enqueue(self.event(), 'noriven', 'sess-1', 'turn', self.content())
        row = self.pending()[0]
        payload = push.notification_payload(row)
        self.assertEqual(payload['aps']['mutable-content'], 1)
        self.assertEqual(payload['aps']['alert'], {'title': 'Hermès', 'body': 'Nouveau message'})
        self.assertEqual(payload['hermes']['kind'], 'turn')
        self.assertEqual(push.decrypt_content(KEY, row['event'], payload['hermes']['enc']), self.content())
        self.assertNotIn('Rapport', json.dumps(payload['aps']))
        self.assertNotIn('key', row)

    def event(self):
        return str(uuid.uuid4())

    def test_huge_response_stays_under_4096_and_still_decrypts(self):
        for size in (500, 5_000, 200_000):
            event = self.event()
            long_session = 'S' * 200
            self.store.enqueue(event, 'noriven', long_session, 'turn',
                               {'agent': 'A' * 500, 'conversation': 'é' * 900, 'preview': 'Ünïcode ✓ ' * size})
            row = next(r for r in self.pending() if r['event'] == event)
            body = json.dumps(push.notification_payload(row), ensure_ascii=False, separators=(',', ':')).encode()
            self.assertLess(len(body), 4096)
            self.assertIsNotNone(row['enc'])
            plain = push.decrypt_content(KEY, event, row['enc'])
            self.assertLessEqual(len(plain['agent']), 60)
            self.assertLessEqual(len(plain['conversation']), 100)
            self.assertTrue(plain['preview'].startswith('Ünïcode'))

    def test_unsealable_content_degrades_to_generic_not_failure(self):
        event = self.event()
        self.store.enqueue(event, 'p' * 4000, 'sess', 'turn', self.content())      # absurd metadata: no room at all
        row = next(r for r in self.pending() if r['event'] == event)
        self.assertIsNone(row['enc'])
        self.assertEqual(push.notification_payload(row)['aps']['alert']['body'], 'Un nouveau message vous attend.')

    def test_device_without_key_gets_v01_generic_notification(self):
        other = str(uuid.uuid4()).upper()
        self.store.register(self.installation, other, 'cd' * 32, 'sandbox')
        self.store.enqueue(self.event(), 'noriven', 'sess', 'turn', self.content())
        rows = {r['connection']: r for r in self.pending()}
        self.assertIsNone(rows[other]['enc'])
        payload = push.notification_payload(rows[other])
        self.assertNotIn('enc', payload['hermes']); self.assertNotIn('mutable-content', payload['aps'])
        self.assertEqual(payload['aps']['alert']['body'], 'Un nouveau message vous attend.')
        self.assertIsNotNone(rows[self.connection]['enc'])

    def test_each_device_gets_its_own_ciphertext(self):
        other, key2 = str(uuid.uuid4()).upper(), bytes(range(1, 33))
        self.store.register(self.installation, other, 'cd' * 32, 'sandbox', key2)
        event = self.event()
        self.store.enqueue(event, 'noriven', 'sess', 'turn', self.content())
        rows = {r['connection']: r for r in self.pending()}
        self.assertEqual(push.decrypt_content(key2, event, rows[other]['enc']), self.content())
        with self.assertRaises(Exception):
            push.decrypt_content(KEY, event, rows[other]['enc'])

    def test_rotation_replaces_key_and_drops_stale_ciphertext(self):
        event = self.event()
        self.store.enqueue(event, 'noriven', 'sess', 'turn', self.content())
        new_key = bytes(range(2, 34))
        self.store.register(self.installation, self.connection, 'ab' * 32, 'sandbox', new_key)
        self.assertIsNone(self.pending()[0]['enc'])
        event2 = self.event()
        self.store.enqueue(event2, 'noriven', 'sess', 'turn', self.content())
        row = next(r for r in self.pending() if r['event'] == event2)
        self.assertEqual(push.decrypt_content(new_key, event2, row['enc']), self.content())

    def test_registration_without_key_clears_the_previous_key(self):
        self.store.register(self.installation, self.connection, 'ab' * 32, 'sandbox')
        self.store.enqueue(self.event(), 'noriven', 'sess', 'turn', self.content())
        self.assertIsNone(self.pending()[0]['enc'])


class Migration(unittest.TestCase):
    def test_v01_database_keeps_working(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            db = sqlite3.connect(home / 'notifications.sqlite')
            db.executescript("""
                CREATE TABLE devices (installation TEXT NOT NULL, connection TEXT NOT NULL, token TEXT NOT NULL,
                    environment TEXT NOT NULL, registered REAL NOT NULL, PRIMARY KEY (installation, connection));
                CREATE TABLE outbox (event TEXT NOT NULL, installation TEXT NOT NULL, connection TEXT NOT NULL,
                    profile TEXT NOT NULL, session TEXT NOT NULL, created REAL NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL DEFAULT 0,
                    state TEXT NOT NULL DEFAULT 'pending', reason TEXT, PRIMARY KEY (event, installation, connection));""")
            db.execute("INSERT INTO devices VALUES ('I1','C1',?,?,?)", ('ef' * 32, 'production', time.time()))
            db.execute("INSERT INTO outbox(event,installation,connection,profile,session,created) VALUES ('E1','I1','C1','noriven','S1',?)", (time.time(),))
            db.commit(); db.close()
            store = push.Store(home)
            store2 = push.Store(home)      # idempotent
            row = store.pending()[0]
            self.assertEqual((row['event'], row['kind'], row['enc'], row['title']), ('E1', 'turn', None, None))
            payload = push.notification_payload(row)
            self.assertEqual(payload['aps']['alert']['body'], 'Un nouveau message vous attend.')
            self.assertEqual(payload['hermes']['session_id'], 'S1')
            self.assertEqual([r[1] for r in sqlite3.connect(home / 'notifications.sqlite').execute('PRAGMA table_info(devices)')],
                             ['installation', 'connection', 'token', 'environment', 'registered'])      # untouched
            store.register('I1', 'C1', 'ef' * 32, 'production', KEY)       # old device row gains a key
            store.enqueue('E2', 'noriven', 'S2', 'turn', {'agent': 'A', 'conversation': 'C', 'preview': 'P'})
            self.assertIsNotNone(next(r for r in store.pending() if r['event'] == 'E2')['enc'])
            self.assertEqual(oct(store.path.stat().st_mode & 0o777), '0o600')
            # v0.1 code (positional INSERT into devices, named INSERT into outbox) still works on the migrated database
            db = sqlite3.connect(home / 'notifications.sqlite')
            db.execute("INSERT INTO devices VALUES ('I2','C2',?,?,?)", ('aa' * 32, 'sandbox', time.time()))
            db.execute("INSERT OR IGNORE INTO outbox(event,installation,connection,profile,session,created) SELECT 'E3',installation,connection,'p','s',? FROM devices", (time.time(),))
            db.commit(); db.close()
            self.assertEqual({d['connection'] for d in store.devices()}, {'C1', 'C2'})


class Revocation(Fixture):
    def test_revoke_removes_key_ciphertext_and_presence(self):
        self.store.set_presence(self.installation, self.connection, 'noriven', 'sess', 60)
        self.store.enqueue(self.event(), 'noriven', 'sess', 'turn', self.content())
        self.store.revoke(self.installation, self.connection)
        with self.store.connect() as db:
            for table in ('devices', 'outbox', 'presence'):
                self.assertEqual(db.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0], 0)
        self.assertNotIn(KEY, self.store.path.read_bytes())      # secure_delete overwrote the freed pages

    def event(self):
        return str(uuid.uuid4())

    def test_invalid_token_410_removes_device_and_key(self):
        self.store.enqueue(self.event(), 'noriven', 'sess', 'turn', self.content())
        row = self.pending()[0]
        self.store.resolve(row, 410, 'Unregistered', int((time.time() + 5) * 1000))
        self.assertEqual(self.store.devices(), [])
        self.assertNotIn(KEY, self.store.path.read_bytes())

    def test_sent_row_keeps_no_ciphertext(self):
        self.store.enqueue(self.event(), 'noriven', 'sess', 'turn', self.content())
        self.store.resolve(self.pending()[0], 200)
        self.assertTrue(all(r['enc'] is None for r in row_for(self.store)))


class Presence(Fixture):
    class Recorder:
        def __init__(self): self.rows = []
        async def deliver(self, row):
            self.rows.append(row); return 200, '', None

    def run_worker(self):
        sender = self.Recorder()
        counts = asyncio.run(push.deliver_pending(self.store, sender))
        return counts, sender.rows

    def enqueue(self, session='sess', kind='turn'):
        event = str(uuid.uuid4())
        if kind == 'turn':
            self.store.enqueue(event, 'noriven', session, 'turn', self.content())
        return event

    def test_live_presence_suppresses_at_send_time_not_at_enqueue(self):
        self.enqueue()                                    # queued BEFORE the user opens the conversation
        self.store.set_presence(self.installation, self.connection, 'noriven', 'sess', 60)
        counts, sent = self.run_worker()
        self.assertEqual((counts['suppressed'], sent), (1, []))
        state = row_for(self.store)[0]
        self.assertEqual((state['state'], state['reason'], state['enc']), ('suppressed', 'presence', None))
        self.assertEqual(self.pending(), [])

    def test_presence_cleared_before_send_sends(self):
        self.enqueue()
        self.store.set_presence(self.installation, self.connection, 'noriven', 'sess', 60)
        self.store.clear_presence(self.installation, self.connection, 'noriven', 'sess')
        counts, sent = self.run_worker()
        self.assertEqual((counts['sent'], len(sent)), (1, 1))

    def test_expired_presence_does_not_suppress(self):
        self.enqueue()
        self.store.set_presence(self.installation, self.connection, 'noriven', 'sess', 60)
        with self.store.connect() as db:
            db.execute('UPDATE presence SET expires=?', (time.time() - 1,))
        self.assertEqual(self.run_worker()[0]['sent'], 1)

    def test_other_installation_presence_does_not_suppress(self):
        self.enqueue()
        self.store.set_presence(str(uuid.uuid4()).upper(), self.connection, 'noriven', 'sess', 60)
        self.assertEqual(self.run_worker()[0]['sent'], 1)

    def test_other_session_connection_or_profile_does_not_suppress(self):
        self.enqueue()
        self.store.set_presence(self.installation, self.connection, 'noriven', 'other-session', 60)
        self.store.set_presence(self.installation, self.connection, 'autre', 'sess', 60)
        self.store.set_presence(self.installation, str(uuid.uuid4()).upper(), 'noriven', 'sess', 60)
        self.assertEqual(self.run_worker()[0]['sent'], 1)

    def test_presence_suppresses_only_the_matching_installation_when_two_devices(self):
        second = str(uuid.uuid4()).upper()
        self.store.register(second, self.connection, 'cd' * 32, 'sandbox', KEY)
        self.enqueue()
        self.store.set_presence(self.installation, self.connection, 'noriven', 'sess', 60)
        counts, sent = self.run_worker()
        self.assertEqual((counts['suppressed'], counts['sent']), (1, 1))
        self.assertEqual(sent[0]['installation'], second)

    def test_tool_notifications_are_never_suppressed(self):
        self.store.set_presence(self.installation, self.connection, 'noriven', 'sess', 60)
        self.assertTrue(self.store.enqueue_tool('noriven', 'sess', 'sess', 'T1', self.content(), 'Hermès')['ok'])
        counts, sent = self.run_worker()
        self.assertEqual((counts['sent'], counts['suppressed']), (1, 0))
        self.assertEqual(sent[0]['kind'], 'tool')

    def test_ttl_is_bounded_and_put_extends(self):
        self.store.set_presence(self.installation, self.connection, 'noriven', 'sess', 1)
        with self.store.connect() as db:
            first = db.execute('SELECT expires FROM presence').fetchone()[0]
        self.assertAlmostEqual(first - time.time(), 5, delta=1)
        self.store.set_presence(self.installation, self.connection, 'noriven', 'sess', 99999)
        with self.store.connect() as db:
            rows = db.execute('SELECT expires FROM presence').fetchall()
        self.assertEqual(len(rows), 1)
        self.assertAlmostEqual(rows[0][0] - time.time(), 120, delta=1)


class ToolOutbox(Fixture):
    def call(self, store=None, profile='noriven', now=None, session='', turn_session='sess', turn='T1'):
        return (store or self.store).enqueue_tool(profile, session, turn_session, turn, self.content(), 'Hermès', now)

    def test_five_per_hour_and_refusals_are_not_counted(self):
        t = 1_000_000.0
        for i in range(5):
            self.assertTrue(self.call(now=t + i)['ok'])
        refused = self.call(now=t + 10)
        self.assertEqual(refused['error'], 'limit_hour')
        self.assertGreater(refused['retry_in'], 3500)
        self.call(now=t + 11)
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM tool_log').fetchone()[0], 5)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM outbox WHERE kind='tool'").fetchone()[0], 5)
        self.assertTrue(self.call(now=t + 3601)['ok'])        # the window slides
        self.assertTrue(self.call(profile='autre', now=t + 11)['ok'])      # per profile

    def test_twenty_per_day(self):
        t = 2_000_000.0
        for i in range(20):
            self.assertTrue(self.call(now=t + i * 726)['ok'], i)       # never more than 5 per hour
        refused = self.call(now=t + 20 * 726)
        self.assertEqual(refused['error'], 'limit_day')
        self.assertTrue(self.call(now=t + 86400 + 726)['ok'])

    def test_counted_at_enqueue_even_if_delivery_fails_or_is_dropped(self):
        t = time.time()
        for i in range(5):
            self.call(now=t - 100 + i)
        for row in self.pending():
            self.store.resolve(row, 400, 'BadRequest')
        self.assertEqual(self.call(now=t)['error'], 'limit_hour')

    def test_concurrent_calls_cannot_exceed_the_limit(self):
        results = []
        def work():
            results.append(push.Store(self.home).enqueue_tool('noriven', '', 's', 't', self.content(), 'Hermès')['ok'])
        threads = [threading.Thread(target=work) for _ in range(16)]
        [t.start() for t in threads]; [t.join() for t in threads]
        self.assertEqual(results.count(True), 5)

    def test_no_device_is_a_clear_error_and_not_counted(self):
        self.store.revoke(self.installation, self.connection)
        self.assertEqual(self.call()['error'], 'no_device')
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM tool_log').fetchone()[0], 0)

    def test_session_is_omitted_without_open_conversation(self):
        self.call(session='', turn_session='sess')
        payload = push.notification_payload(self.pending()[0])
        self.assertNotIn('session_id', payload['hermes'])
        expected = push.hashlib.sha256(f'{self.connection}:noriven'.encode()).hexdigest()
        self.assertEqual(payload['aps']['thread-id'], expected)
        self.assertNotIn('category', payload['aps'])                      # nothing to answer without a conversation
        self.assertEqual(payload['hermes']['kind'], 'tool')
        self.assertEqual(payload['aps']['alert'], {'title': 'Hermès', 'body': 'Nouveau message'})

    def test_session_present_with_open_conversation(self):
        self.call(session='sess-9')
        payload = push.notification_payload(self.pending()[0])
        self.assertEqual(payload['hermes']['session_id'], 'sess-9')
        expected = push.hashlib.sha256(f'{self.connection}:noriven:sess-9'.encode()).hexdigest()
        self.assertEqual(payload['aps']['thread-id'], expected)
        self.assertEqual(payload['aps']['category'], 'hermes.reply')       # a conversation target offers the reply action

    def test_turn_dedupe_marker(self):
        self.call(turn_session='s1', turn='T1')
        self.assertFalse(self.store.consume_tool_turn('s1', 'T2'))          # another turn: not suppressed
        self.assertTrue(self.store.consume_tool_turn('s1', 'T1'))
        self.assertFalse(self.store.consume_tool_turn('s1', 'T1'))          # consumed once
        self.assertFalse(self.store.consume_tool_turn('s2', 'T1'))          # other session
        self.call(turn_session='s1', turn='')                              # turn id unavailable: session window
        self.assertTrue(self.store.consume_tool_turn('s1', 'T9'))
        self.assertFalse(self.store.consume_tool_turn('s1', 'T10'))        # only the turn that is ending

    def test_stale_marker_expires(self):
        self.call(turn_session='s1', turn='')
        with self.store.connect() as db:
            db.execute('UPDATE tool_turns SET created=?', (time.time() - push.TURN_MARKER_AGE - 5,))
        self.assertFalse(self.store.consume_tool_turn('s1', 'T1'))


class Privacy(Fixture):
    SECRETS = ['SECRET-PREVIEW-TEXT', 'SECRET-CONVERSATION', 'SECRET-AGENT']

    def test_nothing_sensitive_reaches_logs(self):
        records = []
        class Capture(logging.Handler):
            def emit(self, record): records.append(record.getMessage() + ' ' + repr(record.args))
        handler, root = Capture(level=logging.DEBUG), logging.getLogger()
        old = root.level; root.addHandler(handler); root.setLevel(logging.DEBUG)
        try:
            content = {'agent': 'SECRET-AGENT', 'conversation': 'SECRET-CONVERSATION', 'preview': 'SECRET-PREVIEW-TEXT ' * 400}
            self.store.enqueue(str(uuid.uuid4()), 'noriven', 'sess', 'turn', content)
            self.store.enqueue_tool('noriven', '', 'sess', 'T', content, 'SECRET-AGENT')
            # absurd metadata makes sealing fail: the failure path must not log content either
            self.store.enqueue(str(uuid.uuid4()), 'p' * 4000, 'sess', 'turn', content)
            class Failing:
                async def deliver(self, row): raise OSError('boom')
            asyncio.run(push.deliver_pending(self.store, Failing()))
            self.store.set_presence(self.installation, self.connection, 'noriven', 'sess', 60)
            self.store.enqueue(str(uuid.uuid4()), 'noriven', 'sess', 'turn', content)
            class Ok:
                async def deliver(self, row): return 200, '', None
            asyncio.run(push.deliver_pending(self.store, Ok()))
        finally:
            root.removeHandler(handler); root.setLevel(old)
        joined = '\n'.join(records)
        for secret in self.SECRETS + [base64.b64encode(KEY).decode(), repr(KEY)]:
            self.assertNotIn(secret, joined)

    def test_payload_never_carries_clear_text_or_key(self):
        content = {'agent': 'SECRET-AGENT', 'conversation': 'SECRET-CONVERSATION', 'preview': 'SECRET-PREVIEW-TEXT'}
        self.store.enqueue(str(uuid.uuid4()), 'noriven', 'sess', 'turn', content)
        self.store.enqueue_tool('noriven', '', 'sess', 'T', content, 'Hermès')
        for row in self.pending():
            raw = json.dumps(push.notification_payload(row), ensure_ascii=False)
            for secret in self.SECRETS + [base64.b64encode(KEY).decode()]:
                self.assertNotIn(secret, raw)
        raw_db = self.store.path.read_bytes()
        for secret in self.SECRETS:
            self.assertNotIn(secret.encode(), raw_db)      # the outbox stores ciphertext only


class Text(unittest.TestCase):
    def test_rich_cards_never_reach_a_notification(self):
        text = 'Quatre maisons trouvées.\n\n```ui\n{"type":"carousel","items":[{"title":"A"}]}\n```\n\nBonne visite !'
        self.assertEqual(push.strip_markdown(text), 'Quatre maisons trouvées. Bonne visite !')
        self.assertEqual(push.strip_markdown('Code :\n```python\nprint(1)\n```'), 'Code : print(1)')

    def test_markdown_is_stripped(self):
        md = '# Titre\n\nVoici **du gras**, de l\'*italique*, `du code` et [un lien](http://x.y/z).\n\n- point un\n- point deux\n\n> citation\n\n```python\nprint(1)\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n![alt](http://i/p.png) snake_case_name ~~barré~~'
        out = push.strip_markdown(md)
        for noise in ('**', '`', '](', '# ', '```', '|--', '~~', '!['):
            self.assertNotIn(noise, out)
        for kept in ('Titre', 'du gras', 'italique', 'du code', 'un lien', 'point un', 'citation', 'print(1)', 'alt', 'snake_case_name', 'barré'):
            self.assertIn(kept, out)
        self.assertNotIn('\n', out); self.assertNotIn('  ', out)

    def test_preview_cut_cleanly(self):
        text = ('mot ' * 100).strip()
        preview = push.make_preview(text)
        self.assertLessEqual(len(preview), 140)
        self.assertTrue(preview.endswith('…'))
        self.assertFalse(preview[:-1].endswith(' '))
        self.assertEqual(push.make_preview('Court.'), 'Court.')
        self.assertLessEqual(len(push.make_preview('x' * 1000)), 140)

    def test_agent_display_name_order(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            self.assertEqual(push.agent_display_name(home, 'noriven'), 'noriven')
            (home / 'profile.yaml').write_text('display_name: Nori\n')
            self.assertEqual(push.agent_display_name(home, 'noriven'), 'Nori')
            (home / 'profile.yaml').write_text('display_name: Nori\nui_meta:\n  hermes-bots:\n    title: Noriven Assistant\n')
            self.assertEqual(push.agent_display_name(home, 'noriven'), 'Noriven Assistant')


class Api(unittest.TestCase):
    """The dashboard routes (FastAPI TestClient, no lifespan: the Apple worker is not started)."""
    def setUp(self):
        from fastapi import FastAPI
        from fastapi.testclient import TestClient
        self.temp = tempfile.TemporaryDirectory()
        os.environ['HERMES_IOS_PUSH_HOME'] = self.temp.name
        spec = importlib.util.spec_from_file_location('plugin_api_under_test', PLUGIN / 'dashboard/plugin_api.py')
        self.api = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.api)
        self.api.service.load_settings = lambda home=None: {'ready': True}
        app = FastAPI(); app.include_router(self.api.router, prefix='/api/plugins/hermes-ios-push')
        self.client = TestClient(app)
        self.base = '/api/plugins/hermes-ios-push'
        self.ids = {'installation_id': str(uuid.uuid4()), 'connection_id': str(uuid.uuid4())}
        self.device = {**self.ids, 'token': 'ab' * 32, 'environment': 'sandbox'}

    def tearDown(self):
        os.environ.pop('HERMES_IOS_PUSH_HOME', None); self.temp.cleanup()

    def store(self):
        return push.Store(Path(self.temp.name))

    def stored_key(self):
        with self.store().connect() as db:
            row = db.execute('SELECT key FROM device_keys').fetchone()
            return row[0] if row else None

    def test_register_with_key_without_key_and_rotation(self):
        b64 = base64.b64encode(KEY).decode()
        self.assertEqual(self.client.put(self.base + '/devices', json={**self.device, 'key': b64}).json(), {'registered': True})
        self.assertEqual(self.stored_key(), KEY)
        self.assertNotIn(b64, self.client.get(self.base + '/status').text)
        new = base64.b64encode(bytes(range(9, 41))).decode()
        self.client.put(self.base + '/devices', json={**self.device, 'key': new}).raise_for_status()
        self.assertEqual(self.stored_key(), bytes(range(9, 41)))
        self.client.put(self.base + '/devices', json=self.device).raise_for_status()      # no key: v0.1 behaviour
        self.assertIsNone(self.stored_key())

    def test_invalid_keys_are_rejected_without_echo(self):
        bad = ['!!!notbase64!!!', base64.b64encode(b'y' * 16).decode(), base64.b64encode(b'y' * 33).decode(), '', 7, ['x']]
        for value in bad:
            r = self.client.put(self.base + '/devices', json={**self.device, 'key': value})
            self.assertEqual(r.status_code, 422, value)
            for fragment in (value if isinstance(value, str) and value else 'zzz',):
                self.assertNotIn(fragment, r.text)
        # a validation error on ANOTHER field must not echo the key either
        secret = base64.b64encode(b'S' * 32).decode()
        r = self.client.put(self.base + '/devices', json={**self.device, 'token': 'zz', 'key': secret})
        self.assertEqual(r.status_code, 422); self.assertNotIn(secret, r.text)
        r = self.client.put(self.base + '/devices', json={'key': secret})
        self.assertEqual(r.status_code, 422); self.assertNotIn(secret, r.text)
        self.assertEqual(self.store().devices(), [])

    def test_not_ready_server_answers_503(self):
        self.api.service.load_settings = lambda home=None: None
        self.assertEqual(self.client.put(self.base + '/devices', json={**self.device, 'key': base64.b64encode(KEY).decode()}).status_code, 503)

    def test_revoke_deletes_key(self):
        self.client.put(self.base + '/devices', json={**self.device, 'key': base64.b64encode(KEY).decode()}).raise_for_status()
        self.client.delete(f"{self.base}/devices/{self.ids['installation_id']}/{self.ids['connection_id']}").raise_for_status()
        self.assertEqual(self.store().devices(), [])
        self.assertNotIn(KEY, (Path(self.temp.name) / 'notifications.sqlite').read_bytes())

    def presence(self, **extra):
        return {**self.ids, 'profile': 'noriven', 'session_id': '20261014_101500_ab12cd', **extra}

    def test_presence_put_delete_and_validation(self):
        self.assertEqual(self.client.put(self.base + '/presence', json=self.presence(ttl=60)).json(), {'ok': True})
        with self.store().connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM presence').fetchone()[0], 1)
        self.client.put(self.base + '/presence', json=self.presence(ttl=999)).raise_for_status()      # clamped
        self.client.put(self.base + '/presence', json=self.presence(ttl=1)).raise_for_status()
        with self.store().connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM presence').fetchone()[0], 1)
            self.assertAlmostEqual(db.execute('SELECT expires FROM presence').fetchone()[0] - time.time(), 5, delta=1)
        for bad in (self.presence(ttl='60'), self.presence(ttl=60.5), {**self.presence(ttl=60), 'installation_id': 'nope'},
                    self.presence(ttl=60, session_id='../etc'), self.presence(ttl=60, profile=''), self.presence(ttl=60, session_id='x' * 300)):
            self.assertEqual(self.client.put(self.base + '/presence', json=bad).status_code, 422, bad)
        self.assertEqual(self.client.request('DELETE', self.base + '/presence', json=self.presence()).json(), {'ok': True})
        with self.store().connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM presence').fetchone()[0], 0)
        self.client.put(self.base + '/presence', json=self.presence(ttl=60)).raise_for_status()
        query = self.presence(); 
        self.client.delete(self.base + '/presence', params=query).raise_for_status()      # query form
        with self.store().connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM presence').fetchone()[0], 0)
        self.assertEqual(self.client.delete(self.base + '/presence').status_code, 422)


# ---------------------------------------------------------------- v0.3: Live Activities + silent widget refresh

TOKEN_SECRET = 'cafe' * 16      # a Live Activity push token; must never reach a log or an error body
T0 = 1_760_000_000


def make_activity(store, installation, connection, **extra):
    fields = dict(profile='noriven', session='sess-1', activity='ACT-1', token=TOKEN_SECRET, environment='sandbox',
                  kind='reply', started_at=1_760_000_000.5, now=None)
    fields.update(extra)
    store.put_activity(installation, connection, fields['profile'], fields['session'], fields['activity'], fields['token'],
                       fields['environment'], fields['kind'], fields['started_at'], fields['now'])
    return fields


class LiveFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.store = push.Store(self.home)
        self.installation, self.connection = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
        self.store.register(self.installation, self.connection, 'ab' * 32, 'sandbox', KEY)

    def tearDown(self):
        self.temp.cleanup()

    def queue(self):
        with self.store.connect() as db:
            return [dict(r) for r in db.execute('SELECT * FROM live_queue ORDER BY created')]

    def act(self, **extra):
        return make_activity(self.store, self.installation, self.connection, **extra)

    def activity_row(self, activity='ACT-1'):
        return next(a for a in self.store.activities() if a['activity'] == activity)

    def state(self, detail='Exécute une commande'):
        return push.live_state('working', 'Nori', detail, 1_760_000_000)


class LiveStorage(LiveFixture):
    def test_table_is_created_and_other_tables_are_untouched(self):
        with self.store.connect() as db:
            tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertTrue({'activities', 'live_queue', 'meta'} <= tables)
        self.assertEqual([r[1] for r in sqlite3.connect(self.store.path).execute('PRAGMA table_info(devices)')],
                         ['installation', 'connection', 'token', 'environment', 'registered'])

    def test_v02_database_gains_the_tables_without_losing_anything(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            db = sqlite3.connect(home / 'notifications.sqlite')
            db.executescript("""
                CREATE TABLE devices (installation TEXT NOT NULL, connection TEXT NOT NULL, token TEXT NOT NULL,
                    environment TEXT NOT NULL, registered REAL NOT NULL, PRIMARY KEY (installation, connection));
                CREATE TABLE device_keys (installation TEXT NOT NULL, connection TEXT NOT NULL, key BLOB NOT NULL,
                    PRIMARY KEY (installation, connection));""")
            db.execute("INSERT INTO devices VALUES ('I1','C1',?,?,?)", ('ef' * 32, 'production', time.time()))
            db.execute("INSERT INTO device_keys VALUES ('I1','C1',?)", (KEY,))
            db.commit(); db.close()
            store = push.Store(home); push.Store(home)      # idempotent
            self.assertEqual([d['connection'] for d in store.devices()], ['C1'])
            self.assertEqual(store.activities(), [])
            make_activity(store, 'I1', 'C1')
            self.assertEqual(len(store.activities()), 1)

    def test_put_replaces_the_same_installation_and_activity(self):
        self.act()
        self.act(token='dd' * 32, environment='production', session='sess-2', started_at=T0 + 10)
        self.act(activity='ACT-2')
        rows = self.store.activities()
        self.assertEqual(len(rows), 2)
        row = self.activity_row()
        self.assertEqual((row['token'], row['environment'], row['session'], row['started_at']), ('dd' * 32, 'production', 'sess-2', T0 + 10))
        other = str(uuid.uuid4()).upper()
        make_activity(self.store, other, self.connection)          # same activity id, other installation: another row
        self.assertEqual(len(self.store.activities()), 3)

    def test_expiry_is_eight_hours_and_every_write_purges(self):
        t = time.time()
        expires = self.store.put_activity(self.installation, self.connection, 'noriven', 's', 'OLD', TOKEN_SECRET, 'sandbox', 'reply', T0, now=t - 8 * 3600 - 5)
        self.assertAlmostEqual(expires, t - 5, delta=1)
        self.act(activity='NEW')       # purges OLD on write
        with self.store.connect() as db:
            self.assertEqual([r[0] for r in db.execute('SELECT activity FROM activities')], ['NEW'])
        self.assertAlmostEqual(self.activity_row('NEW')['expires'] - time.time(), 8 * 3600, delta=5)

    def test_expired_activity_is_invisible_unqueueable_and_its_queue_is_purged(self):
        t = time.time()
        self.act(now=t - 8 * 3600 + 2)             # expires in 2 s
        activity = self.activity_row()
        self.assertTrue(self.store.enqueue_live(activity, 'update', self.state(), now=t))
        self.assertEqual(self.store.activities_for('noriven', 'sess-1', now=t + 10), [])
        self.assertFalse(self.store.enqueue_live(activity, 'update', self.state(), now=t + 10))
        self.assertEqual(self.store.pending_live(now=t + 10), [])        # purged by the read
        self.assertEqual(self.queue(), [])
        self.assertEqual(self.store.activities(now=t + 10), [])

    def test_delete_activity_and_revoke_device_forget_everything(self):
        self.act(); self.act(activity='ACT-2')
        self.store.enqueue_live(self.activity_row(), 'update', self.state())
        self.store.delete_activity(self.installation, 'ACT-1')
        self.assertEqual([a['activity'] for a in self.store.activities()], ['ACT-2'])
        self.assertEqual(self.queue(), [])
        self.store.enqueue_live(self.activity_row('ACT-2'), 'end', self.state())
        self.store.claim_widget_pushes(3600)
        self.store.revoke(self.installation, self.connection)
        with self.store.connect() as db:
            for table in ('activities', 'live_queue', 'meta'):
                self.assertEqual(db.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0], 0, table)
        self.assertNotIn(TOKEN_SECRET.encode(), self.store.path.read_bytes())      # secure_delete

    def test_matching_requires_profile_session_and_reply_kind(self):
        self.act(activity='A-ok')
        self.act(activity='A-profile', profile='autre')
        self.act(activity='A-session', session='sess-2')
        self.act(activity='A-call', kind='call')
        found = {a['activity'] for a in self.store.activities_for('noriven', 'sess-1')}
        self.assertEqual(found, {'A-ok'})
        self.assertEqual({a['activity'] for a in self.store.activities_for('noriven', 'sess-1', 'call')}, {'A-call'})


class LiveCoalescing(LiveFixture):
    def test_updates_coalesce_and_the_last_one_wins(self):
        self.act()
        activity = self.activity_row()
        for detail in ('Exécute une commande', 'Cherche sur le web', 'Lit des fichiers'):
            self.assertTrue(self.store.enqueue_live(activity, 'update', self.state(detail)))
        rows = self.queue()
        self.assertEqual(len(rows), 1)
        self.assertEqual(json.loads(rows[0]['state'])['detail'], 'Lit des fichiers')

    def test_at_most_one_update_every_five_seconds(self):
        self.act()
        activity = self.activity_row()
        t = time.time()
        self.store.enqueue_live(activity, 'update', self.state('A'), now=t)
        [row] = self.store.pending_live(now=t)
        row['timestamp'] = int(t)
        self.store.resolve_live(row, 200, now=t)                  # first update left at t
        self.assertEqual(self.queue(), [])
        for i, detail in enumerate(('B', 'C', 'D')):
            self.store.enqueue_live(activity, 'update', self.state(detail), now=t + 0.5 + i)
        self.assertEqual(self.store.pending_live(now=t + 4.9), [])              # still inside the 5 s window
        [row] = self.store.pending_live(now=t + 5.0)
        self.assertEqual(json.loads(row['state'])['detail'], 'D')           # the last one
        row['timestamp'] = int(t) + 5
        self.store.resolve_live(row, 200, now=t + 5.0)
        self.store.enqueue_live(activity, 'update', self.state('E'), now=t + 6)
        self.assertEqual(self.store.pending_live(now=t + 9.9), [])
        self.assertEqual(len(self.store.pending_live(now=t + 10.0)), 1)

    def test_end_is_never_delayed_and_replaces_pending_updates(self):
        self.act()
        activity = self.activity_row()
        t = time.time()
        self.store.enqueue_live(activity, 'update', self.state('A'), now=t)
        [row] = self.store.pending_live(now=t); row['timestamp'] = int(t)
        self.store.resolve_live(row, 200, now=t)
        self.store.enqueue_live(activity, 'update', self.state('B'), now=t + 1)
        done = push.live_state('done', 'Nori', push.LIVE_DONE_DETAIL, T0)
        self.assertTrue(self.store.enqueue_live(activity, 'end', done, now=t + 1.5))
        rows = self.store.pending_live(now=t + 1.6)                 # 1.6 s after the last update: the end leaves at once
        self.assertEqual([r['event'] for r in rows], ['end'])
        self.assertFalse(self.store.enqueue_live(activity, 'update', self.state('C'), now=t + 1.7))     # nothing after an end
        self.assertEqual([r['event'] for r in self.queue()], ['end'])

    def test_end_survives_the_update_window_even_when_updates_are_in_flight(self):
        self.act()
        activity = self.activity_row()
        t = time.time()
        self.store.enqueue_live(activity, 'update', self.state('A'), now=t)
        [update] = self.store.pending_live(now=t)
        self.store.enqueue_live(activity, 'update', self.state('NEWER'), now=t + 0.1)        # replaced while "in flight"
        update['timestamp'] = int(t)
        self.store.resolve_live(update, 200, now=t + 0.2)
        self.assertEqual(json.loads(self.queue()[0]['state'])['detail'], 'NEWER')           # not deleted by the old answer

    def test_timestamps_are_strictly_increasing_per_activity(self):
        self.act()
        activity = self.activity_row()
        class Recorder:
            def __init__(self): self.rows = []
            async def deliver_live(self, row): self.rows.append(dict(row)); return 200, '', None
        recorder = Recorder()
        self.store.enqueue_live(activity, 'update', self.state('A'))
        asyncio.run(push.deliver_live(self.store, recorder))
        with self.store.connect() as db:
            db.execute('UPDATE activities SET last_update=0')            # skip the 5 s wait
        self.store.enqueue_live(activity, 'end', self.state('Z'))
        asyncio.run(push.deliver_live(self.store, recorder))
        self.assertEqual(len(recorder.rows), 2)
        self.assertGreater(recorder.rows[1]['timestamp'], recorder.rows[0]['timestamp'])


class LivePayloads(LiveFixture):
    PRIVATE = ['SECRET-TOOL-ARGUMENT', 'SECRET-RESULT', 'SECRET-USER-TEXT']

    def row(self, event, **extra):
        state = self.state() if event == 'update' else push.live_state('done', 'Nori', push.LIVE_DONE_DETAIL, 1_760_000_000)
        return {'event': event, 'state': json.dumps(state), 'timestamp': T0 + 3, 'token': TOKEN_SECRET,
                'environment': 'sandbox', **extra}

    def test_update_payload_is_exact(self):
        payload = push.live_payload(self.row('update'))
        self.assertEqual(payload, {'aps': {'timestamp': T0 + 3, 'event': 'update', 'content-state': {
            'phase': 'working', 'title': 'Nori', 'detail': 'Exécute une commande', 'muted': False, 'startedAt': 1_760_000_000}}})
        self.assertNotIn('dismissal-date', payload['aps'])
        self.assertEqual(list(payload['aps']['content-state']), ['phase', 'title', 'detail', 'muted', 'startedAt'])
        self.assertIs(type(payload['aps']['timestamp']), int)

    def test_end_payload_is_exact_with_dismissal_fifteen_minutes_later(self):
        payload = push.live_payload(self.row('end'))
        self.assertEqual(payload, {'aps': {'timestamp': T0 + 3, 'event': 'end', 'dismissal-date': T0 + 3 + 900, 'content-state': {
            'phase': 'done', 'title': 'Nori', 'detail': 'Réponse prête', 'muted': False, 'startedAt': 1_760_000_000}}})
        self.assertIs(type(payload['aps']['dismissal-date']), int)

    def test_started_at_stays_a_json_number(self):
        for value, expected in ((1_760_000_000.5, 1_760_000_000.5), (1_760_000_000.0, 1_760_000_000), (1_760_000_000, 1_760_000_000)):
            state = push.live_state('working', 'Nori', 'x', value)
            self.assertEqual(state['startedAt'], expected)
            self.assertIn(type(state['startedAt']), (int, float))
            self.assertIs(state['muted'], False)

    def test_title_is_bounded(self):
        self.assertLessEqual(len(push.live_state('working', 'A' * 500, 'x', 1)['title']), 60)

    def test_labels_are_a_fixed_french_table(self):
        cases = {'terminal': 'Exécute une commande', 'execute_code': 'Exécute une commande',
                 'web_search': 'Cherche sur le web', 'web_extract': 'Cherche sur le web', 'x_search': 'Cherche sur le web',
                 'read_file': 'Lit des fichiers', 'write_file': 'Lit des fichiers', 'search_files': 'Lit des fichiers', 'patch': 'Lit des fichiers',
                 'browser_cdp': 'Navigue sur le web', 'browser_exec': 'Navigue sur le web',
                 'memory': 'Consulte sa mémoire', 'session_search': 'Consulte sa mémoire',
                 'google_perso_list': 'Regarde tes courriels', 'connectors__gmail__search': 'Regarde tes courriels',
                 'google_perso_calendar': 'Regarde ton agenda', 'agenda_lire': 'Regarde ton agenda',
                 'meteo': 'Consulte la météo', 'get_weather': 'Consulte la météo',
                 'image_generate': 'Utilise un outil', '': 'Utilise un outil', None: 'Utilise un outil', 42: 'Utilise un outil'}
        for name, label in cases.items():
            self.assertEqual(push.tool_label(name), label, name)
        self.assertNotIn('SECRET', push.tool_label('SECRET-TOOL-NAME'))      # the name itself never travels

    def test_live_activity_wire_headers_body_and_hosts(self):
        key = ec.generate_private_key(ec.SECP256R1())
        path = self.home / 'fixture.p8'
        path.write_bytes(key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption()))
        config = {'key_path': str(path), 'key_id': 'TESTKEY', 'team_id': 'TESTTEAM'}
        seen = []
        def handle(request):
            seen.append(request)
            return httpx.Response(200)
        async def run():
            async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
                sender = push.APNs(config, client)
                self.assertEqual((await sender.deliver_live(self.row('update')))[0], 200)
                self.assertEqual((await sender.deliver_live(self.row('end', environment='production')))[0], 200)
        before = int(time.time())
        asyncio.run(run())
        update, end = seen
        self.assertEqual((update.url.host, end.url.host), ('api.sandbox.push.apple.com', 'api.push.apple.com'))
        self.assertEqual(update.url.path, f'/3/device/{TOKEN_SECRET}')
        for request, priority, event in ((update, '5', 'update'), (end, '10', 'end')):
            self.assertEqual(request.headers['apns-push-type'], 'liveactivity')
            self.assertEqual(request.headers['apns-topic'], 'org.hermesios.HermesIOS.push-type.liveactivity')
            self.assertEqual(request.headers['apns-priority'], priority)
            self.assertGreater(int(request.headers['apns-expiration']), before)
            self.assertLessEqual(int(request.headers['apns-expiration']), before + 3700)
            uuid.UUID(request.headers['apns-id'])
            self.assertEqual(jwt.decode(request.headers['authorization'].removeprefix('bearer '), key.public_key(), algorithms=['ES256'])['iss'], 'TESTTEAM')
            self.assertEqual(json.loads(request.content)['aps']['event'], event)
        self.assertEqual(json.loads(end.content), push.live_payload(self.row('end')))

    def test_alert_delivery_is_unchanged(self):
        key = ec.generate_private_key(ec.SECP256R1())
        path = self.home / 'fixture.p8'
        path.write_bytes(key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption()))
        seen = []
        async def run():
            async with httpx.AsyncClient(transport=httpx.MockTransport(lambda r: (seen.append(r), httpx.Response(200))[1])) as client:
                self.store.enqueue(str(uuid.uuid4()), 'noriven', 'sess-1', 'turn', {'agent': 'A', 'conversation': 'C', 'preview': 'P'})
                await push.APNs({'key_path': str(path), 'key_id': 'K', 'team_id': 'T'}, client).deliver(self.store.pending()[0])
        asyncio.run(run())
        self.assertEqual((seen[0].headers['apns-push-type'], seen[0].headers['apns-topic'], seen[0].headers['apns-priority']), ('alert', push.TOPIC, '10'))

    def test_nothing_private_in_state_payload_or_database(self):
        raw = json.dumps(push.live_payload(self.row('update')))
        for secret in self.PRIVATE:
            self.assertNotIn(secret, raw)
        self.assertEqual(set(json.loads(raw)['aps']['content-state']), {'phase', 'title', 'detail', 'muted', 'startedAt'})


class LiveResolution(LiveFixture):
    def sent(self, event='update'):
        self.act()
        activity = self.activity_row()
        self.store.enqueue_live(activity, event, self.state())
        [row] = self.store.pending_live()
        row['timestamp'] = int(time.time())
        return row

    def test_success_of_end_forgets_the_activity(self):
        row = self.sent('end')
        self.store.resolve_live(row, 200)
        self.assertEqual((self.store.activities(), self.queue()), ([], []))

    def test_success_of_update_keeps_the_activity_and_records_the_send(self):
        row = self.sent()
        self.store.resolve_live(row, 200)
        activity = self.activity_row()
        self.assertGreater(activity['last_update'], 0)
        self.assertEqual(activity['last_ts'], row['timestamp'])
        self.assertEqual(self.queue(), [])

    def test_410_badtoken_and_unregistered_remove_the_activity(self):
        for status, reason in ((410, 'Unregistered'), (400, 'BadDeviceToken'), (410, ''), (400, 'DeviceTokenNotForTopic')):
            row = self.sent('end' if status == 410 else 'update')
            self.store.resolve_live(row, status, reason)
            self.assertEqual((self.store.activities(), self.queue()), ([], []), (status, reason))
            self.assertEqual(len(self.store.devices()), 1)          # the alert device is a different token

    def test_a_late_410_for_an_old_token_does_not_remove_the_refreshed_activity(self):
        row = self.sent()
        self.act(token='dd' * 32)
        self.store.resolve_live(row, 410, 'Unregistered')
        self.assertEqual(self.activity_row()['token'], 'dd' * 32)

    def test_other_errors_retry_once_then_stop(self):
        for status, reason in ((0, 'TransportError'), (503, 'ServiceUnavailable'), (429, 'TooManyRequests'), (403, 'ExpiredProviderToken')):
            row = self.sent('end')
            self.store.resolve_live(row, status, reason)
            self.assertEqual(self.store.pending_live(), [], 'waits before the retry')
            self.assertEqual(len(self.queue()), 1)
            later = time.time() + push.LIVE_RETRY_DELAY + 1
            [again] = self.store.pending_live(now=later)
            self.assertEqual(again['attempts'], 1)
            self.store.resolve_live(again, status, reason, now=later)
            self.assertEqual(self.queue(), [], 'no loop: dropped after the single retry')
            self.store.delete_activity(self.installation, 'ACT-1')

    def test_client_errors_are_not_retried(self):
        row = self.sent('end')
        self.store.resolve_live(row, 400, 'BadPayload')
        self.assertEqual(self.queue(), [])
        self.assertEqual(len(self.store.activities()), 1)

    def test_deliver_live_pass_maps_transport_errors_and_410(self):
        self.act()
        activity = self.activity_row()
        class Sender:
            def __init__(self, outcome): self.outcome = outcome; self.calls = 0
            async def deliver_live(self, row):
                self.calls += 1
                if isinstance(self.outcome, Exception): raise self.outcome
                return self.outcome
        self.store.enqueue_live(activity, 'end', self.state())
        sender = Sender(httpx.ConnectError('boom'))
        self.assertEqual(asyncio.run(push.deliver_live(self.store, sender)), {'sent': 0, 'other': 1})
        self.assertEqual(self.queue()[0]['attempts'], 1)
        sender = Sender((410, 'Unregistered', 1))
        with self.store.connect() as db:
            db.execute('UPDATE live_queue SET next_attempt=0')
        asyncio.run(push.deliver_live(self.store, sender))
        self.assertEqual((self.store.activities(), self.queue()), ([], []))


class LiveHooks(LiveFixture):
    SECRET_ARGS = {'command': 'SECRET-TOOL-ARGUMENT', 'text': 'SECRET-USER-TEXT'}

    def setUp(self):
        super().setUp()
        import hermes_constants
        self.profile_home = self.home / 'profiles' / 'noriven'; self.profile_home.mkdir(parents=True)
        (self.profile_home / 'profile.yaml').write_text('display_name: Nori\nui_meta:\n  hermes-bots:\n    title: Noriven Assistant\n')
        self.profile = 'noriven'
        for patcher in (mock.patch.dict(os.environ, {'HERMES_IOS_PUSH_HOME': str(self.home)}),
                        mock.patch.object(hermes_constants, 'get_hermes_home', lambda: self.profile_home),
                        mock.patch.object(hermes_constants, 'profile_name_for_home', lambda home: self.profile)):
            patcher.start(); self.addCleanup(patcher.stop)
        self.addCleanup(push.flush_live)

    def pre(self, tool='terminal', session='sess-1', **extra):
        result = push.on_pre_tool_call(tool_name=tool, args=self.SECRET_ARGS, task_id='t', session_id=session, tool_call_id='c',
                                       turn_id='T1', api_request_id='r', middleware_trace=[], **extra)
        self.assertTrue(push.flush_live())
        return result

    def states(self, event=None):
        return [(r['event'], json.loads(r['state'])) for r in self.queue() if event in (None, r['event'])]

    def test_pre_tool_call_queues_a_generic_working_update_for_this_profile_and_session(self):
        self.act()
        self.act(activity='OTHER-SESSION', session='sess-2')
        self.act(activity='OTHER-PROFILE', profile='autre')
        self.act(activity='CALL', kind='call')
        self.assertIsNone(self.pre('terminal'))
        rows = self.queue()
        self.assertEqual([r['activity'] for r in rows], ['ACT-1'])
        self.assertEqual(json.loads(rows[0]['state']), {'phase': 'working', 'title': 'Noriven Assistant', 'detail': 'Exécute une commande',
                                                       'muted': False, 'startedAt': 1_760_000_000.5})
        self.assertEqual(rows[0]['event'], 'update')

    def test_every_registered_activity_of_the_session_is_updated(self):
        other_installation = str(uuid.uuid4()).upper()
        self.act()
        make_activity(self.store, other_installation, self.connection, activity='ACT-2', started_at=T0 + 77)
        self.pre('web_search')
        by_activity = {r['activity']: json.loads(r['state']) for r in self.queue()}
        self.assertEqual(by_activity['ACT-1']['startedAt'], 1_760_000_000.5)
        self.assertEqual(by_activity['ACT-2']['startedAt'], T0 + 77)
        self.assertEqual({s['detail'] for s in by_activity.values()}, {'Cherche sur le web'})

    def test_successive_tools_coalesce_to_the_last_label(self):
        self.act()
        for tool in ('terminal', 'web_search', 'read_file'):
            self.pre(tool)
        self.assertEqual([s['detail'] for _, s in self.states()], ['Lit des fichiers'])

    def test_no_activity_means_no_row_and_no_error(self):
        self.pre('terminal')
        self.assertEqual(self.queue(), [])

    def test_post_llm_call_ends_the_activity_and_keeps_the_turn_notification(self):
        self.act(); self.act(activity='CALL', kind='call'); self.act(activity='OTHER', session='sess-9')
        self.pre('terminal')
        calls = []
        with mock.patch.object(push, 'record_completion', lambda **kw: calls.append(kw)):
            result = push.on_post_llm_call(session_id='sess-1', task_id='t', turn_id='T1', user_message='SECRET-USER-TEXT',
                                           assistant_response='SECRET-RESULT', conversation_history=[], model='m', platform='cli')
            self.assertTrue(push.flush_live())
        self.assertIsNone(result)
        self.assertEqual(len(calls), 1)
        self.assertEqual((calls[0]['session_id'], calls[0]['turn_id'], calls[0]['platform'], calls[0]['assistant_response']),
                         ('sess-1', 'T1', 'cli', 'SECRET-RESULT'))
        rows = self.queue()
        self.assertEqual([(r['activity'], r['event']) for r in rows], [('ACT-1', 'end')])      # the pending update is replaced
        self.assertEqual(json.loads(rows[0]['state']), {'phase': 'done', 'title': 'Noriven Assistant', 'detail': 'Réponse prête',
                                                       'muted': False, 'startedAt': 1_760_000_000.5})

    def test_post_llm_call_really_enqueues_the_turn_notification_too(self):
        # the unchanged v0.2 path: session + response -> an outbox row (the hook needs a stored session)
        import hermes_state
        class Sessions:
            def __init__(self, *a, **k): pass
            def get_session(self, sid): return {'source': 'tui', 'title': 'Rapport'}
            def close(self): pass
        self.act()
        with mock.patch.object(hermes_state, 'SessionDB', Sessions):
            push.on_post_llm_call(session_id='sess-1', turn_id='T1', assistant_response='Bonjour', platform='cli', user_message='')
            self.assertTrue(push.flush_live())
        self.assertEqual(len(self.store.pending()), 1)
        self.assertEqual([r['event'] for r in self.queue()], ['end'])

    def test_nothing_after_end_and_calls_are_left_to_the_app(self):
        self.act(activity='CALL', kind='call')
        self.pre('terminal')
        with mock.patch.object(push, 'record_completion', lambda **kw: None):
            push.on_post_llm_call(session_id='sess-1', turn_id='T1')
            self.assertTrue(push.flush_live())
        self.assertEqual(self.queue(), [])

    def test_hooks_return_immediately_even_when_the_store_is_slow(self):
        self.act()
        original = push._live_job
        def slow(*args):
            time.sleep(0.6)
            return original(*args)
        with mock.patch.object(push, '_live_job', slow):
            t = time.perf_counter()
            self.assertIsNone(push.on_pre_tool_call(tool_name='terminal', session_id='sess-1', args={}))
            with mock.patch.object(push, 'record_completion', lambda **kw: None):
                self.assertIsNone(push.on_post_llm_call(session_id='sess-1', turn_id='T'))
            elapsed = time.perf_counter() - t
            self.assertLess(elapsed, 0.3)
            self.assertEqual(self.queue(), [])         # the work is still pending in the background
            self.assertTrue(push.flush_live(10))
        self.assertEqual([r['event'] for r in self.queue()], ['end'])

    def test_hooks_never_raise(self):
        import hermes_constants
        self.act()
        with mock.patch.object(hermes_constants, 'get_hermes_home', side_effect=RuntimeError('boom')):
            self.assertIsNone(self.pre('terminal'))
        with mock.patch.object(hermes_constants, 'profile_name_for_home', lambda home: None):
            self.assertIsNone(self.pre('terminal'))
        for bad in (None, 7, '', ['x']):
            self.assertIsNone(push.on_pre_tool_call(tool_name=None, session_id=bad))
            self.assertIsNone(push.on_pre_tool_call(tool_name=bad, session_id='sess-1'))
        self.assertIsNone(push.on_pre_tool_call())
        file = self.home / 'not-a-directory'; file.write_text('x')
        with mock.patch.dict(os.environ, {'HERMES_IOS_PUSH_HOME': str(file / 'inside')}):      # the store cannot even open
            self.assertIsNone(self.pre('terminal'))
            with mock.patch.object(push, 'record_completion', side_effect=ValueError('SECRET-RESULT')):
                self.assertIsNone(push.on_post_llm_call(session_id='sess-1', turn_id='T'))
                self.assertTrue(push.flush_live())
        with mock.patch.object(push, 'ThreadPoolExecutor', side_effect=RuntimeError('boom')), \
             mock.patch.object(push, '_live_pool', None):
            self.assertIsNone(push.on_pre_tool_call(tool_name='terminal', session_id='sess-1'))
        self.assertEqual(push._live_waiting, 0)

    def test_the_hook_queue_is_bounded(self):
        import threading
        gate = threading.Event()
        original = push._live_job
        def blocked(*args):
            gate.wait(5)
            return original(*args)
        try:
            with mock.patch.object(push, '_live_job', blocked):
                for _ in range(push.LIVE_QUEUE_LIMIT + 50):
                    push.on_pre_tool_call(tool_name='terminal', session_id='sess-1')
                self.assertLessEqual(push._live_waiting, push.LIVE_QUEUE_LIMIT)
        finally:
            gate.set()
        self.assertTrue(push.flush_live(10))
        self.assertEqual(push._live_waiting, 0)

    def test_nothing_private_reaches_the_database_the_payload_or_the_logs(self):
        self.act()
        records = []
        class Capture(logging.Handler):
            def emit(self, record): records.append(record.getMessage() + ' ' + repr(record.args))
        handler, root = Capture(level=logging.DEBUG), logging.getLogger()
        old = root.level; root.addHandler(handler); root.setLevel(logging.DEBUG)
        try:
            self.pre('SECRET-TOOL-ARGUMENT')
            with mock.patch.object(push, 'record_completion', side_effect=ValueError('SECRET-RESULT')):
                push.on_post_llm_call(session_id='sess-1', turn_id='T', assistant_response='SECRET-RESULT', user_message='SECRET-USER-TEXT')
                push.flush_live()
            file = self.home / 'not-a-directory'; file.write_text('x')
            with mock.patch.dict(os.environ, {'HERMES_IOS_PUSH_HOME': str(file / 'inside')}):
                self.pre('terminal')
        finally:
            root.removeHandler(handler); root.setLevel(old)
        joined = '\n'.join(records)
        for secret in LivePayloads.PRIVATE + ['SECRET-TOOL-NAME', TOKEN_SECRET]:
            self.assertNotIn(secret, joined)
        for secret in LivePayloads.PRIVATE + ['SECRET-TOOL-NAME']:
            self.assertNotIn(secret.encode(), self.store.path.read_bytes())      # arguments, results and tool names are never stored
        for row in self.queue():
            payload = push.live_payload({**row, 'timestamp': T0})
            for secret in LivePayloads.PRIVATE:
                self.assertNotIn(secret, json.dumps(payload))


class WidgetsPush(LiveFixture):
    class Recorder:
        def __init__(self, outcome=(200, '', None)): self.devices, self.outcome = [], outcome
        async def deliver_background(self, device):
            self.devices.append(dict(device)); return self.outcome

    def run_pass(self, minutes=60, recorder=None, store=None):
        recorder = recorder or self.Recorder()
        counts = asyncio.run(push.deliver_widgets(store or self.store, recorder, minutes))
        return counts, recorder.devices

    def age(self, seconds):
        with self.store.connect() as db:
            db.execute('UPDATE meta SET value=?', (repr(time.time() - seconds),))

    def test_payload_is_exact_and_silent(self):
        self.assertEqual(push.widgets_payload(), {'aps': {'content-available': 1}, 'hermes': {'version': 1, 'kind': 'widgets'}})

    def test_no_burst_at_first_sight_then_one_push_per_interval(self):
        counts, devices = self.run_pass()
        self.assertEqual((counts['sent'], devices), (0, []))         # stamped, not pushed
        self.assertEqual(self.run_pass()[1], [])                      # still inside the interval
        self.age(59 * 60); self.assertEqual(self.run_pass()[1], [])
        self.age(60 * 60 + 1)
        counts, devices = self.run_pass()
        self.assertEqual((counts['sent'], len(devices)), (1, 1))
        self.assertEqual((devices[0]['installation'], devices[0]['connection'], devices[0]['token']), (self.installation, self.connection, 'ab' * 32))
        self.assertEqual(self.run_pass()[1], [])                      # stamped when claimed: no repeat

    def test_cadence_survives_a_restart(self):
        self.run_pass(); self.age(61 * 60)
        self.assertEqual(len(self.run_pass()[1]), 1)
        restarted = push.Store(self.home)                              # new process, same database
        self.assertEqual(self.run_pass(store=restarted)[1], [])
        with restarted.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM meta WHERE key LIKE 'widgets:%'").fetchone()[0], 1)
        self.age(61 * 60)
        self.assertEqual(len(self.run_pass(store=push.Store(self.home))[1]), 1)

    def test_interval_follows_the_setting_and_zero_disables(self):
        self.run_pass(15); self.age(16 * 60)
        self.assertEqual(self.run_pass(0)[1], [])                      # disabled: nothing, and the stamp is untouched
        self.assertEqual(self.run_pass(-5)[1], [])
        self.assertEqual(len(self.run_pass(15)[1]), 1)

    def test_each_device_has_its_own_clock_and_new_devices_do_not_burst(self):
        self.run_pass(); self.age(2 * 3600)
        newcomer = str(uuid.uuid4()).upper()
        self.store.register(self.installation, newcomer, 'cd' * 32, 'production')
        devices = self.run_pass()[1]
        self.assertEqual([d['connection'] for d in devices], [self.connection])       # the newcomer is only stamped

    def test_a_clock_that_went_backwards_does_not_freeze_the_cadence(self):
        self.run_pass()
        with self.store.connect() as db:
            db.execute('UPDATE meta SET value=?', (repr(time.time() + 10 * 3600),))
        self.assertEqual(self.run_pass()[1], [])
        self.age(61 * 60)
        self.assertEqual(len(self.run_pass()[1]), 1)

    def test_invalid_token_removes_the_device_as_for_alerts(self):
        self.run_pass(); self.age(2 * 3600)
        counts, _ = self.run_pass(recorder=self.Recorder((410, 'Unregistered', int((time.time() + 5) * 1000))))
        self.assertEqual(counts['other'], 1)
        self.assertEqual(self.store.devices(), [])
        self.assertNotIn(KEY, self.store.path.read_bytes())
        self.run_pass()         # forgets the stamp of the vanished device
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM meta').fetchone()[0], 0)

    def test_a_delayed_410_does_not_remove_a_refreshed_token(self):
        self.run_pass(); self.age(2 * 3600)
        recorder = self.Recorder((410, 'Unregistered', int((time.time() - 30) * 1000)))
        self.store.register(self.installation, self.connection, 'cd' * 32, 'sandbox', KEY)
        self.run_pass(recorder=recorder)
        self.assertEqual(len(self.store.devices()), 1)

    def test_transient_failure_is_not_retried_before_the_next_interval(self):
        self.run_pass(); self.age(2 * 3600)
        self.run_pass(recorder=self.Recorder((503, 'ServiceUnavailable', None)))
        self.assertEqual(self.run_pass()[1], [])
        self.assertEqual(len(self.store.devices()), 1)

    def test_transport_error_is_absorbed(self):
        class Broken:
            async def deliver_background(self, device): raise httpx.ConnectError('boom')
        self.run_pass(); self.age(2 * 3600)
        self.assertEqual(asyncio.run(push.deliver_widgets(self.store, Broken(), 60)), {'sent': 0, 'other': 1})

    def test_setting_parsing(self):
        parse = push.widgets_refresh_minutes
        self.assertEqual(parse({}), 60)
        self.assertEqual(parse(None), 60)
        self.assertEqual(parse({'widgets_refresh_minutes': 30}), 30)
        self.assertEqual(parse({'widgets_refresh_minutes': 0}), 0)
        self.assertEqual(parse({'widgets_refresh_minutes': 90.9}), 90)
        self.assertEqual(parse({'widgets_refresh_minutes': -3}), 0)
        self.assertEqual(parse({'widgets_refresh_minutes': 10 ** 9}), push.WIDGETS_MAX_MINUTES)
        for bad in ('30', True, None, [], float('nan'), float('inf')):
            self.assertEqual(parse({'widgets_refresh_minutes': bad}), 60, bad)

    def test_setting_is_read_from_apns_json_and_load_settings_keeps_it(self):
        key = ec.generate_private_key(ec.SECP256R1())
        path = self.home / 'fixture.p8'
        path.write_bytes(key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption()))
        (self.home / 'apns.json').write_text(json.dumps({'key_path': str(path), 'key_id': 'K', 'team_id': 'T', 'widgets_refresh_minutes': 15}))
        self.assertEqual(push.widgets_refresh_minutes(push.load_settings(self.home)), 15)

    def test_background_push_wire(self):
        key = ec.generate_private_key(ec.SECP256R1())
        path = self.home / 'fixture.p8'
        path.write_bytes(key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption()))
        seen = []
        def handle(request):
            seen.append(request); return httpx.Response(200)
        async def run():
            async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
                sender = push.APNs({'key_path': str(path), 'key_id': 'K', 'team_id': 'T'}, client)
                await sender.deliver_background({'token': 'ab' * 32, 'environment': 'sandbox'})
                await sender.deliver_background({'token': 'cd' * 32, 'environment': 'production'})
        asyncio.run(run())
        first, second = seen
        self.assertEqual((first.url.host, second.url.host), ('api.sandbox.push.apple.com', 'api.push.apple.com'))
        self.assertEqual(first.url.path, '/3/device/' + 'ab' * 32)
        self.assertEqual(first.headers['apns-push-type'], 'background')
        self.assertEqual(first.headers['apns-priority'], '5')
        self.assertEqual(first.headers['apns-topic'], push.TOPIC)
        self.assertEqual(json.loads(first.content), {'aps': {'content-available': 1}, 'hermes': {'version': 1, 'kind': 'widgets'}})
        self.assertNotIn(b'alert', first.content); self.assertNotIn(b'sound', first.content)


class ApiActivities(unittest.TestCase):
    def setUp(self):
        from fastapi import FastAPI
        from fastapi.testclient import TestClient
        self.temp = tempfile.TemporaryDirectory()
        os.environ['HERMES_IOS_PUSH_HOME'] = self.temp.name
        spec = importlib.util.spec_from_file_location('plugin_api_under_test_activities', PLUGIN / 'dashboard/plugin_api.py')
        self.api = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.api)
        self.api.service.load_settings = lambda home=None: {'ready': True}
        app = FastAPI(); app.include_router(self.api.router, prefix='/api/plugins/hermes-ios-push')
        self.client = TestClient(app)
        self.url = '/api/plugins/hermes-ios-push/activities'
        self.body = {'installation_id': str(uuid.uuid4()), 'connection_id': str(uuid.uuid4()), 'profile': 'noriven',
                     'session_id': '20261020_101500_ab12cd', 'activity_id': 'B2C3D4E5-0000-4000-8000-000000000001', 'token': TOKEN_SECRET,
                     'environment': 'sandbox', 'kind': 'reply', 'started_at': 1_760_000_000.25}

    def tearDown(self):
        os.environ.pop('HERMES_IOS_PUSH_HOME', None); self.temp.cleanup()

    def store(self):
        return push.Store(Path(self.temp.name))

    def put(self, **extra):
        return self.client.put(self.url, json={**self.body, **extra})

    def test_put_stores_the_activity_normalised(self):
        response = self.put(token=TOKEN_SECRET.upper())
        self.assertEqual(response.status_code, 200, response.text)
        self.assertTrue(response.json()['registered'])
        self.assertAlmostEqual(response.json()['expires_at'] - time.time(), 8 * 3600, delta=5)
        [row] = self.store().activities()
        self.assertEqual((row['installation'], row['connection'], row['profile'], row['session'], row['activity'], row['token'],
                          row['environment'], row['kind'], row['started_at']),
                         (self.body['installation_id'].upper(), self.body['connection_id'].upper(), 'noriven', '20261020_101500_ab12cd',
                          self.body['activity_id'], TOKEN_SECRET, 'sandbox', 'reply', 1_760_000_000.25))

    def test_put_again_replaces_and_integer_started_at_is_accepted(self):
        self.put().raise_for_status()
        self.put(token='dd' * 32, kind='call', started_at=1_760_000_100).raise_for_status()
        [row] = self.store().activities()
        self.assertEqual((row['token'], row['kind'], row['started_at']), ('dd' * 32, 'call', 1_760_000_100))

    def test_delete_removes_and_is_idempotent(self):
        self.put().raise_for_status()
        url = f"{self.url}/{self.body['installation_id']}/{self.body['activity_id']}"
        self.assertEqual(self.client.delete(url).json(), {'revoked': True})
        self.assertEqual(self.store().activities(), [])
        self.assertEqual(self.client.delete(url).status_code, 200)
        self.assertEqual(self.client.delete(f"{self.url}/not-a-uuid/{self.body['activity_id']}").status_code, 422)
        self.assertEqual(self.client.delete(f"{self.url}/{self.body['installation_id']}/" + 'x' * 101).status_code, 422)

    def test_delete_only_touches_the_given_installation(self):
        self.put().raise_for_status()
        self.client.delete(f"{self.url}/{uuid.uuid4()}/{self.body['activity_id']}").raise_for_status()
        self.assertEqual(len(self.store().activities()), 1)

    def test_validation_rejects_bad_fields_and_never_echoes_the_token(self):
        bad = [dict(token='zz' * 20), dict(token='ab' * 8), dict(token=TOKEN_SECRET + 'g'), dict(environment='staging'),
               dict(kind='voice'), dict(profile='../x'), dict(session_id=''), dict(activity_id=''), dict(activity_id='a' * 101),
               dict(activity_id='a/b'), dict(started_at='1760000000'), dict(started_at=True), dict(started_at=0), dict(started_at=-1),
               dict(started_at=float('nan')), dict(started_at=1e20), dict(installation_id='nope'), dict(connection_id=7)]
        for change in bad:
            body = {**self.body, **change}
            if change.get('started_at') != change.get('started_at'):
                response = self.client.put(self.url, content=json.dumps(body), headers={'content-type': 'application/json'})
            else:
                response = self.client.put(self.url, json=body)
            self.assertEqual(response.status_code, 422, change)
            self.assertNotIn(TOKEN_SECRET, response.text)
            self.assertNotIn(TOKEN_SECRET.upper(), response.text)
        for change in ({'token': 'zz'}, {'token': 'ab' * 8}, {'kind': 'x'}):
            response = self.client.put(self.url, json={**self.body, 'token': TOKEN_SECRET + 'q', **change})
            self.assertEqual(response.status_code, 422); self.assertNotIn(TOKEN_SECRET, response.text)
        for missing in self.body:
            body = {k: v for k, v in self.body.items() if k != missing}
            response = self.client.put(self.url, json=body)
            self.assertEqual(response.status_code, 422, missing); self.assertNotIn(TOKEN_SECRET, response.text)
        self.assertEqual(self.client.put(self.url, content='{not json', headers={'content-type': 'application/json'}).status_code, 422)
        self.assertEqual(self.client.put(self.url, json=[TOKEN_SECRET]).status_code, 422)
        self.assertEqual(self.store().activities(), [])

    def test_not_ready_server_answers_503(self):
        self.api.service.load_settings = lambda home=None: None
        response = self.put()
        self.assertEqual(response.status_code, 503); self.assertNotIn(TOKEN_SECRET, response.text)

    def test_status_answer_is_unchanged(self):
        self.assertEqual(self.client.get('/api/plugins/hermes-ios-push/status').json(), {'version': 1, 'ready': True})

    def test_the_worker_delivers_alerts_live_events_and_widget_pushes(self):
        key = ec.generate_private_key(ec.SECP256R1())
        path = Path(self.temp.name) / 'fixture.p8'
        path.write_bytes(key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption()))
        config = {'key_path': str(path), 'key_id': 'K', 'team_id': 'T'}
        store = self.store()
        installation, connection = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
        store.register(installation, connection, 'ab' * 32, 'sandbox')
        store.claim_widget_pushes(3600)
        with store.connect() as db:
            db.execute('UPDATE meta SET value=?', (repr(time.time() - 7200),))
        make_activity(store, installation, connection)
        store.enqueue_live(store.activities()[0], 'update', push.live_state('working', 'Nori', 'Lit des fichiers', 1))
        store.enqueue(str(uuid.uuid4()), 'noriven', 'sess', 'turn')
        seen = []
        def handle(request):
            seen.append(request); return httpx.Response(200)
        real = httpx.AsyncClient
        factory = lambda **kw: real(transport=httpx.MockTransport(handle))
        async def run():
            task = asyncio.create_task(self.api.worker())
            await asyncio.sleep(1.5)
            task.cancel()
            try: await task
            except asyncio.CancelledError: pass
        with mock.patch.object(self.api.httpx, 'AsyncClient', factory), \
             mock.patch.object(self.api.service, 'load_settings', lambda home=None: config), \
             mock.patch('hermes_cli.config.load_config', lambda: {'plugins': {'enabled': ['hermes-ios-push']}}):
            asyncio.run(run())
        self.assertEqual(sorted(r.headers['apns-push-type'] for r in seen), ['alert', 'background', 'liveactivity'])
        self.assertEqual(store.pending(), [])
        self.assertEqual(self.store().pending_live(), [])


if __name__ == '__main__': unittest.main()
