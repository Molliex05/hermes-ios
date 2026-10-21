"""Gemini 3.8 TTS for Hermes with custom voices, as a TTS provider plugin (no core change).

Hermes' built-in ``gemini`` provider speaks through ``generateContent`` with
``prebuiltVoiceConfig``: it reaches the 30 prebuilt voices only. Gemini 3.8 TTS
(``gemini-3.8-flash-tts``, ``gemini-3.8-flash-lite-tts``) takes stored voices —
Voice design (``voice_…``), Voice replication and the Extended Voice Library — through
the Interactions API (``POST /v1beta/interactions``, ``generation_config.speech_config =
[{"voice": …}]``), streamed as raw 24 kHz mono int16 PCM.

Configuration (per profile, like every voice setting):
  tts.provider: gemini-voix
  tts.gemini.model: gemini-3.8-flash-lite-tts      (default)
  tts.gemini.voice: voice_…  |  the voice's display name in AI Studio  |  a prebuilt name
  tts.gemini.style: optional delivery hint (speech_metadata.style), e.g. "naturel et chaleureux"
  GEMINI_API_KEY (or GOOGLE_API_KEY) in the profile's .env
The key stays in the profile's secret scope and travels only in the ``x-goog-api-key`` header.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import threading
import time
from pathlib import Path
from typing import Any, Dict, Iterator, Optional, Tuple

from agent.tts_provider import TTSProvider

logger = logging.getLogger(__name__)

NAME = "gemini-voix"
DEFAULT_MODEL = "gemini-3.8-flash-lite-tts"
DEFAULT_VOICE = "Kore"
DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"
SAMPLE_RATE = 24000
PREBUILT = (
    "Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe", "Autonoe",
    "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi",
    "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird",
    "Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat",
)
_PREBUILT_BY_KEY = {name.casefold(): name for name in PREBUILT}
_VOICE_CACHE_SECONDS = 3600
OPENAI_TTS_URL = "https://api.openai.com/v1/audio/speech"
FALLBACK_INSTRUCTIONS = "Parle en français québécois, d'un ton chaleureux, naturel et posé, comme dans une conversation."
_session_lock = threading.Lock()
_session = None


def _http():
    """One keep-alive session for Google: a fresh TLS handshake per sentence costs a few hundred milliseconds."""
    global _session
    with _session_lock:
        if _session is None:
            import requests
            from requests.adapters import HTTPAdapter
            _session = requests.Session()
            _session.mount("https://", HTTPAdapter(pool_connections=4, pool_maxsize=8))
        return _session

_MAX_STREAM_BYTES = 32 * 1024 * 1024  # ~11 min of audio for one sentence: a runaway stream guard


def _settings() -> Dict[str, Any]:
    """The requesting profile's ``tts.gemini`` section (Hermes runs synthesis inside that scope)."""
    try:
        from hermes_cli.config import load_config
        tts = (load_config() or {}).get("tts") or {}
        section = tts.get("gemini") if isinstance(tts, dict) else None
        return section if isinstance(section, dict) else {}
    except Exception:
        logger.debug("gemini-voix: config unavailable", exc_info=True)
        return {}


def _api_key() -> str:
    from tools.tool_backend_helpers import resolve_provider_secret
    return resolve_provider_secret("GEMINI_API_KEY", "gemini") or resolve_provider_secret("GOOGLE_API_KEY", "gemini")


def _base_url(settings: Dict[str, Any]) -> str:
    raw = str(settings.get("base_url") or os.environ.get("GEMINI_BASE_URL") or DEFAULT_BASE_URL).strip().rstrip("/")
    from urllib.parse import urlparse
    parsed = urlparse(raw)
    # The key may only travel to Google over HTTPS (loopback is allowed for the test fixture).
    google = parsed.scheme == "https" and parsed.hostname == "generativelanguage.googleapis.com"
    loopback = parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost")
    if not (google or loopback):
        raise RuntimeError("gemini-voix : seul https://generativelanguage.googleapis.com est autorisé comme base_url.")
    return raw if raw.endswith(("/v1beta", "/v1")) else raw + "/v1beta"


def _error(response) -> RuntimeError:
    try:
        detail = response.json().get("error", {}).get("message") or response.text
    except Exception:
        detail = getattr(response, "text", "")
    return RuntimeError(f"Gemini TTS a refusé la requête (HTTP {response.status_code}) : {str(detail)[:300]}")


