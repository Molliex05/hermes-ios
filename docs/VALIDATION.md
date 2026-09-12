# Initial validation — September 12, 2026

| Check | Result |
| --- | --- |
| Foundation core suite | 21 tests passed |
| Offline iOS UI suite | 3 tests passed: chat/agents/settings, onboarding, draft preservation |
| Official Hermes protocol probe | 13 checks passed, including auth, live replay, canonical Bot Chat, profile isolation, routines and hosted groups |
| Native iOS integration | Passed: fresh sign-in, saved authentication after relaunch, streaming prompt, background/foreground resume, one final answer, cached history after another relaunch |
| Release device build | ARM64 iOS build succeeded without distribution signing |

The integration backend was the official, unmodified Hermes Agent **0.21.2** at commit `b7b35a84b7fbe1aa2e223a6ce726a2471300d0a4`, running in an isolated home. Inference alone was replaced with a deterministic local fixture. The socket probe recovered 13 events and verified exactly two durable history messages for its single user/assistant turn.

UI validation used a dedicated iPhone 17 Pro simulator with iOS 27, Xcode 27 (`27A5218g`). The application deployment target is iOS 17. Older OS versions and physical iPhones have not yet been exercised. This machine only had the iOS 27 runtime; its other Xcode installation could not process assets with that runtime, so matching Xcode 27 was used for the final builds.

The unsigned, unpacked device app is approximately **3.7 MB** (decimal). This is not an App Store download-size measurement. There are no third-party runtime packages.

The user's production Hermes instance and physical Tailscale connection were not used. No personal agent data or credentials are included. Simulator preview screenshots use synthetic conversations. See [TESTING.md](TESTING.md) to reproduce the checks and [README boundaries](../README.md#honest-boundaries) for the initial feature scope.
