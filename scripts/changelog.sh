#!/usr/bin/env bash
# Prints the CHANGELOG.md section for a version (without the version header),
# with leading and trailing blank lines trimmed.
# Usage: scripts/changelog.sh <version> [path/to/CHANGELOG.md]
set -euo pipefail
VERSION="${1:?version required, e.g. 0.0.3}"
FILE="${2:-$(dirname "$0")/../CHANGELOG.md}"
awk -v v="$VERSION" '
  /^##[[:space:]]+\[?[0-9]/ {
    if (found) { found=0; exit }
    line=$0; gsub(/[^0-9.]/, " ", line); split(line, a, " ")
    for (i in a) { if (a[i] == v) { found=1; hdr=1; next } }
  }
  found { print }
' "$FILE" | perl -0pe 's/\A\n+//; s/\n\s*\n+\z/\n/'
