"""Builds the widget snapshot from Noriven's read-only MCP analytics datasets (no Noriven secret, no raw rows).

Source: the same MCP client and token Hermès already uses (`mcp_servers.noriven` in the Noriven profile).
Output is a small JSON document with CAD amounts rounded to cents. Nothing here is written anywhere.
"""
from __future__ import annotations

import json
import os
import re
import time
from datetime import date
from pathlib import Path
from typing import Any, Awaitable, Callable, Dict, List, Optional

PROFILE = "noriven"
MCP_URL = "http://noriven-mcp-production:3000/api/mcp"
CACHE_SECONDS = 300
MONTHS = ("janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre")

CallTool = Callable[[str, Dict[str, Any]], Awaitable[Dict[str, Any]]]
_cache: Dict[str, Any] = {"at": 0.0, "value": None}


def _money(value: Any) -> float:
    try:
        return round(float(value or 0), 2)
    except (TypeError, ValueError):
        return 0.0


def month_label(month: str) -> str:
    year, number = month[:4], int(month[5:7])
    return f"{MONTHS[number - 1]} {year}"


def _shift(month: str, delta: int) -> str:
    index = int(month[:4]) * 12 + int(month[5:7]) - 1 + delta
    return f"{index // 12:04d}-{index % 12 + 1:02d}"


def _projection(raw: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    """Shape `finance_get_projection` (Noriven MCP) for the widgets; None when the tool is absent or malformed."""
    if not isinstance(raw, dict) or not raw.get("ok"):
        return None
    current, following = raw.get("current_month") or {}, raw.get("next_month") or {}
    months = [{"month": str(m.get("month", ""))[:7], "total": None if m.get("total") is None else _money(m.get("total"))}
              for m in (raw.get("months") or []) if isinstance(m, dict) and m.get("month")]
    if not months:
        return None
    return {"month_total": None if current.get("total") is None else _money(current.get("total")),
            "next_month_total": None if following.get("total") is None else _money(following.get("total")),
            "twelve_month_total": None if raw.get("twelve_months_total") is None else _money(raw.get("twelve_months_total")),
            "months": months}


def build(rows: List[Dict[str, Any]], mrr_rows: List[Dict[str, Any]], today: date, environment: str,
          projection: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Pure function: dataset rows in, snapshot out."""
    current = f"{today.year:04d}-{today.month:02d}"
    by_month = {str(r.get("month", ""))[:7]: r for r in rows if re.match(r"^\d{4}-\d{2}", str(r.get("month", "")))}

    def entry(month: str) -> Dict[str, Any]:
        r = by_month.get(month) or {}
        return {"month": month, "estimated_revenue": _money(r.get("estimated_net_revenue")), "confirmed_revenue": _money(r.get("confirmed_net_revenue")),
                "expenses": _money(r.get("total_expenses")), "estimated_profit": _money(r.get("estimated_profit"))}

    months = [entry(_shift(current, -offset)) for offset in range(5, -1, -1)]
    mrr = None
    ordered = sorted((r for r in mrr_rows if r.get("month")), key=lambda r: str(r["month"]))
    if ordered:
        last = ordered[-1]
        mrr = {"value": _money(last.get("mrr")), "active_subscriptions": int(last.get("active_subscriptions") or 0),
               "trialing_subscriptions": int(last.get("trialing_subscriptions") or 0), "month": str(last["month"])[:7],
               "snapshot_date": str(last.get("snapshot_date") or "")[:10]}
    return {"version": 1, "currency": "CAD", "data_environment": environment, "as_of": today.isoformat(),
            "finance": {"month": current, "label": month_label(current), "current": entry(current), "previous": entry(_shift(current, -1)), "months": months},
            "mrr": mrr, "projection": _projection(projection)}


async def fetch(call: CallTool, today: Optional[date] = None) -> Dict[str, Any]:
    today = today or date.today()
    start = _shift(f"{today.year:04d}-{today.month:02d}", -5)
    window = {"from": start, "to": f"{today.year:04d}-{today.month:02d}"}
    money = await call("analytics_query_dataset", {"dataset": "revenue_vs_expenses_monthly", **window, "limit": 20})
    try:
        growth = await call("analytics_query_dataset", {"dataset": "glutax_mrr_monthly", **window, "limit": 20})
    except Exception:
        growth = {"rows": []}      # MRR is secondary: the money figures still ship
    try:
        projection = await call("finance_get_projection", {})
    except Exception:
        projection = None      # not deployed yet, or temporarily failing: the figures above still ship
    if not money.get("ok", True):
        raise RuntimeError("Noriven a refusé la requête.")
    return build(list(money.get("rows") or []), list(growth.get("rows") or []), today, str(money.get("data_environment") or "unknown"), projection)


def _token() -> str:
    for name in ("NORIVEN_MCP_TOKEN",):
        if os.environ.get(name):
            return os.environ[name].strip()
    home = Path(os.environ.get("HERMES_PROFILES_DIR", "/opt/data/profiles")) / PROFILE / ".env"
    try:
        for line in home.read_text().splitlines():
            if line.startswith("NORIVEN_MCP_TOKEN="):
                return line.split("=", 1)[1].strip().strip("\"'")
    except OSError:
        pass
    return ""


async def mcp_call(name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
    """One tool call over the MCP streamable HTTP transport. The token never leaves this function."""
    from mcp import ClientSession
    from mcp.client.streamable_http import create_mcp_http_client, streamable_http_client
    token = _token()
    if not token:
        raise RuntimeError("Jeton Noriven absent.")
    async with streamable_http_client(MCP_URL, http_client=create_mcp_http_client(headers={"Authorization": f"Bearer {token}"})) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(name, arguments)
    return json.loads(result.content[0].text)


async def snapshot(call: CallTool = mcp_call, now: Optional[float] = None) -> Dict[str, Any]:
    """Cached for CACHE_SECONDS. On failure the last good snapshot is served, marked stale."""
    clock = time.time() if now is None else now
    if _cache["value"] is not None and clock - _cache["at"] < CACHE_SECONDS:
        return _cache["value"]
    try:
        value = await fetch(call)
    except Exception:
        if _cache["value"] is not None:
            return {**_cache["value"], "stale": True}
        raise
    value["generated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(clock))
    _cache["value"], _cache["at"] = value, clock
    return value


async def year_to_date(call: CallTool = mcp_call, today: Optional[date] = None) -> Dict[str, Any]:
    """Revenue, expenses and profit since 1 January (sums of the monthly dataset)."""
    today = today or date.today()
    money = await call("analytics_query_dataset", {"dataset": "revenue_vs_expenses_monthly", "from": f"{today.year:04d}-01",
                                                   "to": f"{today.year:04d}-{today.month:02d}", "limit": 20})
    rows = [r for r in (money.get("rows") or []) if isinstance(r, dict)]
    total = lambda key: round(sum(float(r.get(key) or 0) for r in rows), 2)
    return {"depuis": f"{today.year:04d}-01-01", "revenu_estime": total("estimated_net_revenue"), "revenu_confirme": total("confirmed_net_revenue"),
            "depenses": total("total_expenses"), "profit_estime": total("estimated_profit"), "mois_couverts": len(rows)}
