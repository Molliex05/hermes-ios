# gemini-voix — Gemini 3.8 TTS with custom voices for Hermes

Hermes' built-in `gemini` TTS provider reaches only the 30 prebuilt Gemini voices. This plugin speaks with any Gemini 3.8 voice: Voice design (`voice_…`), Voice replication or the Extended Voice Library, through the Interactions API. Audio streams to the iPhone as 24 kHz PCM through Hermes' native `/api/audio/speak-stream` relay. It's a standard TTS provider plugin (`register_tts_provider`), not a fork; it survives Hermes updates.

## Install (once per profile)

```sh
# Inside the Hermes container, for each profile that should speak with Gemini:
P=/opt/data/profiles/<profile>
mkdir -p $P/plugins/gemini-voix
cp plugin.yaml __init__.py $P/plugins/gemini-voix/
chown -R hermes:hermes $P/plugins/gemini-voix
hermes -p <profile> plugins enable gemini-voix
hermes -p <profile> config set tts.gemini.model gemini-3.8-flash-lite-tts
```

The plugin stays idle until the profile selects it.

## Activate

1. Put `GEMINI_API_KEY` in the profile's keys (Hermès iOS: Mon agent → Clés et identifiants).
2. Choose the voice: its exact name in AI Studio (Voice design), its `voice_…` id, or a prebuilt name.
3. Select the provider:

```sh
hermes -p <profile> config set tts.gemini.voice "<voice name or voice_… id>"
hermes -p <profile> config set tts.provider gemini-voix
```

In Hermès iOS (build ≥ 27): Réglages → Voix → Synthèse → « Gemini 3.8 · voix personnalisée », voice and model fields, then « Tester la voix ».

Optional `tts.gemini.style` adds a delivery hint (`speech_metadata.style`, e.g. "naturel et chaleureux"). Permanent traits such as accent belong in the Voice design description, not in the style.

## Rollback

```sh
hermes -p <profile> config set tts.provider openai   # or edge, …
```

## Behavior

- **Model:** `tts.gemini.model` (default `gemini-3.8-flash-lite-tts`). A non-3.x value, such as the built-in provider's `gemini-2.5-…` default, is replaced by the default, because older models can't take stored voices.
- **Voice names:** display names are resolved once per hour through `GET /v1beta/voices` (stored voices first, then a search of the library).
- **Key:** read from the profile's secret scope and sent only in the `x-goog-api-key` header, never in URLs or logs.
- **Unary synthesis** (`/api/audio/speak`, tools) returns WAV.
- **Streaming** yields whole int16 frames; any odd trailing byte is held back for the next chunk.

## Tests

`scripts/check_gemini_voix_contract.py` against `scripts/integration_server.py --gemini-voix` (unmodified Hermes 0.21.7 plus a loopback Gemini fixture). It checks:
- voice resolution by display name;
- the exact Interactions request;
- unary WAV and streamed PCM for two profiles.

`hermes plugins validate server/hermes-gemini-voix` passes, including the security scan.

## Deployment record

**2026-10-13**, Hermes 0.21.7 (`71d34bad`), Coolify app « Hermes Agent » (port 9120). Code review and go-ahead from the VPS infrastructure session on the exact version below.

| File | sha256 |
|---|---|
| `/opt/data/plugins/gemini-voix/__init__.py` | `aa61e0f5d84b95d8f1b1f9171f8b64d969b898e525b8d9612e8350a5418fe4e1` |
| `/opt/data/plugins/gemini-voix/plugin.yaml` | `b32b83666141b83139d98f0e7df0ae45b033fc5b0baaf43ef6d9e9fe89313252` |

- **Links:** `/opt/data/profiles/{noriven,personnel}/plugins/gemini-voix` → `/opt/data/plugins/gemini-voix` (owner `hermes`).
- **Enabled:** `hermes -p noriven|personnel plugins enable gemini-voix`. `search-console` and `umami` are kept on noriven.
- **Model:** `tts.gemini.model = gemini-3.8-flash-lite-tts` on both profiles.
- **Still inactive:** `tts.provider = openai` until `GEMINI_API_KEY` and the voice are set. Discovery verified in both profiles (`found`, `available=False` without a key, `streams_pcm=True`).
- **Backups:** `config.yaml.bak-gemini-voix-20261013` in each profile.

**Follow-up from the review** (not blocking):
- Allow loopback base URLs only behind an explicit test variable (`GEMINI_VOIX_ALLOW_LOOPBACK=1`).
- Spoken text is sent to Google, as it was with OpenAI.
