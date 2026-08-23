from __future__ import annotations

import unittest
from urllib.error import HTTPError, URLError

from agent_usage_collectors.common import base_record, classify_failure
from agent_usage_collectors.deepseek import record_from_payload as deepseek_record
from agent_usage_collectors.openrouter import record_from_payload as openrouter_record
from agent_usage_collectors.transcript_cost import decorate, normalise_today_buckets


class CollectorParsingTests(unittest.TestCase):
    def test_openrouter_budget_maps_to_balance(self) -> None:
        record = openrouter_record({"data": {"limit": 25, "limit_remaining": 17.5, "usage": 7.5, "limit_reset": "monthly"}})
        self.assertTrue(record["ready"])
        self.assertEqual(record["balance"], {"remaining": 17.5, "funded": 25.0, "spent": 7.5, "currency": "USD"})
        self.assertIn("monthly", record["tierLabel"])

    def test_openrouter_without_key_limit_is_not_an_error(self) -> None:
        record = openrouter_record({"data": {"usage": 4.25, "limit": None}})
        self.assertTrue(record["ready"])
        self.assertNotIn("balance", record)
        self.assertNotIn("usageStatusText", record)

    def test_deepseek_prefers_usd_ledger(self) -> None:
        record = deepseek_record({"is_available": True, "balance_infos": [{"currency": "CNY", "total_balance": "100"}, {"currency": "USD", "total_balance": "3.20"}]})
        self.assertEqual(record["balance"], {"remaining": 3.2, "currency": "USD"})
        self.assertTrue(record["ready"])

    def test_auth_and_transport_states_have_correct_retry_behavior(self) -> None:
        error = HTTPError("https://x", 401, "no", {}, None)
        rejected = classify_failure(base_record("x", "X", "X"), "X", error, "Fix auth")
        error.close()
        network = classify_failure(base_record("x", "X", "X"), "X", URLError("offline"), "Fix auth")
        self.assertEqual(rejected["usageStatusText"], "API key rejected")
        self.assertNotIn("retryAdvised", rejected)
        self.assertTrue(network["retryAdvised"])

    def test_transcript_cost_decorator_uses_complete_known_model_pricing(self) -> None:
        record = decorate({
            "id": "claude",
            "modelUsage": {
                "claude-sonnet-5": {
                    "inputTokens": 1_000_000,
                    "outputTokens": 1_000_000,
                    "cacheReadInputTokens": 1_000_000,
                    "cacheCreationInputTokens": 1_000_000,
                },
            },
        }, "claude", "Local transcript history")
        self.assertEqual(record["cost"]["estimateUsd"], 14.7)

    def test_transcript_cost_decorator_refuses_a_partial_unknown_model_total(self) -> None:
        record = decorate({
            "id": "codex",
            "modelUsage": {
                "gpt-5.6-sol": {"inputTokens": 1},
                "unpriced-model": {"outputTokens": 1},
            },
        }, "codex", "Local transcript history")
        self.assertNotIn("cost", record)

    def test_transcript_cost_decorator_upgrades_old_daily_scalar_totals(self) -> None:
        record = {"todayTokensByModel": {"model": 42}}
        normalise_today_buckets(record)
        self.assertEqual(record["todayTokensByModel"]["model"], {
            "inputTokens": 42,
            "outputTokens": 0,
            "cacheReadInputTokens": 0,
            "cacheCreationInputTokens": 0,
        })


if __name__ == "__main__":
    unittest.main()
