#!/bin/bash
# Builds LiveWall from source, packages it as a .dmg and (optionally) uploads
# it to the R2 bucket the website downloads from.
#
#   scripts/release.sh 2.7              build dist/LiveWall-2.7.dmg
#   scripts/release.sh 2.7 --install    …and install it into /Applications
#   scripts/release.sh 2.7 --publish    …and upload it as the website's download
#
# The app is ad-hoc signed (no Apple Developer ID), so people opening it for
# the first time see macOS's "Open Anyway" step — the website's setup guide
# walks through it.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version> [--install] [--publish]}"
shift
cd "$(dirname "$0")/.."

BUCKET="livewall-media"
PUBLIC_BASE="https://pub-a3e561f362c147a7845a8f32d2f71a91.r2.dev"
BUILD="$(git rev-list --count HEAD)"
APP="dist/LiveWall.app"
DMG="dist/LiveWall-$VERSION.dmg"

echo "▸ Building LiveWall $VERSION ($BUILD)"
swift build -c release

echo "▸ Assembling $APP"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/scripts"
cp .build/release/LiveWall "$APP/Contents/MacOS/LiveWall"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ship the activity helpers inside the app, so Claude Code hooks and other
# tools have a stable path: /Applications/LiveWall.app/Contents/Resources/scripts/
cp scripts/livewall-activity scripts/livewall-claude-hook "$APP/Contents/Resources/scripts/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Packaging/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --deep --sign - "$APP"
codesign --verify "$APP"

echo "▸ Packaging $DMG"
# A styled installer window like other Mac apps': app icon, arrow, Applications
# folder, and the install steps drawn into the background (including the
# one-time "Open Anyway"). Icon positions match Packaging/make_dmg_background.swift.
WORK="$(mktemp -d)"
mkdir "$WORK/source"
cp -R "$APP" "$WORK/source/"
swift Packaging/make_dmg_background.swift "$WORK/bg.png" "$WORK/bg@2x.png"
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/background.tiff" 2>/dev/null
# The window height includes Finder's title bar, so add it to the 440pt artwork.
create-dmg \
  --volname "LiveWall $VERSION" \
  --background "$WORK/background.tiff" \
  --window-pos 240 160 --window-size 660 468 \
  --icon-size 112 --text-size 13 \
  --icon "LiveWall.app" 170 175 --hide-extension "LiveWall.app" \
  --app-drop-link 490 175 \
  --no-internet-enable \
  "$DMG" "$WORK/source" >/dev/null
rm -rf "$WORK"
SIZE=$(stat -f%z "$DMG")
echo "  $(( SIZE / 1000000 )) MB"

for arg in "$@"; do
  case "$arg" in
    --install)
      echo "▸ Installing to /Applications"
      pkill -f /Applications/LiveWall.app/Contents/MacOS/LiveWall || true
      sleep 1
      rm -rf /Applications/LiveWall.app
      ditto "$APP" /Applications/LiveWall.app
      open /Applications/LiveWall.app
      ;;
    --publish)
      echo "▸ Uploading to R2"
      for key in "releases/LiveWall-$VERSION.dmg" "releases/LiveWall.dmg"; do
        npx --yes wrangler r2 object put "$BUCKET/$key" --file "$DMG" --remote \
          --content-type application/x-apple-diskimage \
          --content-disposition "attachment; filename=\"LiveWall-$VERSION.dmg\"" >/dev/null
      done
      cat > dist/latest.json <<JSON
{ "version": "$VERSION", "build": $BUILD, "bytes": $SIZE,
  "minimumSystem": "macOS 26", "published": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "url": "$PUBLIC_BASE/releases/LiveWall-$VERSION.dmg" }
JSON
      npx --yes wrangler r2 object put "$BUCKET/releases/latest.json" --file dist/latest.json --remote \
        --content-type application/json >/dev/null
      echo "  $PUBLIC_BASE/releases/LiveWall-$VERSION.dmg"
      ;;
  esac
done
echo "✓ Done"
