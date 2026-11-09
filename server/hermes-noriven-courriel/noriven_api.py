"""Minimal client for noriven-web's agent mail routes (docs/noriven-courriel-contrat.md). No sending, by construction.

Every request goes through ``request()``, which only lets a closed list of (method, path) pairs through: the agent can
list its mailboxes, search, read, file and draft. The relay routes (read a draft for review, send it) are not here and
need another token. The token only ever goes to the configured private address, never follows a redirect, and is never
logged, returned or placed in an error message.
"""
from __future__ import annotations

import base64
import hashlib
import ipaddress
import os
import re
import sqlite3
import time
from pathlib import Path
from typing import Any, Dict, Optional
from urllib.parse import quote, urlparse

BASE_PATH = "/api/agent/email"
TIMEOUT = 30
MAX_ATTACHMENTS, MAX_ATTACHMENT_BYTES, MAX_TOTAL_BYTES = 5, 10 * 1024 * 1024, 15 * 1024 * 1024   # what noriven-web sends
MAX_RECIPIENTS = 20

# noriven-web's signed ids: m1.<base64url payload>.<22-character signature>.
ID = re.compile(r"m1\.[A-Za-z0-9_-]{1,8000}\.[A-Za-z0-9_-]{22}")
_ID = r"m1\.[A-Za-z0-9_-]{1,8000}\.[A-Za-z0-9_-]{22}"

# What the agent sees instead: a short reference per message (`n-` + 8 characters) or per page of results (`p-`). A model
# recopying a 200-character signed id mixes up pieces of its neighbours and noriven-web rightly answers « introuvable »;
# eight characters it copies faithfully. Derived from the id itself, so a message always gets the same reference (the
# monitor's lines stay stable), and remembered in the profile for REF_DAYS so any later turn, cron or widget can use it.
REF = re.compile(r"[np]-[a-z2-7]{8}")
REF_DAYS = 30
REFS_PATH: Optional[Path] = None                      # set by the cron script; else <profile>/cache/courriel_refs.sqlite3
_memory_refs: Dict[str, str] = {}                     # when no profile folder can be found (tests)

# The whole surface the agent can reach. Anything else is refused before leaving the server.
_ALLOWED = (
    ("GET", re.compile(rf"^{BASE_PATH}/mailboxes$")),
    ("GET", re.compile(rf"^{BASE_PATH}/messages$")),
    ("GET", re.compile(rf"^{BASE_PATH}/messages/{_ID}$")),
    ("POST", re.compile(rf"^{BASE_PATH}/messages/{_ID}/organize$")),
    ("POST", re.compile(rf"^{BASE_PATH}/drafts$")),
)


class NorivenError(RuntimeError):
    """A failure whose text is safe to show the agent (no secret, no internal detail). `status`: the HTTP code, 0 if none."""

    def __init__(self, message: str, status: int = 0):
        super().__init__(message)
        self.status = status


def _env(name: str) -> str:
    try:
        from hermes_cli.config import get_env_value
        return str(get_env_value(name) or "").strip()
    except Exception:
        return os.environ.get(name, "").strip()


def private_address(url: str, extra_hosts: str = "") -> bool:
    """HTTPS anywhere, or plain HTTP only inside the tailnet (100.64.0.0/10, *.ts.net), on this machine, or to a host:port
    named exactly in `NORIVEN_COURRIEL_HOTES` (a Docker network alias that never leaves the server, for example)."""
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme == "https" and host:
        return True
    if parsed.scheme != "http" or not host:
        return False
    named = {h.strip().lower() for h in extra_hosts.split(",") if h.strip()}
    if parsed.port and f"{host}:{parsed.port}" in named:
        return True
    if host in ("localhost", "127.0.0.1", "::1") or host.endswith(".ts.net"):
        return True
    try:
        return ipaddress.ip_address(host) in ipaddress.ip_network("100.64.0.0/10")
    except ValueError:
        return False


def base_url() -> str:
    url = _env("NORIVEN_COURRIEL_URL").rstrip("/")
    return url if url and private_address(url, _env("NORIVEN_COURRIEL_HOTES")) and not urlparse(url).path.strip("/") else ""


def configured() -> bool:
    return bool(base_url() and _env("NORIVEN_COURRIEL_TOKEN"))


def _http(method: str, url: str, **kwargs):          # the single network seam (tests replace it)
    import requests
    return requests.request(method, url, timeout=TIMEOUT, allow_redirects=False, **kwargs)


