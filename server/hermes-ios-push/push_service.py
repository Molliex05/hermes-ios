"""Durable APNs outbox; Hermes remains the only owner of conversation execution.

Uses the documented post_llm_call hook and read-only SessionDB API. No WebSocket
attachment, polling of transcripts, second agent, or changes to Hermes sources.

v0.2: end-to-end encrypted preview (AES-256-GCM, key per installation+connection, held only in
notifications.sqlite), presence suppression checked at send time, and the `ios_notify` tool outbox.
Privacy rule: neither the key nor the clear text (agent, conversation, preview, tool message) is ever
logged, returned by an API or put in an error message.

v0.3: Live Activity updates pushed by the server (`pre_tool_call` -> generic "working" label, `post_llm_call`
-> "done"; content-state carries NO conversation text because it crosses Apple unencrypted) and a periodic
silent background push that makes the app refresh its widgets. See outputs/live-activity-2026-10-20/CONTRACT.md.
"""
from __future__ import annotations

import asyncio
import base64
import binascii
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import hashlib
import json
import logging
import os
from pathlib import Path
import re
import sqlite3
import sys
import threading
import time
import uuid

# HTTP/2 is mandatory for APNs. Images that lack `h2` can ship its pure-Python wheels (h2, hyperframe, hpack)
# next to the plugin in `_vendor/`; installed packages always win because the folder is appended, not prepended.
_VENDOR = Path(__file__).resolve().parent / "_vendor"
if _VENDOR.is_dir() and str(_VENDOR) not in sys.path:
    sys.path.append(str(_VENDOR))

log = logging.getLogger("hermes_ios_push")
TOPIC = "org.hermesios.HermesIOS"
MAX_AGE = 24 * 60 * 60
KEY_BYTES = 32            # AES-256-GCM
MAX_PAYLOAD = 4096        # APNs limit for the whole JSON body
PREVIEW_CHARS = 140
AGENT_CHARS, CONVERSATION_CHARS = 60, 100
TOOL_PER_HOUR, TOOL_PER_DAY = 5, 20
TURN_MARKER_AGE = 6 * 60 * 60
CRON_DELIVERY_WINDOW = 60 * 60
PRESENCE_TTL = (5, 120)
LIVE_TTL = 8 * 60 * 60            # an activity registration expires after 8 h (Apple ends a Live Activity after 8 h)
LIVE_UPDATE_INTERVAL = 5          # at most one `update` per activity every 5 s (the last one wins)
LIVE_DISMISS_AFTER = 15 * 60      # `end` removes the activity from the Lock Screen 15 min later
LIVE_UPDATE_TTL, LIVE_END_TTL = 120, 60 * 60       # apns-expiration, seconds after sending
LIVE_RETRY_DELAY = 10
LIVE_TOPIC_SUFFIX = ".push-type.liveactivity"
LIVE_DONE_DETAIL = "Réponse prête"
LIVE_QUEUE_LIMIT = 256            # jobs waiting in memory for the hook worker thread
WIDGETS_DEFAULT_MINUTES, WIDGETS_MAX_MINUTES = 60, 7 * 24 * 60


def data_home() -> Path:
    from hermes_constants import get_default_hermes_root
    return Path(os.environ.get("HERMES_IOS_PUSH_HOME") or get_default_hermes_root() / "ios-push")


# ---------------------------------------------------------------- crypto (CONTRACT §1-§2)

def decode_key(value) -> bytes:
    """Validate a base64 (standard alphabet) 32-byte key. Raises ValueError WITHOUT echoing the value."""
    if not isinstance(value, str) or not value or len(value) > 64:
        raise ValueError("invalid key")
    try:
        raw = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        raise ValueError("invalid key") from None
    if len(raw) != KEY_BYTES:
        raise ValueError("invalid key")
    return raw


def encrypt_content(key: bytes, event_id: str, content: dict, nonce: bytes | None = None) -> str:
    """base64(nonce[12] || ciphertext || tag[16]); AAD = UTF-8 bytes of event_id; compact UTF-8 JSON."""
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    nonce = nonce or os.urandom(12)
    plain = json.dumps(content, ensure_ascii=False, separators=(",", ":")).encode()
    return base64.b64encode(nonce + AESGCM(key).encrypt(nonce, plain, event_id.encode())).decode()


def decrypt_content(key: bytes, event_id: str, enc: str) -> dict:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    raw = base64.b64decode(enc, validate=True)
    return json.loads(AESGCM(key).decrypt(raw[:12], raw[12:], event_id.encode()))


# ---------------------------------------------------------------- text helpers

def strip_markdown(text) -> str:
    t = str(text or "")
    t = re.sub(r"```[^\n]*\n?", " ", t)                          # fence markers (keep the code text)
    t = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", t)              # images -> alt
    t = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", t)               # links -> label
    t = re.sub(r"\[([^\]]+)\]\[[^\]]*\]", r"\1", t)              # reference links
    t = re.sub(r"<[^>\n]{1,200}>", " ", t)                       # html tags / autolinks
    t = re.sub(r"(?m)^\s{0,3}#{1,6}\s*", "", t)                  # headings
    t = re.sub(r"(?m)^\s*>+\s?", "", t)                          # quotes
    t = re.sub(r"(?m)^\s*([-*+]|\d+[.)])\s+", "", t)             # list markers
    t = re.sub(r"(?m)^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$", " ", t)   # table rules / hr
    t = t.replace("|", " ")
    t = re.sub(r"`+([^`]*)`+", r"\1", t)                         # inline code
    t = re.sub(r"(\*\*|__)(.+?)\1", r"\2", t, flags=re.S)         # bold
    t = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?!\w)", r"\1", t, flags=re.S)   # italics
    t = re.sub(r"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)", r"\1", t, flags=re.S)
    t = re.sub(r"~~(.+?)~~", r"\1", t, flags=re.S)
    return re.sub(r"\s+", " ", t).strip()


