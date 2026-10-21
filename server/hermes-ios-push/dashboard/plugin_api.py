"""Mounted by Hermes under its existing dashboard authentication boundary."""
import asyncio
from contextlib import asynccontextmanager
import fcntl
import importlib.util
import logging
from pathlib import Path
import sys
from typing import Literal, Optional
from uuid import UUID

import httpx
from fastapi import APIRouter, HTTPException, Path as PathParam, Query, Request
from pydantic import BaseModel, ConfigDict, Field, ValidationError

# Dashboard APIs are loaded by filename, outside the CLI plugin's namespace.
_spec = importlib.util.spec_from_file_location("hermes_ios_push_service", Path(__file__).resolve().parent.parent / "push_service.py")
service = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = service
_spec.loader.exec_module(service)
log = logging.getLogger("hermes_ios_push")


async def worker():
    store = service.Store()
    # Several native Hermes surfaces can host the same plugin. Only one delivers
    # each shared outbox; a replacement process takes over when its owner exits.
    with (store.home / "worker.lock").open("a") as lock:
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                await asyncio.sleep(5)
        async with httpx.AsyncClient(http2=True, timeout=20, follow_redirects=False) as client:
            config, sender = None, None
            while True:
                from hermes_cli.config import load_config
                config_state = await asyncio.to_thread(load_config)
                plugins = config_state.get("plugins", {})
                enabled = "hermes-ios-push" in plugins.get("enabled", []) and "hermes-ios-push" not in plugins.get("disabled", [])
                settings = await asyncio.to_thread(service.load_settings) if enabled else None
                if settings:
                    if settings != config:
                        config, sender = settings, service.APNs(settings, client)
                    # Alerts, Live Activity events and widget refreshes are independent: one failing kind must not
                    # starve the others (the supervisor would otherwise retry the whole pass from the start).
                    for name, step in (("alerts", lambda: service.deliver_pending(store, sender)),
                                       ("live", lambda: service.deliver_live(store, sender)),
                                       ("widgets", lambda: service.deliver_widgets(store, sender, service.widgets_refresh_minutes(settings)))):
                        try:
                            await step()
                        except asyncio.CancelledError:
                            raise
                        except Exception as error:
                            log.warning("Push worker step %s failed (%s)", name, type(error).__name__)
                await asyncio.sleep(3)


async def supervised_worker():
    while True:
        try:
            await worker()
        except asyncio.CancelledError:
            raise
        except Exception as error:
            # Do not log tokens, credentials, notification bodies or HTTP requests.
            log.warning("Push worker will retry after %s", type(error).__name__)
            await asyncio.sleep(5)


@asynccontextmanager
async def lifespan(app):
    task = asyncio.create_task(supervised_worker())
    try:
        yield
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass


router = APIRouter(lifespan=lifespan)


SAFE_NAME = r"^[A-Za-z0-9._@:-]{1,200}$"


class Registration(BaseModel):
    # hide_input_in_errors: a 422 must never echo the request body (it carries the key).
    model_config = ConfigDict(hide_input_in_errors=True)
    installation_id: UUID
    connection_id: UUID
    token: str = Field(min_length=32, max_length=512, pattern=r"^(?:[a-fA-F0-9]{2})+$")
    environment: Literal["sandbox", "production"]
    key: Optional[str] = None      # base64, 32 bytes; validated in the handler so errors never repeat it


class ActivityRegistration(BaseModel):
    # hide_input_in_errors: a 422 must never echo the request body (it carries the Live Activity push token).
    model_config = ConfigDict(hide_input_in_errors=True)
    installation_id: UUID
    connection_id: UUID
    profile: str = Field(pattern=SAFE_NAME)
    session_id: str = Field(pattern=SAFE_NAME)
    activity_id: str = Field(min_length=1, max_length=100, pattern=SAFE_NAME)
    token: str = Field(min_length=32, max_length=512, pattern=r"^(?:[a-fA-F0-9]{2})+$")
    environment: Literal["sandbox", "production"]
    kind: Literal["reply", "call"]
    started_at: float = Field(strict=True, gt=0, lt=4102444800, allow_inf_nan=False)      # seconds since 1970


