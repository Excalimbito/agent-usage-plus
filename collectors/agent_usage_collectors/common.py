"""Small, dependency-free helpers shared by the provider collectors.

Collectors print one record to stdout.  ``run-all`` is responsible for the
atomic state-file write, so these commands remain compatible with Omarchy's
existing ``omarchy-agent-usage-update`` contract as well.
"""

from __future__ import annotations

import json
import os
import socket
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


USER_AGENT = "agent-usage-plus-collectors/1"


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def base_record(agent_id: str, name: str, tier: str) -> dict[str, Any]:
    return {
        "id": agent_id,
        "name": name,
        "schemaVersion": 1,
        "updatedAt": now_iso(),
        "scope": "account",
        "hasLocalStats": False,
        "hasPromptStats": False,
        "tierLabel": tier,
        "limits": [],
    }


def auth_missing(record: dict[str, Any], help_text: str) -> dict[str, Any]:
    record.update({"ready": False, "usageStatusText": "Waiting for API key", "authHelpText": help_text})
    return record


def endpoint_problem(record: dict[str, Any], status: str, help_text: str, *, retry: bool = False) -> dict[str, Any]:
    record.update({"ready": False, "usageStatusText": status, "authHelpText": help_text})
    if retry:
        record["retryAdvised"] = True
    return record


def get_json(
    url: str,
    api_key: str,
    timeout_seconds: float = 10,
    *,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Request a documented JSON endpoint without ever logging the credential."""
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"Authorization": f"Bearer {api_key}", "Accept": "application/json", "User-Agent": USER_AGENT}
    if body is not None:
        headers["Content-Type"] = "application/json"
    request = Request(url, data=body, method=method, headers=headers)
    with urlopen(request, timeout=timeout_seconds) as response:
        payload = json.loads(response.read().decode("utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("provider returned a JSON value other than an object")
    return payload


def classify_failure(
    record: dict[str, Any],
    provider: str,
    exc: BaseException,
    auth_help: str,
    *,
    rejected_status: str = "API key rejected",
) -> dict[str, Any]:
    """Turn an expected probe failure into the panel's documented state."""
    if isinstance(exc, HTTPError):
        if exc.code in (401, 403):
            return endpoint_problem(record, rejected_status, auth_help)
        return endpoint_problem(
            record,
            f"{provider} usage unavailable",
            f"{provider} returned HTTP {exc.code}. Check the provider status and try the next refresh.",
        )
    if isinstance(exc, (URLError, TimeoutError, socket.timeout)):
        return endpoint_problem(
            record,
            f"{provider} usage unavailable",
            f"Could not reach {provider}. Check your network or DNS; Agent Usage Plus will retry shortly.",
            retry=True,
        )
    return endpoint_problem(
        record,
        f"{provider} usage unavailable",
        f"{provider} returned an unexpected response. Update the collectors package or try the next refresh.",
    )


def find_key(env_name: str, config_provider: str, setting_name: str = "apiKey") -> str | None:
    """Read an opt-in 0600 JSON credential file without ever echoing its value.

    Environment variables take precedence.  The file is deliberately a
    collector-owned config path; guessing random application configs creates
    brittle credential detection and risks treating an unrelated key as this
    provider's key.
    """
    value = os.environ.get(env_name, "").strip()
    if value:
        return value
    config_home = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config"))
    path = config_home / "omarchy" / "agent-usage-plus" / "collectors.json"
    try:
        if path.stat().st_mode & 0o077:
            return None
        data = json.loads(path.read_text(encoding="utf-8"))
        candidate = data.get(config_provider, {}).get(setting_name) if isinstance(data, dict) else None
        return candidate.strip() if isinstance(candidate, str) and candidate.strip() else None
    except (OSError, ValueError, AttributeError):
        return None


def find_setting(env_name: str, config_provider: str, setting_name: str) -> str | None:
    """Return a non-secret companion-collector setting from the opt-in config.

    This is deliberately restricted to the same mode-600 collector-owned
    config file as ``find_key``.  It avoids guessing at provider application
    settings or copying secrets from unrelated tools.
    """
    value = os.environ.get(env_name, "").strip()
    if value:
        return value
    config_home = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config"))
    path = config_home / "omarchy" / "agent-usage-plus" / "collectors.json"
    try:
        if path.stat().st_mode & 0o077:
            return None
        data = json.loads(path.read_text(encoding="utf-8"))
        candidate = data.get(config_provider, {}).get(setting_name) if isinstance(data, dict) else None
        return candidate.strip() if isinstance(candidate, str) and candidate.strip() else None
    except (OSError, ValueError, AttributeError):
        return None


def print_record(record: dict[str, Any]) -> None:
    json.dump(record, sys.stdout, separators=(",", ":"), sort_keys=True)
    sys.stdout.write("\n")
