#!/usr/bin/env bash
# Usage: shorebird-release-version.sh <ios|android> <latest|store|NAME+NUMBER>
# Prints version=, name=, number= and icons= lines (GitHub step outputs) for the Shorebird release to
# patch. "latest" is the platform's newest release that reached TestFlight or Play: release.yml
# tags those as shorebird/<platform>/<NAME+NUMBER>, so dry runs and failed uploads (releases no
# phone has) are skipped. "store" (iOS) is the newest shipped release of the version the App Store
# has live (iTunes lookup), which can trail "latest" while a newer version waits for review. Newest means the highest NUMBER: build numbers are minutes since the
# Unix epoch, so they only grow. An explicit NAME+NUMBER is used as given. Needs a git remote
# named origin (the checkout's).
#
# icons= is the icon-font flag the release was built with, which the patch must repeat: releases
# after 1.0.20 keep the whole Material icon font (--no-tree-shake-icons), so a patch can use any
# icon; 1.0.20 and earlier were built with the font trimmed to the icons they used, so patches to
# them stay trimmed (an icon those releases lack still needs a release tag).
#
# patch_flags= are extra `shorebird patch` flags: for those trimmed releases, --allow-asset-diffs,
# since the trimmed font differs once the app uses an icon they lack; the patch keeps the release's
# font, so such an icon shows blank there, and everything else is patched.
set -euo pipefail

platform="$1" wanted="$2"
if [[ "$wanted" == latest || "$wanted" == store ]]; then
  prefix='[0-9]+\.[0-9]+\.[0-9]+'
  if [[ "$wanted" == store ]]; then
    live="$(curl -fsS "https://itunes.apple.com/lookup?bundleId=${BUNDLE_ID:-dev.famchat.app}&country=us" \
      | python3 -c 'import json,sys; r=json.load(sys.stdin)["results"]; print(r[0]["version"] if r else "")')"
    [[ "$live" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::The App Store has no live version." >&2; exit 1; }
    prefix="${live//./\\.}"
  fi
  version="$(git ls-remote --tags origin "refs/tags/shorebird/$platform/*" \
    | sed -nE "s#^.*refs/tags/shorebird/$platform/($prefix\+[0-9]+)\$#\1#p" \
    | sort -t+ -k2,2n | tail -1 || true)"
  [[ -n "$version" ]] || {
    echo "::error::No $platform release has reached the store through Shorebird yet (no shorebird/$platform/* tag)." >&2
    exit 1
  }
else
  version="$wanted"
fi
[[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$ ]] \
  || { echo "::error::Release version '$version' isn't NAME+NUMBER." >&2; exit 1; }
echo "version=$version"
echo "name=${BASH_REMATCH[1]}"
echo "number=${BASH_REMATCH[2]}"
if [[ "$(printf '%s\n' 1.0.20 "${BASH_REMATCH[1]}" | sort -V | tail -1)" == 1.0.20 ]]; then
  echo "icons="
  echo "patch_flags=--allow-asset-diffs"
else
  echo "icons=--no-tree-shake-icons"
  echo "patch_flags="
fi
