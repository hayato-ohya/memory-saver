#!/bin/bash
# Builds the release executable and wraps it into dist/MemorySaver.app (ad-hoc signed).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c release --product MemorySaver

APP="$ROOT/dist/MemorySaver.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/MemorySaver" "$APP/Contents/MacOS/MemorySaver"

# The translation files. The package's resource accessor looks for this bundle in Contents/Resources.
TRANSLATIONS="MemorySaver_MemorySaverCore.bundle"
cp -R "$ROOT/.build/release/$TRANSLATIONS" "$APP/Contents/Resources/$TRANSLATIONS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ja</string>
    <key>CFBundleLocalizations</key>
    <array/>
    <key>CFBundleIdentifier</key>
    <string>com.memorysaver.app</string>
    <key>CFBundleName</key>
    <string>MemorySaver</string>
    <key>CFBundleDisplayName</key>
    <string>MemorySaver</string>
    <key>CFBundleExecutable</key>
    <string>MemorySaver</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST

# Declare every language that has a translation folder, so the app appears with those languages
# in System Settings > Language & Region > Applications and system-provided text follows suit.
index=0
for lproj in "$APP/Contents/Resources/$TRANSLATIONS/Contents/Resources/"*.lproj; do
    plutil -insert "CFBundleLocalizations.$index" -string "$(basename "$lproj" .lproj)" "$APP/Contents/Info.plist"
    index=$((index + 1))
done
if [ "$index" -eq 0 ]; then
    echo "error: no translation folders found in $TRANSLATIONS" >&2
    exit 1
fi

plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
