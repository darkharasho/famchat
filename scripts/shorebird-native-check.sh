#!/usr/bin/env bash
# Checks that nothing a Shorebird patch can't carry changed since a native release, so a patch built
# from HEAD can reach it: the iOS/Android projects, local and vendored packages, plugins and other
# dependencies (pubspec.yaml apart from its version line, pubspec.lock), assets, shorebird.yaml and
# the Flutter version release.yml builds with. Exits 0 when nothing did, 1 (listing what) otherwise.
# Shorebird itself refuses a native diff when patching; this answers the question without a build
# (scripts/review-required.sh uses it to tell whether a version has to be App Store reviewed).
#
# Usage: shorebird-native-check.sh <ios|android> <NAME+NUMBER>
# Compares HEAD with the tag shorebird/<platform>/<NAME+NUMBER>; needs it locally or on origin.
set -euo pipefail
platform="${1:?ios|android}" release="${2:?NAME+NUMBER}"
cd "$(git rev-parse --show-toplevel)"
tag="shorebird/$platform/$release"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null \
  || git fetch -q origin "refs/tags/$tag:refs/tags/$tag" 2>/dev/null \
  || { echo "::error::No tag $tag: $release isn't a shipped native release." >&2; exit 2; }

paths=("app/$platform" app/packages app/third_party app/assets app/pubspec.yaml app/pubspec.lock app/shorebird.yaml)
changed="$(git diff --name-only -I'^version:' "$tag" HEAD -- "${paths[@]}")"
flutter() { git show "$1:.github/workflows/release.yml" | sed -nE 's/^ *FLUTTER_VERSION: *"?([^"]*)"?.*/\1/p' | head -1; }
[ "$(flutter "$tag")" = "$(flutter HEAD)" ] || changed+=$'\n'"Flutter $(flutter "$tag") -> $(flutter HEAD)"
changed="$(sed '/^$/d' <<<"$changed")"
if [ -n "$changed" ]; then
  echo "Changed since $tag, which a patch can't carry:"
  sed 's/^/  /' <<<"$changed" | head -20
  exit 1
fi
echo "Nothing native changed since $tag."
