// Percentage-to-severity classification for meters and the bar icon.
//
// Moved out of Panel.qml's inline `>= 0.9` / `<= 0.1` comparisons (issue
// #1). Issue #6 replaces the original boolean alarming/not-alarming check
// with a three-level severity model driven by two user-configurable
// thresholds (percentage points, 0-100), so the panel can show a distinct
// "warn" state before things turn "critical".

var DEFAULT_WARN_PCT = 75
var DEFAULT_CRITICAL_PCT = 90

// Classifies a percentage-point value (0-100 scale, matching the
// warnThresholdPct/criticalThresholdPct manifest settings) into one of
// "ok" | "warn" | "critical".
//
// `thresholds.warn` and `thresholds.critical` fall back to the defaults
// above when missing or non-numeric. A misconfigured `warn >= critical` is
// guarded rather than left to produce contradictory output: `critical`
// stays the effective floor for "critical", and `warn` is clamped down so
// it can never report a state at or above `critical` — in that case the
// "warn" band simply collapses to empty and values classify as "ok" or
// "critical" only.
function severityFor(pct, thresholds) {
  var opts = thresholds || {}
  var warn = typeof opts.warn === "number" && isFinite(opts.warn) ? opts.warn : DEFAULT_WARN_PCT
  var critical = typeof opts.critical === "number" && isFinite(opts.critical) ? opts.critical : DEFAULT_CRITICAL_PCT

  if (warn >= critical) warn = critical

  if (typeof pct !== "number" || !isFinite(pct)) return "ok"
  if (pct >= critical) return "critical"
  if (pct >= warn) return "warn"
  return "ok"
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    DEFAULT_WARN_PCT: DEFAULT_WARN_PCT,
    DEFAULT_CRITICAL_PCT: DEFAULT_CRITICAL_PCT,
    severityFor: severityFor
  }
}
