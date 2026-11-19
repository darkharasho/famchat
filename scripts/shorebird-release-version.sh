#!/usr/bin/env bash
# Usage: shorebird-release-version.sh <ios|android> <latest|NAME+NUMBER>
# Prints version=, name= and number= lines (GitHub step outputs) for the Shorebird release to
# patch. "latest" is the platform's newest release that reached TestFlight or Play: release.yml
# tags those as shorebird/<platform>/<NAME+NUMBER>, so dry runs and failed uploads (releases no
# phone has) are skipped. Newest means the highest NUMBER: build numbers are minutes since the
# Unix epoch, so they only grow. An explicit NAME+NUMBER is used as given. Needs a git remote
# named origin (the checkout's).
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
