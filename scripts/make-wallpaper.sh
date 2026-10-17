#!/usr/bin/env bash
# Turn any video into the stacked wallpaper format the overlay expects:
# 2560x2880 H.264, original on the top half, blurred/tinted "glass" copy on the bottom.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
config_dir_init
OUT="$CONFIG_DIR/wallpaper-stacked.mp4"
STILL="$CONFIG_DIR/wallpaper-still.png"
CURVE=0.2
BLUR=14
TINT=1
SET_DESKTOP=0
VERBOSE=0
INPUT=""
W=2560; H=1440; FPS=30
MIN_SECONDS=5

usage() {
  cat <<USAGE
Usage: $(basename "$0") <input-video> [options]

Options:
  --out PATH         stacked video (default: $OUT)
  --still PATH       still PNG from the glass half (default: $STILL)
  --set-desktop      set the still as the desktop picture on every display
  --curve C          colour curve strength, 0 disables (default: $CURVE)
  --blur SIGMA       glass blur sigma (default: $BLUR)
  --verbose          show full ffmpeg output
  --no-glass-tint    skip the gradient tint/sheen on the glass half
  -h, --help         show this help

Notes:
  Encoding takes a few minutes at high CPU. DRY_RUN=1 prints the plan only.
  The video should loop seamlessly by itself (last frame flows into the first).
  --set-desktop uses System Events; macOS asks for Automation permission once.
  The still shows at login, in Mission Control and before the video starts,
  so no third-party wallpaper app is needed.
USAGE
}

need_arg() { [[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) need_arg "$@"; OUT="$2"; shift 2 ;;
    --still) need_arg "$@"; STILL="$2"; shift 2 ;;
    --curve) need_arg "$@"; CURVE="$2"; shift 2 ;;
    --blur) need_arg "$@"; BLUR="$2"; shift 2 ;;
    --set-desktop) SET_DESKTOP=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --no-glass-tint) TINT=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) [[ -z "$INPUT" ]] || { echo "error: only one input video allowed" >&2; exit 2; }; INPUT="$1"; shift ;;
  esac
done

