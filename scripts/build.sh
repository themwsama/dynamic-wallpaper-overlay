#!/usr/bin/env bash
# Build Wallpaper Overlay as a macOS app bundle from Sources/*.swift.
# Env: OUT_DIR (default ~/Applications), BUNDLE_ID (default local.wallpaper-overlay),
#      CONFIG_DIR (default ~/.config/wallpaper-overlay), DRY_RUN (any value except 0/false/no/off).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$REPO/scripts/lib.sh"
env_path OUT_DIR "$DEFAULT_OUT_DIR"
config_dir_init
validate_bundle_id
APP_NAME="Wallpaper Overlay"
EXE="wallpaper-overlay"
BUNDLE="$OUT_DIR/$APP_NAME.app"
MIN_MACOS=26

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--install]

Compiles Sources/*.swift into "$BUNDLE" (built in a temp bundle first, then moved
into place; a failed build leaves the old app untouched), ad-hoc signs it, and puts
Transition.metal in the bundle's Resources. $CONFIG_DIR/Transition.metal is only
created when missing; an existing copy is never overwritten.
  --install   also restart the LaunchAgent ($BUNDLE_ID) if it is loaded
  -h, --help  show this help
DRY_RUN=1 (or any value except 0/false/no/off) prints the plan without doing anything.
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

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only"
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( MAJOR >= MIN_MACOS )) || die "macOS $MIN_MACOS or newer required (found $(sw_vers -productVersion))"
command -v swiftc >/dev/null 2>&1 || die "swiftc not found: xcode-select --install"
compgen -G "$REPO/Sources/*.swift" >/dev/null || die "no Swift sources in $REPO/Sources"
[[ -f "$REPO/Sources/Transition.metal" ]] || die "missing $REPO/Sources/Transition.metal"
check_rm_target "$BUNDLE" app || exit 1

if is_dry_run; then
  echo "[dry-run] would compile $REPO/Sources/*.swift into a temp bundle in $OUT_DIR"
  echo "[dry-run] would write Info.plist (CFBundleIdentifier=$BUNDLE_ID), copy Transition.metal to Resources, codesign"
  echo "[dry-run] would move it to $BUNDLE (replacing any old bundle)"
  echo "[dry-run] would copy Transition.metal to $CONFIG_DIR only if missing (else write Transition.metal.new if it differs)"
  (( INSTALL == 0 )) || echo "[dry-run] would kickstart gui/$(id -u)/$BUNDLE_ID if loaded"
  echo "$BUNDLE"
  exit 0
fi

mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d "$OUT_DIR/.wo-build.XXXXXX")"
cleanup() { safe_rm_rf "$STAGE" glob '.wo-build.*' || true; }
trap cleanup EXIT
NEW="$STAGE/$APP_NAME.app"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"

swiftc -O "$REPO"/Sources/*.swift -o "$NEW/Contents/MacOS/$EXE" || die "swiftc failed; existing app left untouched"

# Info.plist (plutil escapes values for us)
INFO="$NEW/Contents/Info.plist"
plutil -create xml1 "$INFO"
plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$INFO"
plutil -insert CFBundleName -string "$APP_NAME" "$INFO"
plutil -insert CFBundleDisplayName -string "$APP_NAME" "$INFO"
plutil -insert CFBundleExecutable -string "$EXE" "$INFO"
plutil -insert CFBundlePackageType -string APPL "$INFO"
plutil -insert CFBundleShortVersionString -string 1.0 "$INFO"
plutil -insert CFBundleVersion -string 1 "$INFO"
plutil -insert LSMinimumSystemVersion -string "$MIN_MACOS.0" "$INFO"
plutil -insert LSUIElement -bool YES "$INFO"
plutil -insert NSAppleEventsUsageDescription -string "$APP_NAME asks Spotify what's playing and its playback position so lyrics stay in sync." "$INFO"
plutil -insert NSAudioCaptureUsageDescription -string "$APP_NAME listens to Spotify's audio (never recorded or saved) so the wallpaper glow can pulse with the beat." "$INFO"
plutil -lint "$INFO" >/dev/null || die "generated Info.plist is invalid"

# Shader: bundled copy is the fallback the app loads when the config copy is missing or broken.
cp "$REPO/Sources/Transition.metal" "$NEW/Contents/Resources/Transition.metal"

# Ad-hoc sign (permissions may re-prompt after rebuilds), then verify.
codesign --force --sign - --identifier "$BUNDLE_ID" "$NEW"
codesign --verify "$NEW" || die "codesign verification failed; existing app left untouched"

# Swap in. The old bundle is parked in the stage dir until the new one is in place.
if [[ -e "$BUNDLE" ]]; then
  mv "$BUNDLE" "$STAGE/old.app"
  mv "$NEW" "$BUNDLE" || { mv "$STAGE/old.app" "$BUNDLE"; die "could not move new bundle into place; old app restored"; }
else
  mv "$NEW" "$BUNDLE"
fi

# User's shader copy is never overwritten.
mkdir -p "$CONFIG_DIR"
USER_SHADER="$CONFIG_DIR/Transition.metal"
if [[ ! -e "$USER_SHADER" ]]; then
  cp "$REPO/Sources/Transition.metal" "$USER_SHADER"
elif ! cmp -s "$REPO/Sources/Transition.metal" "$USER_SHADER"; then
  cp "$REPO/Sources/Transition.metal" "$USER_SHADER.new"
  echo "note: your edited shader was kept: $USER_SHADER (differs from the bundled one)."
  echo "      the new version is at $USER_SHADER.new"
  echo "      compare: diff \"$USER_SHADER\" \"$USER_SHADER.new\""
  echo "      to adopt: mv \"$USER_SHADER.new\" \"$USER_SHADER\""
fi
[[ ! -e "$USER_SHADER.new" ]] || ! cmp -s "$REPO/Sources/Transition.metal" "$USER_SHADER" || rm -f "$USER_SHADER.new"

if [[ $INSTALL -eq 1 ]]; then
  if launchctl print "gui/$(id -u)/$BUNDLE_ID" >/dev/null 2>&1; then
    run launchctl kickstart -k "gui/$(id -u)/$BUNDLE_ID"
  else
    echo "note: launchd job $BUNDLE_ID not loaded; nothing restarted."
  fi
fi

echo "$BUNDLE"
