# Feature coverage

Hermès iOS remains a native client of Hermes. No proxy, replacement scheduler, sync backend is introduced; native WebRTC is the one added iOS runtime dependency. Hermes 0.21.7 (`71d34bad`, the deployed version) is the source audited against the typed contract catalog and used for the isolated integration suite since 2026-10-13.

| Area | Available | Remaining limits |
| --- | --- | --- |
| Navigation | Send/stop beside the text; attachments, profile, history, tools and voice inside the composer; conversation title in the header; pinned/recent agent picker; up to three persistent editable tool shortcuts; searchable complete catalogue | Favorites and recent visits are local to this iPhone; no bottom tab bar or unified multi-server roster |
| Interactive requests | New bidirectional approval/clarify/sudo/secret and vault value prompts; session/always choices only when offered; reconnect snapshots, per-question acknowledged locks, cancellation and expiry; legacy event support | Unsupported interactive methods receive a JSON-RPC error rather than hanging or being automatically approved |
| Permissions | Profile approval policy explained in plain language, common controls first and detailed rules in advanced settings; schema-driven preferences, toolset toggles, MCP HTTP creation/toggles/removal | Hermes remains responsible for permission enforcement; MCP OAuth and platform-specific user permissions have no dedicated mobile wizard |
| Agent settings | Desktop-parity pages for any profile (model, fallbacks, auxiliary tasks, MoA, conversation, workspace, safety, browser, memory, voice, advanced, other fields) with native controls, defaults, reset and search; keys and credentials (write-only, per-profile `.env`), providers (OAuth device codes, custom endpoints), messaging platforms and pairing, extensions; grouped as Essentiel / Connexions / Avancé; « Mes agents » in the menu across profiles and saved servers | External OAuth flows (Anthropic, Qwen, Copilot) and WhatsApp QR pairing still need the server/desktop; secret values are never revealed |
| History/chat | Remote content search, paginated older conversations, All/Unread/Archives filters, local persistent reading markers, rename, archive/restore, branch, compress, native command.dispatch/slash.exec routing; expandable live tool activity | Reading state is not synchronized with desktop/other phones; native search returns at most 100 hits; no edit/regenerate or rich tool-result/usage panels; /new and /reset direct the user to the existing New Conversation control |
| Bot Mode | Canonical Bot Chat, profile switching/creation/personality editing, display name, pin, hide, profile deletion; pinned/recent sections and local unread indicators | No avatars, native mention routing, server-synced sections or unified multi-server roster; only one active connection |
| Groups | Native local groups, log-based messages, stop, pending once/deny approvals, explicit uncertain-task retry, rename/disband | No member management, reply threads, attachments or cross-gateway routing UI; group tokens remain log-based |
| Cron | Create/list/pause/resume/edit/delete/trigger; daily/weekday/weekly/hourly controls, advanced native schedules, readable next-run times and recent run summaries; open a completed run's native conversation | Server owns schedule validation, timezone and execution; result navigation requires a native stored-session ID; no execution log editor |
| Kanban | Boards, filters, triage creation, title/body/assignment/status editing, comments, result Markdown | Server owns dispatch and dependencies; worker orchestration controls and decomposition are not exposed |
| Skills | Read/toggle/create/edit; native hub install/update/uninstall | Hub-only uninstall; locally authored/bundled skills use disable; native CLI output is displayed because CLI exit zero can still report refusal |
| Workspace/memory | Create/edit projects, choose conversation cwd, browse/read/edit server text files, profile MEMORY.md/USER.md | Binary/truncated files stay read-only; missing memory files are not created automatically; check-before-write is not atomic CAS |
| Models/config | Existing main-model chooser plus schema-driven profile settings, including reasoning/auxiliary fields exposed by Hermes | No dedicated provider authentication or current-session model switch |
| Voice | Automatic listening → live STT (`transcribe-stream`, upload fallback) → agent on the fast `voice_chat` route → incremental PCM speech opened before the answer; barge-in while thinking or speaking; profile provider/voice and fallback synthesis; duplex microphone/playback, native-setting-controlled spoken interruption with pre-roll, mute/restart and end-call controls; expandable transcript and isolated Canvas animation | Native GPT-Live/WebRTC with Stone/French selection, delegated Hermes turns, streamed commentary and per-call standard fallback; key required on the profile’s server; real microphone, Bluetooth and speaker echo behavior need physical iPhone validation |
| Widgets and Live Activities | Noriven finance widget (month revenue, expenses, profit, MRR, projection) and voice launcher widget; Live Activities for calls (mute, end) and for replies in progress (stop), stale after 110 s without confirmation and cleaned up at launch; silent push refreshes the widgets | Needs the `hermes-widgets` and `hermes-ios-push` plugins ([SERVER_PLUGINS.md](SERVER_PLUGINS.md)); the snapshot is shared through a keychain access group; no Apple Watch app |
| Agent tools | Plugins give Jarvis Gmail (read, drafts, folders, archive) and Google Calendar (all calendars read, main calendar create/modify/delete), weather, Noryv figures through MCP; Hermès reads Noriven figures | Never sends or deletes mail, never writes to work or shared calendars; see [SERVER_PLUGINS.md](SERVER_PLUGINS.md) |
| Background | Native agent execution persists on the server; reconnect/replay/cache on return | Optional APNs extension + exact conversation routing; requires Apple key, push-capable signing and server activation (see NOTIFICATIONS.md) |

