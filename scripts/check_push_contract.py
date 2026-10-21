#!/usr/bin/env python3
"""Actual Hermes hooks + cron Bot Chat delivery; no Apple credentials or real APNs."""
import asyncio
import importlib.util
from pathlib import Path
import sys
import json
import time
import uuid

import httpx
from check_hermes_contract import BASE, Client

HOME = Path(sys.argv[1]).resolve()
assert 'outputs' in HOME.parts and (HOME / 'plugins/hermes-ios-push').is_dir(), 'Use the disposable push fixture'
spec = importlib.util.spec_from_file_location('push', HOME / 'plugins/hermes-ios-push/push_service.py')
push = importlib.util.module_from_spec(spec); spec.loader.exec_module(push)

KEY = bytes(range(32))


class Recorder:
    """Stands in for Apple: records what the worker would send."""
    def __init__(self): self.rows = []
    async def deliver(self, row):
        self.rows.append(row); return 200, '', None


async def turn(c, sid, text):
    done = lambda: sum(1 for e in c.events if e['type'] == 'message.complete' and e.get('session_id') == sid)
    before = done()
    await c.rpc('prompt.submit', {'session_id': sid, 'text': text})
    while done() == before: await c.read()
    await asyncio.sleep(0.5)      # the post_llm_call hook runs right after message.complete


