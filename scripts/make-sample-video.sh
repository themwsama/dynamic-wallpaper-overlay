#!/usr/bin/env bash
# Generate an original 16 s seamless-looping abstract video (2560x1440, 30 fps)
# with ffmpeg only: drifting colour fields plus soft bokeh. No external media.
# Feed the result to make-wallpaper.sh.
set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/wallpaper-overlay}"
OUT="$CONFIG_DIR/sample-input.mp4"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--out PATH]

Creates a 16-second seamless-looping abstract video (2560x1440, 30fps, no audio).
  --out PATH   output file (default: $OUT)
  -h, --help   show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) [[ $# -ge 2 ]] || { echo "error: --out needs a path" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v ffmpeg >/dev/null 2>&1 || { echo "error: ffmpeg not found: brew install ffmpeg" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

# Every animated term is sin/cos of 2*PI*k*T/16 with integer k, so frame 480
# equals frame 0 and the loop is seamless.
LOOP='2*PI*T/16'

# Soft bokeh disc i: centre orbits on a circle, radius pulses. Returns glow 0..1.
bokeh() { # cx0 cy0 orbit phase size
  echo "exp(-pow((X/W-($1+$3*cos($LOOP+$4)))*W/H,2)/pow($5*(1+0.15*sin($LOOP+$4)),2)-pow(Y/H-($2+$3*sin($LOOP+$4)),2)/pow($5*(1+0.15*sin($LOOP+$4)),2))"
}
B="0.55*$(bokeh 0.25 0.35 0.10 0.0 0.09)+0.45*$(bokeh 0.70 0.60 0.12 2.1 0.12)+0.40*$(bokeh 0.50 0.25 0.08 4.2 0.07)+0.35*$(bokeh 0.85 0.30 0.06 1.0 0.06)+0.30*$(bokeh 0.15 0.75 0.09 3.3 0.10)"

# Low-res colour field (cheap), then upscale: smooth by construction.
FIELD="(0.5+0.5*sin(2*PI*(0.6*X/W+0.4*Y/H)+$LOOP))"
FIELD2="(0.5+0.5*sin(2*PI*(0.5*X/W-0.7*Y/H)-2*$LOOP+1.3))"
R="clip(30+70*$FIELD+40*$FIELD2+110*($B),0,255)"
G="clip(25+40*$FIELD2+25*$FIELD+80*($B),0,255)"
Bl="clip(60+110*$FIELD+50*(1-$FIELD2)+90*($B),0,255)"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=black:s=320x180:r=30:d=16,format=gbrp,geq=r='$R':g='$G':b='$Bl'" \
  -vf "scale=2560:1440:flags=bicubic,gblur=sigma=6,noise=alls=3:allf=t,format=yuv420p" \
  -r 30 -t 16 -an -c:v libx264 -crf 16 -preset medium -movflags +faststart "$OUT"

echo "wrote $OUT"
