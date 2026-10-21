#!/usr/bin/env python3
"""Native management contracts. Run only against integration_server.py on localhost."""
import asyncio
import uuid
import httpx
from check_hermes_contract import BASE, Client

async def main():
    async with httpx.AsyncClient(base_url=BASE, timeout=90) as http:
        (await http.post('/auth/password-login', json={'provider':'basic','username':'hermes-ios-test','password':'hermes-ios-local-fixture'})).raise_for_status()
        c = Client(http); await c.connect()
        suffix = uuid.uuid4().hex[:8]
        async def call(method, path, profile='research', **kw):
            params = kw.pop('params', {}); params['profile'] = profile
            if isinstance(kw.get('json'), dict): kw['json']['profile'] = profile
            r = await http.request(method, path, params=params, **kw)
            assert r.is_success, (method, path, r.status_code, r.text[:500])
            return r.json()

        cfg = await call('GET','/api/config')
        schema = await call('GET','/api/config/schema')
        assert 'approvals.mode' in schema['fields'], list(schema)[:10]
        original = await call('GET','/api/config', profile='studio')
        result = await call('PUT','/api/config',json={'config':{'approvals':{'mode':'manual'}}})
        changed = await call('GET','/api/config')
        assert changed['approvals']['mode'] == 'manual', changed.keys()
        assert changed['model'] == cfg['model']
        assert (await call('GET','/api/config',profile='studio')) == original
        print('PASS partial configuration preserves model and isolates profiles', flush=True)

        sets = await call('GET','/api/tools/toolsets')
        assert isinstance(sets,list) and sets
        selected = next(s for s in sets if s.get('enabled'))
        await call('PUT','/api/tools/toolsets/'+selected['name'],json={'enabled':False})
        after = await call('GET','/api/tools/toolsets')
        assert not next(s for s in after if s['name']==selected['name'])['enabled']
        await call('PUT','/api/tools/toolsets/'+selected['name'],json={'enabled':True})
        print('PASS toolset toggles', flush=True)

        name = 'edit-fixture-'+suffix
        content = f'---\nname: {name}\ndescription: Contract test\n---\nOriginal'
        await call('POST','/api/skills',json={'name':name,'content':content})
        await call('PUT','/api/skills/content',json={'name':name,'content':content+' edited'})
        assert (await call('GET','/api/skills/content',params={'name':name}))['content'].endswith('edited')
        removal = await c.rpc('cli.exec',{'argv':['--profile','research','skills','uninstall',name,'--yes'],'timeout':30})
        # 0.21.7 refuses a non-hub uninstall with a non-zero exit (older builds exited zero); the app only offers hub uninstall.
        assert removal.get('code') != 0 or removal.get('blocked') or 'not a hub-installed skill' in removal.get('output', ''), removal
        assert any(s['name']==name for s in await call('GET','/api/skills')), 'Local skills must not be presented as hub-uninstallable'
        print('PASS skills create/edit; native CLI refuses non-hub uninstall', flush=True)

        project = (await c.rpc('projects.create',{'profile':'research','name':'Contract '+suffix}))['project']
        await c.rpc('projects.update',{'profile':'research','id':project['id'],'name':'Edited '+suffix,'description':'Updated'})
        assert next(p for p in (await c.rpc('projects.list',{'profile':'research'}))['projects'] if p['id']==project['id'])['name']=='Edited '+suffix
        profiles = await call('GET','/api/profiles')
        home = next(p['path'] for p in profiles['profiles'] if p['name']=='research')
        path = home+'/contract-'+suffix+'.txt'
        await call('POST','/api/fs/write-text',json={'path':path,'content':'Hello'})
        assert (await call('GET','/api/fs/read-text',params={'path':path}))['text']=='Hello'
        files = await call('GET','/api/fs/list',params={'path':home})
        assert any(e['path']==path for e in files['entries'])
        print('PASS project editing and native remote file roundtrip', flush=True)

        session = await c.rpc('session.create',{'profile':'research','title':'History '+suffix})
        stored = session['stored_session_id']
        await c.rpc('prompt.submit', {'session_id':session['session_id'],'text':'History contract '+suffix})
        while not any(e['type']=='message.complete' and e.get('session_id')==session['session_id'] for e in c.events): await c.read()
        await call('PATCH','/api/sessions/'+stored,json={'title':'Renamed '+suffix,'archived':True})
        archived = await call('GET','/api/sessions',params={'archived':'only','limit':100,'offset':0})
        assert any(s['id']==stored for s in archived['sessions']), archived
        active = await call('GET','/api/sessions',params={'archived':'exclude','limit':100,'offset':0})
        assert not any(s['id']==stored for s in active['sessions'])
        await call('PATCH','/api/sessions/'+stored,json={'archived':False})
        search = await call('GET','/api/sessions/search',params={'q':suffix,'limit':100})
        assert 'results' in search, search
        print('PASS history rename, archive, restore and remote search', flush=True)

        await c.rpc('cron.manage',{'action':'add','profile':'research','name':'[bot:research] Contract '+suffix,'schedule':'0 8 * * *','prompt':'Fixture only','deliver':'bot-chat:research'})
        jobs = await call('GET','/api/cron/jobs')
        job = next(j for j in jobs if suffix in j['name']); jid = job['id']
        detail = await call('GET','/api/cron/jobs/'+jid)
        await call('PUT','/api/cron/jobs/'+jid,json={'updates':{'name':job['name'],'prompt':'Edited fixture','schedule':'0 9 * * *'}})
        changed = await call('GET','/api/cron/jobs/'+jid)
        assert changed['prompt']=='Edited fixture' and changed['schedule'] != detail['schedule'], changed
        assert isinstance((await call('GET','/api/cron/jobs/'+jid+'/runs'))['runs'],list)
        await call('DELETE','/api/cron/jobs/'+jid)
        print('PASS cron edit, schedule, run history and deletion', flush=True)

        slug = (await call('GET','/api/plugins/kanban/boards'))['current']; query={'board':slug}
        task = (await call('POST','/api/plugins/kanban/tasks',params=query,json={'title':'Contract '+suffix,'body':'Before','triage':True,'idempotency_key':suffix}))['task']
        path = '/api/plugins/kanban/tasks/'+task['id']
        await call('PATCH',path,params=query,json={'title':'Edited '+suffix,'body':'After','status':'todo'})
        await call('POST',path+'/comments',params=query,json={'body':'Comment','author':'Hermès iOS'})
        detail = await call('GET',path,params=query)
        assert detail['task']['body']=='After' and any(v['body']=='Comment' for v in detail['comments'])
        print('PASS kanban edit, status and comments', flush=True)

        roster = await c.rpc('profiles.list'); row=next(p for p in roster['profiles'] if p['name']=='research')
        meta={**row.get('ui_meta',{}).get('hermes-bots',{}),'title':'Recherche','pinned':True}
        payload={'name':'research','ui_meta':{'hermes-bots':meta},'ui_meta_expected_revisions':{'hermes-bots':row.get('ui_meta_revisions',{}).get('hermes-bots',0)}}
        assert (await c.rpc('profiles.configure',payload))['applied']['ui_meta']
        assert not (await c.rpc('profiles.configure',payload))['applied'].get('ui_meta',False)
        print('PASS Bot presentation and concurrent-edit rejection', flush=True)

        rid=str(uuid.uuid4())
        await c.rpc('groups.create',{'room_id':rid,'name':'Contract','members':[{'member_id':p,'profile':p,'handle':p} for p in ['research','studio']]})
        await c.rpc('groups.rename',{'room_id':rid,'event_id':str(uuid.uuid4()),'name':'Renamed group'})
        state=await c.rpc('groups.state',{'room_id':rid})
        assert state['room']['name']=='Renamed group' and 'pending_actions' in state['driver_status']
        await c.rpc('groups.disband',{'room_id':rid,'cancel_id':str(uuid.uuid4())})
        assert (await c.rpc('groups.state',{'room_id':rid,'include_disbanded':True}))['room']['disbanded_at']
        print('PASS groups state, rename and disband', flush=True)
        await c.ws.close()

if __name__ == '__main__': asyncio.run(main())