async def main():
    store = push.Store(HOME / 'ios-push')
    with store.connect() as db:
        db.execute('DELETE FROM outbox'); db.execute('DELETE FROM devices')
    installation, connection = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
    # Seed a fake registration directly into the disposable outbox; no Apple traffic.
    store.register(installation, connection, 'ab' * 32, 'sandbox', KEY)
    async with httpx.AsyncClient(base_url=BASE, timeout=180) as http:
        assert (await http.get('/api/plugins/hermes-ios-push/status')).status_code == 401
        for method, path in (('PUT', '/presence'), ('DELETE', '/presence'), ('PUT', '/devices'), ('PUT', '/activities'),
                             ('DELETE', '/activities/' + str(uuid.uuid4()) + '/ACT-1')):
            assert (await http.request(method, '/api/plugins/hermes-ios-push' + path, json={})).status_code == 401, path   # behind dashboard auth
        (await http.post('/auth/password-login', json={'provider':'basic','username':'hermes-ios-test','password':'hermes-ios-local-fixture'})).raise_for_status()
        status = await http.get('/api/plugins/hermes-ios-push/status'); status.raise_for_status()
        assert status.json() == {'version':1,'ready':False},status.text
        c = Client(http); await c.connect()
        created = await c.rpc('session.create', {'profile':'research','close_on_disconnect':False})
        await c.rpc('prompt.submit', {'session_id':created['session_id'],'text':'Notification fixture'})
        while not any(e['type']=='message.complete' and e.get('session_id')==created['session_id'] for e in c.events): await c.read()
        rows = store.pending()
        assert len(rows)==1,rows
        assert rows[0]['profile']=='research' and rows[0]['session']==created['stored_session_id'],rows
        print('PASS authenticated native plugin API and real completion hook preserve profile/session',flush=True)
        payload = push.notification_payload(rows[0])
        assert len(json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode()) < 4096
        plain = push.decrypt_content(KEY, rows[0]['event'], payload['hermes']['enc'])
        assert plain['agent'] == 'Chercheur', plain          # ui_meta.hermes-bots.title of the profile
        assert plain['preview'].startswith('Bonjour depuis Hermes.') and len(plain['preview']) <= 140 and '*' not in plain['preview'], plain
        assert plain['conversation'], plain
        assert payload['hermes']['kind'] == 'turn' and payload['aps']['mutable-content'] == 1
        assert 'Bonjour' not in json.dumps(payload['aps']) and 'Bonjour' not in payload['hermes']['enc']      # nothing readable by Apple
        print('PASS real turn: encrypted agent/conversation/preview decrypt with the device key, payload < 4096 bytes',flush=True)
        # Create the native Bot Chat before scheduling so its canonical identity is explicit.
        roster = await c.rpc('session.list', {'profile':'research','title':'Bot Chat','include_hidden':True})
        if roster['sessions']:
            stored = roster['sessions'][0].get('resolved_id') or roster['sessions'][0]['id']
            bot = await c.rpc('session.resume', {'profile':'research','session_id':stored,'close_on_disconnect':False})
            bot['stored_session_id'] = bot.get('session_key') or stored
        else:
            bot = await c.rpc('session.create', {'profile':'research','title':'Bot Chat','hidden':True,'follow_profile_config':True,'close_on_disconnect':False})
            await c.rpc('session.title', {'session_id':bot['session_id'],'title':'Bot Chat'})
        await c.ws.close()  # No phone/socket remains attached during the cron.
        job = await http.post('/api/cron/jobs',params={'profile':'research'},json={'name':'Push contract','prompt':'Say hello for a notification test.','schedule':'0 8 * * *','deliver':'bot-chat:research','profile':'research'})
        job.raise_for_status()
        jobs = (await http.get('/api/cron/jobs',params={'profile':'research'})).json()
        if isinstance(jobs,dict): jobs=jobs['jobs']
        jid=next(j['id'] for j in jobs if j['name']=='Push contract')
        fired = await http.post('/api/cron/jobs/'+jid+'/trigger',params={'profile':'research'});fired.raise_for_status()
        for _ in range(90):
            rows = store.pending()
            if len(rows)>=2: break
            await asyncio.sleep(1)
        assert len(rows)==2,rows
        assert rows[1]['session']==bot['stored_session_id'] and rows[1]['profile']=='research',rows
        # Raw cron execution must not produce a second notification for the same delivery.
        await asyncio.sleep(2)
        assert len(store.pending())==2
        payload = push.notification_payload(rows[1])
        (HOME.parent / 'cron-notification.apns').write_text(__import__('json').dumps(payload))
        await c.connect()
        resumed = await c.rpc('session.resume', {'profile':'research','session_id':payload['hermes']['session_id'],'close_on_disconnect':False})
        assert any(m.get('role')=='assistant' and 'le fil est retrouvé.' in m.get('text','') for m in resumed['messages'])
        await c.ws.close()
        (await http.delete('/api/cron/jobs/'+jid,params={'profile':'research'})).raise_for_status()
        print('PASS cron ran with phone disconnected; exactly one notification targets the actual Bot Chat; native resume finds its answer',flush=True)
        # Presence, checked by the worker at send time (Apple replaced by a recorder).
        await c.connect()
        flush = Recorder(); await push.deliver_pending(store, flush)      # drain earlier rows
        live = await c.rpc('session.create', {'profile':'research','close_on_disconnect':False})
        stored = live['stored_session_id']
        presence = {'installation_id':installation,'connection_id':connection,'profile':'research','session_id':stored,'ttl':60}
        (await http.put('/api/plugins/hermes-ios-push/presence', json=presence)).raise_for_status()
        await turn(c, live['session_id'], 'Presence fixture')
        assert len(store.pending()) == 1, 'queued before delivery, as the worker would find it'
        recorder = Recorder(); counts = await push.deliver_pending(store, recorder)
        assert counts['suppressed'] == 1 and recorder.rows == [], (counts, recorder.rows)
        other = dict(presence, installation_id=str(uuid.uuid4()))
        (await http.put('/api/plugins/hermes-ios-push/presence', json=other)).raise_for_status()      # another phone: irrelevant
        (await http.request('DELETE', '/api/plugins/hermes-ios-push/presence', json={k:v for k,v in presence.items() if k != 'ttl'})).raise_for_status()
        await turn(c, live['session_id'], 'Presence over')
        recorder = Recorder(); counts = await push.deliver_pending(store, recorder)
        assert counts['sent'] == 1 and len(recorder.rows) == 1, counts
        await c.ws.close()
        print('PASS presence PUT/DELETE over the authenticated API: suppressed at send time, then delivered once cleared',flush=True)
        # Live Activity (v0.3): authenticated registration API, then the REAL pre_tool_call / post_llm_call hooks.
        token = 'be' * 32
        activity = {'installation_id':installation,'connection_id':connection,'profile':'research','session_id':'ignored','activity_id':'ACT-CONTRACT',
                    'token':token,'environment':'sandbox','kind':'reply','started_at':1760000000.5}
        bad = await http.put('/api/plugins/hermes-ios-push/activities', json=dict(activity, token='zz'+token))
        assert bad.status_code == 422 and token not in bad.text, bad.text
        notready = await http.put('/api/plugins/hermes-ios-push/activities', json=activity)
        assert notready.status_code == 503 and token not in notready.text, notready.text       # same gate as PUT /devices: APNs not configured here
        await c.connect()
        live = await c.rpc('session.create', {'profile':'research','close_on_disconnect':False})
        stored = live['stored_session_id']
        store.put_activity(installation, connection, 'research', stored, 'ACT-CONTRACT', token, 'sandbox', 'reply', 1760000000.5)      # what the API stores once APNs is configured
        store.put_activity(installation, connection, 'research', stored, 'ACT-CALL', token, 'sandbox', 'call', 1760000000.5)
        with store.connect() as db: db.execute('DELETE FROM live_queue')
        await c.rpc('prompt.submit', {'session_id':live['session_id'],'text':'HERMES_IOS_TOOL_BACKGROUND_TEST'})
        deadline = time.time() + 60
        queued = []
        while not queued and time.time() < deadline:
            await asyncio.sleep(0.5)
            with store.connect() as db: queued = [dict(r) for r in db.execute('SELECT * FROM live_queue')]
        assert [r['activity'] for r in queued] == ['ACT-CONTRACT'] and queued[0]['event'] == 'update', queued      # not the call
        state = json.loads(queued[0]['state'])
        assert state == {'phase':'working','title':'Chercheur','detail':'Exécute une commande','muted':False,'startedAt':1760000000.5}, state
        assert 'sleep' not in queued[0]['state'] and 'HERMES_IOS' not in queued[0]['state']
        print('PASS real pre_tool_call (terminal): one generic "Exécute une commande" update for the activity of this session, none for the call, no tool arguments',flush=True)
        while not any(e['type']=='message.complete' and e.get('session_id')==live['session_id'] for e in c.events): await c.read()
        await asyncio.sleep(1)
        with store.connect() as db: queued = [dict(r) for r in db.execute('SELECT * FROM live_queue')]
        assert [(r['activity'], r['event']) for r in queued] == [('ACT-CONTRACT', 'end')], queued
        assert json.loads(queued[0]['state']) == {'phase':'done','title':'Chercheur','detail':'Réponse prête','muted':False,'startedAt':1760000000.5}, queued
        wire = push.live_payload(dict(queued[0], timestamp=1760000100))
        assert wire['aps']['event'] == 'end' and wire['aps']['dismissal-date'] == 1760000100 + 900
        await c.ws.close()
        print('PASS real post_llm_call: the update is replaced by one "done" end event (dismissal +15 min); the turn notification is unchanged',flush=True)
        assert (await http.delete('/api/plugins/hermes-ios-push/activities/'+installation+'/ACT-CONTRACT')).status_code == 200
        assert [a['activity'] for a in store.activities()] == ['ACT-CALL']
        with store.connect() as db: assert db.execute('SELECT COUNT(*) FROM live_queue').fetchone()[0] == 0
        print('PASS DELETE /activities forgets the activity and its queue',flush=True)
        assert (await http.put('/api/plugins/hermes-ios-push/devices', json={'installation_id':installation,'connection_id':connection,'token':'ab'*32,'environment':'sandbox','key':'not-a-key'})).status_code == 422
        (await http.delete('/api/plugins/hermes-ios-push/devices/'+installation+'/'+connection)).raise_for_status()
        # UUIDs are normalized by the HTTP API; fixture registration uses canonical casing.
        store.revoke(installation,connection)

if __name__=='__main__': asyncio.run(main())