def truncate(text, limit: int) -> str:
    """Cut at a word boundary where possible, ending with an ellipsis; never longer than `limit`."""
    text = re.sub(r"\s+", " ", str(text or "")).strip()
    if len(text) <= limit:
        return text
    cut = text[:max(limit - 1, 0)]
    space = cut.rfind(" ")
    if space >= limit * 0.6:
        cut = cut[:space]
    return cut.rstrip(" ,;:.-–—") + "…"


def make_preview(text, limit: int = PREVIEW_CHARS) -> str:
    return truncate(strip_markdown(text), limit)


def agent_display_name(home, profile: str) -> str:
    """ui_meta.hermes-bots.title, else display_name, else the profile name (same order as the app)."""
    name = ""
    try:
        from hermes_cli.profiles import read_profile_meta
        meta = read_profile_meta(Path(home))
        name = (meta.get("bot_title") or meta.get("display_name") or "").strip()
    except Exception:
        try:
            import yaml
            data = yaml.safe_load((Path(home) / "profile.yaml").read_text(encoding="utf-8")) or {}
            bots = (data.get("ui_meta") or {}).get("hermes-bots") or {}
            name = str(bots.get("title") or data.get("display_name") or "").strip()
        except Exception:
            name = ""
    return truncate(name or profile, AGENT_CHARS)


# ---------------------------------------------------------------- payload

def thread_id(row) -> str:
    base = f'{row["connection"]}:{row["profile"]}'
    return hashlib.sha256((base + (f':{row["session"]}' if row["session"] else "")).encode()).hexdigest()


def notification_payload(row):
    """APNs JSON for an outbox row. `enc` (when present) is already sealed for the target device."""
    enc, kind = row.get("enc"), row.get("kind") or "turn"
    if kind == "tool":
        alert = {"title": row.get("title") or "Hermès", "body": "Nouveau message"}
    elif enc:
        alert = {"title": "Hermès", "body": "Nouveau message"}
    else:
        alert = {"title": "Hermès", "body": "Un nouveau message vous attend."}     # v0.1 generic fallback
    aps = {"alert": alert, "sound": "default", "thread-id": thread_id(row)}
    hermes = {"version": 1, "connection_id": row["connection"], "profile": row["profile"]}
    if row["session"]:
        hermes["session_id"] = row["session"]
    hermes.update({"event_id": row["event"], "kind": kind})
    if enc:
        aps["mutable-content"] = 1
        hermes["enc"] = enc
    return {"aps": aps, "hermes": hermes}


def seal(key: bytes, row: dict, content: dict) -> str | None:
    """Encrypt `content` for a device so that the whole APNs body stays under MAX_PAYLOAD bytes. The preview is
    shortened to fit; if even that is impossible, return None (generic notification). Never raises."""
    try:
        base = {"agent": truncate(content.get("agent", ""), AGENT_CHARS),
                "conversation": truncate(content.get("conversation", ""), CONVERSATION_CHARS)}
        preview = str(content.get("preview", ""))
        while True:
            enc = encrypt_content(key, row["event"], {**base, "preview": preview})
            size = len(json.dumps(notification_payload({**row, "enc": enc}), ensure_ascii=False,
                                  separators=(",", ":")).encode())
            if size < MAX_PAYLOAD - 64:          # margin for serialisation differences
                return enc
            if not preview:
                return None
            preview = truncate(preview, int(len(preview) * 0.8)) if len(preview) > 20 else ""
    except Exception as error:
        log.warning("Notification content could not be sealed (%s)", type(error).__name__)
        return None


# ---------------------------------------------------------------- Live Activity payloads (CONTRACT-LIVE §3)

DEFAULT_TOOL_LABEL = "Utilise un outil"
# Only the NAME of a tool is looked at, never its arguments or result. First match wins.
_TOOL_LABELS = (
    (("agenda", "calendar", "calendrier"), "Regarde ton agenda"),
    (("gmail", "mail", "google_perso", "courriel"), "Regarde tes courriels"),
    (("meteo", "weather"), "Consulte la météo"),
    (("memory", "session_search"), "Consulte sa mémoire"),
    (("browser", "computer_use"), "Navigue sur le web"),
    (("terminal", "execute_code", "process_manage", "shell", "bash"), "Exécute une commande"),
    (("web_", "x_search", "internet"), "Cherche sur le web"),
    (("file", "patch"), "Lit des fichiers"),
)


def tool_label(tool_name) -> str:
    """Fixed French label for a tool name. Nothing but the name is used: the result is one of this table."""
    name = str(tool_name or "").lower()[:200]
    for needles, label in _TOOL_LABELS:
        if any(n in name for n in needles):
            return label
    return DEFAULT_TOOL_LABEL


def _widgets_key(installation, connection) -> str:
    return f"widgets:{installation}:{connection}"


def _number(value):
    value = float(value)
    return int(value) if value.is_integer() else value


def live_state(phase: str, title: str, detail: str, started_at) -> dict:
    """The content-state sent to ActivityKit: EXACTLY phase, title, detail, muted, startedAt."""
    return {"phase": phase, "title": truncate(title, AGENT_CHARS), "detail": detail, "muted": False,
            "startedAt": _number(started_at)}


def live_payload(row) -> dict:
    """APNs JSON of a Live Activity event. `row` carries event ("update"|"end"), state (JSON content-state) and
    timestamp (integer seconds, strictly increasing per activity)."""
    timestamp = int(row["timestamp"])
    aps = {"timestamp": timestamp, "event": row["event"], "content-state": json.loads(row["state"])}
    if row["event"] == "end":
        aps["dismissal-date"] = timestamp + LIVE_DISMISS_AFTER
    return {"aps": aps}


