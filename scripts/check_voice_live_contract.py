#!/usr/bin/env python3
"""Profile-scoped GPT-Live contract against the disposable localhost fixture."""
import asyncio
import json

import httpx
from aiortc import RTCPeerConnection, RTCSessionDescription, RTCConfiguration
from check_hermes_contract import BASE, Client


async def main():
    async with httpx.AsyncClient(base_url=BASE, timeout=45) as http:
        denied = await http.get("/api/audio/voice-live/status")
        assert denied.status_code == 401
        (await http.post("/auth/password-login", json={"provider": "basic", "username": "hermes-ios-test", "password": "hermes-ios-local-fixture"})).raise_for_status()
        client = Client(http)
        await client.connect()
        for profile in ["research", "studio"]:
            scoped = {"profile": profile}
            status = (await http.get("/api/audio/voice-live/status", params=scoped)).json()
            assert status["available"] and status["model"] == "gpt-live-1"
            assert "local-fixture-only" not in json.dumps(status)
            # The small native settings patch must not replace provider config or secrets.
            (await http.put("/api/config", params=scoped, json={"config": {"voice": {"voice_chat_mode": "gpt-live", "gpt_live": {"voice": "stone"}}}})).raise_for_status()
            status = (await http.get("/api/audio/voice-live/status", params=scoped)).json()
            assert status["available"] and status["voice"] == "stone"
            peer = RTCPeerConnection(RTCConfiguration(iceServers=[]))
            peer.addTransceiver("audio", direction="sendrecv")
            channel = peer.createDataChannel("oai-events")
            events = []
            channel.on("message", lambda raw: events.append(json.loads(raw)))
            try:
                await peer.setLocalDescription(await peer.createOffer())
                response = await http.post("/api/audio/voice-live/session", params=scoped, json={"sdp": peer.localDescription.sdp, "history": []})
                response.raise_for_status()
                payload = response.json()
                assert "local-fixture-only" not in json.dumps(payload)
                await peer.setRemoteDescription(RTCSessionDescription(sdp=payload["transport"]["sdp"], type="answer"))
                async with asyncio.timeout(15):
                    while not any(e["type"] == "session.delegation.created" for e in events):
                        await asyncio.sleep(.05)
                assert any(e["type"] == "session.started" for e in events)
                prompt = "".join(e["delta"] for e in events if e["type"] == "session.input_transcript.delta")
                chat = await client.rpc("session.create", {"profile": profile})
                runtime = chat["session_id"]
                await client.rpc("prompt.submit", {"session_id": runtime, "text": prompt, "surface": "voice-live", "voice_context": "User: " + prompt})
                while not any(e["type"] == "message.complete" and e.get("session_id") == runtime for e in client.events):
                    await client.read()
                reply = next(e for e in client.events if e["type"] == "message.complete" and e.get("session_id") == runtime)["payload"]["text"]
                assert "Bonjour depuis Hermes" in reply
                channel.send(json.dumps({"type": "session.commentary.append", "event_id": "fixture-result", "delegation_id": "fixture-first", "content": reply[:200]}))
                async with asyncio.timeout(5):
                    while not any(e["type"] == "session.output_transcript.delta" for e in events):
                        await asyncio.sleep(.05)
                channel.send(json.dumps({"type": "session.close"}))
                print("PASS " + profile + ": authenticated SDP, WebRTC events, native delegation, reply, secret isolation")
            finally:
                await peer.close()
        await client.ws.close()


if __name__ == "__main__":
    asyncio.run(main())
