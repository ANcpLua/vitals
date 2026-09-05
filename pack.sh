#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

output="${1:?output directory required}"
scratch="$output/swift"
app="$output/Vitals.app"

swift build --scratch-path "$scratch" -c release
if [ -e "$app" ]; then
    find "$app" -depth -delete
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$scratch/release/vitals" "$app/Contents/MacOS/vitals"
cp "Info.plist" "$app/Contents/Info.plist"
cp "PrivacyInfo.xcprivacy" "$app/Contents/Resources/PrivacyInfo.xcprivacy"
codesign --force --sign - "$app"

echo "built $app"
