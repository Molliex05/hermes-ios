# Validation — September 14, 2026

| Check | Result |
| --- | --- |
| Foundation core suite | 40 tests passed, including Markdown streaming/fences/tables, interrupted replies, replay/scoping and profile cache isolation |
| Offline iOS UI suite | 6 tests passed: chat/agents/settings, onboarding, draft preservation, filtered tool discovery, quick profile switching and attachment/voice controls |
| Integrated composer | Passed: controls inside the bubble, keyboard layout, photo/file menu and voice sheet preserve the written draft |
| Official Hermes protocol probe | 13 checks passed, including auth, live replay, canonical Bot Chat, profile isolation, routines and hosted groups |
| Native tools probe | Passed: skills list/content/toggle isolation, workspace isolation, model assignment isolation, Kanban triage creation and idempotency |
| Native iOS integration | Passed: sign-in, persisted auth, streaming and resume; skill toggling, profile model/workspace/board reads; automatic voice send, playback, resumed listening and draft preservation |
| Release device build | Development-signed ARM64 build 14 succeeded; installed and launched on iPhone 16 Plus |

The integration backend is the official, unmodified Hermes Agent **0.21.2**, commit `b7b35a84b7fbe1aa2e223a6ce726a2471300d0a4`, in an isolated home. Model, STT and TTS provider endpoints use deterministic local fixtures; native Hermes remains unmodified. Production agent data and credentials are excluded from automated tests and screenshots.

Earlier UI tests used a dedicated iPhone 17 Pro simulator on iOS 27 with Xcode 27 (`27A5218g`). Build 14 uses a fresh iPhone 18 Pro simulator on iOS 27 with Xcode 27 (`27A266a`). The application targets iOS 17; older OS versions have not been exercised. The physical iPhone 16 Plus also runs iOS 27. Installation preserves existing app data. The user confirmed the native private-HTTP/Tailscale connection after the ATS correction in the earlier build.

The app occupies approximately **7 MiB**, unpacked and development-signed, with no third-party runtime packages. This is not an App Store download-size measurement.

The media contract probe passes image staging/attach/detach retry, encoded paths and file references. The chained voice probe passes transcription → native agent → speech playback data for two profiles; the fixture confirms their distinct configured voices (`nova` and `echo`). Real microphone capture and speech-provider quality still require a manual device check. Chained conversations are supported; GPT-Live/WebRTC and automatic barge-in remain outside this release.

Xcode 27 beta sometimes stalls while finalizing an xcresult after all test cases finish. The test runner also saves screenshots to its disposable temporary directory so visual inspection does not depend on that finalization. Native voice assertions passed in the iOS runner. The audio fixture is DEBUG-only and restricted to loopback; Release uses the physical microphone.

See [TESTING.md](TESTING.md) for reproduction and [README boundaries](../README.md#honest-boundaries) for exact feature scope.

Build 9 modernizes conversation history. The existing profile-switch/draft-preservation UI test passes with the new history sheet and X, and its screenshot was inspected on iPhone 17 Pro Simulator. The Release device build is verified separately.

Build 10 removes GPT-Live HTTP discovery from standard voice startup. The native config RPC supplies mode and silence settings. A regression transport returns 404 for every unsupported HTTP route while the standard voice sequence still succeeds; missing required audio routes are reported explicitly. The initial production Tailscale probe was blocked by the development shell’s proxy configuration. A later direct probe reached the installed Hermes 0.21.0 server. Its source has the required audio routes and lacks the optional GPT-Live status route; production audio operation has not been tested with authenticated requests.

For build 10, 28 core tests, native config/STT/agent/TTS integration probes and the signed device build passed. The fresh simulator UI run could not start; the dedicated iOS 27 simulator stalled during boot even after a restart. The prior UI results above are from builds 8–9, not a completed build 10 UI run. Build 10 was installed successfully; automatic launch was blocked by the phone’s lock screen.

Build 11 addresses history refresh recovery. Read-only production diagnostics found native gateway event-loop stalls of 21.7–24.9 seconds, exceeding the previous 15-second heartbeat deadline. Native read-only database listing succeeded in 12 ms or less for the two inspected profiles. The original app error discarded its cause, so these findings identify a plausible interruption mechanism, not a recovered exception. The app also retained stale errors after successful background refreshes and could request history before the socket was ready. These cases are corrected, concurrent reads are shared, and the next failure preserves its actual reason. No production server settings or data were changed.

Build 11 validation: all 30 core tests passed, including concurrent history reads, cancellation without aborting another reader, failure retry and profile scoping. The targeted iOS UI test passed for profile switching, separate drafts, conversation history and X dismissal. The signed Release build was installed and launched on iPhone 16 Plus. Automated recovery tests use the request coordinator; the observed production server stalls have not been deliberately reproduced on device.

Build 12 (September 14) adds a native SF Symbol pulse to the active thinking/tool indicator. It respects Reduce Motion and keeps the text and layout stable. The signed Release build passed and was installed and launched on iPhone 16 Plus; no core logic changed and the earlier core/UI results were not rerun for this visual-only change.

Build 13 improves synchronization and background submission. Core: 33 tests passed. The new native iOS background test passed: immediate backgrounding after Send, 40 seconds away while the official Hermes fixture continues a slow turn, one complete answer after return, and successful cache/reconnect after process relaunch. The isolated database confirms exactly one user message and one assistant response for that test. The native tools probe also passed. Simulator backgrounding exercises the app lifecycle; a physical lock-screen/OS-expiration test has not been automated. No production server configuration was changed.

The final build 13 Release was installed on the physical iPhone. Automatic launch of the final revision was blocked by the lock screen; an earlier build 13 revision had launched successfully. An additional broad native UI run verified sign-in/resume, profile opening, skills and model display, then repeatedly waited 60 seconds for missing iOS 27 animation-completion notifications. That run was interrupted and is not counted as a passing full native suite. The focused background/relaunch test above completed successfully.

The separate focused UI test also passed for profile switching, isolated drafts, conversation history and X dismissal. Both focused UI runs completed; the broad animation-stalled run remains excluded.

Build 14 adds immediate first-fragment rendering, structured native Markdown, verbatim user messages and improved scroll following. The 40 core tests pass. The native streaming UI test verifies that the beginning is visible before completion, the keyboard closes after Send, a single final reply, and the code-copy control; screenshots were inspected. The final Release revision was installed and launched on the physical iPhone 16 Plus. The build uses Xcode 27 (`27A266a`) at `Xcode.app` after the workspace move to external storage. Fresh build caches avoid stale paths from the prior toolchain. No third-party runtime dependencies were added.
