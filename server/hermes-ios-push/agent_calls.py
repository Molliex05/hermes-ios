"""Calls an agent places to Maxime's iPhone: the agent plans one (`appel_planifier`, e.g. halfway through the drive to a
shift), and at that moment the push worker rings the iPhone with a VoIP push that CallKit shows as « Jarvis ».

Nothing runs in between: the worker keeps the time of the next planned call and only looks at the table when that time
comes or when a plan changes (`calls.stamp`). The VoIP push carries the call's id, profile and agent name only; the reason
and the script are read by the app over the authenticated dashboard API while it rings (pushes cross Apple unencrypted).

Prepared before ringing: a one-shot Hermes cron job (`prep_jobs`) runs the agent PREP_LEAD before the call; it gathers the
topo and stores what it will say with `appel_preparer` (`script`). Answered, the iPhone says it at once: the agent never
makes Maxime wait while it looks things up. Without a script, the agent speaks first as before.

Guards live here, not in the prompt: at most CALLS_PER_DAY per profile and local day, never in quiet hours, within
MAX_AHEAD, one call per `key` (planning the same key again moves it).
"""
from __future__ import annotations

import json
import os
import re
import secrets
import time
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

TIMEZONE = ZoneInfo(os.environ.get("HERMES_CALLS_TIMEZONE", "America/Toronto"))
CALLS_PER_DAY = 3
QUIET_FROM, QUIET_UNTIL = 23, 5          # local hours: no call from 23:00 to 04:59
MIN_AHEAD, MAX_AHEAD = 60, 36 * 3600      # seconds
LATE = 10 * 60                            # a call more than 10 min late (server down at its time) is dropped, not rung
RING_TTL = 60                             # apns-expiration: an undelivered ring is worthless after a minute
IDLE_RECHECK = 600                        # without a planned call, look again at least every 10 min
VOIP_TOPIC_SUFFIX = ".voip"
REASON_CHARS, KEY_CHARS, SCRIPT_CHARS = 140, 60, 1200
PREP_LEAD = 20 * 60                       # the agent prepares 20 min before: before Maxime leaves, so a car claim has it too
OUTCOMES = {"ringing", "answered", "missed", "declined"}
ID = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
KEY = re.compile(r"^[A-Za-z0-9_.:-]{1,60}$")

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS calls (
    id TEXT PRIMARY KEY, profile TEXT NOT NULL, agent TEXT NOT NULL, at REAL NOT NULL, reason TEXT NOT NULL,
    key TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'planned', outcome TEXT, created REAL NOT NULL, sent REAL);
