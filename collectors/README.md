# Agent Usage Plus collectors

This is the plugin's **supported companion package** for providers whose
authoritative API exposes an account/key budget. It is intentionally
dependency-free Python (3.10+) and does not send a credential anywhere other
than that provider's documented HTTPS endpoint. The plugin remains usable
without it; these collectors publish additional records into the same state
directory the panel already watches.

| Provider | What the collector reads | First-class credential state |
|---|---|---|
| OpenRouter | current API key's optional spending limit, remaining budget, and usage from `GET /api/v1/auth/key` | `OPENROUTER_API_KEY` or `collectors.json` entry; otherwise **Waiting for API key** tells the user exactly how to set one |
| DeepSeek | account's available credit ledger from `GET /user/balance` | `DEEPSEEK_API_KEY` or `collectors.json` entry; otherwise **Waiting for API key** tells the user exactly how to set one |
| xAI / Grok | team's authoritative prepaid API-credit balance from xAI's Management API | `XAI_MANAGEMENT_API_KEY` (not an inference `XAI_API_KEY`); team-scoped keys discover the team automatically, organization keys also need `XAI_TEAM_ID` |
| Z.AI / GLM | **No meter is published**: Z.AI currently has no documented account quota/balance/usage endpoint for API keys or Coding Plan subscriptions | `ZAI_API_KEY`/`ZHIPUAI_API_KEY` or config is detected and produces a clear status card; no key produces an exact setup instruction |
| Claude Code | existing local transcript collector, decorated with published API pricing | no new credential; the base Claude collector retains its own sign-in state |
| Codex | existing local transcript collector, decorated with published API pricing | no new credential; the base Codex collector retains its own sign-in state |

