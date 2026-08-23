"""Decorate an existing Claude/Codex transcript collector with API pricing.

Omarchy already owns the mature transcript scanners. This companion keeps
that source of truth and only adds a derived ``cost`` block to its JSON; it
does not read credentials or make a network request.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any


def helper_path() -> Path | None:
    configured = os.environ.get("AGENT_USAGE_PLUS_COST_HELPER", "")
    candidates = [Path(configured)] if configured else []
    here = Path(__file__).resolve()
    # Installed layout: <data>/agent_usage_collectors + <data>/scripts.
    candidates.append(here.parents[1] / "scripts" / "calculate-api-cost")
    # Source layout: <repo>/collectors/agent_usage_collectors + <repo>/scripts.
    candidates.append(here.parents[2] / "scripts" / "calculate-api-cost")
    return next((candidate for candidate in candidates if candidate.is_file()), None)


def normalise_today_buckets(record: dict[str, Any]) -> None:
    """Upgrade old base collectors' scalar daily totals to the contract shape.

    Older Omarchy scanners only retain a per-model total for today. It cannot
    reconstruct a historic input/output/cache split, so preserve the total in
    ``inputTokens`` and make the unknown split explicit as zeroes. Newer
    bucket-shaped values pass through with every required key present.
    """
    raw = record.get("todayTokensByModel")
    if not isinstance(raw, dict):
        return
    buckets: dict[str, dict[str, int]] = {}
    for model, value in raw.items():
        if isinstance(value, dict):
            buckets[str(model)] = {
                "inputTokens": int(value.get("inputTokens") or 0),
                "outputTokens": int(value.get("outputTokens") or 0),
                "cacheReadInputTokens": int(value.get("cacheReadInputTokens") or 0),
                "cacheCreationInputTokens": int(value.get("cacheCreationInputTokens") or 0),
            }
        else:
            try:
                total = max(0, int(value or 0))
            except (TypeError, ValueError):
                total = 0
            buckets[str(model)] = {
                "inputTokens": total,
                "outputTokens": 0,
                "cacheReadInputTokens": 0,
                "cacheCreationInputTokens": 0,
            }
    record["todayTokensByModel"] = buckets


def decorate(record: dict[str, Any], provider: str, period: str) -> dict[str, Any]:
    """Add a complete, exact-price estimate, or leave cost absent.

    The estimator rejects a partial total when a used transcript model is
    unknown. The base record remains useful and authoritative in that case.
    """
    normalise_today_buckets(record)
    helper = helper_path()
    if helper is None:
        return record
    payload = {"provider": provider, "period": period, "modelUsage": record.get("modelUsage") or {}}
    try:
        result = subprocess.run(
            [str(helper)], input=json.dumps(payload), text=True, capture_output=True,
            check=True, timeout=10,
        )
        calculated = json.loads(result.stdout)
        cost = calculated.get("cost") if isinstance(calculated, dict) else None
        if isinstance(cost, dict):
            record["cost"] = cost
    except (OSError, subprocess.SubprocessError, ValueError, json.JSONDecodeError):
        # A cost estimate is additive: never hide the base collector's usage
        # record merely because the optional local bridge was unavailable.
        pass
    return record
