# Manual QA checklist

Run this checklist against the real Omarchy bar before a release. QML is not hot-reloaded: after changing or relinking this plugin, run `omarchy restart shell`. `omarchy-shell shell rescanPlugins` is not enough to load changed QML.

Automated tests cover extracted logic and record validation. They cannot show clipped bar content, a confusing control, or a popup that has become hard to use at a real desktop size.

## Bar

- [ ] With one, two, and three enabled providers that have data and `showInBar: true`, each meter has a readable mark, meter, and percentage. A provider with a weekly limit also has the small weekly tick.
- [ ] With four or more eligible providers, the bar shows at most three full meter groups followed by a `+N` indicator. Hovering it explains that the remaining subscriptions are in the panel; clicking it opens the full provider list rather than creating an inert gap.
- [ ] Verify Off, Fixed, and Cycle roles. Fixed providers
  stay visible while the configured number of rotating slots advances at the
  interval. Test two rotating slots and one Fixed plus one Cycle. Middle-click
  advances the rotating slice without changing the panel's selected tab.
- [ ] `showInBar: false` hides only the meter, not the provider's panel tab. `enabled: false` hides it from both and stops collector refreshes for it.
- [ ] When every known provider is hidden from the bar or disabled, the module glyph remains visible and opens settings. On a machine with no discovered record at all, the widget correctly stays absent.
- [ ] Check normal, warn, and critical meter colors at the configured boundaries. They must follow the current Omarchy theme rather than a fixed color, including after a theme change.

## Panel hierarchy and interaction

- [ ] The hero has two equal outlined actions: gear for Settings and chevron for Details. Their tooltips name the action and shortcut; `s` toggles Settings and `e` toggles Details. Opening either closes the other.
- [ ] With several providers, the switch shows compact logos instead of text pills. Hover and keyboard focus reveal each full name. `h`/`l` still select every provider, including a logo on a wrapped row.
- [ ] Compact view prioritizes error/help, limits or balance, daily tokens, then model tokens. It should not open scrolled partway down or clip content at 1366x768 and 1920x1080.
- [ ] Details first show the selected provider's token use by model. If known, each row's right column is labelled API price. The derived total follows this table and says that it is not a bill or subscription price.
- [ ] The history is a line chart across every recorded day. It shows a 0/50/100% token scale and start, middle, and end dates without a fake range selector.
- [ ] `r` and Enter refresh, `j`/`k` scroll, Tab moves to the neighbouring panel, and Esc closes. Tab can focus the gear, expansion chevron, and cost disclosure; Enter, Space, and Return activate each.

## Settings

- [ ] Open the gear: every provider occupies one row; its name, Enabled switch,
  and Off/Fixed/Cycle selector do not clip or overlap. Disabled providers dim
  the bar-slot selector.
- [ ] Mark a provider Cycle and verify the rotating-slot count and interval
  appear. Both values must stay within their stated limits.
- [ ] Change refresh interval and warn/critical thresholds, then confirm values survive `omarchy restart shell`. Settings must apply without a restart because the panel writes via `omarchy bar set`, not directly to `shell.json`.
- [ ] Confirm an invalid externally-written threshold pair (`warn >= critical`) never crashes the panel; it should skip the warn band until the pair is corrected.

## Error and data states

- [ ] An auth-missing or endpoint-down record shows a coloured card with a visible status heading and the collector's actionable help text. A status record with no help text must still show its status rather than a blank card.
- [ ] Claude without valid CLI credentials retains local token statistics but clearly explains that live subscription limits need sign-in.
- [ ] Codex with its app-server RPC unavailable clearly reports the endpoint problem while retaining local statistics where available.
- [ ] Fireworks without `fundedAmount` still shows token usage and simply omits the balance estimate; this is not presented as a failure.
- [ ] Validate valid collector output with `scripts/agent-usage-doctor`, then check malformed and oversized records do not crash or hang the widget.
- [ ] With sync enabled, two snapshots for the same provider merge day data without duplicate days and retain local-only rate limits.

## Release checks

- [ ] `npm test` passes.
- [ ] Qt 6 `qmllint` reports no Warning or Error lines (Quickshell import Info lines outside Omarchy are expected).
- [ ] `jq empty manifest.json` and `./scripts/check-manifest.sh manifest.json` pass.
- [ ] Use the live checkout/restart workflow above for every meaningful QML batch; do not approve a visual change from lint output alone.
