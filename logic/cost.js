// Pure API-rate cost estimator for transcript collectors. This is purposely
// separate from the QML display parser: collectors can require it in Node,
// while QML can import it if it ever needs to explain a price version.

var Catalogue = typeof require !== "undefined" ? require("./api-price-catalogue.js") : PRICE_CATALOGUE

function nonnegative(value) {
  var n = Number(value)
  return isFinite(n) && n > 0 ? n : 0
}

function bucketTokens(bucket) {
  var b = bucket || {}
  return nonnegative(b.inputTokens) + nonnegative(b.outputTokens)
    + nonnegative(b.cacheReadInputTokens) + nonnegative(b.cacheCreationInputTokens)
}

function bucketUsd(bucket, price) {
  var b = bucket || {}
  return (nonnegative(b.inputTokens) * price.input
    + nonnegative(b.outputTokens) * price.output
    + nonnegative(b.cacheReadInputTokens) * price.cacheRead
    + nonnegative(b.cacheCreationInputTokens) * price.cacheWrite) / 1000000
}

function priceFor(provider, model) {
  var p = Catalogue.providers[String(provider || "")] || null
  return p && p.models[String(model || "")] ? p.models[String(model || "")] : null
}

// Returns `{ cost, unknownModels, pricingVersion }`. `cost` is null whenever
// a used model has no exact catalogue entry; callers must surface
// unknownModels instead of publishing a misleading partial estimate.
// `dailyModelUsage` is optional: `{ "YYYY-MM-DD": { model: TokenBucket }}`.
function calculateCost(input) {
  var options = input || {}
  var provider = String(options.provider || "")
  var usage = options.modelUsage && typeof options.modelUsage === "object" ? options.modelUsage : {}
  var byModel = []
  var unknown = []
  var total = 0

  for (var model in usage) {
    var bucket = usage[model]
    var tokens = bucketTokens(bucket)
    if (tokens === 0) continue
    var price = priceFor(provider, model)
    if (!price) { unknown.push(model); continue }
    var usd = bucketUsd(bucket, price)
    total += usd
    byModel.push({ model: model, usd: usd, tokens: Math.round(tokens) })
  }

  var daily = options.dailyModelUsage && typeof options.dailyModelUsage === "object" ? options.dailyModelUsage : {}
  var byDay = []
  for (var date in daily) {
    var dayUsd = 0
    var dayUsage = daily[date] || {}
    for (var dayModel in dayUsage) {
      var dayTokens = bucketTokens(dayUsage[dayModel])
      if (dayTokens === 0) continue
      var dayPrice = priceFor(provider, dayModel)
      if (!dayPrice) {
        if (unknown.indexOf(dayModel) < 0) unknown.push(dayModel)
        continue
      }
      dayUsd += bucketUsd(dayUsage[dayModel], dayPrice)
    }
    if (dayUsd > 0) byDay.push({ date: String(date), usd: dayUsd })
  }

  byModel.sort(function(a, b) { return b.usd - a.usd })
  byDay.sort(function(a, b) { return a.date < b.date ? -1 : a.date > b.date ? 1 : 0 })
  return {
    pricingVersion: Catalogue.version,
    unknownModels: unknown.sort(),
    cost: unknown.length ? null : {
      estimateUsd: total,
      period: String(options.period || ""),
      pricingVersion: Catalogue.version,
      byModel: byModel,
      byDay: byDay
    }
  }
}

if (typeof module !== "undefined" && module.exports)
  module.exports = { priceFor: priceFor, bucketTokens: bucketTokens, bucketUsd: bucketUsd, calculateCost: calculateCost, PRICE_CATALOGUE: Catalogue }