def _clean(text: Any, limit: int = 240) -> str:
    return re.sub(r"[\x00-\x1f\x7f]+", " ", str(text or "")).strip()[:limit]


def request(method: str, path: str, *, params: Optional[Dict[str, Any]] = None, body: Optional[Dict[str, Any]] = None,
            idempotency_key: str = "") -> Dict[str, Any]:
    if not any(method == allowed and pattern.fullmatch(path) for allowed, pattern in _ALLOWED):
        raise NorivenError("Opération courriel non permise.")
    base, token = base_url(), _env("NORIVEN_COURRIEL_TOKEN")
    if not base or not token:
        raise NorivenError("Le courriel Noriven n'est pas configuré pour ce profil.")
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    if idempotency_key:
        headers["Idempotency-Key"] = idempotency_key
    try:
        response = _http(method, base + path, params=params, json=body, headers=headers)
    except Exception as error:
        raise NorivenError(f"Le Dashboard Noriven ne répond pas ({type(error).__name__}).") from None
    status = response.status_code
    try:
        payload = response.json() if response.content else {}
    except ValueError:
        payload = {}
    if 300 <= status < 400:
        raise NorivenError("Le Dashboard Noriven a répondu par une redirection, refusée.")
    if status == 401:
        raise NorivenError("Le jeton courriel de ce profil est refusé : dis à Maxime de le vérifier.")
    if status >= 400:
        message = _clean(payload.get("error") if isinstance(payload, dict) else "") or f"Erreur {status}."
        raise NorivenError(message, status)
    if not isinstance(payload, dict):
        raise NorivenError("Réponse inattendue du Dashboard Noriven.")
    return payload


def _refs_path() -> Optional[Path]:
    if REFS_PATH:
        return REFS_PATH
    try:
        from hermes_constants import get_hermes_home
        home = Path(get_hermes_home())
    except Exception:
        home = Path(os.environ["HERMES_HOME"]) if os.environ.get("HERMES_HOME") else None
    return home / "cache" / "courriel_refs.sqlite3" if home else None


def _refs_db() -> Optional[sqlite3.Connection]:
    path = _refs_path()
    if not path:
        return None
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=5)
    db.execute("create table if not exists refs (ref text primary key, value text not null, seen real not null)")
    return db


def short(value: str, kind: str = "n") -> str:
    """The short reference of a signed id (`n`) or of a page cursor (`p`), remembered for later calls."""
    digest = base64.b32encode(hashlib.sha256(value.encode()).digest()).decode().lower()[:8]
    ref = f"{kind}-{digest}"
    db = _refs_db()
    if db is None:
        _memory_refs[ref] = value
        return ref
    with db:
        db.execute("insert into refs (ref, value, seen) values (?, ?, ?) on conflict(ref) do update set value = excluded.value, seen = excluded.seen",
                   (ref, value, time.time()))
        if hashlib.sha256(ref.encode()).digest()[0] < 4:                  # now and then, forget the old ones
            db.execute("delete from refs where seen < ?", (time.time() - REF_DAYS * 86400,))
    db.close()
    return ref


def resolve(value: str, kind: str = "n") -> str:
    """A reference given back by the agent → the signed id. A full signed id is still accepted as is."""
    text = str(value or "").strip().strip("`\"'")
    if kind == "n" and ID.fullmatch(text):
        return text
    if REF.fullmatch(text) and text[0] == kind:
        db = _refs_db()
        if db is None:
            found = _memory_refs.get(text)
        else:
            row = db.execute("select value from refs where ref = ?", (text,)).fetchone()
            db.close()
            found = row[0] if row else None
        if found:
            return found
        raise NorivenError("Référence de courriel inconnue ou expirée : relance courriel_chercher pour la retrouver.", 404)
    raise NorivenError("Référence de courriel invalide : reprends exactement le `id` (n-xxxxxxxx) que courriel_chercher a rendu.")


def shorten(value: Any) -> Any:
    """Every signed message id inside a result, replaced by its reference (draft ids are never passed here)."""
    if isinstance(value, dict):
        return {k: shorten(v) for k, v in value.items()}
    if isinstance(value, list):
        return [shorten(v) for v in value]
    if isinstance(value, str) and ID.fullmatch(value):
        return short(value)
    return value


def message_path(message_id: str, suffix: str = "") -> str:
    return f"{BASE_PATH}/messages/{quote(resolve(message_id), safe='')}{suffix}"