Both endpoint references are provider documentation: [OpenRouter current-key
metadata](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-key)
and [DeepSeek balance](https://api-docs.deepseek.com/api/get-user-balance).
OpenRouter's endpoint is a *per-key* budget: if the key has no configured
spending limit the record deliberately says “no key budget” instead of
mistaking account credit for one. DeepSeek can return both CNY and USD
ledgers; the panel record has one currency slot, so USD is preferred when
present and otherwise the first provider-returned ledger is shown.

## Install and run

From a clone of this repository:

```bash
./collectors/install.sh
~/.local/share/agent-usage-plus-collectors/bin/agent-usage-plus-collectors update
```

The runner atomically writes `openrouter.json`, `deepseek.json`, `xai.json`,
and `zai.json` under
`$XDG_STATE_HOME/omarchy/agents/usage` (default
`~/.local/state/omarchy/agents/usage`). Run either collector directly when
you want to inspect only its JSON output:

```bash
~/.local/share/omarchy/agent-usage-plus-collectors/bin/omarchy-agent-usage-openrouter
```

To refresh in the background without modifying Omarchy, install the optional
user timer. It runs at boot and every ten minutes:

```bash
./collectors/install.sh --enable-timer
systemctl --user status agent-usage-plus-collectors.timer
```

To have Omarchy's own `omarchy agent usage-update` invoke the collectors on
its normal refresh, explicitly choose a *writable* Omarchy bin directory:

```bash
./collectors/install.sh --omarchy-bin "$OMARCHY_PATH/bin"
```

The installer refuses a non-writable target; it never uses `sudo` or modifies
Omarchy's updater. If your distribution's `$OMARCHY_PATH/bin` is
root-owned (as `/usr/share/omarchy/bin` normally is), use the timer, or ask
your system administrator to install the two symlinks. Re-run `install.sh`
after updating this repository; it replaces only its own package and symlinks.

## Claude and Codex API-cost estimates

`omarchy-agent-usage-claude-cost` and `omarchy-agent-usage-codex-cost` run an
existing local transcript collector, then add the versioned `cost` block from
the repository's official-rate catalogue. They never send transcript content,
credentials, or usage to a network endpoint. A used model without an exact
price intentionally produces no partial dollar total.

Run either wrapper directly to inspect the resulting record. The Claude
wrapper defaults to Omarchy's packaged scanner. For Codex or a custom scanner,
point it at the preserved base executable:

```bash
AGENT_USAGE_PLUS_CODEX_BASE_COLLECTOR="$HOME/.local/bin/omarchy-agent-usage-codex" \
  ./collectors/bin/omarchy-agent-usage-codex-cost | jq '.cost'
```

With `--with-transcript-cost`, an existing regular user collector is moved
once to a recoverable `agent-usage-plus-base-<provider>` file; the wrapper
invokes that preserved scanner and then adds cost. The backup name is outside
Omarchy's collector-discovery pattern, so it is never shown as a duplicate
provider. Unknown symlinks and a pre-existing backup stop the install rather
than being overwritten. See
[`../docs/cost-estimation.md`](../docs/cost-estimation.md) for price-list
version and model-coverage rules.

## Credentials and error states

Use an environment variable for a one-off/manual run:

```bash
export OPENROUTER_API_KEY='…'
export DEEPSEEK_API_KEY='…'
export XAI_MANAGEMENT_API_KEY='…'
# Only needed for an organization-scoped xAI management key:
export XAI_TEAM_ID='…'
export ZAI_API_KEY='…'
```

For a user timer, where an interactive shell's environment is usually not
available, create this **mode 600** file instead:

```json
{
  "openrouter": { "apiKey": "…" },
  "deepseek": { "apiKey": "…" },
  "xai": { "managementKey": "…", "teamId": "optional-team-id" },
  "zai": { "apiKey": "…" }
}
```

Save it as `~/.config/omarchy/agent-usage-plus/collectors.json` and run
`chmod 600 ~/.config/omarchy/agent-usage-plus/collectors.json`. A group- or
world-readable file is deliberately ignored and reported as missing auth.
Never commit this file or paste its contents into an issue.

Missing or rejected credentials produce the panel's documented non-retrying
auth state, with the exact remediation above. A DNS, connection, or timeout
failure produces “usage unavailable”, includes a network instruction, and
sets `retryAdvised: true`; a real 4xx/5xx provider response does not retry
aggressively. A successful call is account-scoped and leaves local token
stats absent rather than inventing transcript numbers the APIs do not offer.

### xAI / Grok details

xAI deliberately separates ordinary inference keys from Management API keys.
The latter have the documented billing endpoints, so this collector does not
accept `XAI_API_KEY` as if it could fetch personal usage. Create a Management
Key in **xAI Console → Settings → Management Keys** and grant the needed
billing read access. Its validation endpoint yields the team ID for a
team-scoped key. For an organization-scoped key, copy the Team ID from **xAI
Console → Team settings** into `XAI_TEAM_ID`/`xai.teamId`. The collector calls
only the documented validation endpoint and `GET
/v1/billing/teams/{team_id}/prepaid/balance`; the latter's signed cents are
converted to the positive USD balance rendered by the panel. It does not
mislabel a prepaid balance as a subscription quota or fabricate token counts.

References: [xAI Management API guide](https://docs.x.ai/developers/management-api-guide)
and [xAI Billing Management reference](https://docs.x.ai/developers/rest-api-reference/management/billing).

### Z.AI / GLM details

Z.AI documents Bearer API-key authentication, the Coding Plan's dedicated
endpoint, and a five-hour quota cycle, but does **not** document a supported
endpoint for an account's remaining API balance, Coding Plan quota, or usage
history. This package will not scrape the authenticated web console or issue
a paid model request merely to guess. It writes a visible status record so a
configured user sees why no meter exists, and a missing user gets exact key
setup instructions; neither case reports a fake zero meter. This is a real
provider integration boundary, not a claim that the panel can measure a value
Z.AI does not expose. References: [Z.AI API authentication](https://docs.z.ai/api-reference/introduction),
[Coding Plan FAQ](https://docs.z.ai/devpack/faq), and [Usage Policy](https://docs.z.ai/devpack/usage-policy).

## Providers without a documented personal meter

This package adds a meter only when it can publish a useful authoritative
value. Gemini API documents API-key/OAuth authentication but not a user-level
usage/balance API; Cursor's public API likewise does not expose a personal
subscription meter. Z.AI now has an explicit status-only integration (above),
rather than being silently absent, because its plan quota remains console-only.
Relevant provider references: [Gemini API keys](https://ai.google.dev/gemini-api/docs/api-key)
and [Z.AI Coding Plan setup](https://docs.z.ai/devpack/quick-start).

## Development

```bash
PYTHONPATH=collectors python -m unittest discover -s collectors/tests -v
```

Tests exercise parsing and every error-state classification without a real
credential or network request.
