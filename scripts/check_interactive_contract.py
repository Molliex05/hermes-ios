#!/usr/bin/env python3
"""Test actual Hermes server-to-client requests, reconnect snapshots and per-question locks."""
import asyncio
import httpx
from check_hermes_contract import BASE, Client

async def main():
    async with httpx.AsyncClient(base_url=BASE, timeout=60) as http:
        (await http.post('/auth/password-login',json={'provider':'basic','username':'hermes-ios-test','password':'hermes-ios-local-fixture'})).raise_for_status()
        c=Client(http); await c.connect()
        session=await c.rpc('session.create',{'profile':'default'})
        sid=session['session_id']
        await c.rpc('prompt.submit',{'session_id':sid,'text':'HERMES_IOS_REQUEST_TEST'})
        while not any(r['method']=='clarify' for r in c.requests): await c.read()
        request=next(r for r in c.requests if r['method']=='clarify')
        assert request['id'].startswith('srq-') and request['params']['session_id']==sid
        first,second=request['params']['questions']
        locked=await c.rpc('clarify.lock',{'request_id':request['id'],'question_id':first['qid'],'answer':'Bleu'})
        assert locked=={'status':'ok','remaining':['q1']},locked
        await c.ws.close(); await c.connect()
        resume=await c.rpc('session.resume',{'profile':'default','session_id':session['stored_session_id'],'omit_messages':True})
        open_request=next(r for r in resume['open_requests'] if r['id']==request['id'])
        assert open_request['params']['answers'][first['qid']]=='Bleu'
        final=await c.rpc('clarify.lock',{'request_id':request['id'],'question_id':second['qid'],'answer':'Simple et fluide'})
        assert final=={'status':'ok','remaining':[]},final
        while not any(e['type']=='message.complete' and e.get('session_id')==sid for e in c.events): await c.read()
        result=await c.rpc('request.answer',{'id':request['id'],'result':{'answer':'Too late'}})
        assert result['status']=='expired',result
        info=await c.rpc('session.resume',{'profile':'default','session_id':session['stored_session_id'],'omit_messages':True})
        assert not info.get('open_requests'),info.get('open_requests')
        assert not any(e['type']=='message.error' for e in c.events)
        print('PASS actual clarify request, acknowledged answer, reconnect with accepted locks, completion and late-answer expiry',flush=True)
        await c.ws.close()
if __name__ == '__main__': asyncio.run(main())
