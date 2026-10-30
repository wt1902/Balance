#!/usr/bin/env bash
# Re-renders avatar.png and banner.png from their SVG sources.
# Requires resvg (https://github.com/linebender/resvg). Uses the app's own Roboto
# fonts so the result does not depend on system fonts.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
fonts=(
  --skip-system-fonts
  --use-font-file ../assets/fonts/Roboto-Regular.ttf
  --use-font-file ../assets/fonts/Roboto-Medium.ttf
  --use-font-file ../assets/fonts/Roboto-Bold.ttf
)
resvg "${fonts[@]}" -w 512 -h 512 avatar.svg avatar.png
resvg "${fonts[@]}" banner.svg banner.png
