#!/usr/bin/env python3
"""gemini-voix plugin on an unmodified Hermes: Voice design voice resolved by name, unary speak and streamed PCM.

Start: integration_server.py --home <new> --port 19169 --model-port 19270 --gemini-voix
"""
import asyncio
import base64
import json
import os

import httpx
import websockets

BASE = os.environ.get("HERMES_TEST_BASE", "http://127.0.0.1:19169")
assert BASE.startswith("http://127.0.0.1:"), "Tests must target the isolated localhost fixture"


async def main():
    async with httpx.AsyncClient(base_url=BASE, timeout=60) as http:
        (await http.post('/auth/password-login', json={'provider': 'basic', 'username': 'hermes-ios-test', 'password': 'hermes-ios-local-fixture'})).raise_for_status()
        for profile in ['default', 'research']:
            speech = await http.post('/api/audio/speak', params={'profile': profile}, json={'text': 'Bonjour! Je suis ton agent.'})
            assert speech.status_code == 200, speech.text
            result = speech.json()
            assert result['provider'] == 'gemini-voix' and result['mime_type'] == 'audio/wav', result
            assert base64.b64decode(result['data_url'].split(',', 1)[1]).startswith(b'RIFF'), 'unary Gemini audio must stay WAV'
            ticket = (await http.post('/api/auth/ws-ticket')).json()['ticket']
            url = BASE.replace('http://', 'ws://', 1) + f'/api/audio/speak-stream?profile={profile}&ticket={ticket}'
            async with websockets.connect(url) as ws:
                await ws.send(json.dumps({'text': 'Une première phrase. ', 'done': True}))
                start, pcm, ended = None, 0, False
                while not ended:
                    frame = await asyncio.wait_for(ws.recv(), timeout=30)
                    if isinstance(frame, bytes):
                        assert start, 'start precedes PCM'
                        pcm += len(frame)
                    else:
                        event = json.loads(frame)
                        assert event.get('type') != 'fallback', 'gemini-voix must stream, not fall back'
                        if event.get('type') == 'start':
                            start = event
                        ended = event.get('type') == 'end'
                assert start['sample_rate'] == 24000 and start['channels'] == 1, start
                assert pcm >= 3 * 9600, pcm
            print(f'PASS {profile}: Voice design voice resolved by name, unary WAV and streamed 24 kHz PCM through gemini-voix', flush=True)


if __name__ == '__main__':
    asyncio.run(main())
