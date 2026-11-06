#!/bin/bash
# PathBar installer: builds PathBar from source into ~/Applications and starts it at login.
#
#   bash install.sh             install or update
#   bash install.sh --no-login  build and open it, without starting at login
#
# Needs macOS 13+ and the Xcode Command Line Tools (for the Swift compiler).
# The first time, it creates a personal code-signing certificate (see setup-signing.sh) so
# that later updates keep PathBar's Accessibility permission. Nothing needs admin rights.
set -euo pipefail

LABEL="local.pathbar"                # login item (LaunchAgent) name
BUNDLE_ID="local.pathbar.helper"     # changing this makes macOS treat PathBar as a new app
VERSION="1.1.0"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/PathBar.app"
BIN="$APP/Contents/MacOS/PathBar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/PathBar.log"
SIGN_ID="PathBar Local Signing"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

say() { printf '\033[1m%s\033[0m\n' "$*"; }

# --- Checks -------------------------------------------------------------------------------
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MACOS_MAJOR" -lt 13 ]; then
  echo "PathBar needs macOS 13 (Ventura) or newer. This Mac runs $(sw_vers -productVersion)."
  exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "The Swift compiler is missing. Install Apple's Command Line Tools (free, no Xcode needed):"
  echo "    xcode-select --install"
  echo "Then run this installer again."
  xcode-select --install >/dev/null 2>&1 || true
  exit 1
fi

SOURCES=("$HERE"/Sources/*.swift)
SRC_HASH="$(cat "${SOURCES[@]}" "$HERE/install.sh" | shasum -a 256 | cut -c1-40)"
STAMP="$APP/Contents/Resources/source-hash"

# --- Signing certificate (once) -------------------------------------------------------------
if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  say "Creating your PathBar signing certificate (one time)…"
  echo "If macOS asks whether \"codesign\" may use the key, enter your Mac password and click Always Allow."
  bash "$HERE/setup-signing.sh" || echo "Couldn't create the certificate; continuing without it (updates will need the permission again)."
fi
HAVE_CERT=0
security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\"" && HAVE_CERT=1

# --- Stop the running copy ----------------------------------------------------------------
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x PathBar 2>/dev/null || true
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$HOME/Applications"

# How macOS currently identifies an installed PathBar (empty if none).
requirement() { codesign -dr - "$APP" 2>/dev/null | sed -n 's/^#* *designated => //p'; }
OLD_REQ="$(requirement)"
OLD_ID="$(codesign -dv "$APP" 2>&1 | sed -n 's/^Identifier=//p')"

NEED_BUILD=1
if [ -x "$BIN" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$SRC_HASH" ]; then NEED_BUILD=0; fi
# Certificate created after an earlier install: re-sign so updates keep the permission.
if [ "$HAVE_CERT" = 1 ] && [ -n "$OLD_REQ" ] && ! echo "$OLD_REQ" | grep -q 'certificate leaf'; then NEED_BUILD=1; fi

# --- Build --------------------------------------------------------------------------------
if [ "$NEED_BUILD" = 0 ]; then
  say "PathBar ${VERSION} is already up to date."
else
  say "Building PathBar ${VERSION}…"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  xcrun swiftc -O -swift-version 5 "${SOURCES[@]}" -o "$BIN"
  "$BIN" --selftest >/dev/null || { echo "Self-test failed; not installing."; exit 1; }
  echo "$SRC_HASH" > "$STAMP"

cat > "$APP/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>PathBar</string>
    <key>CFBundleDisplayName</key><string>PathBar</string>
    <key>CFBundleExecutable</key><string>PathBar</string>
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

  if [ "$HAVE_CERT" = 1 ]; then
    echo "Signing… (if macOS asks whether \"codesign\" may use the PathBar key, enter your Mac password and click Always Allow)"
    codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP" 2>/dev/null
  else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1
  fi
  NEW_REQ="$(requirement)"
  # Tell macOS's app index about the app, or System Settings may not find it.
  "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true

  if [ -n "$OLD_REQ" ] && [ "$OLD_ID" = "$BUNDLE_ID" ] && [ "$OLD_REQ" != "$NEW_REQ" ]; then
    # macOS keeps the permission tied to the old signature and won't ask again by itself,
    # so clear that entry (System Settings must be closed, or it writes the old one back).
    say "PathBar's signature changed, so its Accessibility permission has to be given once more."
    echo "Clearing the old permission (asks for your Mac password)…"
    osascript -e 'quit app "System Settings"' >/dev/null 2>&1 || true
    sudo tccutil reset Accessibility "$BUNDLE_ID" >/dev/null || true
  fi
fi

# --- Start --------------------------------------------------------------------------------
if [ "${1:-}" = "--no-login" ]; then
  rm -f "$PLIST"
  open "$APP"
  say "Built and opened PathBar (folder icon in the menu bar). It won't start at login."
else
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$BIN</string></array>
    <key>EnvironmentVariables</key>
    <dict><key>PATHBAR_LAUNCHD</key><string>1</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLISTEOF
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  say "Installed PathBar ${VERSION} (folder icon in the menu bar). It starts at login."
fi

sleep 2
if grep -q "accessibility granted" <(tail -n 3 "$LOG" 2>/dev/null); then
  echo "Accessibility permission: already granted. Open any Save dialog to try it."
else
  echo
  say "One last step: allow Accessibility."
  echo "macOS shows \"PathBar would like to control this computer\": click Open System Settings"
  echo "and switch PathBar on (System Settings > Privacy & Security > Accessibility)."
fi
