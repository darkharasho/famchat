# Release Pipelines & Web Hosting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship FamChat from CI: the web app on famchat.dev from the same Worker as the API, and native builds to TestFlight, Play internal testing, a notarized DMG, a signed Windows installer and an AppImage.

**Architecture:** The Worker gets a Workers static-assets directory (`server/public`, filled from `flutter build web`) with SPA fallback and `run_worker_first: ["/api/*"]`. `scripts/deploy.sh` (build web → D1 migrations → `wrangler deploy` → smoke test) is the one deploy path, run locally or by `deploy.yml`. `release.yml` builds each platform in its own job on a `v*` tag or a manual run, signs it, uploads to the store when the store listing exists, and collects the desktop files in a draft prerelease.

**Tech Stack:** Cloudflare Workers static assets, wrangler 4, GitHub Actions (macos-26, windows-latest, ubuntu-22.04/24.04), Flutter stable, xcodebuild + App Store Connect API key, notarytool, Azure Artifact Signing (`azure/artifact-signing-action`), Inno Setup 6, appimagetool, `r0adkll/upload-google-play`.

**Spec:** `docs/superpowers/specs/2026-11-15-famchat-design.md` ("Decisions", "Distribution", "Architecture")

## Global Constraints

- One Worker serves the web app at `/` and the API at `/api/*` on `famchat.dev`.
- App id `dev.famchat.app` on every platform.
- iOS: TestFlight, App Store Connect API key (as in duel-binder). Android: Play internal testing, new FamChat upload keystore saved in 1Password. macOS: notarized DMG, Developer ID. Windows: installer, Azure Artifact Signing (`darkharasho-signing` / `public-trust`), signature must verify `Valid`. Linux: AppImage.
- Never print secrets; never put the owner's email in files, commits or requests.
- vitest `maxWorkers` ≤ 2; no local Flutter desktop/mobile builds.

## Review Focus

1. A browser navigation to an unknown `/api/...` path must still get the JSON 404, not `index.html` (pinned by `server/test/web-assets.test.ts` and `scripts/smoke-web.sh`).
2. A deep link such as `/join?code=…` opened cold must load the app (SPA fallback; smoke test).
3. A release without a store listing yet must still produce the signed file as an artifact and tell the owner what to do, not fail opaquely (store pre-checks in `release.yml`).
4. A release build silently signed with a fallback identity: Android debug key, macOS ad-hoc, unsigned Windows installer (each job fails on it).
5. Re-running a release must not collide on build numbers (build number = minutes since epoch).

---

### Task 1: Web app from the Worker

**Files:** Modify `server/wrangler.jsonc`, `.gitignore`, `app/lib/main.dart`, `app/pubspec.yaml`; Create `server/test/web-assets.test.ts`, `server/test/raw.d.ts`.

- [x] Test: `web-assets.test.ts` — config has `assets.directory == "./public"`, `not_found_handling == "single-page-application"`, `run_worker_first == ["/api/*"]`; `GET /api/unknown` (plain and with `Sec-Fetch-Mode: navigate`) is 404 `application/json` `{"error":"not_found"}`.
- [x] Run: fails before the `assets` block exists.
- [x] Add the `assets` block; gitignore `server/public`; `usePathUrlStrategy()` in `main.dart` (+ `flutter_web_plugins` sdk dep).
- [x] Run `npx vitest run --maxWorkers=2` and `npm run typecheck`: pass. Manual: `wrangler dev` with a stand-in `public/` serves `/`, `/join` → index.html, `/main.dart.js` → JS, `/api/unknown` → JSON 404.
- [x] Commit.

### Task 2: Deploy

**Files:** Create `scripts/deploy.sh`, `scripts/smoke-web.sh`, `.github/workflows/deploy.yml`.