CREATE INDEX IF NOT EXISTS calls_due ON calls(state, at);
"""
ADDED_COLUMNS = (("script", "TEXT"), ("prep_job", "TEXT"))


class CallRefused(ValueError):
    """A plan the guards refuse; the message is for the agent."""


def ensure(db) -> None:
    db.executescript(SCHEMA_SQL)
    present = {row[1] for row in db.execute("PRAGMA table_info(calls)")}
    for name, kind in ADDED_COLUMNS:
        if name not in present:
            db.execute(f"ALTER TABLE calls ADD COLUMN {name} {kind}")


def stamp(home: Path) -> Path:
    return Path(home) / "calls.stamp"


def _touch(home: Path) -> None:
    path = stamp(home)
    path.touch(exist_ok=True)
    os.utime(path, None)


def _clean(text, limit: int) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[\x00-\x1f\x7f]", " ", str(text or ""))).strip()[:limit]


def parse_when(value, now: datetime) -> datetime:
    """« 2026-11-23T14:00 » (local time) or with an offset; « +45m » / « +2h » from now."""
    text = str(value or "").strip()
    relative = re.fullmatch(r"\+(\d{1,4})\s*(m|min|h)", text)
    if relative:
        amount = int(relative.group(1))
        return now + (timedelta(hours=amount) if relative.group(2) == "h" else timedelta(minutes=amount))
    try:
        when = datetime.fromisoformat(text)
    except ValueError:
        raise CallRefused("`quand` doit être une heure ISO (« 2026-11-23T13:30 », heure de Montréal) ou « +45m ».") from None
    return when.replace(tzinfo=TIMEZONE) if when.tzinfo is None else when


def plan(store, profile: str, agent: str, when, reason, key=None, now: datetime | None = None) -> dict:
    now = now or datetime.now(TIMEZONE)
    at = parse_when(when, now).astimezone(TIMEZONE)
    reason = _clean(reason, REASON_CHARS)
    if not reason:
        raise CallRefused("`raison` est requise : en une phrase, pourquoi tu appelles (« trajet vers ton quart de 14 h 30 »).")
    key = _clean(key, KEY_CHARS) or f"{at:%Y-%m-%dT%H:%M}"
    if not KEY.fullmatch(key):
        raise CallRefused("`cle` : lettres, chiffres, point, tiret ou deux-points seulement.")
    ahead = (at - now).total_seconds()
    if ahead < MIN_AHEAD:
        raise CallRefused("L'heure est passée ou trop proche : au moins une minute d'avance.")
    if ahead > MAX_AHEAD:
        raise CallRefused("Trop loin : planifie au plus 36 heures à l'avance (ton plan du matin s'en chargera).")
    if at.hour >= QUIET_FROM or at.hour < QUIET_UNTIL:
        raise CallRefused(f"Jamais d'appel entre {QUIET_FROM} h et {QUIET_UNTIL} h.")
    day_start = at.replace(hour=0, minute=0, second=0, microsecond=0)
    with store.connect(immediate=True) as db:
        ensure(db)
        same = db.execute("SELECT id FROM calls WHERE profile=? AND key=? AND state='planned'", (profile, key)).fetchone()
        count = db.execute("SELECT COUNT(*) FROM calls WHERE profile=? AND at>=? AND at<? AND state!='cancelled' AND key!=?",
                           (profile, day_start.timestamp(), (day_start + timedelta(days=1)).timestamp(), key)).fetchone()[0]
        if count >= CALLS_PER_DAY:
            raise CallRefused(f"Au plus {CALLS_PER_DAY} appels par jour : annule-en un d'abord (`appel_annuler`).")
        call_id = same["id"] if same else secrets.token_urlsafe(12)
        db.execute("INSERT INTO calls(id,profile,agent,at,reason,key,state,created) VALUES (?,?,?,?,?,?,'planned',?) "
                   "ON CONFLICT(id) DO UPDATE SET at=excluded.at, reason=excluded.reason, agent=excluded.agent, "
                   "script=CASE WHEN calls.at=excluded.at THEN calls.script END",
                   (call_id, profile, _clean(agent, 40) or profile, at.timestamp(), reason, key, time.time()))
    _touch(store.home)
    return {"id": call_id, "cle": key, "quand": at.isoformat(timespec="minutes"), "deplace": bool(same), "at": at.timestamp()}


def prepare(store, profile: str, ref, script) -> dict:
    """What the agent will say the moment Maxime answers, stored on its planned call (by `id` or `cle`)."""
    ref = _clean(ref, KEY_CHARS)
    script = re.sub(r"[ \t]+", " ", re.sub(r"[\x00-\x09\x0b-\x1f\x7f]", " ", str(script or ""))).strip()[:SCRIPT_CHARS]
    if not script:
        raise CallRefused("`texte` est requis : ce que tu diras dès qu'il décroche.")
    with store.connect(immediate=True) as db:
        ensure(db)
        row = db.execute("SELECT id,at FROM calls WHERE profile=? AND state='planned' AND (id=? OR key=?) ORDER BY at LIMIT 1",
                         (profile, ref, ref)).fetchone()
        if not row:
            raise CallRefused("Aucun appel prévu avec cet `id` ou cette `cle` (déjà sonné ou annulé).")
        db.execute("UPDATE calls SET script=? WHERE id=?", (script, row["id"]))
    return {"id": row["id"], "quand": datetime.fromtimestamp(row["at"], TIMEZONE).isoformat(timespec="minutes")}


def set_prep_job(store, call_id: str, job_id) -> str | None:
    """Records the call's preparation job; returns the one it replaces (to remove)."""
    with store.connect(immediate=True) as db:
        ensure(db)
        row = db.execute("SELECT prep_job FROM calls WHERE id=?", (call_id,)).fetchone()
        db.execute("UPDATE calls SET prep_job=? WHERE id=?", (job_id, call_id))
    return row["prep_job"] if row else None


def cancel(store, profile: str, ref, jobs: list | None = None) -> int:
    """Cancels the planned call; its preparation jobs are added to `jobs` for the caller to remove."""
    ref = _clean(ref, KEY_CHARS)
    with store.connect(immediate=True) as db:
        ensure(db)
        if jobs is not None:
            jobs.extend(r["prep_job"] for r in db.execute("SELECT prep_job FROM calls WHERE profile=? AND state='planned' AND "
                                                          "(id=? OR key=?) AND prep_job IS NOT NULL", (profile, ref, ref)))
        changed = db.execute("UPDATE calls SET state='cancelled' WHERE profile=? AND state='planned' AND (id=? OR key=?)",
                             (profile, ref, ref)).rowcount
    if changed:
        _touch(store.home)
    return changed


