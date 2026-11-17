#!/usr/bin/env bash
# Pack the `flutter build linux --release` bundle into an AppImage (release.yml runs this on
# Ubuntu 22.04, so it runs on that glibc and newer).
#   app/linux/packaging/build-appimage.sh <version> <out-dir>
# GTK 3 comes from the system, as on any Flutter Linux install. libmpv (voice and video) is bundled
# with its dependencies from the build machine (libmpv-dev must be installed there); AppRun puts
# the bundled libraries the system lacks on the library path when it has no libmpv.so.1.
set -euo pipefail
version="${1:?version}"
out="${2:?out dir}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="$(cd "$here/../.." && pwd)"
bundle="$app/build/linux/x64/release/bundle"
[ -x "$bundle/famchat" ] || { echo "no Linux bundle at $bundle; run flutter build linux --release" >&2; exit 1; }
libmpv="$(ls /usr/lib/x86_64-linux-gnu/libmpv.so.[0-9] 2>/dev/null | head -1)"
[ -n "$libmpv" ] || { echo "no libmpv on the build machine; install libmpv-dev" >&2; exit 1; }

work="$(mktemp -d)"
appdir="$work/FamChat.AppDir"
mkdir -p "$appdir/usr/share/applications" "$appdir/usr/share/icons/hicolor/512x512/apps" "$appdir/usr/lib"
cp -R "$bundle/." "$appdir/"
cp "$here/dev.famchat.app.desktop" "$appdir/dev.famchat.app.desktop"
cp "$here/dev.famchat.app.desktop" "$appdir/usr/share/applications/"
cp "$app/web/icons/Icon-512.png" "$appdir/dev.famchat.app.png"
cp "$app/web/icons/Icon-512.png" "$appdir/usr/share/icons/hicolor/512x512/apps/dev.famchat.app.png"
cp "$here/AppRun" "$appdir/AppRun"
chmod +x "$appdir/AppRun"

curl -fsSL -o "$work/linuxdeploy" \
  https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
curl -fsSL -o "$work/appimagetool" \
  https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x "$work/linuxdeploy" "$work/appimagetool"
# Extract-and-run: CI runners have no FUSE.
export APPIMAGE_EXTRACT_AND_RUN=1
# libmpv and what it links to, minus the libraries every desktop has (glibc, X11, GL, ...): into
# usr/lib, each with an $ORIGIN rpath so they find each other there.
"$work/linuxdeploy" --appdir "$appdir" --library "$libmpv"
[ -e "$appdir/usr/lib/$(basename "$libmpv")" ] || { echo "linuxdeploy didn't bundle libmpv" >&2; exit 1; }
# AppRun reads this to find the bundled copy.
basename "$libmpv" > "$appdir/usr/lib/libmpv.name"

mkdir -p "$out"
ARCH=x86_64 "$work/appimagetool" --no-appstream "$appdir" "$out/FamChat-$version-linux-x86_64.AppImage"
rm -rf "$work"
