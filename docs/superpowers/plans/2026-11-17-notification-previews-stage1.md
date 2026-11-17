# Notification previews, stage 1 (server, Android, desktop) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-device "Show message previews" switch (off by default) that makes notifications show what a message says on Android and desktop. Decryption happens on the device; the server only forwards the still-encrypted envelope.

**Architecture:** The server stores a `push_previews` flag per device. For flagged devices it sends a data-only FCM message carrying the envelope, plus the generic title and body as a fallback. One Dart helper, `previewText`, applies the chat screen's checks (trusted sender device, chat key, AEAD and signature) and returns the body. That helper is used by:
- the desktop socket notifier;
- the Android foreground banner;
- a new Android background handler, which draws the notification with flutter_local_notifications.

**Tech Stack:** Cloudflare Worker (Hono, D1, Queues, vitest), Flutter (riverpod 3, drift, firebase_messaging 17, flutter_local_notifications 23, shared_preferences, cryptography).

**Spec:** `docs/superpowers/specs/2026-11-17-notification-previews-design.md`. This plan covers stage 1 only; iPhone and web come later.

## Global Constraints

**Setting**
- The switch is labelled "Show message previews", with subtitle "Show what messages say. Only this device can read them."
- It is off by default and set per device. It lives under Settings → Notifications.

**Preview text**
- A text message is shown cut to 300 characters; when cut, it ends with "…".
- Media get fixed labels: photo "📷 Photo", voice "🎤 Voice message", video "🎥 Video", gif "GIF".
- Any other kind, or any failure, falls back to the server's generic text ("New message", "New message from Ann", "Ann mentioned you").
- In a group the body is `<sender>: <preview>`. In a direct chat it is `<preview>`. The title is always the generic title.

**What decrypts**
- A preview needs a sender device that `deviceById` finds with `certValid && trusted && !revoked`, whose `userId` is the claimed sender.
- It also needs the chat key for `(chatId, epoch)` and an envelope that passes `decryptEnvelope`.
- Anything less returns null, and the generic text is shown.

**Server**
- An envelope whose `JSON.stringify` is longer than **3000** bytes is not attached; that push is generic.
- A device with previews off gets exactly today's FCM message.

**Platforms**
- Stage 1 platforms: Android, macOS, Windows, Linux.
- iOS and the web never show the switch and never send `previews: true` in this stage. Web tabs' socket notifications stay generic (gate on `!kIsWeb`).

**Fallback and privacy**
- No readable message text may reach the server, logs or FCM.
- Every failure path still shows a notification with the generic text.

**Process**
- Deploy the Worker before any app release; this plan adds migration `0014_push_previews.sql`.
- Run vitest with `--maxWorkers=2`.
- Run `export PATH=$HOME/development/flutter/bin:$PATH` before Flutter commands.
- Never `dart format` existing files.
- Run one heavy build at a time.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A preview push arrives after the user turned previews off locally, before the server learned it. Expected: generic text (Task 6 test `previews off locally shows generic text`).
2. The background handler can't open the database, or decrypting throws. Expected: a notification with the generic text still shows (Task 6 test `failure falls back to generic`).
3. An FCM token moves to another device row (app reinstalled and signed in again). Expected: the old row's `push_previews` is reset with its token (Task 1 test).
4. A long text, more than 3000 bytes of envelope. Expected: a generic push, not an FCM error (Task 2 test).
5. A message from a device whose identity key changed and isn't yet acknowledged (`trusted = false`). Expected: generic text, never a preview (Task 3 test).

---

### Task 1: Server — per-device previews flag

**Files:**
- Create: `server/migrations/0014_push_previews.sql`
- Modify: `server/src/routes/devices.ts` (the `PUT /me/push` handler, mounted at `/api/devices/me/push`)
- Modify: `docs/protocol.md` (the push-token section)
- Test: `server/test/push.test.ts` (`describe("PUT /api/devices/me/push")`)

**Interfaces:**
- Produces: column `devices.push_previews INTEGER NOT NULL DEFAULT 0`. The body is `{token: string|null, previews?: boolean}`.

