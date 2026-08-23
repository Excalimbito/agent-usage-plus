import QtQuick
import Quickshell
import Quickshell.Io

// The display side of agent usage. All extraction lives behind
// omarchy-agent-usage-update, which writes one JSON record per agent into
// the usage directory; this file only discovers those records, watches them
// for changes, and optionally merges snapshots synced from other machines.
Item {
  id: root
  visible: false

  property var settings: ({})

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string usageDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/agents/usage"

  // ------------------------------------------------------------- discovery

  property var agentIds: []
  property var agents: []
  property int dataRevision: 0

  // Hard caps on the local usage-directory scan: a file at or above maxAgentFileBytes
  // is excluded before any Agent/FileView is ever created for it, the file count is
  // capped at the shell level (head), and the whole scan is time-boxed. These are the
  // limits requested in the marketplace security review — enforced at the source
  // rather than after the fact.
  readonly property int maxAgentFiles: 500
  readonly property int maxAgentFileBytes: 1048576

  Process {
    id: listProcess
    running: false
    command: ["timeout", "5", "bash", "-c",
      "find \"$1\" -maxdepth 1 -name '*.json' -size -" + root.maxAgentFileBytes + "c -printf '%f\\n' 2>/dev/null | head -n " + root.maxAgentFiles,
      "find-agents", root.usageDir]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyAgentListing(text)
    }
  }

  function rescanAgents() {
    if (!listProcess.running) listProcess.running = true
  }

  function applyAgentListing(output) {
    var ids = []
    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length && ids.length < root.maxAgentFiles; i++) {
      var name = lines[i].trim()
      if (name.slice(-5) === ".json") ids.push(name.slice(0, -5))
    }
    ids.sort()
    // Same list, same objects: reassigning the model would tear down every
    // FileView just to build identical ones.
    if (JSON.stringify(ids) !== JSON.stringify(agentIds)) agentIds = ids
  }

  Instantiator {
    id: agentInstantiator
    model: root.agentIds

    delegate: Agent {
      required property var modelData
      agentId: modelData
      path: root.usageDir + "/" + modelData + ".json"
      onRecordChanged: root.recordsChanged()
    }

    onObjectAdded: (index, object) => root.rebuildAgents()
    onObjectRemoved: (index, object) => root.rebuildAgents()
  }

  function rebuildAgents() {
    var result = []
    for (var i = 0; i < agentInstantiator.count; i++) {
      var agent = agentInstantiator.objectAt(i)
      if (agent) result.push(agent)
    }
    agents = result
    recordsChanged()
  }

  function recordsChanged() {
    dataRevision++
    scheduleLimitsRetry()
    scheduleSync()
  }

  // A collector that could not reach its limits endpoint at all — typically
  // the seconds after login before the network is up — writes retryAdvised
  // into its record. Honor it with one sooner try instead of waiting out the
  // full refresh interval; a run that reaches the endpoint clears the flag.
  // Only the advising agents rerun, so an outage at one provider does not
  // put every other collector on a 30-second treadmill.
  property var retryAgentIds: []

  Timer {
    id: limitsRetry
    interval: 30000
    repeat: false
    onTriggered: root.runUpdate("limits", root.retryAgentIds)
  }

  function scheduleLimitsRetry() {
    var advising = []
    for (var i = 0; i < agents.length; i++) {
      var record = agents[i] ? agents[i].record : null
      if (record && record.retryAdvised === true && providerEnabled(sanitizeProviderId(record.id)))
        advising.push(sanitizeProviderId(record.id))
    }
    retryAgentIds = advising
    if (advising.length > 0) limitsRetry.restart()
    else limitsRetry.stop()
  }

  Component.onCompleted: {
    rescanAgents()
    if (syncConfigured()) scheduleSync()
  }

  // -------------------------------------------------------------- refresh

  property int refreshIntervalSec: Math.max(30, Number(setting("refreshIntervalSec", 900)))
  property string pendingUpdateKind: ""

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.runUpdate("normal")
  }

  Process {
    id: updateProcess
    running: false
    onExited: {
      root.rescanAgents()
      if (root.pendingUpdateKind !== "") {
        var kind = root.pendingUpdateKind
        root.pendingUpdateKind = ""
        root.runUpdate(kind)
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("agents", text.trim())
    }
  }

  function updateCommand(kind, agentIds) {
    // Quickshell's inherited PATH places the packaged Omarchy commands before
    // ~/.local/bin. Use the user-owned collector explicitly so compatibility
    // fixes survive without changing /usr/share/omarchy.
    var command = [home + "/.local/bin/omarchy-agent-usage-update"]
    if (kind === "force") command.push("--force")
    if (kind === "limits") command.push("--limits-only")
    var providers = settings && settings.providers ? settings.providers : {}
    for (var id in providers) {
      if (providers[id] && providers[id].enabled === false) command.push("--except", id)
    }
    if (agentIds) {
      for (var i = 0; i < agentIds.length; i++) command.push(agentIds[i])
    }
    return command
  }

  function runUpdate(kind, agentIds) {
    if (updateProcess.running) {
      // Collapse queued requests to one full rerun; a forced refresh outranks
      // the cheaper kinds it might have been queued behind.
      if (kind === "force" || root.pendingUpdateKind === "") root.pendingUpdateKind = kind
      return
    }
    updateProcess.command = updateCommand(kind, agentIds)
    updateProcess.running = true
  }

  function refresh() { refreshAll(true) }
  function refreshAll(force) { runUpdate(force === true ? "force" : "normal") }

  // Opening the panel wants the numbers that go stale on the wire, not
  // another walk over every transcript on disk — the collectors reuse their
  // recent scans in this mode.
  function refreshLimits() { runUpdate("limits") }

  // ------------------------------------------------------------- providers

  // An agent earns a place in the bar and the panel by being switched on in
  // settings and having actually produced numbers — locally or on a synced
  // device. With nothing to show, the whole module collapses out of the bar
  // rather than sitting there dimmed.
  property var enabledProviders: {
    var rev = dataRevision
    var syncRev = syncRevision
    var result = []
    var localIds = {}
    for (var i = 0; i < agents.length; i++) {
      var record = agents[i] ? agents[i].record : null
      if (!record || !record.id) continue
      var id = sanitizeProviderId(record.id)
      localIds[id] = true
      if (!providerEnabled(id)) continue
      var display = displayProvider(record)
      if (providerHasData(display)) result.push(display)
    }
    // An agent that only ever ran on another machine has no local record, but
    // its synced numbers still deserve a tab. Rate limits stay blank — they
    // are per-account and never travel. aggregateData.providers is already
    // keyed by sanitized id (aggregateSnapshots does this on ingestion), so
    // syncedId here needs no further sanitizing before use as a lookup key —
    // it does still get sanitized again inside displayProvider before it is
    // ever used to build an asset path or a display label.
    var syncedProviders = syncConfigured() && aggregateData && aggregateData.providers ? aggregateData.providers : {}
    var syncedCount = 0
    for (var syncedId in syncedProviders) {
      if (localIds[syncedId] || !providerEnabled(syncedId)) continue
      if (++syncedCount > 50) break
      var stats = syncedProviders[syncedId] || {}
      var syncedDisplay = displayProvider({ id: syncedId, name: stats.providerName || syncedId })
      if (providerHasData(syncedDisplay)) result.push(syncedDisplay)
    }
    return result
  }

  function providerEnabled(id) {
    if (!settings || !settings.providers || !settings.providers[id]) return true
    return settings.providers[id].enabled !== false
  }

  // All-time keeps a quiet day from hiding an agent; today's counts admit a
  // machine whose only source is history.jsonl, which knows nothing older.
  function providerHasData(p) {
    return numberValue(p.totalPrompts) > 0 || numberValue(p.totalSessions) > 0
      || numberValue(p.activeDays) > 0 || numberValue(p.todayPrompts) > 0
      || numberValue(p.todaySessions) > 0 || (p.limits && p.limits.length > 0)
      || !!p.balance
  }

  // A prepaid agent's credit ledger. Like rate limits, the balance is
  // per-account and never merged across devices.
  function balanceValue(raw) {
    if (!raw || typeof raw !== "object") return null
    var remaining = Number(raw.remaining)
    var funded = Number(raw.funded)
    if (!isFinite(remaining) || remaining < 0) return null
    return {
      remaining: remaining,
      funded: isFinite(funded) && funded > 0 ? funded : 0,
      spent: Math.max(0, Number(raw.spent) || 0),
      currency: sanitizeDisplayText(raw.currency || "USD", 10),
      estimated: raw.estimated === true
    }
  }

  function displayProvider(record) {
    var providerId = sanitizeProviderId(record.id)
    var stats = syncedStatsFor(providerId)
    var synced = !!stats
    var deviceCount = synced ? Number(stats.deviceCount || aggregateData.deviceCount || 0) : 0

    return {
      providerId: providerId,
      providerName: sanitizeDisplayText(record.name || record.id, 80),
      ready: record.ready === true || synced,
      usageStatusText: sanitizeDisplayText(record.usageStatusText, 200),
      authHelpText: sanitizeDisplayText(record.authHelpText, 300),

      // Rate limits and balances stay per-account and are never merged
      // across devices.
      limits: sanitizeLimits(record.limits),
      tierLabel: sanitizeDisplayText(record.tierLabel, 60),
      balance: balanceValue(record.balance),

      todayPrompts: synced ? numberValue(stats.todayPrompts) : numberValue(record.todayPrompts),
      todaySessions: synced ? numberValue(stats.todaySessions) : numberValue(record.todaySessions),
      todayTotalTokens: synced ? numberValue(stats.todayTotalTokens) : numberValue(record.todayTotalTokens),
      todayTokensByModel: synced ? capModelUsage(stats.todayTokensByModel) : capModelUsage(record.todayTokensByModel),
      recentDays: synced ? capRecentDays(stats.recentDays) : capRecentDays(record.recentDays),
      totalPrompts: synced ? numberValue(stats.totalPrompts) : numberValue(record.totalPrompts),
      totalSessions: synced ? numberValue(stats.totalSessions) : numberValue(record.totalSessions),
      activeDays: synced ? numberValue(stats.activeDays) : numberValue(record.activeDays),
      modelUsage: synced ? capModelUsage(stats.modelUsage) : capModelUsage(record.modelUsage),
      hasLocalStats: synced ? (stats.hasLocalStats !== false) : (record.hasLocalStats !== false),
      hasPromptStats: synced ? (stats.hasPromptStats !== false) : (record.hasPromptStats !== false),

      syncEnabled: synced,
      syncDeviceCount: deviceCount,
      syncUpdatedAt: aggregateData && aggregateData.updatedAt ? aggregateData.updatedAt : ""
    }
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // ------------------------------------------------------------------ sync

  property var syncModeSetting: setting("syncMode", setting("syncEnabled", false))
  property bool syncEnabled: parseSyncEnabled(syncModeSetting)
  property string syncDir: String(setting("syncDir", ""))
  property string syncFileName: String(setting("syncFileName", ""))
  property string syncDeviceId: String(setting("syncDeviceId", ""))
  property string detectedHostname: ""
  readonly property string syncEffectiveDir: expandPath(syncDir)
  readonly property string syncEffectiveFileName: safeSnapshotFileName(syncFileName, syncDeviceId)
  readonly property string syncEffectiveDeviceId: safeDeviceId(syncDeviceId || syncEffectiveFileName.replace(/\.json$/i, ""))
  readonly property string syncSnapshotPath: syncConfigured() ? syncEffectiveDir + "/" + syncEffectiveFileName : home + "/.cache/omarchy/agents-disabled.json"
  property var aggregateData: ({})
  property int syncRevision: 0
  property bool syncRunning: false
  property bool syncRequestedWhileRunning: false
  property string syncStatusText: ""
  property double aggregateUpdatedAtMs: aggregateData && aggregateData.updatedAtMs ? Number(aggregateData.updatedAtMs) : 0

  onSyncEnabledChanged: syncSettingsChanged()
  onSyncDirChanged: syncSettingsChanged()
  onSyncFileNameChanged: if (syncConfigured()) scheduleSync()
  onSyncDeviceIdChanged: if (syncConfigured()) scheduleSync()

  Timer {
    id: syncDebounce
    interval: 1000
    repeat: false
    onTriggered: root.runSync()
  }

  Process {
    id: syncMkdirProcess
    running: false
    onRunningChanged: root.updateSyncRunning()
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        if (root.syncConfigured()) root.syncStatusText = "Usage sync mkdir failed"
        root.finishSyncRun()
        return
      }
      root.writeSyncSnapshot()
    }
  }

  Process {
    id: syncScanProcess
    running: false
    onRunningChanged: root.updateSyncRunning()
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.syncConfigured()) root.syncStatusText = "Usage sync scan failed"
      root.finishSyncRun()
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseSyncScanOutput(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("agents/sync", text.trim())
    }
  }

  FileView {
    id: syncSnapshotFile
    path: root.syncSnapshotPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  FileView {
    id: hostnameFile
    path: "/etc/hostname"
    watchChanges: false
    printErrors: false
    onLoaded: root.detectedHostname = String(text() || "").trim()
  }

  function parseSyncEnabled(value) {
    if (value === true) return true
    var text = String(value || "").trim().toLowerCase()
    return text === "on" || text === "enabled" || text === "true" || text === "yes" || text === "1"
  }

  function syncConfigured() {
    return root.syncEnabled === true && String(root.syncDir || "").trim() !== ""
  }

  function syncSettingsChanged() {
    if (syncConfigured()) {
      scheduleSync()
    } else {
      syncDebounce.stop()
      syncRequestedWhileRunning = false
      aggregateData = ({})
      syncStatusText = ""
      syncRevision++
    }
  }

  function updateSyncRunning() {
    root.syncRunning = syncMkdirProcess.running || syncScanProcess.running
  }

  function scheduleSync() {
    if (!syncConfigured()) return
    syncDebounce.restart()
  }

  function runSync() {
    if (!syncConfigured()) return
    if (root.syncRunning) {
      syncRequestedWhileRunning = true
      return
    }

    syncRequestedWhileRunning = false
    syncStatusText = ""
    syncMkdirProcess.command = ["mkdir", "-p", root.syncEffectiveDir]
    syncMkdirProcess.running = true
  }

  function writeSyncSnapshot() {
    if (!syncConfigured()) {
      finishSyncRun()
      return
    }
    syncSnapshotFile.setText(JSON.stringify(localSnapshot(), null, 2) + "\n")
    Qt.callLater(root.startSyncScan)
  }

  // Caps on the sync-directory scan: snapshots come from other machines over
  // whatever transport backs the configured sync directory, so none of it is
  // trusted. At most maxSyncSnapshots files are read, each truncated to
  // maxSyncSnapshotBytes, the whole concatenated output is capped again, and
  // the scan itself is time-boxed — limits enforced in the shell pipeline
  // itself, before any of it reaches QML.
  readonly property int maxSyncSnapshots: 50
  readonly property int maxSyncSnapshotBytes: 262144
  readonly property int maxSyncScanOutputBytes: 20971520

  function startSyncScan() {
    if (!syncConfigured()) {
      finishSyncRun()
      return
    }
    var script = "dir=$0; [[ -d \"$dir\" ]] || exit 0; shopt -s nullglob;"
      + " { n=0; for f in \"$dir\"/*.json; do [[ -f \"$f\" ]] || continue;"
      + " n=$((n+1)); [[ $n -le " + root.maxSyncSnapshots + " ]] || break;"
      + " printf '===%s===\\n' \"$f\"; head -c " + root.maxSyncSnapshotBytes + " \"$f\";"
      + " printf '\\n=== EOM ===\\n'; done; } | head -c " + root.maxSyncScanOutputBytes
    syncScanProcess.command = ["timeout", "10", "bash", "-c", script, root.syncEffectiveDir]
    syncScanProcess.running = true
  }

  function finishSyncRun() {
    if (syncRequestedWhileRunning && syncConfigured()) {
      syncRequestedWhileRunning = false
      scheduleSync()
    }
  }

  function expandPath(path) {
    var value = String(path || "").trim()
    if (value === "") return ""
    if (value === "~") return home
    if (value.indexOf("~/") === 0) return home + value.substring(1)
    if (value.indexOf("$HOME/") === 0) return home + value.substring(5)
    if (value.charAt(0) !== "/") return home + "/" + value
    return value
  }

  function safeDeviceId(raw) {
    var value = String(raw || "").trim()
    if (value === "") value = Quickshell.env("HOSTNAME") || root.detectedHostname || Quickshell.env("HOST") || Quickshell.env("USER") || "device"
    value = value.replace(/[^A-Za-z0-9_.-]+/g, "-").replace(/^[._-]+|[._-]+$/g, "")
    if (value === "") value = "device"
    return value.length > 80 ? value.substring(0, 80) : value
  }

  function safeSnapshotFileName(rawFileName, rawDeviceId) {
    var value = String(rawFileName || "").trim()
    if (value === "") value = safeDeviceId(rawDeviceId) + ".json"
    value = value.split("/").pop().replace(/[^A-Za-z0-9_.-]+/g, "-").replace(/^[._-]+|[._-]+$/g, "")
    if (value === "") value = safeDeviceId(rawDeviceId) + ".json"
    if (!/\.json$/i.test(value)) value += ".json"
    return value.length > 100 ? value.substring(0, 95) + ".json" : value
  }

  function parseSyncScanOutput(output) {
    var lines = String(output || "").split("\n")
    var snapshots = []
    var currentPath = ""
    var currentJson = []

    function flush() {
      if (currentPath === "") return
      if (snapshots.length >= root.maxSyncSnapshots) return
      var raw = currentJson.join("\n").trim()
      try {
        var parsed = JSON.parse(raw)
        if (parsed && parsed.providers) snapshots.push(parsed)
      } catch (e) {
        console.warn("agents/sync", "Ignoring bad snapshot", currentPath, e)
      }
      currentPath = ""
      currentJson = []
    }

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var start = line.match(/^===(.+)===$/)
      if (start && line !== "=== EOM ===") {
        flush()
        currentPath = start[1]
        currentJson = []
        continue
      }
      if (line === "=== EOM ===") {
        flush()
        continue
      }
      if (currentPath !== "") currentJson.push(line)
    }
    flush()

    aggregateData = aggregateSnapshots(snapshots)
    syncStatusText = ""
    syncRevision++
  }

  function cloneValue(value, fallback) {
    if (value === undefined || value === null) return fallback
    try {
      return JSON.parse(JSON.stringify(value))
    } catch (e) {
      return fallback
    }
  }

  function numberValue(value) {
    var n = Number(value || 0)
    return isFinite(n) ? Math.round(n) : 0
  }

  // ---------------------------------------------------------- untrusted input
  //
  // Everything below sanitizes values that ultimately come from a usage
  // record or a synced snapshot — content this module never generated and,
  // in the synced case, never even generated on this machine. All of it can
  // reach native QML Text/Button/Image sinks in Panel.qml, most of which are
  // shared Omarchy components this plugin doesn't own and can't set
  // textFormat on directly. Neutralizing the risky characters and capping
  // sizes here, once, covers every sink at once.

  // A provider id feeds straight into an asset path (Qt.resolvedUrl("assets/"
  // + id + ".svg")) in Panel.qml, so it must never contain path separators or
  // traversal segments — restrict it to a safe, filename-like charset.
  function sanitizeProviderId(raw) {
    var value = String(raw || "").trim()
    value = value.replace(/[^A-Za-z0-9_-]+/g, "-").replace(/^[-_.]+|[-_.]+$/g, "")
    if (value === "") value = "agent"
    return value.length > 64 ? value.substring(0, 64) : value
  }

  // Strips control characters and the characters QML's rich-text detection
  // keys off of (`<`, `>`, `&`), so a record can't get itself rendered as
  // markup regardless of which Text/Button component ends up displaying it.
  // Also caps length so one field can't blow up a panel's layout.
  function sanitizeDisplayText(raw, maxLen) {
    var text = raw === undefined || raw === null ? "" : String(raw)
    text = text.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "")
    text = text.replace(/[<>&]/g, "")
    var limit = maxLen || 200
    return text.length > limit ? text.substring(0, limit) : text
  }

  // Rate-limit windows come straight from a usage record; cap how many are
  // trusted and sanitize the free-text fields before they reach LimitRow.
  function sanitizeLimits(raw) {
    var list = Array.isArray(raw) ? raw : []
    var out = []
    for (var i = 0; i < list.length && out.length < 20; i++) {
      var entry = list[i] || {}
      out.push({
        label: sanitizeDisplayText(entry.label, 80),
        title: sanitizeDisplayText(entry.title, 80),
        percent: entry.percent,
        resetsAt: sanitizeDisplayText(entry.resetsAt, 40)
      })
    }
    return out
  }

  function capRecentDays(raw) {
    var list = Array.isArray(raw) ? raw : []
    return list.length > 31 ? list.slice(0, 31) : list
  }

  // Bounds how many distinct model ids a single record/snapshot can push into
  // TOKENS BY MODEL bookkeeping, independent of the top-4 Panel.qml already
  // displays — that slice happens after this data is built and merged.
  function capModelUsage(raw) {
    var usage = raw && typeof raw === "object" ? raw : {}
    var out = {}
    var count = 0
    for (var id in usage) {
      if (count >= 100) break
      out[sanitizeDisplayText(id, 80)] = usage[id]
      count++
    }
    return out
  }

  function dateString(date) {
    var y = date.getFullYear()
    var m = String(date.getMonth() + 1).padStart(2, "0")
    var d = String(date.getDate()).padStart(2, "0")
    return y + "-" + m + "-" + d
  }

  function recentDateStrings() {
    var result = []
    for (var offset = 6; offset >= 0; offset--) {
      var date = new Date()
      date.setDate(date.getDate() - offset)
      result.push(dateString(date))
    }
    return result
  }

  function emptyTokenBucket() {
    return { inputTokens: 0, outputTokens: 0, cacheReadInputTokens: 0, cacheCreationInputTokens: 0 }
  }

  // Device-scoped stats add up across machines; account-scoped stats
  // (Fireworks' billing API) are replicas of the same upstream truth on
  // every synced device, so the widest value wins — summing them would
  // double every token per machine.
  function combineNumber(additive, current, value) {
    return additive ? numberValue(current) + numberValue(value) : Math.max(numberValue(current), numberValue(value))
  }

  function combineObjectNumbers(additive, target, source) {
    if (!source) return
    for (var key in source) target[key] = combineNumber(additive, target[key], source[key])
  }

  function aggregateSnapshots(snapshots) {
    var dates = recentDateStrings()
    var devices = {}
    var providers = {}

    function providerAcc(id) {
      if (providers[id]) return providers[id]
      var recentByDay = {}
      for (var d = 0; d < dates.length; d++) recentByDay[dates[d]] = 0
      providers[id] = {
        providerId: id,
        providerName: "",
        ready: false,
        hasLocalStats: false,
        hasPromptStats: false,
        todayPrompts: 0,
        todaySessions: 0,
        todayTotalTokens: 0,
        todayTokensByModel: ({}),
        recentByDay: recentByDay,
        totalPrompts: 0,
        totalSessions: 0,
        activeDays: 0,
        activeDates: ({}),
        modelUsage: ({}),
        devices: ({})
      }
      return providers[id]
    }

    // Snapshots are written by other machines over whatever transport backs
    // the sync directory, so every shape and size below is untrusted. The
    // caps here (snapshot count, providers per snapshot, distinct providers
    // overall, and the per-collection loops) bound the CPU and memory this
    // merge can be made to spend, on top of the file-count/size limits the
    // scan itself already enforces.
    var snapshotCap = Math.min(snapshots.length, root.maxSyncSnapshots)
    for (var i = 0; i < snapshotCap; i++) {
      var snapshot = snapshots[i]
      var device = safeDeviceId(snapshot.deviceId || "device")
      devices[device] = true
      var snapshotProviders = snapshot.providers || {}
      var providerCount = 0
      for (var rawProviderId in snapshotProviders) {
        if (++providerCount > 100) break
        var providerId = sanitizeProviderId(rawProviderId)
        if (!providers[providerId] && Object.keys(providers).length >= 100) continue
        var stats = snapshotProviders[rawProviderId] || {}
        var acc = providerAcc(providerId)
        acc.devices[device] = true
        if (stats.providerName && acc.providerName === "") acc.providerName = sanitizeDisplayText(stats.providerName, 80)
        acc.ready = acc.ready || stats.ready === true
        acc.hasLocalStats = acc.hasLocalStats || stats.hasLocalStats !== false
        // Snapshots from before the field existed only came from agents that
        // count prompts, so a missing value reads as true.
        acc.hasPromptStats = acc.hasPromptStats || stats.hasPromptStats !== false
        var additive = String(stats.scope || "device") !== "account"
        acc.todayPrompts = combineNumber(additive, acc.todayPrompts, stats.todayPrompts)
        acc.todaySessions = combineNumber(additive, acc.todaySessions, stats.todaySessions)
        acc.todayTotalTokens = combineNumber(additive, acc.todayTotalTokens, stats.todayTotalTokens)
        acc.totalPrompts = combineNumber(additive, acc.totalPrompts, stats.totalPrompts)
        acc.totalSessions = combineNumber(additive, acc.totalSessions, stats.totalSessions)
        // Active days overlap between machines, so union the dates rather than
        // summing counts. Snapshots written before activeDates existed only
        // carry a count; the widest one stands in for them.
        var activeDates = Array.isArray(stats.activeDates) ? stats.activeDates : []
        for (var ad = 0; ad < activeDates.length && ad < 400; ad++) {
          if (Object.keys(acc.activeDates).length >= 1000) break
          acc.activeDates[String(activeDates[ad]).slice(0, 20)] = true
        }
        acc.activeDays = Math.max(acc.activeDays, numberValue(stats.activeDays))
        combineObjectNumbers(additive, acc.todayTokensByModel, capModelUsage(stats.todayTokensByModel))

        var recent = Array.isArray(stats.recentDays) ? stats.recentDays : []
        for (var r = 0; r < recent.length && r < 366; r++) {
          var day = recent[r] || {}
          var date = String(day.date || "")
          if (acc.recentByDay[date] !== undefined)
            acc.recentByDay[date] = combineNumber(additive, acc.recentByDay[date], day.messageCount)
        }

        var usage = capModelUsage(stats.modelUsage)
        for (var modelId in usage) {
          var bucket = acc.modelUsage[modelId]
          if (!bucket) bucket = acc.modelUsage[modelId] = emptyTokenBucket()
          combineObjectNumbers(additive, bucket, usage[modelId] || {})
        }
      }
    }

    var outProviders = {}
    for (var id in providers) {
      var acc = providers[id]
      var recentDays = []
      for (var di = 0; di < dates.length; di++) recentDays.push({ date: dates[di], messageCount: acc.recentByDay[dates[di]] || 0 })
      var providerDevices = Object.keys(acc.devices).sort()
      outProviders[id] = {
        providerId: acc.providerId,
        providerName: acc.providerName,
        ready: acc.ready || providerDevices.length > 0,
        hasLocalStats: acc.hasLocalStats,
        hasPromptStats: acc.hasPromptStats,
        todayPrompts: acc.todayPrompts,
        todaySessions: acc.todaySessions,
        todayTotalTokens: acc.todayTotalTokens,
        todayTokensByModel: acc.todayTokensByModel,
        recentDays: recentDays,
        totalPrompts: acc.totalPrompts,
        totalSessions: acc.totalSessions,
        activeDays: Math.max(acc.activeDays, Object.keys(acc.activeDates).length),
        modelUsage: acc.modelUsage,
        deviceCount: providerDevices.length,
        devices: providerDevices
      }
    }

    return {
      schemaVersion: 1,
      updatedAt: new Date().toISOString(),
      updatedAtMs: Date.now(),
      deviceCount: Object.keys(devices).length,
      devices: Object.keys(devices).sort(),
      providers: outProviders
    }
  }

  // Snapshots keep the field names older Omarchy versions wrote, so a fleet
  // of machines on mixed versions still merges cleanly in both directions.
  // This is also what this machine writes into the shared sync directory, so
  // it gets sanitized and capped just like an incoming snapshot: a corrupted
  // or hostile local record shouldn't be able to use the fleet's own sync
  // mechanism to push oversized or malformed data onto every other machine.
  function providerSnapshot(record) {
    return {
      providerId: sanitizeProviderId(record.id),
      providerName: sanitizeDisplayText(record.name || record.id, 80),
      ready: record.ready === true,
      hasLocalStats: record.hasLocalStats !== false,
      hasPromptStats: record.hasPromptStats !== false,
      scope: String(record.scope || "device"),
      todayPrompts: numberValue(record.todayPrompts),
      todaySessions: numberValue(record.todaySessions),
      todayTotalTokens: numberValue(record.todayTotalTokens),
      todayTokensByModel: capModelUsage(record.todayTokensByModel),
      recentDays: capRecentDays(cloneValue(record.recentDays, [])),
      totalPrompts: numberValue(record.totalPrompts),
      totalSessions: numberValue(record.totalSessions),
      activeDays: numberValue(record.activeDays),
      activeDates: cloneValue(record.activeDates, []).slice(0, 400),
      modelUsage: capModelUsage(record.modelUsage)
    }
  }

  function localSnapshot() {
    var providerMap = {}
    var count = 0
    for (var i = 0; i < agents.length; i++) {
      var record = agents[i] ? agents[i].record : null
      if (!record || !record.id) continue
      var id = sanitizeProviderId(record.id)
      if (!providerEnabled(id)) continue
      if (++count > 100) break
      providerMap[id] = providerSnapshot(record)
    }
    return {
      schemaVersion: 1,
      deviceId: syncEffectiveDeviceId,
      updatedAt: new Date().toISOString(),
      providers: providerMap
    }
  }

  function syncedStatsFor(providerId) {
    var rev = syncRevision
    if (!syncConfigured() || !aggregateData || !aggregateData.providers) return null
    return aggregateData.providers[providerId] || null
  }

  // ---------------------------------------------------------------- format

  function formatTokenCount(n) {
    if (n === undefined || n === null) return "0"
    if (n >= 1e9) return (n / 1e9).toFixed(1) + "B"
    if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
    if (n >= 1e3) return (n / 1e3).toFixed(1) + "K"
    return String(n)
  }

  function modelWordCase(word) {
    if (word === "gpt") return "GPT"
    if (word === "deepseek") return "DeepSeek"
    return word.charAt(0).toUpperCase() + word.slice(1)
  }

  // Model ids arrive hyphenated with the version split across segments
  // (`claude-opus-4-8`, `gpt-5.6-sol`). Rejoin the numeric run into one
  // version and title-case the words around it.
  function friendlyModelName(id) {
    if (!id) return "Unknown"
    var name = String(id).replace(/^claude-/, "").replace(/-\d{8}$/, "")
    var parts = name.split("-")
    var words = []
    var version = []
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i]
      if (part === "") continue
      if (/^\d/.test(part)) {
        version.push(part)
        continue
      }
      if (version.length > 0) {
        words.push(version.join("."))
        version = []
      }
      words.push(modelWordCase(part))
    }
    if (version.length > 0) words.push(version.join("."))
    return words.length > 0 ? words.join(" ") : "Unknown"
  }
}
