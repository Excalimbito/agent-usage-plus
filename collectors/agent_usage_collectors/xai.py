"""xAI/Grok team credit collector using xAI's documented Management API.

The ordinary inference ``XAI_API_KEY`` cannot read billing data.  xAI exposes
prepaid credit balance to a *management key*, so this collector intentionally
requires the narrower, explicit management credential instead of pretending
an inference key can provide a usage meter.

References:
https://docs.x.ai/developers/management-api-guide
https://docs.x.ai/developers/rest-api-reference/management/billing
"""

from __future__ import annotations

from typing import Any

from .common import auth_missing, base_record, classify_failure, endpoint_problem, find_key, find_setting, get_json, print_record

BASE_URL = "https://management-api.x.ai"
VALIDATION_ENDPOINT = f"{BASE_URL}/auth/management-keys/validation"
AUTH_HELP = (
    "Create an xAI Management Key in xAI Console → Settings → Management Keys, "
    "then set XAI_MANAGEMENT_API_KEY (not XAI_API_KEY). A team ID is discovered "
    "automatically for team-scoped keys; otherwise set XAI_TEAM_ID."
)


def cents(value: Any) -> float | None:
    """xAI Management API billing amounts are signed USD cents strings.

    Its prepaid-balance endpoint returns available prepaid credit as a negative
    accounting amount (the official example returns ``-1000`` for $10).  The
    panel expects a positive remaining-credit number, hence the sign flip.
    """
    try:
        parsed = float(value)
        return -parsed / 100
    except (TypeError, ValueError):
        return None


def team_id_from_validation(payload: dict[str, Any], configured_team_id: str | None) -> str | None:
    if configured_team_id:
        return configured_team_id
    team_id = payload.get("teamId")
    if isinstance(team_id, str) and team_id.strip():
        return team_id.strip()
    # Newer responses call this scopeId. It is safe to use only for a
    # team-scoped management key; organization scope needs an explicit team.
    if payload.get("scope") == "SCOPE_TEAM":
        scope_id = payload.get("scopeId")
        if isinstance(scope_id, str) and scope_id.strip():
            return scope_id.strip()
    return None


def record_from_payload(payload: dict[str, Any]) -> dict[str, Any]:
    record = base_record("xai", "xAI / Grok", "xAI team API")
    total = payload.get("total")
    value = total.get("val") if isinstance(total, dict) else None
    remaining = cents(value)
    if remaining is None or remaining < 0:
        raise ValueError("prepaid balance total is missing or invalid")
    record["balance"] = {"remaining": remaining, "currency": "USD"}
    record["ready"] = True
    return record


def collect() -> dict[str, Any]:
    record = base_record("xai", "xAI / Grok", "xAI team API")
    key = find_key("XAI_MANAGEMENT_API_KEY", "xai", "managementKey")
    if not key:
        return auth_missing(record, AUTH_HELP)
    configured_team_id = find_setting("XAI_TEAM_ID", "xai", "teamId")
    try:
        validation = get_json(VALIDATION_ENDPOINT, key)
        team_id = team_id_from_validation(validation, configured_team_id)
        if not team_id:
            return endpoint_problem(
                record,
                "xAI team ID required",
                "This management key is organization-scoped. Set XAI_TEAM_ID or xai.teamId in collectors.json to the Team ID from xAI Console → Team settings.",
            )
        return record_from_payload(get_json(f"{BASE_URL}/v1/billing/teams/{team_id}/prepaid/balance", key))
    except Exception as exc:  # converted to a display record, never leaked
        return classify_failure(record, "xAI", exc, AUTH_HELP, rejected_status="Management key rejected")


if __name__ == "__main__":
    print_record(collect())
