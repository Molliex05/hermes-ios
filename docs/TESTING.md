# Testing

## Core

```sh
swift test
```

Behavioral tests cover newline-coalesced JSON-RPC frames, Unicode, reverse-proxy URL prefixes, Tailscale/private URL validation, cookie Secure flags after Keychain serialization, replay ordering, duplicate suppression, session isolation, optimistic-send reconciliation, overflow recovery, epoch reset, canonical compression tips, native routine identity and pending approvals.

## UI

```sh
xcodebuild -scheme HermesIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Choose an installed simulator. The regular suite runs offline previews, captures welcome/chat/agents/settings/connection screenshots, checks that all navigation and message controls stay inside the composer bubble, including with the keyboard open, with no tab bar, verifies draft preservation through navigation and sheet dismissal, and exercises Work/Agent tool filters plus global tool search. A dedicated test switches profiles from the bottom picker, checks that selecting the active agent preserves the chat, and verifies separate drafts when returning to each demo Bot Chat. Native integration is skipped in this scheme. Keep code signing enabled for Keychain tests. Do not run competing XCUITest processes on the same simulator.

If your simulator runtime belongs to a second Xcode installation, select it for the command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` rather than changing the machine-wide selection.

## Real Hermes integration

These tests execute the **official, unmodified Hermes backend** with a new isolated Hermes home. Model, STT and TTS provider endpoints are deterministic local fixtures; the Hermes backend itself is unmodified. No real provider keys, personal profiles or production server are required.

```sh
mkdir -p outputs/integration
git clone https://github.com/NousResearch/hermes-agent.git outputs/integration/upstream
git -C outputs/integration/upstream checkout b7b35a84b7fbe1aa2e223a6ce726a2471300d0a4
python3.11 -m venv outputs/integration/venv
outputs/integration/venv/bin/pip install -e outputs/integration/upstream

# Leave running in a terminal; --home must be new and empty:
outputs/integration/venv/bin/python scripts/integration_server.py \
  --home outputs/integration/hermes-home
```

In another terminal:

```sh
outputs/integration/venv/bin/python scripts/check_hermes_contract.py
outputs/integration/venv/bin/python scripts/check_tools_contract.py
outputs/integration/venv/bin/python scripts/check_media_contract.py

xcodebuild -scheme HermesIOSIntegration \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HermesIOSUITests/HermesIOSUITests/testNativeHermesConnectionAndResume test
```

The fixture binds only to loopback. Its intentionally public test credentials are `hermes-ios-test` / `hermes-ios-local-fixture`; they are for this disposable fixture only. No bridge script is required by Hermès iOS in normal use.

The protocol probe verifies authentication gates, ticket minting, native RPC calls, streaming across a closed/reopened socket, replay sequences, exactly one persisted user message, canonical Bot Chat profile isolation, cron create/list/pause and hosted-group creation/logs. The opt-in UI test signs in from iOS, sends a message, backgrounds/reactivates the app during the turn, checks the final reply and relaunches to verify cached history plus saved authentication.

Stop the fixture with Ctrl-C. The test home and dependencies remain in the ignored `outputs/` directory for inspection. Never run this harness with your real `HERMES_HOME`.

The tools probe verifies native skills list/content/toggle and profile isolation, workspace list isolation, model assignment isolation, Kanban board/detail/triage creation and retry deduplication. Audio checks validate the native authenticated routes without calling an STT/TTS provider; physical microphone capture and real speech providers require a manual device check.

The media probe verifies native image staging/attach/detach with encoded paths, native file references, and chained STT → agent → TTS for two profiles with distinct configured voices. The native UI test additionally starts voice, checks automatic submission and return to listening, and verifies the typed draft is preserved. It uses a DEBUG-only audio fixture, enabled only by `--voice-fixture` against a loopback connection; production microphone permission/capture and real provider quality still require a manual device check. No audio fixtures are enabled in Release builds.

## Background submission and recovery

With the isolated fixture running, select `HermesIOSIntegration` and run `testNativeSendThenImmediatelyBackground`. The test sends `HERMES_IOS_BACKGROUND_TEST` and immediately backgrounds the app without waiting for acknowledgement or the first token. Only that fixture marker slows the deterministic provider stream to about 30 seconds. After 40 seconds away (longer than the native 20-second orphan grace), the test requires exactly one complete answer and one user bubble, then verifies recovery after process relaunch. This exercises native Hermes server-side continuation with no provider outage or production data. It does not guarantee the amount of background execution time granted by iOS or cover force-quitting before transmission.

## Streaming Markdown

`testNativeStreamingMarkdown` uses the isolated Hermes fixture with a deliberately gradual Markdown reply. It requires visible first words before the final sentence exists, checks keyboard dismissal, then verifies one reply and the code-copy action. Screenshots cover the partial stream, formatted answer and scrolling back to earlier content. Core tests cover block structure, unfinished/nested fences, escaped table pipes, Unicode and partial-answer retention after interruption.


## Management and bidirectional requests (build 15)

Use the same disposable fixture with Hermes 0.21.3. `check_management_contract.py` verifies partial configuration writes and profile isolation, toolsets, skill content, native project/file operations, history archives/search, cron editing, Kanban comments/status, Bot metadata revision conflicts and group administration.

`check_interactive_contract.py` requests a real `clarify` tool call from the deterministic model. It answers one question, reconnects, verifies the accepted answer in `open_requests`, answers the remaining question, and checks that a late answer expires. `check_speech_stream_contract.py` verifies PCM arrives before text completion and checks two profile voices.

