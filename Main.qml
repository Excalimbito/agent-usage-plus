import QtQuick
import Quickshell
import Quickshell.Io
import "logic/aggregate.js" as Aggregate
import "logic/format.js" as Format

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

  // Agent.qml reads its record through a bounded, one-shot process rather
  // than a watched FileView (see Agent.qml for why), so nothing re-reads a
  // record on its own when the file changes underneath it. Call this
  // whenever the collector may just have rewritten records — a newly
  // discovered agent picks up its first record on its own via
  // Component.onCompleted, so this only needs to cover ones that already
  // existed.
  function reloadAllAgents() {
    for (var i = 0; i < agentInstantiator.count; i++) {
      var agent = agentInstantiator.objectAt(i)
      if (agent) agent.reload()
    }
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
      if (record && record.retryAdvised === true && providerEnabled(Aggregate.sanitizeProviderId(record.id)))
        advising.push(Aggregate.sanitizeProviderId(record.id))
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

  // A collector talking to a misbehaving provider API could dump an
  // arbitrarily large error body to stderr; cap what actually reaches this
  // process's memory at the producer boundary instead of trusting the
  // collector to behave.
  readonly property int maxUpdateStderrBytes: 65536

  Process {
    id: updateProcess
    running: false
    onExited: {
      root.rescanAgents()
      root.reloadAllAgents()
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

  // Wraps the real command so only the first maxUpdateStderrBytes bytes of
  // its stderr ever reach updateProcess's StdioCollector, no matter how
  // much a provider collector's diagnostics try to write.
  function boundedCommand(command, maxStderrBytes) {
    var script = 'exec "$0" "$@" 2> >(head -c ' + maxStderrBytes + ' >&2)'
    return ["bash", "-c", script].concat(command)
  }

  function runUpdate(kind, agentIds) {
    if (updateProcess.running) {
      // Collapse queued requests to one full rerun; a forced refresh outranks
      // the cheaper kinds it might have been queued behind.
      if (kind === "force" || root.pendingUpdateKind === "") root.pendingUpdateKind = kind
      return
    }
    updateProcess.command = boundedCommand(updateCommand(kind, agentIds), root.maxUpdateStderrBytes)
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
      var id = Aggregate.sanitizeProviderId(record.id)
      localIds[id] = true
      if (!providerEnabled(id)) continue
      var display = displayProvider(record)
      if (Aggregate.providerHasData(display)) result.push(display)
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
      if (Aggregate.providerHasData(syncedDisplay)) result.push(syncedDisplay)
    }
    return result
  }

  function providerEnabled(id) {
    if (!settings || !settings.providers || !settings.providers[id]) return true
    return settings.providers[id].enabled !== false
  }

  // Merges one usage record with its synced counterpart (if any) into the
  // per-provider object the panel renders — see logic/aggregate.js for the
  // pure merge (mergeProviderDisplay) and the "has this provider produced
  // anything worth a tab" check (providerHasData).
  function displayProvider(record) {
    var providerId = Aggregate.sanitizeProviderId(record.id)
    var stats = syncedStatsFor(providerId)
    return Aggregate.mergeProviderDisplay(record, stats, {
      deviceCount: aggregateData ? aggregateData.deviceCount : 0,
      updatedAt: aggregateData && aggregateData.updatedAt ? aggregateData.updatedAt : ""
    })
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
    var envFallback = Quickshell.env("HOSTNAME") || root.detectedHostname || Quickshell.env("HOST") || Quickshell.env("USER") || "device"
    return Aggregate.sanitizeDeviceId(raw, envFallback)
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

    aggregateData = Aggregate.aggregateSnapshots(snapshots, root.maxSyncSnapshots)
    syncStatusText = ""
    syncRevision++
  }

  // ---------------------------------------------------------- untrusted input
  //
  // The sanitizers that used to live here (sanitizeProviderId,
  // sanitizeDisplayText, sanitizeLimits, capRecentDays, capModelUsage,
  // cloneValue, numberValue) moved to logic/aggregate.js: they're pure and
  // shared by the merge functions there. See that file's header comment for
  // why they still matter — everything they touch can reach a native QML
  // Text/Button/Image sink in Panel.qml.

  // localSnapshot() feeds the write side of sync: one plain record per
  // agent, handed to logic/aggregate.js's buildLocalSnapshot (which sanitizes
  // and caps each one through providerSnapshot before it ever reaches disk).
  function localSnapshot() {
    var records = []
    for (var i = 0; i < agents.length; i++) records.push(agents[i] ? agents[i].record : null)
    return Aggregate.buildLocalSnapshot(records, syncEffectiveDeviceId, providerEnabled)
  }

  function syncedStatsFor(providerId) {
    var rev = syncRevision
    if (!syncConfigured() || !aggregateData || !aggregateData.providers) return null
    return aggregateData.providers[providerId] || null
  }

  // ---------------------------------------------------------------- format
  //
  // Both moved to logic/format.js; Panel.qml calls these through `usage.`
  // (the Main {} instance it embeds), so they stay here as thin wrappers
  // rather than making every call site import Format itself.

  function formatTokenCount(n) {
    return Format.formatTokenCount(n)
  }

  function friendlyModelName(id) {
    return Format.friendlyModelName(id)
  }
}
