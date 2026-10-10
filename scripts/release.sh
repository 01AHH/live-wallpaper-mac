#!/bin/bash
# Builds LiveWall from source, packages it as a .dmg and (optionally) uploads
# it to the R2 bucket the website downloads from.
#
#   scripts/release.sh 2.7              build dist/LiveWall-2.7.dmg
#   scripts/release.sh 2.7 --install    …and install it into /Applications
#   scripts/release.sh 2.7 --publish    …and upload it as the website's download
#
# The app is a universal binary (Apple silicon and Intel) with Sparkle for
# automatic updates; --publish also signs the .dmg for Sparkle and writes
# releases/appcast.xml (the EdDSA key lives in your login keychain, made once
# with .build/artifacts/sparkle/Sparkle/bin/generate_keys --account LiveWall).
#
# Signing: without a Developer ID the app is ad-hoc signed, so people opening
# a fresh download see macOS's "Open Anyway" step (the website walks through
# it; Sparkle updates skip it). With an Apple Developer account, set
#   LIVEWALL_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   LIVEWALL_NOTARY_PROFILE=<profile from `xcrun notarytool store-credentials`>
# and the app and .dmg are signed with the hardened runtime, notarized and
# stapled, which removes "Open Anyway" entirely.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version> [--install] [--publish]}"
shift
cd "$(dirname "$0")/.."

BUCKET="livewall-media"
PUBLIC_BASE="https://pub-a3e561f362c147a7845a8f32d2f71a91.r2.dev"
BUILD="$(git rev-list --count HEAD)"   # CFBundleVersion: Sparkle compares this
IDENTITY="${LIVEWALL_SIGN_IDENTITY:--}"
SPARKLE=".build/artifacts/sparkle/Sparkle"
APP="dist/LiveWall.app"
DMG="dist/LiveWall-$VERSION.dmg"

echo "▸ Building LiveWall $VERSION ($BUILD), universal"
swift build -c release --triple arm64-apple-macosx26.0
swift build -c release --triple x86_64-apple-macosx26.0

echo "▸ Assembling $APP"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/scripts" "$APP/Contents/Frameworks"
lipo -create .build/arm64-apple-macosx/release/LiveWall .build/x86_64-apple-macosx/release/LiveWall \
  -output "$APP/Contents/MacOS/LiveWall"
ditto "$SPARKLE/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ship the activity helpers inside the app, so Claude Code hooks and other
# tools have a stable path: /Applications/LiveWall.app/Contents/Resources/scripts/
cp scripts/livewall-activity scripts/livewall-claude-hook "$APP/Contents/Resources/scripts/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s|__MEDIA__|$PUBLIC_BASE|" \
  Packaging/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
if [ "$IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  # Inside out, as Sparkle's docs describe: its helpers, the framework, the app.
  sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
  FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  sign "$FW/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
  sign "$FW/Autoupdate" "$FW/Updater.app"
  sign "$APP/Contents/Frameworks/Sparkle.framework"
  sign "$APP/Contents/Resources/scripts/"*
  sign "$APP"
fi
codesign --verify --deep --strict "$APP"

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
if [ "$IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  if [ -n "${LIVEWALL_NOTARY_PROFILE:-}" ]; then
    echo "▸ Notarizing (a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$LIVEWALL_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi
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
      # Sparkle's feed: the newest release, signed with the keychain's EdDSA key.
      SIGNATURE="$("$SPARKLE/bin/sign_update" --account LiveWall "$DMG")"
      cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>LiveWall</title>
    <item>
      <title>LiveWall $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure url="$PUBLIC_BASE/releases/LiveWall-$VERSION.dmg" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML
      npx --yes wrangler r2 object put "$BUCKET/releases/appcast.xml" --file dist/appcast.xml --remote \
        --content-type application/xml --cache-control "no-cache" >/dev/null
      echo "  $PUBLIC_BASE/releases/LiveWall-$VERSION.dmg"
      ;;
  esac
done
echo "✓ Done"
