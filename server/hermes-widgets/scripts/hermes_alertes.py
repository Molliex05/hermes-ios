"""Cron monitor for Hermès's server watch (``hermes cron create --monitor-script``).

Prints one stable line per problem found on the production server, and NOTHING when all is well. Hermes wakes the agent only
when this text changes: a problem appears, changes or goes away. A healthy server costs nothing, and the agent is never asked
to say « rien à signaler ». Lines carry thresholds, never live values (« disque : plus de 85 % »), so a number that moves
by itself does not wake anyone. Read-only: it calls the same monitoring tools the agent has (ops_get_host, ops_list_services,
ops_get_backups).
"""
from __future__ import annotations

import asyncio
import importlib.util
import os
import sys
from pathlib import Path
from typing import Any, Dict, List

PLUGIN = Path(os.environ.get("HERMES_WIDGETS_PLUGIN", "/opt/data/plugins/hermes-widgets"))
DISK_LIMIT, MEMORY_LIMIT, RESTART_LIMIT = 0.85, 0.10, 3
# A backup check that cannot run (« unchecked ») is a known gap, not an alert; one that ran and found trouble is.
BACKUP_PROBLEMS = {"stale", "failed", "error", "missing"}


def _kb(text: Any) -> float:
    try:
        return float(str(text).split()[0])
    except (ValueError, IndexError):
        return 0.0


def evaluate(host: Dict[str, Any], services: Dict[str, Any], backups: Dict[str, Any]) -> List[str]:
    """The problems, sorted, as stable one-line strings. Empty when the server is fine."""
    found: List[str] = []
    info = host.get("host") or {}
    server = info.get("hostname") or "serveur"
    disk = info.get("disk") or {}
    if disk.get("total_bytes") and disk.get("used_bytes", 0) / disk["total_bytes"] > DISK_LIMIT:
        found.append(f"{server} : disque utilisé à plus de {int(DISK_LIMIT * 100)} %")
    memory = info.get("memory") or {}
    if _kb(memory.get("mem_total")) and _kb(memory.get("mem_available")) / _kb(memory["mem_total"]) < MEMORY_LIMIT:
        found.append(f"{server} : moins de {int(MEMORY_LIMIT * 100)} % de mémoire disponible")
    if info.get("cpu_count") and (info.get("loadavg") or [0])[-1] > 2 * info["cpu_count"]:
        found.append(f"{server} : charge soutenue très élevée")
    for name in (info.get("docker") or {}).get("unhealthy") or []:
        found.append(f"service en mauvaise santé : {name}")

    for service in services.get("services") or []:
        name = service.get("alias") or service.get("id") or "?"
        if service.get("status") not in (None, "running"):
            found.append(f"service arrêté : {name}")
        elif service.get("health") == "unhealthy":
            found.append(f"service en mauvaise santé : {name}")
        elif int(service.get("restarts") or 0) >= RESTART_LIMIT:
            found.append(f"service qui redémarre souvent : {name}")

    for backup in backups.get("backups") or []:
        if str(backup.get("condition") or "").lower() in BACKUP_PROBLEMS:
            found.append(f"sauvegarde en retard ou en échec : {backup.get('name') or '?'}")
    return sorted(set(found))


def _load_snapshot():
    spec = importlib.util.spec_from_file_location("hermes_widgets_snapshot_monitor", PLUGIN / "snapshot.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


async def collect(call) -> List[str]:
    host, services, backups = await asyncio.gather(call("ops_get_host", {}), call("ops_list_services", {}), call("ops_get_backups", {}))
    for name, answer in (("ops_get_host", host), ("ops_list_services", services), ("ops_get_backups", backups)):
        if not isinstance(answer, dict) or answer.get("ok") is False:
            raise RuntimeError(f"{name} n'a pas répondu correctement")
    return evaluate(host, services, backups)


if __name__ == "__main__":
    try:
        print("\n".join(asyncio.run(collect(_load_snapshot().mcp_call))))
    except Exception as error:      # a failure is reported by Hermes, never read as « all is well »
        print(f"surveillance serveur: {type(error).__name__}: {str(error)[:160]}", file=sys.stderr)
        sys.exit(1)
