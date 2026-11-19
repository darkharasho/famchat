# Shorebird code push (small updates without store review)

## Why

Small adjustments and small features keep waiting on App Store review. Web (deploy on main) and
desktop (Sparkle / GitHub releases) already update themselves; Android's Play internal track is
unreviewed. iPhone is the bottleneck, Android benefits too.

## Goals / non-goals

- Ship Dart-only changes to installed iPhone and Android apps with no store build or review.
- Keep the existing tag-driven release flow for full (native) releases.
- Non-goal: changing how web or desktop update.
- Anti-goal: a Flutter version that drifts ahead of Shorebird again (the reason it failed before).

## Approaches

1. **Shorebird on pinned Flutter 3.47.9 (picked).** Real code push to App Store installs. Costs:
   stay on Shorebird-supported Flutter; native changes still need review.
2. TestFlight internal testers. No review, no code, but each family member needs an App Store
   Connect account and the App Store copy gets nothing.
3. Server-side switches. Only toggles prebuilt behaviour; doesn't cover small features.

Spike (2026-11-18): on Flutter 3.47.9 (Dart 3.13.7) the app resolves, analyzes clean, builds a
release APK and passes 1221/1228 tests; the 7 failures are `notification_settings_test.dart`
resetting `debugDefaultTargetPlatformOverride` too late. Only source change: Dart floor ^3.13.

## Design

- **Pin Flutter 3.47.9** in `app.yml`, `deploy.yml`, `release.yml` (one shared value), Dart
  floor `^3.13.0` in the app and `famchat_updater`. Fix the notification settings test teardown.
  Bump Flutter only to versions Shorebird supports.
- **Shorebird project**: `shorebird init` → `app/shorebird.yaml` (app id, committed),
  `auto_update: true` (patch downloads in the background, applies next launch).
- **Release**: in `release.yml`, iOS and Android build with `shorebird release ios|android
  --flutter-version=3.47.9` instead of `flutter build ipa|appbundle`; same signing, same
  TestFlight/Play upload. Desktop jobs unchanged.
- **Patch**: new `patch.yml`, run manually (platforms + release version inputs, default latest)
  or on a `patch-v*` tag, runs `shorebird patch ios|android --release-version=<v>`.
- **Secret**: `SHOREBIRD_TOKEN` from `shorebird login:ci` (owner does the browser login once).
- Patches reach only installs from a Shorebird release build, so the next store version (one
  more review) is the starting point.

## Left to the builder

Exact `shorebird release` flags for the existing iOS export options/signing; whether CI uses
`shorebirdtech/setup-shorebird` or the install script; docs/README updates.
