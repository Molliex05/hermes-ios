"""Minimal Google REST client for Hermès: Gmail read + drafts, Calendar list + create. No sending, by construction.

Every request goes through ``request()``, which only lets a closed list of (method, path) pairs through.
Mail can be searched, read and drafted; no code path sends a message,
and no Calendar call can invite anyone (events are created without attendees, ``sendUpdates=none``).
Tokens are never logged, returned or placed in an error message.
"""
from __future__ import annotations

import base64
import os
import re
import threading
import time
from email.message import EmailMessage
from email.utils import parseaddr
from typing import Any, Dict, Optional
from urllib.parse import quote, urlparse

TOKEN_URL = "https://oauth2.googleapis.com/token"
GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me"
CALENDAR = "https://www.googleapis.com/calendar/v3"
HOSTS = {"oauth2.googleapis.com", "gmail.googleapis.com", "www.googleapis.com"}
SCOPES = (
    "https://www.googleapis.com/auth/gmail.modify",       # read, drafts and labels; the plugin never sends or deletes
    "https://www.googleapis.com/auth/calendar.events",                 # events on every calendar the account can reach
    "https://www.googleapis.com/auth/calendar.calendarlist.readonly",  # which calendars exist (names only)
)
TIMEOUT = 20

# The whole surface the agent can reach. Anything else is refused before leaving the server.
_ALLOWED = (
    ("GET", re.compile(r"^/gmail/v1/users/me/messages$")),
    ("GET", re.compile(r"^/gmail/v1/users/me/messages/[A-Za-z0-9_-]+$")),
    ("POST", re.compile(r"^/gmail/v1/users/me/drafts$")),
    ("GET", re.compile(r"^/gmail/v1/users/me/labels$")),
    ("POST", re.compile(r"^/gmail/v1/users/me/labels$")),
    ("POST", re.compile(r"^/gmail/v1/users/me/messages/batchModify$")),
    ("GET", re.compile(r"^/calendar/v3/users/me/calendarList$")),
    ("GET", re.compile(r"^/calendar/v3/calendars/[A-Za-z0-9._%-]{1,200}/events$")),   # read any calendar
    ("POST", re.compile(r"^/calendar/v3/calendars/primary/events$")),                 # write: the main calendar only
    ("GET", re.compile(r"^/calendar/v3/calendars/primary/events/[A-Za-z0-9_-]{1,100}$")),
    ("PATCH", re.compile(r"^/calendar/v3/calendars/primary/events/[A-Za-z0-9_-]{1,100}$")),
    ("DELETE", re.compile(r"^/calendar/v3/calendars/primary/events/[A-Za-z0-9_-]{1,100}$")),
)


class GoogleError(RuntimeError):
    """A failure whose text is safe to show the agent (no secret, no mail content)."""


def _env(name: str) -> str:
    try:
        from hermes_cli.config import get_env_value
        return str(get_env_value(name) or "").strip()
    except Exception:
        return os.environ.get(name, "").strip()


