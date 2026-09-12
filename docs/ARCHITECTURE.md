# Architecture and continuity

Hermès iOS is one SwiftUI application with a Foundation-only core package for tests. There are no third-party runtime dependencies. Apple frameworks provide rendering, HTTP, WebSocket, secure credential storage and local data protection. The app has no hosted component.

## Ownership

```
SwiftUI views → AppModel → HermesSocket → /api/ws → official Hermes handlers
                   │         │
                   │         └─ HermesHTTP → native auth / short-lived WS ticket
                   └─ LocalCache (display projection and drafts only)
```

Hermes owns context, memory, skills, tools, model selection and persisted messages. Hermès iOS never submits a locally reconstructed chat history as model context. A message is `prompt.submit {session_id, text}` on the existing native runtime session.

A saved gateway has a UUID and an endpoint including any proxy prefix. Every cached conversation is scoped by gateway, profile and stored session ID. Runtime IDs are kept separately and rebound by `session.resume`. Selection and connection generations prevent stale async results from taking over a different conversation.

## Fast path

Saved chats and drafts render before the network is contacted. The socket stays open while the app is in the foreground. Native `ping` heartbeats detect a half-open connection. Token events are applied in batches at approximately 30 updates per second; control and completion events flush immediately. Cache writes are debounced and happen on a separate actor.

The view keeps stable message identities during hydration and follows the last message only while the reader is near the bottom. A tiny connection indicator reports availability; there is no full-screen sync overlay or forced clearing of chat. The composer remains editable offline.

## Reconnect

1. Mint a new single-use ticket with the existing native session cookie.
2. Read `gateway.ready.payload.replay_epoch`.
3. Reattach the stored conversation and receive its current runtime ID.
4. If epoch and runtime still match, fetch `session.events.since` after the last applied sequence.
5. Hold concurrent live events while that request runs, then merge by sequence and deduplicate before dispatch.
6. If the epoch changed, runtime changed, a send is uncertain, or the replay was truncated, fetch the native transcript/in-flight snapshot and rebase the visible tail.

Hermes' replay buffer is bounded. There is no atomic snapshot+cursor field in the inspected backend. The fallback can reconstruct a retained turn from `message.start`; otherwise it uses a linear-time overlap of the cumulative partial response and retained stream suffix. When the overlap cannot be proven, the existing partial response remains until `message.complete` provides the authoritative answer. The final native history is then reconciled without changing model context.

iOS suspends background execution. Hermès iOS saves local state and detaches when backgrounded, then resumes when active. It does not use a fake background-audio mode to keep a socket alive. The server may continue work according to Hermes' own orphan/reaper and task policies. No push notifications are implemented in 0.1.0.

## Sending and ambiguity

An optimistic user bubble appears on submit. The native acknowledgement confirms acceptance. Network loss after transmission leaves an **uncertain** bubble; an explicit RPC refusal marks it **failed**. A later authoritative snapshot can reconcile the optimistic row. Hermès iOS never automatically replays a plain chat submission, because JSON-RPC IDs alone do not provide durable idempotency.

Hosted groups are different: the native `groups.send` contract includes a durable event ID. Hermès iOS persists that ID before sending and reuses it for a user-requested retry. Group log cursors and event IDs deduplicate replay. Only the visible group polls its native log, at a two-second interval; no Hermès iOS group coordinator or bot relay exists.

## Privacy

Session cookies/tokens are stored in the Keychain with `AfterFirstUnlockThisDeviceOnly`. Passwords entered at login are cleared after authentication; credential-request values are transient. Cookie restore preserves the actual Secure flag (Foundation treats even a present `"FALSE"` string as secure).

Display caches live in Application Support, with data protection and backup exclusion. The recent cache keeps up to 500 messages per conversation; opening/recovery can retrieve native history. Connection removal erases its local files and Keychain entry. Hermès iOS has no analytics SDK, crash upload endpoint or advertising identifier.

ATS allows HTTP because tailnet IP addresses are user-configurable. Application URL validation restricts HTTP to loopback/private address ranges and private-network names; public addresses require HTTPS. Redirects are not followed, so login bodies and credentials are not forwarded to a new origin. HTTPS certificate validation remains the platform default. The separate socket session has a long resource timeout; short HTTP-request deadlines must not repeatedly tear down a healthy chat socket.