def upcoming(store, profile: str, now: float | None = None) -> list:
    now = now or time.time()
    with store.connect() as db:
        ensure(db)
        rows = db.execute("SELECT id,key,at,reason,script FROM calls WHERE profile=? AND state='planned' AND at>? ORDER BY at",
                          (profile, now)).fetchall()
    return [{"id": r["id"], "cle": r["key"], "quand": datetime.fromtimestamp(r["at"], TIMEZONE).isoformat(timespec="minutes"),
             "raison": r["reason"], "prepare": bool(r["script"])} for r in rows]


def get(store, call_id: str) -> dict | None:
    if not ID.fullmatch(call_id or ""):
        return None
    with store.connect() as db:
        ensure(db)
        row = db.execute("SELECT id,profile,agent,at,reason,state,outcome,script FROM calls WHERE id=?", (call_id,)).fetchone()
    return dict(row) if row else None


def record_outcome(store, call_id: str, outcome: str) -> bool:
    if outcome not in OUTCOMES or not ID.fullmatch(call_id or ""):
        return False
    with store.connect() as db:
        ensure(db)
        # « answered » is never overwritten by a late « missed » from another path.
        return db.execute("UPDATE calls SET outcome=? WHERE id=? AND state='sent' AND COALESCE(outcome,'')!='answered'",
                          (outcome, call_id)).rowcount > 0


def claim_due(store, now: float | None = None) -> list:
    """Planned calls whose time has come, marked sent at once (a second worker pass never rings twice). Too late: dropped."""
    now = now or time.time()
    with store.connect(immediate=True) as db:
        ensure(db)
        db.execute("UPDATE calls SET state='expired' WHERE state='planned' AND at<?", (now - LATE,))
        rows = [dict(r) for r in db.execute("SELECT id,profile,agent FROM calls WHERE state='planned' AND at<=?", (now,))]
        for row in rows:
            db.execute("UPDATE calls SET state='sent', sent=? WHERE id=?", (now, row["id"]))
    return rows


CLAIM_WINDOW = 90 * 60     # the iPhone connected to the car this long before a planned call takes it now


def claim_now(store, within: float = CLAIM_WINDOW, now: float | None = None) -> dict | None:
    """The iPhone reached the car (CarPlay) before a planned call: the next one within `within` seconds rings now, from the
    iPhone, and is marked sent so the worker never rings it again (one briefing per trip). None when nothing is planned."""
    now = now or time.time()
    within = min(max(float(within), 0), CLAIM_WINDOW)
    with store.connect(immediate=True) as db:
        ensure(db)
        row = db.execute("SELECT id,profile,agent,reason,script FROM calls WHERE state='planned' AND at>=? AND at<=? ORDER BY at LIMIT 1",
                         (now - LATE, now + within)).fetchone()
        if not row:
            return None
        db.execute("UPDATE calls SET state='sent', sent=? WHERE id=?", (now, row["id"]))
    _touch(store.home)
    return dict(row)


def next_at(store) -> float | None:
    with store.connect() as db:
        ensure(db)
        row = db.execute("SELECT MIN(at) FROM calls WHERE state='planned'").fetchone()
    return row[0] if row and row[0] is not None else None


def voip_devices(store) -> list:
    with store.connect() as db:
        return [dict(r) for r in db.execute("SELECT d.installation,d.connection,v.token,d.environment FROM devices d "
                                            "JOIN device_voip v USING(installation,connection)")]


def payload(call: dict) -> dict:
    return {"hermes": {"kind": "call", "call": call["id"], "profile": call["profile"], "agent": call["agent"]}}


class Timer:
    """When the worker next needs to look: the next planned call, or a change of plan (the stamp file's time)."""

    def __init__(self):
        self.check_at, self.seen = 0.0, None

    def due(self, store, now: float) -> bool:
        try:
            mtime = stamp(store.home).stat().st_mtime
        except OSError:
            mtime = None
        if mtime != self.seen:
            self.seen = mtime
            return True
        return now >= self.check_at

    def reset(self, store, now: float) -> None:
        upcoming_at = next_at(store)
        self.check_at = min(upcoming_at, now + IDLE_RECHECK) if upcoming_at else now + IDLE_RECHECK


async def deliver(store, sender, timer: Timer, now: float | None = None) -> dict:
    """One worker pass: rings every device registered for VoIP for each call that is due. Nothing at all between calls."""
    now = now or time.time()
    counts = {"rung": 0, "other": 0}
    if not timer.due(store, now):
        return counts
    calls = claim_due(store, now)
    for call in calls:
        for device in voip_devices(store):
            status, _, _ = await sender.deliver_voip(device, payload(call))
            counts["rung" if status == 200 else "other"] += 1
    timer.reset(store, now)
    return counts
