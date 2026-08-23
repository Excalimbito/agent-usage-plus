// Pure data-shaping for the "TOKENS BY DAY" Canvas chart (issue #13).
//
// This module only ever slices/reads the `recentDays` array a provider
// already carries (see logic/aggregate.js and docs/collector-contract.md —
// `recentDays[].messageCount` is, despite the name, a per-day token total).
// It never fetches anything and never talks to Quickshell: selecting a
// different range just re-slices data already sitting in memory, so no
// collector call is ever triggered by this module or by the range selector
// that calls it.

// The panel's four range-selector choices. `days` is how many trailing
// calendar days that choice asks to see. Kept as plain data (not enum
// strings baked into Panel.qml) so a test can iterate every option without
// duplicating the list.
var RANGE_OPTIONS = [
  { id: "24h", label: "24h", days: 1 },
  { id: "7d", label: "7d", days: 7 },
  { id: "30d", label: "30d", days: 30 },
  { id: "90d", label: "90d", days: 90 }
]

function rangeDaysFor(rangeId) {
  for (var i = 0; i < RANGE_OPTIONS.length; i++)
    if (RANGE_OPTIONS[i].id === rangeId) return RANGE_OPTIONS[i].days
  return RANGE_OPTIONS[0].days
}

// recentDays already comes out of logic/aggregate.js oldest-first, but this
// re-sorts defensively (ISO "YYYY-MM-DD" strings sort lexically) since this
// function also has to handle a raw record's `recentDays` before it has
// been through aggregation.
function sortedDays(recentDays) {
  var list = Array.isArray(recentDays) ? recentDays.slice() : []
  list.sort(function(a, b) {
    var da = String((a && a.date) || "")
    var db = String((b && b.date) || "")
    return da < db ? -1 : da > db ? 1 : 0
  })
  return list
}

// Builds a chart-ready series for one provider, clamped to the most recent
// `requestedDays` calendar days actually present in `recentDays`.
//
// Returns `{ ok, availableDays, requestedDays, points, peak }`.
//
// `ok` is false when the caller asked for more days than the data actually
// has (e.g. "90d" selected but the record only carries 30) — the panel must
// show an explicit "not available" message in that case rather than render
// a chart over a shorter span while implying the full range, so this
// function never silently narrows the request; it reports the shortfall
// instead and leaves `points` empty.
//
// A day with `messageCount` 0 (a real gap in usage, not a missing record —
// logic/aggregate.js always fills every date in its window, defaulting to
// 0) is kept in `points` at its own position rather than dropped, so a gap
// paints as a zero-height bar in its correct slot instead of silently
// compressing the timeline.
function buildHistorySeries(recentDays, requestedDays) {
  var days = sortedDays(recentDays)
  var available = days.length
  var requested = Math.max(1, Math.round(Number(requestedDays) || 0))

  if (requested > available) {
    return { ok: false, availableDays: available, requestedDays: requested, points: [], peak: 0 }
  }

  var slice = requested >= available ? days : days.slice(available - requested)
  var points = []
  var peak = 0
  for (var i = 0; i < slice.length; i++) {
    var day = slice[i] || {}
    var value = Number(day.messageCount || 0)
    if (!isFinite(value) || value < 0) value = 0
    points.push({ date: String(day.date || ""), value: value })
    if (value > peak) peak = value
  }

  return { ok: true, availableDays: available, requestedDays: requested, points: points, peak: peak }
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    RANGE_OPTIONS: RANGE_OPTIONS,
    rangeDaysFor: rangeDaysFor,
    buildHistorySeries: buildHistorySeries
  }
}
