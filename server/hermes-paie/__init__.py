"""`paie_synchroniser` et `paie_lire` : les talons de paie de Maxime, par le service « paie » du Mac mini (Tailscale).

Le Mac se connecte à MaPaie.net avec l'identifiant de son trousseau, range les talons dans iCloud et rend un PDF par sa
date. Ce plugin ne voit jamais l'identifiant MaPaie.net ; il ne connaît que l'adresse du service et son jeton
(`HERMES_PAIE_TOKEN`, dans le .env du profil, placé par Maxime). L'agent ne donne jamais d'adresse ni de chemin :
une date, c'est tout.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
from pathlib import Path
from typing import Any, Dict

TOOLSET = "paie"
DEFAULT_URL = "http://100.110.134.51:8790"
SYNC_TIMEOUT = 170
READ_TIMEOUT = 90

SYNC_DESCRIPTION = (
    "Va chercher les talons de paie de Maxime sur MaPaie.net (par son Mac mini) et range dans son iCloud ceux qui manquent. "
    "Renvoie les talons ajoutés (date de paie, semaine payée, anciennes semaines ajustées), les jeudis de paie sans talon "
    "publié et sans talon classé. La paie tombe chaque jeudi et paie la semaine (dimanche-samedi) finie 12 jours plus tôt. "
    "Lis ensuite un talon avec paie_lire."
)
READ_DESCRIPTION = (
    "Donne le talon de paie complet d'une date de paie (un jeudi, AAAA-MM-JJ) : le PDF est copié dans le dossier `paie` du "
    "profil et son texte intégral est renvoyé (heures, taux, gains, déductions, cumuls). Le talon contient des données "
    "personnelles : n'en recopie que ce qui sert la réponse."
)
SYNC_SCHEMA = {"name": "paie_synchroniser", "description": SYNC_DESCRIPTION,
               "parameters": {"type": "object", "properties": {}, "additionalProperties": False}}
READ_SCHEMA = {
    "name": "paie_lire", "description": READ_DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {"date": {"type": "string", "pattern": r"^\d{4}-\d{2}-\d{2}$", "description": "Date de paie, ex. 2026-11-19."}},
        "required": ["date"], "additionalProperties": False,
    },
}


def _error(message: str) -> str:
    return json.dumps({"ok": False, "erreur": message}, ensure_ascii=False)


def _service() -> tuple:
    url = (os.environ.get("HERMES_PAIE_URL") or DEFAULT_URL).rstrip("/")
    token = (os.environ.get("HERMES_PAIE_TOKEN") or "").strip()
    return url, token


def _call(method: str, path: str, timeout: int):
    import requests
    url, token = _service()
    if not token:
        raise RuntimeError("Le jeton du service paie (HERMES_PAIE_TOKEN) n'est pas configuré sur le serveur.")
    try:
        return requests.request(method, url + path, headers={"Authorization": f"Bearer {token}"}, timeout=timeout)
    except requests.exceptions.ConnectionError:
        raise RuntimeError("Le Mac mini ne répond pas : il est peut-être éteint ou hors de Tailscale.") from None
    except requests.exceptions.Timeout:
        raise RuntimeError("Le Mac mini n'a pas répondu à temps.") from None


def _json(response) -> Dict[str, Any]:
    try:
        body = response.json()
    except ValueError:
        body = {}
    if response.status_code != 200 or not body.get("ok"):
        raise RuntimeError(str(body.get("erreur") or f"Le Mac a répondu HTTP {response.status_code}."))
    return body


def _folder() -> Path:
    from hermes_constants import get_hermes_home
    folder = Path(get_hermes_home()) / "paie"
    folder.mkdir(parents=True, exist_ok=True)
    return folder


def _text(path: Path) -> str:
    """Le texte du PDF par l'extracteur de Hermes (celui de read_file)."""
    try:
        from tools.read_extract import extract_document_text
        return extract_document_text(str(path))
    except Exception:
        return ""


def synchronize(args, **kwargs) -> str:
    try:
        return json.dumps(_json(_call("POST", "/synchroniser", SYNC_TIMEOUT)), ensure_ascii=False)
    except Exception as error:
        return _error(str(error) if isinstance(error, RuntimeError) else f"La synchronisation a échoué ({type(error).__name__}).")


def read(args, **kwargs) -> str:
    try:
        raw = str((args or {}).get("date") or "").strip()
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", raw):
            return _error("Donne la date de paie au format AAAA-MM-JJ.")
        day = dt.date.fromisoformat(raw)
        response = _call("GET", f"/talon/{day.isoformat()}", READ_TIMEOUT)
        if response.status_code != 200 or not response.content.startswith(b"%PDF-"):
            _json(response)  # raises with the Mac's message
            return _error("Le Mac n'a pas renvoyé un PDF.")
        path = _folder() / f"Paye ({day.isoformat()}).pdf"
        temporary = path.with_name(f".{path.name}.partiel")
        temporary.write_bytes(response.content)
        os.replace(temporary, path)
        text = _text(path)
        result = {"ok": True, "date": day.isoformat(), "fichier": str(path), "texte": text[:40_000]}
        if not text:
            result["note"] = "Le texte n'a pas pu être extrait ici : lis le fichier avec read_file."
        return json.dumps(result, ensure_ascii=False)
    except Exception as error:
        return _error(str(error) if isinstance(error, RuntimeError) else f"Le talon est indisponible ({type(error).__name__}).")


def register(ctx) -> None:
    ctx.register_tool(name="paie_synchroniser", toolset=TOOLSET, schema=SYNC_SCHEMA, handler=synchronize, description=SYNC_DESCRIPTION, emoji="💵")
    ctx.register_tool(name="paie_lire", toolset=TOOLSET, schema=READ_SCHEMA, handler=read, description=READ_DESCRIPTION, emoji="🧾")
