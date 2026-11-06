#!/usr/bin/env bash
# Builds MacMixer.app into ./build. Works with just the Xcode Command Line Tools.
#
#   ./scripts/build-app.sh                         # your Mac's architecture
#   ARCHS="arm64 x86_64" ./scripts/build-app.sh    # universal (Apple silicon + Intel)
#   VERSION=1.2.0 ./scripts/build-app.sh           # set the version shown in Finder
#   SIGN_IDENTITY="Developer ID Application: …"    # real signing (default: ad-hoc)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCHS="${ARCHS:-$(uname -m)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/MacMixer.app"

binaries=()
for arch in $ARCHS; do
  echo "==> Building for $arch"
  swift build -c release --arch "$arch"
  binaries+=("$(swift build -c release --arch "$arch" --show-bin-path)/MacMixer")
done

echo "==> Assembling $APP (version $VERSION, build $BUILD)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "${#binaries[@]}" -gt 1 ]; then
  lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/MacMixer"
else
  cp "${binaries[0]}" "$APP/Contents/MacOS/MacMixer"
fi

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

# Under the hardened runtime, process taps deliver pure silence without the
# audio-input entitlement, while still muting the tapped app at the source.
ENTITLEMENTS="Resources/MacMixer.entitlements"

echo "==> Signing ($SIGN_IDENTITY)"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
else
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp --entitlements "$ENTITLEMENTS" "$APP"
fi

echo "==> Done: $APP"
