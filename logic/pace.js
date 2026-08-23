// Pure token-history burn-rate projection for a rate-limit window.
//
// Percentage limits are not token quotas. This intentionally needs an
// explicit `tokenLimit` and never tries to reverse-engineer one from a
// percentage, label, or another provider's plan. `tokensByDay` is normally
// the selected provider's recentDays array (messageCount is token count).

function ms(value) {
  var n = new Date(String(value || "")).getTime()
  return isFinite(n) ? n : NaN
}

function tokenValue(value) {
  if (typeof value === "number") return isFinite(value) && value > 0 ? value : 0
  var entry = value || {}
  var n = Number(entry.messageCount)
  return isFinite(n) && n > 0 ? n : 0
}

function tokenLimitValue(limit) {
  if (typeof limit === "number") return isFinite(limit) && limit > 0 ? limit : 0
  var raw = limit || {}
  var n = Number(raw.tokenLimit !== undefined ? raw.tokenLimit : raw.limitTokens)
  return isFinite(n) && n > 0 ? n : 0
}

// `projectExhaustion(tokensByDay, limit, windowResetAt[, nowMs])` returns
// null unless it has a real token quota, at least one history point, and a
// future reset. It forecasts the next day's burn with a least-squares trend:
// flat history stays flat, rising history increases, falling history floors
// at zero. With one day the only defensible forecast is that day's pace.
function projectExhaustion(tokensByDay, limit, windowResetAt, nowMs) {
  var days = Array.isArray(tokensByDay) ? tokensByDay : []
  var tokenLimit = tokenLimitValue(limit)
  var resetMs = ms(windowResetAt)
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  if (!tokenLimit || !isFinite(resetMs) || !isFinite(now) || resetMs <= now || !days.length) return null

  var values = []
  var usedTokens = 0
  for (var i = 0; i < days.length; i++) {
    var value = tokenValue(days[i])
    values.push(value)
    usedTokens += value
  }

  var dailyTokens
  if (values.length === 1) {
    dailyTokens = values[0]
  } else {
    var meanX = (values.length - 1) / 2
    var meanY = usedTokens / values.length
    var numerator = 0
    var denominator = 0
    for (var j = 0; j < values.length; j++) {
      var dx = j - meanX
      numerator += dx * (values[j] - meanY)
      denominator += dx * dx
    }
    var slope = denominator ? numerator / denominator : 0
    // Predict the first unseen day (x = n), not "mean plus n slopes".
    // The latter would double-count the x offset whenever n > 1.
    dailyTokens = Math.max(0, meanY + slope * (values.length - meanX))
  }
  if (!(dailyTokens > 0)) return null

  var remainingTokens = Math.max(0, tokenLimit - usedTokens)
  var untilExhaustionMs = remainingTokens / dailyTokens * 24 * 60 * 60 * 1000
  var exhaustionAtMs = now + untilExhaustionMs
  return {
    tokenLimit: tokenLimit,
    usedTokens: usedTokens,
    remainingTokens: remainingTokens,
    dailyTokens: dailyTokens,
    resetsAtMs: resetMs,
    exhaustionAtMs: exhaustionAtMs,
    untilExhaustionMs: untilExhaustionMs,
    exhaustsBeforeReset: exhaustionAtMs < resetMs
  }
}

function projectionForWindow(window, nowMs) {
  var w = window || {}
  var now = Number(nowMs)
  var percent = Number(w.percent)
  var startedAtMs = ms(w.startedAt)
  var resetsAtMs = ms(w.resetsAt || w.resetAt)

  if (!isFinite(now) || !isFinite(percent) || percent <= 0 || percent >= 1
      || !isFinite(startedAtMs) || !isFinite(resetsAtMs)
      || startedAtMs >= now || resetsAtMs <= now || resetsAtMs <= startedAtMs) return null

  var elapsedMs = now - startedAtMs
  var remainingFraction = 1 - percent
  var fractionPerMs = percent / elapsedMs
  var exhaustionAtMs = now + remainingFraction / fractionPerMs
  var untilExhaustionMs = exhaustionAtMs - now

  return {
    percent: percent,
    elapsedMs: elapsedMs,
    windowMs: resetsAtMs - startedAtMs,
    resetsAtMs: resetsAtMs,
    exhaustionAtMs: exhaustionAtMs,
    untilExhaustionMs: untilExhaustionMs,
    // A projection that runs past reset is not useful actionably: the
    // allowance resets before it could be exhausted.
    exhaustsBeforeReset: exhaustionAtMs < resetsAtMs
  }
}

function mostUrgentProjection(windows, nowMs) {
  var list = Array.isArray(windows) ? windows : []
  var best = null
  for (var i = 0; i < list.length; i++) {
    var candidate = projectionForWindow(list[i], nowMs)
    if (!candidate || !candidate.exhaustsBeforeReset) continue
    if (!best || candidate.untilExhaustionMs < best.untilExhaustionMs)
      best = candidate
  }
  return best
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    tokenValue: tokenValue,
    tokenLimitValue: tokenLimitValue,
    projectExhaustion: projectExhaustion,
    projectionForWindow: projectionForWindow,
    mostUrgentProjection: mostUrgentProjection
  }
}
