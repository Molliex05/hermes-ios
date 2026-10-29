"""Mounted by Hermes under its existing dashboard authentication boundary. Read-only."""
import importlib.util
import logging
import sys
from pathlib import Path

from fastapi import APIRouter, HTTPException

_spec = importlib.util.spec_from_file_location("hermes_widgets_snapshot", Path(__file__).resolve().parent.parent / "snapshot.py")
snapshot_module = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = snapshot_module
_spec.loader.exec_module(snapshot_module)
_board_spec = importlib.util.spec_from_file_location("hermes_widgets_board", Path(__file__).resolve().parent.parent / "board.py")
board_module = importlib.util.module_from_spec(_board_spec)
sys.modules[_board_spec.name] = board_module
_board_spec.loader.exec_module(board_module)
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
    """Every agent's « À l'affiche » board (written by the agents themselves), for the iPhone widget."""
    return board_module.load_all()
