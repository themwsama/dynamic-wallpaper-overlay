#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts. Bash 3.2 compatible.

DEFAULT_CONFIG_DIR="$HOME/.config/wallpaper-overlay"
DEFAULT_OUT_DIR="$HOME/Applications"
DEFAULT_BUNDLE_ID="local.wallpaper-overlay"
DEFAULT_LOG_PATH="$HOME/Library/Logs/wallpaper-overlay.log"
EXPECTED_CONFIG_LEAF="wallpaper-overlay"
CONFIG_MARKER=".wallpaper-overlay"
MIN_RM_COMPONENTS=3

die() { echo "error: $*" >&2; exit 1; }

# DRY_RUN: any non-empty value except 0/false/no/off (case-insensitive).
is_dry_run() {
  local v
  v="$(printf '%s' "${DRY_RUN:-}" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    ""|0|false|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

# Run a command, or only print it under dry-run.
run() {
  if is_dry_run; then
    printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

# Absolute physical path; the tail may not exist yet. Fails on "." / ".." in the missing tail.
resolve_path() {
  local p="$1" tail="" d
  [[ -n "$p" ]] || return 1
  [[ "$p" == /* ]] || p="$PWD/$p"
  while [[ "$p" != "/" && "$p" == */ ]]; do p="${p%/}"; done
  while [[ ! -d "$p" ]]; do
    tail="/$(basename "$p")$tail"
    p="$(dirname "$p")"
  done
  case "$tail" in */..|*/../*|*/.|*/./*) return 1 ;; esac
  d="$(cd -P "$p" && pwd -P)" || return 1
  d="${d%/}$tail"
  printf '%s' "${d:-/}"
}

count_components() {
  local IFS=/ part n=0
  for part in $1; do [[ -n "$part" ]] && n=$((n+1)); done
  echo "$n"
}

# Resolve env dir/path variable NAME (default DEF). Set-but-empty is an error.
env_path() {
  local name="$1" def="$2" val resolved
  if [[ -n "${!name+x}" ]]; then val="${!name}"; else val="$def"; fi
  [[ -n "$val" ]] || die "$name is set but empty"
  resolved="$(resolve_path "$val")" || die "$name is not a usable path: $val"
  printf -v "$name" '%s' "$resolved"
  export "$name"
}

config_dir_init() { env_path CONFIG_DIR "$DEFAULT_CONFIG_DIR"; }

validate_bundle_id() {
  BUNDLE_ID="${BUNDLE_ID-$DEFAULT_BUNDLE_ID}"
  [[ "$BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] \
    || die "BUNDLE_ID must match ^[A-Za-z0-9][A-Za-z0-9.-]*\$, got: '$BUNDLE_ID'"
  export BUNDLE_ID
}

# check_rm_target PATH KIND [EXPECT]: KIND app (must end .app), leaf (config dir: named
# wallpaper-overlay, or holding the install marker), log (must end .log), plist (must end .plist),
# glob (basename matches EXPECT). Never "/" or $HOME; needs >= 3 components.
check_rm_target() {
  local target="$1" kind="$2" expect="${3:-}" real home_real base
  [[ -n "$target" ]] || { echo "error: refusing to delete: empty path" >&2; return 1; }
  real="$(resolve_path "$target")" || { echo "error: refusing to delete: cannot resolve '$target'" >&2; return 1; }
  home_real="$(resolve_path "$HOME")" || home_real="$HOME"
  if [[ "$real" == "/" || "$real" == "$home_real" ]]; then
    echo "error: refusing to delete '$real' (root or home)" >&2; return 1
  fi
  if (( $(count_components "$real") < MIN_RM_COMPONENTS )); then
    echo "error: refusing to delete '$real' (fewer than $MIN_RM_COMPONENTS path components)" >&2; return 1
  fi
  base="${real##*/}"
  case "$kind" in
    app)  [[ "$base" == *.app ]] || { echo "error: refusing to delete '$real' (not a .app bundle)" >&2; return 1; } ;;
    leaf) [[ "$base" == "$EXPECTED_CONFIG_LEAF" || -f "$real/$CONFIG_MARKER" ]] \
            || { echo "error: refusing to delete '$real' (not named '$EXPECTED_CONFIG_LEAF' and no $CONFIG_MARKER marker inside)" >&2; return 1; } ;;
    log)   [[ "$base" == *.log ]] || { echo "error: refusing to delete '$real' (not a .log file)" >&2; return 1; } ;;
    plist) [[ "$base" == *.plist ]] || { echo "error: refusing to delete '$real' (not a .plist file)" >&2; return 1; } ;;
    glob) [[ "$base" == $expect ]] || { echo "error: refusing to delete '$real' (leaf does not match '$expect')" >&2; return 1; } ;;
    *) echo "error: bad rm kind '$kind'" >&2; return 1 ;;
  esac
  return 0
}

safe_rm_rf() {
  local target="$1"; shift
  check_rm_target "$target" "$@" || return 1
  [[ -e "$(resolve_path "$target")" ]] || return 0
  run rm -rf "$(resolve_path "$target")"
}

# safe_rm_file PATH KIND: guarded single-file delete (KIND log or plist). A directory is refused.
safe_rm_file() {
  local target="$1" kind="$2" real
  check_rm_target "$target" "$kind" || return 1
  real="$(resolve_path "$target")"
  [[ ! -d "$real" ]] || { echo "error: refusing to delete '$real' (is a directory)" >&2; return 1; }
  [[ -e "$real" || -L "$real" ]] || return 0
  run rm -f "$real"
}

# Pass the path as an argument, never interpolated into the script.
set_desktop_picture() {
  run osascript - "$1" <<'APPLESCRIPT'
on run argv
  set p to item 1 of argv
  tell application "System Events" to tell every desktop to set picture to POSIX file p
end run
APPLESCRIPT
}

# Read-only: prints the current desktop picture path(s). Fails if System Events cannot be queried.
get_desktop_pictures() {
  osascript -e 'tell application "System Events" to get picture of every desktop' 2>/dev/null
}

# install_marker_has KEY=VAL: does the config dir's install marker contain that line?
install_marker_has() {
  [[ -f "$CONFIG_DIR/$CONFIG_MARKER" ]] && grep -qx -- "$1" "$CONFIG_DIR/$CONFIG_MARKER"
}
