"""OpenRouter current-key budget collector.

API reference: https://openrouter.ai/docs/api/api-reference/api-keys/get-current-key
"""

from __future__ import annotations

from typing import Any

from .common import auth_missing, base_record, classify_failure, find_key, get_json, print_record

ENDPOINT = "https://openrouter.ai/api/v1/auth/key"
AUTH_HELP = "Set OPENROUTER_API_KEY, or add openrouter.apiKey to ~/.config/omarchy/agent-usage-plus/collectors.json (chmod 600), then run agent-usage-plus-collectors update."


def number(value: Any) -> float | None:
    try:
        result = float(value)
        return result if result >= 0 else None
    except (TypeError, ValueError):
        return None


def record_from_payload(payload: dict[str, Any]) -> dict[str, Any]:
    record = base_record("openrouter", "OpenRouter", "OpenRouter API key")
    data = payload.get("data") if isinstance(payload.get("data"), dict) else payload
    limit = number(data.get("limit"))
    remaining = number(data.get("limit_remaining"))
    usage = number(data.get("usage"))
    reset = data.get("limit_reset")
    if limit is not None and remaining is not None:
        balance: dict[str, Any] = {"remaining": remaining, "funded": limit, "currency": "USD"}
        if usage is not None:
            balance["spent"] = usage
        record["balance"] = balance
        if isinstance(reset, str) and reset in {"daily", "weekly", "monthly"}:
            record["tierLabel"] = f"OpenRouter API key · {reset} budget"
    else:
        # A current-key probe can succeed even if that key has no spending
        # limit. This is a normal account configuration, not a panel error.
        record["tierLabel"] = "OpenRouter API key · no key budget"
    record["ready"] = True
    return record


def collect() -> dict[str, Any]:
    record = base_record("openrouter", "OpenRouter", "OpenRouter API key")
    key = find_key("OPENROUTER_API_KEY", "openrouter")
    if not key:
        return auth_missing(record, AUTH_HELP)
    try:
        return record_from_payload(get_json(ENDPOINT, key))
    except Exception as exc:  # converted to a display record, never leaked
        return classify_failure(record, "OpenRouter", exc, AUTH_HELP)


if __name__ == "__main__":
    print_record(collect())
