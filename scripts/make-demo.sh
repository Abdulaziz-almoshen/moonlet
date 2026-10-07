#!/usr/bin/env bash
# Renders Moonlet's demo film from the app's own interface code and encodes it:
#   docs/media/moonlet-companion-demo.mp4  (1920×1200, for sharing)
#   docs/media/moonlet-companion-demo.gif  (960 wide, for the README)
# Requires ffmpeg.
set -euo pipefail
cd "$(dirname "$0")/.."

frames="$(mktemp -d /tmp/moonlet-frames.XXXX)"
trap 'rm -rf "$frames"' EXIT

swift build --product MoonletApp
"$(swift build --show-bin-path)/MoonletApp" --render-film "$frames"

mkdir -p docs/media
ffmpeg -y -loglevel error -framerate 30 -i "$frames/frame%04d.png" \
  -c:v libx264 -pix_fmt yuv420p -crf 20 -preset slow -movflags +faststart docs/media/moonlet-companion-demo.mp4
ffmpeg -y -loglevel error -framerate 30 -i "$frames/frame%04d.png" \
  -vf "fps=15,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
  docs/media/moonlet-companion-demo.gif
ls -lh docs/media/moonlet-companion-demo.mp4 docs/media/moonlet-companion-demo.gif
