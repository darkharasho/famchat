#!/usr/bin/env bash
# Pack the `flutter build linux --release` bundle into an AppImage (release.yml runs this).
#   app/linux/packaging/build-appimage.sh <version> <out-dir>
# GTK 3 and libmpv (voice playback) come from the system, as on any Flutter Linux install;
# without libmpv the app runs but can't play audio.
set -euo pipefail
version="${1:?version}"
out="${2:?out dir}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="$(cd "$here/../.." && pwd)"
bundle="$app/build/linux/x64/release/bundle"
[ -x "$bundle/famchat" ] || { echo "no Linux bundle at $bundle; run flutter build linux --release" >&2; exit 1; }

work="$(mktemp -d)"
appdir="$work/FamChat.AppDir"
mkdir -p "$appdir/usr/share/applications" "$appdir/usr/share/icons/hicolor/512x512/apps"
cp -R "$bundle/." "$appdir/"
cp "$here/dev.famchat.app.desktop" "$appdir/dev.famchat.app.desktop"
cp "$here/dev.famchat.app.desktop" "$appdir/usr/share/applications/"
cp "$app/web/icons/Icon-512.png" "$appdir/dev.famchat.app.png"
cp "$app/web/icons/Icon-512.png" "$appdir/usr/share/icons/hicolor/512x512/apps/dev.famchat.app.png"
cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/famchat" "$@"
EOF
chmod +x "$appdir/AppRun"

tool="$work/appimagetool"
curl -fsSL -o "$tool" https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x "$tool"
mkdir -p "$out"
# Extract-and-run: CI runners have no FUSE.
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$tool" --no-appstream "$appdir" "$out/FamChat-$version-linux-x86_64.AppImage"
rm -rf "$work"
