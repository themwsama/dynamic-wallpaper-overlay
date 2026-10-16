#!/usr/bin/env bash
# Remove LaunchAgent, app bundle, config and log. Env: DRY_RUN=1, OUT_DIR, BUNDLE_ID, CONFIG_DIR.
set -euo pipefail

OUT_DIR="${OUT_DIR:-$HOME/Applications}"
BUNDLE_ID="${BUNDLE_ID:-local.wallpaper-overlay}"
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/wallpaper-overlay}"
DRY_RUN="${DRY_RUN:-0}"
APP="$OUT_DIR/Wallpaper Overlay.app"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
LOG="$HOME/Library/Logs/wallpaper-overlay.log"
KEEP_CONFIG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-config) KEEP_CONFIG=1; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--keep-config]"
      echo "Stops the LaunchAgent, removes plist, app, log and (unless --keep-config) $CONFIG_DIR."
      echo "Keychain items are never touched. DRY_RUN=1 prints actions only."
      exit 0 ;;
    *) echo "error: unknown option: $1" >&2; exit 2 ;;
  esac
done

run() { if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] $*"; else "$@"; fi; }

if launchctl print "gui/$(id -u)/$BUNDLE_ID" >/dev/null 2>&1; then
  run launchctl bootout "gui/$(id -u)/$BUNDLE_ID"
else
  echo "LaunchAgent $BUNDLE_ID not loaded"
fi
run rm -f "$PLIST"
run rm -rf "$APP"
run rm -f "$LOG"
if [[ $KEEP_CONFIG -eq 1 ]]; then echo "keeping $CONFIG_DIR"; else run rm -rf "$CONFIG_DIR"; fi

cat <<NOTES

Keychain items were left alone. Remove them if you added them:
  security delete-generic-password -s wallpaper-overlay -a gemini-api-key
  security delete-generic-password -s wallpaper-overlay -a spotify-client-id
  security delete-generic-password -s wallpaper-overlay -a spotify-client-secret
NOTES
