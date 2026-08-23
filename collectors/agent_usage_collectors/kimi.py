"""Kimi Coding Plan quota collector.

Kimi's Coding Plan endpoint is not formally documented, so this parser is
intentionally defensive and never turns an unfamiliar response into a zero
meter.  Its public behaviour is covered by the package README.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from .common import auth_missing, base_record, classify_failure, find_key, get_json, print_record

ENDPOINT = "https://api.kimi.com/coding/v1/usages"
AUTH_HELP = "Set KIMI_API_KEY, or add kimi.apiKey to ~/.config/omarchy/agent-usage-plus/collectors.json (chmod 600), then run agent-usage-plus-collectors update."


def number(value: Any) -> float | None:
    try:
        result = float(value)
        return result if result >= 0 else None
    except (TypeError, ValueError):
        return None


def iso_time(value: Any) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
        return value
    except ValueError:
        return None


def limit_from_block(block: Any, label: str, title: str) -> dict[str, Any]:
    if not isinstance(block, dict):
        raise ValueError(f"{label} block is missing")
    limit = number(block.get("limit"))
    used = number(block.get("used"))
    remaining = number(block.get("remaining"))
    if limit is None or limit <= 0:
        raise ValueError(f"{label} limit is missing")
    if used is None and remaining is None:
        raise ValueError(f"{label} usage is missing")
    if used is None:
        used = max(0.0, limit - remaining)
    percent = max(0.0, min(1.0, used / limit))
    result: dict[str, Any] = {"label": label, "title": title, "percent": percent}
    reset = iso_time(block.get("resetTime") or block.get("resetAt") or block.get("reset_at") or block.get("reset_time"))
    if reset:
        result["resetsAt"] = reset
    return result


def is_five_hour_window(window: Any) -> bool:
    if not isinstance(window, dict):
        return False
    duration = number(window.get("duration"))
    unit = str(window.get("timeUnit") or window.get("time_unit") or "").upper()
    return (duration == 300 and unit in {"TIME_UNIT_MINUTE", "MINUTE", "MINUTES"}) or (duration == 5 and unit in {"TIME_UNIT_HOUR", "HOUR", "HOURS"})


def record_from_payload(payload: dict[str, Any]) -> dict[str, Any]:
    record = base_record("kimi", "Kimi", "Kimi Coding Plan")
    user = payload.get("user")
    membership = user.get("membership") if isinstance(user, dict) else None
    level = membership.get("level") if isinstance(membership, dict) else None
    if isinstance(level, str) and level:
        record["tierLabel"] = level.removeprefix("LEVEL_").replace("_", " ").title()
    limits = [limit_from_block(payload.get("usage"), "Weekly", "Weekly")]
    advertised = payload.get("limits")
    if advertised is not None:
        if not isinstance(advertised, list):
            raise ValueError("limits is not an array")
        if advertised:
            rolling = next((item.get("detail") for item in advertised if isinstance(item, dict) and is_five_hour_window(item.get("window"))), None)
            if rolling is None:
                raise ValueError("recognized 5-hour limit is missing")
            limits.insert(0, limit_from_block(rolling, "Session (5-hour)", "Session"))
    record["limits"] = limits
    record["ready"] = True
    return record


def collect() -> dict[str, Any]:
    record = base_record("kimi", "Kimi", "Kimi Coding Plan")
    key = find_key("KIMI_API_KEY", "kimi")
    if not key:
        return auth_missing(record, AUTH_HELP)
    try:
        return record_from_payload(get_json(ENDPOINT, key))
    except Exception as exc:
        return classify_failure(record, "Kimi", exc, AUTH_HELP)


if __name__ == "__main__":
    print_record(collect())