def widgets_payload() -> dict:
    return {"aps": {"content-available": 1}, "hermes": {"version": 1, "kind": "widgets"}}


def widgets_refresh_minutes(config) -> int:
    """`widgets_refresh_minutes` of apns.json: minutes between two silent pushes per device; 0 disables."""
    value = (config or {}).get("widgets_refresh_minutes", WIDGETS_DEFAULT_MINUTES)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value or value in (float("inf"), float("-inf")):
        return WIDGETS_DEFAULT_MINUTES
    return max(0, min(WIDGETS_MAX_MINUTES, int(value)))


def is_invalid_token(status, reason) -> bool:
    return status == 410 or reason == "Unregistered" or status == 400 and reason in {"BadDeviceToken", "DeviceTokenNotForTopic"}


# ---------------------------------------------------------------- storage

class Store:
    def __init__(self, home: Path | None = None):
        self.home = home or data_home()
        self.home.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.home / "notifications.sqlite"
        if not self.path.exists():
            os.close(os.open(self.path, os.O_CREAT | os.O_WRONLY, 0o600))   # never world-readable, even briefly
        with self.connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS devices (
                    installation TEXT NOT NULL, connection TEXT NOT NULL, token TEXT NOT NULL,
                    environment TEXT NOT NULL, registered REAL NOT NULL,
                    PRIMARY KEY (installation, connection));
                CREATE TABLE IF NOT EXISTS outbox (
                    event TEXT NOT NULL, installation TEXT NOT NULL, connection TEXT NOT NULL,
                    profile TEXT NOT NULL, session TEXT NOT NULL, created REAL NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL DEFAULT 0,
                    state TEXT NOT NULL DEFAULT 'pending', reason TEXT,
                    PRIMARY KEY (event, installation, connection));
                CREATE TABLE IF NOT EXISTS device_keys (
                    installation TEXT NOT NULL, connection TEXT NOT NULL, key BLOB NOT NULL,
                    PRIMARY KEY (installation, connection));
                CREATE TABLE IF NOT EXISTS presence (
                    installation TEXT NOT NULL, connection TEXT NOT NULL, profile TEXT NOT NULL,
                    session TEXT NOT NULL, expires REAL NOT NULL,
                    PRIMARY KEY (installation, connection, profile, session));
                CREATE TABLE IF NOT EXISTS tool_log (profile TEXT NOT NULL, created REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS tool_log_profile ON tool_log(profile, created);
                CREATE TABLE IF NOT EXISTS tool_turns (
                    session TEXT NOT NULL, turn TEXT NOT NULL, created REAL NOT NULL,
                    PRIMARY KEY (session, turn));
                CREATE TABLE IF NOT EXISTS cron_notified (
                    profile TEXT NOT NULL, job TEXT NOT NULL, created REAL NOT NULL, PRIMARY KEY (profile, job));
                CREATE TABLE IF NOT EXISTS activities (
                    installation TEXT NOT NULL, connection TEXT NOT NULL, profile TEXT NOT NULL, session TEXT NOT NULL,
                    activity TEXT NOT NULL, token TEXT NOT NULL, environment TEXT NOT NULL, kind TEXT NOT NULL,
                    started_at REAL NOT NULL, registered REAL NOT NULL, expires REAL NOT NULL,
                    last_update REAL NOT NULL DEFAULT 0, last_ts INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (installation, activity));
                CREATE INDEX IF NOT EXISTS activities_session ON activities(profile, session);
                CREATE TABLE IF NOT EXISTS live_queue (
                    installation TEXT NOT NULL, activity TEXT NOT NULL, event TEXT NOT NULL, state TEXT NOT NULL,
                    created REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL DEFAULT 0,
                    PRIMARY KEY (installation, activity, event));
                CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
            # v0.1 -> v0.2: only additive changes. The key lives in its own table so the `devices` table is
            # untouched and v0.1 code (positional INSERT) keeps working against a migrated database.
            self._add_column(db, "outbox", "kind", "TEXT NOT NULL DEFAULT 'turn'")
            self._add_column(db, "outbox", "enc", "TEXT")
            self._add_column(db, "outbox", "title", "TEXT")
        self.path.chmod(0o600)

    @staticmethod
    def _add_column(db, table, column, definition):
        if column not in {row["name"] for row in db.execute(f"PRAGMA table_info({table})")}:
            try:
                db.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")
            except sqlite3.OperationalError as error:       # another process migrated first
                if "duplicate column" not in str(error):
                    raise

    @contextmanager
    def connect(self, immediate=False):
        db = sqlite3.connect(self.path, timeout=5)
        db.row_factory = sqlite3.Row
        try:
            db.execute("PRAGMA secure_delete=ON")      # a revoked key/ciphertext is overwritten, not just unlinked
            if immediate:
                db.execute("BEGIN IMMEDIATE")      # takes the write lock now: check-then-insert is atomic
            with db:
                yield db
        finally:
            db.close()

    # -- devices

    def register(self, installation, connection, token, environment, key: bytes | None = None):
        with self.connect() as db:
            old = db.execute("SELECT key FROM device_keys WHERE installation=? AND connection=?",
                             (installation, connection)).fetchone()
            db.execute("INSERT INTO devices(installation,connection,token,environment,registered) VALUES (?,?,?,?,?) "
                       "ON CONFLICT(installation,connection) DO UPDATE SET token=excluded.token,"
                       "environment=excluded.environment,registered=excluded.registered",
                       (installation, connection, token, environment, time.time()))
            if key is None:
                db.execute("DELETE FROM device_keys WHERE installation=? AND connection=?", (installation, connection))
            else:
                db.execute("INSERT INTO device_keys VALUES (?,?,?) ON CONFLICT(installation,connection) "
                           "DO UPDATE SET key=excluded.key", (installation, connection, key))
            if (old["key"] if old else None) != key and old is not None:
                # Rotation: a ciphertext made with the previous key can no longer be opened by the app.
                db.execute("UPDATE outbox SET enc=NULL WHERE installation=? AND connection=? AND state='pending'",
                           (installation, connection))

    @staticmethod
    def _drop_orphan_keys(db):
        db.execute("DELETE FROM device_keys WHERE NOT EXISTS (SELECT 1 FROM devices d WHERE "
                   "d.installation=device_keys.installation AND d.connection=device_keys.connection)")

    def revoke(self, installation, connection):
        with self.connect() as db:
            db.execute("DELETE FROM devices WHERE installation=? AND connection=?", (installation, connection))
            db.execute("DELETE FROM device_keys WHERE installation=? AND connection=?", (installation, connection))
            db.execute("DELETE FROM outbox WHERE installation=? AND connection=?", (installation, connection))
            db.execute("DELETE FROM presence WHERE installation=? AND connection=?", (installation, connection))
            db.execute("DELETE FROM live_queue WHERE EXISTS (SELECT 1 FROM activities a WHERE a.installation=? AND "
                       "a.connection=? AND a.installation=live_queue.installation AND a.activity=live_queue.activity)",
                       (installation, connection))
            db.execute("DELETE FROM activities WHERE installation=? AND connection=?", (installation, connection))
            db.execute("DELETE FROM meta WHERE key=?", (_widgets_key(installation, connection),))

    def devices(self):
        with self.connect() as db:
            return [dict(r) for r in db.execute(
                "SELECT d.installation,d.connection,(k.key IS NOT NULL) AS has_key FROM devices d "
                "LEFT JOIN device_keys k USING(installation,connection)")]

    # -- outbox

    def _insert(self, db, event, profile, session, kind, content, title, now):
        """One outbox row per registered device; the content is encrypted with THAT device's key right here,
        so the outbox never holds clear text."""
        count = 0
        for device in db.execute("SELECT d.installation,d.connection,k.key FROM devices d "
                                  "LEFT JOIN device_keys k USING(installation,connection)").fetchall():
            row = {"event": event, "connection": device["connection"], "profile": profile, "session": session,
                   "kind": kind, "title": title}
            enc = seal(device["key"], row, content) if device["key"] and content else None
            cursor = db.execute(
                "INSERT OR IGNORE INTO outbox(event,installation,connection,profile,session,created,kind,enc,title) "
                "VALUES (?,?,?,?,?,?,?,?,?)",
                (event, device["installation"], device["connection"], profile, session, now, kind, enc, title))
            count += cursor.rowcount
        return count

    def enqueue(self, event, profile, session, kind="turn", content=None, title=None):
        now = time.time()
        with self.connect() as db:
            self._insert(db, event, profile, session, kind, content, title, now)
            db.execute("DELETE FROM outbox WHERE created < ?", (now - MAX_AGE,))

    def pending(self):
        now = time.time()
        with self.connect() as db:
            db.execute("DELETE FROM outbox WHERE created < ?", (now - MAX_AGE,))
            return [dict(row) for row in db.execute(
                "SELECT o.*,d.token,d.environment FROM outbox o JOIN devices d USING(installation,connection) "
                "WHERE o.state='pending' AND o.next_attempt <= ? AND o.created >= ? ORDER BY o.created LIMIT 50",
                (now, now - MAX_AGE))]

    def _invalidate_device(self, db, row, invalidated_at=None):
        # A delayed 410 for an older registration must not remove a refreshed token.
        cutoff = invalidated_at / 1000 if invalidated_at else time.time()
        db.execute("DELETE FROM devices WHERE installation=? AND connection=? AND token=? AND registered<=?",
                   (row["installation"], row["connection"], row["token"], cutoff))
        self._drop_orphan_keys(db)

    def resolve(self, row, status, reason="", invalidated_at=None):
        identity = (row["event"], row["installation"], row["connection"])
        with self.connect() as db:
            if status == 410 or status == 400 and reason in {"BadDeviceToken", "DeviceTokenNotForTopic"}:
                self._invalidate_device(db, row, invalidated_at)
            if status == 200:
                state, next_attempt = "sent", 0
            elif status in {0, 403, 429, 500, 503}:
                state = "pending"
                next_attempt = time.time() + min(3600, 5 * 2 ** min(row["attempts"], 10))
            else:
                state, next_attempt = "failed", 0
            # A delivered or abandoned row keeps no ciphertext.
            db.execute("UPDATE outbox SET state=?,reason=?,attempts=attempts+1,next_attempt=?,"
                       "enc=CASE WHEN ?='pending' THEN enc ELSE NULL END "
                       "WHERE event=? AND installation=? AND connection=?",
                       (state, reason[:100], next_attempt, state, *identity))

    # -- Live Activities (CONTRACT-LIVE §1-§2)

    def put_activity(self, installation, connection, profile, session, activity, token, environment, kind, started_at, now=None):
        """Register (or replace) a Live Activity. Expired registrations are purged on every write.
        Returns the expiry (epoch seconds)."""
        now = now or time.time()
        expires = now + LIVE_TTL
        with self.connect() as db:
            self._purge_activities(db, now)
            db.execute("INSERT INTO activities(installation,connection,profile,session,activity,token,environment,kind,"
                       "started_at,registered,expires) VALUES (?,?,?,?,?,?,?,?,?,?,?) "
                       "ON CONFLICT(installation,activity) DO UPDATE SET connection=excluded.connection,"
                       "profile=excluded.profile,session=excluded.session,token=excluded.token,"
                       "environment=excluded.environment,kind=excluded.kind,started_at=excluded.started_at,"
                       "registered=excluded.registered,expires=excluded.expires",
                       (installation, connection, profile, session, activity, token, environment, kind,
                        float(started_at), now, expires))
        return expires

    @staticmethod
    def _purge_activities(db, now):
        db.execute("DELETE FROM activities WHERE expires <= ?", (now,))
        db.execute("DELETE FROM live_queue WHERE NOT EXISTS (SELECT 1 FROM activities a WHERE "
                   "a.installation=live_queue.installation AND a.activity=live_queue.activity)")

    def delete_activity(self, installation, activity):
        with self.connect() as db:
            db.execute("DELETE FROM live_queue WHERE installation=? AND activity=?", (installation, activity))
            db.execute("DELETE FROM activities WHERE installation=? AND activity=?", (installation, activity))

    def activities(self, now=None):
        now = now or time.time()
        with self.connect() as db:
            return [dict(r) for r in db.execute("SELECT * FROM activities WHERE expires > ? ORDER BY registered", (now,))]

    def activities_for(self, profile, session, kind="reply", now=None):
        now = now or time.time()
        with self.connect() as db:
            return [dict(r) for r in db.execute(
                "SELECT * FROM activities WHERE profile=? AND session=? AND kind=? AND expires > ?",
                (profile, session, kind, now))]

    def enqueue_live(self, activity, event, state, now=None) -> bool:
        """Queue one event for an activity. `update` rows are coalesced (a newer one replaces the pending one) and
        dropped once an `end` is pending; `end` removes any pending update and is never ignored."""
        now = now or time.time()
        with self.connect(immediate=True) as db:
            if not db.execute("SELECT 1 FROM activities WHERE installation=? AND activity=? AND expires > ?",
                              (activity["installation"], activity["activity"], now)).fetchone():
                return False
            if event == "update":
                if db.execute("SELECT 1 FROM live_queue WHERE installation=? AND activity=? AND event='end'",
                              (activity["installation"], activity["activity"])).fetchone():
                    return False
            else:
                db.execute("DELETE FROM live_queue WHERE installation=? AND activity=? AND event='update'",
                           (activity["installation"], activity["activity"]))
            db.execute("INSERT OR REPLACE INTO live_queue(installation,activity,event,state,created) VALUES (?,?,?,?,?)",
                       (activity["installation"], activity["activity"], event, json.dumps(state, ensure_ascii=False, separators=(",", ":")), now))
            return True

    def pending_live(self, now=None):
        """Events ready to leave: `end` first; an `update` only if 5 s elapsed since the last update was sent."""
        now = now or time.time()
        with self.connect() as db:
            self._purge_activities(db, now)
            return [dict(r) for r in db.execute(
                "SELECT q.installation,q.activity,q.event,q.state,q.created,q.attempts,a.connection,a.profile,a.session,"
                "a.token,a.environment,a.started_at,a.last_update,a.last_ts FROM live_queue q JOIN activities a "
                "USING(installation,activity) WHERE q.next_attempt <= ? AND "
                "(q.event='end' OR ? - a.last_update >= ?) ORDER BY (q.event='end') DESC, q.created LIMIT 50",
                (now, now, LIVE_UPDATE_INTERVAL))]

    def resolve_live(self, row, status, reason="", now=None):
        """Outcome of one APNs call. 200: done (an `end` also forgets the activity). Invalid token: the activity is
        forgotten. 0/403/429/5xx: ONE more attempt later, then the event is dropped. Anything else: dropped."""
        now = now or time.time()
        where = (row["installation"], row["activity"], row["event"], row["created"])
        with self.connect() as db:
            if status == 200:
                db.execute("DELETE FROM live_queue WHERE installation=? AND activity=? AND event=? AND created=?", where)
                if row["event"] == "end":
                    db.execute("DELETE FROM live_queue WHERE installation=? AND activity=?", where[:2])
                    db.execute("DELETE FROM activities WHERE installation=? AND activity=?", where[:2])
                else:
                    db.execute("UPDATE activities SET last_update=?,last_ts=MAX(last_ts,?) WHERE installation=? AND activity=?",
                               (now, int(row.get("timestamp") or 0), *where[:2]))
                return
            if is_invalid_token(status, reason):
                # A delayed 410 for an older token must not remove an activity that registered a fresh one.
                if db.execute("SELECT 1 FROM activities WHERE installation=? AND activity=? AND token=?",
                              (*where[:2], row["token"])).fetchone():
                    db.execute("DELETE FROM live_queue WHERE installation=? AND activity=?", where[:2])
                    db.execute("DELETE FROM activities WHERE installation=? AND activity=?", where[:2])
                else:
                    db.execute("DELETE FROM live_queue WHERE installation=? AND activity=? AND event=? AND created=?", where)
                return
            if status in {0, 403, 429, 500, 503} and row["attempts"] < 1:
                db.execute("UPDATE live_queue SET attempts=attempts+1,next_attempt=? WHERE installation=? AND activity=? "
                           "AND event=? AND created=?", (now + LIVE_RETRY_DELAY, *where))
            else:
                db.execute("DELETE FROM live_queue WHERE installation=? AND activity=? AND event=? AND created=?", where)

    # -- silent widget refresh (CONTRACT-LIVE §5)

    def claim_widget_pushes(self, interval_seconds, now=None):
        """Devices whose last silent push is older than the interval; each one is stamped NOW (at most once per
        interval, even if Apple then fails). A device never seen before is only stamped, not pushed: a restart or an
        upgrade never fires a burst. Stamps of vanished devices are forgotten."""
        now = now or time.time()
        due = []
        with self.connect(immediate=True) as db:
            keys = set()
            for device in db.execute("SELECT installation,connection,token,environment,registered FROM devices").fetchall():
                key = _widgets_key(device["installation"], device["connection"])
                keys.add(key)
                row = db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
                try:
                    last = float(row["value"]) if row else None
                except ValueError:
                    last = None
                if last is None or last > now + 60:          # unknown, or the clock went backwards: restart the interval
                    db.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", (key, repr(now)))
                elif now - last >= interval_seconds:
                    db.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", (key, repr(now)))
                    due.append(dict(device))
            for row in db.execute("SELECT key FROM meta WHERE key LIKE 'widgets:%'").fetchall():
                if row["key"] not in keys:
                    db.execute("DELETE FROM meta WHERE key=?", (row["key"],))
        return due

    def resolve_device(self, device, status, reason="", invalidated_at=None):
        """Apple's answer to a push addressed to a device (not to an outbox row): an invalid token removes it."""
        if is_invalid_token(status, reason):
            with self.connect() as db:
                self._invalidate_device(db, device, invalidated_at)

    # -- presence (CONTRACT §3)

    def set_presence(self, installation, connection, profile, session, ttl):
        now = time.time()
        lo, hi = PRESENCE_TTL
        ttl = max(lo, min(hi, int(ttl)))
        with self.connect() as db:
            db.execute("DELETE FROM presence WHERE expires <= ?", (now,))
            db.execute("INSERT INTO presence VALUES (?,?,?,?,?) ON CONFLICT(installation,connection,profile,session) "
                       "DO UPDATE SET expires=excluded.expires", (installation, connection, profile, session, now + ttl))

    def clear_presence(self, installation, connection, profile, session):
        with self.connect() as db:
            db.execute("DELETE FROM presence WHERE installation=? AND connection=? AND profile=? AND session=?",
                       (installation, connection, profile, session))

    def suppress_if_present(self, row) -> bool:
        """Called by the worker right before sending. Only automatic turn notifications for a real
        conversation are suppressed, and only by a live presence of the SAME installation as the target device."""
        if row.get("kind", "turn") != "turn" or not row["session"]:
            return False
        with self.connect() as db:
            here = db.execute("SELECT 1 FROM presence WHERE installation=? AND connection=? AND profile=? "
                              "AND session=? AND expires > ?",
                              (row["installation"], row["connection"], row["profile"], row["session"], time.time())).fetchone()
            if here:
                db.execute("UPDATE outbox SET state='suppressed',reason='presence',enc=NULL "
                           "WHERE event=? AND installation=? AND connection=? AND state='pending'",
                           (row["event"], row["installation"], row["connection"]))
            return bool(here)

    # -- ios_notify (CONTRACT §4, §7b)

    def enqueue_tool(self, profile, session, turn_session, turn, content, title, now=None):
        """Atomically: devices exist? limits? then count the call, queue it, and mark the turn so the automatic
        notification of the same turn is dropped. Returns {"ok": True, "queued": n} or {"ok": False, "error": ..}."""
        now = now or time.time()
        with self.connect(immediate=True) as db:
            if not db.execute("SELECT 1 FROM devices LIMIT 1").fetchone():
                return {"ok": False, "error": "no_device"}
            db.execute("DELETE FROM tool_log WHERE created < ?", (now - 2 * 86400,))
            for window, limit, name in ((3600, TOOL_PER_HOUR, "hour"), (86400, TOOL_PER_DAY, "day")):
                used = db.execute("SELECT COUNT(*), MIN(created) FROM tool_log WHERE profile=? AND created > ?",
                                  (profile, now - window)).fetchone()
                if used[0] >= limit:
                    return {"ok": False, "error": "limit_" + name, "retry_in": int(used[1] + window - now) + 1}
            db.execute("INSERT INTO tool_log VALUES (?,?)", (profile, now))        # counted when queued
            queued = self._insert(db, str(uuid.uuid4()), profile, session, "tool", content, title, now)
            if turn_session:     # the turn that called the tool, whether or not the tap opens it
                db.execute("INSERT OR REPLACE INTO tool_turns VALUES (?,?,?)", (turn_session, turn or "", now))
            return {"ok": True, "queued": queued}

    def consume_tool_turn(self, session, turn) -> bool:
        """True (and forget it) if ios_notify served during this turn of this session. The hook fires once per
        turn and turns of a session are serial, so a marker without a known turn id belongs to the turn that
        is ending now."""
        now = time.time()
        with self.connect() as db:
            db.execute("DELETE FROM tool_turns WHERE created < ?", (now - TURN_MARKER_AGE,))
            cursor = db.execute("DELETE FROM tool_turns WHERE session=? AND (turn=? OR turn='')", (session, turn or ""))
            return cursor.rowcount > 0


    # -- cron runs that used ios_notify: their bot-chat delivery must not notify a second time

    def note_cron_run(self, profile, job_name, used_tool):
        with self.connect() as db:
            db.execute("DELETE FROM cron_notified WHERE profile=? AND job=?", (profile, job_name))
            if used_tool:
                db.execute("INSERT INTO cron_notified VALUES (?,?,?)", (profile, job_name, time.time()))

    def consume_cron_delivery(self, profile, user_message) -> bool:
        """True (once) when `user_message` is the bot-chat delivery of a cron run that already notified."""
        now, text = time.time(), str(user_message or "")
        with self.connect() as db:
            db.execute("DELETE FROM cron_notified WHERE created < ?", (now - CRON_DELIVERY_WINDOW,))
            for row in db.execute("SELECT job FROM cron_notified WHERE profile=?", (profile,)).fetchall():
                if text.startswith('[Cronjob "' + row["job"] + '" output'):
                    db.execute("DELETE FROM cron_notified WHERE profile=? AND job=?", (profile, row["job"]))
                    return True
        return False


# ---------------------------------------------------------------- Hermes hook

def _note_cron_run(session_id, turn_id, assistant_response, profile, store):
    """A cron run ended. If it used ios_notify, remember its job so that the Bot Chat turn which receives the
    output (`[Cronjob "<name>" output ...]`) does not produce a second notification."""
    match = re.fullmatch(r"cron_([0-9a-f]+)_\d{8}_\d{6}", session_id or "")
    if not match:
        return
    from cron.jobs import get_job
    job = get_job(match.group(1)) or {}
    name = job.get("name")
    if isinstance(name, str) and name:
        used = store.consume_tool_turn(session_id, turn_id)
        store.note_cron_run(profile, name, used and str(assistant_response or "").strip() != "[SILENT]")


def record_completion(*, session_id="", assistant_response="", platform="", turn_id="", user_message="", **kwargs):
    # Cron execution is internal. Its native bot-chat delivery starts a real turn
    # in the destination conversation; that turn produces the single notification.
    if not session_id or not assistant_response or not turn_id:
        return
    from hermes_constants import get_hermes_home, profile_name_for_home
    home = get_hermes_home()
    profile = profile_name_for_home(home)
    if not profile:
        return
    if platform == "cron":
        try:
            _note_cron_run(session_id, turn_id, assistant_response, profile, Store())
        except Exception:
            pass        # best effort: worst case is one extra notification
        return
    from hermes_state import SessionDB
    db = SessionDB(home / "state.db", read_only=True)
    try:
        session = db.get_session(session_id)
    finally:
        db.close()
    if not session or session.get("source") not in {"cli", "desktop", "tui", "web"}:
        return
    store = Store()
    if store.consume_tool_turn(session_id, turn_id):
        return      # ios_notify already notified for this turn: no second notification
    if store.consume_cron_delivery(profile, user_message):
        return      # the cron run behind this delivery already called ios_notify
    try:
        content = {"agent": agent_display_name(home, profile),
                   "conversation": session.get("title") or "Conversation",
                   "preview": make_preview(assistant_response)}
    except Exception:
        content = None      # generic notification rather than none
    event = str(uuid.uuid5(uuid.NAMESPACE_URL, f"hermes-ios:{profile}:{session_id}:{turn_id}"))
    store.enqueue(event, profile, session_id, "turn", content)


# ---------------------------------------------------------------- Live Activity hooks (CONTRACT-LIVE §4)
#
# Hermes calls `pre_tool_call` before EVERY tool and fails closed if a callback is slow or raises, so these hooks do
# nothing but hand a tiny job to one background thread and return None at once. The thread writes the (coalesced)
# event into the SQLite queue that the dashboard worker, another process, delivers to Apple.

_live_pool = None
_live_lock = threading.Lock()
_live_waiting = 0
_live_stores: dict = {}


def _live_store(home):
    key = str(home)
    store = _live_stores.get(key)
    if store is None:
        store = _live_stores[key] = Store(Path(home))
    return store


def _live_job(event, store_home, home, profile, session_id, tool_name):
    global _live_waiting
    try:
        store = _live_store(store_home)
        activities = store.activities_for(profile, session_id, "reply")
        if not activities:
            return
        title = agent_display_name(home, profile)
        for activity in activities:
            if event == "update":
                state = live_state("working", title, tool_label(tool_name), activity["started_at"])
            else:
                state = live_state("done", title, LIVE_DONE_DETAIL, activity["started_at"])
            store.enqueue_live(activity, event, state)
    except Exception as error:      # never any content, token or path
        log.warning("Live Activity event could not be queued (%s)", type(error).__name__)
    finally:
        with _live_lock:
            _live_waiting -= 1


def _schedule_live(event, session_id, tool_name=""):
    """Never blocks, never raises."""
    global _live_pool, _live_waiting
    try:
        if not session_id or not isinstance(session_id, str):
            return
        from hermes_constants import get_hermes_home, profile_name_for_home
        home = get_hermes_home()
        profile = profile_name_for_home(home)     # resolved here: the worker thread does not share context variables
        if not profile:
            return
        store_home = data_home()
        with _live_lock:
            if _live_waiting >= LIVE_QUEUE_LIMIT:
                return
            if _live_pool is None:
                _live_pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="hermes-ios-live")
            _live_waiting += 1
            pool = _live_pool
        try:
            pool.submit(_live_job, event, store_home, home, profile, session_id, tool_name if isinstance(tool_name, str) else "")
        except Exception:
            with _live_lock:
                _live_waiting -= 1
    except Exception:
        pass


