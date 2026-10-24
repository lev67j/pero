#!/bin/bash
# Builds build/Перо.app (universal: Apple Silicon + Intel) and build/Pero.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

# One build per architecture, then lipo: works with plain Command Line Tools too.
BINARIES=()
for ARCH in arm64 x86_64; do
  swift build -c release --triple "$ARCH-apple-macosx14.0"
  BINARIES+=("$(swift build -c release --triple "$ARCH-apple-macosx14.0" --show-bin-path)/Pero")
done

APP="build/Перо.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Pero"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"

rm -f build/Pero.zip
ditto -c -k --keepParent "$APP" build/Pero.zip
echo "Built $APP and build/Pero.zip"
