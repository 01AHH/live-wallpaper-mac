#!/bin/bash
# Deploys the website (web/public) to Vercel production.
#
# The Vercel project's root directory is `web`, so the CLI wants to run from
# the repo root, which would upload the multi-GB Media/ library. Instead,
# deploy a clean copy holding only what the site needs.
set -euo pipefail
cd "$(dirname "$0")/.."
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/web"
cp -R web/.vercel "$STAGE/.vercel"
cp -R web/public web/vercel.json web/.vercelignore "$STAGE/web/"
cd "$STAGE"
npx --yes vercel --prod --yes 2>&1 | grep -E "Aliased|Production|Error" || true