- [ ] **Step 1: Write the failing tests** in `push.test.ts`, under the existing describe, with a helper `previewsOf(deviceId)` that reads `push_previews`:
  - `stores previews with the token`: PUT `{token:"t", previews:true}` → 204, then `previewsOf` = 1. PUT `{token:"t"}` (no field) → still 1. PUT `{token:"t", previews:false}` → 0.
  - `clearing the token clears previews`: set `{token:"t", previews:true}`, then `{token:null}` → `previewsOf` = 0.
  - `a token taken by another device clears that row's previews`: a sets `{token:"shared", previews:true}`, then b sets `{token:"shared"}` → a has `push_token` null and `push_previews` 0.
  - `rejects a non-boolean previews`: `{token:"t", previews:"yes"}` → 400 `invalid_request`.
- [ ] **Step 2: Run** `cd server && npx vitest run test/push.test.ts --maxWorkers=2`. Expected: the 4 new tests FAIL (no such column / status mismatch).
- [ ] **Step 3: Implement.**
  - Write the migration (one `ALTER TABLE`).
  - In the handler:
    - validate `previews` as undefined or boolean;
    - the "take the token away" UPDATE also sets `push_previews = 0`;
    - the own-row UPDATE sets `push_previews = CASE WHEN ? IS NULL THEN 0 ELSE COALESCE(?, push_previews) END`, binding the token and then the previews value (`1`/`0`/`null`).
  - Document the field and its reset rules in `docs/protocol.md` beside `PUT /devices/me/push`.
- [ ] **Step 4: Run** the same command. Expected: PASS. Then run the full `npx vitest run --maxWorkers=2` and `npx tsc --noEmit`. Expected: all pass, tsc clean.
- [ ] **Step 5: Commit** `feat(server): per-device push previews flag`.

### Task 2: Server — preview push messages

**Files:**
- Modify: `server/src/hub.ts` (`PushJob`, the send path where `const job = {chatId, senderUserId, messageId}` is built)
- Modify: `server/src/push/consumer.ts` (`deliverJob` select and retry job, `sendAll`)
- Modify: `server/src/push/fcm.ts` (new `fcmPreviewMessage`, `sendFcm` taking a ready message)
- Modify: `docs/protocol.md` (push payload section)
- Test: `server/test/fcm.test.ts`, `server/test/push.test.ts`, `server/test/hub.test.ts`

**Interfaces:**
- Consumes: `devices.push_previews` (Task 1).
- Produces:
  - `PushJob.preview?: { senderDeviceId: string; epoch: number; envelope: string }`, where `envelope` is the stored envelope JSON string.
  - `export const MAX_PREVIEW_ENVELOPE = 3000`.
  - `export function fcmPreviewMessage(token: string, n: Notification, p: PreviewData, appOrigin: string)`, where `PreviewData = { messageId: string; senderUserId: string; senderDeviceId: string; epoch: number; envelope: string }`.
- FCM `data` keys, all strings: `chatId`, `messageId`, `senderUserId`, `senderDeviceId`, `epoch`, `env`, `title`, `body`, and `preview: "1"`.

- [ ] **Step 1: Write the failing tests.**
  - `fcm.test.ts` `fcmPreviewMessage`:
    - it has no top-level `notification` key;
    - `data` contains the keys above with string values, `epoch: "3"` and `preview: "1"`;
    - `android` is `{priority:"high"}` with no `notification` block;
    - `apns.payload.aps` has `alert:{title,body}`, `"mutable-content":1`, `sound:"default"` and `"thread-id":chatId`;
    - `webpush` has no `notification`.
  - `push.test.ts`, using the existing fake-Google helpers that capture sent bodies:
    - `previews device gets a preview message, others the plain one`: two devices of one user, one with `push_previews=1`, and a job with `preview` set. Device 1's body has `data.env`, device 2's body equals today's `fcmMessage` output.
    - `job without preview sends plain to a previews device`.
    - `retry keeps preview`: make one send return 503 and read the re-queued job; it has the same `preview`.
  - `hub.test.ts`:
    - `push job carries the envelope`: an offline recipient's queued job has `preview.envelope === JSON.stringify(env)`, `preview.epoch` and `preview.senderDeviceId`.
    - `oversized envelope is not attached`: send a text whose envelope string is longer than 3000 bytes; the job has no `preview`.
    - Silent sends still queue nothing.
