#!/bin/bash
# Builds Transcriber and creates build/Transcriber.app, without Xcode (the Command Line Tools are enough).
# Usage: ./scripts/build_app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product Transcriber
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Transcriber.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses"
cp "$BIN/Transcriber" "$APP/Contents/MacOS/Transcriber"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Credits.rtf shows up by itself in the standard "About Transcriber" window.
cp Resources/AppIcon.icns Resources/Credits.rtf "$APP/Contents/Resources/"
# Resources of the Swift dependencies (if any).
for bundle in "$BIN"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# License texts that travel with the app: ours, and FluidAudio's (Apache 2.0) with the ones it includes.
FLUIDAUDIO=".build/checkouts/FluidAudio"
cp LICENSE "$APP/Contents/Resources/Licenses/Transcriber-LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Licenses/"
cp "$FLUIDAUDIO/LICENSE" "$APP/Contents/Resources/Licenses/FluidAudio-LICENSE.txt"
cp -R "$FLUIDAUDIO/ThirdPartyLicenses" "$APP/Contents/Resources/Licenses/FluidAudio-ThirdPartyLicenses"

# Local ("ad-hoc") signature: no Apple account needed. Downloaded copies open after "Open Anyway".
codesign --force --sign - --entitlements Resources/Transcriber.entitlements "$APP"
echo "Ready: $APP"
