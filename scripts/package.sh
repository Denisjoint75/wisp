#!/usr/bin/env bash
# Builds release binaries and assembles dist/Wisp.app (daemon + Sparkle.framework + icon) and dist/wisp (CLI),
# signing everything with the given identity ("-" = ad-hoc).
#
#   scripts/package.sh [--identity "Developer ID Application: ..."] [--output dist] [--feed-url URL] [--universal]
# Env: WISP_SIGN_IDENTITY (default "-"), SPARKLE_PUBLIC_KEY (default: assets/sparkle-public-key.txt),
#      WISP_FEED_URL (default: GitHub releases appcast).
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${WISP_SIGN_IDENTITY:--}"
OUT="dist"
FEED_URL="${WISP_FEED_URL:-https://github.com/missuo/wisp/releases/latest/download/appcast.xml}"
UNIVERSAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --output) OUT="$2"; shift 2 ;;
    --feed-url) FEED_URL="$2"; shift 2 ;;
    --universal) UNIVERSAL=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
PUBKEY="${SPARKLE_PUBLIC_KEY:-$(cat assets/sparkle-public-key.txt 2>/dev/null || true)}"
VERSION=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/WispCore/Version.swift)
BUILD=$(sed -n 's/.*static let build = "\(.*\)".*/\1/p' Sources/WispCore/Version.swift)

echo "building release ($VERSION build $BUILD)…"
if [ "$UNIVERSAL" = 1 ]; then
  swift build -c release --arch arm64 --arch x86_64 2>&1 | tail -1
  PRODUCTS=".build/apple/Products/Release"
else
  swift build -c release 2>&1 | tail -1
  PRODUCTS=".build/release"
fi

APP="$OUT/Wisp.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$PRODUCTS/wispd" "$APP/Contents/MacOS/wispd"
cp "$PRODUCTS/wisp" "$OUT/wisp"
echo "architectures: $(lipo -archs "$APP/Contents/MacOS/wispd")"

# Sparkle.framework from the SwiftPM binary artifact
SPARKLE_FW=$(find .build/artifacts -type d -name "Sparkle.framework" -path "*macos*" | head -1)
if [ -z "$SPARKLE_FW" ]; then echo "Sparkle.framework not found in .build/artifacts" >&2; exit 1; fi
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.wisp.daemon</string>
  <key>CFBundleName</key><string>Wisp</string>
  <key>CFBundleDisplayName</key><string>Wisp</string>
  <key>CFBundleExecutable</key><string>wispd</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Wisp</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$PUBKEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict></plist>
PLIST

# App icon: Icon Composer document via actool (Assets.car + .icns), else .icns from the PNG.
ICON_DOC="assets/icon/Wisp.icon"
ICON_PNG="assets/icon/wisp-icon-1024.png"
ICON_DONE=0
if [ -d "$ICON_DOC" ]; then
  PARTIAL="$(mktemp -t wisp-icon).plist"
  if xcrun actool "$ICON_DOC" --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
       --app-icon Wisp --output-partial-info-plist "$PARTIAL" >/dev/null 2>&1 && [ -f "$APP/Contents/Resources/Assets.car" ]; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string Wisp" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string Wisp" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
    ICON_DONE=1
    echo "icon: compiled $ICON_DOC (Assets.car + Wisp.icns)"
  else
    echo "icon: actool could not compile $ICON_DOC; falling back to the PNG"
  fi
fi
if [ "$ICON_DONE" = 0 ] && [ -f "$ICON_PNG" ]; then
  ICONSET="$(mktemp -d)/Wisp.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Wisp.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string Wisp" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
  echo "icon: Wisp.icns from $ICON_PNG"
fi

# Code signing (inside-out, as Sparkle documents for Developer ID distribution).
SIGN=(codesign --force --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then SIGN+=(--options runtime --timestamp); fi
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for xpc in "$FW"/XPCServices/*.xpc; do "${SIGN[@]}" --preserve-metadata=entitlements "$xpc"; done
"${SIGN[@]}" "$FW/Autoupdate"
"${SIGN[@]}" "$FW/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" --identifier dev.wisp.daemon "$APP/Contents/MacOS/wispd"
"${SIGN[@]}" --identifier dev.wisp.daemon "$APP"
"${SIGN[@]}" --identifier dev.wisp.cli "$OUT/wisp"
codesign --verify --deep --strict "$APP"
echo "packaged $APP and $OUT/wisp (signed with: $IDENTITY)"