- [x] `deploy.sh`: `flutter build web --release --no-web-resources-cdn` → copy to `server/public` → `wrangler d1 migrations apply famchat --remote` → `wrangler deploy` → `smoke-web.sh https://famchat.dev`. Env `SKIP_WEB_BUILD=1`, `SKIP_SMOKE=1`.
- [x] `smoke-web.sh <base>`: `/` and `/join?code=x` are 200 html containing `flutter_bootstrap.js`; `/api/health` is `{"ok":true}`; `/api/does-not-exist` with navigate headers is 404 JSON. Retries 6× 10 s.
- [x] `deploy.yml`: on push to main (server/**, app/**, the scripts), skip with a warning when `CLOUDFLARE_API_TOKEN` is missing; else server typecheck + tests, then `scripts/deploy.sh`.
- [x] actionlint clean. Commit.

### Task 3: Native release workflow

**Files:** Create `.github/workflows/release.yml`, `scripts/store-check.py`, `app/windows/installer/famchat.iss`, `app/linux/packaging/{build-appimage.sh,dev.famchat.app.desktop}`; Modify `app/android/app/build.gradle.kts`.

- [x] `store-check.py appstore|play <id>` prints `exists` / `missing: <reason>`, exit 1 only if the check itself fails.
- [x] Jobs `version`, `ios`, `android`, `macos`, `windows`, `linux`, `github-release` as described in the workflow header.
- [x] Android Gradle: `signingConfigs.upload` from env `ANDROID_KEYSTORE_FILE`/`_PASSWORD`/`ANDROID_KEY_ALIAS`/`ANDROID_KEY_PASSWORD`, debug fallback when unset.
- [x] Prove it: run on the branch (temporary `push: branches: [plan12-release]` trigger, because `workflow_dispatch` needs the file on main), iterate until each job is green or blocked on an owner-only action. Remove the temporary trigger. Result (run 43856540897): all seven jobs green; Windows installer and exe `Valid`; DMG notarization `Accepted`, stapled, `source=Notarized Developer ID`; IPA exported with App Store distribution signing; AAB signed with the upload key; draft prerelease `v1.0.0-build.29913798` holds the DMG, setup.exe and AppImage. Store uploads skipped: no App Store Connect app record yet; Play says "Package not found" until the first bundle is uploaded by hand.
- [x] Open the PR; `app.yml` and `server.yml` green.

## Rulings ledger

| # | Ruling | Why | Cost if wrong |
|---|---|---|---|
| R1 | Assets dir is `server/public` (gitignored), filled by `deploy.sh` from `app/build/web`. | Keeps wrangler config self-contained; tests don't need a web build. | Deploying without the script ships no web app (wrangler errors on a missing dir), caught immediately. |
| R2 | Routing pinned by a config test plus a local `wrangler dev` check and a post-deploy smoke test, not by vitest. | `SELF.fetch` in vitest-pool-workers calls the Worker directly and skips the asset router. | A future wrangler routing change slips past unit tests; the smoke test catches it at deploy. |
| R3 | `--no-web-resources-cdn` (self-host CanvasKit). | Private app; no runtime dependency on gstatic.com. | ~10 MB more per deploy upload; none for users. |
| R4 | No Cloudflare API token could be created (MCP OAuth and wrangler OAuth lack token-write scope); `deploy.yml` skips with a warning and `scripts/deploy.sh` is the working path. | No credential available non-interactively. | Main isn't auto-deployed until the owner adds `CLOUDFLARE_API_TOKEN`. |
| R5 | Build number = minutes since Unix epoch (iOS, Android, macOS, Linux); Windows gets only `--build-name`. | Monotonic across workflows/branches/re-runs; Windows file-version parts cap at 65535. | Android versionCode limit 2.1e9 is reached in ~4000 years; mixing with a hand-chosen small build number later would be refused by the stores (easy to see). |
| R6 | iOS: archive unsigned, sign at export with cloud-managed signing via the API key (duel-binder pattern). | Avoids a new development cert per runner. | Happened: the App Manager key got "Cloud signing permission error"; the secrets now hold the team's Admin key (`5287VQWCFL`, as in duel-binder). |
| R7 | Store uploads are gated by `store-check.py`: missing listing → warning + signed artifact, job stays green. | First Play upload and the App Store Connect app record are owner-only console actions. | A misconfigured service account looks like "missing listing" (warning text says both causes). |
| R8 | Play upload tries `status: completed`, falls back to `draft`. | Play refuses non-draft releases for apps that haven't completed setup. | A real failure gets one retry as a draft before the job fails. |
| R9 | macOS: re-sign the Flutter build ourselves with `--options runtime` + `Release.entitlements`, bundle renamed `FamChat.app` in the DMG; notarize with the App Store Connect API key (not Apple ID). | Flutter's template has no hardened runtime; the API key avoids 2FA/app-password drift and keeps the Apple ID out of CI use. | Sandbox + hardened runtime could block something at runtime (mic needs `audio-input`, present). |
| R10 | Windows: Inno Setup, per-user install by default, signed exe/dlls + installer via `azure/artifact-signing-action@v2`, MSVC runtime DLLs copied in after signing. | Simpler than MSIX (no store identity), matches spec's "installer". | Machines with a stricter policy may want an MSIX later. |
| R11 | Linux AppImage built on ubuntu-22.04, relying on system GTK 3 and libmpv. | Older glibc for wider compatibility; bundling GTK/libmpv is fragile. | Users without libmpv lose voice playback until they install it. |
| R12 | Bundle id `dev.famchat.app` registered with Apple via the API during this plan (it wasn't on team YMPSC6RQ4F); PUSH_NOTIFICATIONS capability enabled for plan 9. | Needed for signing; plan 0 note was wrong. | None. |
| R13 | `ITSAppUsesNonExemptEncryption` not set in Info.plist. | Export-compliance answer for an E2E messenger is the owner's call. | Each TestFlight build waits on the compliance question in App Store Connect. |
| R14 | `ANDROID_KEY_ALIAS` is a repo variable, not a secret. | As a secret (`upload`), GitHub masked the word "upload" in every log line. | None; an alias isn't sensitive. |
| R15 | The temporary branch push trigger and its draft-release clause were removed after the proof; the proof's draft prerelease is kept (drafts aren't public). | `workflow_dispatch` only works once the file is on main. | A stale draft to delete by hand. |