def flush_live(timeout: float = 10.0) -> bool:
    """Wait until every job handed to the hook thread so far has run (tests, orderly shutdown)."""
    pool = _live_pool
    if pool is None:
        return True
    try:
        pool.submit(lambda: None).result(timeout)
        return True
    except Exception:
        return False


def on_pre_tool_call(*, tool_name="", session_id="", **kwargs):
    """`pre_tool_call`: tell the Live Activity of this session which kind of tool runs. Only the tool NAME is read;
    arguments and results are never touched. Returns None: this hook never blocks, modifies or approves a call."""
    _schedule_live("update", session_id, tool_name)
    return None


def on_post_llm_call(*, session_id="", **kwargs):
    """`post_llm_call`: end the Live Activity of this session, then the unchanged turn notification (the exact
    behaviour of v0.2's `record_completion`, whose errors are now logged instead of raised)."""
    _schedule_live("end", session_id)
    try:
        record_completion(session_id=session_id, **kwargs)
    except Exception as error:      # a hook never raises into Hermes; the type is logged, never the content
        log.warning("Turn notification could not be recorded (%s)", type(error).__name__)
    return None


def load_settings(home: Path | None = None):
    home = home or data_home()
    try:
        config = json.loads((home / "apns.json").read_text())
        if not all(isinstance(config.get(k), str) and config[k] for k in ("team_id", "key_id", "key_path")):
            return None
        key = Path(config["key_path"]).expanduser()
        if not key.is_absolute() or not key.is_file():
            return None
        # Validate the credentials locally, without disclosing their contents.
        import jwt
        jwt.encode({"iss": config["team_id"], "iat": int(time.time())}, key.read_text(), algorithm="ES256", headers={"kid": config["key_id"]})
        import h2  # HTTP/2 is required by APNs; report missing server dependency as not ready.
        return config
    except Exception:
        return None


