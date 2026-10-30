#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
platform="${1:-web}"
if [[ $# -gt 0 ]]; then shift; fi
flutter_bin="${FLUTTER_BIN:-flutter}"
case "$platform" in
  web|android|ios|macos|windows|linux) ;;
  *) echo "Usage: $0 {web|android|ios|macos|windows|linux} [build options]" >&2; exit 2 ;;
esac
"$flutter_bin" pub get
case "$platform" in
  web) "$flutter_bin" build web --release --no-web-resources-cdn "$@" ;;
  android) "$flutter_bin" build apk --release "$@" ;;
  ios) "$flutter_bin" build ios --release --no-codesign "$@" ;;
  *) "$flutter_bin" build "$platform" --release "$@" ;;
esac
