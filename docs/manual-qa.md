# Manual QA checklist

Run this checklist against the real Omarchy bar before a release. QML is not hot-reloaded: after changing or relinking this plugin, run `omarchy restart shell`. `omarchy-shell shell rescanPlugins` is not enough to load changed QML.

Automated tests cover extracted logic and record validation. They cannot show clipped bar content, a confusing control, or a popup that has become hard to use at a real desktop size.

## Bar

- [ ] With one, two, and three enabled providers that have data and `showInBar: true`, each meter has a readable mark, meter, and percentage. A primary meter with a weekly limit also has the small weekly tick.
- [ ] With four or more eligible providers in `barMode: "all"`, the bar shows at most three full meter groups followed by a `+N` indicator. Hovering it explains that the remaining subscriptions are in the panel; clicking it opens the full provider list rather than creating an inert gap.
- [ ] In `barMode: "primary"`, exactly one eligible meter appears: the marked Primary provider, or the fullest eligible provider when none is marked.
- [ ] In `barMode: "cycle"`, one meter rotates at the configured interval. Middle-click advances it immediately and the next automatic change waits a full interval. Middle-click must not change the panel's selected tab.
- [ ] `showInBar: false` hides only the meter, not the provider's panel tab. `enabled: false` hides it from both and stops collector refreshes for it.
- [ ] When every known provider is hidden from the bar or disabled, the module glyph remains visible and opens settings. On a machine with no discovered record at all, the widget correctly stays absent.
- [ ] Check normal, warn, and critical meter colors at the configured boundaries. They must follow the current Omarchy theme rather than a fixed color, including after a theme change.

## Panel hierarchy and interaction

- [ ] The hero has two distinct outlined actions: gear for Settings and chevron for the all-subscription model view. Their tooltips name the action and its shortcut; `s` toggles Settings and `e` toggles the model view. Opening either closes the other.
- [ ] With several providers, subscription chips stay readable at the panel's normal width. Extra chips scroll horizontally instead of shrinking every provider name into an ambiguous label. `h`/`l` still select every provider.
- [ ] Compact view prioritizes error/help, limits or balance, daily tokens, then model tokens. It should not open scrolled partway down or clip content at 1366x768 and 1920x1080.
- [ ] Expanded view includes the cross-provider model table and the selected provider's 24h/7d/30d/90d chart. Selecting a range only re-slices existing data; it must not run a collector. A range beyond the record's history says so explicitly instead of drawing a misleading chart.
- [ ] Cost records show an `EST. API COST` section labelled as a derived API estimate, never as a bill. When a per-model breakdown is present, its outlined disclosure is visible, toggles open/closed, and remains readable with a long period label and a large dollar value. A record without `cost` leaves no blank separator or empty section.
- [ ] `r` and Enter refresh, `j`/`k` scroll, Tab moves to the neighbouring panel, and Esc closes. Tab can focus the gear, expansion chevron, and cost disclosure; Enter, Space, and Return activate each.

## Settings

- [ ] Open the gear: provider Enabled, Show in bar, and Primary controls do not clip or overlap at the normal panel width. Disabled providers dim the dependent controls. Primary selects only one provider at a time.
- [ ] Switch among All, Primary, and Cycle and verify the copy matches the bar. The cycle interval appears only in Cycle mode and honours 3--120 seconds.
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
