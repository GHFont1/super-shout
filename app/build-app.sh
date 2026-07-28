#!/bin/bash
# Builds SuperShout.app from the SwiftPM executable and installs to /Applications (optional).
set -euo pipefail
cd "$(dirname "$0")"

# Universal binary so Intel Macs work too.
swift build -c release --arch arm64 --arch x86_64

APP=build/SuperShout.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/SuperShout "$APP/Contents/MacOS/SuperShout"
cp Resources/* "$APP/Contents/Resources/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SuperShout</string>
    <key>CFBundleIdentifier</key><string>com.gca.supershout</string>
    <key>CFBundleName</key><string>Super Shout</string>
    <key>CFBundleDisplayName</key><string>Super Shout</string>
    <key>CFBundleShortVersionString</key><string>1.5</string>
    <key>CFBundleVersion</key><string>5</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Super Shout listens while you hold the hotkey so it can transcribe your speech.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Super Shout transcribes your speech on-device to insert text where you are typing.</string>
</dict>
</plist>
PLIST

# Hardened runtime entitlements (required for notarization; mic access).
cat > build/entitlements.plist <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
ENT

# Prefer Developer ID (public distribution + notarization); fall back to the
# development identity so builds still work on machines without it.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
    codesign --force --deep --sign "$IDENTITY" --identifier com.gca.supershout \
        --options runtime --entitlements build/entitlements.plist --timestamp "$APP"
    echo "Signed with: $IDENTITY (hardened runtime)"
else
    IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
    codesign --force --deep --sign "${IDENTITY:--}" --identifier com.gca.supershout "$APP"
    echo "Signed with: ${IDENTITY:-ad-hoc}"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/Super Shout.app"
    cp -R "$APP" "/Applications/Super Shout.app"
    echo "Installed to /Applications/Super Shout.app"
fi
