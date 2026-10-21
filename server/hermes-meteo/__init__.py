"""`meteo`: current conditions and a short forecast from Open-Meteo (free, no key, no account).

Only two fixed hosts are ever contacted; the agent supplies a place name or coordinates, never a URL.
Optional per-profile default place: ``meteo.lieu_defaut`` in config.yaml (e.g. "Québec").
"""
from __future__ import annotations

import json
from typing import Any, Dict, Optional

TOOLSET = "meteo"
GEOCODING = "https://geocoding-api.open-meteo.com/v1/search"
FORECAST = "https://api.open-meteo.com/v1/forecast"
TIMEOUT = 12

# WMO weather interpretation codes (Open-Meteo), in French.
WMO = {
    0: "ciel dégagé", 1: "plutôt dégagé", 2: "partiellement nuageux", 3: "couvert", 45: "brouillard", 48: "brouillard givrant",
    51: "bruine légère", 53: "bruine", 55: "bruine forte", 56: "bruine verglaçante légère", 57: "bruine verglaçante",
    61: "pluie légère", 63: "pluie", 65: "pluie forte", 66: "pluie verglaçante légère", 67: "pluie verglaçante",
    71: "neige légère", 73: "neige", 75: "neige forte", 77: "grains de neige", 80: "averses légères", 81: "averses",
    82: "averses violentes", 85: "averses de neige légères", 86: "averses de neige fortes",
    95: "orage", 96: "orage avec grêle légère", 99: "orage avec grêle forte",
}

DESCRIPTION = (
    "Donne la météo d'un lieu (conditions actuelles et prévisions de 1 à 7 jours) avec Open-Meteo. "
    "Passe `lieu` (ville, ex. « Québec » ou « Montréal, Canada ») ou `latitude` et `longitude`. "
    "Sans lieu, utilise le lieu par défaut du profil s'il existe."
)

SCHEMA = {
    "name": "meteo",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "lieu": {"type": "string", "maxLength": 100, "description": "Nom de la ville ou du lieu."},
            "latitude": {"type": "number", "minimum": -90, "maximum": 90},
            "longitude": {"type": "number", "minimum": -180, "maximum": 180},
            "jours": {"type": "integer", "minimum": 1, "maximum": 7, "default": 3, "description": "Nombre de jours de prévision."},
        },
        "additionalProperties": False,
    },
}


def _error(message: str) -> str:
    return json.dumps({"error": message}, ensure_ascii=False)


def _default_place() -> str:
    try:
        from hermes_cli.config import load_config
        section = (load_config() or {}).get("meteo")
        return str(section.get("lieu_defaut") or "").strip() if isinstance(section, dict) else ""
    except Exception:
        return ""


def _get(url: str, params: Dict[str, Any]) -> Dict[str, Any]:
    import requests
    response = requests.get(url, params=params, timeout=TIMEOUT)
    if response.status_code != 200:
        raise RuntimeError(f"Open-Meteo a répondu HTTP {response.status_code}.")
    return response.json()


_default_country: Dict[str, str] = {}


def _preferred_country() -> str:
    """Country code of the profile's default place (cached): « Saint-Constant » then means Québec, not France."""
    place = _default_place()
    if not place:
        return ""
    if place not in _default_country:
        try:
            found = _get(GEOCODING, {"name": place.partition(",")[0].strip(), "count": 5, "language": "fr", "format": "json"}).get("results") or []
            region = place.partition(",")[2].strip().casefold()
            pick = next((r for r in found if region and region in " ".join(str(r.get(k) or "") for k in ("country", "admin1", "admin2")).casefold()), found[0] if found else {})
            _default_country[place] = str(pick.get("country_code") or "")
        except Exception:
            _default_country[place] = ""
    return _default_country[place]


