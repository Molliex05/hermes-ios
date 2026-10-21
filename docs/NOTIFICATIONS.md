# Notifications iPhone

Hermès iOS uses **visible Apple Push Notifications (APNs)**. The Mac runs Hermes and sends the alert; the iPhone does not need an open WebSocket, a background polling task, or a running app. Tapping the alert selects the saved server, profile and native stored conversation. Tailscale must be connected when the app fetches the conversation from a private server.

## Current activation requirements

The iOS client and the optional `server/hermes-ios-push` extension are included in this repository. Actual iPhone delivery requires all of the following:

1. An explicit Apple App ID for the app's bundle identifier with **Push Notifications** enabled, and a provisioning profile that contains `aps-environment`. A wildcard development profile does not support push. Connect the developer account in Xcode and use automatic signing, or supply a matching profile.
2. An APNs signing key from that Apple Developer team. Keep the `.p8` file **on the server only**, outside this repository. Never bundle it into the iOS application or publish it.
3. The extension installed and enabled in the Hermes server and in each profile whose conversations should send notifications.
4. User consent in iOS: **Réglages → Notifications** in Hermès iOS, then enable the desired server.

The app shows a configuration error rather than claiming notifications work when the extension or Apple setup is missing. Registering a token confirms registration, not successful delivery through Apple; a real device test is still required.

## Server setup

Use the same Python environment as the installed Hermes server:

```sh
python -m pip install -r /path/to/hermes-ios/server/hermes-ios-push/requirements.txt
hermes plugins install /path/to/hermes-ios/server/hermes-ios-push
hermes plugins enable hermes-ios-push
```

Hermes plugins are scoped by profile. Install/enable the same extension for each desired named profile with `hermes -p PROFILE plugins install …` and `hermes -p PROFILE plugins enable hermes-ios-push`. Do not replace an existing profile's plugin allow-list. Restart the server and affected agent surfaces when idle so they discover the new plugin; do not interrupt an ongoing turn to install it.

Place a private JSON configuration at `<Hermes root>/ios-push/apns.json`:

```json
{
  "team_id": "YOUR_APPLE_TEAM_ID",
  "key_id": "YOUR_APNS_KEY_ID",
  "key_path": "/absolute/private/path/AuthKey.p8"
}
```

Restrict this directory and the key to their owner. The optional `HERMES_IOS_PUSH_HOME` environment variable overrides the state directory; it must be the same for the server and all agent/cron processes. Each independent Hermes root has its own device registrations and queue. The fixed APNs topic is `org.hermesios.HermesIOS`; forks using another bundle identifier must also change `TOPIC` in `push_service.py`.

The extension uses Hermes' documented backend plugin namespace `/api/plugins/hermes-ios-push/` behind existing dashboard authentication. It adds no publicly listening port. The server requires outbound HTTPS/HTTP2 access to Apple on port 443. An authenticated `GET …/status` reports whether its key and dependencies are configured locally.

## Behavior and privacy

- The official `post_llm_call` observer records a completed answer. It never submits, resumes, interrupts or claims an agent session.
- Raw cron executions are skipped. A cron delivered to `bot-chat:PROFILE` starts Hermes' native destination turn; the notification names **that Bot Chat**, not the cron's internal run. A cron configured for local-only output does not create a chat notification.
- Successful CLI, TUI, Desktop and web conversation completions are supported. Tool progress, subagent/internal turns, failed turns and individual tokens do not generate notifications. Approval/question alerts are not included in this first version.
- The Apple payload contains a generic alert plus the opaque event, saved-connection, profile and stored-session identifiers. Since v0.2 the readable preview travels only inside `hermes.enc`, encrypted with the device's key (see below); a device registered without a key receives the generic v0.1 alert. Credentials and server URL are never sent to Apple by this extension.
- Device tokens and a small outbox are persisted privately on the Mac. Turn IDs deduplicate repeated callbacks. Transient Apple/network failures back off; alerts expire after 24 hours. Invalid registrations are removed without deleting a newer rotated token. APNs delivery is best effort; iOS Focus and user settings still apply.
- Disabling a server's notifications revokes the registration on that server. Removal of a saved connection first revokes its subscription. An alert already delivered to iOS may remain in Notification Center.
- Development-signed apps use APNs sandbox even when built in Release. Distribution uses production. The app reads its signed provisioning profile, rather than guessing from the build configuration.
- Tapping an old notification never sends a message. Unknown/removed servers show an explanation. Cold-launch taps wait for cache restoration, preserve drafts, and select the explicit profile/session before native resync.

