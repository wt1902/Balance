#!/usr/bin/env bash
# Re-renders the app icon, avatar.png and banner.png from their SVG sources,
# then spreads the icon over the platform runners (tool/update_icons.py).
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
resvg -w 1024 -h 1024 icon.svg ../assets/app_icon.png
resvg -w 1024 -h 1024 icon_foreground.svg icon_foreground.png
python3 ../tool/update_icons.py
resvg "${fonts[@]}" -w 512 -h 512 avatar.svg avatar.png
resvg "${fonts[@]}" banner.svg banner.png
