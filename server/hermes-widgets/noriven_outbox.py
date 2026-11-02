"""Sending a Noriven (Polaris) draft, for Maxime only, from the iPhone app (docs/noriven-courriel-contrat.md).

Hermès can save drafts in Noriven's mailboxes but has no way to send one: its plugin has no send path and its token has no
send permission. This relay, in the dashboard behind its authentication, reads a draft the agent made (as the mailbox
holds it) and passes on Maxime's send, which carries an approval signed on the iPhone by a Face ID-protected key. The relay
token alone cannot send: noriven-web checks that signature, the draft's fingerprint, a one-time nonce and its own limits.
Each send is written to the profile's `widgets/envois.jsonl`. Nothing here deletes a message.
"""
from __future__ import annotations

import ipaddress
import json
import re
import threading
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Optional
from urllib.parse import quote, urlparse

BASE_PATH = "/api/agent/email/drafts"
TIMEOUT, SENDS_PER_HOUR = 45, 20
KEYS = ("NORIVEN_COURRIEL_URL", "NORIVEN_COURRIEL_RELAIS_TOKEN")
DRAFT_ID = re.compile(r"m1\.[A-Za-z0-9_-]{1,8000}\.[A-Za-z0-9_-]{22}")
_sent: deque = deque()
_lock = threading.Lock()


class OutboxError(RuntimeError):
    """A failure whose text can be shown in the app (no token, no mail content). `status` is the HTTP code to answer."""

    def __init__(self, message: str, status: int = 400):
        super().__init__(message)
        self.status = status


def is_noriven(draft_id: str) -> bool:
    return str(draft_id or "").startswith("m1.")


def _private(url: str) -> bool:
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme == "https" and host:
        return True
    if parsed.scheme != "http" or not host:
        return False
    if host in ("localhost", "127.0.0.1", "::1") or host.endswith(".ts.net"):
        return True
    try:
        return ipaddress.ip_address(host) in ipaddress.ip_network("100.64.0.0/10")
    except ValueError:
        return False


def configured(env: Dict[str, str]) -> bool:
    url = env.get("NORIVEN_COURRIEL_URL", "").rstrip("/")
    return bool(url and _private(url) and not urlparse(url).path.strip("/") and env.get("NORIVEN_COURRIEL_RELAIS_TOKEN"))


def _http(method: str, url: str, **kwargs):          # the network seam (tests replace it)
    import requests
    return requests.request(method, url, timeout=TIMEOUT, allow_redirects=False, **kwargs)


def _clean(text: Any, limit: int = 240) -> str:
    return re.sub(r"[\x00-\x1f\x7f]+", " ", str(text or "")).strip()[:limit]


def _call(env: Dict[str, str], method: str, draft_id: str, *, body: Optional[dict] = None, http: Callable = None) -> Dict[str, Any]:
    """Only two calls exist: read one draft, send one draft."""
    if not configured(env):
        raise OutboxError("L'envoi Noriven n'est pas configuré pour ce profil.", 404)
    if not DRAFT_ID.fullmatch(draft_id or ""):
        raise OutboxError("Identifiant de brouillon invalide.")
    path = f"{BASE_PATH}/{quote(draft_id, safe='')}" + ("/send" if method == "POST" else "")
    try:
        response = (http or _http)(method, env["NORIVEN_COURRIEL_URL"].rstrip("/") + path, json=body,
                                   headers={"Authorization": f"Bearer {env['NORIVEN_COURRIEL_RELAIS_TOKEN']}", "Accept": "application/json"})
    except Exception as error:
        raise OutboxError(f"Le Dashboard Noriven ne répond pas ({type(error).__name__}).", 502) from None
    try:
        payload = response.json() if response.content else {}
    except ValueError:
        payload = {}
    status = response.status_code
    message = _clean(payload.get("error")) if isinstance(payload, dict) else ""
    if 300 <= status < 400:
        raise OutboxError("Le Dashboard Noriven a répondu par une redirection, refusée.", 502)
    if status == 401:
        raise OutboxError("Le jeton d'envoi de ce profil est refusé.", 502)
    if status in (403, 404):
        raise OutboxError(message or "Ce brouillon n'existe plus (déjà envoyé, modifié ou supprimé).", 404)
    if status in (409, 429, 400, 413):
        raise OutboxError(message or f"Refusé (HTTP {status}).", status)
    if status >= 400:
        raise OutboxError(message or f"Le Dashboard Noriven a refusé (HTTP {status}).", 502)
    if not isinstance(payload, dict):
        raise OutboxError("Réponse inattendue du Dashboard Noriven.", 502)
    return payload


