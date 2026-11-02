"""Minimal client for noriven-web's agent mail routes (docs/noriven-courriel-contrat.md). No sending, by construction.

Every request goes through ``request()``, which only lets a closed list of (method, path) pairs through: the agent can
list its mailboxes, search, read, file and draft. The relay routes (read a draft for review, send it) are not here and
need another token. The token only ever goes to the configured private address, never follows a redirect, and is never
logged, returned or placed in an error message.
"""
from __future__ import annotations

import ipaddress
import os
import re
from typing import Any, Dict, Optional
from urllib.parse import quote, urlparse

BASE_PATH = "/api/agent/email"
TIMEOUT = 30
MAX_ATTACHMENTS, MAX_ATTACHMENT_BYTES, MAX_TOTAL_BYTES = 5, 10 * 1024 * 1024, 15 * 1024 * 1024   # what noriven-web sends
MAX_RECIPIENTS = 20

# noriven-web's signed ids: m1.<base64url payload>.<22-character signature>.
ID = re.compile(r"m1\.[A-Za-z0-9_-]{1,8000}\.[A-Za-z0-9_-]{22}")
_ID = r"m1\.[A-Za-z0-9_-]{1,8000}\.[A-Za-z0-9_-]{22}"

# The whole surface the agent can reach. Anything else is refused before leaving the server.
_ALLOWED = (
    ("GET", re.compile(rf"^{BASE_PATH}/mailboxes$")),
    ("GET", re.compile(rf"^{BASE_PATH}/messages$")),
    ("GET", re.compile(rf"^{BASE_PATH}/messages/{_ID}$")),
    ("POST", re.compile(rf"^{BASE_PATH}/messages/{_ID}/organize$")),
    ("POST", re.compile(rf"^{BASE_PATH}/drafts$")),
)


class NorivenError(RuntimeError):
    """A failure whose text is safe to show the agent (no secret, no internal detail)."""


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
        raise NorivenError(message)
    if not isinstance(payload, dict):
        raise NorivenError("Réponse inattendue du Dashboard Noriven.")
    return payload


def message_path(message_id: str, suffix: str = "") -> str:
    if not ID.fullmatch(message_id or ""):
        raise NorivenError("Identifiant de courriel invalide : reprends celui que courriel_chercher a rendu.")
    return f"{BASE_PATH}/messages/{quote(message_id, safe='')}{suffix}"
