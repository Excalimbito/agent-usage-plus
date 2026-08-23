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

The runner atomically writes `openrouter.json` and `deepseek.json` under
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
once to a recoverable `.agent-usage-plus-base` sibling; the wrapper invokes
that preserved scanner and then adds cost. Unknown symlinks and a pre-existing
backup stop the install rather than being overwritten. See
[`../docs/cost-estimation.md`](../docs/cost-estimation.md) for price-list
version and model-coverage rules.

## Credentials and error states

Use an environment variable for a one-off/manual run:

```bash
export OPENROUTER_API_KEY='…'
export DEEPSEEK_API_KEY='…'
```

For a user timer, where an interactive shell's environment is usually not
available, create this **mode 600** file instead:

```json
{
  "openrouter": { "apiKey": "…" },
  "deepseek": { "apiKey": "…" }
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

## Why only these two right now

This package adds providers only when it can publish a useful authoritative
record. Gemini API documents API-key/OAuth authentication but not a
user-level usage/balance API; Cursor's public API likewise does not expose a
personal subscription meter; and Z.AI documents API-key and Coding Plan
endpoints but directs plan limits to its web console. A “collector” that only
checks for a key would add a misleading zero meter, so those remain explicitly
unsupported until a documented source exists. Relevant provider references:
[Gemini API keys](https://ai.google.dev/gemini-api/docs/api-key), [Z.AI
Coding Plan setup](https://docs.z.ai/devpack/quick-start), and [Z.AI FAQ on
rate limits](https://docs.z.ai/help/faq).

## Development

```bash
python -m unittest discover -s collectors/tests -v
```

Tests exercise parsing and every error-state classification without a real
credential or network request.
