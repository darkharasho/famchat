#!/usr/bin/env bash
# Deploy FamChat to famchat.dev: build the Flutter web app, apply D1 migrations, deploy the Worker
# (API + web app in one Worker), then smoke-test the live site.
#
#   scripts/deploy.sh                 # from a machine where `npx wrangler whoami` is logged in
#   CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ACCOUNT_ID=... scripts/deploy.sh   # CI (deploy.yml)
#
# Options (env): SKIP_WEB_BUILD=1 reuses an existing app/build/web; SKIP_SMOKE=1 skips the check.
# Needs flutter on PATH and Node 22+. Worker secrets (TOKEN_SECRET, BOOTSTRAP_SECRET) are set once
# with `wrangler secret put` and survive deploys.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
site="${SITE_URL:-https://famchat.dev}"

if [ "${SKIP_WEB_BUILD:-}" != 1 ]; then
  echo "==> flutter build web"
  # Self-host CanvasKit instead of loading it from Google's CDN: fewer third parties for a
  # private app, and the site works without gstatic.com.
  (cd "$root/app" && flutter build web --release --no-web-resources-cdn)
fi
[ -f "$root/app/build/web/index.html" ] || { echo "app/build/web has no index.html" >&2; exit 1; }

echo "==> copy the web build into server/public"
rm -rf "$root/server/public"
cp -R "$root/app/build/web" "$root/server/public"

cd "$root/server"
[ -d node_modules ] || npm ci --no-audit --no-fund

echo "==> D1 migrations (remote)"
npx wrangler d1 migrations apply famchat --remote

echo "==> wrangler deploy"
npx wrangler deploy

if [ "${SKIP_SMOKE:-}" != 1 ]; then
  echo "==> smoke test $site"
  "$root/scripts/smoke-web.sh" "$site"
fi
