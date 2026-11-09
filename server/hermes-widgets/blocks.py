"""Blocks of the « À l'affiche » widget: the pieces an agent composes it with (figures, rings, a curve, a short list, a note),
each in a named slot with its own lifetime. The morning summary lays out the day, the mail watch keeps its own block, a
finance answer refreshes its figures, and none of them erases the others'. Same shapes as the chat's cards, cut down to what
a widget can show. Two more kinds carry no content and only place what the widget already has: `meteo` (the weather) and
`affiche` (the agent's lines, else the calendar).

One file per slot (`<profile>/widgets/blocs/<slot>.json`): two sessions writing different slots never race.
"""
from __future__ import annotations

import json
import math
import os
import re
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

MAX_SLOTS = 6
MAX_PER_CALL = 4
SLOT = re.compile(r"[a-z0-9][a-z0-9_-]{0,23}")
KINDS = ("metrics", "progress", "chart", "list", "note", "meteo", "affiche")
TONES = {"positive", "warning", "negative", "neutral"}
DEFAULT_HOURS, MAX_HOURS = 6.0, 48.0
DEFAULT_ORDER = 5
NUMBER_LIMIT = 1e12


def _clean(value: Any, limit: int) -> str:
    text = re.sub(r"[​-‏‪-‮⁠-⁩﻿]", "", str(value if value is not None else ""))
    text = re.sub(r"\s+", " ", re.sub(r"[\x00-\x1f\x7f]", " ", text)).strip()
    return text[: limit - 1] + "…" if len(text) > limit else text


def _symbol(value: Any) -> str:
    text = str(value or "").strip().lower()
    return text if re.fullmatch(r"[a-z0-9.]{1,40}", text) else ""


def _tone(value: Any) -> str:
    tone = _clean(value, 10).lower()
    return tone if tone in TONES else ""


def _number(value: Any) -> Optional[float]:
    """A finite number of sensible size, else None (a bool is not a number)."""
    if isinstance(value, bool):
        return None
    try:
        number = float(str(value).replace(",", ".").replace(" ", "").replace(" ", "")) if isinstance(value, str) else float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) and abs(number) < NUMBER_LIMIT else None


def _rows(value: Any, limit: int) -> List[Dict[str, Any]]:
    return [row for row in (value if isinstance(value, list) else [])[: 4 * limit] if isinstance(row, dict)]


def card(raw: Any) -> Dict[str, Any]:
    """The card as the widget gets it, every field cut to size. Raises ValueError (a message for the agent) when it shows nothing."""
    if not isinstance(raw, dict):
        raise ValueError("`carte` doit être un objet, comme une carte du chat.")
    kind = _clean(raw.get("type"), 12).lower()
    if kind not in KINDS:
        raise ValueError(f"Type de carte inconnu pour le widget : « {kind} ». Types possibles : {', '.join(KINDS)}.")
    out: Dict[str, Any] = {"type": kind, "title": _clean(raw.get("title"), 30), "icon": _symbol(raw.get("icon")),
                           "ask": _clean(raw.get("reply") or raw.get("ask"), 200), "tone": _tone(raw.get("tone"))}
    if kind == "metrics":
        items = [{"label": _clean(row.get("label"), 20), "value": _clean(row.get("value"), 14), "delta": _clean(row.get("delta"), 10),
                  "tone": _tone(row.get("tone"))} for row in _rows(raw.get("items"), 4)]
        out["items"] = [row for row in items if row["label"] and row["value"]][:4]
        if not out["items"]:
            raise ValueError("Carte metrics sans chiffre : donne `items` avec `label` et `value`.")
    elif kind == "progress":
        items = []
        for row in _rows(raw.get("items"), 3):
            value, goal = _number(row.get("value")), _number(row.get("goal"))
            if _clean(row.get("label"), 16) and value is not None and goal and goal > 0:
                items.append({"label": _clean(row.get("label"), 16), "value": value, "goal": goal, "unit": _clean(row.get("unit"), 6)})
        out["items"] = items[:3]
        if not out["items"]:
            raise ValueError("Carte progress sans objectif : donne `items` avec `label`, `value` et `goal` (positif).")
    elif kind == "chart":
        points = []
        for row in _rows(raw.get("points"), 24):
            value = _number(row.get("value"))
            if value is not None:
                points.append({"label": _clean(row.get("label"), 8), "value": value})
        out.update({"points": points[-24:], "value": _clean(raw.get("value"), 14), "delta": _clean(raw.get("delta"), 10),
                    "unit": _clean(raw.get("unit"), 4), "style": "bar" if str(raw.get("style")).lower() == "bar" else "line"})
        if len(out["points"]) < 2:
            raise ValueError("Carte chart : au moins 2 points `{label, value}`.")
    elif kind == "list":
        items = [{"title": _clean(row.get("title"), 40), "subtitle": _clean(row.get("subtitle"), 30), "value": _clean(row.get("value"), 14),
                  "icon": _symbol(row.get("icon")), "tone": _tone(row.get("tone"))} for row in _rows(raw.get("items"), 5)]
        out["items"] = [row for row in items if row["title"]][:5]
        if not out["items"]:
            raise ValueError("Carte list vide : donne `items` avec au moins un `title`.")
    elif kind == "note":
        out["text"] = _clean(raw.get("text"), 140)
        if not out["text"]:
            raise ValueError("Carte note vide : donne `text`.")
    return out


