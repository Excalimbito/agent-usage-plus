import QtQuick
import Quickshell.Io

// One agent's usage record, read straight off the data file that
// omarchy-agent-usage-update maintains. The panel never learns how the
// numbers were made — a record that appears in the usage directory is an
// agent, whoever wrote it.
Item {
  id: root
  visible: false

  property string agentId: ""
  property string path: ""
  property var record: null

  // Main.qml's listing already excludes files at or above this size before an
  // Agent is ever created for them; this is a backstop against a file that
  // grows past the limit between that scan and this load.
  readonly property int maxBytes: 1048576

  FileView {
    path: root.path
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parse(text())
    onLoadFailed: root.record = null
  }

  function parse(content) {
    var raw = String(content || "")
    if (raw.length > root.maxBytes) {
      console.warn("agents", "Ignoring oversized usage record", root.path, raw.length)
      root.record = null
      return
    }
    try {
      var parsed = JSON.parse(raw)
      root.record = parsed && typeof parsed === "object" ? parsed : null
    } catch (e) {
      console.warn("agents", "Ignoring bad usage record", root.path, e)
      root.record = null
    }
  }
}