[[ -n "$INPUT" ]] || { usage >&2; exit 2; }
[[ -f "$INPUT" ]] || { echo "error: input not found: $INPUT" >&2; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "error: ffmpeg not found: brew install ffmpeg" >&2; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { echo "error: ffprobe not found: brew install ffmpeg" >&2; exit 1; }
MAX_CURVE=0.5
if ! [[ "$CURVE" =~ ^([0-9]+(\.[0-9]*)?|\.[0-9]+)$ ]] || ! awk -v c="$CURVE" -v m="$MAX_CURVE" 'BEGIN{exit !(c>=0 && c<=m)}'; then
  echo "error: --curve must be a number in 0..$MAX_CURVE, got: $CURVE" >&2; exit 2
fi
CURVE_ON=0; awk -v c="$CURVE" 'BEGIN{exit !(c>0)}' && CURVE_ON=1
[[ "$BLUR" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "error: --blur must be a positive number, got: $BLUR" >&2; exit 2; }

DUR="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$INPUT" 2>/dev/null || true)"
[[ -n "$DUR" && "$DUR" != "N/A" ]] || { echo "error: ffprobe cannot read a duration from: $INPUT" >&2; exit 1; }
if awk -v d="$DUR" -v m="$MIN_SECONDS" 'BEGIN{exit !(d<m)}'; then
  echo "warning: input is only ${DUR}s (< ${MIN_SECONDS}s); a short loop may look repetitive." >&2
fi

if is_dry_run; then
  echo "[dry-run] would encode $INPUT -> $OUT (via temp file + mv) and extract $STILL"
  (( SET_DESKTOP == 0 )) || echo "[dry-run] would set the desktop picture to $STILL"
  exit 0
fi

echo "note: encoding takes a few minutes at high CPU (fans may spin up)."
mkdir -p "$(dirname "$OUT")" "$(dirname "$STILL")"
WORK="$(mktemp -d)"
TMP_OUT="$(dirname "$OUT")/.$(basename "$OUT").tmp.$$"
TMP_STILL="$(dirname "$STILL")/.$(basename "$STILL").tmp.$$"
trap 'rm -rf "$WORK"; rm -f "$TMP_OUT" "$TMP_STILL"' EXIT
if [[ $VERBOSE -eq 1 ]]; then FF_LOG=(-loglevel info -stats); else FF_LOG=(-loglevel error -nostats); fi

# Base look shared by both halves: fill 16:9, 30 fps, optional colour curve.
BASE="scale=$W:$H:force_original_aspect_ratio=increase,crop=$W:$H,setsar=1,fps=$FPS"
if [[ $CURVE_ON -eq 1 ]]; then
  BASE="$BASE,curves=all='0/$CURVE 1/$(awk -v c="$CURVE" 'BEGIN{printf "%g", 1-c}')'"
fi

# Glass tint overlay: diagonal gradient #1c2340 -> #2a1f3d -> #1a2a3a at ~42% alpha
# plus a soft white sheen from the top-left, built with ffmpeg only.
GLASS="gblur=sigma=$BLUR,eq=saturation=1.2:brightness=-0.02"
INPUTS=(-i "$INPUT")
if [[ $TINT -eq 1 ]]; then
  TINT_PNG="$WORK/tint.png"
  SHEEN='0.5*exp(-5*(pow(X/W,2)+pow(Y/H,2))/2)'
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "gradients=s=${W}x${H}:c0=1c2340:c1=2a1f3d:c2=1a2a3a:nb_colors=3:x0=0:y0=0:x1=$W:y1=$H:type=linear:d=1" \
    -vf "format=gbrap,geq=r='r(X,Y)*(1-$SHEEN)+255*$SHEEN':g='g(X,Y)*(1-$SHEEN)+255*$SHEEN':b='b(X,Y)*(1-$SHEEN)+255*$SHEEN':a='255*(0.42+0.3*$SHEEN)'" \
    -frames:v 1 "$TINT_PNG" || { echo "error: failed to build tint overlay" >&2; exit 1; }
  INPUTS+=(-loop 1 -i "$TINT_PNG")
  FILTER="[0:v]$BASE,split[top][b0];[b0]$GLASS[bg];[1:v]format=rgba[tint];[bg][tint]overlay=shortest=1:format=auto[bot];[top][bot]vstack=inputs=2,scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv[v]"
else
  FILTER="[0:v]$BASE,split[top][b0];[b0]$GLASS[bot];[top][bot]vstack=inputs=2,scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv[v]"
fi

echo "encoding... (2-3 min)"
ffmpeg -hide_banner "${FF_LOG[@]}" -y "${INPUTS[@]}" \
  -filter_complex "$FILTER" -map "[v]" -an \
  -c:v libx264 -crf 18 -preset slow -pix_fmt yuv420p \
  -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv \
  -f mp4 -movflags +faststart "$TMP_OUT" \
  || { echo "error: ffmpeg encode failed" >&2; exit 1; }
mv "$TMP_OUT" "$OUT"

# Still from the glass (bottom) half, ~1 s in or mid-clip for short inputs.
SEEK="$(awk -v d="$DUR" 'BEGIN{s=1; if (d<2) s=d/2; printf "%.2f", s}')"
ffmpeg -hide_banner -loglevel error -y -ss "$SEEK" -i "$OUT" \
  -vf "crop=$W:$H:0:$H" -frames:v 1 -update 1 -f image2 "$TMP_STILL" \
  || { echo "error: failed to extract still" >&2; exit 1; }
mv "$TMP_STILL" "$STILL"

echo "wrote $OUT"
echo "wrote $STILL"

if [[ $SET_DESKTOP -eq 1 ]]; then
  echo "setting desktop picture (macOS may ask to let this app control System Events; allow it once)..."
  ABS="$(resolve_path "$STILL")"
  set_desktop_picture "$ABS" \
    || { echo "error: could not set desktop picture. Grant Automation > System Events in System Settings > Privacy & Security." >&2; exit 1; }
  echo "desktop picture set on every display"
fi
