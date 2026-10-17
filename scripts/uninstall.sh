#!/usr/bin/env bash
# Remove LaunchAgent, app bundle, preferences, config and log.
# Env: DRY_RUN (any value except 0/false/no/off), OUT_DIR, BUNDLE_ID, CONFIG_DIR, LOG_PATH.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$REPO/scripts/lib.sh"
env_path OUT_DIR "$DEFAULT_OUT_DIR"
config_dir_init
env_path LOG_PATH "$DEFAULT_LOG_PATH"
validate_bundle_id
APP="$OUT_DIR/Wallpaper Overlay.app"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
PREFS="$HOME/Library/Preferences/$BUNDLE_ID.plist"
STILL="$CONFIG_DIR/wallpaper-still.png"
DEFAULT_DESKTOP="/System/Library/CoreServices/DefaultDesktop.heic"
KEEP_CONFIG=0; ASSUME_YES=0; RESET_DESKTOP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-config) KEEP_CONFIG=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --reset-desktop) RESET_DESKTOP=1; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--keep-config] [--yes] [--reset-desktop]"
      echo "Stops the LaunchAgent ($BUNDLE_ID), removes its plist, the app, preferences, log"
      echo "and (unless --keep-config) $CONFIG_DIR."
      echo "  --yes             do not ask before deleting the config directory"
      echo "  --reset-desktop   if the desktop picture is wallpaper-still.png, set $DEFAULT_DESKTOP"
      echo "Keychain items are never touched. DRY_RUN=1 (any value except 0/false/no/off) prints actions only."
      exit 0 ;;
    *) echo "error: unknown option: $1" >&2; exit 2 ;;
  esac
done

# Validate every delete target before touching anything.
check_rm_target "$APP" app || exit 1
check_rm_target "$LOG_PATH" log || exit 1
check_rm_target "$PLIST" plist || exit 1
check_rm_target "$PREFS" plist || exit 1
[[ $KEEP_CONFIG -eq 1 ]] || check_rm_target "$CONFIG_DIR" leaf || exit 1

confirm_config_removal() {
  echo "The following will be deleted from $CONFIG_DIR:"
  ls -A "$CONFIG_DIR" | sed 's/^/  /'
  if is_dry_run; then echo "[dry-run] would ask for confirmation"; return 0; fi
  [[ $ASSUME_YES -eq 1 ]] && return 0
  if [[ ! -t 0 ]]; then
    echo "not interactive and --yes not given: keeping $CONFIG_DIR" >&2
    return 1
  fi
  local reply
  read -r -p "Delete $CONFIG_DIR? [y/N] " reply
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

# Is the still the current desktop picture? Queries System Events (a permission prompt) only when
# --reset-desktop was given, or the still exists and install recorded set_desktop=1.
still_is_desktop() {
  [[ -f "$STILL" ]] || return 1
  if [[ $RESET_DESKTOP -ne 1 ]] && ! install_marker_has "set_desktop=1"; then return 1; fi
  local current real
  if ! current="$(get_desktop_pictures)"; then
    echo "note: could not query System Events for the desktop picture; if $STILL is your desktop picture, pick another in System Settings > Wallpaper." >&2
    return 1
  fi
  real="$(resolve_path "$STILL")"
  [[ "$current" == *"$STILL"* || "$current" == *"$real"* ]]
}

if launchctl print "gui/$(id -u)/$BUNDLE_ID" >/dev/null 2>&1; then
  run launchctl bootout "gui/$(id -u)/$BUNDLE_ID"
else
  echo "LaunchAgent $BUNDLE_ID not loaded"
fi
safe_rm_file "$PLIST" plist
safe_rm_rf "$APP" app
run defaults delete "$BUNDLE_ID" 2>/dev/null || true
safe_rm_file "$PREFS" plist
safe_rm_file "$LOG_PATH" log

if [[ $KEEP_CONFIG -eq 1 ]]; then
  echo "keeping $CONFIG_DIR"
elif [[ ! -d "$CONFIG_DIR" ]]; then
  echo "$CONFIG_DIR does not exist"
else
  if still_is_desktop; then
    if [[ $RESET_DESKTOP -eq 1 ]]; then
      echo "desktop picture is $STILL; resetting to $DEFAULT_DESKTOP"
      set_desktop_picture "$DEFAULT_DESKTOP"
    else
      echo "warning: $STILL is your current desktop picture. Pick a new one in System Settings > Wallpaper (or rerun with --reset-desktop)."
    fi
  fi
  if confirm_config_removal; then
    safe_rm_rf "$CONFIG_DIR" leaf
  else
    echo "keeping $CONFIG_DIR"
  fi
fi

cat <<NOTES

Keychain items were left alone. Remove them if you added them:
  security delete-generic-password -s wallpaper-overlay -a gemini-api-key
  security delete-generic-password -s wallpaper-overlay -a spotify-client-id
  security delete-generic-password -s wallpaper-overlay -a spotify-client-secret
NOTES
