#!/bin/bash
# Builds Rimshot.app with swiftc only (no Xcode), as a universal binary, and signs it ad hoc.
set -euo pipefail
cd "$(dirname "$0")"

APP="Rimshot.app"
VERSION="0.1.1"

rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

for arch in arm64 x86_64; do
  echo "Compiling for ${arch}..."
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" main.swift -o "build/Rimshot-$arch"
done
lipo -create build/Rimshot-arm64 build/Rimshot-x86_64 -output "$APP/Contents/MacOS/Rimshot"
rm -rf build

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Rimshot</string>
  <key>CFBundleDisplayName</key>
  <string>Rimshot</string>
  <key>CFBundleIdentifier</key>
  <string>dev.rimshot.Rimshot</string>
  <key>CFBundleExecutable</key>
  <string>Rimshot</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>MIT License</string>
</dict>
</plist>
EOF

# The icon is pre-built; regenerate it with design/icons/make-icns.sh.
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP"