class APNs:
    def __init__(self, config, client):
        self.config, self.client = config, client
        self.token, self.issued = "", 0

    def bearer(self):
        if time.time() - self.issued > 45 * 60:
            import jwt
            self.issued = int(time.time())
            self.token = jwt.encode({"iss": self.config["team_id"], "iat": self.issued},
                                    Path(self.config["key_path"]).expanduser().read_text(), algorithm="ES256",
                                    headers={"kid": self.config["key_id"]})
        return self.token

    async def deliver(self, row):
        host = "api.sandbox.push.apple.com" if row["environment"] == "sandbox" else "api.push.apple.com"
        # Fixed Apple hosts; the client cannot choose an arbitrary destination or topic.
        response = await self.client.post(f'https://{host}/3/device/{row["token"]}',
            headers={"authorization": "bearer " + self.bearer(), "apns-topic": TOPIC,
                     "apns-push-type": "alert", "apns-priority": "10", "apns-id": row["event"],
                     "apns-collapse-id": row["event"], "apns-expiration": str(int(row["created"] + MAX_AGE))},
            json=notification_payload(row))
        result = response.json() if response.content else {}
        if result.get("reason") == "ExpiredProviderToken":
            self.issued = 0
        return response.status_code, result.get("reason", ""), result.get("timestamp")

    async def _post(self, environment, token, headers, payload):
        host = "api.sandbox.push.apple.com" if environment == "sandbox" else "api.push.apple.com"
        response = await self.client.post(f"https://{host}/3/device/{token}",
                                          headers={"authorization": "bearer " + self.bearer(), **headers}, json=payload)
        try:
            result = response.json() if response.content else {}
        except ValueError:
            result = {}
        if not isinstance(result, dict):
            result = {}
        if result.get("reason") == "ExpiredProviderToken":
            self.issued = 0
        return response.status_code, result.get("reason", ""), result.get("timestamp")

    async def deliver_live(self, row):
        """One Live Activity event (`row`: see Store.pending_live, plus `timestamp`). Same client and JWT as alerts."""
        end = row["event"] == "end"
        now = int(time.time())
        return await self._post(row["environment"], row["token"], {
            "apns-topic": TOPIC + LIVE_TOPIC_SUFFIX, "apns-push-type": "liveactivity",
            "apns-priority": "10" if end else "5", "apns-id": str(uuid.uuid4()),
            "apns-expiration": str(now + (LIVE_END_TTL if end else LIVE_UPDATE_TTL))}, live_payload(row))

    async def deliver_background(self, device):
        """Silent push asking the app to refresh its widgets (no alert, no sound)."""
        return await self._post(device["environment"], device["token"], {
            "apns-topic": TOPIC, "apns-push-type": "background", "apns-priority": "5", "apns-id": str(uuid.uuid4()),
            "apns-collapse-id": "hermes-widgets", "apns-expiration": str(int(time.time()) + 3600)}, widgets_payload())


