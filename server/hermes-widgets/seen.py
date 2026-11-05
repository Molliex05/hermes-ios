"""« Vu » on the widget archives its emails at once. The mail watchers that used to do it no longer run: they read the boxes
every 5 minutes, which is what Maxime wanted gone. The archiving itself stays theirs (`archive_seen`, in each mail plugin), and
a « Vu » that fails stays in `widgets/a_classer` and is tried again when the widget next refreshes (`retry`), a week at most.
Never trash, never delete.
"""
from __future__ import annotations

import importlib.util
import logging
import os
import threading
from pathlib import Path
from typing import Any, Callable

log = logging.getLogger("hermes_widgets")

PLUGINS = Path(os.environ.get("HERMES_PLUGINS_DIR", "/opt/data/plugins"))
GMAIL_SCRIPT = PLUGINS / "hermes-google-lite" / "scripts" / "jarvis_courriels.py"
NORIVEN_SCRIPT = "scripts/hermes_courriels.py"          # kept in the profile, beside its memory of the mail seen


def _script(path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(f"seen_{path.stem}", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_retrying = threading.Lock()


def retry(root: Path, agenda: Any, load: Callable[[Path], Any] = _script) -> int:
    """Every profile's « Vu » still waiting; only one pass at a time, and none at all when nothing waits."""
    if not _retrying.acquire(blocking=False):
        return 0
    try:
        done = 0
        for folder in sorted(Path(root).glob("*/widgets/a_classer")):
            try:
                done += archive(root, folder.parent.parent.name, agenda, load)
            except Exception as error:
                log.warning("Seen emails not archived (%s)", type(error).__name__)
        return done
    finally:
        _retrying.release()


def read_noriven(root: Path, profile: str, agenda: Any, message_id: str, load: Callable[[Path], Any] = _script) -> dict:
    """A Noriven message's whole text for its card, through the same agent access. Reading marks nothing as read."""
    script = load(Path(root) / profile / NORIVEN_SCRIPT)
    api = script.load_api(agenda.read_env(root, profile, script.KEYS))
    message = api.request("GET", api.message_path(message_id))
    return {"id": message_id, "texte": message.get("text") or "", "tronque": bool(message.get("truncated"))}


def archive(root: Path, profile: str, agenda: Any, load: Callable[[Path], Any] = _script) -> int:
    """How many emails left the inbox. Gmail for a profile with Google, else the Noriven boxes."""
    folder = Path(root) / profile / "widgets" / "a_classer"
    if not any(folder.glob("*.json")):
        return 0
    if agenda.has_google(root, profile):
        return load(GMAIL_SCRIPT).archive_seen(agenda._google(root, profile), folder)
    script = load(Path(root) / profile / NORIVEN_SCRIPT)
    return script.archive_seen(script.load_api(agenda.read_env(root, profile, script.KEYS)), folder)
