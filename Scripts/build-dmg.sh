#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${EVANTO_SIGN_IDENTITY:?Set EVANTO_SIGN_IDENTITY to the full signing identity name.}"
case "$EVANTO_SIGN_IDENTITY" in
    "Developer ID Application:"*) timestamp=(--timestamp) ;;
    "Apple Development:"*) timestamp=(--timestamp=none) ;;
    *) echo "Use a Developer ID Application or Apple Development certificate." >&2; exit 1 ;;
esac
mkdir -p .build dist
stage=$(mktemp -d "$PWD/.build/dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/payload"
EVANTO_OUTPUT_DIR="$stage/payload" ./Scripts/build-app.sh
app="$stage/payload/Evanto.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
arch=$(lipo -archs "$app/Contents/MacOS/Evanto" | tr ' ' '-')
name="Evanto-$version-$arch.dmg"
ln -s /Applications "$stage/payload/Applications"
hdiutil create -quiet -volname "Evanto $version" -fs HFS+ -format UDZO -srcfolder "$stage/payload" "$stage/$name"
codesign --force --sign "$EVANTO_SIGN_IDENTITY" "${timestamp[@]}" "$stage/$name"
if [[ -n "${EVANTO_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$stage/$name" --keychain-profile "$EVANTO_NOTARY_PROFILE" --wait
    xcrun stapler staple "$stage/$name"
    xcrun stapler validate "$stage/$name"
fi
codesign --verify --strict "$stage/$name"
hdiutil verify -quiet "$stage/$name"
(cd "$stage" && shasum -a 256 "$name" > "$name.sha256")
mv -f "$stage/$name" "$stage/$name.sha256" dist/
echo "Built dist/$name"
