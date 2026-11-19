#!/usr/bin/env bash
# Usage: shorebird-release-version.sh <ios|android> <latest|NAME+NUMBER>
# Prints version=, name=, number= and icons= lines (GitHub step outputs) for the Shorebird release to
# patch. "latest" is the platform's newest release that reached TestFlight or Play: release.yml
# tags those as shorebird/<platform>/<NAME+NUMBER>, so dry runs and failed uploads (releases no
# phone has) are skipped. Newest means the highest NUMBER: build numbers are minutes since the
# Unix epoch, so they only grow. An explicit NAME+NUMBER is used as given. Needs a git remote
# named origin (the checkout's).
#
# icons= is the icon-font flag the release was built with, which the patch must repeat: releases
# after 1.0.20 keep the whole Material icon font (--no-tree-shake-icons), so a patch can use any
# icon; 1.0.20 and earlier were built with the font trimmed to the icons they used, so patches to
# them stay trimmed (an icon those releases lack still needs a release tag).
set -euo pipefail

platform="$1" wanted="$2"
if [[ "$wanted" == latest ]]; then
  version="$(git ls-remote --tags origin "refs/tags/shorebird/$platform/*" \
    | sed -nE "s#^.*refs/tags/shorebird/$platform/([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)\$#\1#p" \
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
else
  echo "icons=--no-tree-shake-icons"
fi
