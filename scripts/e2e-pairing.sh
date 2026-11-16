#!/usr/bin/env bash
# End-to-end test of device pairing and key rotation against a local Worker.
#
# Starts `wrangler dev` on a fresh, throwaway local D1 (migrations applied), then runs
# app/test_e2e/ with the Dart chat engine against it: two users chat, the first pairs a new
# device that reads the history, then revokes it and the chat moves to a new key.
#
# Usage: scripts/e2e-pairing.sh            (needs node/npm deps in server/ and flutter on PATH
#                                          or at ~/development/flutter/bin)
# Env:   PORT (default 8799)
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
port=${PORT:-8799}
state=$(mktemp -d)
secret="e2e-bootstrap-$(date +%s)-$RANDOM"
flutter_bin=$(command -v flutter || echo "$HOME/development/flutter/bin/flutter")

cd "$root/server"
mkdir -p public # the assets directory wrangler.jsonc names; empty is fine for the API
npx wrangler d1 migrations apply famchat --local --persist-to "$state" > "$state/migrate.log" 2>&1
npx wrangler dev --local --port "$port" --persist-to "$state" \
  --var TOKEN_SECRET:e2e-token-secret --var "BOOTSTRAP_SECRET:$secret" \
  > "$state/wrangler.log" 2>&1 &
pid=$!
cleanup() {
  kill "$pid" 2> /dev/null || true
  wait "$pid" 2> /dev/null || true
  rm -rf "$state"
}
trap cleanup EXIT

for _ in $(seq 1 60); do
  curl -sf "http://127.0.0.1:$port/api/health" > /dev/null && break
  sleep 1
done
curl -sf "http://127.0.0.1:$port/api/health" > /dev/null || { cat "$state/wrangler.log"; exit 1; }

cd "$root/app"
FAMCHAT_E2E_API="http://127.0.0.1:$port" FAMCHAT_E2E_BOOTSTRAP="$secret" \
  "$flutter_bin" test test_e2e/ || { echo "--- wrangler log ---"; tail -50 "$state/wrangler.log"; exit 1; }
