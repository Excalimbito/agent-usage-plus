"""Gemini CLI / Gemini Code Assist quota collector.

The official Gemini CLI itself calls the Code Assist quota RPC.  This
collector reuses only its locally persisted OAuth access token and performs
the same read-only calls; it never refreshes, changes, or exports credentials.
"""

from __future__ import annotations

import json
import os
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.error import HTTPError

from .common import auth_missing, base_record, classify_failure, endpoint_problem, print_record, request_json

BASE_URL = "https://cloudcode-pa.googleapis.com/v1internal:"
LOAD_ENDPOINT = BASE_URL + "loadCodeAssist"
QUOTA_ENDPOINT = BASE_URL + "retrieveUserQuota"
AUTH_HELP = "Sign in with the Gemini CLI using Google login (not only GEMINI_API_KEY), then run agent-usage-plus-collectors update. This collector reads ~/.gemini/oauth_creds.json without modifying it."


def credential_path() -> Path:
    # Gemini CLI historically used GEMINI_HOME; current builds use
    # GEMINI_CLI_HOME. Honor both, then the official default.
    home = os.environ.get("GEMINI_CLI_HOME") or os.environ.get("GEMINI_HOME")
    return Path(home) / "oauth_creds.json" if home else Path.home() / ".gemini" / "oauth_creds.json"


def read_access_token() -> str | None:
    # An explicitly supplied short-lived access token is useful for systems
    # where Gemini CLI is configured to put OAuth credentials in its keychain.
    # It is never persisted or included in a panel record.
    supplied = os.environ.get("GEMINI_ACCESS_TOKEN", "").strip()
    if supplied:
        return supplied
    path = credential_path()
    try:
        if not path.is_file() or path.stat().st_mode & 0o077:
            return None
        data = json.loads(path.read_text(encoding="utf-8"))
        token = data.get("access_token") if isinstance(data, dict) else None
        return token.strip() if isinstance(token, str) and token.strip() else None
    except (OSError, ValueError):
        return None


def iso_time(value: Any) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
        return value
    except ValueError:
        return None


def remaining_fraction(value: Any, model: str) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{model} has no remainingFraction") from exc
    if result < 0 or result > 1 or result != result:
        raise ValueError(f"{model} has an invalid remainingFraction")
    return result


def model_title(model: str) -> str:
    normalized = model.replace("_", "-").lower()
    if "flash" in normalized:
        return "Flash"
    if "pro" in normalized:
        return "Pro"
    return model


def record_from_payload(load: dict[str, Any], quota: dict[str, Any]) -> dict[str, Any]:
    record = base_record("gemini", "Gemini", "Gemini Code Assist")
    tier = load.get("paidTier") if isinstance(load.get("paidTier"), dict) else load.get("currentTier")
    if isinstance(tier, dict):
        tier_name = tier.get("name") or tier.get("id")
        if isinstance(tier_name, str) and tier_name.strip():
            record["tierLabel"] = tier_name.strip()
    buckets = quota.get("buckets")
    # Compatibility with the early private RPC response used by older Gemini
    # CLI releases. Current official CLI source calls this field `buckets`.
    if not isinstance(buckets, list):
        buckets = quota.get("userQuota")
    if not isinstance(buckets, list) or not buckets:
        raise ValueError("quota response has no model buckets")
    limits: list[dict[str, Any]] = []
    seen: set[str] = set()
    for entry in buckets:
        if not isinstance(entry, dict):
            continue
        model = entry.get("modelId") or entry.get("model")
        if not isinstance(model, str) or not model.strip() or model in seen:
            continue
        remaining = remaining_fraction(entry.get("remainingFraction"), model)
        title = model_title(model)
        limit: dict[str, Any] = {
            "label": f"{title} daily quota",
            "title": title,
            "percent": 1.0 - remaining,
        }
        reset = iso_time(entry.get("resetTime"))
        if reset:
            limit["resetsAt"] = reset
        limits.append(limit)
        seen.add(model)
    if not limits:
        raise ValueError("quota response has no usable model buckets")
    record["limits"] = limits
    record["ready"] = True
    return record


def collect() -> dict[str, Any]:
    record = base_record("gemini", "Gemini", "Gemini Code Assist")
    token = read_access_token()
    if not token:
        return auth_missing(record, AUTH_HELP, status="Waiting for Gemini sign-in")
    headers = {"Authorization": f"Bearer {token}"}
    project = os.environ.get("GOOGLE_CLOUD_PROJECT", "").strip()
    load_body: dict[str, Any] = {
        "metadata": {
            "ideType": "IDE_UNSPECIFIED",
            "platform": "PLATFORM_UNSPECIFIED",
            "pluginType": "GEMINI",
        }
    }
    if project:
        load_body["cloudaicompanionProject"] = project
        load_body["metadata"]["duetProject"] = project
    try:
        load = request_json(LOAD_ENDPOINT, headers=headers, body=load_body)
        project = load.get("cloudaicompanionProject") if isinstance(load.get("cloudaicompanionProject"), str) else project
        if not project:
            return auth_missing(record, "Gemini CLI is signed in but Google did not return a Code Assist project. Complete `gemini` setup, or set GOOGLE_CLOUD_PROJECT for your Code Assist project, then refresh.", status="Gemini project setup needed")
        quota = request_json(QUOTA_ENDPOINT, headers=headers, body={"project": project})
        return record_from_payload(load, quota)
    except HTTPError as exc:
        if exc.code in (401, 403):
            return endpoint_problem(record, "Gemini sign-in expired", "Run `gemini` and complete Google sign-in again. Then refresh Agent Usage Plus; this collector never changes Gemini CLI credentials.")
        return classify_failure(record, "Gemini", exc, AUTH_HELP)
    except Exception as exc:
        return classify_failure(record, "Gemini", exc, AUTH_HELP)


if __name__ == "__main__":
    print_record(collect())