## Server v0.2: encrypted preview, presence and `ios_notify`

Wire contract: `outputs/notif-v2-2026-10-14/CONTRACT.md`; shared AES-GCM vector: `vector.json` (same folder).

- **Registration.** `PUT /devices` accepts an optional `key` (base64 of 32 bytes). It is validated and stored as a BLOB in its own table `device_keys` of `notifications.sqlite` (mode 600, `secure_delete` on; the `devices` table is untouched, so v0.1 code still runs on a migrated database); a new registration replaces it, one without `key` clears it (generic v0.1 alert). `DELETE /devices/…`, or an Apple 410 / `BadDeviceToken`, deletes the row, its key, its queued ciphertext and its presence. Validation errors are produced without echoing the request, so a key never comes back in a 422. The key is never logged.
- **Encryption.** At enqueue time each device row gets its own ciphertext (`enc`): AES-256-GCM, random 12-byte nonce, AAD = UTF-8 `event_id`, `base64(nonce || ciphertext || tag)`, plaintext `{"agent","conversation","preview"}`. The outbox therefore never stores clear text; sent, failed and suppressed rows drop their ciphertext. The whole APNs JSON stays under 4096 bytes: the preview is shortened to fit, and if even that is impossible the generic alert is sent (a send is never refused for size).
- **Content.** Agent = `ui_meta.hermes-bots.title`, else `display_name`, else the profile name (read with Hermes' own `read_profile_meta`); conversation = native session title (`state.db`) or « Conversation »; preview = start of the final answer, Markdown stripped, whitespace collapsed, cut at about 140 characters with « … ».
- **Payload.** `aps.mutable-content = 1`, alert « Hermès » / « Nouveau message » when encrypted; `hermes.kind` is `turn` (automatic) or `tool` (`ios_notify`). Without `session_id`, `thread-id` is the SHA-256 of `connection:profile`.
- **Presence.** `PUT /presence` `{installation_id, connection_id, profile, session_id, ttl}` (ttl clamped to 5…120 s, integers only); `DELETE /presence` with the same fields in the body or the query string. The worker (`deliver_pending`) asks the store right before each send; a live presence of the same installation, connection, profile and session turns the row into `suppressed` and nothing goes to Apple. Presence never suppresses `kind: tool`.
- **`ios_notify` (toolset `ios_push`).** `message` (≤200, required), `subtitle` (≤60), `open_conversation` (default false). The title is always the profile's display name, set by the server; the agent cannot choose title, topic, token or destination. Limits: 5 per hour and 20 per day per profile, counted atomically when queued (a later Apple failure or suppression still counts, a refusal does not). Errors given to the agent are explicit (limit with a retry delay, no registered iPhone, message too long). The automatic notification of a turn in which the tool succeeded is not sent (key: session + `turn_id`, which Hermes binds in a context variable around every tool call and which equals the `post_llm_call` `turn_id`; if it were ever empty the marker applies to the next turn that ends in that session). In a cron run the tool never targets a conversation, and the Bot Chat delivery of that run (`[Cronjob "<name>" output …]`) does not notify again.
- **Not available to the email assistant.** Hermes enables a plugin toolset on every platform whose `known_plugin_toolsets` does not list it. Production therefore needs `known_plugin_toolsets.api_server: [search_console, umami, ios_push]`; `scripts/test_ios_notify.py` proves that with that line the tool is absent for `api_server`, and the handler additionally refuses to run when the session platform is `api_server`. In Hermes 0.21.7 plugin tools are also deferred behind Tool Search (`tool_search` / `tool_call`), so the model finds `ios_notify` in the catalogue rather than in its eager tool list.

Tests: `python scripts/test_push_service.py` (store, encryption vector, migration, presence, revocation, privacy, API) and `python scripts/test_ios_notify.py` (tool, limits, dedupe, cron, toolset resolution against the real Hermes resolver), both with the Hermes venv; `PLUGIN_DIR=<dir>` runs them against a review bundle. Against the disposable fixture: `check_push_contract.py <home>` then, on a fresh fixture, `check_ios_notify_contract.py <home>`.

## App: encrypted preview, anti-spam and presence (v0.2)

- **Key.** When a server's notifications are enabled, the app generates a random 32-byte key per connection at every registration (rotation) and sends it as `key` (base64) in `PUT /devices`. It is kept in the Keychain in the shared access group `$(AppIdentifierPrefix)org.hermesios.shared` (declared in the app and extension entitlements, and exposed to code as `HermesSharedKeychainGroup` in both Info.plists), accessibility `AfterFirstUnlockThisDeviceOnly`. It is deleted when notifications are disabled or the connection is removed. The key is sent only over HTTPS, localhost, or Tailscale (100.64.0.0/10, `fd7a:115c:a1e0::/48`, `*.ts.net`); otherwise the app sends none, the server falls back to the generic alert, and Settings says why. Neither the key nor decrypted text is ever logged.
- **Extension.** `HermesIOSNotificationService` (a Notification Service Extension, no networking, no UI) decrypts `hermes.enc` (AES-256-GCM, AAD = `event_id`, `base64(nonce12 || ciphertext || tag16)`) with the connection's key, then sets title = agent, subtitle = conversation, body = preview. On any failure it delivers the generic fallback unchanged. The shared code is `HermesIOS/Core/NotificationCrypto.swift`, `NotificationEnvelope.swift`, `NotificationKeyStore.swift`; `outputs/notif-v2-2026-10-14/vector.json` is the cross-language test vector.
- **Foreground.** `willPresent` returns no banner for an automatic alert (`hermes.kind` absent or `turn`) when it targets the conversation on screen, or when a voice call is active. `ios_notify` alerts (`kind: tool`) always show. Opening a conversation removes its delivered notifications by `thread-id` (SHA-256 of `connection:profile:session`, as the server computes it).
- **Presence.** While the notification-enabled conversation is visible in the foreground, or a voice call runs (also in the background), the app sends `PUT …/presence` immediately then every 45 s (ttl 120), and `DELETE` when leaving, ending the call, or backgrounding without voice. Failures are silent; 401/403/404 stops presence until the next connection.
- **Taps.** Unchanged: `hermes.session_id` selects the conversation. A notification without `session_id` (`ios_notify` with `open_conversation=false`) just opens the app.
- **Device check required.** Extension decryption, shared-Keychain access between app and extension, and presence during a locked-screen voice call can only be proven on a signed physical iPhone (the new App ID `org.hermesios.HermesIOS.NotificationService` must be registered; the keychain group needs no portal setup).

## Validation

`python scripts/test_push_service.py` checks deduplication, retries, token rotation/revocation, profile/connection targeting, payload privacy, encryption, presence, migration, the dashboard routes, ES256 authentication and APNs host selection with an HTTP mock. It never contacts Apple.

Start a disposable fixture with `scripts/integration_server.py --home outputs/push-fixture --port 19133 --model-port 19234 --push-plugin`, then run:

```sh
HERMES_TEST_BASE=http://127.0.0.1:19133 python scripts/check_push_contract.py outputs/push-fixture
```

This executes the real, unmodified Hermes agent and a real cron with deterministic model replies. It checks plugin authentication, the native completion hook, a disconnected-phone cron delivery, one queued alert for the correct Bot Chat, and native resume of that answer. Fake tokens are seeded only into the disposable test outbox. No Apple credentials are used and no real push is sent.

To validate delivery end to end, use a signed physical iPhone build with a real APNs registration, close the app, trigger a routine delivered to a Bot Chat, then tap its alert. Verify the server, profile, conversation and response, including after force-quitting and relaunching the app. A simulator notification injection can test routing but does not prove Apple delivery.

References: [Apple remote notification server](https://developer.apple.com/documentation/usernotifications/setting-up-a-remote-notification-server), [APNs registration](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns), [Hermes backend plugins](https://hermes-agent.nousresearch.com/docs/user-guide/features/extending-the-dashboard#backend-api-routes), [Hermes lifecycle hooks](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks#plugin-hooks).
