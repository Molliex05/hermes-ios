"""Hermes notification outbox + APNs contract tests; no real device or Apple traffic."""
import asyncio
import importlib.util
import json
from pathlib import Path
import tempfile
import time
import unittest
import uuid

import httpx
import jwt
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import Encoding, PrivateFormat, NoEncryption

spec = importlib.util.spec_from_file_location('push', Path(__file__).resolve().parents[1] / 'server/hermes-ios-push/push_service.py')
push = importlib.util.module_from_spec(spec); spec.loader.exec_module(push)


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


if __name__ == '__main__': unittest.main()
