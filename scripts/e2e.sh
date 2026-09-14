#!/usr/bin/env bash
# End-to-end smoke test against TextEdit. Requires Accessibility permission for wispd (or an inherited grant when run from a trusted terminal).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build 2>&1 | tail -1
export WISP_DAEMON="$PWD/.build/debug/wispd"
W="$PWD/.build/debug/wisp"
$W daemon restart
$W doctor --no-start
echo "--- launch TextEdit"; $W launch --app TextEdit >/dev/null
echo "--- new document"; $W key --app TextEdit "cmd+n" --no-observe
sleep 0.5
echo "--- state"; $W state --app TextEdit --full | head -25
echo "--- type"; $W type --app TextEdit "Hello from Wisp" | tail -5
echo "--- select all + replace"; $W key --app TextEdit "cmd+a" --no-observe; $W type --app TextEdit "Replaced" | tail -3
echo "--- query"; $W state --app TextEdit --query Replaced
echo "--- close without saving"; $W key --app TextEdit "cmd+w" --no-observe; sleep 0.4
$W state --app TextEdit --query "Delete" | tail -6 || true
$W end --app TextEdit
echo "e2e done"
