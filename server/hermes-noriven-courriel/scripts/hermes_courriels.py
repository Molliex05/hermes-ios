"""Cron monitor for Hermès's mailboxes (Noriven's Polaris boxes, ``hermes cron create --monitor-script``).

Same idea as Jarvis's ``jarvis_courriels.py``. Prints one stable line per *incident*: messages of the same box, the same
sender domain and the same subject once numbers are masked. The text only changes when a new message arrives, so Hermes
wakes the agent only then, and a quiet mailbox costs nothing.

Messages are remembered from the moment they are first seen in a box's inbox, for 3 days. Archiving or filing a message
(which takes it out of the inbox) therefore never changes the text. No read state and no message content are printed:
only the box, the sender, the subject and the ids the agent needs.

Before that, it archives and marks read the emails Maxime marked « Vu » on the iPhone widget. The dashboard leaves one
file per tap in ``<profile>/widgets/a_classer``. No model is involved, and archiving never wakes the agent. A file that
fails stays for the next run, a week at most.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

PLUGIN = Path(os.environ.get("NORIVEN_COURRIEL_PLUGIN", "/opt/data/plugins/hermes-noriven-courriel"))
HOME = Path(__file__).resolve().parent.parent                       # <profile>/scripts/ → <profile>
SEEN = Path(__file__).with_name(".courriels_noriven_vus.json")
TO_FILE = Path(os.environ.get("NORIVEN_SEEN_DIR", HOME / "widgets" / "a_classer"))
DAYS, WINDOW, MAX_IDS, KEEP_DAYS = 3, 30, 4, 7
KEYS = ("NORIVEN_COURRIEL_URL", "NORIVEN_COURRIEL_TOKEN", "NORIVEN_COURRIEL_HOTES")


def profile_env(path: Path = HOME / ".env") -> dict:
    """The three agent settings from the profile's `.env` (the relay token is never read here)."""
    values = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return values
    for line in lines:
        line = line.strip().removeprefix("export ").strip()
        key, sep, value = line.partition("=")
        if sep and key.strip() in KEYS:
            value = value.strip()
            if value[:1] in "\"'" and value.count(value[0]) >= 2:
                value = value[1:value.index(value[0], 1)]
            else:
                value = value.split(" #", 1)[0].strip()
            values[key.strip()] = value
    return values


def load_api(env: dict):
    spec = importlib.util.spec_from_file_location("noriven_courriel_api", PLUGIN / "noriven_api.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module._env = lambda name, _env=env: str(_env.get(name, "")).strip()
    module.REFS_PATH = HOME / "cache" / "courriel_refs.sqlite3"     # the same references as the agent's tools
    return module


def group_key(mailbox: str, sender: str, subject: str) -> str:
    """Box + sender domain + subject with Re:/Fwd: and digits masked."""
    domain = sender.rsplit("@", 1)[-1].strip("<> ").lower()
    subject = re.sub(r"^(?:(?:re|fwd?|tr)\s*:\s*)+", "", subject.lower().strip())
    return mailbox + "|" + domain + "|" + re.sub(r"\s+", " ", re.sub(r"\d+", "#", subject))


def clean(text, limit: int) -> str:
    return " ".join(str(text or "").split())[:limit]


def _when(value) -> datetime:
    text = str(value or "")
    for parse in (lambda t: datetime.fromisoformat(t.replace("Z", "+00:00")), parsedate_to_datetime):
        try:
            moment = parse(text)
            return (moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)).astimezone(timezone.utc)
        except (TypeError, ValueError, IndexError):
            continue
    return datetime.now(timezone.utc)


def archive_seen(api, folder: Path = TO_FILE) -> int:
    """Marks read, then archives, the emails of every « Vu » waiting; returns how many. Never trash, never delete."""
    done = 0
    for entry in sorted(folder.glob("*.json")) if folder.is_dir() else []:
        try:
            ids = [str(i) for i in json.loads(entry.read_text(encoding="utf-8")).get("ids") or [] if api.ID.fullmatch(str(i)) or api.REF.fullmatch(str(i))][:100]
        except (OSError, ValueError, AttributeError):
            ids = []
        failed = False
        for message_id in ids:
            try:
                api.request("POST", api.message_path(message_id, "/organize"), body={"action": "mark_read"})
                path = api.message_path(message_id, "/organize")
                try:
                    api.request("POST", path, body={"action": "archive"})
                except api.NorivenError as error:
                    if error.status != 409:
                        raise
                    # The box's « Archive » folder is not flagged \\Archive: moved there by name (as the agent's tool does).
                    api.request("POST", path, body={"action": "move", "folder": "Archive"})
                done += 1
            except api.NorivenError as error:
                if error.status == 404:
                    continue                     # already moved or gone: nothing left to do for it
                failed = True
        if failed and time.time() - entry.stat().st_mtime < KEEP_DAYS * 86400:
            continue                             # the Dashboard unreachable: tried again on the next run
        entry.unlink(missing_ok=True)
    return done


def render(api, seen_path: Path = SEEN, now: datetime = None) -> str:
    if not api.configured():
        raise RuntimeError("Le courriel Noriven n'est pas configuré pour ce profil.")
    now = now or datetime.now(timezone.utc)
    since = (now - timedelta(days=DAYS)).date().isoformat()
    try:
        cache = json.loads(seen_path.read_text())
    except (OSError, ValueError):
        cache = {}
    boxes = [b.get("address") for b in api.request("GET", f"{api.BASE_PATH}/mailboxes").get("mailboxes") or [] if b.get("address")]
    for box in sorted(boxes):
        page = api.request("GET", f"{api.BASE_PATH}/messages", params={"mailbox": box, "folder": "inbox", "q": f"since:{since}", "limit": WINDOW})
        for message in page.get("messages") or []:
            identifier = str(message.get("id") or "")
            if api.ID.fullmatch(identifier) and identifier not in cache:
                cache[identifier] = {"box": box, "from": clean(message.get("from"), 70), "subject": clean(message.get("subject"), 90),
                                     "at": _when(message.get("date")).isoformat()}
    limit = now - timedelta(days=DAYS)
    cache = {k: v for k, v in cache.items() if _when(v.get("at")) >= limit}
    seen_path.write_text(json.dumps(cache, ensure_ascii=False)); seen_path.chmod(0o600)
    groups: dict = {}
    for identifier, entry in sorted(cache.items(), key=lambda item: item[1]["at"], reverse=True):   # newest first
        groups.setdefault(group_key(entry["box"], entry["from"], entry["subject"]), []).append(identifier)
    lines = []
    for members in groups.values():
        first = cache[members[0]]
        shown = " ".join(api.short(m) for m in members[:MAX_IDS]) + (f" (+{len(members) - MAX_IDS})" if len(members) > MAX_IDS else "")
        lines.append(f"×{len(members)} | {first['box']} | {first['from']} | {first['subject']} | ids: {shown}")
    return "\n".join(lines)


if __name__ == "__main__":
    try:
        api = load_api(profile_env())
        try:
            archive_seen(api)
        except Exception as error:           # never stops the watch itself
            print(f"archivage des courriels vus: {type(error).__name__}", file=sys.stderr)
        print(render(api))
    except Exception as error:               # a failure is reported by Hermes, never silently treated as « no mail »
        print(f"surveillance courriels Noriven: {type(error).__name__}: {str(error)[:160]}", file=sys.stderr)
        sys.exit(1)
