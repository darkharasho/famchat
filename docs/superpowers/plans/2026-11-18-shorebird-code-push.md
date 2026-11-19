# Shorebird Code Push Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Dart-only changes to installed iPhone and Android apps through Shorebird patches, with no store build or review.

**Architecture:** Pin the whole repo to Flutter 3.47.9 (Shorebird's newest). `release.yml` builds iOS and Android with `shorebird release` (iOS unsigned, then the existing entitlement + cloud-signing export), and a new `patch.yml` runs `shorebird patch` against a release. Web and desktop are untouched.

**Tech Stack:** Flutter 3.47.9 / Dart 3.13, Shorebird CLI (`shorebirdtech/setup-shorebird@v1`), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-18-shorebird-code-push-design.md`

## Global Constraints

- Flutter `3.47.9` everywhere (CI and `shorebird --flutter-version=3.47.9`); Dart floor `^3.13.0`.
- Only iOS and Android go through Shorebird; macOS/Windows/Linux/web jobs keep `flutter build`.
- `SHOREBIRD_TOKEN` repo secret; never echoed.
- Store builds keep today's version/build-number scheme (tag → NAME, minutes-since-epoch → NUMBER); Shorebird release version is `NAME+NUMBER`.
- iOS archive must keep the aps-environment/app-group entitlements (existing "Attach the entitlements" step stays).

## Review Focus

- A patch built with a different Flutter than its release is rejected by Shorebird — `patch.yml` must pass the same `--flutter-version=3.47.9`.
- `--release-version=latest` picks the most recently *updated* release; when iOS and Android releases differ, the patch must still find each platform's release (latest is per platform; document in patch.yml).
- Patch changing native code / plugins / assets-only-native: Shorebird warns and asks to confirm; in CI the job must fail rather than hang (`--allow-native-diffs` NOT passed; non-interactive fails).
- `shorebird release ios --no-codesign` puts the archive at `build/ios/archive/Runner.xcarchive`; the entitlement and export steps must point there, not `$RUNNER_TEMP/Runner.xcarchive`.
- A tag re-run (same NAME+NUMBER) must not fail on "release already exists" — NUMBER is regenerated per run, so each run is a new release; confirm in Task 3's dispatch run.

---

### Task 1: Pin Flutter 3.47.9 and Dart 3.13

**Files:**
- Modify: `app/pubspec.yaml` (`sdk: ^3.13.0`), `app/packages/famchat_updater/pubspec.yaml` (same), `app/pubspec.lock` (regenerated)
- Modify: `.github/workflows/app.yml`, `deploy.yml`, `release.yml`: every `subosito/flutter-action@v2` `with: { channel: stable, cache: true }` → `with: { flutter-version: ${{ env.FLUTTER_VERSION }}, channel: stable, cache: true }`, plus top-level `env: FLUTTER_VERSION: "3.47.9"` in each file.
- Modify: `app/test/push/notification_settings_test.dart` (platform override teardown)

- [ ] **Step 1:** With Flutter 3.47.9 (`/tmp/spike/flutter-3.47.9`, or `git clone --depth 1 -b 3.47.9 https://github.com/flutter/flutter.git`), run `flutter test --concurrency=2 test/push/notification_settings_test.dart` in `app/`. Expected: 7 fail with "The value of a foundation debug variable was changed by the test."
- [ ] **Step 2:** Reset `debugDefaultTargetPlatformOverride = null` at the end of each test body (before it returns), not in `addTearDown`/`tearDown`. Rerun: all 7 pass on 3.47.9 and on current stable.
- [ ] **Step 3:** Set the Dart floors and workflow pins above; `flutter pub get` on 3.47.9.
- [ ] **Step 4:** On 3.47.9: `flutter analyze` → "No issues found!"; `flutter test --concurrency=2` → "All tests passed!".
- [ ] **Step 5:** Commit `chore: pin Flutter 3.47.9 for Shorebird`.

### Task 2: Shorebird app, token and `shorebird.yaml`

**Files:**
- Create: `app/shorebird.yaml` (from `shorebird init`; `app_id: <id>`, `auto_update: true`)
- Modify: `app/pubspec.yaml` assets: add `- shorebird.yaml` (init does this)

- [ ] **Step 1:** In the owner's shared Shorebird console tab: create an API key (role Developer, name "famchat GitHub Actions"). Set it without printing: `printf %s "$KEY" | gh secret set SHOREBIRD_TOKEN -R darkharasho/famchat`.
- [ ] **Step 2:** Install the CLI locally (`curl --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/shorebirdtech/install/main/install.sh -sSf | bash`), then in `app/` run `SHOREBIRD_TOKEN=<key> shorebird init --force` (non-interactive; display name "FamChat").
- [ ] **Step 3:** Verify: `app/shorebird.yaml` has an `app_id`, pubspec assets lists `shorebird.yaml`, `shorebird doctor` reports no errors.
- [ ] **Step 4:** Commit `chore: add Shorebird app config`.

### Task 3: Releases through Shorebird (`release.yml`)

**Files:**
- Modify: `.github/workflows/release.yml` (ios and android jobs, header comment)

**Interfaces:** Produces Shorebird releases `NAME+NUMBER` for `ios` and `android`, which Task 4 patches.

- [ ] **Step 1:** In both jobs, after flutter-action add `- uses: shorebirdtech/setup-shorebird@v1` and job env `SHOREBIRD_TOKEN: ${{ secrets.SHOREBIRD_TOKEN }}`.
- [ ] **Step 2:** iOS: replace "Build (Flutter, unsigned)" and "Archive" with one step: `shorebird release ios --no-codesign --flutter-version="$FLUTTER_VERSION" -- --build-name "$NAME" --build-number "$NUMBER" --dart-define=FAMCHAT_VERSION="$NAME" --dart-define=FAMCHAT_BUILD="$NUMBER"`, then `mv build/ios/archive/Runner.xcarchive "$RUNNER_TEMP/Runner.xcarchive"` so the entitlement/export steps stay unchanged. Keep `DEVELOPMENT_TEAM` reaching the build (set it via `ios/Runner.xcodeproj` already, or export `DEVELOPMENT_TEAM` env; check the archive's team in the entitlement step's output).
- [ ] **Step 3:** Android: replace `flutter build appbundle ...` with `shorebird release android --flutter-version="$FLUTTER_VERSION" -- --build-name "$NAME" --build-number "$NUMBER" --dart-define=...` (same defines); the AAB path `build/app/outputs/bundle/release/app-release.aab` is unchanged.
- [ ] **Step 4:** Update the header comment: iOS/Android are Shorebird releases; patches via `patch.yml`; new secret `SHOREBIRD_TOKEN`.
- [ ] **Step 5:** `actionlint .github/workflows/release.yml` (if installed) clean; push the branch and run `gh workflow run release.yml --ref feat/shorebird -f platforms=ios,android -f upload=false -f github_release=false`. Expected: both jobs green, ios log shows aps-environment check passing, Shorebird console lists releases for ios and android.
- [ ] **Step 6:** Commit `ci: build iOS and Android releases with Shorebird`.

### Task 4: Patch workflow and docs

**Files:**
- Create: `.github/workflows/patch.yml`
- Modify: `README.md` (short "Shipping a patch" section)

- [ ] **Step 1:** `patch.yml`: triggers `workflow_dispatch` (inputs `platforms`: `ios,android` default; `release_version`: default `latest`) and `push: tags: ["patch-*"]`. Jobs `ios` (`macos-26`) and `android` (`ubuntu-latest`, Java 21), each: checkout, flutter-action pinned, setup-shorebird, `working-directory: app`, `shorebird patch <platform> --release-version="$RELEASE_VERSION" --flutter-version="$FLUTTER_VERSION"` with the same `--dart-define`s using the release's NAME/NUMBER parsed from the target release (`latest` → leave defines from pubspec-derived NAME; document that FAMCHAT_VERSION shows the release's version). iOS patch needs `--no-codesign`. Android patch needs the keystore env as in release.yml.
- [ ] **Step 2:** README: when to patch (Dart-only) vs tag a release (native, plugins, permissions); `gh workflow run patch.yml` usage; patches apply on next app launch.
- [ ] **Step 3:** After Task 3's dispatch release exists, run `gh workflow run patch.yml --ref feat/shorebird -f platforms=android` with a trivial Dart change committed on a throwaway branch; expected: Shorebird console shows patch 1 for that release. (Delete the patch's effect by rolling it back in the console if it was against a real release.)
- [ ] **Step 4:** Commit `ci: add Shorebird patch workflow`.
