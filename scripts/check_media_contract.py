#!/usr/bin/env python3
"""Native upload and chained voice contract against the isolated fixture, never a real account."""
import asyncio
import base64
import io
import uuid
import wave
from pathlib import Path

import httpx
from check_hermes_contract import BASE, Client


def data_url(kind, data):
    return 'data:' + kind + ';base64,' + base64.b64encode(data).decode()


async def main():
    async with httpx.AsyncClient(base_url=BASE, timeout=180) as http:
        login = await http.post('/auth/password-login', json={'provider': 'basic', 'username': 'hermes-ios-test', 'password': 'hermes-ios-local-fixture'})
        login.raise_for_status()
        client = Client(http)
        await client.connect()
        created = await client.rpc('session.create', {'profile': 'research'})
        runtime = created['session_id']
        png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')
        image = await client.rpc('file.attach', {'session_id': runtime, 'name': 'Photo avec espaces.png', 'data_url': data_url('image/png', png)})
        assert image['attached'] and image['path']
        attached = await client.rpc('image.attach', {'session_id': runtime, 'path': Path(image['path']).as_uri()})
        assert attached['attached'] and attached['count'] == 1
        await client.rpc('image.detach', {'session_id': runtime, 'path': image['path']})
        attached = await client.rpc('image.attach', {'session_id': runtime, 'path': Path(image['path']).as_uri()})
        assert attached['count'] == 1, attached
        await client.rpc('image.detach', {'session_id': runtime, 'path': image['path']})
        doc = await client.rpc('file.attach', {'session_id': runtime, 'name': 'Notes été.txt', 'data_url': data_url('text/plain', b'Fixture attachment')})
        assert doc['attached'] and doc['ref_text'].startswith('@file:')
        await client.rpc('prompt.submit', {'session_id': runtime, 'text': doc['ref_text'] + '\n\nExamine ce fichier.'})
        while not any(e['type'] == 'message.complete' and e.get('session_id') == runtime for e in client.events):
            await client.read()
        print('PASS media: native file staging, image attach/detach/retry, path spaces and file prompt reference', flush=True)
        audio = io.BytesIO()
        with wave.open(audio, 'wb') as wav:
            wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000); wav.writeframes(b'\x00\x00' * 2400)
        for profile in ['research', 'studio']:
            status = (await http.get('/api/audio/voice-live/status', params={'profile': profile})).json()
            assert status['mode'] == 'chained', status
            lease = 'ios-contract-' + uuid.uuid4().hex
            (await http.post('/api/audio/tts-lease', params={'profile': profile}, json={'lease': lease, 'active': True})).raise_for_status()
            transcription = await http.post('/api/audio/transcribe', params={'profile': profile}, json={'data_url': data_url('audio/wav', audio.getvalue()), 'mime_type': 'audio/wav'})
            transcription.raise_for_status()
            assert transcription.json()['transcript'] == 'Bonjour Hermes, résume mon projet.', transcription.text
            chat = await client.rpc('session.create', {'profile': profile})
            await client.rpc('prompt.submit', {'session_id': chat['session_id'], 'text': transcription.json()['transcript']})
            while not any(e['type'] == 'message.complete' and e.get('session_id') == chat['session_id'] for e in client.events):
                await client.read()
            complete = next(e for e in client.events if e['type'] == 'message.complete' and e.get('session_id') == chat['session_id'])
            speech = await http.post('/api/audio/speak', params={'profile': profile}, json={'text': complete['payload']['text']})
            speech.raise_for_status()
            result = speech.json()
            assert result['provider'] == 'openai' and base64.b64decode(result['data_url'].split(',', 1)[1]).startswith(b'RIFF'), result
            (await http.post('/api/audio/tts-lease', params={'profile': profile}, json={'lease': lease, 'active': False})).raise_for_status()
            print('PASS voice: ' + profile + ' STT → native prompt → profile TTS → lease release', flush=True)
        await client.ws.close()


if __name__ == '__main__':
    asyncio.run(main())