```sh
python scripts/check_management_contract.py
HERMES_TEST_BASE=http://127.0.0.1:19123 python scripts/check_interactive_contract.py
HERMES_TEST_BASE=http://127.0.0.1:19123 python scripts/check_speech_stream_contract.py
```

Start the second fixture with a fresh empty home, `--port 19123 --model-port 19224`. The focused `testNativeInteractiveRecoveryAndPermissions` UI test expects this second fixture and a clean dedicated simulator app install. It verifies question recovery after relaunch, permissions discovery and the voice playback/listening loop. Do not clear a real device’s app data for these tests.

### Tool execution while the phone is away (build 15)

Run `HERMES_TEST_BASE=http://127.0.0.1:19129 python scripts/check_background_tool_contract.py` against a disposable fixture started with `--port 19129 --model-port 19230`. It waits for a native terminal tool to start, closes the WebSocket for 55 seconds (beyond the 20-second orphan grace), then resumes and requires one persisted user message and one completed answer. The terminal tool sleeps for 35 seconds; no production agent is modified.

The matching `testNativeToolContinuesWhileBackgrounded` UI test uses port 19129 and a fresh QA simulator app container. It backgrounds the app after observing the tool, returns after 55 seconds, and checks recovery without duplicate bubbles or a false unsent label. Core regression tests cover lost acknowledgements, late failures after confirmed receipt, native admission refusals, transient resume races and tool events from a shared session.

The app explicitly requests `close_on_disconnect: false` using native session create/resume. Hermes owns execution. iOS receives a finite background allowance only to finish transmission and save local state; after that the phone disconnects and retrieves the authoritative session on return. Unknown send outcomes are never automatically resent. A provider failure, server restart or Hermes interruption remains a separate execution failure.


## Apple notification routing

See [NOTIFICATIONS.md](NOTIFICATIONS.md) for the server outbox unit tests and the real Hermes cron contract. `testNativeNotificationOpensCorrectConversationAfterColdLaunch` uses a fresh dedicated QA simulator, the fixture on port 19133, and `scripts/inject_notification_fixture.py --output <test-output-directory>` running alongside XCTest. The output directory must contain the successful cron contract's `cron-notification.apns` and the current test log named `ui.log`. The injector waits for the test checkpoint, reads only the simulator's fixture connection ID, and injects the actual cron target through `simctl push`. The test terminates the app, taps the iOS notification banner, and verifies the correct profile and native answer after cold launch.

A DEBUG-only `--notification-fixture-permission` flag requests notification permission only for a loopback fixture. It does not bypass notification decoding/routing or enable a server registration. Simulator injection validates the iOS delegate and navigation; it does not validate APNs signing or physical delivery.

## Conversation navigation and routine results (September 25)

The offline UI suite additionally checks persistent tool favorites, the unread filter and read position after opening a chat, and navigation with accessibility text sizes. The attachment menu/voice test preserves a typed draft through both surfaces. These tests exercise demo data only.

Core tests cover local unread baselines, late history responses, profile isolation, differing native previews with equal message counts, and old cache decoding. Tool activity tests cover replay, duplicate events, interrupted tools, idle snapshots and the bounded activity list. Routine tests cover human schedule round trips, native one-shot timestamps and explicit session routing.

For the routine result contract, start a new disposable fixture with `--port 19139 --model-port 19240`, then run:

```sh
HERMES_TEST_BASE=http://127.0.0.1:19139 python scripts/check_routine_navigation_contract.py
xcodebuild -scheme HermesIOSIntegration \
  -destination 'platform=iOS Simulator,name=Hermes iOS UX QA' \
  -only-testing:HermesIOSUITests/HermesIOSUITests/testNativeRoutineResultAndPermissionDiscovery test
```

The probe creates and triggers its own routine, follows the native run's exact profile/session, resumes the answer and deletes its routine afterward. The UI test uses a fresh dedicated simulator app container on the same fixture, creates a future one-shot routine, triggers it explicitly, opens its result and reads the native permission settings. Neither test uses production agents. Presence of a test in the suite is not a passing result; see VALIDATION.md for the runs actually completed.

## Hands-free voice (September 26)

Start a disposable fixture with a new home, `--port 19149 --model-port 19250`. Run the native speech contract with `HERMES_TEST_BASE=http://127.0.0.1:19149 python scripts/check_speech_stream_contract.py`. On a dedicated simulator, use scheme `HermesIOSIntegration` for:

- `testNativeHandsFreeVoiceConversation`: 18 seconds of initial silence, two automatically submitted/spoken turns without a send gesture, microphone mute, expandable transcript and preserved written draft.
- `testNativeVoiceBargeInAndNextTurn`: microphone activity over the first playback, immediate local audio interruption, native agent interruption and a second completed response.
- `testNativeVoiceCanCloseAndReopenWithoutLateCapture`: rapid close/reopen, no late submitted utterance and an immediately usable chat.

The DEBUG-only `--voice-fixture` requires a loopback connection and replaces microphone samples/transcription input, while exercising the actual iOS PCM converter/player, native Hermes requests and server execution. `--voice-quiet-fixture` and `--voice-barge-fixture` only affect this fixture. They do not prove physical echo rejection, microphone sensitivity or Bluetooth routing. Validate those manually on the physical iPhone: let Hermès speak on the speaker, interrupt with a full phrase, repeat with headphones, mute/unmute and disconnect the headphones. An incoming call or backgrounding should stop local recording/playback; an admitted agent turn remains in the chat.

`testVoiceAccessibilityAndDismissal` covers the largest accessibility text size and reachable bottom controls. The audio-only animation is bounded to 24 fps and respects Reduce Motion. Core tests exercise native preference parsing, short-noise rejection, long silence, confirmed pre-roll handoff, interruption grace and disabled barge-in.
