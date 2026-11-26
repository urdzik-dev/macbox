#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
configuration="${1:-debug}"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
sdk_major="${sdk_version%%.*}"
build_args=(-c "$configuration")
if [[ "$sdk_major" =~ ^[0-9]+$ ]] && (( sdk_major >= 27 )); then
  build_args+=(-Xswiftc -DMACBOX_HAS_MACOS27_SDK)
fi
swift build "${build_args[@]}"
products="$(swift build "${build_args[@]}" --show-bin-path)"
identity="${MACBOX_SIGN_IDENTITY:--}"
build_number="${MACBOX_BUILD_NUMBER:-$(date +%s)}"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || { echo 'MACBOX_BUILD_NUMBER має бути додатним числом.' >&2; exit 1; }
app="$products/MacBoxGuest.app"
mkdir -p "$app/Contents/MacOS"
cp "$products/macbox-guest" "$app/Contents/MacOS/macbox-guest"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ua.macbox.guest</string>
<key>CFBundleExecutable</key><string>macbox-guest</string>
<key>CFBundleName</key><string>MacBox Guest</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
codesign --force --sign "$identity" --timestamp=none "$app"
codesign --force --sign "$identity" --timestamp=none --entitlements "$root/config/MacBox.entitlements" "$products/macbox"
codesign --verify --strict "$app"
printf 'Built: %s\nGuest: %s\n' "$products/macbox" "$app"
