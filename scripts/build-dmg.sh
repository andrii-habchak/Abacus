#!/usr/bin/env bash
# Builds an ad-hoc signed Release of Abacus and packages it as dist/Abacus-<version>.dmg
# (the app plus an /Applications link). Run from anywhere: scripts/build-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# This Mac's xcode-select points at the Command Line Tools; the build needs full Xcode.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
XCODEGEN="$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)"

echo "==> Generating the Xcode project"
"$XCODEGEN" generate --spec project.yml --quiet

echo "==> Building Release (ad-hoc signed)"
xcodebuild \
  -project Abacus.xcodeproj \
  -scheme Abacus \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  -quiet \
  build

APP="build/Build/Products/Release/Abacus.app"
test -d "$APP" || { echo "error: $APP not found" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="dist/Abacus-$VERSION.dmg"

echo "==> Packaging $DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
hdiutil create -volname "Abacus $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

(cd dist && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1))"
