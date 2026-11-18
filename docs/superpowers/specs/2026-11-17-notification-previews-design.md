# Notification message previews — design

Status: approach and default approved by the user on 2026-11-17 (option 1, off by default).

## Why

Today every push says only who wrote ("New message", "New message from Ann"). The family wants to
read the message itself from the notification, on every device they use, without opening the app.
FamChat is end-to-end encrypted, so the server, Google and Apple must never see the text. The only
place a preview can be made is on the receiving device.

## Goals

- A **"Show message previews"** switch under Settings → Notifications, **off by default**, set
  **per device** (previews on a laptop, off on a phone's lock screen).
- With it on, a notification shows what the message says:
  - text shows the text itself, cut to 300 characters;
  - photo shows "📷 Photo", voice "🎤 Voice message", video "🎥 Video", GIF "GIF";
  - anything else, or any failure, shows the server's generic text ("New message", "New message from Ann").
  Edits, deletes and reactions are silent and never push.
- Every platform eventually gets this: desktop (macOS, Windows, Linux), Android, iPhone and web.
- Releases come in stages, each shippable on its own:
  1. Server, Android, desktop and the setting.
  2. iPhone.
  3. Web.

## Non-goals

- Photo thumbnails in notifications, replying from a notification, or marking a message read from one.
- Changing *which* messages notify: mute, mention and silent rules stay exactly as they are.
- Previews on the old FCM "notification" path. A device with previews off keeps today's pushes,
  byte for byte.

## Anti-goals (a failure even if it "works")

- Readable message text reaching the server, the push queue, FCM, APNs or logs.
- A preview path that loses notifications. If decrypting fails for any reason, the person still
  gets today's generic notification:
  - a key that isn't there yet, an unknown sender device or a bad signature;
  - a timeout, a payload that's too big, or a crash.
- A preview that could be forged. The text must pass the same checks the chat screen applies: it
  opens under the chat key with AEAD, and the sender device's Ed25519 signature verifies against a
  **trusted** device of the claimed sender.
- Previews on a lock screen that the OS has been told to keep private:
  - Android: the notification is `VISIBILITY_PRIVATE`, with a public version holding the generic text.
  - iOS: the system's own "Show Previews" setting applies as it does for any app.

## How it works (option 1: the encrypted message rides in the push)

### Server (stage 1)

- Migration `0014_push_previews.sql`: `devices.push_previews INTEGER NOT NULL DEFAULT 0`.
- `PUT /devices/me/push` accepts an optional `previews: boolean` next to `token`.
  - If `previews` is absent, the device's current value stays.
  - When the token is cleared, `push_previews` resets to 0.
- `PushJob` gains an optional `preview: {senderDeviceId, epoch, envelope}`:
  - The hub fills it from the message it is fanning out. `envelope` is the message's envelope JSON
    exactly as stored.
  - It is left out when the serialised envelope is longer than **3000 bytes**, which keeps the FCM
    message under its 4 KB data limit. Those devices get the generic push.
  - Retries carry it unchanged. Today the consumer rebuilds the retry job field by field
    (`server/src/push/consumer.ts`), so `preview` must be added there.
- The consumer selects `push_previews` with each device token and builds one of two messages per device:
  - **previews off, or no `preview` in the job:** today's message, unchanged.
  - **previews on and `preview` present:** a *preview message*. Its `data` holds:
    - `chatId`, `messageId`, `senderUserId`, `senderDeviceId` and `epoch`;
    - `env`, the envelope JSON as a string;
    - `title` and `body`, today's generic text, used as the fallback.

  The platform blocks:
  - **android:** a data-only message (no `notification` block), `priority: "high"`. The app draws it.
  - **apns:** keeps the alert with the generic title and body, plus `"mutable-content": 1`. The
    iPhone extension rewrites the body; if it fails or runs out of time, iOS shows the generic alert.
    Until stage 2 ships, an iPhone never turns previews on, so this path is unused but harmless.
  - **webpush:** data-only. The service worker draws it (stage 3); until then, the web never turns
    previews on.
- `docs/protocol.md` documents the field, the payload and the 3000-byte cut-off.

### What a device needs to decrypt

1. The chat key for `(chatId, epoch)`.
2. The trusted directory entry for `senderDeviceId`: its user must equal `senderUserId`, and it
   must not be revoked.
3. Its `signPub`, to check the envelope signature.

These are the same checks `ChatSync` applies (`app/lib/chat/chat_sync.dart`, around `decryptEnvelope`).
The body comes from the same `Plaintext.decode` the chat uses. The four media labels are shared
with the chat list. Unknown kinds fall back to the server's generic text, not the chat list's
"Message" or "Unsupported message" labels. The title stays
the server's generic title (sender name or group title). In a group, the body becomes
"`<sender>`: `<preview>`".

### Desktop (stage 1)

Desktop notifications already come from socket `msg` events in `MessageNotifier._onEvent`
(`app/lib/push/notifications.dart`); `LocalNotifier` only draws them.
With previews on, `_onEvent` decrypts the event's envelope through the existing chat-sync path, or
waits for the message row it writes, and uses the preview body. If that fails, it falls back to
`notificationText`. Nothing on the server is involved, because the hub never pushes to a device with
an open socket.

- The same `MessageNotifier` also serves background **web** tabs. In stage 1 the preview branch is
  gated to desktop platforms (`!kIsWeb`), and web tabs join in stage 3.
- A macOS app with its socket closed but a push token gets FCM pushes. Until stage 2, macOS doesn't
  send `previews: true`, so it keeps getting generic pushes; stage 2 covers macOS with the same
  extension approach as iPhone if it uses APNs.

### Android (stage 1)

- A top-level `FirebaseMessaging.onBackgroundMessage` handler runs for data-only preview messages.
  It opens the chat database and the device keys in the background isolate, decrypts, and shows the
  notification through `flutter_local_notifications`:
  - channel `messages`, tag = chatId (the same as today, so a newer message replaces the older one);
  - tap opens the chat;
  - `VISIBILITY_PRIVATE` with a generic public version.
- **Any** exception, or no key, shows the generic `title`/`body` from `data`.
- In the foreground, a preview push goes to the existing in-app banner (`showInApp`). The banner
  shows the preview text instead of the generic text, and it is still hidden while that chat is on
  screen. `PushMessage` mapping reads `title`/`body` from `data` when there's no `notification` block.
- Reliability (builder's call, accepted): an app that has been force-stopped already gets no FCM
  at all, so data-only messages change nothing there. FCM deprioritises high-priority data
  messages only when they don't lead to a notification, and this handler always shows one. What
  remains is aggressive vendor battery savers, the same exposure Signal and WhatsApp accept.

### iPhone (stage 2)

- A new **Notification Service Extension** target, `NotificationService`, written in Swift, in the
  existing app group `group.dev.famchat.app`. Flutter can't run inside it.
- The app mirrors a small **preview keyring** into a keychain access group the app and the
  extension share. Entries are kept only while previews are on and wiped when they're turned off or
  on sign-out. Accessibility is `kSecAttrAccessibleAfterFirstUnlock`. The keyring holds:
  - chat keys, keyed by `(chatId, epoch)`;
  - trusted device entries `deviceId → (userId, signPub, revoked)`.

  The app rewrites it whenever keys or the directory change. It holds every epoch the app has for every
  chat, which is small at family scale.
  Accepted limit: a chat or key epoch that arrives while the app isn't running previews only after
  the app has next run, and gets the generic text until then. Background refresh is out of scope.
- Crypto uses CryptoKit only, with no third-party dependency:
  - XChaCha20-Poly1305 is HChaCha20 (hand-written, checked against the draft-irtf-cfrg-xchacha
    test vectors) plus `ChaChaPoly`;
  - signatures are checked with `Curve25519.Signing.PublicKey.isValidSignature`.
- If anything fails, the extension delivers the original generic content unchanged.

### Web (stage 3)

- The app mirrors the same preview keyring into an IndexedDB store, `famchat_preview_keyring`,
  that the service worker can read.
- `firebase-messaging-sw.js` handles data-only preview pushes. It decrypts with a vendored
  `@noble/ciphers` (xchacha20poly1305) and `@noble/curves` (ed25519), shipped as a local file
  rather than from a CDN.
- It falls back to the generic text, and a click opens `/chats/<id>` as today.

### The setting

- `NotificationSettingsGroup` gets a "Show message previews" switch with the subtitle "Show what
  messages say. Only this device can read them."
- It is shown only on platforms whose stage has shipped. The value lives on the device.
- Turning it on:
  1. Sends `PUT /devices/me/push {token, previews: true}`; desktop doesn't need this step.
  2. Builds the keyring where that platform needs one.
- Turning it off sends `previews: false` and wipes the keyring.
- On a new token, the stored value is sent with it.

## Constraints

- Deploy the Worker before the app release of stage 1. A server that predates the field already
  ignores `previews`, and an old app never sends it.
- vitest with `--maxWorkers=2`. Run `export PATH=$HOME/development/flutter/bin:$PATH` before
  Flutter commands. Never `dart format` existing files. Run one heavy build at a time.

## Approaches considered

1. **The encrypted message rides in the push, and the device decrypts it.** Picked. Nothing
   readable leaves the sender's device, and every platform can do it.
2. **The device fetches the message itself when a push arrives.** Each platform would need sign-in
   and network code, and iOS gives extensions little time. It's more fragile, for no gain.
3. **The sender's app sends a readable preview through the server.** Simple, but the server, Apple
   and Google could then read messages. That breaks the app's promise, so it's ruled out.

## Left to the builder

- How the Android background isolate opens the database safely alongside a running app.
- Where in `ChatSync` the shared preview helper lives.
- Swift file layout and the keychain item schema.
- The exact shape of the IndexedDB records.
- Test structure.
