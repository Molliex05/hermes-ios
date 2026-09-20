#!/usr/bin/env python3
"""Actual Hermes hooks + cron Bot Chat delivery; no Apple credentials or real APNs."""
import asyncio
import importlib.util
from pathlib import Path
import sys
import uuid

import httpx
from check_hermes_contract import BASE, Client

HOME = Path(sys.argv[1]).resolve()
assert 'outputs' in HOME.parts and (HOME / 'plugins/hermes-ios-push').is_dir(), 'Use the disposable push fixture'
spec = importlib.util.spec_from_file_location('push', HOME / 'plugins/hermes-ios-push/push_service.py')
push = importlib.util.module_from_spec(spec); spec.loader.exec_module(push)

async def main():
    store = push.Store(HOME / 'ios-push')
    with store.connect() as db:
        db.execute('DELETE FROM outbox'); db.execute('DELETE FROM devices')
    installation, connection = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
    # Seed a fake registration directly into the disposable outbox; no Apple traffic.
    store.register(installation, connection, 'ab' * 32, 'sandbox')
    async with httpx.AsyncClient(base_url=BASE, timeout=180) as http:
        assert (await http.get('/api/plugins/hermes-ios-push/status')).status_code == 401
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
        (await http.delete('/api/plugins/hermes-ios-push/devices/'+installation+'/'+connection)).raise_for_status()
        # UUIDs are normalized by the HTTP API; fixture registration uses canonical casing.
        store.revoke(installation,connection)

if __name__=='__main__': asyncio.run(main())
