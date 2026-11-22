#!/usr/bin/env bash
# Usage: review-required.sh <NAME>   (an iOS version waiting for App Store review or in review)
# Exits 0 when that version has to be reviewed: its build changes native code, plugins, assets or
# the Flutter version compared with the version the App Store has live, so no Shorebird patch can
# bring live installs up to it and pulling it from review would hold those changes back. Exits 1
# when it doesn't (everything in it could reach live installs as a patch), so a newer build may take
# its place. Prints why either way.
#
# Unsure counts as required: a version without a shorebird/ios tag, or no live version, exits 0.
# Builds are the shorebird/ios/<NAME+NUMBER> tags release.yml pushes (newest NUMBER per name).
# LIVE_VERSION overrides the App Store lookup (for trying it out).
# Needs a git remote named origin and full history (actions/checkout fetch-depth: 0).
set -euo pipefail
name="${1:?NAME}"
bundle="${BUNDLE_ID:-dev.famchat.app}"

tag_for() {
  git ls-remote --tags origin "refs/tags/shorebird/ios/$1+*" \
    | sed -nE "s#^.*refs/tags/(shorebird/ios/${1//./\\.}\+[0-9]+)\$#\1#p" | sort -t+ -k2,2n | tail -1
}

live="${LIVE_VERSION:-}"
[ -n "$live" ] || live="$(curl -fsS "https://itunes.apple.com/lookup?bundleId=$bundle&country=us" \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["results"]; print(r[0]["version"] if r else "")' || true)"
[ -n "$live" ] || { echo "The App Store has no live version, so $name needs review."; exit 0; }
[ "$live" != "$name" ] || { echo "$name is already the App Store's live version."; exit 1; }
waiting="$(tag_for "$name")" store="$(tag_for "$live")"
[ -n "$waiting" ] || { echo "No shorebird/ios tag for $name; treating it as needing review."; exit 0; }
[ -n "$store" ] || { echo "No shorebird/ios tag for live $live; treating $name as needing review."; exit 0; }
git fetch -q origin "refs/tags/$waiting:refs/tags/$waiting" "refs/tags/$store:refs/tags/$store"

# What a Shorebird patch can't carry. pubspec.yaml's version line doesn't count.
paths=(app/ios app/packages app/third_party app/assets app/pubspec.yaml app/pubspec.lock app/shorebird.yaml)
changed="$(git diff --name-only -I'^version:' "$store" "$waiting" -- "${paths[@]}")"
flutter() { git show "$1:.github/workflows/release.yml" | sed -nE 's/^ *FLUTTER_VERSION: *"?([^"]*)"?.*/\1/p' | head -1; }
[ "$(flutter "$store")" = "$(flutter "$waiting")" ] || changed+=$'\n'"Flutter $(flutter "$store") -> $(flutter "$waiting")"
changed="$(sed '/^$/d' <<<"$changed")"
if [ -n "$changed" ]; then
  echo "$name needs review: against live $live it changes"
  sed 's/^/  /' <<<"$changed" | head -20
  exit 0
fi
echo "$name has nothing live $live can't get as a patch."
exit 1
