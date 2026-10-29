"""The agenda part of the widget, read straight from Google Calendar with no model in the loop: the next events of the
profiles that have Google set up, so the widget is useful even when the agent has written nothing.

It uses the same Google plugin and credentials as the agent's `agenda_lister` (read only: events of every calendar the account
shows, merged by start time). The dashboard process has no profile of its own, so the credentials are read from the profile's
`.env` and handed to a private copy of the Google module; they go nowhere else. Answers are cached for five minutes.
"""
from __future__ import annotations

import importlib.util
import os
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional
from zoneinfo import ZoneInfo

GOOGLE_PLUGIN = Path(os.environ.get("HERMES_GOOGLE_PLUGIN", "/opt/data/plugins/hermes-google-lite"))
TIMEZONE = os.environ.get("WIDGET_TIMEZONE", "America/Toronto")
CACHE_SECONDS, MAX_ITEMS, VALID_MINUTES = 300, 5, 120
LOOKBACK, LOOKAHEAD = timedelta(hours=1), timedelta(hours=36)
NEEDED = ("GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "GOOGLE_REFRESH_TOKEN")

_cache: Dict[str, Dict[str, Any]] = {}
_modules: Dict[str, Any] = {}


def read_env(profiles_dir: Path, profile: str) -> Dict[str, str]:
    values: Dict[str, str] = {}
    try:
        for line in (profiles_dir / profile / ".env").read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip().strip("\"'")
    except OSError:
        pass
    return values


def has_google(profiles_dir: Path, profile: str) -> bool:
    env = read_env(profiles_dir, profile)
    return all(env.get(name) for name in NEEDED)


def _google(profiles_dir: Path, profile: str):
    """A private copy of the Google module that reads this profile's credentials."""
    if profile not in _modules:
        spec = importlib.util.spec_from_file_location(f"widget_google_{profile}", GOOGLE_PLUGIN / "google_api.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        env = read_env(profiles_dir, profile)
        module._env = lambda name, _env=env: str(_env.get(name, "")).strip()
        _modules[profile] = module
    return _modules[profile]


def _parse(value: str, zone: ZoneInfo) -> Optional[datetime]:
    try:
        moment = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment.astimezone(zone) if moment.tzinfo else moment.replace(tzinfo=zone)


def _text(value: Any, limit: int) -> str:
    text = " ".join(str(value or "").split())
    return text[: limit - 1] + "…" if len(text) > limit else text


def build(events: List[Dict[str, Any]], now: datetime) -> Dict[str, Any]:
    """The widget board for a list of `calendar_list` events: what is happening or coming, five at most."""
    zone = now.tzinfo or ZoneInfo(TIMEZONE)
    today, tomorrow = now.date(), (now + timedelta(days=1)).date()
    timed, whole_day = [], []
    for event in events:
        if event.get("statut") == "cancelled":
            continue
        start, title = str(event.get("debut") or ""), _text(event.get("titre"), 80)
        if not start or not title:
            continue
        place = _text(event.get("lieu"), 40) or _text(event.get("calendrier"), 40)
        if "T" not in start:                                   # an all-day event: only today's, as a line without a time
            day = _parse(start + "T00:00:00", zone)
            if day and day.date() == today:
                whole_day.append({"text": title, "time": "", "detail": "Toute la journée", "icon": "", "tone": ""})
            continue
        begin, end = _parse(start, zone), _parse(str(event.get("fin") or ""), zone)
        if not begin or (end or begin + timedelta(minutes=30)) < now - LOOKBACK:
            continue
        label = "Demain" if begin.date() == tomorrow else "" if begin.date() == today else begin.strftime("%-d %b")
        timed.append((begin, {"text": title, "time": begin.strftime("%H:%M"), "at": begin.isoformat(timespec="seconds"),
                              "detail": " · ".join(part for part in (label, place) if part), "icon": "", "tone": ""}))
    timed.sort(key=lambda pair: pair[0])
    items = ([item for _, item in timed] + whole_day[:1])[:MAX_ITEMS]
    first_today = bool(timed) and timed[0][0].date() == today
    return {"title": "Aujourd’hui" if first_today or (whole_day and not timed) else "Prochainement" if items else "Aujourd’hui",
            "items": items, "focus": "", "ask": "", "updated_at": now.isoformat(timespec="seconds"),
            "expires_at": (now + timedelta(minutes=VALID_MINUTES)).isoformat(timespec="seconds")}


def upcoming(profiles_dir: Path, profile: str, now: Optional[datetime] = None) -> Optional[Dict[str, Any]]:
    """The agenda board of one profile (an empty one on a free day), or None when Google is not set up or does not answer."""
    if not has_google(profiles_dir, profile):
        return None
    cached = _cache.get(profile)
    if cached and time.time() - cached["at"] < CACHE_SECONDS:
        return cached["board"]
    zone = ZoneInfo(TIMEZONE)
    now = now or datetime.now(zone)
    try:
        events = _google(profiles_dir, profile).calendar_list((now - LOOKBACK).isoformat(), (now + LOOKAHEAD).isoformat(), "", 30)
    except Exception:
        return cached["board"] if cached else None           # never forward upstream text; keep the last good answer
    board = build(events, now)
    _cache[profile] = {"at": time.time(), "board": board}
    return board
