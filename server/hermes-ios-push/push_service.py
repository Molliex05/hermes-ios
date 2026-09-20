"""Durable APNs outbox; Hermes remains the only owner of conversation execution.

Uses the documented post_llm_call hook and read-only SessionDB API. No WebSocket
attachment, polling of transcripts, second agent, or changes to Hermes sources.
"""
from __future__ import annotations

from contextlib import contextmanager
import hashlib
import json
import logging
import os
from pathlib import Path
import sqlite3
import time
import uuid

log = logging.getLogger("hermes_ios_push")
TOPIC = "org.hermesios.HermesIOS"
MAX_AGE = 24 * 60 * 60


def data_home() -> Path:
    from hermes_constants import get_default_hermes_root
    return Path(os.environ.get("HERMES_IOS_PUSH_HOME") or get_default_hermes_root() / "ios-push")


class Store:
    def __init__(self, home: Path | None = None):
        self.home = home or data_home()
        self.home.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.home / "notifications.sqlite"
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
            """)
        self.path.chmod(0o600)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=3)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def register(self, installation, connection, token, environment):
        with self.connect() as db:
            db.execute("INSERT INTO devices VALUES (?,?,?,?,?) ON CONFLICT(installation,connection) "
                       "DO UPDATE SET token=excluded.token,environment=excluded.environment,registered=excluded.registered",
                       (installation, connection, token, environment, time.time()))

    def revoke(self, installation, connection):
        with self.connect() as db:
            db.execute("DELETE FROM devices WHERE installation=? AND connection=?", (installation, connection))
            db.execute("DELETE FROM outbox WHERE installation=? AND connection=?", (installation, connection))

    def enqueue(self, event, profile, session):
        now = time.time()
        with self.connect() as db:
            db.execute("INSERT OR IGNORE INTO outbox(event,installation,connection,profile,session,created) "
                       "SELECT ?,installation,connection,?,?,? FROM devices", (event, profile, session, now))
            db.execute("DELETE FROM outbox WHERE created < ?", (now - MAX_AGE,))

    def pending(self):
        now = time.time()
        with self.connect() as db:
            db.execute("DELETE FROM outbox WHERE created < ?", (now - MAX_AGE,))
            return [dict(row) for row in db.execute(
                "SELECT o.*,d.token,d.environment FROM outbox o JOIN devices d USING(installation,connection) "
                "WHERE o.state='pending' AND o.next_attempt <= ? AND o.created >= ? ORDER BY o.created LIMIT 50",
                (now, now - MAX_AGE))]

    def resolve(self, row, status, reason="", invalidated_at=None):
        identity = (row["event"], row["installation"], row["connection"])
        with self.connect() as db:
            if status == 410 or status == 400 and reason in {"BadDeviceToken", "DeviceTokenNotForTopic"}:
                # A delayed 410 for an older registration must not remove a refreshed token.
                cutoff = invalidated_at / 1000 if invalidated_at else time.time()
                db.execute("DELETE FROM devices WHERE installation=? AND connection=? AND token=? AND registered<=?",
                           (row["installation"], row["connection"], row["token"], cutoff))
            if status == 200:
                state, next_attempt = "sent", 0
            elif status in {0, 403, 429, 500, 503}:
                state = "pending"
                next_attempt = time.time() + min(3600, 5 * 2 ** min(row["attempts"], 10))
            else:
                state, next_attempt = "failed", 0
            db.execute("UPDATE outbox SET state=?,reason=?,attempts=attempts+1,next_attempt=? "
                       "WHERE event=? AND installation=? AND connection=?",
                       (state, reason[:100], next_attempt, *identity))


def record_completion(*, session_id="", assistant_response="", platform="", turn_id="", **kwargs):
    # Cron execution is internal. Its native bot-chat delivery starts a real turn
    # in the destination conversation; that turn produces the single notification.
    if platform == "cron" or not session_id or not assistant_response or not turn_id:
        return
    from hermes_constants import get_hermes_home, profile_name_for_home
    from hermes_state import SessionDB
    home = get_hermes_home()
    profile = profile_name_for_home(home)
    if not profile:
        return
    db = SessionDB(home / "state.db", read_only=True)
    try:
        session = db.get_session(session_id)
    finally:
        db.close()
    if not session or session.get("source") not in {"cli", "desktop", "tui", "web"}:
        return
    event = str(uuid.uuid5(uuid.NAMESPACE_URL, f"hermes-ios:{profile}:{session_id}:{turn_id}"))
    Store().enqueue(event, profile, session_id)


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


def notification_payload(row):
    thread = hashlib.sha256(f'{row["connection"]}:{row["profile"]}:{row["session"]}'.encode()).hexdigest()
    return {
        "aps": {"alert": {"title": "Hermès", "body": "Un nouveau message vous attend."},
                "sound": "default", "thread-id": thread},
        "hermes": {"version": 1, "connection_id": row["connection"], "profile": row["profile"],
                   "session_id": row["session"], "event_id": row["event"]},
    }


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
