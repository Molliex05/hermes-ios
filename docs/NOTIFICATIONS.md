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
- The Apple payload contains a generic message plus the opaque event, saved-connection, profile and stored-session identifiers. Conversation text, tool output, credentials and server URL are not sent to Apple by this extension.
- Device tokens and a small outbox are persisted privately on the Mac. Turn IDs deduplicate repeated callbacks. Transient Apple/network failures back off; alerts expire after 24 hours. Invalid registrations are removed without deleting a newer rotated token. APNs delivery is best effort; iOS Focus and user settings still apply.
- Disabling a server's notifications revokes the registration on that server. Removal of a saved connection first revokes its subscription. An alert already delivered to iOS may remain in Notification Center.
- Development-signed apps use APNs sandbox even when built in Release. Distribution uses production. The app reads its signed provisioning profile, rather than guessing from the build configuration.
- Tapping an old notification never sends a message. Unknown/removed servers show an explanation. Cold-launch taps wait for cache restoration, preserve drafts, and select the explicit profile/session before native resync.

## Validation

`python scripts/test_push_service.py` checks deduplication, retries, token rotation/revocation, profile/connection targeting, payload privacy, ES256 authentication and APNs host selection with an HTTP mock. It never contacts Apple.

Start a disposable fixture with `scripts/integration_server.py --home outputs/push-fixture --port 19133 --model-port 19234 --push-plugin`, then run:

```sh
HERMES_TEST_BASE=http://127.0.0.1:19133 python scripts/check_push_contract.py outputs/push-fixture
```

This executes the real, unmodified Hermes agent and a real cron with deterministic model replies. It checks plugin authentication, the native completion hook, a disconnected-phone cron delivery, one queued alert for the correct Bot Chat, and native resume of that answer. Fake tokens are seeded only into the disposable test outbox. No Apple credentials are used and no real push is sent.

To validate delivery end to end, use a signed physical iPhone build with a real APNs registration, close the app, trigger a routine delivered to a Bot Chat, then tap its alert. Verify the server, profile, conversation and response, including after force-quitting and relaunching the app. A simulator notification injection can test routing but does not prove Apple delivery.

References: [Apple remote notification server](https://developer.apple.com/documentation/usernotifications/setting-up-a-remote-notification-server), [APNs registration](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns), [Hermes backend plugins](https://hermes-agent.nousresearch.com/docs/user-guide/features/extending-the-dashboard#backend-api-routes), [Hermes lifecycle hooks](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks#plugin-hooks).
