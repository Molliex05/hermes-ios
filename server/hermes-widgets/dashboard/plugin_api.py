"""Mounted by Hermes under its existing dashboard authentication boundary. Read-only, except « Vu » (`/board/seen`) and the
app's sending of a Gmail draft Maxime has read (`/drafts/…/send`, see `outbox.py`)."""
import importlib.util
import logging
import os
import re
import sys
from pathlib import Path

from fastapi import APIRouter, Body, HTTPException

_spec = importlib.util.spec_from_file_location("hermes_widgets_snapshot", Path(__file__).resolve().parent.parent / "snapshot.py")
snapshot_module = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = snapshot_module
_spec.loader.exec_module(snapshot_module)
_agenda_spec = importlib.util.spec_from_file_location("hermes_widgets_agenda", Path(__file__).resolve().parent.parent / "agenda.py")
agenda_module = importlib.util.module_from_spec(_agenda_spec)
sys.modules[_agenda_spec.name] = agenda_module
_agenda_spec.loader.exec_module(agenda_module)
_board_spec = importlib.util.spec_from_file_location("hermes_widgets_board", Path(__file__).resolve().parent.parent / "board.py")
board_module = importlib.util.module_from_spec(_board_spec)
sys.modules[_board_spec.name] = board_module
_board_spec.loader.exec_module(board_module)
_blocks_spec = importlib.util.spec_from_file_location("hermes_widgets_blocks", Path(__file__).resolve().parent.parent / "blocks.py")
blocks_module = importlib.util.module_from_spec(_blocks_spec)
sys.modules[_blocks_spec.name] = blocks_module
_blocks_spec.loader.exec_module(blocks_module)
_weather_spec = importlib.util.spec_from_file_location("hermes_widgets_weather", Path(__file__).resolve().parent.parent / "weather.py")
weather_module = importlib.util.module_from_spec(_weather_spec)
sys.modules[_weather_spec.name] = weather_module
_weather_spec.loader.exec_module(weather_module)
_outbox_spec = importlib.util.spec_from_file_location("hermes_widgets_outbox", Path(__file__).resolve().parent.parent / "outbox.py")
outbox_module = importlib.util.module_from_spec(_outbox_spec)
sys.modules[_outbox_spec.name] = outbox_module
_outbox_spec.loader.exec_module(outbox_module)
_noriven_spec = importlib.util.spec_from_file_location("hermes_widgets_noriven_outbox", Path(__file__).resolve().parent.parent / "noriven_outbox.py")
noriven_outbox = importlib.util.module_from_spec(_noriven_spec)
sys.modules[_noriven_spec.name] = noriven_outbox
_noriven_spec.loader.exec_module(noriven_outbox)
log = logging.getLogger("hermes_widgets")

router = APIRouter()


@router.get("/status")
def status():
    return {"version": 1, "ready": bool(snapshot_module._token())}


@router.get("/snapshot")
async def get_snapshot():
    try:
        return await snapshot_module.snapshot()
    except Exception as error:      # never forward upstream text
        log.warning("Widget snapshot unavailable (%s)", type(error).__name__)
        raise HTTPException(503, "Les chiffres Noriven sont momentanément indisponibles.") from None


@router.get("/board")
def get_board():
    """Every agent's « À l'affiche » board (written by the agents themselves) and, for profiles with Google, the next events
    straight from the calendar, the weather of the place, and the blocks each agent composed the widget with, for the iPhone
    widget. A plain `def`: the Google and weather calls block, FastAPI runs it in a thread."""
    return blocks_module.with_blocks(weather_module.with_weather(board_module.with_agendas(board_module.load_all(), source=agenda_module.upcoming)))


def _google_profile(profile: str) -> Path:
    root = Path(os.environ.get("HERMES_PROFILES_DIR", "/opt/data/profiles"))
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", profile or "") or not (root / profile).is_dir():
        raise HTTPException(404, "Profil inconnu.")
    if not agenda_module.has_google(root, profile):
        raise HTTPException(404, "Google n'est pas configuré pour ce profil.")
    return root


