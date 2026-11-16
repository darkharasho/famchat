# Vendored firebase_core

An unmodified copy of `firebase_core` 5.2.0 from pub.dev (BSD-3, see LICENSE), used through
`dependency_overrides` in `app/pubspec.yaml`, with these removals only:

- the `windows/` plugin and its `windows:` entry in `pubspec.yaml` (its CMake build downloads the
  960 MB Firebase C++ SDK on every Windows build; FamChat uses Firebase only on Android, iOS and web),
- `example/`, `test/`, `dev_dependencies`, `false_secrets` and `resolution: workspace`.

To update: copy the new version from `~/.pub-cache/hosted/pub.dev/firebase_core-<version>/`, repeat the
removals, keep this file, and bump the `firebase_core` constraint in `app/pubspec.yaml`.