class PresenceKey(BaseModel):
    model_config = ConfigDict(hide_input_in_errors=True)
    installation_id: UUID
    connection_id: UUID
    profile: str = Field(pattern=SAFE_NAME)
    session_id: str = Field(pattern=SAFE_NAME)


class Presence(PresenceKey):
    ttl: int = Field(strict=True)      # clamped to 5...120 seconds by the store


@router.get("/status")
def status():
    return {"version": 1, "ready": service.load_settings() is not None}


def _validated(model, raw):
    """Validate by hand: FastAPI's own 422 body repeats the request (and so the key) in `input`."""
    try:
        return model.model_validate(raw)
    except ValidationError as error:
        raise HTTPException(422, [{"loc": [str(p) for p in e["loc"]], "msg": e["msg"]} for e in error.errors(include_input=False, include_url=False)]) from None


@router.put("/devices")
async def register(request: Request):
    try:
        raw = await request.json()
    except ValueError:
        raise HTTPException(422, "Corps JSON invalide.") from None
    body = _validated(Registration, raw)
    key = None
    if body.key is not None:
        try:
            key = service.decode_key(body.key)
        except ValueError:
            raise HTTPException(422, "Clé de chiffrement invalide (base64 de 32 octets attendu).") from None
    if await asyncio.to_thread(service.load_settings) is None:
        raise HTTPException(503, "Configurez Apple Push sur le serveur Hermes.")
    # No key (HTTP connection judged unsafe by the app, or older app): the previous key is cleared and the
    # generic v0.1 notification is used.
    await asyncio.to_thread(service.Store().register, str(body.installation_id).upper(), str(body.connection_id).upper(),
                            body.token.lower(), body.environment, key)
    return {"registered": True}


@router.delete("/devices/{installation}/{connection}")
def revoke(installation: UUID, connection: UUID):
    service.Store().revoke(str(installation).upper(), str(connection).upper())
    return {"revoked": True}


@router.put("/activities")
async def register_activity(request: Request):
    try:
        raw = await request.json()
    except ValueError:
        raise HTTPException(422, "Corps JSON invalide.") from None
    body = _validated(ActivityRegistration, raw)
    if await asyncio.to_thread(service.load_settings) is None:
        raise HTTPException(503, "Configurez Apple Push sur le serveur Hermes.")
    expires = await asyncio.to_thread(
        service.Store().put_activity, str(body.installation_id).upper(), str(body.connection_id).upper(), body.profile,
        body.session_id, body.activity_id, body.token.lower(), body.environment, body.kind, body.started_at)
    return {"registered": True, "expires_at": int(expires)}


@router.delete("/activities/{installation}/{activity_id}")
def delete_activity(installation: UUID, activity_id: str = PathParam(min_length=1, max_length=100, pattern=SAFE_NAME)):
    service.Store().delete_activity(str(installation).upper(), activity_id)
    return {"revoked": True}


@router.put("/presence")
def put_presence(body: Presence):
    service.Store().set_presence(str(body.installation_id).upper(), str(body.connection_id).upper(), body.profile, body.session_id, body.ttl)
    return {"ok": True}


@router.delete("/presence")
def delete_presence(body: Optional[PresenceKey] = None,
                    installation_id: Optional[UUID] = Query(None), connection_id: Optional[UUID] = Query(None),
                    profile: Optional[str] = Query(None, pattern=SAFE_NAME), session_id: Optional[str] = Query(None, pattern=SAFE_NAME)):
    """Same fields as PUT, in the JSON body or in the query string."""
    if body is None:
        if None in (installation_id, connection_id, profile, session_id):
            raise HTTPException(422, "installation_id, connection_id, profile et session_id sont requis.")
        body = PresenceKey(installation_id=installation_id, connection_id=connection_id, profile=profile, session_id=session_id)
    service.Store().clear_presence(str(body.installation_id).upper(), str(body.connection_id).upper(), body.profile, body.session_id)
    return {"ok": True}
