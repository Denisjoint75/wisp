#!/usr/bin/env bash
# Local install: packages Wisp.app + wisp (ad-hoc signed unless WISP_SIGN_IDENTITY is set) into $PREFIX/bin.
set -euo pipefail
cd "$(dirname "$0")/.."
PREFIX="${PREFIX:-$HOME/.local}"
scripts/package.sh --output dist
mkdir -p "$PREFIX/bin"
rm -rf "$PREFIX/bin/Wisp.app"
cp -R dist/Wisp.app "$PREFIX/bin/Wisp.app"
cp dist/wisp "$PREFIX/bin/wisp"
echo "installed: $PREFIX/bin/wisp and $PREFIX/bin/Wisp.app"
echo "next: '$PREFIX/bin/wisp doctor' — the menu bar item guides you through Accessibility (and Screen Recording) permissions."
