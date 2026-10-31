#!/bin/bash
# Builds the app and packs it into dist/Transcriber.dmg, ready to attach to a GitHub release.
# The file name never changes, so .../releases/latest/download/Transcriber.dmg always gives the newest version.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build_app.sh release

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto build/Transcriber.app "$STAGING/Transcriber.app"
# Shortcut to drag the app onto when the disk image opens.
ln -s /Applications "$STAGING/Applications"

mkdir -p dist
hdiutil create -volname Transcriber -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov dist/Transcriber.dmg >/dev/null
shasum -a 256 dist/Transcriber.dmg
echo "Ready: dist/Transcriber.dmg"
