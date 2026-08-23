#!/usr/bin/env node
'use strict';

// Pulls the two inline bash scripts that Main.qml builds as JS string
// concatenation (see `boundedCommand` and `startSyncScan`) out into real
// files so CI can run `shellcheck` against actual shell source instead of
// QML. This is deliberately a CI-time extraction step rather than a
// refactor of Main.qml: the scripts stay inline (simpler at the call
// site, and the numbers they interpolate are internal QML properties, not
// untrusted input), and this script reconstructs the exact same text using
// representative numeric values for those interpolated properties.
//
// Usage: node scripts/extract-inline-shell.js <output-dir>

const fs = require('fs');
const path = require('path');

const outDir = process.argv[2];
if (!outDir) {
  console.error('usage: extract-inline-shell.js <output-dir>');
  process.exit(1);
}

const mainQmlPath = path.join(__dirname, '..', 'Main.qml');
const src = fs.readFileSync(mainQmlPath, 'utf8');

function extractExpr(name, regex) {
  const match = src.match(regex);
  if (!match) {
    throw new Error(`Could not locate the "${name}" inline script expression in Main.qml. ` +
      'Main.qml was likely restructured; update the regex in scripts/extract-inline-shell.js to match.');
  }
  return match[1];
}

function evalExpr(expr, context) {
  const fn = new Function(...Object.keys(context), `return (${expr});`);
  return fn(...Object.values(context));
}

// --- boundedCommand's script (wraps a provider command to cap stderr) -----
const boundedCommandExpr = extractExpr(
  'boundedCommand',
  /function boundedCommand\([^)]*\)\s*\{\s*var script = (.*)\n\s*return \["bash"/
);
const boundedCommandScript = evalExpr(boundedCommandExpr, { maxStderrBytes: 65536 });

// --- startSyncScan's script (scans the sync directory for snapshots) ------
const syncScanExpr = extractExpr(
  'startSyncScan',
  /function startSyncScan\(\)[\s\S]*?var script = ([\s\S]*?)\n\s*syncScanProcess\.command/
);
const syncScanScript = evalExpr(syncScanExpr, {
  root: {
    maxSyncSnapshots: 50,
    maxSyncSnapshotBytes: 262144,
    maxSyncScanOutputBytes: 20971520
  }
});

fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(
  path.join(outDir, 'bounded-command.sh'),
  '#!/usr/bin/env bash\n' +
    '# Extracted from boundedCommand() in Main.qml by scripts/extract-inline-shell.js.\n' +
    '# Not run directly; shellcheck-only. "$0"/"$@" below stand for the wrapped command.\n' +
    boundedCommandScript + '\n'
);
fs.writeFileSync(
  path.join(outDir, 'sync-scan.sh'),
  '#!/usr/bin/env bash\n' +
    '# Extracted from startSyncScan() in Main.qml by scripts/extract-inline-shell.js.\n' +
    '# Not run directly; shellcheck-only. "$0" below stands for the sync directory.\n' +
    syncScanScript + '\n'
);

console.log(`Wrote ${path.join(outDir, 'bounded-command.sh')}`);
console.log(`Wrote ${path.join(outDir, 'sync-scan.sh')}`);
