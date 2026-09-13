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

Choose an installed simulator. The regular suite runs offline previews, captures welcome/chat/agents/settings/connection screenshots, checks bottom composer placement with no tab bar, and verifies draft preservation through header navigation and sheet dismissal. Native integration is skipped in this scheme. Keep code signing enabled for Keychain tests. Do not run competing XCUITest processes on the same simulator.

If your simulator runtime belongs to a second Xcode installation, select it for the command with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` rather than changing the machine-wide selection.

## Real Hermes integration

These tests execute the **official, unmodified Hermes backend** with a new isolated Hermes home. Only the model endpoint is a deterministic local fixture. No real provider keys, personal profiles or production server are required.

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

xcodebuild -scheme HermesIOSIntegration \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HermesIOSUITests/HermesIOSUITests/testNativeHermesConnectionAndResume test
```

The fixture binds only to loopback. Its intentionally public test credentials are `hermes-ios-test` / `hermes-ios-local-fixture`; they are for this disposable fixture only. No bridge script is required by Hermès iOS in normal use.

The protocol probe verifies authentication gates, ticket minting, native RPC calls, streaming across a closed/reopened socket, replay sequences, exactly one persisted user message, canonical Bot Chat profile isolation, cron create/list/pause and hosted-group creation/logs. The opt-in UI test signs in from iOS, sends a message, backgrounds/reactivates the app during the turn, checks the final reply and relaunches to verify cached history plus saved authentication.

Stop the fixture with Ctrl-C. The test home and dependencies remain in the ignored `outputs/` directory for inspection. Never run this harness with your real `HERMES_HOME`.
