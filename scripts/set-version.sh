#!/usr/bin/env bash
# Usage: scripts/set-version.sh <version> [build]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?version required, e.g. 0.2.0}"
BUILD="${2:-1}"
cat > Sources/WispCore/Version.swift <<EOF
import Foundation

/// Single source of truth for the version. \`scripts/set-version.sh\` rewrites this file at release time.
public enum WispVersion {
    public static let string = "$VERSION"
    public static let build = "$BUILD"
}
EOF
echo "version $VERSION ($BUILD)"
