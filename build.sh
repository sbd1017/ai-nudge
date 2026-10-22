#!/bin/sh
# Builds "AI Nudge.app" into ./build. Signs with your Apple Development certificate if you have one
# (so macOS remembers the Accessibility permission across rebuilds), otherwise ad hoc.
set -e
cd "$(dirname "$0")"
# UNIVERSAL=1 builds for Apple silicon and Intel. Source paths are mapped to "." so the binary
# doesn't carry the folder it was built in.
FLAGS="-c release -Xswiftc -file-prefix-map -Xswiftc $PWD=."
[ -n "${UNIVERSAL:-}" ] && FLAGS="$FLAGS --arch arm64 --arch x86_64"
swift build $FLAGS
BIN="$(swift build $FLAGS --show-bin-path)/AINudge"
APP="build/AI Nudge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AINudge"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AI Nudge</string>
  <key>CFBundleDisplayName</key><string>AI Nudge</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID:-local.ai-nudge}</string>
  <key>CFBundleExecutable</key><string>AINudge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT licence</string>
</dict>
</plist>
PLIST
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad hoc})"