def _locate(place: str) -> Optional[Dict[str, Any]]:
    # Open-Meteo matches a bare name: "Québec, Canada" is searched as "Québec" then filtered by the rest.
    name, _, rest = place.partition(",")
    data = _get(GEOCODING, {"name": name.strip(), "count": 10, "language": "fr", "format": "json"})
    results = data.get("results") or []
    wanted = rest.strip().casefold()
    if wanted:
        narrowed = [r for r in results if wanted in " ".join(str(r.get(k) or "") for k in ("country", "admin1", "admin2")).casefold()]
        results = narrowed or results
    else:
        # No region given: a namesake in the person's own country wins (the default place's country).
        country = _preferred_country()
        results = sorted(results, key=lambda r: 0 if country and r.get("country_code") == country else 1)
    return results[0] if results else None


def _label(code: Any) -> str:
    return WMO.get(int(code), "conditions inconnues") if isinstance(code, (int, float)) else "conditions inconnues"


def forecast(latitude: float, longitude: float, days: int) -> Dict[str, Any]:
    data = _get(FORECAST, {
        "latitude": round(latitude, 4), "longitude": round(longitude, 4), "timezone": "auto", "forecast_days": days,
        "current": "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m,wind_gusts_10m",
        "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,wind_speed_10m_max,sunrise,sunset",
    })
    current = data.get("current") or {}
    units = data.get("current_units") or {}
    daily = data.get("daily") or {}
    out_days = []
    for index, day in enumerate(daily.get("time") or []):
        def pick(key: str) -> Any:
            values = daily.get(key) or []
            return values[index] if index < len(values) else None
        out_days.append({
            "date": day, "conditions": _label(pick("weather_code")), "min_c": pick("temperature_2m_min"), "max_c": pick("temperature_2m_max"),
            "pluie_mm": pick("precipitation_sum"), "probabilite_pluie_pct": pick("precipitation_probability_max"),
            "vent_max_kmh": pick("wind_speed_10m_max"), "lever": (pick("sunrise") or "")[-5:], "coucher": (pick("sunset") or "")[-5:],
        })
    return {
        "fuseau": data.get("timezone"),
        "actuel": {
            "heure": current.get("time"), "conditions": _label(current.get("weather_code")), "temperature_c": current.get("temperature_2m"),
            "ressenti_c": current.get("apparent_temperature"), "humidite_pct": current.get("relative_humidity_2m"),
            "precipitation_mm": current.get("precipitation"), "vent_kmh": current.get("wind_speed_10m"), "rafales_kmh": current.get("wind_gusts_10m"),
            "unites": {"vent": units.get("wind_speed_10m", "km/h")},
        },
        "jours": out_days,
    }


def handle(args, **kwargs) -> str:
    try:
        args = args if isinstance(args, dict) else {}
        days = args.get("jours", 3)
        days = days if isinstance(days, int) and not isinstance(days, bool) and 1 <= days <= 7 else 3
        latitude, longitude = args.get("latitude"), args.get("longitude")
        place = str(args.get("lieu") or "").strip()
        label = place
        if isinstance(latitude, (int, float)) and isinstance(longitude, (int, float)) and not isinstance(latitude, bool):
            if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
                return _error("Coordonnées hors limites.")
        else:
            default = _default_place()
            # The default place's own name always means the default place (region included).
            if default and place and place.partition(",")[0].strip().casefold() == default.partition(",")[0].strip().casefold() and "," not in place:
                place = default
            place = place or default
            if not place:
                return _error("Indique un `lieu` (ville) ou des coordonnées ; aucun lieu par défaut n'est configuré.")
            found = _locate(place)
            if not found:
                return _error(f"Lieu introuvable : « {place[:60]} ». Essaie avec le nom de la ville et le pays.")
            latitude, longitude = found["latitude"], found["longitude"]
            label = ", ".join(str(found[k]) for k in ("name", "admin1", "country") if found.get(k))
        result = forecast(float(latitude), float(longitude), days)
        result["lieu"] = label or f"{latitude}, {longitude}"
        result["source"] = "Open-Meteo.com"
        return json.dumps(result, ensure_ascii=False)
    except Exception as error:
        return _error(f"La météo est indisponible pour le moment ({type(error).__name__}).")


def register(ctx) -> None:
    ctx.register_tool(name="meteo", toolset=TOOLSET, schema=SCHEMA, handler=handle, description=DESCRIPTION, emoji="🌤️")
