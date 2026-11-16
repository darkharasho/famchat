#!/usr/bin/env bash
# Check a deployed FamChat site: the web app at / and on app routes, the API under /api.
#   scripts/smoke-web.sh https://famchat.dev
# Retries for up to a minute, since a fresh deploy can take a few seconds to reach every colo.
set -uo pipefail
base="${1:?usage: smoke-web.sh <base-url>}"
nav=(-H 'Sec-Fetch-Mode: navigate' -H 'Accept: text/html')

check() { # <name> <path> <want-status> <want-content-type-prefix> <want-body-substring> [curl args]
  local name=$1 path=$2 status=$3 ctype=$4 body=$5; shift 5
  local out code type
  out="$(curl -sS --max-time 15 "$@" -w '\n%{http_code} %{content_type}' "$base$path")" || return 1
  code="$(tail -n1 <<<"$out" | cut -d' ' -f1)"
  type="$(tail -n1 <<<"$out" | cut -d' ' -f2-)"
  if [ "$code" = "$status" ] && [[ "$type" == "$ctype"* ]] && grep -qF -- "$body" <<<"$out"; then
    echo "ok   $name ($path -> $code $type)"
  else
    echo "FAIL $name ($path -> $code $type)"
    return 1
  fi
}

run_all() {
  local failed=0
  check "web app"            /                 200 text/html        flutter_bootstrap.js "${nav[@]}" || failed=1
  check "SPA fallback"       /join?code=x      200 text/html        flutter_bootstrap.js "${nav[@]}" || failed=1
  # The push service worker must be the file, not the SPA fallback's index.html.
  check "push worker"        /firebase-messaging-sw.js 200 "" famchatFirebaseConfig                || failed=1
  check "API health"         /api/health       200 application/json '"ok":true'                      || failed=1
  check "API 404 stays JSON" /api/does-not-exist 404 application/json not_found  "${nav[@]}"         || failed=1
  return $failed
}

for attempt in 1 2 3 4 5 6; do
  run_all && exit 0
  [ "$attempt" = 6 ] && break
  echo "retrying in 10 s..."
  sleep 10
done
echo "smoke test failed for $base" >&2
exit 1
