#!/usr/bin/env bash
# Validates manifest.json against the minimum Omarchy plugin manifest shape:
#   1. it must be valid JSON, and
#   2. it must carry every required top-level key.
#
# Usage: scripts/check-manifest.sh [path/to/manifest.json]
# Exits non-zero (with a message on stderr) on the first problem found.

set -euo pipefail

manifest="${1:-manifest.json}"

if [ ! -f "$manifest" ]; then
  echo "check-manifest: $manifest not found" >&2
  exit 1
fi

if ! jq empty "$manifest" 2>/tmp/check-manifest-jq-err; then
  echo "check-manifest: $manifest is not valid JSON:" >&2
  cat /tmp/check-manifest-jq-err >&2
  exit 1
fi

required_keys=(schemaVersion id name version entryPoints barWidget)
missing=()
for key in "${required_keys[@]}"; do
  if ! jq -e --arg k "$key" 'has($k)' "$manifest" >/dev/null; then
    missing+=("$key")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "check-manifest: $manifest is missing required key(s): ${missing[*]}" >&2
  exit 1
fi

echo "check-manifest: $manifest OK (valid JSON, all required keys present)"
