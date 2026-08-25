"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")

const History = require("../logic/history.js")

function days(count, startValue) {
  // Builds `count` consecutive oldest-first days, 2026-01-01, 01-02, ...
  // with a distinct messageCount per day so ordering bugs show up as
  // wrong values, not just wrong lengths.
  const out = []
  for (let i = 0; i < count; i++) {
    const day = i + 1
    out.push({ date: "2026-01-" + String(day).padStart(2, "0"), messageCount: (startValue || 0) + i })
  }
  return out
}

test("RANGE_OPTIONS: exposes the four selector choices in day counts", () => {
  assert.deepEqual(History.RANGE_OPTIONS.map((o) => o.id), ["24h", "7d", "30d", "90d"])
  assert.deepEqual(History.RANGE_OPTIONS.map((o) => o.days), [1, 7, 30, 90])
  assert.equal(History.rangeDaysFor("30d"), 30)
  assert.equal(History.rangeDaysFor("nonsense"), 1)
})

test("buildHistorySeries: a single day of data renders as one point, no distortion", () => {
  const result = History.buildHistorySeries([{ date: "2026-01-01", messageCount: 42 }], 1)
  assert.equal(result.ok, true)
  assert.equal(result.availableDays, 1)
  assert.deepEqual(result.points, [{ date: "2026-01-01", value: 42 }])
  assert.equal(result.peak, 42)
})

test("buildHistorySeries: a gap day (messageCount 0) stays in its slot rather than being dropped", () => {
  const data = [
    { date: "2026-01-01", messageCount: 10 },
    { date: "2026-01-02", messageCount: 0 },
    { date: "2026-01-03", messageCount: 5 }
  ]
  const result = History.buildHistorySeries(data, 3)
  assert.equal(result.ok, true)
  assert.equal(result.points.length, 3)
  assert.equal(result.points[1].date, "2026-01-02")
  assert.equal(result.points[1].value, 0)
  assert.equal(result.peak, 10)
})

test("buildHistorySeries: exactly historyDays (30) days of data fills the requested 30d range", () => {
  const data = days(30, 1)
  const result = History.buildHistorySeries(data, 30)
  assert.equal(result.ok, true)
  assert.equal(result.availableDays, 30)
  assert.equal(result.points.length, 30)
  assert.equal(result.points[0].date, "2026-01-01")
  assert.equal(result.points[29].date, "2026-01-30")
})

test("buildHistorySeries: requesting more days than available reports the shortfall instead of narrowing silently", () => {
  const data = days(7, 1)
  const result = History.buildHistorySeries(data, 90)
  assert.equal(result.ok, false)
  assert.equal(result.availableDays, 7)
  assert.equal(result.requestedDays, 90)
  assert.deepEqual(result.points, [])
})

test("buildHistorySeries: requesting fewer days than available clamps to the most recent slice", () => {
  const data = days(30, 1)
  const result = History.buildHistorySeries(data, 7)
  assert.equal(result.ok, true)
  assert.equal(result.points.length, 7)
  assert.equal(result.points[0].date, "2026-01-24")
  assert.equal(result.points[6].date, "2026-01-30")
})

test("buildHistorySeries: no data at all reports zero available days without throwing", () => {
  const result = History.buildHistorySeries([], 1)
  assert.equal(result.ok, false)
  assert.equal(result.availableDays, 0)
  assert.deepEqual(result.points, [])
})

test("buildHistorySeries: undefined/null input is treated as no data", () => {
  assert.equal(History.buildHistorySeries(undefined, 7).ok, false)
  assert.equal(History.buildHistorySeries(null, 7).ok, false)
})

test("buildHistorySeries: out-of-order input is sorted before slicing", () => {
  const data = [
    { date: "2026-01-03", messageCount: 3 },
    { date: "2026-01-01", messageCount: 1 },
    { date: "2026-01-02", messageCount: 2 }
  ]
  const result = History.buildHistorySeries(data, 3)
  assert.deepEqual(result.points.map((p) => p.date), ["2026-01-01", "2026-01-02", "2026-01-03"])
})

test("buildHistorySeries: negative or non-finite messageCount reads as zero, never NaN", () => {
  const data = [
    { date: "2026-01-01", messageCount: -5 },
    { date: "2026-01-02", messageCount: NaN },
    { date: "2026-01-03", messageCount: "not a number" }
  ]
  const result = History.buildHistorySeries(data, 3)
  assert.deepEqual(result.points.map((p) => p.value), [0, 0, 0])
  assert.equal(result.peak, 0)
})