- [ ] **Step 2: Run** `cd server && npx vitest run test/fcm.test.ts test/push.test.ts test/hub.test.ts --maxWorkers=2`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.**
  - In the hub, add `preview` to the job when `JSON.stringify(env).length <= MAX_PREVIEW_ENVELOPE`. It applies to both the normal job and the mention job.
  - `deliverJob` selects `d.push_previews` and passes it to `sendAll`.
  - Per device, `sendAll` builds `fcmPreviewMessage` when `push_previews = 1 && job.preview`, and `fcmMessage` otherwise.
  - `sendFcm` takes the built message object instead of building it.
  - The retry job copies `preview`.
  - In `docs/protocol.md`, document the preview payload and the 3000-byte cut-off.
- [ ] **Step 4: Run** the same command, then the full suite and `npx tsc --noEmit`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(server): send the encrypted envelope to devices with previews on`.

### Task 3: App — `previewText`, the shared decrypt-and-label helper

**Files:**
- Create: `app/lib/push/preview.dart`
- Modify: `app/lib/screens/chats/chat_list.dart` (`messageSnippet` uses the shared `mediaLabel`)
- Test: `app/test/push/preview_test.dart`

**Interfaces:**
- Produces, in `app/lib/push/preview.dart`:
  - `const maxPreviewChars = 300;`
  - `String? mediaLabel(String kind)` returns `'📷 Photo'`, `'🎤 Voice message'`, `'🎥 Video'` or `'GIF'`, and null for any other kind.
  - `Future<String?> previewText({required ChatDb db, required String chatId, required String messageId, required String senderUserId, required String senderDeviceId, required Map<String, Object?> envelope})`. It returns the label or text, or null when anything fails, and never throws.
  - `Future<String> previewBody({required ChatDb db, required String chatId, required String senderUserId, required String preview})` returns `preview` in a direct chat (or when the chat is unknown), and `'<sender name or "Someone">: <preview>'` in a group.

- [ ] **Step 1: Write the failing tests** in `preview_test.dart`.
  - Setup: an in-memory `ChatDb` (`ChatDb(NativeDatabase.memory())`, as `test/chat/chat_db_test.dart` does). Insert a `DeviceRow` for the sender with `certValid:true, trusted:true, revoked:false` and a real Ed25519 `signPub`. Store a chat key with `putKey`. Build envelopes with `encryptEnvelope`.
  - `text message returns its text`.
  - `text over 300 chars is cut with an ellipsis` gives `'${'a' * 300}…'`.
  - `photo returns 📷 Photo`; likewise voice, video and gif.
  - `unknown kind returns null` (for example `{"kind":"reaction",...}`).
  - `untrusted sender device returns null` (`trusted:false`).
  - `revoked sender device returns null`.
  - `sender device of another user returns null`.
  - `missing chat key returns null`.
  - `bad signature returns null` (signed by another key).
  - `malformed envelope returns null` (`{'v':1}`).
  - `previewBody in a group prefixes the sender name`, and `previewBody in a direct chat is the bare preview`.
- [ ] **Step 2: Run** `cd app && flutter test test/push/preview_test.dart`. Expected: FAIL (file missing).
- [ ] **Step 3: Implement `preview.dart`.**
  - Use `Envelope.fromJson` and `db.deviceById`, then `b64urlDecode(signPub)`, `db.key(chatId, env.epoch)`, `decryptEnvelope` and `Plaintext.decode`.
  - A `TextBody` gives its `text`; media kinds give `mediaLabel`.
  - Wrap everything in try/catch and return null on any failure.
  - Make `messageSnippet` in `chat_list.dart` use `mediaLabel(m.kind) ?? 'Message'` for non-text kinds, so the labels live in one place.
- [ ] **Step 4: Run** the preview tests and `flutter test test/screens` and `flutter analyze`. Expected: pass, no issues.
- [ ] **Step 5: Commit** `feat(app): decrypt a message for a notification preview`.

### Task 4: App — the setting, registration and sign-out

**Files:**
- Create: `app/lib/push/preview_setting.dart`
- Modify: `app/lib/push/notifications.dart` (`PushController`)
- Modify: `app/lib/push/providers.dart` (`register` body)
- Modify: `app/lib/push/notification_settings.dart` (the switch)
- Modify: `app/lib/session/session_controller.dart` (`_endSession` clears the setting)
- Test: `app/test/push/preview_setting_test.dart`, `app/test/push/notifications_test.dart`, `app/test/push/notification_settings_test.dart` (create if missing)

**Interfaces:**
- Produces, in `preview_setting.dart`:
  - `const previewsPrefKey = 'notification_previews';`
  - `Future<bool> readPreviewsOn([SharedPreferencesAsync? prefs])` defaults to false.
  - `Future<void> writePreviewsOn(bool on, [SharedPreferencesAsync? prefs])`.
  - `bool previewsSupported({bool web = kIsWeb, TargetPlatform? platform})` is true for android, macOS, windows and linux, and false for iOS and web.
  - `final previewsOnProvider = AsyncNotifierProvider<PreviewsOnNotifier, bool>(...)`, with `Future<void> set(bool on)`.
- `PushController.register` becomes `Future<void> Function(String token, bool previews)`. It gets a new `required Future<bool> Function() previewsOn`, plus a method `Future<void> setPreviews(bool on)` that re-sends the current token with `on`. `providers.dart` sends `{'token': token, 'previews': previews}`.

- [ ] **Step 1: Write the failing tests.**
  - `preview_setting_test.dart`: default false; write then read; `previewsSupported` truth table for the 6 platforms plus web.
  - `notifications_test.dart`:
    - `enable registers with the previews value`: with a fake `previewsOn` returning true, `register` is called with `(token, true)`;
    - `setPreviews re-registers the token`.
  - `notification_settings_test.dart`:
    - the switch with key `settings-previews` shows when `previewsSupported` is true and push or local is available;
    - it is absent on iOS and on web;
    - toggling calls `previewsOnProvider.notifier.set(true)`.
  - Session: an existing session test file asserts that after `signOut()` the pref reads false.
- [ ] **Step 2: Run** `flutter test test/push test/session`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.**
  - Write `preview_setting.dart`.
  - Add the `PushController` changes. `setPreviews` reads `messaging.getToken()`; with no token it only stores the value.
  - Add the `SwitchListTile` with leading `TileIcon(Icons.chat_bubble_outline)` and the exact copy from Global Constraints. It shows only when `previewsSupported()`. On Android it awaits `set(on)`, then `pushControllerProvider?.setPreviews(on)`.
  - `_endSession` calls `writePreviewsOn(false)` in a try/catch.
  - Use `SharedPreferencesAsync` (works in background isolates); `SharedPreferencesAsyncPlatform` test fakes go in tests.
- [ ] **Step 4: Run** the same tests and `flutter analyze`. Expected: pass, clean.
- [ ] **Step 5: Commit** `feat(app): show message previews setting`.

### Task 5: App — desktop previews from the socket

**Files:**
- Modify: `app/lib/push/notifications.dart` (`MessageNotifier`)
- Modify: `app/lib/push/providers.dart` (`messageNotifierProvider` passes `previewsOn`)
- Test: `app/test/push/notifications_test.dart`

**Interfaces:**
- Consumes: `previewText` and `previewBody` (Task 3), and `readPreviewsOn` and `previewsSupported` (Task 4).
- `MessageNotifier` gets `required Future<bool> Function() previewsOn`. The provider passes `() async => previewsSupported() && await readPreviewsOn()`, which is false on the web.

- [ ] **Step 1: Write the failing tests** in the existing `MessageNotifier` group, with a fake `LocalNotifier` that records `show` calls and the in-memory DB setup from Task 3:
  - `previews on shows the decrypted text`: a `msg` event whose `message` carries `id`, `chatId`, `senderUserId`, `senderDeviceId` and `envelope` (a map, as `messageOut` sends it). The body is the text.
  - `previews off shows generic text`.
  - `previews on but undecryptable falls back to generic`.
  - `group shows sender prefix`.
- [ ] **Step 2: Run** `flutter test test/push/notifications_test.dart`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.** In `_onEvent`, after the mute check, if `await previewsOn()`, call `previewText` with the event's message fields; when it returns non-null, the body is `previewBody(...)`. The title stays from `notificationText`.
- [ ] **Step 4: Run** the same test and `flutter analyze`. Expected: pass.
- [ ] **Step 5: Commit** `feat(app): message previews in desktop notifications`.

### Task 6: App — Android preview pushes (background and foreground)

**Files:**
- Create: `app/lib/push/android_previews.dart`
- Modify: `app/lib/push/push_messaging.dart` (`PushMessage` fields, `fromData`, background registration)
- Modify: `app/lib/main.dart` (register the background handler on Android before `runApp`)
- Modify: `app/lib/push/providers.dart` (foreground enrich, tap routing for local notifications)
- Modify: `app/lib/chat/db/chat_db.dart` (`openChatDb` uses `DriftNativeOptions(shareAcrossIsolates: true)`)
- Test: `app/test/push/android_previews_test.dart`, `app/test/push/notifications_test.dart`

**Interfaces:**
- Consumes: Tasks 3 and 4, and the FCM data keys from Task 2.
- Produces:
  - `PushMessage` gains `messageId`, `senderUserId`, `senderDeviceId`, `envelope` (a `Map<String,Object?>?` decoded from `data['env']`) and `bool get isPreview` (`data['preview'] == '1'`).
  - `fromData` falls back to `data['title']`/`data['body']` when the notification fields are null.
  - `Future<({String title, String body})> previewNotificationText(PushMessage m, {required Future<bool> Function() previewsOn, required Future<ChatDb> Function() openDb})` returns the generic `m.title`/`m.body` unless previews are on and `previewText` succeeds. It never throws: an `openDb` failure gives the generic text.
  - `@pragma('vm:entry-point') Future<void> firebaseBackgroundHandler(RemoteMessage message)` is top-level in `android_previews.dart`. For `isPreview` messages it:
    1. initialises flutter_local_notifications (Android icon `@mipmap/ic_launcher`);
    2. creates channel `messages` ("Messages", importance high), which is idempotent;
    3. calls `previewNotificationText`;
    4. shows the notification with id `chatId.hashCode & 0x7fffffff`, `tag: chatId`, and `visibility: NotificationVisibility.private`. flutter_local_notifications 23 has no `publicVersion`, so the OS's own "contents hidden" redaction stands in for the spec's generic public version; record this as a ruling. The fallback title and body come from `data`.
    5. sets payload `/chats/<chatId>`.
  - `PushController` gets `required Future<PushMessage> Function(PushMessage) enrich`. `_foreground` awaits it before `showInApp`. The provider's enrich replaces `body` with the preview result for `isPreview` messages.

- [ ] **Step 1: Write the failing tests** in `android_previews_test.dart`, testing `previewNotificationText` with the Task 3 DB setup:
  - `preview on and decryptable gives the text`;
  - `previews off locally shows generic text`;
  - `failure falls back to generic`: `openDb` throws;
  - `not a preview message gives generic`.
  - In `notifications_test.dart`:
    - `PushMessage.fromData reads title and body from data`;
    - `foreground preview is enriched before showInApp`;
    - `foreground preview for the visible chat is still suppressed`.
- [ ] **Step 2: Run** `flutter test test/push`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.**
  - Register in `main.dart`: `if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android && push != null) FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);`.
  - In the background handler:
    - call `Firebase.initializeApp` with `firebaseOptions()` when it isn't initialised;
    - `openDb` is `openChatDb()`, closed after use;
    - previews come from `readPreviewsOn()`.
  - Tap routing: the app's Android startup initialises the same flutter_local_notifications instance with `onDidReceiveNotificationResponse` → `router.go(payload)`. `getNotificationAppLaunchDetails()` routes a cold start. This sits in the `pushControllerProvider` setup and only runs on Android.
  - `openChatDb`'s `shareAcrossIsolates: true` lets the background isolate and a running app share one connection.
- [ ] **Step 4: Run** `flutter test` (the full app suite) and `flutter analyze`. Expected: all pass, clean.
- [ ] **Step 5: Build-check Android:** `flutter build apk --debug`. Expected: it builds.
- [ ] **Step 6: Commit** `feat(app): message previews in Android notifications`.
