// Percentage-to-severity checks for meters and the bar icon.
//
// Moved out of Panel.qml's inline `>= 0.9` / `<= 0.1` comparisons (issue
// #1). Deliberately boolean for now — issue 06 extends this to three
// severity levels, and that later change only has to touch this file.

var DEFAULT_ALARM_PERCENT = 0.9
var DEFAULT_BALANCE_ALARM_RATIO = 0.1

// A rate-limit window (or the derived "binding"/"primary" window) is
// alarming once it crosses `threshold` (default 90% used). `percent` of -1
// (no data yet) never alarms.
function isPercentAlarming(percent, threshold) {
  var limit = threshold === undefined || threshold === null ? DEFAULT_ALARM_PERCENT : threshold
  return typeof percent === "number" && isFinite(percent) && percent >= limit
}

// A prepaid balance runs low the way a subscription window fills up: the
// last `threshold` share (default 10%) of the funded credits lights the
// same alarm.
function isBalanceAlarming(remaining, funded, threshold) {
  var limit = threshold === undefined || threshold === null ? DEFAULT_BALANCE_ALARM_RATIO : threshold
  if (!(funded > 0)) return false
  return (Number(remaining) / Number(funded)) <= limit
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    DEFAULT_ALARM_PERCENT: DEFAULT_ALARM_PERCENT,
    DEFAULT_BALANCE_ALARM_RATIO: DEFAULT_BALANCE_ALARM_RATIO,
    isPercentAlarming: isPercentAlarming,
    isBalanceAlarming: isBalanceAlarming
  }
}
