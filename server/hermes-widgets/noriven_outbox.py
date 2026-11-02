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
KEYS = ("NORIVEN_COURRIEL_URL", "NORIVEN_COURRIEL_RELAIS_TOKEN", "NORIVEN_COURRIEL_HOTES")
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


def _private(url: str, extra_hosts: str = "") -> bool:
    """Same rule as the agent plugin: HTTPS, or HTTP to the tailnet, this machine, or a host:port named exactly."""
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


def configured(env: Dict[str, str]) -> bool:
    url = env.get("NORIVEN_COURRIEL_URL", "").rstrip("/")
    return bool(url and _private(url, env.get("NORIVEN_COURRIEL_HOTES", "")) and not urlparse(url).path.strip("/") and env.get("NORIVEN_COURRIEL_RELAIS_TOKEN"))


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
        raise OutboxError(message or "Refusé : jeton du relais ou approbation de l'iPhone non reconnus.", 403)
    if status in (403, 404):
        raise OutboxError(message or "Ce brouillon n'existe plus (déjà envoyé, modifié ou supprimé).", 404)
    if status in (409, 429, 400, 413, 503):
        raise OutboxError(message or f"Refusé (HTTP {status}).", status)
    if status >= 400:
        raise OutboxError(message or f"Le Dashboard Noriven a refusé (HTTP {status}).", 502)
    if not isinstance(payload, dict):
        raise OutboxError("Réponse inattendue du Dashboard Noriven.", 502)
    return payload


def read(env: Dict[str, str], draft_id: str, http: Callable = None) -> Dict[str, Any]:
    """The draft as the mailbox holds it, passed on VERBATIM: the iPhone recomputes the fingerprint from these exact fields
    before Face ID, so nothing is cleaned, joined or cut here. Only the types are checked."""
    draft = _call(env, "GET", draft_id, http=http)
    strings = lambda v: isinstance(v, list) and len(v) <= 20 and all(isinstance(x, str) for x in v)
    files = draft.get("attachments")
    well_formed = (
        draft.get("id") == draft_id and all(isinstance(draft.get(k), str) for k in ("mailbox", "from", "subject", "body"))
        and all(strings(draft.get(k)) for k in ("to", "cc", "bcc"))
        and (draft.get("in_reply_to") is None or isinstance(draft.get("in_reply_to"), str))
        and isinstance(files, list) and len(files) <= 10
        and all(isinstance(f, dict) and isinstance(f.get("name"), str) and isinstance(f.get("type"), str)
                and isinstance(f.get("size"), int) and not isinstance(f.get("size"), bool) and f["size"] >= 0
                and isinstance(f.get("sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", f["sha256"]) for f in files)
        and isinstance(draft.get("fingerprint"), str) and re.fullmatch(r"[0-9a-f]{64}", draft["fingerprint"]))
    if not well_formed:
        raise OutboxError("Le brouillon reçu est incomplet : envoi impossible.", 502)
    keys = ("id", "mailbox", "from", "to", "cc", "bcc", "subject", "body", "in_reply_to", "fingerprint")
    return {**{k: draft.get(k) for k in keys}, "attachments": [{k: f[k] for k in ("name", "type", "size", "sha256")} for f in files],
            "truncated": False, "approval": "device"}


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
    if not re.fullmatch(r"[0-9a-f]{64}", fingerprint or ""):
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
    raise OutboxError(_clean(result.get("error")) or "Le serveur de courriel a refusé l'envoi.", 502)
