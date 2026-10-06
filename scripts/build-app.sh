#!/usr/bin/env bash
# Builds build/Moonlet.app: the menu bar app with the `moonlet` command inside.
#
#   scripts/build-app.sh                 # release build for this Mac
#   UNIVERSAL=1 scripts/build-app.sh     # arm64 + x86_64
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# Without SIGN_IDENTITY the app is signed ad hoc, which is enough to run it locally.
set -euo pipefail
cd "$(dirname "$0")/.."

version="$(cat VERSION)"
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
arch_flags=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then arch_flags=(--arch arm64 --arch x86_64); fi

swift build -c release ${arch_flags[@]+"${arch_flags[@]}"} --product MoonletApp
swift build -c release ${arch_flags[@]+"${arch_flags[@]}"} --product moonlet
bin="$(swift build -c release ${arch_flags[@]+"${arch_flags[@]}"} --show-bin-path)"

app="build/Moonlet.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin/MoonletApp" "$app/Contents/MacOS/Moonlet"
# APFS is usually case-insensitive, so the command can't sit next to `Moonlet`.
cp "$bin/moonlet" "$app/Contents/Helpers/moonlet"
sed -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build_number/" Packaging/Info.plist > "$app/Contents/Info.plist"
if [[ ! -f Packaging/AppIcon.icns ]]; then swift scripts/make-icon.swift Packaging/AppIcon.icns; fi
cp Packaging/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

codesign --force --options runtime --timestamp=none --sign "${SIGN_IDENTITY:--}" "$app/Contents/Helpers/moonlet"
codesign --force --options runtime --timestamp=none --entitlements Packaging/Moonlet.entitlements --sign "${SIGN_IDENTITY:--}" "$app"
echo "Built $app ($version)"
