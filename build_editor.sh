#!/bin/bash
# Builds "TacoEngine.app" next to this script. The app is self-contained: it carries a copy of the
# engine runtime and the documentation, so it can be moved anywhere (devkitPro and mGBA are still
# installed separately).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0"
BUILD="1"

swift build -c release --package-path editor
APP="TacoEngine.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp editor/.build/release/TacoEngine "$APP/Contents/MacOS/TacoEngine"
cp editor/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
rsync -a --exclude ".DS_Store" engine docs "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TacoEngine</string>
  <key>CFBundleDisplayName</key><string>TacoEngine</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>local.tacoengine</string>
  <key>CFBundleExecutable</key><string>TacoEngine</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>NSHumanReadableCopyright</key><string>Taco Engine contributors. zlib license.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP $VERSION"
