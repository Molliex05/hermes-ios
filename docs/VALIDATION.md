# Validation — September 13, 2026

| Check | Result |
| --- | --- |
| Foundation core suite | 25 tests passed, including replay/scoping, silence detection and exact stop-phrase matching |
| Offline iOS UI suite | 6 tests passed: chat/agents/settings, onboarding, draft preservation, filtered tool discovery, quick profile switching and attachment/voice controls |
| Integrated composer | Passed: controls inside the bubble, keyboard layout, photo/file menu and voice sheet preserve the written draft |
| Official Hermes protocol probe | 13 checks passed, including auth, live replay, canonical Bot Chat, profile isolation, routines and hosted groups |
| Native tools probe | Passed: skills list/content/toggle isolation, workspace isolation, model assignment isolation, Kanban triage creation and idempotency |
| Native iOS integration | Passed: sign-in, persisted auth, streaming and resume; skill toggling, profile model/workspace/board reads; automatic voice send, playback, resumed listening and draft preservation |
| Release device build | Development-signed ARM64 build 9 succeeded; installed on iPhone 16 Plus |

The integration backend is the official, unmodified Hermes Agent **0.21.2**, commit `b7b35a84b7fbe1aa2e223a6ce726a2471300d0a4`, in an isolated home. Model, STT and TTS provider endpoints use deterministic local fixtures; native Hermes remains unmodified. Production agent data and credentials are excluded from automated tests and screenshots.

UI tests use a dedicated iPhone 17 Pro simulator on iOS 27 with Xcode 27 (`27A5218g`). The application targets iOS 17; older OS versions have not been exercised. The physical iPhone 16 Plus also runs iOS 27. Installation preserves existing app data. The user confirmed the native private-HTTP/Tailscale connection after the ATS correction in the earlier build.

The app is approximately **6.3 MB**, unpacked and development-signed, with no third-party runtime packages. This is not an App Store download-size measurement.

The media contract probe passes image staging/attach/detach retry, encoded paths and file references. The chained voice probe passes transcription → native agent → speech playback data for two profiles; the fixture confirms their distinct configured voices (`nova` and `echo`). Real microphone capture and speech-provider quality still require a manual device check. Chained conversations are supported; GPT-Live/WebRTC and automatic barge-in remain outside this release.

Xcode 27 beta sometimes stalls while finalizing an xcresult after all test cases finish. The test runner also saves screenshots to its disposable temporary directory so visual inspection does not depend on that finalization. Native voice assertions passed in the iOS runner. The audio fixture is DEBUG-only and restricted to loopback; Release uses the physical microphone.

See [TESTING.md](TESTING.md) for reproduction and [README boundaries](../README.md#honest-boundaries) for exact feature scope.

Build 9 modernizes conversation history. The existing profile-switch/draft-preservation UI test passes with the new history sheet and X, and its screenshot was inspected on iPhone 17 Pro Simulator. The Release device build is verified separately.
