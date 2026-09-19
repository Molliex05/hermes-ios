#!/usr/bin/env python3
"""Test incremental native PCM speech with the isolated provider fixture only."""
import asyncio
import json
import httpx
import websockets
from check_hermes_contract import BASE

async def main():
    async with httpx.AsyncClient(base_url=BASE,timeout=60) as http:
        (await http.post('/auth/password-login',json={'provider':'basic','username':'hermes-ios-test','password':'hermes-ios-local-fixture'})).raise_for_status()
        for profile in ['research','studio']:
            ticket=(await http.post('/api/auth/ws-ticket')).json()['ticket']
            async with websockets.connect(BASE.replace('http://','ws://',1)+'/api/audio/speak-stream?ticket='+ticket+'&profile='+profile) as ws:
                start=json.loads(await asyncio.wait_for(ws.recv(),20))
                assert start=={'type':'start','sample_rate':24000,'channels':1},start
                await ws.send(json.dumps({'text':'Bonjour. '}))
                audio=await asyncio.wait_for(ws.recv(),30)
                assert isinstance(audio,bytes) and len(audio)>0 and not any(audio), 'Fixture must send silent PCM before done'
                await ws.send(json.dumps({'text':'La suite.','done':True}))
                count=len(audio)
                while True:
                    frame=await asyncio.wait_for(ws.recv(),30)
                    if isinstance(frame,bytes): count+=len(frame)
                    else:
                        assert json.loads(frame)['type']=='end'; break
                assert count==2*72000*2,count
            print('PASS '+profile+': native ticket, profile, PCM before text completion and end-of-stream',flush=True)
if __name__=='__main__': asyncio.run(main())
