"""Records the voice call's progress lines (``HermesIOS/Core/VoiceProgress.swift``) in the agent's own Gemini voice.

Run inside the Hermes container, from /opt/hermes, as the profile whose voice the calls use:

    HERMES_HOME=/opt/data/profiles/personnel python3 record_progress_lines.py lines.json out_dir

``lines.json`` maps a clip name to its text (``VoiceProgress.lines``). Each clip is written as raw 24 kHz mono int16 PCM
(``<clip>.pcm``), the format of the fillers in ``HermesIOS/Resources/Filler``; copy them to
``HermesIOS/Resources/Progress``. One Gemini TTS request per missing line, 7 s apart (Tier 1: 10 a minute, 100 a day),
never the fallback voice; lines already in ``out_dir`` are kept.
"""
from __future__ import annotations

import importlib.util
import json
import pathlib
import sys
import time

PLUGIN = pathlib.Path("/opt/data/plugins/gemini-voix/__init__.py")


def main(lines_path: str, out_dir: str) -> None:
    spec = importlib.util.spec_from_file_location("gemini_voix", PLUGIN, submodule_search_locations=[str(PLUGIN.parent)])
    module = importlib.util.module_from_spec(spec)
    sys.modules["gemini_voix"] = module
    spec.loader.exec_module(module)
    if module.SAMPLE_RATE != 24000:
        sys.exit(f"Unexpected sample rate {module.SAMPLE_RATE}: the app plays these clips at 24 kHz.")
    provider = module.GeminiVoixProvider()
    out = pathlib.Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for clip, text in json.loads(pathlib.Path(lines_path).read_text(encoding="utf-8")).items():
        if (out / f"{clip}.pcm").exists():
            continue                                         # recorded by an earlier run: no request spent again
        time.sleep(7)                                        # 10 requests a minute on Tier 1
        pcm = b"".join(provider._stream_gemini(text))      # Gemini only: a fallback voice would not match the call
        (out / f"{clip}.pcm").write_bytes(pcm)
        print(f"{clip}: {len(pcm) / 48000:.1f} s")


if __name__ == "__main__":
    main(*sys.argv[1:3])
