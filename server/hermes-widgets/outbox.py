"""Sending a Gmail draft, for Maxime only, from the iPhone app.

The agents can save drafts but have no way to send one: their Google plugin has no send path at all. Sending lives here, in
the dashboard, behind its authentication, and is reached by the app's « Envoyer » button only. The app first reads the draft
as Gmail holds it (not as an agent described it), shows it, asks for Face ID, then sends it with the fingerprint of what it
showed: if the draft changed in between (an agent rewrote it, a recipient was added in Gmail), the send is refused. Each
send is written to the profile's `widgets/envois.jsonl`. Nothing here ever deletes a message.
"""
from __future__ import annotations

import hashlib
import json
import re
import threading
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Optional

GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me"
TIMEOUT, SENDS_PER_HOUR, BODY_LIMIT = 30, 20, 20_000
_DRAFT_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")
_sent: deque = deque()
_lock = threading.Lock()


class OutboxError(RuntimeError):
    """A failure whose text can be shown in the app (no token, no mail content). `status` is the HTTP code to answer."""

    def __init__(self, message: str, status: int = 400):
        super().__init__(message)
        self.status = status


def _http(method: str, url: str, **kwargs):          # the network seam (tests replace it)
    import requests
    return requests.request(method, url, timeout=TIMEOUT, **kwargs)


def _call(google, method: str, path: str, *, params: Optional[dict] = None, body: Optional[dict] = None,
          http: Callable = None) -> Dict[str, Any]:
    """Only two calls exist: read one draft, send one draft."""
    allowed = (method == "GET" and re.fullmatch(r"/drafts/[A-Za-z0-9_-]{1,64}", path)) or (method == "POST" and path == "/drafts/send")
    if not allowed:
        raise OutboxError("Opération non autorisée.", 403)
    http = http or _http
    for attempt in (0, 1):
        response = http(method, GMAIL + path, params=params, json=body,
                        headers={"Authorization": f"Bearer {google._access_token(force=attempt == 1)}"})
        if response.status_code != 401:
            break
    if response.status_code == 404:
        raise OutboxError("Ce brouillon n'existe plus dans Gmail (déjà envoyé ou supprimé).", 404)
    if response.status_code >= 400:
        raise OutboxError(f"Gmail a refusé (HTTP {response.status_code}).", 502)
    return response.json() if response.content else {}


def _header(headers: list, name: str) -> str:
    return next((str(h.get("value") or "") for h in headers or [] if str(h.get("name", "")).casefold() == name.casefold()), "")


def _fingerprint(view: Dict[str, Any]) -> str:
    keys = ("message_id", "to", "cc", "bcc", "subject", "body")
    material = json.dumps([view.get(k) for k in keys] + [[f["name"], f["size"]] for f in view["attachments"]], ensure_ascii=False)
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def read(google, draft_id: str, http: Callable = None) -> Dict[str, Any]:
    """The draft as Gmail holds it: recipients (Bcc included), subject, text, attachments, and its fingerprint."""
    if not _DRAFT_ID.fullmatch(draft_id or ""):
        raise OutboxError("Identifiant de brouillon invalide.")
    draft = _call(google, "GET", f"/drafts/{draft_id}", params={"format": "full"}, http=http)
    message = draft.get("message") or {}
    payload = message.get("payload") or {}
    plain, html, files = [], [], []
    google._walk(payload, plain, html, files)
    text = "\n".join(plain).strip() or google._strip_html("\n".join(html))
    headers = payload.get("headers") or []
    view = {"id": draft_id, "message_id": str(message.get("id") or ""), "to": _header(headers, "To"), "cc": _header(headers, "Cc"),
            "bcc": _header(headers, "Bcc"), "subject": _header(headers, "Subject"), "body": text[:BODY_LIMIT],
            "truncated": len(text) > BODY_LIMIT,
            "attachments": [{"name": str(f.get("nom") or "")[:120], "type": str(f.get("type") or "")[:80], "size": int(f.get("taille") or 0)}
                            for f in files[:20]]}
    view["fingerprint"] = _fingerprint(view)
    return view


def send(google, draft_id: str, fingerprint: str, home: Path, http: Callable = None, now: Optional[datetime] = None) -> Dict[str, Any]:
    """Sends the draft if it is still exactly what the app showed. Returns the sent message's id."""
    current = read(google, draft_id, http=http)
    if not current["to"].strip() and not current["cc"].strip() and not current["bcc"].strip():
        raise OutboxError("Ce brouillon n'a aucun destinataire.")
    if not fingerprint or fingerprint != current["fingerprint"]:
        raise OutboxError("Le brouillon a changé depuis que tu l'as relu : relis-le avant d'envoyer.", 409)
    with _lock:
        moment = time.time()
        while _sent and moment - _sent[0] > 3600:
            _sent.popleft()
        if len(_sent) >= SENDS_PER_HOUR:
            raise OutboxError(f"Limite atteinte : {SENDS_PER_HOUR} envois par heure.", 429)
        _sent.append(moment)
    sent = _call(google, "POST", "/drafts/send", body={"id": draft_id}, http=http)
    record = {"at": (now or datetime.now(timezone.utc)).isoformat(timespec="seconds"), "draft": draft_id, "message": sent.get("id"),
              "to": current["to"], "cc": current["cc"], "bcc": current["bcc"], "subject": current["subject"],
              "attachments": [f["name"] for f in current["attachments"]]}
    try:
        log = Path(home) / "widgets" / "envois.jsonl"
        log.parent.mkdir(parents=True, exist_ok=True)
        with open(log, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        log.chmod(0o600)
    except OSError:
        pass                                    # the mail is sent; a missing journal line must not say otherwise
    return {"ok": True, "message_id": sent.get("id"), "thread": sent.get("threadId")}
