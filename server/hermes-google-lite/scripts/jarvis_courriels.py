"""Cron monitor for Jarvis's mailbox (``hermes cron create --monitor-script``).

Prints one stable line per *incident*: messages with the same sender domain and the same subject once numbers are
masked (eight « AWS: service disruption in us-east-1 » mails make one line « ×8 »). The text only changes when a new
message arrives, so Hermes wakes the agent only then and a quiet mailbox costs nothing. Archiving or labelling never
changes it: the window is « received in the last 3 days », whatever the label. No timestamps, no read state, no
message content.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
from pathlib import Path

PLUGIN = Path(os.environ.get("JARVIS_GOOGLE_PLUGIN", "/opt/data/plugins/hermes-google-lite"))
SEEN = Path(__file__).with_name(".courriels_vus.json")
QUERY = "newer_than:3d -in:sent -in:drafts -in:trash -in:spam"
WINDOW = 25
MAX_IDS = 8


def load_api():
    spec = importlib.util.spec_from_file_location("jarvis_google_api", PLUGIN / "google_api.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def group_key(description: str) -> str:
    """« sender | subject » → sender domain + subject with Re:/Fwd: and digits masked."""
    sender, _, subject = description.partition(" | ")
    domain = sender.rsplit("@", 1)[-1].strip("<> ").lower()
    subject = re.sub(r"^(?:(?:re|fwd?|tr)\s*:\s*)+", "", subject.lower().strip())
    return domain + "|" + re.sub(r"\s+", " ", re.sub(r"\d+", "#", subject))


def clean(text: str, limit: int) -> str:
    return " ".join(str(text or "").split())[:limit]


def render(api, seen_path: Path = SEEN) -> str:
    if not api.configured():
        raise RuntimeError("Google n'est pas configuré pour ce profil.")
    listing = api.request("GET", f"{api.GMAIL}/messages", params={"q": QUERY, "maxResults": WINDOW})
    ids = [m["id"] for m in listing.get("messages") or []]
    try:
        cache = json.loads(seen_path.read_text())
    except (OSError, ValueError):
        cache = {}
    fresh = {}
    for identifier in ids:
        if identifier in cache:
            fresh[identifier] = cache[identifier]
            continue
        message = api.request("GET", f"{api.GMAIL}/messages/{identifier}", params={"format": "metadata", "metadataHeaders": ["From", "Subject"]})
        headers = {h.get("name", "").casefold(): h.get("value", "") for h in (message.get("payload") or {}).get("headers") or []}
        fresh[identifier] = f"{clean(headers.get('from'), 70)} | {clean(headers.get('subject'), 90)}"
    seen_path.write_text(json.dumps(fresh, ensure_ascii=False)); seen_path.chmod(0o600)
    groups: dict = {}
    for identifier in ids:                       # newest first, so a group sits where its newest message is
        groups.setdefault(group_key(fresh[identifier]), []).append(identifier)
    lines = []
    for members in groups.values():
        shown = " ".join(members[:MAX_IDS]) + (f" (+{len(members) - MAX_IDS})" if len(members) > MAX_IDS else "")
        lines.append(f"×{len(members)} | {fresh[members[0]]} | ids: {shown}")
    return "\n".join(lines)


if __name__ == "__main__":
    try:
        print(render(load_api()))
    except Exception as error:               # a failure is reported by Hermes, never silently treated as « no mail »
        print(f"surveillance courriels: {type(error).__name__}: {str(error)[:160]}", file=sys.stderr)
        sys.exit(1)
