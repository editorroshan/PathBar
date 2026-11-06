#!/bin/bash
# Builds a ready-to-run installer, dist/PathBar-<version>.dmg, for people who don't want to build
# from source: one app for Apple Silicon and Intel Macs, macOS 13+. They drag it to Applications
# and open it; it adds itself to the login items and asks for Accessibility.
#
# Signed with your "PathBar Local Signing" certificate (setup-signing.sh) when you have it, so
# people keep their Accessibility permission when they install a later DMG made the same way.
# It is not notarized by Apple (that needs a paid developer account), so macOS asks people to
# confirm the first open; "Read Me First" in the DMG explains how.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$HERE/install.sh")"
BUNDLE_ID="local.pathbar.helper"
SIGN_ID="PathBar Local Signing"
OUT="$HERE/dist"
STAGE="$OUT/stage"
APP="$STAGE/PathBar.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Building PathBar $VERSION for Apple Silicon and Intel…"
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" "$HERE"/Sources/*.swift -o "$TMP/PathBar-$arch"
done
lipo -create "$TMP/PathBar-arm64" "$TMP/PathBar-x86_64" -output "$APP/Contents/MacOS/PathBar"
"$APP/Contents/MacOS/PathBar" --selftest >/dev/null

cp "$HERE/Resources/PathBar.icns" "$APP/Contents/Resources/PathBar.icns"   # made from Resources/icon-source.png by Resources/make-icon.swift

cat > "$APP/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>PathBar</string>
    <key>CFBundleDisplayName</key><string>PathBar</string>
    <key>CFBundleExecutable</key><string>PathBar</string>
    <key>CFBundleIconFile</key><string>PathBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>PathBar lists the folders of your open Finder windows so you can jump a Save or Open dialog to them.</string>
    <key>NSHumanReadableCopyright</key><string>A typed path bar for Save/Open dialogs and Finder windows. MIT licensed.</string>
</dict>
</plist>
PLISTEOF

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  echo "Signing with \"$SIGN_ID\"…"
  codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
else
  echo "No \"$SIGN_ID\" certificate (run setup-signing.sh); signing without one."
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<EOF
PathBar $VERSION
A Windows-style address bar for Save/Open dialogs and Finder windows.
Works on Apple Silicon and Intel Macs with macOS 13 Ventura or newer.

INSTALL
1. Drag PathBar onto the Applications folder in this window.
2. Open Applications and double-click PathBar.

3. macOS says "Apple could not verify PathBar…" (it's a free app, not sold through
   Apple, so it isn't notarized). Click Done, then:
   System Settings → Privacy & Security → scroll down → "PathBar was blocked…"
   → click Open Anyway → enter your password → Open.
   (You only do this once.)

4. macOS asks: "PathBar would like to control this computer using accessibility
   features". Click Open System Settings and switch PathBar ON.
   PathBar needs this to see Save/Open dialogs and move them to a folder.

Done. A folder icon appears in the menu bar, and PathBar starts by itself at login.

USE
- Save/Open dialogs (browser downloads, Save As…): the bar appears above the dialog.
  Click the path, type or paste a folder path, press Return to jump there.
- Finder: click the folder name at the top of the window to show the path.
- ↑ goes up a folder, Tab completes folder names, the clock button shows recent folders.
- Menu bar folder icon: turn it off for dialogs or Finder, Open at Login, Quit.

REMOVE
Quit PathBar from its menu, drag it from Applications to the Bin, and remove it from
System Settings → Privacy & Security → Accessibility and → General → Login Items.

Free and open source (MIT).
EOF

DMG="$OUT/PathBar-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "PathBar $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
echo "Done: $DMG"
