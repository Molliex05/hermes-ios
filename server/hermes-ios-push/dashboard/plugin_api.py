"""Mounted by Hermes under its existing dashboard authentication boundary."""
import asyncio
from contextlib import asynccontextmanager
import fcntl
import importlib.util
import logging
from pathlib import Path
import sys
from typing import Literal
from uuid import UUID

import httpx
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

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
                    for row in await asyncio.to_thread(store.pending):
                        try:
                            status, reason, timestamp = await sender.deliver(row)
                        except (httpx.HTTPError, OSError):
                            status, reason, timestamp = 0, "TransportError", None
                        await asyncio.to_thread(store.resolve, row, status, reason, timestamp)
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


class Registration(BaseModel):
    installation_id: UUID
    connection_id: UUID
    token: str = Field(min_length=32, max_length=512, pattern=r"^(?:[a-fA-F0-9]{2})+$")
    environment: Literal["sandbox", "production"]


@router.get("/status")
def status():
    return {"version": 1, "ready": service.load_settings() is not None}


@router.put("/devices")
def register(body: Registration):
    if service.load_settings() is None:
        raise HTTPException(503, "Configurez Apple Push sur le serveur Hermes.")
    service.Store().register(str(body.installation_id).upper(), str(body.connection_id).upper(), body.token.lower(), body.environment)
    return {"registered": True}


@router.delete("/devices/{installation}/{connection}")
def revoke(installation: UUID, connection: UUID):
    service.Store().revoke(str(installation).upper(), str(connection).upper())
    return {"revoked": True}
