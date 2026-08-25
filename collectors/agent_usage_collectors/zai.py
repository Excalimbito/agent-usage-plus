"""Z.AI / GLM Coding Plan quota collector.

Z.AI exposes the Coding Plan quota through the read-only monitor endpoint
used by its supported coding tools. The collector never sends a model
request and fails closed when the response shape is unfamiliar.
"""

from __future__ import annotations

import os
from datetime import datetime, timezone
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from .common import (
    auth_missing,
    base_record,
    classify_failure,
    endpoint_problem,
    find_any_key,
    find_setting,
    print_record,
    request_json,
)

GLOBAL_BASE_URL = "https://api.z.ai"
CHINA_BASE_URL = "https://open.bigmodel.cn"
DEFAULT_QUOTA_PATH = "/api/monitor/usage/quota/limit"
TRUSTED_QUOTA_HOSTS = {"api.z.ai", "open.bigmodel.cn"}
AUTH_HELP = (
    "Set Z_AI_API_KEY (or ZAI_API_KEY), or add zai.apiKey to "
    "~/.config/omarchy/agent-usage-plus/collectors.json (chmod 600), "
    "then refresh Agent Usage Plus. China-region keys may also use "
    "BIGMODEL_API_KEY, ZHIPU_API_KEY, ZHIPUAI_API_KEY, or GLM_API_KEY."
)
TEAM_HELP = (
    "Team usage needs both Z_AI_ORGANIZATION and Z_AI_PROJECT, or "
    "zai.organization and zai.project in collectors.json. For a personal "
    "Coding Plan, leave Z_AI_USAGE_SCOPE set to personal."
)


def setting(env_name: str, config_name: str) -> str | None:
    return find_setting(env_name, "zai", config_name)


def selected_region() -> str:
    value = setting("Z_AI_REGION", "region") or setting("Z_AI_API_REGION", "apiRegion") or "global"
    normalized = value.strip().lower().replace("_", "-")
    aliases = {
        "global": "global",
        "z-ai": "global",
        "api.z.ai": "global",
        "bigmodel-cn": "bigmodel-cn",
        "china": "bigmodel-cn",
        "cn": "bigmodel-cn",
        "open.bigmodel.cn": "bigmodel-cn",
    }
    return aliases.get(normalized, normalized)


def quota_endpoint(region: str) -> str:
    override = os.environ.get("Z_AI_QUOTA_ENDPOINT", "").strip()
    if override:
        return override
    base = CHINA_BASE_URL if region == "bigmodel-cn" else GLOBAL_BASE_URL
    return base + DEFAULT_QUOTA_PATH


def with_team_type(url: str) -> str:
    parts = urlsplit(url)
    query = [(key, value) for key, value in parse_qsl(parts.query, keep_blank_values=True) if key != "type"]
    query.append(("type", "2"))
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment))


def finite_number(value: Any) -> float | None:
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if result == result and result not in (float("inf"), float("-inf")) else None


