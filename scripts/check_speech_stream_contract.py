#!/usr/bin/env python3
"""Test the native audio sockets with the isolated provider fixture only.

speak-stream: the server sends `start` together with its first PCM chunk, so a client
must send text without waiting for it (waiting deadlocks until the client times out).
transcribe-stream: a profile without live STT answers `error` immediately, and the
client falls back to POST /api/audio/transcribe with its recording.
"""
import asyncio
import json
import httpx
import websockets
from check_hermes_contract import BASE

async def socket(http, path, profile):
    ticket = (await http.post('/api/auth/ws-ticket')).json()['ticket']
    return websockets.connect(BASE.replace('http://', 'ws://', 1) + path + '?ticket=' + ticket + '&profile=' + profile)

async def main():
    async with httpx.AsyncClient(base_url=BASE, timeout=60) as http:
        (await http.post('/auth/password-login', json={'provider': 'basic', 'username': 'hermes-ios-test', 'password': 'hermes-ios-local-fixture'})).raise_for_status()
        for profile in ['research', 'studio']:
            async with await socket(http, '/api/audio/speak-stream', profile) as ws:
                try:
                    early = await asyncio.wait_for(ws.recv(), 1.5)
                    raise AssertionError('Nothing may arrive before text: ' + repr(early)[:80])
                except asyncio.TimeoutError:
                    pass
                await ws.send(json.dumps({'text': 'Bonjour. '}))
                start = json.loads(await asyncio.wait_for(ws.recv(), 20))
                assert start == {'type': 'start', 'sample_rate': 24000, 'channels': 1}, start
                audio = await asyncio.wait_for(ws.recv(), 30)
                assert isinstance(audio, bytes) and len(audio) > 0 and not any(audio), 'Fixture must send silent PCM before done'
                await ws.send(json.dumps({'text': 'La suite.', 'done': True}))
                count = len(audio)
                while True:
                    frame = await asyncio.wait_for(ws.recv(), 30)
                    if isinstance(frame, bytes): count += len(frame)
                    else:
                        assert json.loads(frame)['type'] == 'end'; break
                assert count == 2 * 72000 * 2, count
            print('PASS ' + profile + ': text first, start with the first PCM chunk, PCM before completion, end-of-stream', flush=True)
            async with await socket(http, '/api/audio/transcribe-stream', profile) as ws:
                event = json.loads(await asyncio.wait_for(ws.recv(), 20))
                assert event == {'type': 'error', 'message': 'no live STT for the configured provider'}, event
            print('PASS ' + profile + ': transcribe-stream reports no live STT so the client uploads its recording', flush=True)

if __name__ == '__main__': asyncio.run(main())
