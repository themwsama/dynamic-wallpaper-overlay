#!/usr/bin/env bash
# One-shot installer: config, wallpaper video, app build, LaunchAgent. Idempotent.
# Env: DRY_RUN (any value except 0/false/no/off: print actions only), OUT_DIR, BUNDLE_ID,
#      CONFIG_DIR, LOG_PATH.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$REPO/scripts/lib.sh"
env_path OUT_DIR "$DEFAULT_OUT_DIR"
config_dir_init
env_path LOG_PATH "$DEFAULT_LOG_PATH"
validate_bundle_id
APP="$OUT_DIR/Wallpaper Overlay.app"
EXE="$APP/Contents/MacOS/wallpaper-overlay"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
VIDEO_DEFAULT="$CONFIG_DIR/wallpaper-stacked.mp4"
DOMAIN="gui/$(id -u)"

NAME=""; SUBTITLE=""; VIDEO=""; SAMPLE=0; SET_DESKTOP=0; LOGIN_ITEM=1; FORCE_CONFIG=0; STABLE_SIGNING=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

  --name NAME        name shown on the overlay
  --subtitle TEXT    subtitle shown on the overlay
  --video PATH       your video (any format); converted with make-wallpaper.sh
  --sample           generate and use the built-in sample video
  --set-desktop      also set the still image as the desktop picture
  --no-login-item    do not write/load the LaunchAgent (no start at login)
  --force-config     overwrite an existing config.json
  --stable-signing   create a local self-signed code-signing identity (once) so rebuilds keep
                     permission grants; see make-signing-identity.sh
  -h, --help         show this help
With neither --video nor --sample, an existing wallpaper is kept; otherwise the sample is used.
DRY_RUN=1 (any value except 0/false/no/off) prints every action without doing it.
USAGE
}

need_arg() { [[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) need_arg "$@"; NAME="$2"; shift 2 ;;
    --subtitle) need_arg "$@"; SUBTITLE="$2"; shift 2 ;;
    --video) need_arg "$@"; VIDEO="$2"; shift 2 ;;
    --sample) SAMPLE=1; shift ;;
    --set-desktop) SET_DESKTOP=1; shift ;;
    --no-login-item) LOGIN_ITEM=0; shift ;;
    --force-config) FORCE_CONFIG=1; shift ;;
    --stable-signing) STABLE_SIGNING=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

BOOTED_OUT=0
TMP_PLIST=""
# EXIT trap: drop temp plist; if we stopped the agent and failed before restarting it, bring the old one back.
on_exit() {
  local rc=$?
  [[ -z "$TMP_PLIST" ]] || rm -f "$TMP_PLIST"
  if (( rc != 0 && BOOTED_OUT == 1 )) && [[ -f "$PLIST" ]]; then
    echo "install failed (exit $rc); restarting the previous LaunchAgent $BUNDLE_ID" >&2
    launchctl bootstrap "$DOMAIN" "$PLIST" || echo "warning: could not restart $BUNDLE_ID; run: launchctl bootstrap $DOMAIN \"$PLIST\"" >&2
  fi
}
trap on_exit EXIT

say() { echo "==> $*"; }
# Escape for a JSON string body: backslash, quote, \b \f \n \r \t, other controls as \u00XX.
json_escape() {
  local s="$1" out="" c code i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      '\') out+='\\' ;;
      '"') out+='\"' ;;
      $'\b') out+='\b' ;;
      $'\f') out+='\f' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      *)
        printf -v code '%d' "'$c"
        if (( code >= 0 && code < 32 )); then printf -v c '\\u%04x' "$code"; fi
        out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# --- requirements
say "checking requirements"
[[ "$(uname -s)" == "Darwin" ]] || { echo "error: macOS only" >&2; exit 1; }
(( $(sw_vers -productVersion | cut -d. -f1) >= 26 )) || { echo "error: macOS 26 or newer required (found $(sw_vers -productVersion))" >&2; exit 1; }
command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found: xcode-select --install" >&2; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "error: ffmpeg not found: brew install ffmpeg" >&2; exit 1; }
[[ -z "$VIDEO" || -f "$VIDEO" ]] || { echo "error: --video file not found: $VIDEO" >&2; exit 1; }
echo "ok ($(uname -m))"

# --- config dir + config.json
say "config directory $CONFIG_DIR"
run mkdir -p "$CONFIG_DIR"
CONFIG="$CONFIG_DIR/config.json"
# Install marker: lets uninstall.sh delete a CONFIG_DIR not named wallpaper-overlay; records --set-desktop.
MARKER="$CONFIG_DIR/$CONFIG_MARKER"
if is_dry_run; then
  echo "[dry-run] write install marker $MARKER (set_desktop=$SET_DESKTOP or previous)"
else
  if [[ $SET_DESKTOP -eq 1 ]] || install_marker_has "set_desktop=1"; then MARKER_BODY="set_desktop=1"; else MARKER_BODY="set_desktop=0"; fi
  printf '%s\n' "wallpaper-overlay install marker" "$MARKER_BODY" > "$MARKER"
fi
if [[ -f "$CONFIG" && $FORCE_CONFIG -eq 0 ]]; then
  echo "config.json exists; keeping it (use --force-config to overwrite)"
elif is_dry_run; then
  echo "[dry-run] write $CONFIG from config.example.json (name='${NAME:-<example>}', subtitle='${SUBTITLE:-<example>}')"
