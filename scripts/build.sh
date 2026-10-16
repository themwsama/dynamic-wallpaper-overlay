#!/usr/bin/env bash
# Build Wallpaper Overlay as a macOS app bundle from Sources/*.swift.
# Env: OUT_DIR (default ~/Applications), BUNDLE_ID (default local.wallpaper-overlay),
#      CONFIG_DIR (default ~/.config/wallpaper-overlay).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$HOME/Applications}"
BUNDLE_ID="${BUNDLE_ID:-local.wallpaper-overlay}"
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/wallpaper-overlay}"
APP_NAME="Wallpaper Overlay"
EXE="wallpaper-overlay"
BUNDLE="$OUT_DIR/$APP_NAME.app"
MIN_MACOS=26

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--install]

Compiles Sources/*.swift into "$BUNDLE", ad-hoc signs it, and copies
Transition.metal to $CONFIG_DIR.
  --install   also restart the LaunchAgent ($BUNDLE_ID) if it is loaded
  -h, --help  show this help
USAGE
}

INSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) INSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || { echo "error: macOS only" >&2; exit 1; }
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( MAJOR >= MIN_MACOS )) || { echo "error: macOS $MIN_MACOS or newer required (found $(sw_vers -productVersion))" >&2; exit 1; }
command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found: xcode-select --install" >&2; exit 1; }
compgen -G "$REPO/Sources/*.swift" >/dev/null || { echo "error: no Swift sources in $REPO/Sources" >&2; exit 1; }
[[ -f "$REPO/Sources/Transition.metal" ]] || { echo "error: missing $REPO/Sources/Transition.metal" >&2; exit 1; }

# Fresh bundle skeleton
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"

# Compile
swiftc -O "$REPO"/Sources/*.swift -o "$BUNDLE/Contents/MacOS/$EXE" \
  || { echo "error: swiftc failed" >&2; exit 1; }

# Info.plist
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$EXE</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>$APP_NAME asks Spotify what's playing and its playback position so lyrics stay in sync.</string>
	<key>NSAudioCaptureUsageDescription</key>
	<string>$APP_NAME listens to Spotify's audio (never recorded or saved) so the wallpaper glow can pulse with the beat.</string>
</dict>
</plist>
PLIST
plutil -lint "$BUNDLE/Contents/Info.plist" >/dev/null

# Ad-hoc sign (permissions may re-prompt after rebuilds), then verify.
codesign --force --sign - --identifier "$BUNDLE_ID" "$BUNDLE"
codesign --verify "$BUNDLE" || { echo "error: codesign verification failed" >&2; exit 1; }

# The shader is compiled at launch from the config dir.
mkdir -p "$CONFIG_DIR"
cp "$REPO/Sources/Transition.metal" "$CONFIG_DIR/Transition.metal"

if [[ $INSTALL -eq 1 ]]; then
  if launchctl print "gui/$(id -u)/$BUNDLE_ID" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/$BUNDLE_ID"
  else
    echo "note: launchd job $BUNDLE_ID not loaded; nothing restarted."
  fi
fi

echo "$BUNDLE"
