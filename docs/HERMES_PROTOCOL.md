# Hermes protocol research

Research date: **2026-09-12**. Source revision: [`b7b35a84b7fbe1aa2e223a6ce726a2471300d0a4`](https://github.com/NousResearch/hermes-agent/tree/b7b35a84b7fbe1aa2e223a6ce726a2471300d0a4), package version **0.21.2**.

The official [full documentation corpus](https://hermes-agent.nousresearch.com/docs/llms-full.txt) was downloaded and indexed: 214 source pages, 82,956 lines, 4,284,592 bytes. Detailed implementation review focused on the sections relevant to a mobile client, then checked each wire contract against official source. The large reference checkout and corpus are local research outputs, excluded from this repository.

## Documentation reviewed for client design

- [Quickstart](https://hermes-agent.nousresearch.com/docs/getting-started/quickstart), installation and updating: keep the runtime independent of the client.
- [Desktop](https://hermes-agent.nousresearch.com/docs/user-guide/desktop): `hermes serve`, remote connections, password/OAuth auth and Tailscale.
- [Web dashboard](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard): auth, REST surfaces and `/api/ws`.
- [Profiles](https://hermes-agent.nousresearch.com/docs/user-guide/profiles), [sessions](https://hermes-agent.nousresearch.com/docs/user-guide/sessions) and [multi-connection desktop](https://hermes-agent.nousresearch.com/docs/user-guide/multi-connection-desktop): separate owners and persistent history.
- [Bot Mode](https://hermes-agent.nousresearch.com/docs/user-guide/bot-mode): a Bot is a profile; canonical chats, routines, mentions, groups and capability settings.
- [Memory](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory), [skills](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills), [personality](https://hermes-agent.nousresearch.com/docs/user-guide/features/personality), [tools](https://hermes-agent.nousresearch.com/docs/user-guide/features/tools) and [security](https://hermes-agent.nousresearch.com/docs/user-guide/security): server-owned behavior, not a client-side reimplementation.
- [Cron](https://hermes-agent.nousresearch.com/docs/user-guide/features/cron), [heartbeat](https://hermes-agent.nousresearch.com/docs/user-guide/features/heartbeat), [delegation](https://hermes-agent.nousresearch.com/docs/user-guide/features/delegation), integrations and environment-variable references: distinguish client controls from runtime processes.

## Native API map

| Purpose | Wire contract used by Hermès iOS | Official source |
| --- | --- | --- |
| Discover login | `GET /api/status` | `hermes_cli/web_server.py`, status router |
| Password login | `POST /auth/password-login {provider:"basic",username,password}` → native cookies | `hermes_cli/dashboard_auth/routes.py` |
| WebSocket authorization | `POST /api/auth/ws-ticket` → 30-second, single-use ticket | `hermes_cli/dashboard_auth/routes.py`, `ws_tickets.py` |
| Native socket | `/api/ws?ticket=…`; newline-delimited JSON-RPC text envelopes, potentially several per WS message | `hermes_cli/web_routers/chat_ws.py`, `tui_gateway/ws.py` |
| Liveness | `ping`; `gateway.ready` advertises epoch/change events | `tui_gateway/methods_voice.py`, `ws.py` |
| Profiles | `profiles.list`, `.create`, `.describe`, `.configure` | `tui_gateway/methods_profiles.py` |
| Sessions | `session.list`, `.create`, `.resume`, `.history`, `.title`, `.interrupt` | `tui_gateway/methods_session.py` |
| Turn | `prompt.submit {session_id,text}`; `message.start/delta/interim/complete` | `tui_gateway/methods_prompt.py`, `prompt_turn.py` |
| Replay | `session.events.since {session_id,last_seen}` → `{events,latest_seq,truncated,epoch}` | `tui_gateway/event_replay.py`, `methods_session.py` |
| User decisions | `approval.respond`, `clarify.respond`, `sudo.respond`, `secret.respond` | `tui_gateway/methods_prompt.py`, `server.py` |
| Routines | `cron.manage {profile,action,…}`; list uses `job_id`, not internal DB `id` | `tui_gateway/methods_tools.py`, `tools/cronjob_job_args.py` |
| Groups | `groups.capabilities/list/create/log/send/stop`; log uses `since_seq`, send uses `event_id` and `{text,thread_id}` | `tui_gateway/methods_groups.py`, `gateway/hosted_room_discussion.py` |

All source paths above refer to the [pinned official repository](https://github.com/NousResearch/hermes-agent/tree/b7b35a84b7fbe1aa2e223a6ce726a2471300d0a4). This is a compatibility record, not a promise that upstream private wire shapes are permanently stable.

## Identity and protocol details that matter

- `session.create` returns both `session_id` (runtime) and `stored_session_id` (persistent). Resume may return persistent identity as `session_key` and a different runtime ID. Treating these as one ID breaks reconnects.
- A canonical Bot Chat is resolved through the exact native title **`Bot Chat`** in its owning profile, including hidden sessions and compression tips. New sessions are lazy; `session.title` materializes the canonical row before any first prompt. If another writer wins the title, re-read and adopt the native winner.
- `profiles.list` exposes `canonical_session` and `bot_mode_protocol`. The backend supplies its Bot Mode protocol; Hermès iOS must not append its own standing instructions to SOUL.
- `seq` is scoped to a runtime session, and resets after a server restart. Epoch changes require resetting the watermark. Replay returns event objects, not full JSON-RPC envelopes.
- Native auth middleware can rotate cookies during an authenticated request. Hermès iOS persists updated cookies without storing the password.
- Batch clarification answers use **`question_id`**, while the individual question is advertised with **`qid`**.
- `cron.manage list` confirms its owner through `scoped`; Hermès iOS refuses profile management when an older backend does not prove that scope.
- Group orchestration is hosted by Hermes. Older desktop-local group machinery is not recreated in Hermès iOS. The current mobile surface is limited to the native same-gateway hosted protocol.

## Why not the OpenAI-compatible API?

The `/v1/*` integration is useful for OpenAI-compatible clients but is not the desktop session/profile protocol. The mobile app needs existing Hermes conversations, permissions, canonical Bot Chats and durable group semantics. Using the official desktop/TUI gateway preserves those primitives and avoids introducing a synchronization bridge.

## Mobile tools (same upstream revision)

| Surface | Native interface | Scope and behavior |
| --- | --- | --- |
| Skills | GET `/api/skills`, GET `/api/skills/content?name=…`, PUT `/api/skills/toggle` | Explicit `profile` query on every request; read instructions and enable/disable |
| Models | GET `/api/model/options`, POST `/api/model/set` | Profile scoped; `scope: main`; applies to new sessions; honor `confirm_required` before retrying with `confirm_expensive_model` |
| Workspace | RPC `projects.list` | Profile scoped; projects include `folders`, `primary_path`, `board_slug` |
| Kanban | GET `/api/plugins/kanban/boards`, `/board`, `/tasks/{id}`; POST `/tasks` | Explicit `board` query; shared board data; task creation uses `triage: true` and a retained `idempotency_key` |
| Voice transcription | POST `/api/audio/transcribe` | Profile scoped JSON `data_url` + `mime_type: audio/mp4`; result `transcript` |
| Speech playback | POST `/api/audio/speak` | Profile scoped `{text}`; result base64 `data_url`; provider credentials remain on Hermes |

These contracts come from `hermes_cli/web_routers/{skills,models,audio}.py`, `tui_gateway/methods_projects.py`, `plugins/kanban/dashboard/plugin_api.py` and the official desktop Kanban client. The server’s `voice.record` captures the **server** microphone, so it is deliberately not used for iPhone recording. The mobile voice screen chains transcription → `prompt.submit` → profile speech playback → listening. It reads `config.get {key: "full", profile}` over the existing native RPC connection for silence/stop-phrase settings and `voice.voice_chat_mode`. Standard voice does not depend on `/api/config` or the optional `/api/audio/voice-live/status` route. Missing required transcription/speech endpoints produce an explicit compatibility message; authentication failures remain authentication errors. `/api/audio/tts-lease` is acquired per call and released on exit. It does not fetch `/api/audio/voice-config`, which exposes client-direct provider credentials. GPT-Live/WebRTC and automatic barge-in remain unsupported; a configured GPT-Live profile is offered an explicit temporary standard-voice call.

## Media attachments

`file.attach {session_id, name, data_url}` returns `{attached, path, ref_text}`. Files use the exact native `ref_text` in `prompt.submit`. Images are staged by the same native upload, then queued with `image.attach {session_id, path: fileURL}`. `image.detach {session_id, path}` clears only known app-owned queued paths before retrying an interrupted upload; no speculative prompt retry occurs. Photo/file draft data stays local until Send. Limits: four files, 10 MiB each; library photos become 3072px JPEGs.

Sources: [native prompt and attachment methods](https://github.com/NousResearch/hermes-agent/blob/main/tui_gateway/methods_prompt.py), [audio routes](https://github.com/NousResearch/hermes-agent/blob/main/hermes_cli/web_routers/audio.py), [voice guide](https://hermes-agent.nousresearch.com/docs/guides/use-voice-mode-with-hermes).

The isolated `scripts/check_media_contract.py` probe validates staging, path quoting, attach/detach retry, file references and STT → native agent → TTS for two profiles. The fixture redirects configured STT/TTS to a loopback provider and reports the selected voices; it does not exercise real microphone hardware or paid providers.
