#!/usr/bin/env bash
# Build MacBox from this checkout and start the guided first run.
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
cd "$root"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'MacBox потребує macOS на Apple Silicon.' >&2
  exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
  echo 'Потрібен Swift і Xcode або Command Line Tools. Встановіть їх, а потім повторіть запуск.' >&2
  exit 1
fi
bash "$root/scripts/build-and-sign.sh" release
binary="$(swift build -c release --show-bin-path)/macbox"
exec "$binary" up "$@"
