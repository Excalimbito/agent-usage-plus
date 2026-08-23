"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")
const Pace = require("../logic/pace.js")

const now = Date.parse("2026-08-23T12:00:00Z")
const resetTomorrow = "2026-08-24T12:00:00Z"

test("projectExhaustion: flat daily history forecasts the same daily burn", () => {
  const result = Pace.projectExhaustion([100, 100, 100], { tokenLimit: 1000 }, resetTomorrow, now)
  assert.ok(result)
  assert.equal(result.usedTokens, 300)
  assert.equal(result.dailyTokens, 100)
  assert.equal(result.untilExhaustionMs, 7 * 24 * 60 * 60 * 1000)
  assert.equal(result.exhaustsBeforeReset, false)
})

test("projectExhaustion: decreasing history floors a non-positive next-day trend and withholds prediction", () => {
  assert.equal(Pace.projectExhaustion([300, 200, 100], { tokenLimit: 1000 }, resetTomorrow, now), null)
})

test("projectExhaustion: one day uses observed burn without inventing a trend", () => {
  const result = Pace.projectExhaustion([{ messageCount: 250 }], { tokenLimit: 1000 }, "2026-08-30T12:00:00Z", now)
  assert.ok(result)
  assert.equal(result.dailyTokens, 250)
  assert.equal(result.untilExhaustionMs, 3 * 24 * 60 * 60 * 1000)
})

test("projectExhaustion: increasing history forecasts an increasing pace", () => {
  const result = Pace.projectExhaustion([100, 200, 300], { tokenLimit: 2000 }, "2026-08-30T12:00:00Z", now)
  assert.ok(result)
  assert.equal(result.dailyTokens, 400)
  assert.equal(result.remainingTokens, 1400)
  assert.equal(result.untilExhaustionMs, 3.5 * 24 * 60 * 60 * 1000)
  assert.equal(result.exhaustsBeforeReset, true)
})

test("projectExhaustion: increasing pace is not urgent when reset arrives first", () => {
  const result = Pace.projectExhaustion([100, 200, 300], { tokenLimit: 2000 }, resetTomorrow, now)
  assert.ok(result)
  assert.equal(result.exhaustsBeforeReset, false)
})

test("projectExhaustion: refuses percentage-only limit, stale reset, or empty history", () => {
  assert.equal(Pace.projectExhaustion([100], { percent: 0.5 }, resetTomorrow, now), null)
  assert.equal(Pace.projectExhaustion([100], { tokenLimit: 1000 }, "2026-08-23T11:59:00Z", now), null)
  assert.equal(Pace.projectExhaustion([], { tokenLimit: 1000 }, resetTomorrow, now), null)
})

test("legacy startedAt projection remains available to collectors with no daily history", () => {
  const result = Pace.projectionForWindow({ percent: 0.5, startedAt: "2026-08-23T10:00:00Z", resetsAt: "2026-08-23T16:00:00Z" }, now)
  assert.ok(result)
  assert.equal(result.exhaustsBeforeReset, true)
})
