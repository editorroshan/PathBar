#!/bin/bash
# Removes PathBar: stops it, removes the login item and the app.
#   bash uninstall.sh        keep settings and the signing certificate (for reinstalling)
#   bash uninstall.sh --all  also delete its settings and the "PathBar Local Signing" certificate
LABEL="local.pathbar"
BUNDLE_ID="local.pathbar.helper"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x PathBar 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/PathBar.app"
if [ "${1:-}" = "--all" ]; then
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Logs/PathBar.log" "$HOME/Library/Logs/PathBar-dump.txt" "$HOME/Library/Logs/PathBar-snap.png"
  security delete-identity -c "PathBar Local Signing" >/dev/null 2>&1 && echo "Deleted the PathBar signing certificate."
fi
echo "PathBar removed."
echo "Also remove it from System Settings > Privacy & Security > Accessibility (select it, click −)."