## Concurrency and scope

Management panels capture the connection and profile that opened them. Requests reject a changed active scope. Partial configuration writes preserve unrelated keys. Bot presentation updates merge the latest namespace and use Hermes’ metadata revision check where available. Successful server acknowledgements are required before clearing answers. Secrets and open request frames stay in memory, outside the transcript cache.

Skills and text files are re-read before saving to detect another editor’s changes. These checks reduce lost edits but are not a substitute for a server-side atomic revision API.

## Local presentation state

Reading markers and recent profile visits are stored with the saved gateway cache and scoped by profile and stored session ID. Initial history establishes a quiet baseline. Native message counts take precedence over preview text; refresh timestamps and heartbeats alone do not create unread activity. A chat is marked read only when it is visible near the bottom and its native attachment has succeeded. Opening a management sheet or a failed connection attempt does not clear the marker. Archiving a conversation clears its local unread marker.

“In progress” is reserved for the selected conversation with an actual running turn. A pending native approval, clarification or credential request takes priority. The tool activity summary keeps at most 40 steps from the live/replayed turn. It is reset with the turn/conversation and is not saved in the transcript cache.

Tool favorites use local app preferences and retain their chosen order. They supplement the catalogue; they never remove a destination. Routine schedule controls generate native Hermes expressions rather than running a client scheduler. Existing custom and one-shot schedules remain unchanged when only a routine's text is edited. Times selected for a schedule follow Hermes' profile timezone; the returned next-run timestamp is displayed in the iPhone's timezone.

## Voice behavior and boundaries

The conversation starts automatically and does not pause after 15 seconds of silence. Speech endpoint detection uses the profile's native threshold and silence duration. Quiet recordings rotate within a two-minute bound. A duplex `AVAudioEngine` with Apple voice processing leaves input monitoring available during playback. Native barge-in preferences control interruption; a 750 ms pre-roll preserves the detected onset, and a previous server turn must finish or acknowledge interruption before another is submitted. Mute discards the current microphone capture and pre-roll while allowing playback to continue. Ending the call stops local audio; an accepted agent turn may still finish in chat.

Audio graph/session changes, WAV encoding, conversion and file decoding run on a serial worker rather than MainActor. The microphone capture is mono Int16, bounded to 120 seconds: approximately 11.5 MB of raw samples at 48 kHz or 23 MB at 96 kHz, excluding encoding/copy overhead and other app memory. Decoded PCM playback is queued in small chunks with approximately 3.2 seconds of backpressure. The decorative Canvas has a 24 fps clock, is isolated from the transcript and controls, and stops animated motion when inactive or Reduce Motion is enabled.

The isolated simulator fixture has exercised an 18-second quiet start, two automatic turns and preservation of the written draft. It uses synthetic input and does not validate acoustic echo cancellation or Bluetooth behavior. See [validation results](VALIDATION.md) for the tested scope.

## Sources

- [Native integration protocol](https://hermes-agent.nousresearch.com/docs/developer-guide/programmatic-integration)
- [Permissions and security](https://hermes-agent.nousresearch.com/docs/user-guide/security)
- [Bot Mode](https://hermes-agent.nousresearch.com/docs/user-guide/bot-mode)
- [Cron](https://hermes-agent.nousresearch.com/docs/user-guide/features/cron)
- [Kanban](https://hermes-agent.nousresearch.com/docs/user-guide/features/kanban)
- [Voice](https://hermes-agent.nousresearch.com/docs/guides/use-voice-mode-with-hermes)