def reset_iso(value: Any) -> str | None:
    number = finite_number(value)
    if number is not None:
        # The monitor response uses epoch milliseconds. Accept seconds too,
        # because older regional responses used a ten-digit timestamp.
        seconds = number / 1000 if number >= 100_000_000_000 else number
        try:
            return datetime.fromtimestamp(seconds, tz=timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        except (OverflowError, OSError, ValueError):
            return None
    if isinstance(value, str) and value.strip():
        try:
            parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
        except ValueError:
            return None
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    return None


def window_minutes(unit: Any, number: Any) -> int | None:
    unit_value = finite_number(unit)
    number_value = finite_number(number)
    if unit_value is None or number_value is None or number_value <= 0:
        return None
    multipliers = {1: 1440, 3: 60, 5: 1, 6: 10080}
    multiplier = multipliers.get(int(unit_value))
    return int(number_value * multiplier) if multiplier else None


def used_fraction(entry: dict[str, Any]) -> float:
    usage = finite_number(entry.get("usage"))
    remaining = finite_number(entry.get("remaining"))
    current = finite_number(entry.get("currentValue"))
    percentage = finite_number(entry.get("percentage"))
    used: float | None = None
    if usage is not None and usage > 0:
        if remaining is not None:
            used = usage - remaining
        elif current is not None:
            used = current
    elif current is not None:
        used = current
    if used is not None and usage is not None and usage > 0:
        return max(0.0, min(1.0, used / usage))
    if percentage is None:
        raise ValueError("limit percentage is missing")
    # The monitor API reports percentage as an integer from 0 to 100.
    return max(0.0, min(1.0, percentage / 100.0))


def limit_title(entry: dict[str, Any], index: int) -> tuple[str, str]:
    kind = str(entry.get("type") or "").upper()
    minutes = window_minutes(entry.get("unit"), entry.get("number"))
    if kind == "TIME_LIMIT":
        return "MCP quota", "MCP"
    if minutes == 300:
        return "Coding Plan · 5-hour", "5-hour"
    if minutes == 10080:
        return "Coding Plan · weekly", "Weekly"
    if minutes == 1440:
        return "Coding Plan · daily", "Daily"
    if minutes is not None:
        return f"Coding Plan · {minutes} min", f"{minutes} min"
    return f"Coding Plan quota {index + 1}", "Quota"


def record_from_payload(payload: dict[str, Any]) -> dict[str, Any]:
    record = base_record("zai", "Z.AI / GLM", "GLM Coding Plan")
    if payload.get("success") is not True or payload.get("code") not in (200, "200"):
        message = payload.get("msg") or payload.get("message") or "the quota endpoint rejected the request"
        raise ValueError(f"Z.AI quota response was not successful: {message}")
    data = payload.get("data")
    if not isinstance(data, dict) or not isinstance(data.get("limits"), list):
        raise ValueError("Z.AI quota response has no limits array")
    plan = next(
        (data.get(name) for name in ("planName", "plan", "plan_type", "packageName", "level")
         if isinstance(data.get(name), str) and data.get(name).strip()),
        None,
    )
    if plan:
        record["tierLabel"] = str(plan).strip()
    limits: list[dict[str, Any]] = []
    for index, entry in enumerate(data["limits"]):
        if not isinstance(entry, dict):
            continue
        kind = str(entry.get("type") or "").upper()
        if kind not in {"TOKENS_LIMIT", "CREDIT_LIMIT", "TIME_LIMIT"}:
            continue
        percent = used_fraction(entry)
        label, title = limit_title(entry, index)
        limit: dict[str, Any] = {"label": label, "title": title, "percent": percent}
        reset = reset_iso(entry.get("nextResetTime"))
        if reset:
            limit["resetsAt"] = reset
        limits.append(limit)
    if not limits:
        raise ValueError("Z.AI quota response has no supported limits")
    limits.sort(key=lambda item: (0 if item["title"] == "5-hour" else 1, item["title"]))
    record["limits"] = limits
    record["ready"] = True
    return record


def collect() -> dict[str, Any]:
    record = base_record("zai", "Z.AI / GLM", "GLM Coding Plan")
    key = find_any_key(
        ("Z_AI_API_KEY", "ZAI_API_KEY", "BIGMODEL_API_KEY", "ZHIPU_API_KEY", "ZHIPUAI_API_KEY", "GLM_API_KEY"),
        "zai",
    )
    if not key:
        return auth_missing(record, AUTH_HELP, status="Waiting for Z.AI API key")
    region = selected_region()
    if region not in {"global", "bigmodel-cn"}:
        return endpoint_problem(record, "Z.AI region is invalid", "Set Z_AI_REGION to global or bigmodel-cn, then refresh Agent Usage Plus.")
    scope = (setting("Z_AI_USAGE_SCOPE", "usageScope") or "personal").strip().lower()
    if scope not in {"personal", "team"}:
        return endpoint_problem(record, "Z.AI usage scope is invalid", "Set Z_AI_USAGE_SCOPE to personal or team, then refresh Agent Usage Plus.")
    headers: dict[str, str] = {}
    if scope == "team":
        organization = setting("Z_AI_ORGANIZATION", "organization")
        project = setting("Z_AI_PROJECT", "project")
        if not organization or not project:
            return endpoint_problem(record, "Z.AI team details required", TEAM_HELP)
        headers.update({"Bigmodel-Organization": organization, "Bigmodel-Project": project})
    try:
        endpoint = quota_endpoint(region)
        parsed = urlsplit(endpoint)
        hostname = (parsed.hostname or "").lower()
        trusted_host = hostname in TRUSTED_QUOTA_HOSTS
        if parsed.scheme != "https" or not parsed.netloc or not trusted_host:
            return endpoint_problem(record, "Z.AI quota endpoint is invalid", "Use the documented HTTPS Z.AI quota endpoint or clear Z_AI_QUOTA_ENDPOINT.")
        payload = request_json(with_team_type(endpoint) if scope == "team" else endpoint, headers={"Authorization": f"Bearer {key}", **headers})
        return record_from_payload(payload)
    except Exception as exc:
        return classify_failure(record, "Z.AI", exc, AUTH_HELP, rejected_status="Z.AI API key rejected")


if __name__ == "__main__":
    print_record(collect())
