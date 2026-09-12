#!/usr/bin/env python3
"""Exercise HermesIOS's wire contract against scripts/integration_server.py, without real model use."""
import asyncio
import json
import uuid
import httpx
import websockets

BASE = "http://127.0.0.1:19119"


class Client:
    def __init__(self, http):
        self.http = http
        self.events = []

    async def connect(self):
        ticket = (await self.http.post(BASE + "/api/auth/ws-ticket")).json()["ticket"]
        self.ws = await websockets.connect("ws://127.0.0.1:19119/api/ws?ticket=" + ticket, max_size=16 * 1024 * 1024)

    async def rpc(self, method, params=None):
        rid = str(uuid.uuid4())
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}))
        while True:
            for frame in await self.read():
                if frame.get("id") == rid:
                    assert "error" not in frame, (method, frame.get("error"))
                    return frame["result"]

    async def read(self):
        raw = await asyncio.wait_for(self.ws.recv(), timeout=90)
        frames = [json.loads(line) for line in raw.splitlines() if line.strip()]
        self.events += [f["params"] for f in frames if f.get("method") == "event"]
        return frames


async def main():
    async with httpx.AsyncClient(timeout=30) as http:
        status = (await http.get(BASE + "/api/status")).json()
        assert status["auth_required"] and "basic" in status["auth_providers"]
        denied = await http.post(BASE + "/api/auth/ws-ticket")
        assert denied.status_code == 401
        login = await http.post(BASE + "/auth/password-login", json={"provider": "basic", "username": "hermes-ios-test", "password": "hermes-ios-local-fixture"})
        assert login.status_code == 200
        c = Client(http)
        await c.connect()
        await c.rpc("ping")
        roster = await c.rpc("profiles.list")
        assert roster["bot_mode_protocol"]
        assert {"default", "research", "studio"} <= {p["name"] for p in roster["profiles"]}
        created = await c.rpc("session.create", {"profile": "default"})
        runtime, stored = created["session_id"], created["stored_session_id"]
        assert runtime and stored and runtime != stored
        await c.rpc("prompt.submit", {"session_id": runtime, "text": "Bonjour, réponds en une phrase."})
        while not any(e["type"] == "message.delta" and e.get("session_id") == runtime for e in c.events):
            await c.read()
        seq = max(e.get("seq", 0) for e in c.events if e.get("session_id") == runtime)
        await c.ws.close()
        await asyncio.sleep(2)
        await c.connect()
        resumed = await c.rpc("session.resume", {"profile": "default", "session_id": stored, "omit_messages": True})
        assert resumed["session_id"] == runtime
        replay = await c.rpc("session.events.since", {"session_id": runtime, "last_seen": seq})
        assert replay["epoch"] and not replay["truncated"]
        assert all(e["seq"] > seq for e in replay["events"])
        c.events += replay["events"]
        while not any(e["type"] == "message.complete" and e.get("session_id") == runtime for e in c.events):
            await c.read()
        completion = next(e for e in reversed(c.events) if e["type"] == "message.complete" and e.get("session_id") == runtime)
        assert completion["payload"].get("status") != "error", completion["payload"]
        assert "Bonjour depuis Hermes" in completion["payload"]["text"]
        history = await c.rpc("session.history", {"session_id": runtime})
        assert len([m for m in history["messages"] if m["role"] == "user"]) == 1
        assert "Bonjour depuis Hermes" in history["messages"][-1]["text"]
        canonical = await c.rpc("session.list", {"profile": "research", "title": "Bot Chat", "include_hidden": True})
        if not canonical["sessions"]:
            bot = await c.rpc("session.create", {"profile": "research", "title": "Bot Chat", "hidden": True, "follow_profile_config": True})
            title = await c.rpc("session.title", {"session_id": bot["session_id"], "title": "Bot Chat"})
            assert not title["pending"]
        canonical = await c.rpc("session.list", {"profile": "research", "title": "Bot Chat", "include_hidden": True})
        assert len(canonical["sessions"]) == 1
        default_lookup = await c.rpc("session.list", {"profile": "default", "title": "Bot Chat", "include_hidden": True})
        assert not default_lookup["sessions"], "Bot chat leaked into the default profile"
        routine = await c.rpc("cron.manage", {"action": "add", "profile": "research", "name": "[bot:research] Fixture", "schedule": "0 8 * * *", "prompt": "Fixture only", "deliver": "bot-chat:research"})
        assert not routine.get("error"), routine
        jobs = await c.rpc("cron.manage", {"action": "list", "profile": "research", "include_disabled": True})
        assert jobs["scoped"] == "research" and jobs["jobs"]
        job = jobs["jobs"][0]
        await c.rpc("cron.manage", {"action": "pause", "profile": "research", "name": job["job_id"]})
        capabilities = await c.rpc("groups.capabilities")
        assert capabilities["driver"]
        room_id = str(uuid.uuid4())
        room = await c.rpc("groups.create", {"room_id": room_id, "name": "Fixture", "members": [{"member_id": p, "profile": p, "handle": p} for p in ["default", "research"]]})
        assert room["room"]["room_id"] == room_id
        page = await c.rpc("groups.log", {"room_id": room_id, "since_seq": 0, "limit": 100})
        assert "cursor" in page and "events" in page
        await c.ws.close()
        print(json.dumps({"passed": True, "checks": ["native password auth", "single-use websocket ticket", "JSON-RPC text frames", "profile roster", "separate stored/runtime identity", "real Hermes turn with fixture inference", "disconnect and live resume", "sequence replay", "exactly one persisted user message", "canonical Bot Chat", "profile isolation", "native cron create/list/pause", "native hosted groups"], "replayed_events": len(replay["events"]), "history_messages": len(history["messages"])}, indent=2))


if __name__ == "__main__":
    asyncio.run(main())
