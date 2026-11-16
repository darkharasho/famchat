# Push Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A family member whose devices are all offline gets a push notification ("Mom" / "New message", or "Parents" / "New message from Mom") on Android, iOS and the web, and tapping it opens that chat. Desktop apps (and a hidden web tab) show a local notification from the socket while running. Push stays cleanly off until Firebase is configured.

**Architecture:** Server: `PUT /api/devices/me/push` stores the device's FCM token (cleared on revoke/sign-out as before). `FamilyHub` prunes half-open sockets (no ping for 90 s) before deciding who is offline, then sends a `PushJob` to the `famchat-push` Queue. The same Worker's `queue()` handler resolves names from D1, gets a Google OAuth token from the service-account JWT (RS256, WebCrypto, cached), and calls FCM HTTP v1 once per device token with `android`/`apns`/`webpush` blocks. 404/`UNREGISTERED` clears the token; 429/5xx re-enqueue only the failed devices (3 attempts). No `FCM_SERVICE_ACCOUNT` secret → jobs are acked and dropped. `POST /api/devices/me/push/test` sends a test notification to the caller's own devices synchronously and reports per-device results.

Client: `lib/push/` — `firebase_options.dart` is a committed stub whose `currentPlatform` throws `UnsupportedError` until `flutterfire configure` overwrites it; `pushSupported` is true only on Android/iOS/web with options. `PushController` (Riverpod) requests permission, registers the token and its refreshes, routes taps (`getInitialMessage`, `onMessageOpenedApp`) through `DeepLinks`, and shows foreground messages in-app unless that chat is open. `DesktopNotifier` (macOS/Windows/Linux via `flutter_local_notifications`, web via the `Notification` API) shows a notification for socket `msg` events from others while the window isn't focused. The router remembers a signed-in location that a loading redirect swallowed and returns to it once the session is ready (cold-start notification taps and web deep links). Mobile clients close their socket when paused so pushes start immediately.

**Tech Stack:** Cloudflare Queues (producer + consumer in the `famchat` Worker), WebCrypto RSASSA-PKCS1-v1_5, FCM HTTP v1. Flutter: `firebase_core` 5.2 (vendored override without the Windows plugin), `firebase_messaging` 17.1, `flutter_local_notifications` 23, `package:web`.

**Spec:** `docs/superpowers/specs/2026-11-15-famchat-design.md` ("Push notifications"). Roadmap row 9. Plan 5 handoff (`PushHook`), plan 4 ruling (deep link during loading).

## Global Constraints

- Notification text is built server-side from metadata only: direct chat → title `<sender name>`, body `New message`; group → title `<chat title>`, body `New message from <sender name>`. Data: `{chatId}` only. Never envelope fields.
- One `notification`/`data` pair per device token; `android.notification.channel_id = "messages"`, `android.notification.tag = chatId`, `android.priority = "high"`; `apns.payload.aps = {sound: "default", "thread-id": chatId}`; `webpush.fcm_options.link = APP_ORIGIN + "/chats/" + chatId`, `webpush.notification.tag = chatId`.
- Presence: a socket is stale when neither its last auto-responded ping nor its connect time is within `STALE_SOCKET_MS = 90_000 (Chrome throttles hidden-tab timers to ~1/min)`; stale sockets are closed with 4002 and treated as gone (presence offline broadcast).
- Push is disabled, never failing, when: no `PUSH_QUEUE` binding (hub logs nothing), no `FCM_SERVICE_ACCOUNT` (consumer acks), no Firebase options on the client (`pushSupported == false`).
- Chat ids in notification data are validated as ULIDs before routing.
- No Firebase config is committed tonight; every platform must build without it.
- One build/test process at a time; vitest maxWorkers 2.

## Rulings

