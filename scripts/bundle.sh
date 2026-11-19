#!/bin/bash
# Builds the release executable and wraps it into dist/MemorySaver.app.
#
#   ./scripts/bundle.sh           build dist/MemorySaver.app
#   ./scripts/bundle.sh install   also replace /Applications/MemorySaver.app and open it
#
# Signs with the "MemorySaver Dev" certificate when it exists (see scripts/make-signing-cert.sh),
# so that Open at login survives rebuilds and updates. Otherwise signs ad hoc.
set -euo pipefail

MODE="${1:-build}"
case "$MODE" in
    build|install) ;;
    *) echo "usage: $0 [install]" >&2; exit 2 ;;
esac

# The version shown to users (Settings, Finder's Get Info). Bump it for each release.
VERSION="0.6"
BUNDLE_ID="com.memorysaver.app"

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

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ja</string>
    <key>CFBundleLocalizations</key>
    <array/>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>MemorySaver</string>
    <key>CFBundleDisplayName</key>
    <string>MemorySaver</string>
    <key>CFBundleExecutable</key>
    <string>MemorySaver</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
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

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q '"MemorySaver Dev"'; then
        SIGN_IDENTITY="MemorySaver Dev"
    else
        SIGN_IDENTITY="-"
        echo "note: signing ad hoc, so Open at login breaks on every rebuild." \
            "Run scripts/make-signing-cert.sh once to fix that."
    fi
fi
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with: $SIGN_IDENTITY)"

if [ "$MODE" = "install" ]; then
    INSTALLED="/Applications/MemorySaver.app"
    # Ask the running copy to quit normally, whichever folder it runs from.
    if pgrep -xq MemorySaver; then
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" || true
        for _ in $(seq 1 50); do
            pgrep -xq MemorySaver || break
            sleep 0.1
        done
        if pgrep -xq MemorySaver; then
            echo "error: MemorySaver is still running. Quit it and try again." >&2
            exit 1
        fi
    fi
    rm -rf "$INSTALLED"
    ditto "$APP" "$INSTALLED"
    echo "Installed $INSTALLED"
    open "$INSTALLED"
fi
