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
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List

PLUGIN = Path(os.environ.get("HERMES_WIDGETS_PLUGIN", "/opt/data/plugins/hermes-widgets"))
DISK_LIMIT, MEMORY_LIMIT = 0.85, 0.10
# An alert already raised clears only past a margin, so a value hovering at the limit does not flip the text on and off.
DISK_CLEAR, MEMORY_CLEAR = 0.80, 0.13
STATE = Path(__file__).with_name(".alertes_etat.json")
TIMEOUT_SECONDS = 60
# A backup check that cannot run (« unchecked ») is a known gap, not an alert; one that ran and found trouble is.
BACKUP_PROBLEMS = {"stale", "failed", "error", "missing"}


def _number(value: Any) -> float:
    try:
        return float(str(value).split()[0])
    except (ValueError, IndexError, TypeError):
        return 0.0


def evaluate(host: Dict[str, Any], services: Dict[str, Any], backups: Dict[str, Any], previous: Iterable[str] = ()) -> List[str]:
    """The problems, sorted, as stable one-line strings. Empty when the server is fine. `previous` is what the last pass
    reported (for the hysteresis). A tool that answers without the data we read is an error, never a calm server."""
    if not isinstance(host.get("host"), dict) or not isinstance(services.get("services"), list):
        raise ValueError("réponse inattendue de ops_get_host ou ops_list_services")
    before = set(previous)
    found: List[str] = []
    info = host["host"]
    server = info.get("hostname") or "serveur"
    disk = info.get("disk") or {}
    disk_line = f"{server} : disque utilisé à plus de {int(DISK_LIMIT * 100)} %"
    if _number(disk.get("total_bytes")) > 0:
        used = _number(disk.get("used_bytes")) / _number(disk["total_bytes"])
        if used > DISK_LIMIT or (disk_line in before and used > DISK_CLEAR):
            found.append(disk_line)
    memory = info.get("memory") or {}
    memory_line = f"{server} : moins de {int(MEMORY_LIMIT * 100)} % de mémoire disponible"
    if _number(memory.get("mem_total")) > 0:
        free = _number(memory.get("mem_available")) / _number(memory["mem_total"])
        if free < MEMORY_LIMIT or (memory_line in before and free < MEMORY_CLEAR):
            found.append(memory_line)
    loadavg = info.get("loadavg") if isinstance(info.get("loadavg"), list) and info.get("loadavg") else [0]
    if _number(info.get("cpu_count")) > 0 and _number(loadavg[-1]) > 2 * _number(info["cpu_count"]):
        found.append(f"{server} : charge soutenue très élevée")
    for name in (info.get("docker") or {}).get("unhealthy") or []:
        found.append(f"service en mauvaise santé : {name}")

    for service in services["services"]:
        if not isinstance(service, dict):
            continue
        name = service.get("alias") or service.get("id") or "?"
        if service.get("status") not in (None, "running"):
            found.append(f"service arrêté : {name}")
        elif service.get("health") == "unhealthy":
            found.append(f"service en mauvaise santé : {name}")

    for backup in backups.get("backups") or []:
        if isinstance(backup, dict) and str(backup.get("condition") or "").lower() in BACKUP_PROBLEMS:
            found.append(f"sauvegarde en retard ou en échec : {backup.get('name') or '?'}")
    return sorted(set(found))


def _load_snapshot():
    spec = importlib.util.spec_from_file_location("hermes_widgets_snapshot_monitor", PLUGIN / "snapshot.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


async def collect(call, previous: Iterable[str] = ()) -> List[str]:
    host, services, backups = await asyncio.gather(call("ops_get_host", {}), call("ops_list_services", {}), call("ops_get_backups", {}))
    for name, answer in (("ops_get_host", host), ("ops_list_services", services), ("ops_get_backups", backups)):
        if not isinstance(answer, dict) or answer.get("ok") is False:
            raise RuntimeError(f"{name} n'a pas répondu correctement")
    return evaluate(host, services, backups, previous)


def _previous() -> List[str]:
    try:
        value = json.loads(STATE.read_text(encoding="utf-8"))
        return [line for line in value if isinstance(line, str)] if isinstance(value, list) else []
    except (OSError, ValueError):
        return []


if __name__ == "__main__":
    try:
        lines = asyncio.run(asyncio.wait_for(collect(_load_snapshot().mcp_call, _previous()), TIMEOUT_SECONDS))
        STATE.write_text(json.dumps(lines, ensure_ascii=False), encoding="utf-8"); STATE.chmod(0o600)
        if lines:                                  # a healthy server prints nothing at all, not even a line break
            print("\n".join(lines))
    except Exception as error:      # a failure is reported by Hermes, never read as « all is well »
        print(f"surveillance serveur: {type(error).__name__}: {str(error)[:160]}", file=sys.stderr)
        sys.exit(1)