class _VoiceResolver:
    """``voice_…`` ids pass through; prebuilt names are canonicalized; any other value is looked up
    by display name among the project's stored voices, then the Extended Voice Library."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._cache: Dict[Tuple[str, str], Tuple[float, str]] = {}

    def resolve(self, value: Optional[str], base: str, key: str) -> str:
        wanted = (value or "").strip()
        if not wanted:
            return DEFAULT_VOICE
        if wanted.startswith(("voice_", "voicekey_")):
            return wanted
        if wanted.casefold() in _PREBUILT_BY_KEY:
            return _PREBUILT_BY_KEY[wanted.casefold()]
        cache_key = (base, wanted.casefold())
        with self._lock:
            hit = self._cache.get(cache_key)
            if hit and time.monotonic() - hit[0] < _VOICE_CACHE_SECONDS:
                return hit[1]
        resolved = self._lookup(wanted, base, key)
        with self._lock:
            self._cache[cache_key] = (time.monotonic(), resolved)
        return resolved

    @staticmethod
    def _lookup(name: str, base: str, key: str) -> str:
        import requests
        attempts = ([("type", "prompted"), ("type", "replicated"), ("page_size", "200")],
                    [("search", name), ("page_size", "50")])
        for params in attempts:
            response = requests.get(f"{base}/voices", params=params, headers={"x-goog-api-key": key}, timeout=15)
            if response.status_code != 200:
                raise _error(response)
            for voice in response.json().get("voices") or []:
                if name.casefold() in (str(voice.get("display_name") or "").casefold(), str(voice.get("id") or "").casefold()):
                    return str(voice.get("id") or name)
        raise RuntimeError(f"Voix Gemini « {name} » introuvable : utilisez son identifiant voice_… ou son nom exact dans AI Studio.")


_resolver = _VoiceResolver()


def _body(text: str, model: str, voice: str, style: str, stream: bool) -> Dict[str, Any]:
    part: Dict[str, Any] = {"type": "text", "text": text}
    if style:
        part["annotations"] = [{"type": "speech_metadata", "style": style}]
    response_format: Dict[str, Any] = {"type": "audio"}
    if stream:
        response_format.update({"mime_type": "audio/l16", "sample_rate": SAMPLE_RATE})
    else:
        response_format["mime_type"] = "audio/wav"
    body: Dict[str, Any] = {
        "model": model,
        "input": [{"type": "user_input", "content": [part]}],
        "response_format": response_format,
        "generation_config": {"speech_config": [{"voice": voice}]},
    }
    if stream:
        body["stream"] = True
    return body


def _audio_from_event(event: Any) -> Optional[str]:
    """Base64 audio carried by one streamed event (``step.delta`` with an audio delta)."""
    if not isinstance(event, dict):
        return None
    if event.get("event_type") == "error" or "error" in event and not event.get("delta"):
        error = event.get("error") or {}
        raise RuntimeError(f"Gemini TTS : {error.get('message') if isinstance(error, dict) else error}")
    delta = event.get("delta")
    if isinstance(delta, dict) and delta.get("type") == "audio" and delta.get("data"):
        return str(delta["data"])
    return None


def _audio_from_interaction(payload: Dict[str, Any]) -> bytes:
    """Last audio block of the model output (``steps[].content[].data``)."""
    blocks = [content for step in payload.get("steps") or [] if step.get("type") == "model_output"
              for content in step.get("content") or [] if content.get("type") == "audio" and content.get("data")]
    if not blocks:
        raise RuntimeError("Gemini TTS n’a renvoyé aucun audio.")
    return base64.b64decode(blocks[-1]["data"])


def _openai_section() -> Dict[str, Any]:
    try:
        from hermes_cli.config import load_config
        section = ((load_config() or {}).get("tts") or {}).get("openai")
        return section if isinstance(section, dict) else {}
    except Exception:
        return {}


def _fallback_wanted(settings: Dict[str, Any]) -> bool:
    """``tts.gemini.fallback``: "openai" keeps the call speaking, in another voice, when Gemini refuses (daily quota,
    outage). Off by default: the owner prefers an error to a different voice."""
    return str(settings.get("fallback", "none")).strip().lower() not in ("", "none", "off", "false", "0")


def _openai_key() -> str:
    from tools.tool_backend_helpers import resolve_provider_secret
    return resolve_provider_secret("OPENAI_API_KEY", "openai")


def _openai_request(text: str, response_format: str):
    import requests
    section = _openai_section()
    key = _openai_key()
    if not key:
        raise RuntimeError("Aucune clé OpenAI pour la voix de repli.")
    body = {"model": str(section.get("model") or "gpt-4o-mini-tts"), "voice": str(section.get("voice") or "alloy"), "input": text,
            "response_format": response_format, "instructions": FALLBACK_INSTRUCTIONS}
    return requests.post(OPENAI_TTS_URL, json=body, headers={"Authorization": f"Bearer {key}"}, timeout=(10, 60), stream=True)


class GeminiVoixProvider(TTSProvider):
    name = NAME
    streams_pcm = True
    stream_sample_rate = SAMPLE_RATE

    @property
    def display_name(self) -> str:
        return "Gemini 3.8 (voix personnalisée)"

    def is_available(self) -> bool:
        try:
            import requests  # noqa: F401
            return bool(_api_key())
        except Exception:
            return False

    def list_voices(self) -> list[dict[str, Any]]:
        return [{"id": name, "display": name} for name in PREBUILT]

    def default_model(self) -> Optional[str]:
        return DEFAULT_MODEL

    def list_models(self) -> list[dict[str, Any]]:
        return [{"id": "gemini-3.8-flash-lite-tts", "display": "Gemini 3.8 Flash-Lite TTS"},
                {"id": "gemini-3.8-flash-tts", "display": "Gemini 3.8 Flash TTS"}]

    def _request(self, voice: Optional[str], model: Optional[str]) -> Tuple[str, str, str, str, str]:
        settings = _settings()
        key = _api_key()
        if not key:
            raise RuntimeError("Ajoutez GEMINI_API_KEY dans les clés de ce profil pour utiliser Gemini.")
        base = _base_url(settings)
        chosen_model = str(settings.get("model") or model or DEFAULT_MODEL).strip()
        if not chosen_model.startswith("gemini-3"):
            chosen_model = DEFAULT_MODEL  # the built-in provider's 2.5 default cannot take stored voices
        chosen_voice = _resolver.resolve(str(settings.get("voice") or voice or ""), base, key)
        return base, key, chosen_model, chosen_voice, str(settings.get("style") or "").strip()

    def _stream_gemini(self, text: str, *, voice: Optional[str] = None, model: Optional[str] = None) -> Iterator[bytes]:
        import requests
        base, key, chosen_model, chosen_voice, style = self._request(voice, model)
        body = _body(text, chosen_model, chosen_voice, style, stream=True)
        headers = {"x-goog-api-key": key, "Content-Type": "application/json", "Accept": "text/event-stream"}
        sent = 0
        carry = b""
        with _http().post(f"{base}/interactions", json=body, headers=headers, timeout=(10, 60), stream=True) as response:
            if response.status_code != 200:
                raise _error(response)
            for raw in response.iter_lines(decode_unicode=True):
                line = (raw or "").strip()
                if not line or line.startswith((":", "event:", "id:")):
                    continue
                if line.startswith("data:"):
                    line = line[5:].strip()
                if line in ("[DONE]", ""):
                    continue
                try:
                    data = _audio_from_event(json.loads(line))
                except ValueError:
                    continue
                if not data:
                    continue
                chunk = carry + base64.b64decode(data)
                # int16 frames only: an odd trailing byte waits for the next chunk.
                usable = len(chunk) - (len(chunk) % 2)
                carry = chunk[usable:]
                if usable:
                    sent += usable
                    if sent > _MAX_STREAM_BYTES:
                        raise RuntimeError("Gemini TTS : flux audio anormalement long, interrompu.")
                    yield chunk[:usable]

    def _stream_openai(self, text: str) -> Iterator[bytes]:
        """Raw 24 kHz mono int16 PCM from OpenAI: the same wire format as Gemini's stream."""
        carry = b""
        with _openai_request(text, "pcm") as response:
            if response.status_code != 200:
                raise RuntimeError(f"La voix de repli a refusé la requête (HTTP {response.status_code}).")
            for chunk in response.iter_content(chunk_size=4800):
                chunk = carry + chunk
                usable = len(chunk) - (len(chunk) % 2)
                carry = chunk[usable:]
                if usable:
                    yield chunk[:usable]

    def stream(self, text: str, *, voice: Optional[str] = None, model: Optional[str] = None,
               format: str = "pcm", **extra: Any) -> Iterator[bytes]:
        started = False
        try:
            for chunk in self._stream_gemini(text, voice=voice, model=model):
                started = True
                yield chunk
            return
        except Exception as error:
            settings = _settings()
            # Never switch voices in the middle of a sentence; before the first sound, keep the call alive.
            if started or not _fallback_wanted(settings):
                raise
            logger.warning("gemini-voix: Gemini unavailable (%s), speaking with the OpenAI fallback voice", str(error)[:140])
        yield from self._stream_openai(text)

    def synthesize(self, text: str, output_path: str, *, voice: Optional[str] = None, model: Optional[str] = None,
                   speed: Optional[float] = None, format: str = "wav", **extra: Any) -> str:
        import requests
        try:
            base, key, chosen_model, chosen_voice, style = self._request(voice, model)
            response = _http().post(f"{base}/interactions", json=_body(text, chosen_model, chosen_voice, style, stream=False),
                                     headers={"x-goog-api-key": key, "Content-Type": "application/json"}, timeout=(10, 120))
            if response.status_code != 200:
                raise _error(response)
            audio = _audio_from_interaction(response.json())
        except Exception as error:
            if not _fallback_wanted(_settings()):
                raise
            logger.warning("gemini-voix: Gemini unavailable (%s), speaking with the OpenAI fallback voice", str(error)[:140])
            with _openai_request(text, "wav") as fallback:
                if fallback.status_code != 200:
                    raise RuntimeError(f"La voix de repli a refusé la requête (HTTP {fallback.status_code}).") from None
                audio = fallback.content
        # Unary Gemini 3.8 audio is WAV: keep the container honest in the file name.
        path = Path(output_path).with_suffix(".wav")
        path.write_bytes(audio)
        return str(path)


def register(ctx) -> None:
    ctx.register_tts_provider(GeminiVoixProvider())