else
  [[ -f "$REPO/config.example.json" ]] || { echo "error: missing $REPO/config.example.json" >&2; exit 1; }
  re_name='^([[:space:]]*)"name":[[:space:]]*"[^"]*"(,?)$'
  re_sub='^([[:space:]]*)"subtitle":[[:space:]]*"[^"]*"(,?)$'
  : > "$CONFIG"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$NAME" && "$line" =~ $re_name ]]; then
      line="${BASH_REMATCH[1]}\"name\": \"$(json_escape "$NAME")\"${BASH_REMATCH[2]}"
    elif [[ -n "$SUBTITLE" && "$line" =~ $re_sub ]]; then
      line="${BASH_REMATCH[1]}\"subtitle\": \"$(json_escape "$SUBTITLE")\"${BASH_REMATCH[2]}"
    fi
    printf '%s\n' "$line" >> "$CONFIG"
  done < "$REPO/config.example.json"
  echo "wrote $CONFIG"
fi

# --- wallpaper
if [[ -n "$VIDEO" ]]; then
  say "making wallpaper from $VIDEO"
  MW_ARGS=("$VIDEO"); [[ $SET_DESKTOP -eq 1 ]] && MW_ARGS+=(--set-desktop)
  run "$REPO/scripts/make-wallpaper.sh" "${MW_ARGS[@]}"
elif [[ $SAMPLE -eq 1 || ! -f "$VIDEO_DEFAULT" ]]; then
  say "making wallpaper from the sample video"
  SAMPLE_MP4="$CONFIG_DIR/sample-input.mp4"
  MW_ARGS=("$SAMPLE_MP4"); [[ $SET_DESKTOP -eq 1 ]] && MW_ARGS+=(--set-desktop)
  run "$REPO/scripts/make-sample-video.sh" --out "$SAMPLE_MP4"
  run "$REPO/scripts/make-wallpaper.sh" "${MW_ARGS[@]}"
else
  say "keeping existing wallpaper $VIDEO_DEFAULT"
  if [[ $SET_DESKTOP -eq 1 && -f "$CONFIG_DIR/wallpaper-still.png" ]]; then
    set_desktop_picture "$CONFIG_DIR/wallpaper-still.png"
  fi
fi

# --- stop a running copy just before the bundle is replaced (the wallpaper file was swapped by mv,
# so a running player keeps its old inode). If anything fails after this, the EXIT trap restarts it.
if [[ $LOGIN_ITEM -eq 1 ]] && launchctl print "$DOMAIN/$BUNDLE_ID" >/dev/null 2>&1; then
  say "stopping loaded LaunchAgent $BUNDLE_ID"
  run launchctl bootout "$DOMAIN/$BUNDLE_ID"
  is_dry_run || BOOTED_OUT=1
fi

# --- build
if [[ $STABLE_SIGNING -eq 1 ]]; then
  say "ensuring stable local signing identity"
  run "$REPO/scripts/make-signing-identity.sh"
fi
say "building app"
run "$REPO/scripts/build.sh"

# --- LaunchAgent
if [[ $LOGIN_ITEM -eq 1 ]]; then
  say "writing LaunchAgent $PLIST"
  if is_dry_run; then
    echo "[dry-run] write plist: Label=$BUNDLE_ID ProgramArguments=$EXE RunAtLoad KeepAlive ProcessType=Interactive StandardErrorPath=$LOG_PATH EnvironmentVariables{WALLPAPER_OVERLAY_DIR=$CONFIG_DIR WALLPAPER_OVERLAY_LOG=$LOG_PATH}"
  else
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG_PATH")"
    TMP_PLIST="$PLIST.tmp.$$"
    plutil -create xml1 "$TMP_PLIST"
    plutil -insert Label -string "$BUNDLE_ID" "$TMP_PLIST"
    plutil -insert ProgramArguments -array "$TMP_PLIST"
    plutil -insert ProgramArguments -string "$EXE" -append "$TMP_PLIST"
    plutil -insert RunAtLoad -bool YES "$TMP_PLIST"
    plutil -insert KeepAlive -bool YES "$TMP_PLIST"
    plutil -insert ProcessType -string Interactive "$TMP_PLIST"
    plutil -insert StandardErrorPath -string "$LOG_PATH" "$TMP_PLIST"
    plutil -insert EnvironmentVariables -dictionary "$TMP_PLIST"
    plutil -insert EnvironmentVariables.WALLPAPER_OVERLAY_DIR -string "$CONFIG_DIR" "$TMP_PLIST"
    plutil -insert EnvironmentVariables.WALLPAPER_OVERLAY_LOG -string "$LOG_PATH" "$TMP_PLIST"
    plutil -lint "$TMP_PLIST" >/dev/null || { echo "error: generated LaunchAgent plist is invalid" >&2; exit 1; }
    mv "$TMP_PLIST" "$PLIST"
  fi
  run launchctl bootstrap "$DOMAIN" "$PLIST"
  BOOTED_OUT=0
else
  say "skipping LaunchAgent (--no-login-item); start manually: open \"$APP\""
fi

cat <<NOTES

Done. Permissions you may be asked for:
  - System Audio Recording Only: lets the glow pulse with Spotify's beat.
  - Control of Spotify (Automation): keeps lyrics in sync.
  - System Events (Automation, optional): only for --set-desktop.

Optional API keys (stored in your Keychain):
  security add-generic-password -s wallpaper-overlay -a gemini-api-key -w
  security add-generic-password -s wallpaper-overlay -a spotify-client-id -w
  security add-generic-password -s wallpaper-overlay -a spotify-client-secret -w

Log: $LOG_PATH
NOTES
