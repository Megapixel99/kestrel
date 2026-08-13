#!/bin/bash
# Builds Kestrel.app.
#
# A bare SwiftPM binary launched from another program inherits that program's TCC
# "responsible process", so macOS attributes camera/microphone prompts to whatever
# started it. A real bundle launched through LaunchServices (`open`) is its own
# responsible process, so the prompt says Kestrel and the grant belongs to Kestrel.
set -e
CONFIG=${1:-debug}
swift build -c "$CONFIG"
APP="Kestrel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/kestrel" "$APP/Contents/MacOS/Kestrel"
cp Info.plist "$APP/Contents/Info.plist"
# The bundle executable name must match CFBundleExecutable.
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Kestrel" \
  "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Kestrel" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool false" "$APP/Contents/Info.plist" 2>/dev/null || true
# Ad-hoc signature: TCC keys grants to the signing identity, so a stable one keeps the
# permission across rebuilds. A real Developer ID would be better still.
codesign --force --deep --sign - \
  --identifier dev.kestrel.browser "$APP" 2>/dev/null
echo "built $APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" || true
