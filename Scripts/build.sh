#!/usr/bin/env bash
# Builds build/Snaps.app.
#   ./Scripts/build.sh           build (release)
#   ./Scripts/build.sh run       build and launch
#   ./Scripts/build.sh install   build and copy to /Applications
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
ACTION="${1:-build}"
APP="$ROOT/build/Snaps.app"
BUNDLE_ID="dev.nearby.Snaps"

# Fall back to the Command Line Tools if Xcode isn't usable (e.g. license not accepted).
if ! xcrun swiftc --version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

echo "→ Compiling ($ARCH)"
mkdir -p build
xcrun swiftc \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -target "$ARCH-apple-macos26.0" \
  -sdk "$SDK" \
  Sources/Snaps/*.swift \
  -o build/Snaps

echo "→ Assembling Snaps.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Snaps "$APP/Contents/MacOS/Snaps"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The app icon is rendered from assets/icon.svg whenever the SVG changes.
if [[ ! -f Resources/AppIcon.icns || assets/icon.svg -nt Resources/AppIcon.icns ]]; then
  echo "→ Rendering app icon"
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" assets/icon.svg --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -s format png -z $((size * 2)) $((size * 2)) assets/icon.svg --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Prefer a real signing identity so Screen Recording permission survives rebuilds.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then echo "→ Signing (ad-hoc)"; else echo "→ Signing ($IDENTITY)"; fi
codesign --force --deep --options runtime --entitlements Resources/Snaps.entitlements \
  --identifier "$BUNDLE_ID" --sign "$IDENTITY" "$APP" >/dev/null 2>&1

echo "✓ Built $APP"

case "$ACTION" in
  run)
    pkill -x Snaps 2>/dev/null || true
    open "$APP"
    ;;
  install)
    pkill -x Snaps 2>/dev/null || true
    rm -rf /Applications/Snaps.app
    cp -R "$APP" /Applications/Snaps.app
    echo "✓ Installed to /Applications/Snaps.app"
    open /Applications/Snaps.app
    ;;
esac
