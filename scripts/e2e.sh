#!/usr/bin/env bash
# End-to-end smoke tests. Requires Accessibility permission for wispd (or an inherited grant when run from a
# trusted terminal). Sections run independently and the script exits non-zero if any section failed:
#   TextEdit (always, unless WISP_E2E_SKIP_TEXTEDIT=1)
#   Chrome over DevTools (only with WISP_E2E_CHROME=1; needs Google Chrome; runs hidden in the background)
set -uo pipefail
cd "$(dirname "$0")/.."
swift build 2>&1 | tail -1
export WISP_DAEMON="$PWD/.build/debug/wispd"
W="$PWD/.build/debug/wisp"
$W daemon restart
$W doctor --no-start
FAILED=0

textedit_section() {
  set -e
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
  echo "textedit e2e done"
}

chrome_section() {
  set -e
  FIXTURE="file://$PWD/Tests/Fixtures/form.html"
  echo "--- chrome: launch hidden on the form fixture"; $W chrome launch "$FIXTURE" >/dev/null
  TAB=$($W chrome tabs | grep -F "form.html" | head -1 | cut -d' ' -f1)
  [[ -n "$TAB" ]] || { echo "no fixture tab"; return 1; }
  $W chrome tabs | grep -F "$TAB" | grep -q "\[agent\]" || { echo "tab is not tagged [agent]"; return 1; }
  TMPF=$(mktemp "${TMPDIR:-/tmp}/wisp-e2e-upload.XXXXXX"); echo "hello" >"$TMPF"
  # Index of the first *control* line (role btn) matching the query; labels share the control's name.
  el() { $W state --tab "$TAB" --full --query "$1" | grep ' btn ' | sed -n 's/^ *\[\([0-9]*\)\] .*/\1/p' | head -1; }
  echo "--- chrome: upload (click the file input, then fill the intercepted chooser)"
  FILE_EL=$(el "Attachment (file input)"); [[ -n "$FILE_EL" ]] || { echo "file input not found"; return 1; }
  $W click --tab "$TAB" --el "$FILE_EL" --no-observe
  $W chrome upload --tab "$TAB" "$TMPF" | tail -2
  NAME=$($W chrome eval --tab "$TAB" "document.getElementById('attachmentName').textContent")
  echo "attachmentName: $NAME"; [[ "$NAME" == *"$(basename "$TMPF")"* ]] || { echo "upload not reflected"; return 1; }
  echo "--- chrome: confirm() dialog"
  CONFIRM_EL=$(el "Show confirm()"); [[ -n "$CONFIRM_EL" ]] || { echo "confirm button not found"; return 1; }
  $W click --tab "$TAB" --el "$CONFIRM_EL" | tee /dev/stderr | grep -q "JavaScript confirm dialog is open" || { echo "state did not report the dialog"; return 1; }
  $W chrome dialog --tab "$TAB" accept | tail -1
  RESULT=$($W chrome eval --tab "$TAB" "document.getElementById('dialogResult').textContent")
  echo "dialogResult: $RESULT"; [[ "$RESULT" == "confirm: true" ]] || { echo "dialog not accepted"; return 1; }
  echo "--- chrome: deliverable tab survives wisp end"
  $W chrome mark --tab "$TAB" deliverable
  $W end
  $W chrome tabs | grep -F "$TAB" >/dev/null || { echo "deliverable tab was closed by wisp end"; return 1; }
  $W chrome close --tab "$TAB" >/dev/null
  rm -f "$TMPF"
  echo "chrome e2e done"
}

if [[ "${WISP_E2E_SKIP_TEXTEDIT:-0}" != "1" ]]; then
  if ! ( textedit_section ); then echo "TEXTEDIT SECTION FAILED"; FAILED=1; fi
fi
if [[ "${WISP_E2E_CHROME:-0}" == "1" ]]; then
  if ! ( chrome_section ); then echo "CHROME SECTION FAILED"; FAILED=1; fi
fi
[[ "$FAILED" == 0 ]] && echo "e2e done" || echo "e2e FAILED"
exit "$FAILED"