def configured() -> bool:
    return all(_env(n) for n in ("GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "GOOGLE_REFRESH_TOKEN"))


_lock = threading.Lock()
_token: Dict[str, Any] = {"value": "", "expires": 0.0}
_timezone: Dict[str, str] = {}


def _http(method: str, url: str, **kwargs):          # the single network seam (tests replace it)
    import requests
    return requests.request(method, url, timeout=TIMEOUT, **kwargs)


def _access_token(force: bool = False) -> str:
    with _lock:
        if not force and _token["value"] and time.time() < _token["expires"] - 60:
            return _token["value"]
        if not configured():
            raise GoogleError("Google n'est pas configuré pour ce profil (identifiants manquants).")
        response = _http("POST", TOKEN_URL, data={
            "client_id": _env("GOOGLE_CLIENT_ID"), "client_secret": _env("GOOGLE_CLIENT_SECRET"),
            "refresh_token": _env("GOOGLE_REFRESH_TOKEN"), "grant_type": "refresh_token"})
        if response.status_code != 200:
            raise GoogleError("Google a refusé le renouvellement de l'accès (HTTP %d). L'autorisation doit peut-être être refaite." % response.status_code)
        data = response.json()
        _token["value"] = str(data.get("access_token") or "")
        _token["expires"] = time.time() + float(data.get("expires_in") or 3000)
        if not _token["value"]:
            raise GoogleError("Google n'a renvoyé aucun accès.")
        return _token["value"]


def request(method: str, url: str, *, params: Optional[dict] = None, json: Optional[dict] = None) -> Dict[str, Any]:
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname not in HOSTS:
        raise GoogleError("Adresse refusée.")
    if not any(m == method and rx.match(parsed.path) for m, rx in _ALLOWED):
        raise GoogleError("Opération non autorisée.")
    for attempt in (0, 1):
        response = _http(method, url, params=params, json=json, headers={"Authorization": f"Bearer {_access_token(force=attempt == 1)}"})
        if response.status_code == 401 and attempt == 0:
            continue
        break
    if response.status_code >= 400:
        detail = ""
        try:
            detail = str((response.json().get("error") or {}).get("message") or "")[:200]
        except Exception:
            pass
        raise GoogleError(f"Google a refusé la requête (HTTP {response.status_code}) {detail}".strip())
    return response.json() if response.content else {}


# ---- Gmail ---------------------------------------------------------------------------------------------

def _header(headers: list, name: str) -> str:
    for h in headers or []:
        if str(h.get("name", "")).casefold() == name.casefold():
            return str(h.get("value") or "")
    return ""


def gmail_search(query: str, limit: int) -> list:
    listing = request("GET", f"{GMAIL}/messages", params={"q": query, "maxResults": max(1, min(limit, 20))})
    out = []
    for item in listing.get("messages") or []:
        message = request("GET", f"{GMAIL}/messages/{item['id']}", params={
            "format": "metadata", "metadataHeaders": ["From", "To", "Subject", "Date"]})
        headers = (message.get("payload") or {}).get("headers") or []
        label_ids = message.get("labelIds") or []
        out.append({"id": message.get("id"), "conversation": message.get("threadId"), "de": _header(headers, "From"),
                    "a": _header(headers, "To"), "objet": _header(headers, "Subject"), "date": _header(headers, "Date"),
                    "extrait": str(message.get("snippet") or "")[:200], "non_lu": "UNREAD" in label_ids,
                    "dans_boite_de_reception": "INBOX" in label_ids,
                    "categorie": next((l[9:].lower() for l in label_ids if l.startswith("CATEGORY_")), None),
                    "dossiers": _label_names(label_ids)})
    return out


def _decode(data: str) -> str:
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4)).decode("utf-8", errors="replace")


