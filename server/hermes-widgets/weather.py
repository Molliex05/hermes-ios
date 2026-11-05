"""The weather part of the widget, from Open-Meteo (free, no key, no account) with no model in the loop: the temperature now,
the next hours and the next days for one place. The place is Saint-Constant unless `WIDGET_PLACE`, `WIDGET_LATITUDE` and
`WIDGET_LONGITUDE` say otherwise. Answers are cached for fifteen minutes, a failure for one minute (the last good answer is
kept up to three hours), and one slow call never holds the dashboard's thread pool: short timeout, one call at a time.
"""
from __future__ import annotations

import json
import logging
import os
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from typing import Any, Callable, Dict, List, Optional
from zoneinfo import ZoneInfo

PLACE = os.environ.get("WIDGET_PLACE", "Saint-Constant")
LATITUDE = float(os.environ.get("WIDGET_LATITUDE", "45.3667"))
LONGITUDE = float(os.environ.get("WIDGET_LONGITUDE", "-73.5667"))
TIMEZONE = os.environ.get("WIDGET_TIMEZONE", "America/Toronto")
ENDPOINT = "https://api.open-meteo.com/v1/forecast"
CACHE_SECONDS, FAILURE_SECONDS, STALE_SECONDS, VALID_MINUTES, TIMEOUT = 15 * 60, 60, 3 * 3600, 90, 4
HOURS, DAYS = 8, 4
log = logging.getLogger("hermes_widgets")

# WMO weather code → (description, SF Symbol by day, SF Symbol by night)
_CODES = {
    0: ("Ciel dégagé", "sun.max.fill", "moon.stars.fill"),
    1: ("Surtout dégagé", "cloud.sun.fill", "cloud.moon.fill"),
    2: ("Partiellement nuageux", "cloud.sun.fill", "cloud.moon.fill"),
    3: ("Couvert", "cloud.fill", "cloud.fill"),
    45: ("Brouillard", "cloud.fog.fill", "cloud.fog.fill"), 48: ("Brouillard givrant", "cloud.fog.fill", "cloud.fog.fill"),
    51: ("Bruine légère", "cloud.drizzle.fill", "cloud.drizzle.fill"), 53: ("Bruine", "cloud.drizzle.fill", "cloud.drizzle.fill"),
    55: ("Bruine dense", "cloud.drizzle.fill", "cloud.drizzle.fill"),
    56: ("Bruine verglaçante", "cloud.sleet.fill", "cloud.sleet.fill"), 57: ("Bruine verglaçante", "cloud.sleet.fill", "cloud.sleet.fill"),
    61: ("Pluie légère", "cloud.rain.fill", "cloud.rain.fill"), 63: ("Pluie", "cloud.rain.fill", "cloud.rain.fill"),
    65: ("Forte pluie", "cloud.heavyrain.fill", "cloud.heavyrain.fill"),
    66: ("Pluie verglaçante", "cloud.sleet.fill", "cloud.sleet.fill"), 67: ("Pluie verglaçante", "cloud.sleet.fill", "cloud.sleet.fill"),
    71: ("Neige légère", "cloud.snow.fill", "cloud.snow.fill"), 73: ("Neige", "cloud.snow.fill", "cloud.snow.fill"),
    75: ("Forte neige", "cloud.snow.fill", "cloud.snow.fill"), 77: ("Grains de neige", "snowflake", "snowflake"),
    80: ("Averses", "cloud.sun.rain.fill", "cloud.moon.rain.fill"), 81: ("Averses", "cloud.rain.fill", "cloud.rain.fill"),
    82: ("Fortes averses", "cloud.heavyrain.fill", "cloud.heavyrain.fill"),
    85: ("Averses de neige", "cloud.snow.fill", "cloud.snow.fill"), 86: ("Fortes averses de neige", "cloud.snow.fill", "cloud.snow.fill"),
    95: ("Orage", "cloud.bolt.rain.fill", "cloud.bolt.rain.fill"), 96: ("Orage et grêle", "cloud.bolt.rain.fill", "cloud.bolt.rain.fill"),
    99: ("Orage et grêle", "cloud.bolt.rain.fill", "cloud.bolt.rain.fill"),
}

_cache: Dict[str, Any] = {}
_lock = threading.Lock()


def describe(code: Any, day: bool = True) -> tuple:
    """(description, symbol) for a WMO code; an unknown code is a plain cloud."""
    try:
        text, by_day, by_night = _CODES[int(code)]
    except (KeyError, TypeError, ValueError):
        return "Variable", "cloud.fill"
    return text, by_day if day else by_night


def _number(value: Any) -> Optional[int]:
    try:
        return int(round(float(value)))
    except (TypeError, ValueError):
        return None


def _at(rows: Any, index: int, default: Any = None) -> Any:
    try:
        return rows[index]
    except (IndexError, TypeError, KeyError):
        return default


