#!/bin/bash
# Points everything at a new public address for the R2 bucket (videos,
# posters, releases), e.g. once a custom domain is connected in Cloudflare:
#
#   scripts/switch-media-domain.sh https://media.example.com
#
# Rewrites the website, the catalog, publish.mjs and release.sh. Then
# commit, run scripts/deploy-web.sh, and publish the next release so
# latest.json carries the new address too. The app reads URLs from
# catalog.json, so it follows without an update.
set -euo pipefail
NEW="${1:?usage: scripts/switch-media-domain.sh https://media.example.com}"
NEW="${NEW%/}"
cd "$(dirname "$0")/.."
OLD="$(sed -n 's/^PUBLIC_BASE="\(.*\)"$/\1/p' scripts/release.sh)"
[ -n "$OLD" ] || { echo "Couldn't read the current address from scripts/release.sh" >&2; exit 1; }
[ "$OLD" != "$NEW" ] || { echo "Already using $NEW"; exit 0; }
curl -fsI "$NEW/releases/latest.json" >/dev/null || { echo "$NEW/releases/latest.json isn't reachable yet" >&2; exit 1; }
FILES=$(grep -rlF "$OLD" web/public web/scripts web/catalog.source.json scripts/release.sh)
for f in $FILES; do sed -i '' "s|$OLD|$NEW|g" "$f"; echo "  $f"; done
echo "Switched $OLD → $NEW"
