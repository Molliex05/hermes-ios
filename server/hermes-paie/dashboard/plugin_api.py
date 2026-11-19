"""Mounted by Hermes under its existing dashboard authentication boundary. Read-only: the PDF of one payslip, by profile and
pay date, for the app's « paie » card. The profile's copy is used when Jarvis already read it; otherwise the Mac mini gives it
(token from the profile's own .env). No path ever comes from the request: a profile name and a date, both checked."""
import base64
import datetime as dt
import importlib.util
import logging
import os
import re
import sys
from pathlib import Path

from fastapi import APIRouter, HTTPException

_spec = importlib.util.spec_from_file_location("hermes_paie_tools", Path(__file__).resolve().parent.parent / "__init__.py")
paie = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = paie
_spec.loader.exec_module(paie)
log = logging.getLogger("hermes_paie")
router = APIRouter()
KEYS = ("HERMES_PAIE_TOKEN", "HERMES_PAIE_URL")


def _env(root: Path, profile: str) -> dict:
    values = {}
    try:
        lines = (root / profile / ".env").read_text(encoding="utf-8").splitlines()
    except OSError:
        return values
    for line in lines:
        line = line.strip()
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" in line and not line.startswith("#"):
            key, value = (part.strip() for part in line.split("=", 1))
            if key in KEYS:
                values[key] = value.strip("'\"")
    return values


@router.get("/talon/{profile}/{pay_date}")
def payslip(profile: str, pay_date: str):
    root = Path(os.environ.get("HERMES_PROFILES_DIR", "/opt/data/profiles"))
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", profile or "") or not (root / profile).is_dir():
        raise HTTPException(404, "Profil inconnu.")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", pay_date or ""):
        raise HTTPException(400, "Date invalide.")
    try:
        day = dt.date.fromisoformat(pay_date)
    except ValueError:
        raise HTTPException(400, "Date invalide.") from None
    env = _env(root, profile)
    if not env.get("HERMES_PAIE_TOKEN") and not (root / profile / "paie").is_dir():
        raise HTTPException(404, "La paie n'est pas configurée pour ce profil.")
    try:
        path = paie.fetch_pdf(day, env.get("HERMES_PAIE_URL") or paie.DEFAULT_URL, env.get("HERMES_PAIE_TOKEN", ""), root / profile / "paie")
    except RuntimeError as error:
        raise HTTPException(502, str(error)) from None
    except Exception as error:
        log.warning("Payslip PDF unavailable (%s)", type(error).__name__)
        raise HTTPException(502, "Le talon n'a pas pu être obtenu.") from None
    return {"date": day.isoformat(), "pdf": base64.b64encode(path.read_bytes()).decode("ascii")}
