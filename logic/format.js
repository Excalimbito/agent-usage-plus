// Number/percentage/time-to-reset formatting helpers.
//
// Moved out of Main.qml (formatTokenCount, friendlyModelName) and Panel.qml
// (formatDuration, formatMoney, currencyPrefix) — issue #1. Pure string
// formatting only; nothing here reads the clock except formatDuration's
// caller-supplied millisecond count.

function formatTokenCount(n) {
  if (n === undefined || n === null) return "0"
  if (n >= 1e9) return (n / 1e9).toFixed(1) + "B"
  if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
  if (n >= 1e3) return (n / 1e3).toFixed(1) + "K"
  return String(n)
}

// A valid (>= 0) percent as a whole-number string, e.g. 0.5 -> "50%". Callers
// decide what to show for a negative/unknown percent (Panel.qml uses "…" for
// the bar and "—" for a limit row), since that fallback differs by call site.
function formatPercent(percent) {
  return Math.round(percent * 100) + "%"
}

function formatDuration(ms) {
  if (!(ms > 0)) return "now"
  var minutes = Math.floor(ms / 60000)
  var hours = Math.floor(minutes / 60)
  var days = Math.floor(hours / 24)
  if (days > 0) return days + "d " + (hours % 24) + "h"
  if (hours > 0) return hours + "h " + (minutes % 60) + "m"
  return Math.max(1, minutes) + "m"
}

function currencyPrefix(currency) {
  var code = String(currency || "USD").toUpperCase()
  if (code === "USD") return "$"
  if (code === "EUR") return "€"
  if (code === "GBP") return "£"
  return code + " "
}

function formatMoney(value, currency) {
  var amount = Number(value)
  if (!isFinite(amount)) amount = 0
  return currencyPrefix(currency) + amount.toFixed(2)
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

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    formatTokenCount: formatTokenCount,
    formatPercent: formatPercent,
    formatDuration: formatDuration,
    currencyPrefix: currencyPrefix,
    formatMoney: formatMoney,
    modelWordCase: modelWordCase,
    friendlyModelName: friendlyModelName
  }
}
