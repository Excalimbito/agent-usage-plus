"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")

const Thresholds = require("../logic/thresholds.js")

test("isPercentAlarming: below the default 90% threshold is not alarming", () => {
  assert.equal(Thresholds.isPercentAlarming(0.89), false)
})

test("isPercentAlarming: at or above the default 90% threshold is alarming", () => {
  assert.equal(Thresholds.isPercentAlarming(0.9), true)
  assert.equal(Thresholds.isPercentAlarming(0.95), true)
})

test("isPercentAlarming: -1 (no data yet) never alarms", () => {
  assert.equal(Thresholds.isPercentAlarming(-1), false)
})

test("isPercentAlarming: non-numeric percent never alarms", () => {
  assert.equal(Thresholds.isPercentAlarming(undefined), false)
  assert.equal(Thresholds.isPercentAlarming(null), false)
  assert.equal(Thresholds.isPercentAlarming(NaN), false)
  assert.equal(Thresholds.isPercentAlarming("0.95"), false)
})

test("isPercentAlarming: honors a custom threshold", () => {
  assert.equal(Thresholds.isPercentAlarming(0.5, 0.5), true)
  assert.equal(Thresholds.isPercentAlarming(0.49, 0.5), false)
})

test("isBalanceAlarming: remaining share above the 10% threshold is not alarming", () => {
  assert.equal(Thresholds.isBalanceAlarming(5, 20), false) // 25% remaining
})

test("isBalanceAlarming: remaining share at or below the 10% threshold is alarming", () => {
  assert.equal(Thresholds.isBalanceAlarming(2, 20), true) // 10% remaining
  assert.equal(Thresholds.isBalanceAlarming(0, 20), true)
})

test("isBalanceAlarming: unfunded balances (funded <= 0) never alarm", () => {
  assert.equal(Thresholds.isBalanceAlarming(0, 0), false)
  assert.equal(Thresholds.isBalanceAlarming(5, -10), false)
  assert.equal(Thresholds.isBalanceAlarming(5, undefined), false)
})

test("isBalanceAlarming: honors a custom threshold", () => {
  assert.equal(Thresholds.isBalanceAlarming(8, 20, 0.5), true) // 40% remaining, 50% threshold
})