def _dir(home: Path) -> Path:
    return Path(home) / "widgets" / "blocs"


def _write(path: Path, data: Dict[str, Any]) -> None:
    """Atomic and private: a temporary file of its own, flushed, then renamed into place."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(dir=path.parent, prefix=".bloc-", suffix=".tmp")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(data, ensure_ascii=False))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
    except BaseException:
        try:
            os.unlink(name)
        except OSError:
            pass
        raise


def _alive(block: Any, now: datetime) -> bool:
    try:
        return isinstance(block, dict) and datetime.fromisoformat(str(block.get("expires_at"))) > now
    except (TypeError, ValueError):
        return False


def read(home: Path, now: Optional[datetime] = None) -> List[Dict[str, Any]]:
    """The profile's live blocks, in the widget's order (then by slot name). Expired files are removed on the way."""
    now = now or datetime.now(timezone.utc)
    blocks = []
    folder = _dir(home)
    for path in sorted(folder.glob("*.json")) if folder.is_dir() else []:
        try:
            block = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if _alive(block, now) and SLOT.fullmatch(str(block.get("slot", ""))):
            blocks.append(block)
        else:
            path.unlink(missing_ok=True)
    return sorted(blocks, key=lambda block: (int(block.get("order", DEFAULT_ORDER)), str(block.get("slot"))))


def publish(home: Path, args: Dict[str, Any], now: Optional[datetime] = None) -> Dict[str, Any]:
    """Applies a `widget_bloc` call: removals first, then each block written in its slot. Raises ValueError for the agent."""
    now = now or datetime.now(timezone.utc)
    args = args if isinstance(args, dict) else {}
    removed = []
    erase = args.get("effacer")
    erase = [erase] if isinstance(erase, str) else erase if isinstance(erase, list) else []
    for slot in [_clean(name, 24).lower() for name in erase[:MAX_SLOTS * 2]]:
        if slot == "tout":
            for path in _dir(home).glob("*.json") if _dir(home).is_dir() else []:
                path.unlink(missing_ok=True)
                removed.append(path.stem)
        elif SLOT.fullmatch(slot) and (_dir(home) / f"{slot}.json").exists():
            (_dir(home) / f"{slot}.json").unlink()
            removed.append(slot)
    rows = args.get("blocs") if isinstance(args.get("blocs"), list) else []
    if not rows and not removed and not erase:
        raise ValueError("Rien à faire : donne `blocs` (1 à 4) ou `effacer` (des emplacements, ou « tout »).")
    if len(rows) > MAX_PER_CALL:
        raise ValueError(f"Au plus {MAX_PER_CALL} blocs par appel.")
    ready = []
    for row in rows:
        row = row if isinstance(row, dict) else {}
        slot = _clean(row.get("emplacement"), 30).lower()
        if not SLOT.fullmatch(slot):
            raise ValueError(f"Emplacement invalide : « {slot} » (lettres minuscules, chiffres, - ou _ ; 24 au plus).")
        try:
            hours = float(row.get("valide_heures", DEFAULT_HOURS))
        except (TypeError, ValueError):
            hours = DEFAULT_HOURS
        hours = min(MAX_HOURS, max(0.25, hours if math.isfinite(hours) else DEFAULT_HOURS))
        order = _number(row.get("ordre"))
        ready.append({"slot": slot, "order": int(min(9, max(0, order))) if order is not None else DEFAULT_ORDER, "card": card(row.get("carte")),
                      "updated_at": now.isoformat(timespec="seconds"), "expires_at": (now + timedelta(hours=hours)).isoformat(timespec="seconds")})
    taken = {block["slot"] for block in read(home, now)}
    if len(taken | {block["slot"] for block in ready}) > MAX_SLOTS:
        raise ValueError(f"Au plus {MAX_SLOTS} emplacements en même temps : réutilise-en un ou efface-en un (`effacer`).")
    for block in ready:                                      # all checked before any is written
        _write(_dir(home) / f"{block['slot']}.json", block)
    return {"publies": [block["slot"] for block in ready], "effaces": removed,
            "widget": [{"emplacement": block["slot"], "type": block["card"]["type"], "ordre": block["order"], "jusqu_a": block["expires_at"]}
                       for block in read(home, now)]}


def with_blocks(payload: Dict[str, Any], profiles_dir: Optional[Path] = None, now: Optional[datetime] = None) -> Dict[str, Any]:
    """Adds `blocks`: each profile's live blocks, for the app."""
    root = Path(profiles_dir or os.environ.get("HERMES_PROFILES_DIR", "/opt/data/profiles"))
    blocks: Dict[str, Any] = {}
    try:
        profiles = sorted(entry for entry in root.iterdir() if entry.is_dir())
    except OSError:
        profiles = []
    for profile in profiles:
        try:
            found = read(profile, now)
        except OSError:
            continue
        if found:
            blocks[profile.name] = found
    return {**payload, "blocks": blocks}
