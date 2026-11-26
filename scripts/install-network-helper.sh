#!/usr/bin/env bash
# Optional third-party userspace NAT; pinned to the upstream release digest.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/vendor/gvproxy"
file="$dir/gvproxy"
expected='e2a6825ba789fe588828b418c09aaf16525dec6d8cb2d16c94e72535dd4606be'
mkdir -p "$dir"
if [[ -e "$file" ]]; then
  if printf '%s  %s\n' "$expected" "$file" | shasum -a 256 -c >/dev/null 2>&1; then
    echo "gvproxy v0.9.0 вже встановлено: $file"
    exit 0
  fi
  echo "Наявний gvproxy не відповідає очікуваній контрольній сумі; файл не змінено." >&2
  exit 1
fi
tmp="$(mktemp "$dir/.download.XXXXXXXX")"
trap 'rm -f "$tmp"' EXIT
curl -fL --retry 2 -o "$tmp" 'https://github.com/containers/gvisor-tap-vsock/releases/download/v0.9.0/gvproxy-darwin'
printf '%s  %s\n' "$expected" "$tmp" | shasum -a 256 -c >/dev/null
chmod 755 "$tmp"
# Refuse to overwrite a helper installed concurrently.
if ! ln "$tmp" "$file"; then
  echo 'Не вдалося встановити gvproxy; наявний файл не змінено.' >&2
  exit 1
fi
echo "Встановлено gvproxy v0.9.0 (Apache-2.0): $file"
