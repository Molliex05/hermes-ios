#!/usr/bin/env python3
"""ios_notify against a real Hermes (disposable fixture started with --push-plugin): Tool Search bridge call,
turn identity, dedupe, limits, presence-independence and cron. No Apple credentials or real APNs.

Usage: HERMES_TEST_BASE=http://127.0.0.1:19133 python check_ios_notify_contract.py <fixture home>"""
import asyncio
import importlib.util
import json
from pathlib import Path
import sys
import uuid

import httpx
from check_hermes_contract import BASE, Client

HOME = Path(sys.argv[1]).resolve()
assert 'outputs' in HOME.parts and (HOME / 'plugins/hermes-ios-push').is_dir(), 'Use the disposable push fixture'
spec = importlib.util.spec_from_file_location('push', HOME / 'plugins/hermes-ios-push/push_service.py')
push = importlib.util.module_from_spec(spec); spec.loader.exec_module(push)
KEY = bytes(range(32))
TOOL = 'HERMES_IOS_NOTIFY_TEST'


class Recorder:
    def __init__(self): self.rows = []
    async def deliver(self, row):
        self.rows.append(row); return 200, '', None


async def turn(c, sid, text):
    done = lambda: sum(1 for e in c.events if e['type'] == 'message.complete' and e.get('session_id') == sid)
    before = done()
    await c.rpc('prompt.submit', {'session_id': sid, 'text': text})
    while done() == before: await c.read()
    await asyncio.sleep(1.0)      # the post_llm_call hook runs right after message.complete


def outbox(store):
    with store.connect() as db:
        return [dict(r) for r in db.execute('SELECT * FROM outbox ORDER BY created, rowid')]


async def main():
    store = push.Store(HOME / 'ios-push')
    with store.connect() as db:
        for table in ('outbox', 'devices', 'tool_log', 'tool_turns', 'presence', 'cron_notified'): db.execute(f'DELETE FROM {table}')
    installation, connection = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
    store.register(installation, connection, 'ab' * 32, 'sandbox', KEY)
    async with httpx.AsyncClient(base_url=BASE, timeout=180) as http:
        (await http.post('/auth/password-login', json={'provider':'basic','username':'hermes-ios-test','password':'hermes-ios-local-fixture'})).raise_for_status()
        c = Client(http); await c.connect()
        live = await c.rpc('session.create', {'profile':'research','close_on_disconnect':False})
        sid, stored = live['session_id'], live['stored_session_id']

        # 1. The model reaches ios_notify through Tool Search (plugin tools are deferred in 0.21.7).
        await turn(c, sid, TOOL + ' premier')
        rows = outbox(store)
        assert [r['kind'] for r in rows] == ['tool'], rows          # the automatic notification of that turn did NOT go out
        row = rows[0]
        assert row['session'] == stored, row                        # open_conversation=true -> current conversation
        payload = push.notification_payload(row)
        assert payload['aps']['alert'] == {'title': 'Chercheur', 'body': 'Nouveau message'}, payload['aps']
        assert payload['hermes']['kind'] == 'tool' and payload['hermes']['session_id'] == stored
        plain = push.decrypt_content(KEY, row['event'], payload['hermes']['enc'])
        assert plain == {'agent': 'Chercheur', 'conversation': 'Audit', 'preview': 'Rapport prêt : 42 erreurs corrigées'}, plain
        assert 'Rapport' not in json.dumps(payload['aps'])
        print('PASS ios_notify via tool_call: title imposed (profile display name), encrypted content, same-turn automatic notification dropped', flush=True)

        # 2. Presence never suppresses a tool notification; the next ordinary turn notifies normally.
        (await http.put('/api/plugins/hermes-ios-push/presence', json={'installation_id':installation,'connection_id':connection,'profile':'research','session_id':stored,'ttl':60})).raise_for_status()
        recorder = Recorder(); counts = await push.deliver_pending(store, recorder)
        assert counts['sent'] == 1 and recorder.rows[0]['kind'] == 'tool', counts
        await turn(c, sid, 'Une question ordinaire')
        assert [r['kind'] for r in outbox(store)] == ['tool', 'turn'], outbox(store)
        counts = await push.deliver_pending(store, Recorder())
        assert counts['suppressed'] == 1, counts                    # ...but presence does suppress the automatic one
        print('PASS tool notification ignores presence; next turn is automatic again (and presence-suppressed)', flush=True)

        # 3. Limit: 5 accepted per hour per profile, then the tool errors and the automatic notification takes over.
        for _ in range(4): await turn(c, sid, TOOL + ' encore')
        assert [r['kind'] for r in outbox(store)].count('tool') == 5
        before = len(outbox(store))
        await turn(c, sid, TOOL + ' sixième')
        after = outbox(store)
        assert len(after) == before + 1 and after[-1]['kind'] == 'turn', after[-1]
        print('PASS 6th call refused (not queued, not counted); the turn falls back to the automatic notification', flush=True)

        # 4. Cron: the tool notification has no conversation, and the Bot Chat delivery does not notify again.
        with store.connect() as db: db.execute('DELETE FROM tool_log'); db.execute('DELETE FROM outbox')
        roster = await c.rpc('session.list', {'profile':'research','title':'Bot Chat','include_hidden':True})
        if not roster['sessions']:      # the native Bot Chat must exist before the cron delivers into it
            bot = await c.rpc('session.create', {'profile':'research','title':'Bot Chat','hidden':True,'follow_profile_config':True,'close_on_disconnect':False})
            await c.rpc('session.title', {'session_id':bot['session_id'],'title':'Bot Chat'})
        await c.ws.close()
        job = await http.post('/api/cron/jobs', params={'profile':'research'}, json={'name':'Notify cron','prompt':TOOL + ' cron','schedule':'0 8 * * *','deliver':'bot-chat:research','profile':'research'})
        job.raise_for_status()
        jobs = (await http.get('/api/cron/jobs', params={'profile':'research'})).json()
        if isinstance(jobs, dict): jobs = jobs['jobs']
        jid = next(j['id'] for j in jobs if j['name'] == 'Notify cron')
        (await http.post('/api/cron/jobs/' + jid + '/trigger', params={'profile':'research'})).raise_for_status()
        for _ in range(60):
            await asyncio.sleep(1)
            if any(r['kind'] == 'tool' for r in outbox(store)): break
        await asyncio.sleep(15)      # time for the Bot Chat delivery turn (and a wrongly queued second notification)
        rows = outbox(store)
        assert [(r['kind'], r['session']) for r in rows] == [('tool', '')], rows
        assert 'session_id' not in push.notification_payload(rows[0])['hermes']
        (await http.delete('/api/cron/jobs/' + jid, params={'profile':'research'})).raise_for_status()
        print('PASS cron: ios_notify (no conversation target) and no second notification from the Bot Chat delivery', flush=True)

        # 5. No registered device: clear error, nothing queued.
        store.revoke(installation, connection)
        with store.connect() as db: db.execute('DELETE FROM tool_log')
        await c.connect()
        live = await c.rpc('session.create', {'profile':'research','close_on_disconnect':False})
        await turn(c, live['session_id'], TOOL + ' sans appareil')
        assert outbox(store) == []
        await c.ws.close()
        print('PASS no registered device: refused, nothing queued', flush=True)

if __name__ == '__main__': asyncio.run(main())
