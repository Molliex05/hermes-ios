#!/usr/bin/env python3
"""Compares speech-to-text providers on recorded sentences: word error rate, proper-noun hits, latency.

Runs inside the Hermes container (it needs the provider keys of a profile):
  HERMES_HOME=/opt/data/profiles/<profile> /opt/hermes/.venv/bin/python stt_compare.py <dir> [--providers a,b,...]

<dir> holds N .wav files plus references.txt (one reference sentence per line). Files are matched to the
references by sorted file name, or by the file stem when it equals the reference's first column
(`stem|sentence`). Providers without a key are skipped. Nothing is written back.
"""
import json
import re
import sys
import time
import unicodedata
from pathlib import Path

sys.path.insert(0, "/opt/hermes")
from tools.transcription_tools import _dispatch_stt_provider  # noqa: E402

PROMPT = ("Conversation en français canadien (Québec). Noms propres possibles : Noriven, Glutax, Minori, Noryv, Hermès, "
          "Jarvis, Saint-Constant, MRR, Gemini, Open-Meteo, Tailscale, Supabase, RevenueCat.")
NAMES = ["noriven", "glutax", "minori", "hermes", "jarvis", "saint-constant", "mrr", "app store", "apple intelligence"]

# name -> (provider, stt config)
VARIANTS = {
    "openai/whisper-1": ("openai", {"openai": {"model": "whisper-1"}, "language": "fr"}),
    "openai/whisper-1+prompt": ("openai", {"openai": {"model": "whisper-1"}, "language": "fr", "prompt": PROMPT}),
    "openai/gpt-4o-transcribe": ("openai", {"openai": {"model": "gpt-4o-transcribe"}, "language": "fr"}),
    "openai/gpt-4o-transcribe+prompt": ("openai", {"openai": {"model": "gpt-4o-transcribe"}, "language": "fr", "prompt": PROMPT}),
    "openai/gpt-4o-mini-transcribe+prompt": ("openai", {"openai": {"model": "gpt-4o-mini-transcribe"}, "language": "fr", "prompt": PROMPT}),
    "groq/whisper-large-v3-turbo": ("groq", {"groq": {"model": "whisper-large-v3-turbo", "language": "fr"}, "language": "fr"}),
    "groq/whisper-large-v3-turbo+prompt": ("groq", {"groq": {"model": "whisper-large-v3-turbo", "language": "fr"}, "language": "fr", "prompt": PROMPT}),
    "groq/whisper-large-v3+prompt": ("groq", {"groq": {"model": "whisper-large-v3", "language": "fr"}, "language": "fr", "prompt": PROMPT}),
}


def normalize(text: str) -> list:
    text = unicodedata.normalize("NFKD", text.lower())
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = re.sub(r"[^a-z0-9' -]", " ", text.replace("-", " "))
    return text.split()


def edit_distance(a: list, b: list) -> int:
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        prev, row[0] = row[0], i
        for j, y in enumerate(b, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (x != y))
    return row[-1]


def main() -> None:
    folder = Path(sys.argv[1])
    wanted = sys.argv[sys.argv.index("--providers") + 1].split(",") if "--providers" in sys.argv else list(VARIANTS)
    references = [line.strip() for line in (folder / "references.txt").read_text(encoding="utf-8").splitlines() if line.strip()]
    keyed = {}
    for line in references:
        if "|" in line:
            stem, sentence = line.split("|", 1)
            keyed[stem.strip()] = sentence.strip()
    files = sorted(folder.glob("*.wav"))
    pairs = [(f, keyed[f.stem]) for f in files if f.stem in keyed] if keyed else list(zip(files, references))
    print(f"{len(pairs)} phrases · fournisseurs : {', '.join(wanted)}\n")
    summary = []
    for name in wanted:
        provider, config = VARIANTS[name]
        errors = words = hits = total_names = 0
        latencies, failures, last = [], 0, ""
        for path, reference in pairs:
            started = time.time()
            try:
                result = _dispatch_stt_provider(str(path), provider, config, None, "bench")
            except Exception as error:      # never print keys or audio details
                result = {"success": False, "error": type(error).__name__}
            latencies.append(time.time() - started)
            if not result.get("success"):
                failures += 1; last = str(result.get("error", ""))[:90]; continue
            heard = normalize(str(result.get("transcript", "")))
            truth = normalize(reference)
            errors += edit_distance(truth, heard); words += len(truth)
            for known in NAMES:
                if known.replace("-", " ") in " ".join(truth):
                    total_names += 1; hits += known.replace("-", " ") in " ".join(heard)
        if failures == len(pairs):
            print(f"{name:<40} indisponible ({last})"); continue
        latencies.sort()
        summary.append((name, errors / max(words, 1), hits, total_names, latencies[len(latencies) // 2], latencies[-1], failures))
    print(f"{'variante':<40}{'erreurs mots':>13}{'noms propres':>14}{'médiane':>9}{'max':>7}{'échecs':>8}")
    for name, wer, hits, names, median, worst, failures in sorted(summary, key=lambda r: r[1]):
        print(f"{name:<40}{wer * 100:>12.1f}%{f'{hits}/{names}':>14}{median:>8.2f}s{worst:>6.2f}s{failures:>8}")


if __name__ == "__main__":
    main()