def _noriven_profile(profile: str):
    """The profile's Noriven relay settings (address and relay token), read from its `.env` at each call."""
    root = Path(os.environ.get("HERMES_PROFILES_DIR", "/opt/data/profiles"))
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", profile or "") or not (root / profile).is_dir():
        raise HTTPException(404, "Profil inconnu.")
    env = agenda_module.read_env(root, profile, noriven_outbox.KEYS)
    if not noriven_outbox.configured(env):
        raise HTTPException(404, "L'envoi Noriven n'est pas configuré pour ce profil.")
    return root, env


@router.get("/drafts/{profile}/{draft_id}")
def draft_read(profile: str, draft_id: str):
    """A draft as its mailbox holds it (Gmail, or Noriven's Polaris boxes for an `m1.` id), for the app to show before
    Maxime sends it."""
    if noriven_outbox.is_noriven(draft_id):
        _, env = _noriven_profile(profile)
        try:
            return noriven_outbox.read(env, draft_id)
        except noriven_outbox.OutboxError as error:
            raise HTTPException(error.status, str(error)) from None
        except Exception as error:
            log.warning("Noriven draft read failed (%s)", type(error).__name__)
            raise HTTPException(502, "Le brouillon n'a pas pu être lu.") from None
    root = _google_profile(profile)
    try:
        return outbox_module.read(agenda_module._google(root, profile), draft_id)
    except outbox_module.OutboxError as error:
        raise HTTPException(error.status, str(error)) from None
    except Exception as error:
        log.warning("Draft read failed (%s)", type(error).__name__)
        raise HTTPException(502, "Le brouillon n'a pas pu être lu.") from None


@router.post("/drafts/{profile}/{draft_id}/send")
def draft_send(profile: str, draft_id: str, payload: dict = Body(...)):
    """Maxime sends a draft from the app (after Face ID): only if it is still exactly what he read. A Noriven draft also
    needs the approval the iPhone signed."""
    if noriven_outbox.is_noriven(draft_id):
        root, env = _noriven_profile(profile)
        try:
            return noriven_outbox.send(env, draft_id, str((payload or {}).get("fingerprint") or ""), (payload or {}).get("approval"), root / profile)
        except noriven_outbox.OutboxError as error:
            raise HTTPException(error.status, str(error)) from None
        except Exception as error:
            log.warning("Noriven draft send failed (%s)", type(error).__name__)
            raise HTTPException(502, "L'envoi a échoué ; vérifie dans Envoyés avant de réessayer.") from None
    root = _google_profile(profile)
    try:
        return outbox_module.send(agenda_module._google(root, profile), draft_id, str((payload or {}).get("fingerprint") or ""), root / profile)
    except outbox_module.OutboxError as error:
        raise HTTPException(error.status, str(error)) from None
    except Exception as error:
        log.warning("Draft send failed (%s)", type(error).__name__)
        raise HTTPException(502, "L'envoi a échoué ; vérifie dans Gmail avant de réessayer.") from None


@router.post("/board/seen")
def board_seen(payload: dict = Body(...)):
    """« Vu » on the widget: these lines leave the agent's board, and the emails they were about are queued for the agent's
    email watcher to archive. Only an existing profile; only texts are taken from the phone, the email ids come from the
    board the agent wrote."""
    profile = str((payload or {}).get("profile") or "")
    root = Path(os.environ.get("HERMES_PROFILES_DIR", "/opt/data/profiles"))
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", profile) or not (root / profile).is_dir():
        raise HTTPException(404, "Profil inconnu.")
    try:
        return {"ok": True, **board_module.mark_seen(root / profile, payload.get("lines"), payload.get("focus"))}
    except Exception as error:      # never forward the arguments
        log.warning("Widget seen mark failed (%s)", type(error).__name__)
        raise HTTPException(500, "Le tableau n'a pas pu être mis à jour.") from None
