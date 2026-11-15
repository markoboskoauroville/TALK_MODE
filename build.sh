#!/bin/sh
# build.sh: Talk Mode (Mantra).app, swiftc straight, no Xcode. Run ONLY by GitHub Actions (.github/workflows/build.yml;
# MANTRA_MANIFEST modules/compile-on-github.md: nothing compiles on the Mac). The version is VERSION in app/App.swift.
# On the Mac: gh release download, unzip into /Applications, sign "Mantra Apps" (TAKEOVER.md, Install).
set -e
cd "$(dirname "$0")"
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/App.swift)
NAME="Talk Mode (Mantra)"
APP="build/$NAME.app"
rm -rf build; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -o "$APP/Contents/MacOS/TalkMode" app/*.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreAudio -framework Carbon
[ -x "$APP/Contents/MacOS/TalkMode" ] || { echo "the app did not build"; exit 1; }
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleDisplayName</key><string>$NAME</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>community.auroville.talkmode</string>
<key>CFBundleExecutable</key><string>TalkMode</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$V</string>
<key>CFBundleVersion</key><string>$V</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Talk Mode (Mantra) listens to you, waits for your pause, and writes what you said into the Claude Code session you chose.</string>
<key>NSAppleEventsUsageDescription</key><string>Talk Mode (Mantra) writes your spoken words into the chosen Claude Code session in iTerm2.</string>
<key>CFBundleURLTypes</key><array><dict>
  <key>CFBundleURLName</key><string>community.auroville.talkmode</string>
  <key>CFBundleURLSchemes</key><array><string>talkmode</string></array>
</dict></array>
</dict></plist>
PL
I=build/AppIcon.iconset; mkdir -p $I
for s in 16 32 128 256 512; do
  sips -z $s $s icon/six_1024.png --out $I/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) icon/six_1024.png --out $I/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $I -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force -s "${SIGN:-Mantra Apps}" "$APP"
echo "built $APP (v$V)"
