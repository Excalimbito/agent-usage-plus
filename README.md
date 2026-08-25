# Agent Usage Plus

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

![Agent Usage Plus](preview.png)

An Omarchy bar widget that shows AI coding usage, limits, balances and token
history in one native Quickshell panel. It reads the JSON records produced by
Omarchy's local collectors, so it works with both subscriptions and API
accounts without storing credentials in the plugin.

## Install

```bash
omarchy plugin add https://github.com/viganogabriele/agent-usage-plus.git --enable
```

Update or remove it with:

```bash
omarchy plugin update io.github.viganogabriele.agent-usage-plus
omarchy plugin remove io.github.viganogabriele.agent-usage-plus
```

## Providers

| Provider | Data source |
|---|---|
| Claude Code | Subscription session/weekly limits and local usage |
| Codex | Subscription weekly limit and local usage |
| Fireworks | API balance estimate and local usage |
| OpenRouter | API-key budget |
| DeepSeek | API credit balance |
| Gemini | Gemini CLI sign-in quota |
| Cursor | Local Cursor sign-in usage |
| Kimi | API quota |
| xAI / Grok | API credit balance |
| Z.AI / GLM | Coding Plan quota |

Claude Code and Codex are supplied by Omarchy. The other API and account
collectors are optional and are installed separately:

```bash
./collectors/install.sh
~/.local/share/agent-usage-plus-collectors/bin/agent-usage-plus-collectors update
```

Provider visibility depends on the corresponding local sign-in, API key or
usage record. Missing credentials are shown as a provider status, not as a
fake zero.

## Theme and notifications

The bar and panel use Omarchy's live theme for foregrounds, surfaces, tracks,
fonts and critical state. Provider marks switch between their default and
light assets according to the live bar foreground. Warn is intentionally fixed
amber (`#F2B705`) so it remains distinct from Critical.

Notifications are off by default. When enabled, each provider sends at most
one notification at Warn and one at Critical when its primary quota crosses
those thresholds; refreshes do not repeat the alert.

## More

- [Collector setup and credentials](collectors/README.md)
- [Collector record contract](docs/collector-contract.md)
- [Manual release checklist](docs/manual-qa.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Contributing and provider icons](CONTRIBUTING.md)

## Development

```bash
npm test
(cd collectors && python3 -m unittest tests.test_collectors)
```

The plugin is MIT licensed. It is based on Omarchy's built-in agents widget;
see [LICENSE](LICENSE) and [Omarchy](https://github.com/basecamp/omarchy).

<!-- Additional screenshots can be added here as the visual documentation grows. -->