def build(raw: Dict[str, Any], now: datetime) -> Optional[Dict[str, Any]]:
    """The widget's weather from an Open-Meteo answer: now, the next hours, the next days. None when the answer has no `current`."""
    zone = now.tzinfo or ZoneInfo(TIMEZONE)
    current = raw.get("current") if isinstance(raw, dict) else None
    if not isinstance(current, dict) or _number(current.get("temperature_2m")) is None:
        return None
    day = bool(current.get("is_day", 1))
    summary, symbol = describe(current.get("weather_code"), day)
    hourly, daily = raw.get("hourly") or {}, raw.get("daily") or {}

    hours: List[Dict[str, Any]] = []
    for index, stamp in enumerate(hourly.get("time") or []):
        try:
            moment = datetime.fromisoformat(stamp).replace(tzinfo=zone)
        except (TypeError, ValueError):
            continue
        if moment < now.replace(minute=0, second=0, microsecond=0):
            continue
        temperature = _number(_at(hourly.get("temperature_2m"), index))
        if temperature is None:
            continue
        _, hour_symbol = describe(_at(hourly.get("weather_code"), index), bool(_at(hourly.get("is_day"), index, 1)))
        hours.append({"at": moment.isoformat(timespec="seconds"), "temp": temperature, "symbol": hour_symbol,
                      "rain": _number(_at(hourly.get("precipitation_probability"), index)) or 0})
        if len(hours) == HOURS:
            break

    days: List[Dict[str, Any]] = []
    today = now.date().isoformat()
    for index, stamp in enumerate(daily.get("time") or []):
        if str(stamp) < today:
            continue
        high, low = _number(_at(daily.get("temperature_2m_max"), index)), _number(_at(daily.get("temperature_2m_min"), index))
        if high is None or low is None:
            continue
        text, day_symbol = describe(_at(daily.get("weather_code"), index), True)
        days.append({"date": str(stamp), "summary": text, "symbol": day_symbol, "high": high, "low": low,
                     "rain": _number(_at(daily.get("precipitation_probability_max"), index)) or 0,
                     "sunrise": str(_at(daily.get("sunrise"), index, "")), "sunset": str(_at(daily.get("sunset"), index, ""))})
        if len(days) == DAYS:
            break

    return {"place": PLACE, "temp": _number(current.get("temperature_2m")), "feels": _number(current.get("apparent_temperature")),
            "wind": _number(current.get("wind_speed_10m")), "summary": summary, "symbol": symbol, "day": day,
            "hours": hours, "days": days, "updated_at": now.isoformat(timespec="seconds"),
            "expires_at": (now + timedelta(minutes=VALID_MINUTES)).isoformat(timespec="seconds")}


def _fetch() -> Dict[str, Any]:
    query = urllib.parse.urlencode({
        "latitude": LATITUDE, "longitude": LONGITUDE, "timezone": TIMEZONE, "forecast_days": DAYS, "wind_speed_unit": "kmh",
        "current": "temperature_2m,apparent_temperature,weather_code,is_day,wind_speed_10m",
        "hourly": "temperature_2m,precipitation_probability,weather_code,is_day",
        "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"})
    with urllib.request.urlopen(f"{ENDPOINT}?{query}", timeout=TIMEOUT) as response:      # a fixed https address, nothing from a caller
        return json.loads(response.read(512_000).decode("utf-8"))


def current(now: Optional[datetime] = None, fetch: Callable[[], Dict[str, Any]] = _fetch) -> Optional[Dict[str, Any]]:
    """The weather of the place, or None when Open-Meteo does not answer (and nothing recent is kept)."""
    try:
        with _lock:                                             # simultaneous refreshes share one call
            cached = _cache.get("weather")
            if cached and time.time() - cached["at"] < (CACHE_SECONDS if cached["fresh"] else FAILURE_SECONDS):
                return cached["weather"]
            now = now or datetime.now(ZoneInfo(TIMEZONE))
            try:
                made = build(fetch(), now)
            except Exception as error:                          # only the kind of failure is logged, never its text
                log.warning("Widget weather unavailable (%s)", type(error).__name__)
                made = None
            if made is not None:
                _cache["weather"] = {"at": time.time(), "good_at": time.time(), "fresh": True, "weather": made}
                return made
            # A failure is tried again in a minute; the last good answer is kept meanwhile, for three hours at most.
            kept = cached["weather"] if cached and cached["weather"] and time.time() - cached["good_at"] < STALE_SECONDS else None
            _cache["weather"] = {"at": time.time(), "good_at": cached["good_at"] if kept else 0, "fresh": False, "weather": kept}
            return kept
    except Exception as error:
        log.warning("Widget weather failed (%s)", type(error).__name__)
        return None


def with_weather(payload: Dict[str, Any], source: Callable[[], Optional[Dict[str, Any]]] = current) -> Dict[str, Any]:
    """Adds `weather` to the board payload when there is some; the payload is otherwise returned as it came."""
    try:
        found = source()
    except Exception:
        found = None
    return {**payload, "weather": found} if found else payload
