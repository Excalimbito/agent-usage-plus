import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "logic/thresholds.js" as Thresholds
import "logic/format.js" as Format
import "logic/aggregate.js" as Aggregate
import "logic/history.js" as History
import "logic/pace.js" as Pace

Panel {
  id: root
  moduleName: "io.github.viganogabriele.agent-usage-plus"
  ipcTarget: "io.github.viganogabriele.agent-usage-plus"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  // "Warn" sits between foreground and urgent — derived from the two
  // theme-aware colors above (via Qt.tint) rather than a new hardcoded hex,
  // so it keeps adapting to whatever the active Omarchy theme's foreground
  // and urgent colors are.
  readonly property color warn: Qt.tint(foreground, alpha(urgent, 0.55))
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var providers: usage.enabledProviders
  // The bar row only draws providers with showInBar !== false; the panel's
  // chip switcher, provider selection, and empty-state text below all keep
  // using `providers` (enabled-only, unchanged) so a provider hidden from
  // the bar is still reachable from the panel.
  readonly property var barProviders: usage.barProviders
  // "All" should mean all providers are represented, not that an expanding
  // provider set is allowed to consume the entire bar. Three full meter
  // groups still fit beside normal Omarchy widgets; any remaining providers
  // are represented by the explicit +N affordance, whose click falls through
  // to the widget button and opens the complete switcher below.
  readonly property int maxBarProviderSlots: 3
  readonly property var visibleBarProviders: barProviders.slice(0, maxBarProviderSlots)
  readonly property int hiddenBarProviderCount: Math.max(0, barProviders.length - visibleBarProviders.length)
  // The selection follows the provider, not the slot it happens to sit in: a
  // provider whose first scan lands while the panel is open would otherwise
  // shift the list underneath you and swap out what you were reading.
  property string selectedProviderId: ""
  readonly property int providerIndex: {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === selectedProviderId) return i
    return 0
  }
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null

  property bool cursorActive: false

  // Session-only: never written to shell.json, and always false the moment
  // the panel opens (see onOpenedChanged below) — nobody should be surprised
  // by a bigger popup than the one they closed last time.
  //
  // `expanded` (cross-provider data) and `settingsOpen` (the settings form)
  // are mutually exclusive so the panel never has to grow to fit both at
  // once — toggling one closes the other rather than stacking their content.
  property bool expanded: false
  property bool settingsOpen: false
  function toggleExpanded() {
    root.expanded = !root.expanded
    if (root.expanded) root.settingsOpen = false
  }
  function toggleSettings() {
    root.settingsOpen = !root.settingsOpen
    if (root.settingsOpen) root.expanded = false
  }

  // Countdowns and "updated" read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  readonly property var limits: limitWindows(provider)
  readonly property var models: modelRows(provider)
  // Only computed while expanded: collapsed behavior/output must stay
  // exactly what it was before this property existed.
  readonly property var allModels: expanded ? allModelRows(providers) : []
  readonly property var headline: bindingWindow(provider)
  readonly property var balance: provider ? (provider.balance || null) : null
  // Optional, collector-reported "what this would cost at published API
  // rates" estimate (issue #12). Absent for every shipped collector today
  // (Claude, Codex, Fireworks don't report it), so the section built around
  // this stays hidden and the panel renders exactly as before this issue.
  readonly property var cost: provider ? (provider.cost || null) : null
  // Session-only, like `expanded`/`settingsOpen`: whether the "Est. API
  // cost" row's per-model breakdown is unfolded. Reset per provider switch
  // so switching subscriptions doesn't leave a stale breakdown open under
  // a different provider's number.
  property bool costOpen: false

  // ---------------------------------------------------------- history chart
  //
  // Issue #13. Session-only, like `expanded`/`settingsOpen` above — the
  // selector re-slices `provider.recentDays`, which is already sitting in
  // memory from the last refresh, so flipping it never touches
  // usage.runUpdate()/Main.qml's updateProcess. Defaults to "7d" rather
  // than the manifest's 30-day `historyDays` default because a real
  // collector today only ever fills ~7-31 days (see capRecentDays in
  // logic/aggregate.js): defaulting to a range most collectors can satisfy
  // means expanding the panel for the first time shows a chart, not an
  // immediate "not available" message.
  property string historyRangeId: "7d"
  // Only computed while expanded, same reasoning as `allModels` above.
  readonly property var historySeries: (expanded && provider)
    ? History.buildHistorySeries(provider.recentDays || [], History.rangeDaysFor(historyRangeId))
    : null

  function historyUnavailableText(series) {
    if (!series) return ""
    var n = Number(series.availableDays || 0)
    return "History not available beyond " + n + " day" + (n === 1 ? "" : "s")
      + " for this subscription."
  }

  function historyRangeLabel(rangeId) {
    for (var i = 0; i < History.RANGE_OPTIONS.length; i++)
      if (History.RANGE_OPTIONS[i].id === rangeId) return History.RANGE_OPTIONS[i].label
    return rangeId
  }

  function historySeriesTotal(series) {
    if (!series || !series.points) return 0
    var total = 0
    for (var i = 0; i < series.points.length; i++) total += Number(series.points[i].value || 0)
    return total
  }

  // User-configurable warn/critical cutoffs (percentage points, 0-100),
  // read straight from the manifest schema's defaults when unset.
  readonly property int warnThresholdPct: Number(usage.setting("warnThresholdPct", Thresholds.DEFAULT_WARN_PCT))
  readonly property int criticalThresholdPct: Number(usage.setting("criticalThresholdPct", Thresholds.DEFAULT_CRITICAL_PCT))
  readonly property var severityThresholds: ({ warn: warnThresholdPct, critical: criticalThresholdPct })

  // ---------------------------------------------------------------- settings
  //
  // The expanded panel's settings section (issue 08) edits the same settings
  // this file already reads elsewhere (warnThresholdPct/criticalThresholdPct
  // above, refreshIntervalSec on `usage`, per-provider enabled/showInBar).
  // Nothing here writes shell.json directly — every control below calls
  // through to one of usage.set*() in Main.qml, which shells out to
  // `omarchy bar set` (see Main.qml's "settings writes" section).

  function providerSettingEnabled(id) {
    var providers = usage.settings && usage.settings.providers ? usage.settings.providers : {}
    return !providers[id] || providers[id].enabled !== false
  }

  // One line of plain-language context per shipped provider, so someone who
  // has never touched (say) Fireworks can tell what it is from the settings
  // list without leaving the panel. Unknown ids (a third-party collector)
  // get no subtitle rather than a guessed-at description.
  readonly property var providerDescriptions: ({
    claude: "Anthropic's Claude Code CLI — subscription usage and limits.",
    codex: "OpenAI's Codex CLI — subscription usage and limits.",
    fireworks: "Fireworks AI — a separate, prepaid inference account, billed by the token."
  })
  function providerDescription(id) {
    return root.providerDescriptions[id] || ""
  }

  function providerSettingShowInBar(id) {
    var providers = usage.settings && usage.settings.providers ? usage.settings.providers : {}
    return !providers[id] || providers[id].showInBar !== false
  }

  // Unlike enabled/showInBar, `primary` defaults to false/unset — only used
  // by `barMode: "primary"` (issue #5), and only one provider's toggle
  // should ever read true at a time (see usage.setProviderPrimary()).
  function providerSettingPrimary(id) {
    var providers = usage.settings && usage.settings.providers ? usage.settings.providers : {}
    return !!(providers[id] && providers[id].primary === true)
  }

  // One row per provider this machine knows about, whether or not it is
  // currently enabled — `usage.agents` covers every discovered usage record
  // regardless of the `enabled` setting (only `enabledProviders` filters that
  // out), so a disabled provider still gets a row here with its toggle ready
  // to flip back on. Falls back to whatever `providers` already names in
  // settings for an id with no record on disk yet (a collector that was
  // configured but has not written a file, or has been uninstalled).
  readonly property var settingsProviders: {
    var rev = usage.dataRevision
    var seen = ({})
    var rows = []
    var agentsList = usage.agents || []
    for (var i = 0; i < agentsList.length; i++) {
      var record = agentsList[i] ? agentsList[i].record : null
      if (!record || !record.id) continue
      var id = Aggregate.sanitizeProviderId(record.id)
      if (seen[id]) continue
      seen[id] = true
      rows.push({
        providerId: id,
        providerName: String(record.name || record.id),
        enabled: providerSettingEnabled(id),
        showInBar: providerSettingShowInBar(id),
        primary: providerSettingPrimary(id)
      })
    }
    var configured = usage.settings && usage.settings.providers ? usage.settings.providers : {}
    for (var pid in configured) {
      if (seen[pid]) continue
      seen[pid] = true
      rows.push({
        providerId: pid,
        providerName: pid,
        enabled: providerSettingEnabled(pid),
        showInBar: providerSettingShowInBar(pid),
        primary: providerSettingPrimary(pid)
      })
    }
    rows.sort(function(a, b) { return a.providerId < b.providerId ? -1 : (a.providerId > b.providerId ? 1 : 0) })
    return rows
  }

  // `percent` here is the 0-1 fraction used throughout the panel's data
  // model; severityFor works in percentage points, so it's scaled up here.
  function severityForPercent(percent) {
    if (typeof percent !== "number" || !isFinite(percent) || percent < 0) return "ok"
    return Thresholds.severityFor(percent * 100, root.severityThresholds)
  }
  function colorForSeverity(severity) {
    if (severity === "critical") return root.urgent
    if (severity === "warn") return root.warn
    return root.foreground
  }

  // A prepaid account runs low the way a subscription window fills up: the
  // last stretch of the funded credits lights the same alarm as a
  // rate-limit window nearing its cap.
  readonly property real balanceUsedRatio: (!!balance && balance.funded > 0)
    ? (1 - Number(balance.remaining) / Number(balance.funded)) : -1
  readonly property string balanceSeverity: severityForPercent(balanceUsedRatio)
  readonly property string headlineSeverity: headline ? severityForPercent(headline.percent) : "ok"
  // The bar icon and its badge reflect the worse of the headline window and
  // the balance — either one crossing into "critical" should read as
  // critical even if the other is still "ok".
  readonly property string severity: (headlineSeverity === "critical" || balanceSeverity === "critical")
    ? "critical" : ((headlineSeverity === "warn" || balanceSeverity === "warn") ? "warn" : "ok")
  readonly property bool alarming: severity === "critical"
  readonly property bool balanceAlarming: balanceSeverity === "critical"

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = providers[wrapped].providerId
  }

  // Keyboard h/l selection must also reveal the selected chip. Without this,
  // a long provider list could change the data below while leaving the
  // highlight off-screen in the horizontal selector.
  function ensureSelectedChipVisible() {
    if (!providerChipRepeater || providerSwitch.width <= 0) return
    var chip = providerChipRepeater.itemAt(providerIndex)
    if (!chip) return
    var nextX = providerSwitch.contentX
    if (chip.x < nextX) nextX = chip.x
    else if (chip.x + chip.width > nextX + providerSwitch.width)
      nextX = chip.x + chip.width - providerSwitch.width
    providerSwitch.contentX = clamp(nextX, 0, Math.max(0, providerSwitch.contentWidth - providerSwitch.width))
  }

  // Opening a specific provider's bar group should show that provider, not
  // whatever was last selected. Only a click opens it; closing only ever
  // happens explicitly (click outside, Esc, or clicking the widget again).
  function openProvider(p) {
    if (p) selectedProviderId = p.providerId
    open()
  }

  function refreshNow() {
    usage.refreshAll(true)
  }

  function launchAgent() {
    if (root.bar) root.bar.run("omarchy-agent --pick")
    root.close()
  }

  // ---------------------------------------------------------------- limits
  //
  // Both providers report the same two shapes: a short rolling session window
  // and a long weekly one. Everything below normalizes them into one record so
  // the meters and the hero speak a single language.

  // Claude spells its windows out ("Session (5-hour)"), Codex abbreviates
  // them ("5h window", "30m window"). Both have to land on the same record.
  function windowIsLong(text) {
    return text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0 || text.indexOf("seven") >= 0
      || text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0
  }

  function windowSpanMs(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0) return 30 * 24 * 3600 * 1000
    if (windowIsLong(text)) return 7 * 24 * 3600 * 1000
    var hours = text.match(/(\d+)\s*-?\s*h(?:our)?\b/)
    if (hours) return Number(hours[1]) * 3600 * 1000
    var minutes = text.match(/(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b/)
    if (minutes) return Number(minutes[1]) * 60 * 1000
    return 0
  }

  function windowTitle(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0) return "Monthly"
    if (windowIsLong(text)) return "Weekly"
    if (text.indexOf("session") >= 0 || windowSpanMs(label) > 0) return "Session"
    var plain = String(label || "").replace(/\s*\(.*\)\s*/, "").trim()
    return plain === "" ? "Limit" : plain
  }

  // A collector that already knows which window a limit belongs to says so,
  // and that beats reading it back out of the label: a model-scoped limit is
  // titled after its model, and a name like "Opus 5 (1M context)" would parse
  // as a one-minute window.
  function limitWindow(label, percent, resetAt, title, startedAt, tokenLimit) {
    return {
      title: String(title || "") !== "" ? String(title) : windowTitle(label),
      percent: Number(percent),
      resetAt: String(resetAt || ""),
      startedAt: String(startedAt || ""),
      tokenLimit: Number(tokenLimit || 0)
    }
  }

  function limitWindows(p) {
    if (!p) return []
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var percent = Number(entry.percent)
      if (percent >= 0) out.push(limitWindow(entry.label, percent, entry.resetsAt, entry.title, entry.startedAt, entry.tokenLimit))
    }
    return out
  }

  // The window that decides how much room is left — the fullest one, since
  // that is what stops the next prompt.
  function bindingWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      if (!best || windows[i].percent > best.percent) best = windows[i]
    }
    return best
  }

  function resetMsFor(w) {
    if (!w || w.resetAt === "") return -1
    var ms = new Date(w.resetAt).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  function formatDuration(ms) {
    return Format.formatDuration(ms)
  }

  // ---------------------------------------------------------------- balance
  //
  // Prepaid agents report a credit ledger instead of rate-limit windows: the
  // record's balance object carries remaining, funded, and spent amounts.

  function formatMoney(value, currency) {
    return Format.formatMoney(value, currency)
  }

  // ------------------------------------------------------------------ cost
  //
  // Optional collector-reported "what this would cost at published API
  // rates" estimate (issue #12) — a derived figure, never a real bill.

  function formatUsd(value) {
    return Format.formatUsd(value)
  }

  function toggleCost() {
    root.costOpen = !root.costOpen
  }

  function balanceDetailText(b) {
    if (!b || !(b.funded > 0)) return ""
    var text = formatMoney(b.spent, b.currency) + " spent of " + formatMoney(b.funded, b.currency) + " funded"
    if (b.estimated) text += " · estimated"
    return text
  }

  // ---------------------------------------------------------------- content

  // The plan you pay for, under the name of the tool it pays for. Limits live
  // in their own section; the hero just says what this is.
  function heroMeta(p) {
    if (!p) return ""
    if (String(p.usageStatusText || "") !== "") return p.usageStatusText
    var tier = String(p.tierLabel || "")
    if (tier === "") return "Subscription"
    return tier.charAt(0).toUpperCase() + tier.slice(1)
  }

  // Local calendar date, recomputed from nowMs so a panel left open across
  // midnight moves the "Today" row with the clock.
  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
  }

  function dayLabel(date, today) {
    if (today) return "Today"
    return dayName(date)
  }

  // The switch deliberately gives every provider the same hit target. A
  // plain Text inside qs.Ui.Button does not elide by itself, so cap its
  // visible label here instead of letting a long collector-supplied name
  // bleed into the next chip. The full name remains the hero title when the
  // chip is selected.
  function providerChipLabel(provider) {
    var name = String(provider && provider.providerName || "")
    return name.length > 14 ? name.slice(0, 13) + "…" : name
  }

  function dayTooltip(day, today) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    var text = label + " · " + usage.formatTokenCount(Number(day.messageCount || 0)) + " tokens"
    // Prompt and session counts only exist for today, so they ride along here
    // instead of taking a section of their own. Billing-API agents never
    // count prompts, and "0 prompts" would read as a quiet day, not a gap.
    if (today && provider && provider.hasPromptStats !== false)
      text += " · " + Number(provider.todayPrompts || 0) + " prompts · "
        + Number(provider.todaySessions || 0) + " sessions"
    return text
  }

  function weekPeak(p) {
    var days = p ? (p.recentDays || []) : []
    var peak = 0
    for (var i = 0; i < days.length; i++) peak = Math.max(peak, Number(days[i].messageCount || 0))
    return peak
  }

  // Shared by the per-provider "TOKENS BY MODEL" section and the expanded
  // view's cross-provider one below — both start from a modelId -> token
  // bucket map, they just build it differently (one provider's modelUsage
  // vs. Aggregate.allProviderModelUsage's combined map across every
  // enabled provider).
  function modelUsageRows(usageByModel, limit) {
    var rows = []
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      var input = Number(bucket.inputTokens || 0)
      var output = Number(bucket.outputTokens || 0)
      var cacheRead = Number(bucket.cacheReadInputTokens || 0)
      var cacheWrite = Number(bucket.cacheCreationInputTokens || 0)
      rows.push({
        name: usage.friendlyModelName(id),
        total: input + output + cacheRead + cacheWrite,
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite
      })
    }
    rows.sort(function(a, b) { return b.total - a.total })
    return rows.slice(0, limit || 4)
  }

  function modelRows(p) {
    return modelUsageRows(p ? (p.modelUsage || {}) : {}, 4)
  }

  // Every enabled provider's models in one table, not just the currently
  // selected chip's — only computed/rendered when the panel is expanded.
  // A generous cap (12) since it spans every subscription at once.
  function allModelRows(providerList) {
    return modelUsageRows(Aggregate.allProviderModelUsage(providerList), 12)
  }

  function modelTooltip(row) {
    if (!row) return ""
    return "In " + usage.formatTokenCount(row.input)
      + " · out " + usage.formatTokenCount(row.output)
      + " · cache read " + usage.formatTokenCount(row.cacheRead)
      + " · cache write " + usage.formatTokenCount(row.cacheWrite)
  }

  // Only speaks up when the numbers cover more than this machine.
  function footerText() {
    if (usage.syncStatusText !== "") return usage.syncStatusText
    if (provider && provider.syncEnabled && provider.syncDeviceCount > 0)
      return "Merged from " + provider.syncDeviceCount + " device" + (provider.syncDeviceCount === 1 ? "" : "s")
    return ""
  }

  // Agents that ship a white mark carry an `assets/<id>-light.svg` twin for
  // light surfaces; marks that work on both (Claude's brand-orange) ship one
  // file. The luminance check decides which candidate to try first.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  // Marks resolve by convention, so a new agent's data file needs nothing
  // from this panel: assets/<id>.svg if it ships one, the module's bar glyph
  // if it doesn't.
  //
  // providerId ultimately comes from a usage record's "id" field (or, when
  // synced, a key inside another machine's snapshot file) and Main.qml's
  // sanitizeProviderId() already restricts it to [A-Za-z0-9_-] before it
  // reaches here — but this is exactly the string that gets concatenated
  // into a resource URL, so it is re-validated at the point of use rather
  // than trusted to have gone through the right upstream function.
  function iconCandidatesForProvider(p, surfaceColor) {
    if (!p) return []
    var id = String(p.providerId || "")
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(id)) return []
    var candidates = []
    if (colorLuminance(surfaceColor || Color.background) >= 0.5)
      candidates.push(Qt.resolvedUrl("assets/" + id + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + id + ".svg"))
    return candidates
  }

  // Nothing to report, nothing in the bar: Bar.qml collapses a slot whose item
  // is invisible, so the icon appears the moment the first scan finds usage and
  // stays away entirely on a machine that has never run either CLI.
  //
  // "Nothing to report" is judged against every *discovered* provider
  // (`settingsProviders`), not just the enabled ones: a machine with real
  // collectors that the user has since disabled everywhere still has a
  // plugin to manage, and it must stay reachable — otherwise turning every
  // provider off from the in-panel settings (issue 08) locks the settings
  // themselves behind a bar icon that no longer exists. A machine that has
  // never produced a single usage record still collapses out entirely.
  // Extra breathing room on both sides so this widget doesn't sit flush
  // against its bar neighbors the way a plain icon slot would.
  readonly property real outerPadding: Style.space(10)

  visible: providers.length > 0 || root.settingsProviders.length > 0
  implicitWidth: Math.max(button.implicitWidth, providersRow.implicitWidth) + outerPadding * 2
  implicitHeight: button.implicitHeight

  // Bar.qml reads this to size the little "panel is open" underline mark —
  // without it, it defaults to ~55% of the slot's width. Full width here so
  // the mark runs the whole span, Claude through Codex, not just a sliver.
  readonly property real openPanelIndicatorWidth: implicitWidth

  onProviderIndexChanged: {
    if (panelFlick) panelFlick.contentY = 0
    costOpen = false
    Qt.callLater(root.ensureSelectedChipVisible)
  }
  onOpenedChanged: if (opened) {
    cursorActive = false
    expanded = false
    settingsOpen = false
    costOpen = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    usage.refreshLimits()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: usage
    settings: root.settings
    moduleId: root.moduleName
  }

  // Cheap enough to keep running: it only re-evaluates text bindings, and a
  // stale "resets in 2h" on a panel that is open is worse than a timer.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.selectProvider(root.providerIndex + 1); return "ok" }
  }

  // The provider's primary window: session when it reports one (Claude),
  // otherwise whatever it does report (Codex today: just weekly).
  function providerPrimaryWindow(p) {
    if (!p) return null
    var windows = limitWindows(p)
    for (var i = 0; i < windows.length; i++) if (windows[i].title === "Session") return windows[i]
    return windows.length > 0 ? windows[0] : null
  }

  // Per-provider percent, independent of which one is selected for the
  // popup — the bar shows every enabled subscription at once, not just the
  // one the panel currently has open.
  function providerPercent(p) {
    var w = providerPrimaryWindow(p)
    if (w && w.percent >= 0) return w.percent
    if (p && p.balance && p.balance.funded > 0) return 1 - p.balance.remaining / p.balance.funded
    return -1
  }
  function providerSeverity(p) { return root.severityForPercent(providerPercent(p)) }
  function providerPercentText(p) {
    var pct = providerPercent(p)
    return pct >= 0 ? Format.formatPercent(pct) : "…"
  }

  // The weekly percent, when the bar's already showing session as the
  // primary number — drawn as a tick on the same meter rather than a
  // second bar, so seeing both costs a couple of pixels, not double width.
  function providerSecondaryPercent(p) {
    if (!p) return -1
    var primary = providerPrimaryWindow(p)
    if (!primary || primary.title !== "Session") return -1
    var windows = limitWindows(p)
    for (var i = 0; i < windows.length; i++) if (windows[i].title === "Weekly") return windows[i].percent
    return -1
  }

  // A wide track with faint ticks at the quarter marks, so the fill reads
  // as "about two thirds of the way there" rather than an unscaled smear.
  component CheckpointMeter: Item {
    id: checkpointMeter
    property real value: -1
    property string severity: "ok"
    // A second percent, drawn as a small marker sticking past the track
    // rather than a whole extra bar — e.g. the weekly percent riding on
    // the session meter, so both numbers show without doubling the width.
    property real secondaryValue: -1
    readonly property real trackThickness: Math.max(Style.space(5), Math.round(Style.spacing.controlHeight * 0.18))

    implicitHeight: trackThickness

    Rectangle {
      id: checkpointTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: checkpointTrack.left
      anchors.verticalCenter: checkpointTrack.verticalCenter
      height: checkpointTrack.height
      radius: checkpointTrack.radius
      width: checkpointTrack.width * root.clamp(checkpointMeter.value, 0, 1)
      color: root.colorForSeverity(checkpointMeter.severity)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Repeater {
      model: [0.25, 0.5, 0.75]

      Rectangle {
        required property real modelData
        x: Math.round(checkpointTrack.width * modelData) - width / 2
        y: 0
        width: 1
        height: checkpointTrack.height
        color: root.alpha(root.surface, 0.55)
      }
    }

    Rectangle {
      visible: checkpointMeter.secondaryValue >= 0
      x: Math.round(checkpointTrack.width * root.clamp(checkpointMeter.secondaryValue, 0, 1)) - width / 2
      y: -3
      width: 3
      radius: 1
      height: checkpointTrack.height + 6
      color: Color.accent
      border.width: 1
      border.color: root.surface
    }
  }

  // Provider's brand mark at bar scale, with the same asset-then-glyph
  // fallback chain the panel's hero uses, so Claude and Codex read apart at
  // a glance instead of both being an unlabeled bar.
  component ProviderMark: Item {
    id: providerMark
    required property var provider
    property var candidates: root.iconCandidatesForProvider(provider, root.surface)
    property string candidatesKey: candidates.join("\n")
    property int candidateIndex: 0
    onCandidatesKeyChanged: candidateIndex = 0

    width: Style.font.body
    height: Style.font.body

    Image {
      id: markImage
      anchors.fill: parent
      source: providerMark.candidateIndex < providerMark.candidates.length ? providerMark.candidates[providerMark.candidateIndex] : ""
      sourceSize.width: Style.font.body * 2
      sourceSize.height: Style.font.body * 2
      fillMode: Image.PreserveAspectFit
      onStatusChanged: if (status === Image.Error && providerMark.candidateIndex < providerMark.candidates.length)
        Qt.callLater(function() { providerMark.candidateIndex++ })
    }

    Text {
      anchors.centerIn: parent
      visible: markImage.status !== Image.Ready
      text: providerMark.provider ? providerMark.provider.providerId.charAt(0).toUpperCase() : ""
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // WidgetButton owns clicks, hover tooltip, and bar registration for the
  // whole slot; providersRow below draws the visible label+meter per
  // provider on top of it.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱚣"
    // The per-provider meters in providersRow draw on top of this button
    // and normally are the only visible content — but when every provider
    // is enabled-but-hidden-from-bar (or the discovered set is enabled with
    // nothing yet to report), providersRow's model is empty and, with the
    // label suppressed, the slot would render as an invisible-but-clickable
    // gap: present enough to keep the panel reachable (see `visible` above)
    // but with no visual sign it's there. Fall back to this module's own
    // glyph whenever there's no per-provider content to show instead.
    labelVisible: root.barProviders.length === 0
    active: root.alarming
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.launchAgent()
      // In "cycle" mode, middle-click manually advances which single
      // provider the BAR shows (usage.cycleNext(), a new index — see
      // Main.qml) instead of the panel's own chip-selection index; the two
      // are deliberately kept separate (see barCycleIndex's comment).
      else if (buttonCode === Qt.MiddleButton) {
        if (usage.barMode === "cycle") usage.cycleNext()
        else root.selectProvider(root.providerIndex + 1)
      }
      else root.toggle()
    }
  }

  // Up to three label+meter pairs per enabled, reporting, showInBar-visible
  // provider sit side by side. Further providers are represented by +N below
  // rather than making the bar progressively wider as support grows.
  Row {
    id: providersRow
    anchors.centerIn: button
    spacing: Style.space(12)

    Repeater {
      id: providersRepeater
      model: root.visibleBarProviders

      // Plain Item, not a Row: the click target below needs its own
      // width/height for Bar's hit-test, which a Row-positioned child
      // can't carry alongside anchors.
      Item {
        id: providerGroup
        required property var modelData
        implicitWidth: groupContent.implicitWidth
        implicitHeight: groupContent.implicitHeight

        Row {
          id: groupContent
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(5)

          ProviderMark {
            anchors.verticalCenter: parent.verticalCenter
            provider: providerGroup.modelData
          }

          CheckpointMeter {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(48)
            value: root.providerPercent(providerGroup.modelData)
            secondaryValue: root.providerSecondaryPercent(providerGroup.modelData)
            severity: root.providerSeverity(providerGroup.modelData)
            visible: root.providerPercent(providerGroup.modelData) >= 0
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.providerPercentText(providerGroup.modelData)
            color: root.colorForSeverity(root.providerSeverity(providerGroup.modelData))
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // Bar.qml dispatches every module click itself (for drag-to-reorder
        // support) and only ever hands it to a *registered* WidgetButton —
        // a plain MouseArea here is never consulted, no matter its z. This
        // has to be a WidgetButton so registerClickTarget() picks it up as
        // its own target, distinct from the whole-slot `button` below.
        WidgetButton {
          id: providerClickTarget
          anchors.fill: parent
          bar: root.bar
          hasVisualContent: true
          text: ""
          labelVisible: false
          onPressed: function(buttonCode) {
            if (buttonCode === Qt.RightButton) root.launchAgent()
            else if (buttonCode === Qt.MiddleButton) {
              if (usage.barMode === "cycle") usage.cycleNext()
              else root.selectProvider(root.providerIndex + 1)
            }
            else root.openProvider(providerGroup.modelData)
          }
        }
      }
    }

    Item {
      visible: root.hiddenBarProviderCount > 0
      implicitWidth: overflowText.implicitWidth
      implicitHeight: overflowText.implicitHeight

      Text {
        id: overflowText
        anchors.verticalCenter: parent.verticalCenter
        text: "+" + root.hiddenBarProviderCount
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      // This needs its own registered target just like a meter group. The
      // outer WidgetButton is visually behind the row and is not guaranteed
      // to receive a hit through every bar implementation.
      WidgetButton {
        anchors.fill: parent
        bar: root.bar
        hasVisualContent: true
        text: ""
        labelVisible: false
        onPressed: function(buttonCode) {
          if (buttonCode === Qt.RightButton) root.launchAgent()
          else root.toggle()
        }
      }

      MouseArea {
        id: overflowHover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
      }

      PanelToolTip {
        visible: overflowHover.containsMouse
        text: root.hiddenBarProviderCount + " more subscription"
          + (root.hiddenBarProviderCount === 1 ? "" : "s") + " — click to open the full list"
        fontFamily: root.fontFamily
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Taller than the control panels on purpose: this one is a dashboard, and
    // the whole point is reading limits and history without scrolling.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectProvider(root.providerIndex + dx)
        }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshNow()
        else if (t === "e" || t === "E") root.toggleExpanded()
        else if (t === "s" || t === "S") root.toggleSettings()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero: provider mark · name · plan ----------
          PanelHero {
            id: hero
            visible: !!root.provider
            width: parent.width
            title: root.provider ? root.provider.providerName : ""
            meta: root.heroMeta(root.provider)
            foreground: root.foreground
            fontFamily: root.fontFamily

            // Two distinct, separately-labeled controls rather than one
            // overloaded toggle: the gear opens the settings form (issue
            // 08), the chevron reveals the cross-provider data section
            // (issue 07). They're mutually exclusive (see toggleExpanded/
            // toggleSettings) so opening one never leaves the other's
            // content stacked underneath, taking up scroll height nobody
            // asked to see.
            trailingControl: Component {
              Row {
                spacing: Style.space(4)

                PanelActionButton {
                  iconText: "󰒓"
                  tooltipText: root.settingsOpen ? "Close settings (s)" : "Settings (s)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  focusable: true
                  onClicked: root.toggleSettings()
                }

                PanelActionButton {
                  visible: !root.settingsOpen
                  iconText: root.expanded ? "󰅃" : "󰅀"
                  tooltipText: root.expanded ? "Hide model breakdown (e)" : "Show all-subscription model breakdown (e)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  focusable: true
                  onClicked: root.toggleExpanded()
                }
              }
            }

            iconComponent: Component {
              Item {
                id: heroMark
                property var candidates: root.iconCandidatesForProvider(root.provider, root.surface)
                // Provider objects are rebuilt on every refresh, which churns the
                // array's identity without changing its content. Restart the fallback
                // walk only when the URLs change: re-pointing source at a URL whose
                // load already failed emits no statusChanged, so an identity-only
                // reset would strand the walker on a missing -light twin.
                property string candidatesKey: candidates.join("\n")
                property int candidateIndex: 0
                onCandidatesKeyChanged: candidateIndex = 0

                width: Style.font.display
                height: Style.font.display

                Image {
                  id: heroMarkImage
                  anchors.fill: parent
                  source: heroMark.candidateIndex < heroMark.candidates.length ? heroMark.candidates[heroMark.candidateIndex] : ""
                  sourceSize.width: Style.font.display * 2
                  sourceSize.height: Style.font.display * 2
                  fillMode: Image.PreserveAspectFit
                  // Advancing source from inside its own status change trips the
                  // binding-loop detector; defer the step one tick.
                  onStatusChanged: if (status === Image.Error && heroMark.candidateIndex < heroMark.candidates.length)
                    Qt.callLater(function() { heroMark.candidateIndex++ })
                }

                Text {
                  anchors.centerIn: parent
                  visible: heroMarkImage.status !== Image.Ready
                  text: button.text
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
          }

          Text {
            visible: root.providers.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: "No AI coding subscriptions found.\nAgents show up here once you've used them."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Provider switch ----------
          Flickable {
            id: providerSwitch
            visible: root.providers.length > 1
            width: parent.width
            implicitHeight: providerChipRow.implicitHeight
            height: implicitHeight
            contentWidth: Math.max(width, providerChipRow.implicitWidth)
            contentHeight: height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.HorizontalFlick
            interactive: contentWidth > width

            // Fixed-size, horizontally scrollable chips preserve provider
            // names as coverage grows. The old equal-width row made every
            // name narrower with each added provider, eventually turning the
            // subscription switch into an unlabeled strip of buttons. Cap
            // text at the chip boundary as Button itself does not elide it.
            Row {
              id: providerChipRow
              spacing: Style.spacing.md

              Repeater {
                id: providerChipRepeater
                model: root.providers

                Button {
                  required property var modelData
                  required property int index

                  width: Style.space(120)
                  text: root.providerChipLabel(modelData)
                  selected: index === root.providerIndex
                  hasCursor: root.cursorActive && index === root.providerIndex
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: {
                    root.cursorActive = true
                    root.selectProvider(index)
                  }
                  onHovered: function(isHovered) { if (isHovered) root.cursorActive = true }
                }
              }
            }

            ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }
          }

          // ---------- Status ----------
            BorderSurface {
              visible: !!root.provider && String(root.provider.usageStatusText || "") !== ""
              width: parent.width
              implicitHeight: statusContent.implicitHeight + Style.spacing.xl * 2
              color: root.alpha(root.urgent, 0.10)
              borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
              radius: Style.cornerRadius

              Column {
                id: statusContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(4)

                Text {
                  width: parent.width
                  text: root.provider ? String(root.provider.usageStatusText || "") : ""
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  wrapMode: Text.WordWrap
                }

                Text {
                  visible: text !== ""
                  width: parent.width
                  text: root.provider ? String(root.provider.authHelpText || "") : ""
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
            }

          // ---------- Balance / limits / cost ----------
          PanelSeparator {
            visible: balanceSection.visible || limitsSection.visible || costSection.visible
            foreground: root.foreground
          }

          Column {
            id: balanceSection
            visible: !!root.balance
            width: parent.width
            spacing: Style.space(10)

            // The meter shows what is left, not what is used: a prepaid
            // account drains toward empty rather than filling toward a cap.
            readonly property real ratio: root.balance && root.balance.funded > 0
              ? root.clamp(root.balance.remaining / root.balance.funded, 0, 1)
              : -1

            PanelSectionHeader {
              width: parent.width
              text: "BALANCE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

              Text {
                id: balanceLabel
                text: "Prepaid credits"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: balanceValue
                text: root.balance ? root.formatMoney(root.balance.remaining, root.balance.currency) : ""
                textFormat: Text.PlainText
                color: root.colorForSeverity(root.balanceSeverity)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Meter {
              visible: balanceSection.ratio >= 0
              width: parent.width
              value: balanceSection.ratio
              severity: root.balanceSeverity
            }

            Text {
              visible: text !== ""
              width: parent.width
              text: root.balanceDetailText(root.balance)
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            id: limitsSection
            visible: root.limits.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.limits

              LimitRow {
                required property var modelData
                width: limitsSection.width
                window: modelData
              }
            }
          }

          // ---------- Cost: an optional, collector-reported *estimate* of
          // what usage would cost at published API rates (issue #12). No
          // shipped collector (Claude, Codex, Fireworks) reports `cost`
          // today, so `costSection.visible` is false for all three real
          // fixtures and this whole block renders nothing — zero visual
          // change from before this section existed. Purely additive, same
          // pattern as `expandedSection` above: gated on a property
          // (`root.cost`) that stays null/false until a future collector
          // opts in.
          Column {
            id: costSection
            visible: !!root.cost
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              width: parent.width
              text: "EST. API COST"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            MouseArea {
              width: parent.width
              height: costHeaderRow.implicitHeight
              cursorShape: Qt.PointingHandCursor
              enabled: !!root.cost && root.cost.byModel && root.cost.byModel.length > 0
              onClicked: root.toggleCost()

              Item {
                id: costHeaderRow
                width: parent.width
                implicitHeight: Math.max(costLabel.implicitHeight, costValueText.implicitHeight, costDisclosure.implicitHeight)

                Text {
                  id: costLabel
                  text: "Est. API cost" + (root.cost && root.cost.period ? " (" + root.cost.period + ")" : "")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.left: parent.left
                  anchors.right: costValueText.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                }

                Text {
                  id: costValueText
                  text: root.cost ? root.formatUsd(root.cost.estimateUsd) : ""
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.right: costDisclosure.left
                  anchors.rightMargin: root.cost && root.cost.byModel && root.cost.byModel.length > 0 ? Style.space(6) : 0
                  anchors.verticalCenter: parent.verticalCenter
                }

                // The row has always been clickable when model estimates
                // exist, but nothing on screen said so. A standard disclosure
                // action makes the optional breakdown discoverable and gives
                // it a keyboard target without permanently expanding more
                // vertical content.
                PanelActionButton {
                  id: costDisclosure
                  visible: !!root.cost && root.cost.byModel && root.cost.byModel.length > 0
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: root.costOpen ? "󰅃" : "󰅀"
                  tooltipText: root.costOpen ? "Hide model cost breakdown" : "Show model cost breakdown"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  focusable: true
                  onClicked: root.toggleCost()
                }
              }
            }

            Text {
              width: parent.width
              text: "Derived estimate at published API rates — not a real bill."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              visible: root.costOpen && !!root.cost && root.cost.byModel && root.cost.byModel.length > 0

              Repeater {
                model: (root.costOpen && root.cost) ? root.cost.byModel : []

                Item {
                  required property var modelData
                  width: costSection.width
                  implicitHeight: costModelName.implicitHeight

                  Text {
                    id: costModelName
                    text: usage.friendlyModelName(modelData.model)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: root.formatUsd(modelData.usd)
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }
          }

          // ---------- Usage ----------
          PanelSeparator {
            visible: usageSection.visible
            foreground: root.foreground
          }

          Column {
            id: usageSection
            visible: !!root.provider && root.provider.recentDays && root.provider.recentDays.length > 0
            width: parent.width
            spacing: Style.spacing.md

            readonly property var days: root.provider ? (root.provider.recentDays || []) : []
            readonly property real peak: Math.max(1, root.weekPeak(root.provider))

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY DAY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: usageSection.days

              DayRow {
                required property var modelData
                required property int index

                width: usageSection.width
                day: modelData
                ratio: Number(modelData.messageCount || 0) / usageSection.peak
                // By date, not by position: the Claude stats-cache fallback can
                // hand us a window that stops short of today.
                today: String(modelData.date || "") === root.todayDate()
              }
            }
          }

          // ---------- Models ----------
          PanelSeparator {
            visible: modelSection.visible
            foreground: root.foreground
          }

          Column {
            id: modelSection
            visible: root.models.length > 0
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY MODEL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.models

              ModelRow {
                required property var modelData
                width: modelSection.width
                row: modelData
                // Scaled to the heaviest model, so the top row is always full —
                // the same scale-to-peak the weekly chart uses for its busiest day.
                share: modelData.total / Math.max(1, root.models[0].total)
              }
            }
          }

          // ---------- Expanded: combined view across every enabled
          // provider, not just the currently selected chip. Purely
          // additive — session-only `expanded` defaults to false, so a
          // panel that never toggles it renders identically to before
          // this section existed.
          PanelSeparator {
            visible: root.expanded
            foreground: root.foreground
          }

          Column {
            id: expandedSection
            visible: root.expanded
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY MODEL · ALL SUBSCRIPTIONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.allModels

              ModelRow {
                required property var modelData
                width: expandedSection.width
                row: modelData
                share: modelData.total / Math.max(1, root.allModels[0].total)
              }
            }

            Text {
              visible: root.allModels.length === 0
              width: parent.width
              text: "No model usage yet across enabled subscriptions."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }

          // ---------- History chart (issue 13): a taller, range-selectable
          // view of the same per-day data as the compact "TOKENS BY DAY"
          // table above, for the currently selected provider only. Kept
          // under `expanded` alongside the all-subscriptions model table
          // above — this is data, like that table, not a setting, so it
          // does not share `settingsOpen`'s gate.
          //
          // There is no existing per-provider color anywhere in this panel
          // (ProviderMark falls back to the module's shared glyph/initial,
          // and every meter/bar uses `root.foreground` at varying alpha) so
          // this chart does the same rather than inventing a color scheme
          // the rest of the panel doesn't have. A future per-provider
          // palette, if one is ever added, would apply here too.
          //
          // Drawn as bars-per-day rather than a line/area fill: it is the
          // same visual idiom DayRow above already uses (a bar scaled to
          // the heaviest day), just taller and Canvas-drawn instead of
          // stacked Rectangles, so it reads as more of this panel's house
          // style rather than a new chart type, and it sidesteps needing
          // any curve/spline math in code that qmllint and the test suite
          // can't check.
          PanelSeparator {
            visible: root.expanded
            foreground: root.foreground
          }

          Column {
            id: historySection
            visible: root.expanded
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY DAY · CHART"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: !root.provider
              width: parent.width
              text: "Select a subscription above to see its history."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            // ---------- Range selector: purely a session-only UI-state
            // change over data already in memory (`root.historySeries`
            // just re-slices `provider.recentDays`). It never calls
            // usage.runUpdate() or anything else that reaches Main.qml's
            // updateProcess, so switching ranges never triggers a new
            // collector run.
            Row {
              id: historyRangeRow
              visible: !!root.provider
              width: parent.width
              spacing: Style.spacing.md

              readonly property real cellWidth: History.RANGE_OPTIONS.length > 0
                ? (width - spacing * (History.RANGE_OPTIONS.length - 1)) / History.RANGE_OPTIONS.length
                : 0

              Repeater {
                model: History.RANGE_OPTIONS

                Button {
                  required property var modelData

                  width: historyRangeRow.cellWidth
                  text: modelData.label
                  selected: modelData.id === root.historyRangeId
                  hasCursor: root.cursorActive && modelData.id === root.historyRangeId
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: {
                    root.cursorActive = true
                    root.historyRangeId = modelData.id
                  }
                  onHovered: function(isHovered) { if (isHovered) root.cursorActive = true }
                }
              }
            }

            Text {
              visible: !!(root.historySeries && root.historySeries.ok)
              width: parent.width
              text: root.historySeries
                ? root.historyRangeLabel(root.historyRangeId) + " · "
                  + usage.formatTokenCount(root.historySeriesTotal(root.historySeries)) + " tokens total"
                : ""
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Canvas {
              id: historyCanvas
              visible: !!(root.historySeries && root.historySeries.ok && root.historySeries.points.length > 0)
              width: parent.width
              height: Style.spacing.controlHeight * 2

              property var series: root.historySeries
              property color barColor: root.foreground

              onSeriesChanged: requestPaint()
              onWidthChanged: requestPaint()
              onHeightChanged: requestPaint()
              onBarColorChanged: requestPaint()
              onVisibleChanged: if (visible) requestPaint()

              // Canvas paint code has no lint/type-check coverage the rest
              // of this file gets and a thrown exception here can silently
              // blank the whole panel rather than just this chart — the
              // try/catch is a hard backstop, not decoration, and the
              // early returns keep an empty/single-point series (or a
              // still-resizing width/height of 0) from ever reaching the
              // drawing math below.
              onPaint: {
                var ctx = getContext("2d")
                try {
                  ctx.clearRect(0, 0, width, height)

                  var s = historyCanvas.series
                  if (!s || !s.ok || !s.points || s.points.length === 0) return
                  if (width <= 0 || height <= 0) return

                  var points = s.points
                  var n = points.length
                  var peak = Math.max(1, Number(s.peak) || 0)
                  var gap = n > 1 ? Style.space(3) : 0
                  var barWidth = Math.max(1, (width - gap * (n - 1)) / n)
                  var todayDate = root.todayDate()

                  for (var i = 0; i < n; i++) {
                    var point = points[i] || {}
                    var value = Math.max(0, Number(point.value) || 0)
                    var ratio = Math.min(1, value / peak)
                    // A nonzero day always shows at least a sliver, so a
                    // quiet day never reads as visually identical to a
                    // true zero (gap) day.
                    var barHeight = value > 0 ? Math.max(2, ratio * height) : 0
                    if (barHeight <= 0) continue

                    var x = i * (barWidth + gap)
                    var y = height - barHeight
                    var isToday = String(point.date || "") === todayDate
                    ctx.fillStyle = root.alpha(historyCanvas.barColor, isToday ? 0.85 : 0.5)
                    ctx.fillRect(x, y, barWidth, barHeight)
                  }
                } catch (e) {
                  // Swallow: a chart that fails to draw should leave a
                  // blank strip, not take the rest of the panel down.
                }
              }
            }

            Text {
              visible: !!(root.historySeries && !root.historySeries.ok)
              width: parent.width
              text: root.historyUnavailableText(root.historySeries)
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Settings: the same values `omarchy bar set` edits,
          // editable here without a terminal (issue 08). Gated by its own
          // `settingsOpen` flag (not `expanded`) so opening settings doesn't
          // also force the cross-provider data section into view — the two
          // are mutually exclusive, see toggleSettings(). The settings
          // themselves are obviously not session-only — every control
          // writes through to shell.json.
          PanelSeparator {
            visible: root.settingsOpen
            foreground: root.foreground
          }

          Column {
            id: settingsSection
            visible: root.settingsOpen
            width: parent.width
            spacing: Style.spacing.lg

            PanelSectionHeader {
              width: parent.width
              text: "SETTINGS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // ----- Per-provider enabled / shown in bar -----
            Column {
              width: parent.width
              spacing: Style.space(10)

              Repeater {
                model: root.settingsProviders

                Column {
                  id: providerSettingsRow
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    text: providerSettingsRow.modelData.providerName
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    elide: Text.ElideRight
                    width: parent.width
                  }

                  Text {
                    text: root.providerDescription(providerSettingsRow.modelData.providerId)
                    visible: text !== ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    width: parent.width
                    wrapMode: Text.WordWrap
                  }

                  Flow {
                    width: parent.width
                    spacing: Style.spacing.xl

                    Row {
                      spacing: Style.space(6)

                      ToggleSwitch {
                        id: enabledSwitch
                        anchors.verticalCenter: parent.verticalCenter
                        checked: providerSettingsRow.modelData.enabled
                        foreground: root.foreground
                        accent: Color.accent
                        onToggled: usage.setProviderEnabled(providerSettingsRow.modelData.providerId, !providerSettingsRow.modelData.enabled)
                      }

                      Text {
                        text: "Enabled"
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    // Dimmed and non-interactive while the provider itself
                    // is disabled: "show in bar" has no effect on a
                    // provider that's off entirely, and leaving both
                    // switches independently clickable read as two
                    // contradictory settings instead of one depending on
                    // the other.
                    Row {
                      spacing: Style.space(6)
                      enabled: providerSettingsRow.modelData.enabled
                      opacity: providerSettingsRow.modelData.enabled ? 1.0 : 0.45

                      ToggleSwitch {
                        id: showInBarSwitch
                        anchors.verticalCenter: parent.verticalCenter
                        checked: providerSettingsRow.modelData.showInBar
                        foreground: root.foreground
                        accent: Color.accent
                        onToggled: usage.setProviderShowInBar(providerSettingsRow.modelData.providerId, !providerSettingsRow.modelData.showInBar)
                      }

                      Text {
                        text: "Show in bar"
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    // Only meaningful under `barMode: "primary"` (issue #5),
                    // but left clickable regardless of the current
                    // `barMode` — flipping it now, then switching `barMode`
                    // to "primary" later, should already reflect the choice
                    // rather than requiring the toggle to be re-set.
                    Row {
                      spacing: Style.space(6)
                      enabled: providerSettingsRow.modelData.enabled
                      opacity: providerSettingsRow.modelData.enabled ? 1.0 : 0.45

                      ToggleSwitch {
                        id: primarySwitch
                        anchors.verticalCenter: parent.verticalCenter
                        checked: providerSettingsRow.modelData.primary
                        foreground: root.foreground
                        accent: Color.accent
                        onToggled: usage.setProviderPrimary(providerSettingsRow.modelData.providerId, !providerSettingsRow.modelData.primary)
                      }

                      Text {
                        text: "Primary"
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }
              }

              Text {
                visible: root.settingsProviders.length === 0
                width: parent.width
                text: "No subscriptions discovered yet."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // ----- Bar display mode (issue #5) -----
            Column {
              width: parent.width
              spacing: Style.space(6)

              Text {
                text: "Bar display"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Row {
                id: barModeSwitch
                width: parent.width
                spacing: Style.spacing.md

                readonly property var options: ["all", "primary", "cycle"]
                readonly property var optionLabels: ({ all: "All", primary: "Primary", cycle: "Cycle" })
                readonly property real cellWidth: (width - spacing * (options.length - 1)) / options.length

                Repeater {
                  model: barModeSwitch.options

                  Button {
                    required property var modelData
                    width: barModeSwitch.cellWidth
                    text: barModeSwitch.optionLabels[modelData]
                    selected: usage.barMode === modelData
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    verticalPadding: Style.spacing.controlPaddingY
                    onClicked: usage.setBarMode(modelData)
                  }
                }
              }

              Text {
                width: parent.width
                text: "All: one meter per provider shown in the bar. Primary: one meter — the provider marked Primary above, or the fullest one. Cycle: one meter, rotating automatically."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            // ----- Cycle interval (only meaningful in Cycle mode) -----
            NumberField {
              visible: usage.barMode === "cycle"
              label: "Cycle interval (seconds)"
              value: usage.barCycleIntervalSec
              from: 3
              to: 120
              stepSize: 1
              foreground: root.foreground
              accent: Color.accent
              fontFamily: root.fontFamily
              onModified: function(v) { usage.setBarCycleIntervalSec(v) }
            }

            // ----- Refresh interval -----
            NumberField {
              label: "Refresh interval (seconds)"
              value: usage.refreshIntervalSec
              from: 30
              to: 3600
              stepSize: 30
              foreground: root.foreground
              accent: Color.accent
              fontFamily: root.fontFamily
              onModified: function(v) { usage.setRefreshIntervalSec(v) }
            }

            // ----- Warn / critical thresholds -----
            Column {
              width: parent.width
              spacing: Style.space(6)

              Item {
                width: parent.width
                implicitHeight: warnLabel.implicitHeight

                Text {
                  id: warnLabel
                  text: "Warn threshold"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: root.warnThresholdPct + "%"
                  color: root.warn
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              PanelSlider {
                width: parent.width
                bar: root.bar
                minimum: 1
                maximum: 99
                step: 1
                integer: true
                value: root.warnThresholdPct
                onReleased: function(v) { usage.setWarnThresholdPct(v) }
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              Item {
                width: parent.width
                implicitHeight: criticalLabel.implicitHeight

                Text {
                  id: criticalLabel
                  text: "Critical threshold"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: root.criticalThresholdPct + "%"
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              PanelSlider {
                width: parent.width
                bar: root.bar
                minimum: 1
                maximum: 100
                step: 1
                integer: true
                value: root.criticalThresholdPct
                onReleased: function(v) { usage.setCriticalThresholdPct(v) }
              }
            }

            Text {
              width: parent.width
              text: "Settings write through `omarchy bar set` and apply immediately — no restart needed."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Text {
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // A limit window: label and percentage, meter, and reset countdown.
  component LimitRow: Column {
    id: limitRow
    property var window: null

    readonly property string severity: window ? root.severityForPercent(window.percent) : "ok"
    // Only providers that report an explicit quota get this. A percentage
    // meter alone cannot be turned into a token burn projection honestly.
    readonly property var paceProjection: Pace.projectExhaustion(
      root.provider ? root.provider.recentDays : [], window, window ? window.resetAt : "", root.nowMs)

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        // A model-scoped window is titled after its model, and those names run
        // long enough to reach the percentage, so the title gives way first.
        text: limitRow.window ? limitRow.window.title : ""
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        text: limitRow.window && limitRow.window.percent >= 0
          ? Format.formatPercent(limitRow.window.percent)
          : "—"
        color: root.colorForSeverity(limitRow.severity)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: limitRow.window ? limitRow.window.percent : -1
      severity: limitRow.severity
    }

    Text {
      id: resetText
      width: parent.width
      text: {
        var remainingMs = root.resetMsFor(limitRow.window)
        return remainingMs > 0 ? "Resets in " + root.formatDuration(remainingMs) : ""
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      visible: !!limitRow.paceProjection && limitRow.paceProjection.exhaustsBeforeReset
      width: parent.width
      text: (limitRow.paceProjection && limitRow.paceProjection.exhaustsBeforeReset)
        ? "At this pace: exhausted in " + root.formatDuration(limitRow.paceProjection.untilExhaustionMs) : ""
      textFormat: Text.PlainText
      color: root.colorForSeverity(limitRow.severity)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Rounded track showing the percentage of the allowance used.
  component Meter: Item {
    id: meter
    property real value: -1
    property string severity: "ok"
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: root.colorForSeverity(meter.severity)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

  }

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
      text: root.dayLabel(dayRow.day ? dayRow.day.date : "", dayRow.today)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      text: usage.formatTokenCount(dayRow.day ? Number(dayRow.day.messageCount || 0) : 0)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day, dayRow.today)
      fontFamily: root.fontFamily
    }
  }

  // Model rows read as a table: the share bar fills the row behind the label
  // instead of stacking under it, which keeps the whole dashboard on one screen.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
      text: modelRow.row ? modelRow.row.name : ""
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      text: modelRow.row ? usage.formatTokenCount(modelRow.row.total) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: modelHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: modelHover.containsMouse
      text: root.modelTooltip(modelRow.row)
      fontFamily: root.fontFamily
    }
  }
}
