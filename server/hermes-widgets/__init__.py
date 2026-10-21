"""Dashboard API (`dashboard/plugin_api.py`) for the iOS widgets, and one agent tool: `noriven_chiffres`."""
import asyncio
import json
from concurrent.futures import ThreadPoolExecutor
from importlib import util as _util
from pathlib import Path

TOOLSET = "noriven_chiffres"
BLOCKED_PLATFORMS = {"api_server"}

DESCRIPTION = (
    "Donne les chiffres de Noriven en UN seul appel : revenu (estimé et confirmé), dépenses, profit, MRR et projection du mois, "
    "ou le cumul depuis le début de l'année (periode=\"annee\"). Montants en dollars canadiens. "
    "Le revenu estimé vient des paiements Glutax ; le confirmé, des versements réellement reçus."
)

SCHEMA = {
    "name": "noriven_chiffres",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {"periode": {"type": "string", "enum": ["mois", "annee"], "default": "mois",
                                   "description": "« mois » : le mois en cours et le précédent ; « annee » : depuis le 1er janvier."}},
        "additionalProperties": False,
    },
}


def _snapshot_module():
    spec = _util.spec_from_file_location("hermes_widgets_snapshot_tool", Path(__file__).resolve().parent / "snapshot.py")
    module = _util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _run(coro):
    # Tool handlers may run inside an event loop: use a private one on a worker thread.
    with ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(asyncio.run, coro).result(timeout=40)


def handle(args, **kwargs) -> str:
    try:
        try:
            from gateway.session_context import get_session_env
            if (get_session_env("HERMES_SESSION_PLATFORM", "") or "") in BLOCKED_PLATFORMS:
                return json.dumps({"error": "Outil indisponible sur cette plateforme."}, ensure_ascii=False)
        except Exception:
            pass
        module = _snapshot_module()
        if (args or {}).get("periode") == "annee":
            return json.dumps({"devise": "CAD", **_run(module.year_to_date())}, ensure_ascii=False)
        snap = _run(module.fetch(module.mcp_call))
        finance, mrr, projection = snap["finance"], snap.get("mrr"), snap.get("projection")
        out = {"devise": "CAD", "environnement": snap.get("data_environment"), "mois": finance["label"],
               "ce_mois": {"revenu_estime": finance["current"]["estimated_revenue"], "revenu_confirme": finance["current"]["confirmed_revenue"],
                           "depenses": finance["current"]["expenses"], "profit_estime": finance["current"]["estimated_profit"]},
               "mois_precedent": {"mois": finance["previous"]["month"], "revenu_estime": finance["previous"]["estimated_revenue"],
                                  "depenses": finance["previous"]["expenses"], "profit_estime": finance["previous"]["estimated_profit"]},
               "note": "Le mois en cours n'est pas terminé."}
        if mrr:
            out["mrr"] = {"valeur": mrr["value"], "abonnes_actifs": mrr["active_subscriptions"], "photo_du": mrr["snapshot_date"]}
        if projection:
            out["projection"] = {"mois": projection["month_total"], "mois_suivant": projection["next_month_total"], "douze_mois": projection["twelve_month_total"]}
        return json.dumps(out, ensure_ascii=False)
    except Exception as error:
        return json.dumps({"error": f"Les chiffres de Noriven sont indisponibles ({type(error).__name__})."}, ensure_ascii=False)


def register(ctx):
    ctx.register_tool(name="noriven_chiffres", toolset=TOOLSET, schema=SCHEMA, handler=handle, description=DESCRIPTION, emoji="📊")
