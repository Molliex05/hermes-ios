"""Loopback-only WebRTC provider for the isolated, unmodified Hermes gateway.

No OpenAI account or microphone recording is used. The real iOS peer exchanges
SDP, audio tracks and data-channel messages with aiortc. Never deploy this module.
"""
import asyncio
import json
import threading

from aiortc import RTCPeerConnection, RTCSessionDescription, RTCConfiguration


class LiveFixture:
    def __init__(self):
        self.loop = asyncio.new_event_loop()
        self.peers = set()
        threading.Thread(target=self.loop.run_forever, daemon=True).start()

    def answer(self, body):
        return asyncio.run_coroutine_threadsafe(self._answer(body), self.loop).result(30)

    async def _answer(self, body):
        session = body["session"]
        assert session["model"] == "gpt-live-1"
        assert session["delegation"] == {"type": "client"}
        assert body["transport"]["sdp"].endswith("\r\n"), "SDP must retain CRLF"
        peer = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        self.peers.add(peer)

        @peer.on("track")
        def track(track):
            async def drain():
                try:
                    while True:
                        await track.recv()
                except Exception:
                    pass
            asyncio.create_task(drain())

        @peer.on("datachannel")
        def channel_ready(channel):
            assert channel.label == "oai-events"
            def send(type, **fields):
                if channel.readyState == "open":
                    channel.send(json.dumps({"type": type, **fields}))

            @channel.on("message")
            def message(raw):
                event = json.loads(raw)
                kind = event["type"]
                print("LIVE FIXTURE received " + kind, flush=True)
                if kind in {"session.commentary.append", "session.thinking.append", "session.instructions.append"}:
                    # Delayed, correlated receipt: writing to the channel isn't delivery.
                    self.loop.call_later(.2, lambda: send(kind + "ed", client_event_id=event["event_id"], start_ms=2000, end_ms=3000))
                if kind == "session.commentary.append":
                    assert len(event["content"].encode()) <= 480
                    assert event["delegation_id"] == "fixture-first"
                    send("session.output_transcript.delta", delta=event["content"], start_ms=3000, end_ms=4000)
                elif kind == "session.close":
                    send("session.closed", reason="close_requested")
                    asyncio.create_task(peer.close())

            async def conversation():
                await asyncio.sleep(0.3)
                send("session.started", session={"id": "fixture-live"})
                await asyncio.sleep(1)
                send("session.input_transcript.delta", delta="Bonjour Hermes, résume ", start_ms=0, end_ms=500)
                send("session.input_transcript.delta", delta="mon projet en français.", start_ms=500, end_ms=1000)
                send("session.delegation.created", offset_ms=1000, delegation={"id": "fixture-first", "type": "client", "target": "hermes"})
                # Duplicate delivery must never submit the user's prompt twice.
                send("session.delegation.created", offset_ms=1000, delegation={"id": "fixture-first", "type": "client", "target": "hermes"})
            asyncio.create_task(conversation())

        @peer.on("connectionstatechange")
        async def changed():
            if peer.connectionState in {"failed", "closed"}:
                await peer.close()
                self.peers.discard(peer)

        await peer.setRemoteDescription(RTCSessionDescription(sdp=body["transport"]["sdp"], type="offer"))
        await peer.setLocalDescription(await peer.createAnswer())
        print("LIVE FIXTURE session voice=" + session["audio"]["output"]["voice"], flush=True)
        return {"session": {"id": "fixture-live"}, "transport": {"type": "webrtc", "sdp": peer.localDescription.sdp}}
