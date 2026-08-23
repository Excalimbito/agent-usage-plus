"""Cursor subscription usage collector.

Cursor does not publish this dashboard endpoint as a public API.  The
collector reads the current Cursor IDE session from its own local SQLite state
database, sends it only to cursor.com, and makes no changes to that database.
"""

from __future__ import annotations

import base64
import json
import os
import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.error import HTTPError

from .common import auth_missing, base_record, classify_failure, endpoint_problem, print_record, request_json

ENDPOINT = "https://cursor.com/api/usage-summary"
AUTH_HELP = "Sign in to the Cursor IDE (or cursor-agent) on this computer, then run agent-usage-plus-collectors update."
BROWSER_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"


def cursor_paths() -> tuple[Path, Path]:
    config = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config"))
    return (
        Path(os.environ.get("CURSOR_STATE_DB") or (config / "Cursor" / "User" / "globalStorage" / "state.vscdb")),
        Path(os.environ.get("CURSOR_AGENT_AUTH") or (config / "cursor" / "auth.json")),
    )


def token_from_jwt(token: str) -> tuple[str, str] | None:
    pieces = token.split(".")
    if len(pieces) < 2:
        return None
    try:
        segment = pieces[1] + "=" * (-len(pieces[1]) % 4)
        claims = json.loads(base64.urlsafe_b64decode(segment).decode("utf-8"))
        sub = claims.get("sub") if isinstance(claims, dict) else None
        user_id = sub.split("|", 1)[1] if isinstance(sub, str) and "|" in sub else ""
        return (user_id, token) if user_id else None
    except (ValueError, UnicodeDecodeError):
        return None


def read_token() -> tuple[str, str] | None:
    supplied = os.environ.get("CURSOR_SESSION_TOKEN", "").strip()
    if supplied:
        return token_from_jwt(supplied)
    database, agent_auth = cursor_paths()
    if database.exists():
        try:
            connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
            try:
                row = connection.execute("SELECT value FROM ItemTable WHERE key = ?", ("cursorAuth/accessToken",)).fetchone()
            finally:
                connection.close()
            if row and isinstance(row[0], str):
                token = token_from_jwt(row[0].strip())
                if token:
                    return token
        except sqlite3.Error:
            pass
    if agent_auth.exists():
        try:
            value = json.loads(agent_auth.read_text(encoding="utf-8"))
            if isinstance(value, dict) and isinstance(value.get("accessToken"), str):
                return token_from_jwt(value["accessToken"].strip())
        except (OSError, ValueError):
            pass
    return None


def iso_time(value: Any) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
        return value
    except ValueError:
        return None


def percentage(value: Any, field: str) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field} is missing") from exc
    if result < 0 or result != result or result == float("inf"):
        raise ValueError(f"{field} is invalid")
    return min(1.0, result / 100.0)


def record_from_payload(payload: dict[str, Any]) -> dict[str, Any]:
    record = base_record("cursor", "Cursor", "Cursor")
    membership = payload.get("membershipType")
    if isinstance(membership, str) and membership.strip():
        record["tierLabel"] = membership.strip().title()
    reset = iso_time(payload.get("billingCycleEnd"))
    if not reset:
        raise ValueError("billingCycleEnd is missing")
    if payload.get("isUnlimited") is True:
        record["tierLabel"] = f"{record['tierLabel']} · unlimited"
        record["ready"] = True
        return record
    individual = payload.get("individualUsage")
    plan = individual.get("plan") if isinstance(individual, dict) else None
    if not isinstance(plan, dict):
        raise ValueError("individualUsage.plan is missing; this Cursor account does not expose a per-user quota")
    auto = percentage(plan.get("autoPercentUsed"), "autoPercentUsed")
    api = percentage(plan.get("apiPercentUsed"), "apiPercentUsed")
    total = percentage(plan.get("totalPercentUsed"), "totalPercentUsed")
    record["limits"] = [
        {"label": "Cursor Models (billing cycle)", "title": "Cursor Models", "percent": auto, "resetsAt": reset},
        {"label": "Other Models (billing cycle)", "title": "Other Models", "percent": api, "resetsAt": reset},
        {"label": "Included total (billing cycle)", "title": "Included total", "percent": total, "resetsAt": reset},
    ]
    record["ready"] = True
    return record


def collect() -> dict[str, Any]:
    record = base_record("cursor", "Cursor", "Cursor")
    auth = read_token()
    if not auth:
        return auth_missing(record, AUTH_HELP, status="Waiting for Cursor sign-in")
    user_id, token = auth
    cookie = f"{user_id}%3A%3A{token}"
    try:
        return record_from_payload(request_json(ENDPOINT, headers={"Cookie": f"WorkosCursorSessionToken={cookie}", "Origin": "https://cursor.com", "Referer": "https://cursor.com/dashboard", "User-Agent": BROWSER_UA}))
    except HTTPError as exc:
        if exc.code in (401, 403):
            return endpoint_problem(record, "Cursor sign-in expired", "Open Cursor or run `cursor-agent` and sign in again, then refresh Agent Usage Plus. The collector only reads Cursor's local session and never modifies it.")
        return classify_failure(record, "Cursor", exc, AUTH_HELP)
    except Exception as exc:
        return classify_failure(record, "Cursor", exc, AUTH_HELP)


if __name__ == "__main__":
    print_record(collect())
