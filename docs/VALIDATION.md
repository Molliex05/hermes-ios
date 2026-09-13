# Validation — September 12, 2026

| Check | Result |
| --- | --- |
| Foundation core suite | 22 tests passed, including reverse-proxy tool query scoping |
| Offline iOS UI suite | 5 tests passed: chat/agents/settings, onboarding, draft preservation, filtered tool discovery and quick profile switching |
| Integrated composer | 2 focused UI tests passed: all controls inside the bubble, keyboard layout, navigation and draft preservation |
| Official Hermes protocol probe | 13 checks passed, including auth, live replay, canonical Bot Chat, profile isolation, routines and hosted groups |
| Native tools probe | Passed: skills list/content/toggle isolation, workspace isolation, model assignment isolation, Kanban triage creation and idempotency |
| Native iOS integration | Passed: sign-in, persisted auth, streaming and resume; skill toggling, profile model/workspace/board reads from iOS |
| Release device build | Development-signed ARM64 build 7 succeeded; installed on iPhone 16 Plus |

The integration backend is the official, unmodified Hermes Agent **0.21.2**, commit `b7b35a84b7fbe1aa2e223a6ce726a2471300d0a4`, in an isolated home. Only inference uses a deterministic local fixture. Production agent data and credentials are excluded from automated tests and screenshots.

UI tests use a dedicated iPhone 17 Pro simulator on iOS 27 with Xcode 27 (`27A5218g`). The application targets iOS 17; older OS versions have not been exercised. The physical iPhone 16 Plus also runs iOS 27. Installation preserves existing app data. The user confirmed the native private-HTTP/Tailscale connection after the ATS correction in the earlier build.

The app is approximately **6.1 MB**, unpacked and development-signed, with no third-party runtime packages. This is not an App Store download-size measurement.

Audio tests validate the authenticated native routes and payload validation without calling STT/TTS providers. Real microphone capture and speech-provider quality still require a manual device check. Continuous voice conversation remains outside this release.

Xcode 27 beta sometimes stalls while finalizing an xcresult after all test cases finish. The test runner also saves screenshots to its disposable temporary directory so visual inspection does not depend on that finalization. The native integration result bundle completed successfully.

See [TESTING.md](TESTING.md) for reproduction and [README boundaries](../README.md#honest-boundaries) for exact feature scope.
