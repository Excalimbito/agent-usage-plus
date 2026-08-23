"""DeepSeek account-balance collector.

API reference: https://api-docs.deepseek.com/api/get-user-balance
"""

from __future__ import annotations

from typing import Any

from .common import auth_missing, base_record, classify_failure, find_key, get_json, print_record

ENDPOINT = "https://api.deepseek.com/user/balance"
AUTH_HELP = "Set DEEPSEEK_API_KEY, or add deepseek.apiKey to ~/.config/omarchy/agent-usage-plus/collectors.json (chmod 600), then run agent-usage-plus-collectors update."


def number(value: Any) -> float | None:
    try:
        result = float(value)
        return result if result >= 0 else None
    except (TypeError, ValueError):
        return None


def record_from_payload(payload: dict[str, Any]) -> dict[str, Any]:
    record = base_record("deepseek", "DeepSeek", "DeepSeek API")
    entries = payload.get("balance_infos")
    if not isinstance(entries, list):
        raise ValueError("balance_infos is missing")
    valid = [entry for entry in entries if isinstance(entry, dict) and number(entry.get("total_balance")) is not None]
    if not valid:
        raise ValueError("balance_infos contains no usable balance")
    # Prefer the panel's native currency. A DeepSeek account can carry CNY
    # and USD ledgers simultaneously, while the record contract has one.
    entry = next((item for item in valid if item.get("currency") == "USD"), valid[0])
    currency = str(entry.get("currency") or "USD")
    remaining = number(entry.get("total_balance"))
    assert remaining is not None
    record["balance"] = {"remaining": remaining, "currency": currency}
    record["ready"] = True
    if payload.get("is_available") is False:
        record["usageStatusText"] = "DeepSeek balance unavailable"
        record["authHelpText"] = "This DeepSeek account reports no usable API balance. Add credit in the DeepSeek console, then refresh."
    return record


def collect() -> dict[str, Any]:
    record = base_record("deepseek", "DeepSeek", "DeepSeek API")
    key = find_key("DEEPSEEK_API_KEY", "deepseek")
    if not key:
        return auth_missing(record, AUTH_HELP)
    try:
        return record_from_payload(get_json(ENDPOINT, key))
    except Exception as exc:  # converted to a display record, never leaked
        return classify_failure(record, "DeepSeek", exc, AUTH_HELP)


if __name__ == "__main__":
    print_record(collect())
