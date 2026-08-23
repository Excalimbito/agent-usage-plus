"""Truthful status collector for Z.AI / GLM Coding Plan users.

Z.AI documents API-key authentication and the Coding Plan's five-hour quota,
but (as of this package version) does not document an account balance, quota,
or usage-history API.  We publish a visible status card rather than a fake
zero meter or an unauthorised console scrape.
"""

from __future__ import annotations

import os

from .common import auth_missing, base_record, endpoint_problem, find_key, print_record

AUTH_HELP = (
    "Set ZAI_API_KEY (or ZHIPUAI_API_KEY), or add zai.apiKey to "
    "~/.config/omarchy/agent-usage-plus/collectors.json (chmod 600)."
)
NO_METER_HELP = (
    "Z.AI documents API-key authentication and a five-hour GLM Coding Plan quota, "
    "but no supported endpoint to read a personal quota, balance, or usage history. "
    "Check the Z.AI console for now; this collector deliberately does not invent a zero meter."
)


def configured_key_present() -> bool:
    # ZHIPUAI_API_KEY remains common in existing GLM tool configurations.
    return bool(find_key("ZAI_API_KEY", "zai") or os.environ.get("ZHIPUAI_API_KEY", "").strip())


def collect() -> dict:
    record = base_record("zai", "Z.AI / GLM", "GLM Coding Plan or API")
    if not configured_key_present():
        return auth_missing(record, AUTH_HELP)
    return endpoint_problem(record, "Z.AI usage meter unavailable", NO_METER_HELP)


if __name__ == "__main__":
    print_record(collect())