1. **Queues available** on the account: `famchat-push` created (`max_batch_size 10`, `max_batch_timeout 1`, `max_retries 3`). Cost if wrong: none — the queue exists.
2. **No migration.** `devices.push_token` exists; platform blocks are always all included (FCM applies the one for the token's platform), so no `push_platform` column. Cost if wrong: a later migration (0007) if per-platform tuning is ever needed.
3. **Dart-only Firebase init** (`Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)`), no `google-services` Gradle plugin, no `GoogleService-Info.plist`. The setup script reverts flutterfire's native edits and commits only `lib/push/firebase_options.dart` + `web/firebase-config.js`. Cost if wrong: if some FCM feature needs the native files, add them and the Gradle plugin later.
4. **Vendored `firebase_core` without Windows** (`app/third_party/firebase_core`, `dependency_overrides`). Its Windows plugin downloads a 960 MB C++ SDK on every Windows build and we never use Firebase on Windows. Cost if wrong: re-vendor on every firebase_core bump (documented in its README).
5. **FCM only on Android, iOS and web.** macOS uses local notifications from the socket (spec: desktop only while running). Cost if wrong: macOS FCM later needs APNs entitlements on macOS.
6. **Presence pruning is lazy** (on every `send` and every new connection), not alarm-driven. Cost if wrong: an offline presence dot can lag until the next send/connection; pushes are correct because pruning runs before the offline calculation.
7. **Mobile clients close the socket when paused** and reopen on resume, so a backgrounded phone gets pushes at once instead of after the 90 s stale window. Cost if wrong: a few reconnects per day; outbox already handles reconnects.
8. **Notification text** as in Global Constraints (spec's `"<sender>" in "<chat title>"` rendered as title/body). Cost if wrong: a string change.
9. **Test endpoint is per user, not admin:** `POST /api/devices/me/push/test` sends only to the caller's own devices. Cost if wrong: none (no one else is reachable).
10. **Token uniqueness:** registering a token clears it from any other device row (a reinstalled app paired again). Cost if wrong: none.
11. **Retries:** per-token 429/5xx/network errors re-enqueue a job restricted to those device ids (`deviceIds`, `attempt`, delay 10 s × attempt, up to 3 attempts); unexpected exceptions `msg.retry()`. Successful tokens never get a duplicate. Cost if wrong: a dropped notification after 3 failures.
12. **`device` events are not pushed** (pairing happens with both devices open; revocation is visible next launch). Cost if wrong: small follow-up.
13. **Web permission is asked from a user gesture** (a "Turn on notifications" banner in the chat list); iOS/Android/macOS ask on the first signed-in home screen; Windows/Linux need none.
14. **iOS entitlements:** `aps-environment` added via `Runner.entitlements`; the release workflow archives unsigned and signs at export, so it warns when the exported IPA lacks `aps-environment` rather than guessing. Cost if wrong: iOS pushes don't arrive until the profile/export is fixed (visible as a release warning).

## Review Focus

1. Half-open socket (phone vanished) → after 90 s without ping its device counts as offline and gets a push. Test `a socket silent for over a minute is pruned and its user pushed` (Task 2).
2. FCM 404 / `UNREGISTERED` → that token is cleared; others still sent. Test `stale tokens are cleared` (Task 3).
3. FCM request body never contains the envelope (`ct`, `nonce`, `sig`) or plaintext. Test `payload has names and chatId only` (Task 3).
4. No secret → job acked, no fetch. Test `without FCM_SERVICE_ACCOUNT jobs are dropped` (Task 3).
5. Cold-start notification tap while the session loads → lands on `/chats/<id>`, not home. Test `a deep link swallowed by loading is restored after sign-in` (Task 5).
6. Foreground push for the chat on screen → nothing shown. Test `foreground message for the open chat is suppressed` (Task 6).
7. App without Firebase options → no Firebase calls, app runs. Test `push stays off without options` (Task 6).

---

### Task 1: Push token registration

**Files:** Modify `server/src/routes/devices.ts`, `docs/protocol.md`; test `server/test/push.test.ts`.

- `PUT /api/devices/me/push {token: string (1..4096) | null}` → 204; sets `push_token` on the caller's device, clears the same token from other rows. Registered before `/:id` routes.
- [ ] Failing tests: set, replace, null clears, invalid body 400, same token moves between devices, revoke clears (existing). Implement; commit.

### Task 2: Presence pruning and the queue producer

**Files:** Modify `server/src/hub.ts`, `server/src/env.ts`, `server/wrangler.jsonc`, `server/vitest.config.ts`; test `server/test/hub.test.ts`.

- Attachment gains `at` (connect ms). `prune()` closes sockets whose `max(getWebSocketAutoResponseTimestamp, at)` is older than `STALE_SOCKET_MS`; runs at the top of `fetch` and `handleSend`. A test hook `hub.now` (default `Date.now`).
- `push` defaults to `queuePush(env)`: `env.PUSH_QUEUE?.send(job)`; absent binding → no-op.
- [ ] Failing tests: stale socket pruned + presence offline + user pushed; fresh socket with recent ping kept; default hook sends to the queue (queue consumer observed via a test override). Implement; commit.

### Task 3: FCM client and queue consumer

**Files:** Create `server/src/push/fcm.ts` (service-account parse, JWT, token cache, `sendToToken`), `server/src/push/consumer.ts` (`handlePushBatch`, `buildNotification`, `deliver`); modify `server/src/index.ts` (default export `{fetch, queue}`), `server/src/routes/devices.ts` (`POST /me/push/test`); tests `server/test/fcm.test.ts`, `server/test/push.test.ts`.

- `parseServiceAccount(json)` → `{projectId, clientEmail, privateKey}` or throws. `signJwt(sa, now)` RS256. `getAccessToken(sa, fetch)` caches until 5 min before expiry. `sendToToken(...)` → `"ok" | "stale" | "retry" | "auth" | "error"`.
- [ ] Failing tests (mocked `fetch`, test RSA key generated in the test): JWT verifies with the public key and has the right claims; token cached; payload shape and no envelope; 404/UNREGISTERED clears token; 500 re-enqueues failed device only; no secret → ack without fetch; test endpoint reports results / `configured:false`. Implement; commit.

### Task 4: Client wiring — push api, deep links, router return path

**Files:** Create `app/lib/push/deep_links.dart`; modify `app/lib/router.dart`, `app/lib/chat/wire.dart` + `http_chat_api.dart` (`setPushToken`), `app/lib/chat/chat_sync.dart` (expose incoming `msg` stream); tests `app/test/router_test.dart`, `app/test/push/deep_links_test.dart`.

- `chatRouteFor(Map data)` → `/chats/<ulid>` or null. `DeepLinks` holds `pending`; router `redirect` records a signed-in-only target when sending to `/loading` and returns it once `SignedIn`.

### Task 5: Push controller, desktop notifier, lifecycle

**Files:** Create `app/lib/push/firebase_options.dart` (stub), `push_messaging.dart` (interface + Firebase impl + `pushSupported`), `push_controller.dart`, `desktop_notifier.dart` (+ `_web`/`_io` conditional parts), `open_chat.dart`, `web/firebase-messaging-sw.js`, `web/firebase-config.js`; modify `main.dart`, `chats_shell.dart`, `conversation_view.dart`, `chat/providers.dart` (lifecycle), Android `MainActivity.kt` (channel) + Gradle desugaring, iOS entitlements + Info.plist; tests `app/test/push/push_controller_test.dart`, `app/test/push/desktop_notifier_test.dart`.

### Task 6: Setup script, docs, CI

**Files:** Create `scripts/setup-firebase.sh`; modify `README.md`, `docs/protocol.md`, `.github/workflows/release.yml` (aps check), roadmap.

### Task 7: Finish — full suites, `flutter build web --release`, merge main, review, PR, CI green.
