from __future__ import annotations

import unittest
from urllib.error import HTTPError, URLError
from unittest.mock import patch

from agent_usage_collectors.common import base_record, classify_failure
from agent_usage_collectors.deepseek import record_from_payload as deepseek_record
from agent_usage_collectors.cursor import record_from_payload as cursor_record
from agent_usage_collectors.gemini import record_from_payload as gemini_record
from agent_usage_collectors.kimi import record_from_payload as kimi_record
from agent_usage_collectors.openrouter import record_from_payload as openrouter_record
from agent_usage_collectors.transcript_cost import decorate, normalise_today_buckets
from agent_usage_collectors.xai import record_from_payload as xai_record
from agent_usage_collectors.xai import team_id_from_validation
from agent_usage_collectors.zai import collect as collect_zai


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

    def test_xai_prepaid_credit_is_converted_from_signed_cents(self) -> None:
        record = xai_record({"total": {"val": "-1234"}})
        self.assertEqual(record["balance"], {"remaining": 12.34, "currency": "USD"})
        self.assertTrue(record["ready"])

    def test_xai_finds_team_from_legacy_or_team_scope_validation(self) -> None:
        self.assertEqual(team_id_from_validation({"teamId": "legacy-team"}, None), "legacy-team")
        self.assertEqual(team_id_from_validation({"scope": "SCOPE_TEAM", "scopeId": "scoped-team"}, None), "scoped-team")
        self.assertIsNone(team_id_from_validation({"scope": "SCOPE_ORGANIZATION", "scopeId": "org"}, None))

    @patch("agent_usage_collectors.zai.configured_key_present", return_value=False)
    def test_zai_missing_key_is_a_clear_non_meter_state(self, _configured: object) -> None:
        record = collect_zai()
        self.assertEqual(record["usageStatusText"], "Waiting for API key")
        self.assertNotIn("balance", record)

    @patch("agent_usage_collectors.zai.configured_key_present", return_value=True)
    def test_zai_configured_key_explains_the_documented_meter_gap(self, _configured: object) -> None:
        record = collect_zai()
        self.assertEqual(record["usageStatusText"], "Z.AI usage meter unavailable")
        self.assertIn("does not invent a zero meter", record["authHelpText"])

    @patch("agent_usage_collectors.xai.get_json")
    @patch("agent_usage_collectors.xai.find_setting", return_value=None)
    @patch("agent_usage_collectors.xai.find_key", return_value="management-secret")
    def test_xai_collects_validated_team_prepaid_credit(self, _key: object, _team: object, get_json: object) -> None:
        get_json.side_effect = [
            {"scope": "SCOPE_TEAM", "scopeId": "team-1"},
            {"total": {"val": "-500"}},
        ]
        from agent_usage_collectors.xai import collect as collect_xai
        record = collect_xai()
        self.assertEqual(record["balance"], {"remaining": 5.0, "currency": "USD"})
        self.assertEqual(get_json.call_count, 2)

    @patch("agent_usage_collectors.xai.get_json")
    @patch("agent_usage_collectors.xai.find_key", return_value="management-secret")
    def test_xai_rejected_management_key_is_explicit(self, _key: object, get_json: object) -> None:
        get_json.side_effect = HTTPError("https://x", 403, "no", {}, None)
        from agent_usage_collectors.xai import collect as collect_xai
        record = collect_xai()
        self.assertEqual(record["usageStatusText"], "Management key rejected")

    def test_kimi_maps_weekly_and_rolling_windows(self) -> None:
        record = kimi_record({
            "user": {"membership": {"level": "LEVEL_INTERMEDIATE"}},
            "usage": {"limit": "100", "remaining": "74", "resetTime": "2026-08-25T17:32:50Z"},
            "limits": [{
                "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
                "detail": {"limit": 100, "used": 15, "resetTime": "2026-08-23T12:32:50Z"},
            }],
        })
        self.assertEqual(record["tierLabel"], "Intermediate")
        self.assertEqual(record["limits"][0]["title"], "Session")
        self.assertEqual(record["limits"][0]["percent"], 0.15)
        self.assertEqual(record["limits"][1]["percent"], 0.26)

    def test_gemini_maps_current_cli_bucket_shape(self) -> None:
        record = gemini_record(
            {"currentTier": {"name": "Google AI Pro"}},
            {"buckets": [
                {"modelId": "gemini-3-pro", "remainingFraction": 0.4, "resetTime": "2026-08-24T00:00:00Z"},
                {"modelId": "gemini-3-flash", "remainingFraction": 0.9},
            ]},
        )
        self.assertEqual(record["tierLabel"], "Google AI Pro")
        self.assertEqual(record["limits"][0]["title"], "Pro")
        self.assertEqual(record["limits"][0]["percent"], 0.6)
        self.assertEqual(record["limits"][1]["title"], "Flash")

    def test_cursor_maps_dashboard_subscription_pools(self) -> None:
        record = cursor_record({
            "membershipType": "ultra",
            "billingCycleEnd": "2026-09-01T00:00:00Z",
            "isUnlimited": False,
            "individualUsage": {"plan": {"autoPercentUsed": 98.1, "apiPercentUsed": 100, "totalPercentUsed": 98.5}},
        })
        self.assertEqual(record["tierLabel"], "Ultra")
        self.assertEqual([limit["title"] for limit in record["limits"]], ["Cursor Models", "Other Models", "Included total"])
        self.assertEqual(record["limits"][0]["percent"], 0.981)

    def test_cursor_unlimited_is_a_real_ready_state_without_fake_meter(self) -> None:
        record = cursor_record({"membershipType": "business", "billingCycleEnd": "2026-09-01T00:00:00Z", "isUnlimited": True})
        self.assertTrue(record["ready"])
        self.assertEqual(record["limits"], [])
        self.assertIn("unlimited", record["tierLabel"])

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

    def test_transcript_cost_decorator_labels_a_partial_unknown_model_total(self) -> None:
        record = decorate({
            "id": "codex",
            "modelUsage": {
                "gpt-5.6-sol": {"inputTokens": 1},
                "unpriced-model": {"outputTokens": 1},
            },
        }, "codex", "Local transcript history")
        self.assertTrue(record["cost"]["incomplete"])
        self.assertEqual(record["cost"]["unknownModels"], ["unpriced-model"])

    def test_transcript_cost_decorator_upgrades_old_daily_scalar_totals(self) -> None:
        record = {"todayTokensByModel": {"model": 42}}
        normalise_today_buckets(record)
        self.assertEqual(record["todayTokensByModel"]["model"], {
            "inputTokens": 42,
            "outputTokens": 0,
            "cacheReadInputTokens": 0,
            "cacheCreationInputTokens": 0,
        })

    def test_transcript_cost_decorator_keeps_the_base_record_on_bad_legacy_buckets(self) -> None:
        record = {"todayTokensByModel": {
            "scalar": float("inf"),
            "partial": {"inputTokens": "not-a-number", "outputTokens": 42},
        }}
        normalise_today_buckets(record)
        self.assertEqual(record["todayTokensByModel"], {
            "scalar": {
                "inputTokens": 0,
                "outputTokens": 0,
                "cacheReadInputTokens": 0,
                "cacheCreationInputTokens": 0,
            },
            "partial": {
                "inputTokens": 0,
                "outputTokens": 42,
                "cacheReadInputTokens": 0,
                "cacheCreationInputTokens": 0,
            },
        })


if __name__ == "__main__":
    unittest.main()
