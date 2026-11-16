# FamChat design

Date: 2026-11-15
Status: approved in conversation, pending implementation

FamChat is a private, invite-only messenger for one family (about a dozen people). It has real-time
text, photos, voice messages, reactions and read receipts, is end-to-end encrypted, and keeps
history synced across every device. The backend is Cloudflare (Workers, Durable Objects, D1, R2, Queues).
The client is one Flutter codebase for iOS, Android, macOS, Windows, Linux and the web.

## Decisions

| Topic | Decision |
|---|---|
| Client | Flutter (Dart). App id `dev.famchat.app`. |
| Domain | `famchat.dev`. Web app at `/`, API at `/api/*`, both from one Worker. |
| Sign-in | Admin-created one-time invite links. Each device gets its own long-lived refresh token. More devices are added by approval from an existing device (QR code). |
| Encryption | End-to-end. The server stores only ciphertext for message content and media. |
| Recovery | The admin can reset a user who lost every device. The admin can't read that user's messages; history comes back from other chat members' devices, and every reset is shown to everyone affected. |
| Push | Firebase Cloud Messaging for Android, iOS and the web. Notifications show the sender and chat name, never the message content. |
| Media cap | 8 GB for the whole family (under R2's 10 GB free tier). Past the cap, the oldest media is deleted and its messages show "media expired". |
| iOS install | TestFlight first, with an unlisted App Store listing planned. |
| v1 features | 1:1 and group chats, text, photos, voice messages, reactions, read receipts, typing indicators and presence. |
| Out of scope | Voice/video calls, public sign-up, federation, message edit/delete (v1.1), replies (v1.1). |

## Chats

Any member can create either kind of chat, and everyone has a mix of both in one chat list:

- **1:1 (direct):** exactly two people. There's at most one per pair; starting a chat with someone you already have a 1:1 with opens the existing one.
- **Group:** any subset of the family, from 2 people up to everyone, with a title and optional avatar. A group can share its members with another group (for example "Parents" and "Everyone").
- **Adding someone from a 1:1** creates a **new group** with the three people. The 1:1 and its history stay private to the original two.
- **In a group,** any member can add people, who see the history. Members can leave, and the group creator can remove members. Both leaving and removal rotate the chat key (see "Devices and membership").
- The chat list is sorted by latest activity and shows unread counts. Groups and 1:1s look alike, apart from the group avatar and title.

## Architecture

```
famchat/
├── server/   Cloudflare Worker (TypeScript): API, FamilyHub Durable Object, D1 migrations, Queue consumer
├── app/      Flutter client for all six platforms
└── docs/     Specs, plans, protocol.md (REST + WebSocket contract)
```

### One Durable Object for the family

The brief suggested one Durable Object per chat room. For a family of about a dozen, a single
`FamilyHub` Durable Object is simpler and well within its capacity:

- Each device holds **one** WebSocket to the hub, not one per chat.
- Events that span chats (new chat created, reactions, read receipts, presence, account resets) have a single place to go.
- The hub is single-threaded, so it hands out a gap-free `seq` per chat with no races.
- It uses the hibernatable WebSocket API, so an idle family costs close to nothing.

If the family ever outgrows it, chats can be split into per-chat objects without changing the client protocol.

### Message path

1. The device encrypts the message and sends `{type:"send", id:<ULID>, chatId, envelope}` over its socket.
2. The hub checks that the sender is a chat member, assigns the next `seq`, and writes the row to D1.
   The client-generated ULID makes retries idempotent.
3. The hub sends `{type:"ack", id, seq}` to the sender and `{type:"msg", ...}` to every connected member device.
4. For members with no connected device, the hub puts a push job on a Cloudflare Queue. A consumer Worker sends it to FCM.

### Sync

Each device remembers the highest `seq` it has seen per chat. On reconnect it calls
`GET /api/chats/:id/messages?after=<seq>`, then resumes live events. Scrolling back uses `?before=<seq>`.
The client keeps a local SQLite cache (drift; wasm on web) plus an outbox for messages that haven't been sent yet.

### API surface (Worker)

- `POST /api/auth/invite/redeem` creates the user and the first device, and returns tokens
- `POST /api/auth/refresh` swaps a refresh token for a 15-minute access token
- `POST /api/devices/pair/*` starts and completes QR pairing of a new device
- `GET/DELETE /api/devices` lists or revokes your devices
- `GET /api/me` returns the signed-in user's id, device id, name and admin flag
- `POST /api/admin/invites`, `POST /api/admin/users/:id/reset` (admin only)
- `GET /api/users` lists the family with every device's public keys and certificate
- `GET/POST /api/chats`, `GET /api/chats/:id`, `POST/DELETE /api/chats/:id/members`, `POST /api/chats/:id/epochs`, `GET /api/chats/:id/messages`
- `GET/PUT /api/keys/*` fetches and adds wrapped chat keys (`/keys/wraps`, `/keys/missing`); device public keys come from `/api/users`
- `POST /api/media`, `GET /api/media/:key` upload and download encrypted media through the Worker
- `GET /api/ws` opens the WebSocket to FamilyHub (authenticated with a short-lived one-time ticket from `POST /api/ws/ticket`)

### D1 schema (first draft)

- `users(id, name, avatar_media_key, is_admin, identity_pub, created_at)`
- `devices(id, user_id, name, platform, enc_pub, sign_pub, cert_sig, refresh_hash, push_token, last_seen, revoked_at)`
- `invites(token_hash, created_by, expires_at, used_by)`
- `chats(id, kind[direct|group], title, created_by, current_epoch, last_seq, last_message_at)`
- `chat_members(chat_id, user_id, joined_seq, last_read_seq)`
- `chat_key_wraps(chat_id, epoch, device_id, wrapped_key, wrapped_by_device)`
- `messages(chat_id, seq, id, sender_device_id, envelope BLOB, created_at)`
- `media(key, uploader_id, chat_id, message_id, bytes, created_at, expired_at)`
- `events(id, kind, payload, created_at)` for the audit log (resets, device adds and revocations)

## End-to-end encryption

Library: `cryptography` + `cryptography_flutter` (Dart; native speed on mobile and desktop, works on the web).
All cryptography runs on the client. The server never sees a private key or a chat key.

### Keys

- **User identity key** (Ed25519). Signs that user's device certificates. Moves between the user's devices only through pairing.
- **Device keys**: X25519 for receiving wrapped keys and Ed25519 for signing messages. Each device's public keys carry a certificate signed by the user's identity key.
- **Chat key** (32 random bytes) per chat **epoch**. Each epoch's key is wrapped separately for every member device:
  ephemeral X25519 → HKDF-SHA256 → XChaCha20-Poly1305 (a sealed box).
- **Signed wraps.** The wrapping device signs each wrap with its Ed25519 sign key over
  `"famchat-wrap-v1" ‖ str(chatId) ‖ u32(epoch) ‖ str(recipientDeviceId) ‖ str(wrapperDeviceId) ‖ sealed`.
  A device accepts a wrap only if that signature verifies with the sign key of a device whose
  certificate chains to the identity key of a current chat member. So the server can't hand a
  device a chat key it made up, or move a wrap to another chat, epoch or device.

Other members trust a user's identity key on first use. If it changes, every chat with that user shows a banner.

### Messages

```
envelope = { v:1, epoch, nonce, ct, sig }
aad = "famchat-envelope-v1" ‖ u8(v) ‖ str(chatId) ‖ u32(epoch) ‖ str(messageId) ‖ str(senderDeviceId)
ct  = XChaCha20-Poly1305(chatKey[epoch], nonce, plaintext, aad)      (ct includes the 16-byte MAC)
sig = Ed25519(deviceSignKey, aad ‖ nonce ‖ ct)
str(s) = u16be(len) ‖ UTF-8(s); integers big-endian
plaintext = JSON { kind: text|photo|voice|reaction, ... }
```

Reactions are encrypted messages of kind `reaction` that point at a message id; the client
aggregates them. Read receipts are plaintext metadata (`chat_members.last_read_seq`).

### Media

The device compresses the file (photos: max 2048 px JPEG/HEIC→JPEG, plus a 320 px thumbnail), then
encrypts the file and thumbnail with a fresh random key. The key and a SHA-256 hash travel inside the
encrypted message. R2 holds only ciphertext.

### Devices and membership

- **New device of an existing user:** the new device shows a QR code that holds an ephemeral public key.
  An existing device scans it, signs the new device's certificate, and sends the identity key plus every
  chat-key epoch over that encrypted channel. The new device can then read the full history.
- **New chat member:** the adding device wraps every epoch for the new member's devices, so they see the history.
- **Device revoked or member removed:** the chat moves to a new epoch whose key is wrapped only for the remaining devices.
- **Missing wraps:** any online member device that sees a member device without wraps for an epoch adds them.
  This is also what restores history after an admin reset.

### Admin recovery (lost every device)

1. The admin taps "Reset account". The user signs in on a new device with a fresh one-time link, which creates a **new identity key**.
2. The server records a reset event signed by the admin's identity key, and revokes the user's old devices and tokens.
3. Other members' devices verify the admin signature, show "Mom's account was reset by Michael" in every shared chat,
   and wrap all past epochs for Mom's new device. Her history comes back from them, not from the admin.

What this does and doesn't protect:
- The admin can't read anyone's messages, and recovery never routes keys through the admin.
- An admin who fakes a reset to get a copy of someone's keys can't do it quietly. The real user's devices are signed out at once, and every affected chat shows the banner.
- Chats where no other member still has a working device can't be recovered (for example, a group whose only other member also lost every device).
- If the admin loses every device, recovery needs a second admin. The setup flow will prompt for one, and a printed admin recovery code is the fallback.

### Known limits (accepted for v1)

- The server sees metadata: who is in which chat, when messages are sent, sizes, chat titles, user names and avatars.
- The web app's code is served by our own Worker, so the web client is only as trustworthy as the deployment.
- On the web, the device's keys and refresh token are kept in WebCrypto-wrapped localStorage, which any script running on the origin can read.
- No forward secrecy inside an epoch; that's the price of syncing history to new devices.
- No safety-number verification screen in v1; trust is first-use plus the reset banners.
- XChaCha20-Poly1305 is not key-committing. A malicious member who wraps different keys for one epoch
  to different devices could show them different text for the same message. Accepted for one family;
  revisit if membership widens.

## Push notifications

- FCM covers Android, iOS (FCM forwards to APNs with the APNs key uploaded in Firebase) and the web (service worker).
- The Queue consumer gets an OAuth token from a Firebase service-account JWT signed with WebCrypto, then calls FCM HTTP v1.
- Payload: `"<sender>" in "<chat title>"`, plus `chatId` for deep linking. Never message content.
- Desktop apps get notifications only while running, over their socket.
- Stale FCM tokens (404/UNREGISTERED) are cleared from `devices.push_token`.

## Media storage cap

- `media` rows track the size of every object. The Worker keeps a running total.
- Per-file limits: photo 15 MB, voice 10 minutes.
- After an upload pushes the total past 8 GB, the Worker deletes the oldest objects until it's below 7.5 GB,
  sets `expired_at`, and broadcasts an event so clients show "media expired".
- The admin screen shows usage.

## Voice messages

AAC-LC in `.m4a` at about 48 kbps mono (about 360 KB per minute). Decided by the plan 2 spikes
(`docs/spikes/2026-11-platform-spikes.md`): the format plays on all six targets and records everywhere
except Chrome. Browsers whose recorder can't produce AAC are playback-only for voice in v1. The app checks
`isEncoderSupported(aacLc)` at runtime and hides the record button there. Opus was ruled out because
Chrome records it as WebM, which iOS and macOS can't play, and Windows can't record it.

## Client

- State: Riverpod. Navigation: go_router. Local DB: drift.
- Layout: one pane on phones; chat list and conversation side by side from about 720 px wide.
- Audio: `record` (capture) and `just_audio` (playback). Photos: `image_picker` / `file_selector`.
- Light and dark themes. The visual design will get its own pass in the UI phase.

## Distribution

| Platform | Channel | Signing |
|---|---|---|
| Web | Worker static assets on famchat.dev | n/a |
| iOS | TestFlight; unlisted App Store later | App Store Connect API key (as in duel-binder) |
| Android | Play internal testing | New FamChat keystore, saved in 1Password |
| macOS | Notarized DMG | Developer ID (as in sai) |
| Windows | Installer | Azure Artifact Signing |
| Linux | AppImage | n/a |

## Testing

- Server: vitest with `@cloudflare/vitest-pool-workers`, `maxWorkers=2`. Covers routes, the hub's ordering and fan-out, quota eviction and the push consumer.
- Client: `flutter test` unit tests for the crypto layer (with fixed test vectors), sync and the outbox. Widget tests for the main screens.
- Crypto: round-trip and tamper tests for envelopes, wraps, pairing and reset verification.
