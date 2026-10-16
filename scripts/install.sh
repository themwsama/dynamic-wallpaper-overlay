#!/usr/bin/env bash
# One-shot installer: config, wallpaper video, app build, LaunchAgent. Idempotent.
# Env: DRY_RUN=1 (print actions only), OUT_DIR, BUNDLE_ID, CONFIG_DIR.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OUT_DIR="${OUT_DIR:-$HOME/Applications}"
export BUNDLE_ID="${BUNDLE_ID:-local.wallpaper-overlay}"
export CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/wallpaper-overlay}"
DRY_RUN="${DRY_RUN:-0}"
APP="$OUT_DIR/Wallpaper Overlay.app"
EXE="$APP/Contents/MacOS/wallpaper-overlay"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
LOG="$HOME/Library/Logs/wallpaper-overlay.log"
VIDEO_DEFAULT="$CONFIG_DIR/wallpaper-stacked.mp4"
DOMAIN="gui/$(id -u)"

NAME=""; SUBTITLE=""; VIDEO=""; SAMPLE=0; SET_DESKTOP=0; LOGIN_ITEM=1; FORCE_CONFIG=0

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
  -h, --help         show this help
With neither --video nor --sample, an existing wallpaper is kept; otherwise the sample is used.
DRY_RUN=1 prints every action without doing it.
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
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say() { echo "==> $*"; }
# Run a command, or just print it under DRY_RUN=1.
run() { if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] $*"; else "$@"; fi; }
json_escape() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

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
if [[ -f "$CONFIG" && $FORCE_CONFIG -eq 0 ]]; then
  echo "config.json exists; keeping it (use --force-config to overwrite)"
elif [[ "$DRY_RUN" == 1 ]]; then
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
    run osascript -e "tell application \"System Events\" to tell every desktop to set picture to POSIX file \"$CONFIG_DIR/wallpaper-still.png\""
  fi
fi

# --- stop a running copy before its bundle is replaced
if [[ $LOGIN_ITEM -eq 1 ]] && launchctl print "$DOMAIN/$BUNDLE_ID" >/dev/null 2>&1; then
  say "stopping loaded LaunchAgent $BUNDLE_ID"
  run launchctl bootout "$DOMAIN/$BUNDLE_ID"
fi

# --- build
say "building app"
run "$REPO/scripts/build.sh"

# --- LaunchAgent
if [[ $LOGIN_ITEM -eq 1 ]]; then
  say "writing LaunchAgent $PLIST"
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "[dry-run] write plist: Label=$BUNDLE_ID ProgramArguments=$EXE RunAtLoad KeepAlive ProcessType=Interactive StandardErrorPath=$LOG"
  else
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$BUNDLE_ID</string>
	<key>ProgramArguments</key>
	<array>
		<string>$EXE</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
</dict>
</plist>
PLISTEOF
    plutil -lint "$PLIST" >/dev/null
  fi
  run launchctl bootstrap "$DOMAIN" "$PLIST"
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

Log: $LOG
NOTES
