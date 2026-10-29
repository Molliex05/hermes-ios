"""The agenda part of the widget, read straight from Google Calendar with no model in the loop: the next events of the
profiles that have Google set up, so the widget is useful even when the agent has written nothing.

It uses the same Google plugin and credentials as the agent's `agenda_lister` (read only: events of every calendar the account
shows, merged by start time). The dashboard process has no profile of its own, so the three credentials are read from the
profile's `.env` and handed to a private copy of the Google module; they go nowhere else. Answers are cached for five minutes,
a failure for one minute, and one slow Google call never holds the dashboard's thread pool: short timeout, one call at a time
per profile.
"""
from __future__ import annotations

import importlib.util
import logging
import os
import sys
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional
from zoneinfo import ZoneInfo

GOOGLE_PLUGIN = Path(os.environ.get("HERMES_GOOGLE_PLUGIN", "/opt/data/plugins/hermes-google-lite"))
TIMEZONE = os.environ.get("WIDGET_TIMEZONE", "America/Toronto")
CACHE_SECONDS, FAILURE_SECONDS, MAX_ITEMS, VALID_MINUTES, GOOGLE_TIMEOUT = 300, 60, 5, 120, 4
LOOKBACK, LOOKAHEAD = timedelta(hours=1), timedelta(hours=36)
NEEDED = ("GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "GOOGLE_REFRESH_TOKEN")
MONTHS = ("janv", "févr", "mars", "avr", "mai", "juin", "juil", "août", "sept", "oct", "nov", "déc")
log = logging.getLogger("hermes_widgets")

_cache: Dict[str, Dict[str, Any]] = {}
_locks: Dict[str, threading.Lock] = {}
_modules: Dict[str, Dict[str, Any]] = {}
_guard = threading.Lock()


def read_env(profiles_dir: Path, profile: str) -> Dict[str, str]:
    """The three Google credentials of a profile's `.env` (and nothing else)."""
    values: Dict[str, str] = {}
    try:
        lines = (profiles_dir / profile / ".env").read_text(encoding="utf-8").splitlines()
    except OSError:
        return values
    for line in lines:
        line = line.strip()
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if key not in NEEDED:
            continue
        if value[:1] in "\"'" and value.count(value[0]) >= 2:
            value = value[1:value.index(value[0], 1)]
        else:
            value = value.split(" #", 1)[0].strip()
        values[key] = value
    return values


def has_google(profiles_dir: Path, profile: str) -> bool:
    env = read_env(profiles_dir, profile)
    return all(env.get(name) for name in NEEDED)


def _env_mtime(profiles_dir: Path, profile: str) -> float:
    try:
        return (profiles_dir / profile / ".env").stat().st_mtime
    except OSError:
        return 0.0


def _google(profiles_dir: Path, profile: str):
    """A private copy of the Google module that reads this profile's credentials, re-read when the `.env` changes (a
    re-authorised refresh token is picked up without a restart)."""
    mtime = _env_mtime(profiles_dir, profile)
    with _guard:
        entry = _modules.get(profile)
        if entry is None:
            spec = importlib.util.spec_from_file_location(f"widget_google_{profile}", GOOGLE_PLUGIN / "google_api.py")
            module = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = module
            spec.loader.exec_module(module)
            env: Dict[str, str] = {}
            module._env = lambda name, _env=env: str(_env.get(name, "")).strip()
            module.TIMEOUT = GOOGLE_TIMEOUT
            entry = _modules[profile] = {"module": module, "env": env, "mtime": None}
        if entry["mtime"] != mtime:
            entry["env"].clear()
            entry["env"].update(read_env(profiles_dir, profile))
            entry["module"]._token.update(value="", expires=0.0)       # the old access token belongs to the old credentials
            entry["mtime"] = mtime
        return entry["module"]


def _parse(value: str, zone: ZoneInfo) -> Optional[datetime]:
    try:
        moment = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment.astimezone(zone) if moment.tzinfo else moment.replace(tzinfo=zone)


def _text(value: Any, limit: int) -> str:
    text = " ".join(str(value or "").split())
    return text[: limit - 1] + "…" if len(text) > limit else text


def _day(value: str, zone: ZoneInfo):
    moment = _parse(str(value) + "T00:00:00", zone) if value and "T" not in str(value) else None
    return moment.date() if moment else None


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
        if "T" not in start:
            # An all-day event, possibly over several days (Google's end date is exclusive): shown on each of its days.
            first, last = _day(start, zone), _day(str(event.get("fin") or ""), zone)
            if first and (last is None or last <= first):
                last = first + timedelta(days=1)
            if first and last and first <= today < last:
                whole_day.append({"text": title, "time": "", "detail": "Toute la journée", "icon": "", "tone": ""})
            continue
        begin, end = _parse(start, zone), _parse(str(event.get("fin") or ""), zone)
        if not begin or (end or begin + timedelta(minutes=30)) < now - LOOKBACK:
            continue
        label = "Demain" if begin.date() == tomorrow else "" if begin.date() <= today else f"{begin.day} {MONTHS[begin.month - 1]}"
        running = bool(end) and begin <= now < end
        until = f"jusqu’à {end.strftime('%H:%M')}" if running and end else ""
        item = {"text": title, "time": begin.strftime("%H:%M"), "at": begin.isoformat(timespec="seconds"),
                "detail": " · ".join(part for part in (label, until, place) if part), "icon": "", "tone": ""}
        if end:
            item["until"] = end.isoformat(timespec="seconds")
        timed.append((begin, item))
    timed.sort(key=lambda pair: pair[0])
    items = ([item for _, item in timed] + whole_day[:1])[:MAX_ITEMS]
    today_items = bool(whole_day) or any(begin.date() <= today for begin, _ in timed)
    return {"title": "Prochainement" if items and not today_items else "Aujourd’hui",
            "items": items, "focus": "", "ask": "", "updated_at": now.isoformat(timespec="seconds"),
            "expires_at": (now + timedelta(minutes=VALID_MINUTES)).isoformat(timespec="seconds")}


def upcoming(profiles_dir: Path, profile: str, now: Optional[datetime] = None) -> Optional[Dict[str, Any]]:
    """The agenda board of one profile (an empty one on a free day), or None when Google is not set up or does not answer."""
    try:
        if not has_google(profiles_dir, profile):
            return None
        with _guard:
            lock = _locks.setdefault(profile, threading.Lock())
        with lock:                                              # simultaneous refreshes share one Google round trip
            cached = _cache.get(profile)
            age = time.time() - cached["at"] if cached else None
            if cached and age is not None and age < (CACHE_SECONDS if cached["board"] is not None else FAILURE_SECONDS):
                return cached["board"]
            zone = ZoneInfo(TIMEZONE)
            now = now or datetime.now(zone)
            try:
                events = _google(profiles_dir, profile).calendar_list((now - LOOKBACK).isoformat(), (now + LOOKAHEAD).isoformat(), "", 30)
                board = build(events, now)
            except Exception as error:                        # only the kind of failure is logged, never its text
                log.warning("Widget agenda unavailable for %s (%s)", profile, type(error).__name__)
                _cache[profile] = {"at": time.time(), "board": None}
                return cached["board"] if cached and cached["board"] else None
            _cache[profile] = {"at": time.time(), "board": board}
            return board
    except Exception as error:
        log.warning("Widget agenda failed for %s (%s)", profile, type(error).__name__)
        return None
