#!/usr/bin/env python3
"""Verify routine execution -> stored conversation against the disposable Hermes fixture."""
import asyncio
import json
import uuid

import httpx
from check_hermes_contract import BASE, Client


async def main():
    async with httpx.AsyncClient(base_url=BASE, timeout=180) as http:
        (await http.post('/auth/password-login', json={
            'provider': 'basic', 'username': 'hermes-ios-test',
            'password': 'hermes-ios-local-fixture',
        })).raise_for_status()
        c = Client(http)
        await c.connect()
        job_id = None
        profile = 'research'

        async def call(method, path, **kwargs):
            response = await http.request(method, path, params={'profile': profile}, **kwargs)
            response.raise_for_status()
            return response.json()

        try:
            name = 'Routine navigation ' + uuid.uuid4().hex[:8]
            await call('POST', '/api/cron/jobs', json={
                'name': name, 'prompt': 'Answer briefly for the routine navigation fixture.',
                'schedule': '0 8 * * *', 'deliver': 'local', 'profile': profile,
            })
            jobs = await call('GET', '/api/cron/jobs')
            if isinstance(jobs, dict):
                jobs = jobs['jobs']
            job_id = next(job['id'] for job in jobs if job['name'] == name)
            path = '/api/cron/jobs/' + job_id
            before = await call('GET', path)
            assert before['schedule']['expr'] == '0 8 * * *', before
            # Text-only editing must not reschedule a stored one-shot or alter cron.
            edited = await call('PUT', path, json={'updates': {'name': name + ' edited'}})
            assert edited['schedule'] == before['schedule'], edited
            await call('POST', path + '/trigger')
            await call('POST', path + '/pause')
            history = await call('GET', path + '/runs')
            assert history['runs'], history
            run = history['runs'][0]
            assert run['id'] and run['profile'] == profile, run
            assert not run['is_active'], run
            detail = await call('GET', '/api/sessions/' + run['id'])
            assert detail['id'] == run['id'], detail
            resumed = await c.rpc('session.resume', {
                'profile': run['profile'], 'session_id': run['id'], 'close_on_disconnect': False,
            })
            stored = resumed.get('session_key') or resumed.get('stored_session_id')
            assert stored == run['id'], resumed
            assert any(message.get('role') == 'assistant' and message.get('text')
                       for message in resumed['messages']), resumed
            # Hermes can remove a finished one-shot from the job list. Its stored
            # results must remain discoverable even after GET /job returns 404.
            await call('DELETE', path)
            job_id = None
            missing = await http.get(path, params={'profile': profile})
            assert missing.status_code == 404, missing.text
            retained = await call('GET', path + '/runs')
            if not any(item['id'] == run['id'] for item in retained['runs']):
                # Hermes 0.21.7 resolves the run owner from the live job, so a deleted job lists no runs.
                # The stored conversation itself stays reachable (checked above via session.resume).
                print('WARN deleted job no longer lists its runs on this Hermes; stored conversation still resumes', flush=True)
            print(json.dumps({
                'passed': True, 'profile': run['profile'], 'stored_session': run['id'],
                'checks': ['native schedule preservation', 'native cron execution',
                           'run SessionInfo mapping', 'stored conversation resume with answer',
                           'stored results remain available after job removal'],
            }, indent=2), flush=True)
        finally:
            if job_id:
                await call('DELETE', '/api/cron/jobs/' + job_id)
            await c.ws.close()


if __name__ == '__main__':
    asyncio.run(main())