def read(env: Dict[str, str], draft_id: str, http: Callable = None) -> Dict[str, Any]:
    """The draft as the mailbox holds it, in the same shape as a Gmail draft, with noriven-web's opaque fingerprint."""
    draft = _call(env, "GET", draft_id, http=http)
    fingerprint = str(draft.get("fingerprint") or "")
    if not fingerprint:
        raise OutboxError("Le brouillon est arrivé sans empreinte.", 502)
    files = [{"name": _clean(f.get("name"), 200), "type": _clean(f.get("type"), 100), "size": int(f.get("size") or 0)}
             for f in draft.get("attachments") or [] if isinstance(f, dict)]
    return {"id": draft_id, "message_id": "", "from": _clean(draft.get("from"), 300), "mailbox": _clean(draft.get("mailbox"), 254),
            "to": _clean(draft.get("to"), 2000), "cc": _clean(draft.get("cc"), 2000), "bcc": _clean(draft.get("bcc"), 2000),
            "subject": _clean(draft.get("subject"), 300), "body": str(draft.get("body") or ""), "truncated": bool(draft.get("truncated")),
            "attachments": files, "fingerprint": fingerprint, "approval": "device"}


def _approval(value: Any) -> Dict[str, Any]:
    """The signed approval as the app made it; checked for shape only (noriven-web verifies the signature)."""
    if not isinstance(value, dict):
        raise OutboxError("L'approbation signée de l'iPhone manque : mets l'app à jour.", 400)
    key_id, nonce, signature = str(value.get("key_id") or ""), str(value.get("nonce") or ""), str(value.get("signature") or "")
    signed_at = value.get("signed_at")
    if not (re.fullmatch(r"[0-9a-f]{64}", key_id) and isinstance(signed_at, int) and not isinstance(signed_at, bool)
            and re.fullmatch(r"[A-Za-z0-9+/]{22}={0,2}", nonce) and re.fullmatch(r"[A-Za-z0-9+/]{40,200}={0,2}", signature)):
        raise OutboxError("Approbation signée invalide.", 400)
    return {"key_id": key_id, "signed_at": signed_at, "nonce": nonce, "signature": signature}


def send(env: Dict[str, str], draft_id: str, fingerprint: str, approval: Any, home: Path, http: Callable = None,
         now: Optional[datetime] = None) -> Dict[str, Any]:
    signed = _approval(approval)
    if not re.fullmatch(r"[A-Za-z0-9_.:=-]{16,200}", fingerprint or ""):
        raise OutboxError("Empreinte invalide : relis le brouillon.", 409)
    with _lock:
        moment = time.time()
        while _sent and moment - _sent[0] > 3600:
            _sent.popleft()
        if len(_sent) >= SENDS_PER_HOUR:
            raise OutboxError(f"Limite atteinte : {SENDS_PER_HOUR} envois par heure.", 429)
        _sent.append(moment)
    result = _call(env, "POST", draft_id, body={"fingerprint": fingerprint, "approval": signed}, http=http)
    status = str(result.get("status") or "")
    record = {"at": (now or datetime.now(timezone.utc)).isoformat(timespec="seconds"), "draft": draft_id[:120],
              "message": result.get("message_id"), "status": status, "via": "noriven"}
    try:
        log = Path(home) / "widgets" / "envois.jsonl"
        log.parent.mkdir(parents=True, exist_ok=True)
        with open(log, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        log.chmod(0o600)
    except OSError:
        pass
    if status == "accepted":
        return {"ok": True, "message_id": result.get("message_id"), "thread": None}
    if status == "uncertain":
        raise OutboxError("Envoi incertain : regarde dans Envoyés avant de réessayer. Le brouillon ne repartira pas tout seul.", 504)
    raise OutboxError("Le serveur de courriel a refusé l'envoi.", 502)
