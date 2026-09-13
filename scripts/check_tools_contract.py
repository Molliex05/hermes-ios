#!/usr/bin/env python3
"""Check the mobile tools against the disposable integration_server.py only.

Never uses the user's Hermes home, model credentials, or tailnet server.
Audio validation checks the native route without calling a speech provider.
"""
import asyncio
import uuid
import httpx
from check_hermes_contract import BASE, Client


async def main():
    async with httpx.AsyncClient(base_url=BASE, timeout=60) as http:
        login = await http.post('/auth/password-login', json={
            'provider': 'basic', 'username': 'hermes-ios-test', 'password': 'hermes-ios-local-fixture'})
        login.raise_for_status()
        client = Client(http)
        await client.connect()
        suffix = uuid.uuid4().hex[:8]
        async def call(method, path, **kwargs):
            response = await http.request(method, path, **kwargs)
            response.raise_for_status()
            return response.json()

        # Separate skills with the same name must stay scoped on read and toggle.
        name = 'mobile-fixture-' + suffix
        for profile in ['research', 'studio']:
            result = await call('POST', '/api/skills', json={
                'name': name, 'profile': profile,
                'content': f'---\nname: {name}\ndescription: Mobile fixture\n---\n# {profile}\nFixture instructions.'})
            assert result['success'], result
        skills = await call('GET', '/api/skills', params={'profile': 'research'})
        assert any(s['name'] == name and s['enabled'] for s in skills)
        await call('PUT', '/api/skills/toggle', params={'profile': 'research'}, json={'name': name, 'enabled': False})
        research = await call('GET', '/api/skills', params={'profile': 'research'})
        studio = await call('GET', '/api/skills', params={'profile': 'studio'})
        assert not next(s for s in research if s['name'] == name)['enabled']
        assert next(s for s in studio if s['name'] == name)['enabled']
        content = await call('GET', '/api/skills/content', params={'profile': 'studio', 'name': name})
        assert '# studio' in content['content']
        print('PASS skills: list, content, toggle and profile isolation', flush=True)

        created = await client.rpc('projects.create', {'profile': 'research', 'name': 'Mobile ' + suffix})
        project_id = created['project']['id']
        projects = await client.rpc('projects.list', {'profile': 'research'})
        assert any(p['id'] == project_id for p in projects['projects'])
        other = await client.rpc('projects.list', {'profile': 'studio'})
        assert not any(p['id'] == project_id for p in other['projects'])
        print('PASS workspaces: native project shape and profile isolation', flush=True)

        options = await call('GET', '/api/model/options', params={'profile': 'studio'})
        assert isinstance(options['providers'], list)
        assert all(isinstance(m, str) for p in options['providers'] for m in p['models'])
        changed = await call('POST', '/api/model/set', params={'profile': 'research'}, json={
            'scope': 'main', 'provider': 'custom', 'model': 'hermes-ios-fixture-mobile',
            'base_url': 'http://127.0.0.1:19220/v1'})
        assert changed['ok'], changed
        after = await call('GET', '/api/model/options', params={'profile': 'research'})
        untouched = await call('GET', '/api/model/options', params={'profile': 'studio'})
        assert after['model'] == 'hermes-ios-fixture-mobile'
        assert untouched['model'] == options['model']
        print('PASS models: options, native assignment and profile isolation', flush=True)

        boards = await call('GET', '/api/plugins/kanban/boards')
        slug = boards['current']
        query = {'board': slug, 'profile': 'research'}
        body = {'title': 'Mobile fixture ' + suffix, 'body': 'Mobile idea for triage.', 'triage': True, 'idempotency_key': 'mobile-' + suffix}
        task = (await call('POST', '/api/plugins/kanban/tasks', params=query, json=body))['task']
        retry = (await call('POST', '/api/plugins/kanban/tasks', params=query, json=body))['task']
        assert task['id'] == retry['id'] and task['status'] == 'triage', task
        board = await call('GET', '/api/plugins/kanban/board', params=query)
        assert sum(t['id'] == task['id'] for col in board['columns'] for t in col['tasks']) == 1
        detail = await call('GET', '/api/plugins/kanban/tasks/' + task['id'], params=query)
        assert detail['task']['body'] == body['body'] and isinstance(detail['comments'], list)
        assert (await call('GET', '/api/plugins/kanban/boards'))['current'] == slug
        print('PASS kanban: board, create, retry deduplication and task detail', flush=True)

        audio = await http.post('/api/audio/transcribe', params={'profile': 'studio'}, json={'data_url': 'invalid', 'mime_type': 'audio/mp4'})
        speech = await http.post('/api/audio/speak', params={'profile': 'studio'}, json={'text': ''})
        assert audio.status_code == 400 and speech.status_code == 400
        print('PASS audio: authenticated native routes validate payloads (no STT/TTS inference)', flush=True)
        await client.ws.close()


if __name__ == '__main__':
    asyncio.run(main())