def _strip_html(html: str) -> str:
    html = re.sub(r"(?is)<(script|style).*?</\1>", " ", html)
    html = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</tr>|</li>", "\n", html)
    text = re.sub(r"<[^>]+>", " ", html)
    for a, b in (("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"'), ("&#39;", "'")):
        text = text.replace(a, b)
    return re.sub(r"\n\s*\n+", "\n\n", re.sub(r"[ \t\r\f\v]+", " ", text)).strip()


def _walk(part: dict, plain: list, html: list, files: list) -> None:
    mime, body = str(part.get("mimeType") or ""), part.get("body") or {}
    if part.get("filename"):
        files.append({"nom": part["filename"], "type": mime, "taille": body.get("size")})
    elif mime == "text/plain" and body.get("data"):
        plain.append(_decode(body["data"]))
    elif mime == "text/html" and body.get("data"):
        html.append(_decode(body["data"]))
    for child in part.get("parts") or []:
        _walk(child, plain, html, files)


def gmail_read(message_id: str, max_chars: int = 8000) -> Dict[str, Any]:
    if not re.fullmatch(r"[A-Za-z0-9_-]{6,64}", message_id or ""):
        raise GoogleError("Identifiant de message invalide.")
    message = request("GET", f"{GMAIL}/messages/{message_id}", params={"format": "full"})
    payload = message.get("payload") or {}
    plain, html, files = [], [], []
    _walk(payload, plain, html, files)
    text = "\n".join(plain).strip() or _strip_html("\n".join(html))
    headers = payload.get("headers") or []
    return {"id": message.get("id"), "conversation": message.get("threadId"), "de": _header(headers, "From"),
            "a": _header(headers, "To"), "cc": _header(headers, "Cc"), "objet": _header(headers, "Subject"),
            "date": _header(headers, "Date"), "message_id": _header(headers, "Message-ID"),
            "texte": text[:max_chars], "tronque": len(text) > max_chars, "pieces_jointes": files[:20]}


_EMAIL = re.compile(r"^[^@\s<>,;\"']+@[^@\s<>,;\"']+\.[^@\s<>,;\"']+$")


def _addresses(value: str, label: str) -> list:
    found = []
    for raw in re.split(r"[;,]", value or ""):
        if not raw.strip():
            continue
        address = parseaddr(raw)[1]
        if not _EMAIL.match(address) or "\n" in raw or "\r" in raw:
            raise GoogleError(f"Adresse invalide dans `{label}`.")
        found.append(address)
    return found


def gmail_draft(to: str, subject: str, body: str, cc: str = "", reply_to_message: str = "") -> Dict[str, Any]:
    recipients, copies = _addresses(to, "a"), _addresses(cc, "cc")
    if not recipients:
        raise GoogleError("Au moins un destinataire est requis.")
    if re.search(r"[\r\n]", subject or ""):
        raise GoogleError("L'objet ne peut pas contenir de saut de ligne.")
    if not (body or "").strip():
        raise GoogleError("Le corps du message est vide.")
    mail = EmailMessage()
    mail["To"] = ", ".join(recipients)
    if copies:
        mail["Cc"] = ", ".join(copies)
    mail["Subject"] = subject
    message: Dict[str, Any] = {}
    if reply_to_message:
        original = request("GET", f"{GMAIL}/messages/{reply_to_message}", params={
            "format": "metadata", "metadataHeaders": ["Message-ID", "References"]}) if re.fullmatch(r"[A-Za-z0-9_-]{6,64}", reply_to_message) else None
        if original is None:
            raise GoogleError("Identifiant de message invalide pour `repondre_a`.")
        headers = (original.get("payload") or {}).get("headers") or []
        mid, refs = _header(headers, "Message-ID"), _header(headers, "References")
        if mid and not re.search(r"[\r\n]", mid + refs):
            mail["In-Reply-To"] = mid
            mail["References"] = (refs + " " + mid).strip()
        message["threadId"] = original.get("threadId")
    mail.set_content(body)
    message["raw"] = base64.urlsafe_b64encode(mail.as_bytes()).decode("ascii")
    draft = request("POST", f"{GMAIL}/drafts", json={"message": message})
    return {"id_brouillon": draft.get("id"), "conversation": (draft.get("message") or {}).get("threadId")}


# ---- Triage: folders (Gmail labels), archive, mark read (never trash, delete or send) ----------------------

# In Gmail a folder is a label and a sub-folder is `Parent/Child`. Jarvis may create any folder tree and file mail in it;
# it can never rename or delete a label, nor touch TRASH, SPAM, SENT or DRAFT.
_RESERVED = {"inbox", "sent", "draft", "drafts", "spam", "trash", "unread", "starred", "important", "chat", "snoozed", "scheduled", "all mail"}
_SEGMENT = re.compile(r"^[A-Za-z0-9À-ÿ][A-Za-z0-9À-ÿ _.&'+-]{0,39}$")
MAX_DEPTH = 4
MAX_TRIAGE_IDS = 100
MAX_QUERY_MATCHES = 200
_labels: Dict[str, Any] = {"at": 0.0, "by_id": {}, "by_name": {}}


def _load_labels(force: bool = False) -> None:
    if not force and _labels["by_id"] and time.time() - _labels["at"] < 600:
        return
    items = [l for l in request("GET", f"{GMAIL}/labels").get("labels") or [] if l.get("type") == "user"]
    _labels.update(at=time.time(), by_id={l["id"]: l["name"] for l in items}, by_name={l["name"]: l["id"] for l in items})


def _label_names(label_ids: list) -> list:
    """Names of the user folders among `label_ids` (system labels need no lookup)."""
    custom = [i for i in label_ids if i.startswith("Label_")]
    if not custom:
        return []
    try:
        _load_labels()
    except GoogleError:
        return []
    return [_labels["by_id"][i] for i in custom if i in _labels["by_id"]]


def list_folders() -> list:
    _load_labels(force=True)
    return sorted(_labels["by_name"])


def _valid_folder(name: str) -> str:
    parts = [part.strip() for part in str(name).strip().strip("/").split("/")]
    if not parts or len(parts) > MAX_DEPTH or any(not _SEGMENT.match(part) for part in parts):
        raise GoogleError("Nom de dossier refusé : lettres, chiffres, espaces ; sous-dossiers séparés par « / » (4 niveaux au plus).")
    if parts[0].lower() in _RESERVED or parts[0].upper().startswith("CATEGORY_") or parts[0].startswith("["):
        raise GoogleError(f"Nom de dossier réservé par Gmail : « {parts[0]} ».")
    return "/".join(parts)


def _folder_id(name: str) -> str:
    """The id of a folder, created on first use (parents first, so the tree shows nested in Gmail)."""
    name = _valid_folder(name)
    _load_labels()
    parts = name.split("/")
    for depth in range(1, len(parts) + 1):
        current = "/".join(parts[:depth])
        if current not in _labels["by_name"]:
            created = request("POST", f"{GMAIL}/labels", json={"name": current, "labelListVisibility": "labelShow", "messageListVisibility": "show"})
            _labels["by_name"][current] = str(created["id"]); _labels["by_id"][str(created["id"])] = current
    return _labels["by_name"][name]


def _ids_for_query(query: str) -> list:
    ids: list = []
    token = None
    while len(ids) < MAX_QUERY_MATCHES:
        params: Dict[str, Any] = {"q": query, "maxResults": min(100, MAX_QUERY_MATCHES - len(ids))}
        if token:
            params["pageToken"] = token
        data = request("GET", f"{GMAIL}/messages", params=params)
        ids += [m["id"] for m in data.get("messages") or []]
        token = data.get("nextPageToken")
        if not token:
            break
    return ids


def gmail_triage(ids: list, query: str, folders: list, archive: bool, mark_read: bool) -> Dict[str, Any]:
    """Files messages into folders (labels, created on demand), optionally archives (removes INBOX) and marks read
    (removes UNREAD). Messages come from explicit `ids` or from a search `query` (up to 200 matches)."""
    if bool(ids) == bool(query):
        raise GoogleError("Donne soit des identifiants de messages, soit une requête de recherche (pas les deux).")
    if not folders and not archive and not mark_read:
        raise GoogleError("Rien à faire : indique un dossier, archiver ou marquer lu.")
    if ids:
        if len(ids) > MAX_TRIAGE_IDS or any(not re.fullmatch(r"[A-Za-z0-9_-]{6,64}", str(i)) for i in ids):
            raise GoogleError(f"Donne entre 1 et {MAX_TRIAGE_IDS} identifiants valides.")
        targets = [str(i) for i in ids]
    else:
        targets = _ids_for_query(str(query))
        if not targets:
            return {"messages": 0, "note": "Aucun message ne correspond à la requête."}
    add = [_folder_id(str(name)) for name in folders]
    remove = (["INBOX"] if archive else []) + (["UNREAD"] if mark_read else [])
    for start in range(0, len(targets), 100):
        body: Dict[str, Any] = {"ids": targets[start:start + 100]}
        if add:
            body["addLabelIds"] = add
        if remove:
            body["removeLabelIds"] = remove
        request("POST", f"{GMAIL}/messages/batchModify", json=body)
    return {"messages": len(targets), "dossiers": [_valid_folder(f) for f in folders], "archives": archive, "marques_lus": mark_read}


# ---- Calendar ------------------------------------------------------------------------------------------

def calendar_timezone() -> str:
    """The calendar's zone, read from an events listing (the `calendar.events` scope cannot read calendar metadata)."""
    if "tz" not in _timezone:
        listing = request("GET", f"{CALENDAR}/calendars/primary/events", params={"maxResults": 1, "singleEvents": "true", "timeMin": "2000-01-01T00:00:00Z", "timeMax": "2000-01-02T00:00:00Z"})
        _timezone["tz"] = str(listing.get("timeZone") or "UTC")
    return _timezone["tz"]


_calendars: Dict[str, Any] = {"at": 0.0, "items": []}
MAX_CALENDARS = 8
_NOISE = ("#holiday@group.v.calendar.google.com", "addressbook#contacts@group.v.calendar.google.com")


def calendar_calendars(force: bool = False) -> list:
    """The calendars the account can see (own, shared, subscribed), as Google shows them."""
    if force or not _calendars["items"] or time.time() - _calendars["at"] > 600:
        items = request("GET", f"{CALENDAR}/users/me/calendarList", params={"maxResults": 100, "minAccessRole": "reader"}).get("items") or []
        _calendars.update(at=time.time(), items=[{
            "id": str(c.get("id") or ""), "nom": c.get("summaryOverride") or c.get("summary") or "(sans nom)",
            "principal": bool(c.get("primary")), "role": c.get("accessRole"), "affiche": c.get("selected", True) is not False,
            "fuseau": c.get("timeZone")} for c in items if c.get("id")])
    return list(_calendars["items"])


def _pick_calendars(wanted: str) -> list:
    every = calendar_calendars()
    if wanted:
        needle = wanted.strip().lower()
        chosen = [c for c in every if needle in c["nom"].lower() or needle == c["id"].lower()]
        if not chosen:
            raise GoogleError(f"Aucun agenda ne correspond à « {wanted} ». Utilise agenda_calendriers pour voir la liste.")
        return chosen[:MAX_CALENDARS]
    shown = [c for c in every if c["affiche"] and not c["id"].endswith(_NOISE)]
    return (shown or every)[:MAX_CALENDARS]


def calendar_list(time_min: str, time_max: str, query: str, limit: int, calendar: str = "") -> list:
    """Events across the shown calendars (or the one named), merged by start time."""
    params = {"timeMin": time_min, "timeMax": time_max, "singleEvents": "true", "orderBy": "startTime",
              "maxResults": max(1, min(limit, 50))}
    if query:
        params["q"] = query
    out = []
    for cal in _pick_calendars(calendar):
        for e in request("GET", f"{CALENDAR}/calendars/{quote(cal['id'], safe='')}/events", params=params).get("items") or []:
            start, end = e.get("start") or {}, e.get("end") or {}
            out.append({"id": e.get("id"), "calendrier": cal["nom"], "titre": e.get("summary") or "(sans titre)",
                        "debut": start.get("dateTime") or start.get("date"), "fin": end.get("dateTime") or end.get("date"),
                        "lieu": e.get("location") or "", "description": str(e.get("description") or "")[:300],
                        "participants": len(e.get("attendees") or []), "statut": e.get("status"), "lien": e.get("htmlLink"),
                        "modifiable": bool(cal["principal"])})
    out.sort(key=lambda e: str(e["debut"] or ""))
    return out[:max(1, min(limit, 50))]


def calendar_create(summary: str, start: Dict[str, str], end: Dict[str, str], description: str = "", location: str = "") -> Dict[str, Any]:
    body: Dict[str, Any] = {"summary": summary, "start": start, "end": end}
    if description:
        body["description"] = description
    if location:
        body["location"] = location
    created = request("POST", f"{CALENDAR}/calendars/primary/events", params={"sendUpdates": "none"}, json=body)
    return {"id": created.get("id"), "lien": created.get("htmlLink"), "debut": (created.get("start") or {}).get("dateTime") or (created.get("start") or {}).get("date")}


def _event_url(event_id: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", event_id or ""):
        raise GoogleError("Identifiant d'événement invalide.")
    return f"{CALENDAR}/calendars/primary/events/{event_id}"


def calendar_get(event_id: str) -> Dict[str, Any]:
    """An event of the MAIN calendar (events of other calendars are read-only and answer 404 here)."""
    return request("GET", _event_url(event_id))


def calendar_update(event_id: str, patch: Dict[str, Any]) -> Dict[str, Any]:
    updated = request("PATCH", _event_url(event_id), params={"sendUpdates": "none"}, json=patch)
    return {"id": updated.get("id"), "titre": updated.get("summary"), "lien": updated.get("htmlLink"),
            "debut": (updated.get("start") or {}).get("dateTime") or (updated.get("start") or {}).get("date"),
            "fin": (updated.get("end") or {}).get("dateTime") or (updated.get("end") or {}).get("date")}


def calendar_delete(event_id: str) -> Dict[str, Any]:
    """Deletes an event of the main calendar without notifying anyone; Google keeps it in the calendar bin for 30 days."""
    event = calendar_get(event_id)
    request("DELETE", _event_url(event_id), params={"sendUpdates": "none"})
    start = event.get("start") or {}
    return {"id": event_id, "titre": event.get("summary") or "(sans titre)", "debut": start.get("dateTime") or start.get("date"),
            "participants": len(event.get("attendees") or [])}
