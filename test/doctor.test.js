"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")
const path = require("node:path")
const { execFileSync } = require("node:child_process")

const doctorPath = path.join(__dirname, "..", "scripts", "agent-usage-doctor")
const fixturesDir = path.join(__dirname, "fixtures")

function fixturePath(name) {
  return path.join(fixturesDir, name)
}

// Runs the doctor script against a file path argument and returns
// { status, stdout, stderr } instead of throwing on a non-zero exit,
// since a non-zero exit is the expected/asserted outcome for several cases.
function runDoctorOnFile(name) {
  try {
    const stdout = execFileSync(doctorPath, [fixturePath(name)], { encoding: "utf8" })
    return { status: 0, stdout, stderr: "" }
  } catch (err) {
    return { status: err.status, stdout: err.stdout ?? "", stderr: err.stderr ?? "" }
  }
}

function runDoctorOnStdin(name) {
  const fs = require("node:fs")
  const input = fs.readFileSync(fixturePath(name))
  try {
    const stdout = execFileSync(doctorPath, [], { input, encoding: "utf8" })
    return { status: 0, stdout, stderr: "" }
  } catch (err) {
    return { status: err.status, stdout: err.stdout ?? "", stderr: err.stderr ?? "" }
  }
}

// -------------------------------------------------------------- ok fixtures

for (const name of ["claude-ok.json", "codex-ok.json", "fireworks-ok.json"]) {
  test(`agent-usage-doctor: ${name} exits 0 (file arg)`, () => {
    const { status, stdout } = runDoctorOnFile(name)
    assert.equal(status, 0)
    assert.match(stdout, /OK/)
  })

  test(`agent-usage-doctor: ${name} exits 0 (stdin)`, () => {
    const { status, stdout } = runDoctorOnStdin(name)
    assert.equal(status, 0)
    assert.match(stdout, /OK/)
  })
}

// ------------------------------------------------------ documented error states

for (const name of ["claude-auth-error.json", "codex-endpoint-down.json"]) {
  test(`agent-usage-doctor: ${name} (documented error state) exits 0`, () => {
    const { status, stdout } = runDoctorOnFile(name)
    assert.equal(status, 0)
    assert.match(stdout, /OK/)
  })
}

// -------------------------------------------------------------------- failures

test("agent-usage-doctor: malformed.json exits non-zero with a specific message, not a generic dump", () => {
  const { status, stderr } = runDoctorOnFile("malformed.json")
  assert.notEqual(status, 0)
  assert.match(stderr, /invalid JSON/)
  // The message should carry jq's actual parse diagnostic (line/column),
  // not just a bare "invalid JSON" with no detail.
  assert.match(stderr, /line \d+/)
})

test("agent-usage-doctor: oversized.json exits non-zero due to real contract violations (id charset, non-ISO-8601 dates) rather than sheer size", () => {
  const { status, stderr } = runDoctorOnFile("oversized.json")
  assert.notEqual(status, 0)
  // id contains characters outside [A-Za-z0-9_-] and exceeds 64 chars.
  assert.match(stderr, /`id` must match/)
  // recentDays/activeDates entries in this fixture are not valid YYYY-MM-DD.
  assert.match(stderr, /is not ISO-8601/)
})

test("agent-usage-doctor: rejects legacy scalar todayTokensByModel values", () => {
  const input = JSON.stringify({ id: "example", todayTokensByModel: { model: 123 } })
  try {
    execFileSync(doctorPath, [], { input, encoding: "utf8" })
    assert.fail("expected scalar TokenBucket legacy form to fail")
  } catch (err) {
    assert.notEqual(err.status, 0)
    assert.match(err.stderr, /TokenBucket object/)
  }
})

// -------------------------------------------------------------------- usage

test("agent-usage-doctor: missing file argument exits non-zero with a clear message", () => {
  const { status, stderr } = runDoctorOnFile("does-not-exist.json")
  assert.notEqual(status, 0)
  assert.match(stderr, /file not found/)
})

test("agent-usage-doctor: empty stdin exits non-zero", () => {
  try {
    execFileSync(doctorPath, [], { input: "", encoding: "utf8" })
    assert.fail("expected a non-zero exit for empty input")
  } catch (err) {
    assert.notEqual(err.status, 0)
    assert.match(err.stderr, /empty input/)
  }
})

test("agent-usage-doctor: script is executable", () => {
  const fs = require("node:fs")
  const mode = fs.statSync(doctorPath).mode
  assert.ok(mode & 0o111, "expected scripts/agent-usage-doctor to have an executable bit set")
})
