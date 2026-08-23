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


def decorate(record: dict[str, Any], provider: str, period: str) -> dict[str, Any]:
    """Add a complete, exact-price estimate, or leave cost absent.

    The estimator rejects a partial total when a used transcript model is
    unknown. The base record remains useful and authoritative in that case.
    """
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
