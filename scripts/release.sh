#!/bin/bash
# Publishes a release: builds the app, uploads Ebb.dmg (for people) and a zip (for the
# Homebrew cask) to GitHub Releases, then bumps the cask to point at it.
#   scripts/release.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
TAG="v$VERSION"
ZIP="dist/Ebb-$VERSION.zip"
# Unversioned so releases/latest/download/Ebb.dmg always points at the newest build.
DMG="dist/Ebb.dmg"

if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree is dirty; commit first." >&2
    exit 1
fi

VERSION="$VERSION" scripts/build-app.sh
scripts/package.sh "$VERSION"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)

sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/ebb.rb
git add Casks/ebb.rb
git commit -m "Release $TAG"
git tag "$TAG"
git push origin HEAD "$TAG"

NOTES=$(mktemp)
trap 'rm -f "$NOTES"' EXIT
cat > "$NOTES" <<EOF
**Download [Ebb.dmg](https://github.com/ZNLong2203/Ebb/releases/download/$TAG/Ebb.dmg)**, drag it to Applications, then on first launch use *System Settings → Privacy & Security → Open Anyway* (Ebb is open source but not notarized). Then allow Full Disk Access when Ebb asks, for a complete scan.

Or with Homebrew:
\`\`\`bash
brew tap znlong2203/ebb https://github.com/ZNLong2203/Ebb
brew install --cask znlong2203/ebb/ebb
\`\`\`
EOF
gh release create "$TAG" "$DMG" "$ZIP" --title "Ebb $VERSION" --notes-file "$NOTES" --generate-notes

echo "Released $TAG ($SHA)"
