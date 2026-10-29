"""The agent's board (« À l'affiche »): what it chose to show on the iPhone widget.

An agent writes its own board with `widget_publier` whenever it has something worth showing, and the dashboard serves every
profile's board to the app (`/board`). Writing a board never notifies anyone: a notification is a separate, explicit
`ios_notify` call. The board expires by itself, so the widget never shows yesterday's news.
"""
from __future__ import annotations

import json
import os
import re
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, Optional

MAX_ITEMS = 5
DEFAULT_HOURS, MAX_HOURS = 6.0, 48.0
TONES = {"positive", "warning", "negative", "neutral"}


def _clean(value: Any, limit: int) -> str:
    text = re.sub(r"[\u200b-\u200f\u202a-\u202e\u2060-\u2069\ufeff]", "", str(value if value is not None else ""))   # bidi and zero-width marks
    text = re.sub(r"\s+", " ", re.sub(r"[\x00-\x1f\x7f]", " ", text)).strip()
    return text[: limit - 1] + "…" if len(text) > limit else text


def _symbol(value: Any) -> str:
    """An SF Symbol name or nothing: letters, digits and dots."""
    text = str(value or "").strip().lower()
    return text if re.fullmatch(r"[a-z0-9.]{1,40}", text) else ""


def build(args: Dict[str, Any], now: Optional[datetime] = None) -> Dict[str, Any]:
    """The board for these tool arguments. Raises ValueError (a message for the agent) when there is nothing to show."""
    now = now or datetime.now(timezone.utc)
    items = []
    for row in (args.get("lignes") if isinstance(args.get("lignes"), list) else [])[:4 * MAX_ITEMS]:
        if len(items) >= MAX_ITEMS:
            break
        row = row if isinstance(row, dict) else {"texte": row}
        text = _clean(row.get("texte"), 80)
        if not text:
            continue
        tone = _clean(row.get("ton"), 10).lower()
        items.append({"text": text, "detail": _clean(row.get("detail"), 50), "time": _clean(row.get("heure"), 12),
                      "icon": _symbol(row.get("icone")), "tone": tone if tone in TONES else ""})
    focus = _clean(args.get("a_retenir"), 140)
    if not items and not focus:
        raise ValueError("Rien à afficher : donne au moins une ligne (`lignes`) ou `a_retenir`. Pour vider le tableau, passe `effacer`.")
    try:
        hours = float(args.get("valide_heures", DEFAULT_HOURS))
    except (TypeError, ValueError):
        hours = DEFAULT_HOURS
    hours = min(MAX_HOURS, max(0.25, hours))
    return {"title": _clean(args.get("titre"), 40), "items": items, "focus": focus, "ask": _clean(args.get("demander"), 200),
            "updated_at": now.isoformat(timespec="seconds"), "expires_at": (now + timedelta(hours=hours)).isoformat(timespec="seconds")}


def merge(existing: Optional[Dict[str, Any]], new: Dict[str, Any], now: Optional[datetime] = None) -> Dict[str, Any]:
    """`new` added to what the board already says: its lines first, then the earlier ones (a line with the same text is
    replaced), five at most; its note and title win when it has them; it stays valid as long as the longer of the two."""
    now = now or datetime.now(timezone.utc)
    try:
        alive = bool(existing) and datetime.fromisoformat(str(existing.get("expires_at"))) > now
    except (TypeError, ValueError):
        alive = False
    if not alive:
        return new
    seen, items = set(), []
    for row in list(new.get("items") or []) + list(existing.get("items") or []):
        key = str(row.get("text", "")).strip().lower()
        if key and key not in seen and len(items) < MAX_ITEMS:
            seen.add(key)
            items.append(row)
    return {**new, "title": new.get("title") or existing.get("title") or "", "items": items,
            "focus": new.get("focus") or existing.get("focus") or "", "ask": new.get("ask") or existing.get("ask") or "",
            "expires_at": max(str(new.get("expires_at")), str(existing.get("expires_at")))}


def path_for(home: Path) -> Path:
    return Path(home) / "widgets" / "board.json"


def save(home: Path, board: Dict[str, Any]) -> None:
    """Atomic and private: a temporary file of its own (two writers never share one), flushed, then renamed into place."""
    target = path_for(home)
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(dir=target.parent, prefix=".board-", suffix=".tmp")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(board, ensure_ascii=False))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, target)
    except BaseException:
        try:
            os.unlink(name)
        except OSError:
            pass
        raise


def clear(home: Path) -> bool:
    try:
        path_for(home).unlink()
        return True
    except FileNotFoundError:
        return False


def load_all(profiles_dir: Optional[Path] = None) -> Dict[str, Any]:
    """Every profile's board, for the app: `{"version": 1, "boards": {profile: board}}`. A board that cannot be read is skipped."""
    root = Path(profiles_dir or os.environ.get("HERMES_PROFILES_DIR", "/opt/data/profiles"))
    boards: Dict[str, Any] = {}
    try:
        profiles = sorted(entry for entry in root.iterdir() if entry.is_dir())
    except OSError:
        profiles = []
    for profile in profiles:
        try:
            board = json.loads(path_for(profile).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(board, dict):
            boards[profile.name] = board
    return {"version": 1, "boards": boards}


def with_agendas(payload: Dict[str, Any], profiles_dir: Optional[Path] = None, source=None) -> Dict[str, Any]:
    """Adds `agendas`: for each profile with Google set up, the next events straight from the calendar (no model)."""
    root = Path(profiles_dir or os.environ.get("HERMES_PROFILES_DIR", "/opt/data/profiles"))
    agendas: Dict[str, Any] = {}
    try:
        profiles = sorted(entry.name for entry in root.iterdir() if entry.is_dir())
    except OSError:
        profiles = []
    for profile in profiles:
        try:
            board = source(root, profile) if source else None
        except Exception:
            board = None
        if board is not None:
            agendas[profile] = board
    return {**payload, "agendas": agendas}
