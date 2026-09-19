#!/usr/bin/env python3
"""Disconnect during a real, long-running Hermes tool; verify persisted completion once."""
import asyncio
import httpx
from check_hermes_contract import BASE, Client

async def main():
    async with httpx.AsyncClient(base_url=BASE, timeout=60) as http:
        (await http.post('/auth/password-login',json={'provider':'basic','username':'hermes-ios-test','password':'hermes-ios-local-fixture'})).raise_for_status()
        c=Client(http); await c.connect()
        session=await c.rpc('session.create',{'profile':'default','close_on_disconnect':False})
        sid=session['session_id']; marker='HERMES_IOS_TOOL_BACKGROUND_TEST'
        accepted=await c.rpc('prompt.submit',{'session_id':sid,'text':marker})
        assert accepted['status']=='streaming',accepted
        while not any(e.get('session_id')==sid and e['type']=='tool.start' for e in c.events): await c.read()
        assert not any(e.get('session_id')==sid and e['type']=='message.complete' for e in c.events)
        print('PASS native submit acknowledged and terminal tool started; disconnecting',flush=True)
        await c.ws.close()
        await asyncio.sleep(55)  # Beyond the native 20-second orphan grace and 35-second tool.
        await c.connect()
        restored=await c.rpc('session.resume',{'profile':'default','session_id':session['stored_session_id'],'close_on_disconnect':False})
        assert not restored.get('running'), 'Task did not finish while disconnected'
        messages=restored['messages']
        assert sum(m.get('role')=='user' and marker in m.get('text','') for m in messages)==1,messages
        answers=[m for m in messages if m.get('role')=='assistant' and 'le fil est retrouvé.' in m.get('text','')]
        assert len(answers)==1,[(m.get('role'),m.get('text','')[:100]) for m in messages]
        assert not restored.get('inflight',{}).get('error'),restored.get('inflight')
        print('PASS tool and model completed on Hermes with no client; one user message, one final answer, native resume',flush=True)
        await c.ws.close()
if __name__=='__main__': asyncio.run(main())
