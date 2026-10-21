#!/bin/bash
# Packages build/Ebb.app into dist/Ebb.dmg (drag-to-Applications) and dist/Ebb-<version>.zip.
#   scripts/package.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/package.sh <version>}"
mkdir -p dist
rm -f "dist/Ebb-$VERSION.zip" dist/Ebb.dmg

ditto -c -k --sequesterRsrc --keepParent build/Ebb.app "dist/Ebb-$VERSION.zip"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Ebb.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Ebb" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov dist/Ebb.dmg 2> >(grep -v deprecated >&2) >/dev/null

ls -lh dist
