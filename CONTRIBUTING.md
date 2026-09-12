# Contributing to Iris

Use a focused pull request that explains the user-visible behavior and its validation. New runtime dependencies need a clear benefit relative to binary size, maintenance and the available Apple frameworks.

The checked-in Xcode project is generated from `project.yml`. Run `xcodegen generate` after adding files or changing build configuration, and commit the generated project. Never commit signing identities, `.env` files, transcripts from a real agent, session tokens or build outputs.

Run `swift test` for protocol/state changes. Run the Iris UI tests for interaction changes. Use the opt-in IrisIntegration scheme with the isolated official Hermes backend for authentication, session ownership, replay, profile, bot or routine changes. See [testing](docs/TESTING.md).

Important invariants:

- Server/profile/stored-session/runtime-session identities are separate. Capture the owner before awaiting a network operation.
- A failed Bot Chat lookup is not permission to create a replacement. Never key canonical bot identity from an Iris-only pointer.
- Do not clear a visible transcript to reconnect. Do not reorder or duplicate sequenced events during replay.
- Do not automatically resend `prompt.submit`: its JSON-RPC request ID is not a durable idempotency key.
- Preserve the user's draft, read position and message view identities.
- Secrets belong in the Keychain or a transient input, never in a transcript or a log.
- The `scripts/integration_server.py` model is a deterministic **test fixture**, not part of the app or a deployable bridge.

For security reports, use GitHub private vulnerability reporting if enabled; never publish credentials or private transcripts in an issue. For non-sensitive bugs, include the Iris version, Hermes commit, transport (HTTPS/Tailscale HTTP) and a minimal reproduction.
