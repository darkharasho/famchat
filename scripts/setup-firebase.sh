#!/usr/bin/env bash
# Turns on push notifications (plan 9). Run once, from a machine where `npx wrangler whoami` works:
#
#   scripts/setup-firebase.sh                       # everything below
#   scripts/setup-firebase.sh --key-file key.json   # use a key downloaded from the Firebase console
#   scripts/setup-firebase.sh --no-git              # only write the files; commit them yourself
#
# 1. Logs in to Firebase (browser) if needed.
# 2. Makes sure the Firebase project "famchat" has Android, iOS and web apps (bundle id
#    dev.famchat.app) and writes their public config to app/lib/push/firebase_options.dart and
#    app/web/firebase-config.js. Until those exist, push is off everywhere.
# 3. Creates a key for the project's firebase-adminsdk service account and stores it as the Worker
#    secret FCM_SERVICE_ACCOUNT. The key goes straight from Google into wrangler: never printed,
#    never written to disk. (With --key-file, that file is used instead; delete it afterwards.)
# 4. Commits the two config files on a branch "firebase-config", pushes it and opens a PR.
#
# Then: merge the PR, deploy (scripts/deploy.sh or the deploy workflow), cut a release for the apps,
# and check with "Send a test notification" on the Devices screen of a phone that allowed
# notifications. No GitHub secrets are needed: the config files are committed (they aren't secret).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
key_file=""
git=1
while [ $# -gt 0 ]; do
  case "$1" in
    --key-file) key_file="$2"; shift 2 ;;
    --no-git) git=0; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if command -v firebase >/dev/null 2>&1; then export FIREBASE=firebase; else export FIREBASE="npx -y firebase-tools"; fi

echo "==> Firebase login"
$FIREBASE login:list 2>/dev/null | grep -q "Logged in as" || $FIREBASE login

echo "==> Firebase apps and client config"
python3 "$root/scripts/firebase-setup.py" apps

echo "==> Worker secret FCM_SERVICE_ACCOUNT"
cd "$root/server"
[ -d node_modules ] || npm ci --no-audit --no-fund
if [ -n "$key_file" ]; then
  npx wrangler secret put FCM_SERVICE_ACCOUNT < "$key_file"
  echo "Stored. Delete $key_file now; the Worker has its own copy."
elif key="$(python3 "$root/scripts/firebase-setup.py" key)" && [ -n "$key" ]; then
  # Held in memory only, then piped (not an argument, so it never shows in a process list).
  printf '%s' "$key" | npx wrangler secret put FCM_SERVICE_ACCOUNT
  unset key
else
  cat >&2 <<EOF
Could not create the key automatically. Download one instead:
  https://console.firebase.google.com/project/famchat/settings/serviceaccounts/adminsdk
  -> "Generate new private key", then run:
  scripts/setup-firebase.sh --key-file <downloaded file>
EOF
  exit 1
fi
# The queue exists since plan 9 (wrangler queues create famchat-push); harmless if it does.
npx wrangler queues create famchat-push >/dev/null 2>&1 || true

cd "$root"
if [ "$git" = 1 ]; then
  echo "==> Commit the config on branch firebase-config"
  git fetch -q origin main
  git switch -c firebase-config origin/main 2>/dev/null || git switch firebase-config
  git add app/lib/push/firebase_options.dart app/web/firebase-config.js
  git commit -m "chore: Firebase config for push notifications" || echo "(nothing new to commit)"
  git push -u origin firebase-config
  if command -v gh >/dev/null 2>&1; then
    gh pr create --base main --head firebase-config --title "Firebase config for push notifications" \
      --body "Written by scripts/setup-firebase.sh. Public Firebase app config only; the service-account key is a Worker secret." || true
  fi
fi

cat <<EOF

Done. Next:
  1. Merge the firebase-config PR (CI builds every platform with Firebase on).
  2. Deploy: scripts/deploy.sh (web app + Worker with the push queue consumer).
  3. Release the apps (release workflow) so phones get the Firebase config.
  4. On a phone: open FamChat, allow notifications, then Devices -> "Send a test notification".
     Or lock the phone and have someone send you a message.
EOF
