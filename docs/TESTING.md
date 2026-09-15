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