async def deliver_live(store: Store, sender) -> dict:
    """One pass over the Live Activity queue. Timestamps are strictly increasing per activity (Apple drops older ones)."""
    import httpx
    counts = {"sent": 0, "other": 0}
    for row in await asyncio.to_thread(store.pending_live):
        row["timestamp"] = max(int(time.time()), int(row["last_ts"] or 0) + 1)
        try:
            status, reason, _ = await sender.deliver_live(row)
        except (httpx.HTTPError, OSError):
            status, reason = 0, "TransportError"
        await asyncio.to_thread(store.resolve_live, row, status, reason)
        counts["sent" if status == 200 else "other"] += 1
    return counts


async def deliver_widgets(store: Store, sender, minutes) -> dict:
    """Silent widget-refresh pushes, at most one per device every `minutes`; 0 disables. No retry before the next tick."""
    import httpx
    counts = {"sent": 0, "other": 0}
    if not minutes or minutes < 0:
        return counts
    for device in await asyncio.to_thread(store.claim_widget_pushes, minutes * 60):
        try:
            status, reason, timestamp = await sender.deliver_background(device)
        except (httpx.HTTPError, OSError):
            status, reason, timestamp = 0, "TransportError", None
        await asyncio.to_thread(store.resolve_device, device, status, reason, timestamp)
        counts["sent" if status == 200 else "other"] += 1
    return counts


async def deliver_pending(store: Store, sender: APNs) -> dict:
    """One worker pass. Presence is checked per row, immediately before the row would be sent."""
    import httpx
    counts = {"sent": 0, "suppressed": 0, "other": 0}
    for row in await asyncio.to_thread(store.pending):
        if await asyncio.to_thread(store.suppress_if_present, row):
            counts["suppressed"] += 1
            continue
        try:
            status, reason, timestamp = await sender.deliver(row)
        except (httpx.HTTPError, OSError):
            status, reason, timestamp = 0, "TransportError", None
        await asyncio.to_thread(store.resolve, row, status, reason, timestamp)
        counts["sent" if status == 200 else "other"] += 1
    return counts
