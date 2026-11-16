# FamChat protocol (REST + WebSocket)

The contract between the Flutter client (`app/`) and the Worker (`server/`). The server code is the
reference; this document says what clients may rely on.

## Conventions

- Origin `https://famchat.dev`; every REST path is under `/api`. JSON in and out.
- Auth: `Authorization: Bearer <access token>` (15 min, from `/api/auth/refresh`). Missing/invalid → 401.
- Errors: `{"error": code}` with these statuses:

  | code | status | meaning |
  |---|---|---|
  | `invalid_request` | 400 | malformed body or query, or an operation the target doesn't allow |
  | `unauthorized` | 401 | no valid token, ticket or refresh token |
  | `forbidden` | 403 | signed in but not allowed (e.g. removing someone from a group you didn't create) |
  | `not_found` | 404 | doesn't exist **or you aren't a member** (chats never leak existence) |
  | `already_bootstrapped` | 409 | bootstrap after the first user exists |
  | `wraps_mismatch` | 409 | wraps don't cover exactly the devices the server expects; refresh `/users` and the chat, re-wrap, retry |
  | `epoch_exists` | 409 | someone else created this epoch first; fetch its wraps |
  | `stale_epoch` | 409 | the chat's current epoch isn't the one you named (or isn't created yet) |
  | `invite_invalid` | 410 | used or expired invite |
  | `conflict` | 409 | a media key already used by another device or for another chat |
  | `media_expired` | 410 | the media was deleted by quota eviction (show "media expired") |
  | `too_large` | 413 | upload over its kind's byte cap |
  | `upgrade_required` | 426 | `/api/ws` without a WebSocket upgrade |
  | `internal` | 500 | bug or outage; retry later |

- Times are Unix milliseconds. Ids are ULIDs (26 chars, Crockford base32). **Chat and message ids are
  made by the client** (wrap and envelope signatures bind them, so they must exist before the request).
- Binary values are base64url without padding.

## Shapes

```
User      = {id, name, isAdmin, identityPub, devices: Device[]}
Device    = {id, name, platform, encPub, signPub, certSig, revoked}
Chat      = {id, kind: "direct"|"group", title: string|null, createdBy, currentEpoch, epochReady,
             lastSeq, lastMessageAt: number|null, createdAt, members: Member[]}
Member    = {userId, joinedSeq, lastReadSeq}
Message   = {chatId, seq, id, senderUserId, senderDeviceId, envelope: Envelope, createdAt}
Envelope  = {v: 1, epoch, nonce, ct, sig}                                  (spec "Messages")
Wrap      = {chatId, epoch, recipientDeviceId, wrapperDeviceId, sealed, sig} (spec "Signed wraps")
```

`certSig` is the identity key's Ed25519 signature over `"famchat-device-cert-v1" ‖ encPub ‖ signPub`.
Clients must check it against the user's (trusted-on-first-use) `identityPub` before using a device's keys.

Plaintext inside an envelope is UTF-8 JSON:
`{"kind":"text","text":"..."}`, `{"kind":"reaction","target":"<messageId>","emoji":"👍"}`
(`"emoji":""` removes your reaction; the latest reaction per user and target wins), or a photo:

```
{"kind":"photo", "mediaKey", "thumbKey",       media keys of the full image and the thumbnail
 "key",                                       b64url 32-byte media key (fresh per photo)
 "sha256", "thumbSha256",                     b64url SHA-256 of each encrypted blob (as stored)
 "width", "height", "bytes", "mime":"image/jpeg"}   full image size in px; bytes = JPEG size
```

Plan 8 adds `voice`; clients keep unknown kinds (whole body) and show them as unsupported.

### Media blobs
Each blob is `nonce(24) ‖ ct ‖ mac(16)`, XChaCha20-Poly1305 under the message's media key with
`aad = "famchat-media-v1" ‖ str(purpose)`, purpose `"file"` (full photo, voice clip) or `"thumb"`.
Photos are re-encoded as JPEG at most 2048 px on the long side (EXIF dropped); thumbnails at most
320 px. Before decrypting, check the blob's SHA-256 against the message.

## REST

### Auth and devices (plans 1 and 4)
- `POST /auth/invite/redeem`, `POST /auth/refresh`, `GET /me`, `GET /devices`, `DELETE /devices/:id`
  (revoking also closes that device's WebSocket), `POST /admin/invites`, `POST /admin/bootstrap`.

### Directory
- `GET /users` → `{users: User[]}`: every family member and every device, revoked ones included
  (`revoked: true`) so old signatures still verify. Wrap only for devices with `revoked: false`.

### Chats
- `GET /chats` → `{chats: Chat[]}` (yours, newest activity first). `GET /chats/:id` → `{chat}`.
- `POST /chats` → `201 {chat, created: true}` or `200 {chat, created: false}`.
  - Direct: `{id, kind: "direct", userId, wraps}`. At most one per pair: if it exists, you get it back
    (your wraps are ignored).
  - Group: `{id, kind: "group", title (1–60), userIds (others, ≥1), wraps}`.
  - `wraps`: epoch 1, exactly one per live device of every member (you included), all with
    `wrapperDeviceId` = your device. Re-posting an id you created returns it.
- `POST /chats/:id/members {userIds, wraps}` → `{chat}`. Groups only. Wraps for the **current** epoch
  must cover every live device of the new users; wraps for older epochs (so they can read history) may
  be included. New members' `joinedSeq` is the chat's `lastSeq`. Fails with `stale_epoch` while the
  current epoch isn't created yet.
  Adding someone to a **direct** chat isn't allowed: clients create a new group instead.
- `DELETE /chats/:id/members/:userId` → 204. Groups only. Yourself = leave; someone else = remove
  (creator only). Either moves the chat to `currentEpoch + 1` with `epochReady: false`.
- `POST /chats/:id/epochs {epoch, wraps}` → `201 {chat}`. Creates the current epoch's key: `epoch` must
  equal `currentEpoch` and wraps must cover exactly the live devices of current members. The first
  member device wins; the rest get `epoch_exists` and fetch the wraps instead.
- `GET /chats/:id/messages?after=N` (ascending, seq > N) or `?before=N` (the latest `limit` rows with
  seq < N, returned ascending); `limit` 1–200, default 100 → `{messages: Message[]}`.

### Media
- `POST /media?chatId=&key=&kind=&messageId=` with the encrypted blob as the raw body
  (`Content-Length` required) → `201 {key, bytes}`. `key` (the object's id) and `messageId` (the
  message that will reference it) are ULIDs made by the client; `kind` is `photo`, `thumb` or `voice`
  with caps 15 MiB, 1 MiB and 8 MiB (`too_large`). You must be a member of `chatId` (`not_found`).
  Re-posting a key you already stored for the same chat and size returns `200` (safe retry); any
  other reuse is `conflict`. Upload the blobs first, then send the message that references them.
- `GET /media/:key` → the blob (`application/octet-stream`) for members of its chat (`not_found`
  otherwise); `media_expired` (410) once evicted.
- Quota: the family's live media is capped at 8 GiB. The upload that passes it makes the server delete
  the oldest blobs (a message's blobs together) until the total is below 7.5 GiB; members of each
  affected chat get `{type:"media_expired", chatId, keys}`.
- `GET /admin/usage` (admin) → `{usedBytes, capBytes, evictToBytes, files, expiredFiles}`.

### Keys
- `GET /keys/wraps[?chatId=]` → `{wraps: Wrap[]}` addressed to your device, for chats you're in.
- `PUT /keys/wraps {wraps}` → `{added}`. Missing-wrap repair: each wrap's `wrapperDeviceId` is your
  device, its epoch exists, and its recipient is a live device of a current member. Existing wraps are
  never replaced (first wrap wins).
- `GET /keys/missing` → `{missing: [{chatId, epoch, deviceId}]}`: live member devices with no wrap for
  an epoch that **your** device holds a wrap for.

### Accepting a wrap (client rule)
Accept a wrap only if `wrapperDeviceId` is a device whose cert verifies against its user's identity key,
that user is a current member of the chat, and the wrap's signature verifies with that device's
`signPub` over `"famchat-wrap-v1" ‖ str(chatId) ‖ u32(epoch) ‖ str(recipientDeviceId) ‖ str(wrapperDeviceId) ‖ sealed`.

## WebSocket

1. `POST /ws/ticket` (authed) → `{ticket, expiresAt}`: one use, valid 30 s.
2. Open `wss://famchat.dev/api/ws?ticket=<ticket>`. Bad/used/expired ticket or revoked device → 401.

Frames are JSON text. One socket per device carries every chat.

### Client → hub
| frame | effect |
|---|---|
| `{type:"send", id, chatId, envelope}` | store and fan out a message (below) |
| `{type:"typing", chatId}` | relayed to the other members' sockets; send at most every 3 s while typing |
| `{type:"read", chatId, seq}` | sets your `lastReadSeq` (never backwards, capped at `lastSeq`) |
| `{type:"ping"}` | answered `{type:"pong"}` without waking the hub; send every ~25 s |

### Hub → client
| frame | when |
|---|---|
| `{type:"hello", online:[userId]}` | right after connecting |
| `{type:"presence", userId, online}` | a user's first socket opened / last socket closed |
| `{type:"ack", id, seq, createdAt}` | your `send` was stored (or had been stored before) |
| `{type:"error", id?, error}` | `invalid_request`, `not_member`, `stale_epoch`, `conflict`, `internal` |
| `{type:"msg", message: Message}` | a new message in one of your chats (not echoed to the sending socket) |
| `{type:"typing", chatId, userId}` | another member is typing; show for ~5 s |
| `{type:"read", chatId, userId, seq}` | a member's (or your own other device's) read position moved |
| `{type:"chat", chatId}` | chat created or changed (members, epoch): `GET /chats/:id` |
| `{type:"removed", chatId}` | you left or were removed |
| `{type:"keys", chatId, epoch?}` | new wraps may be waiting: `GET /keys/wraps?chatId=` |
| `{type:"media_expired", chatId, keys:[...]}` | those media keys were evicted; show "media expired" |
| close code 4001 | this device was revoked |

### `send` rules
- `envelope.v == 1`, `nonce`/`ct`/`sig` base64url, JSON ≤ 64 KiB, `envelope.epoch == currentEpoch` and
  that epoch created; otherwise `invalid_request` / `stale_epoch`. Not a member → `not_member`.
- **Idempotent on `id`:** resending an id from the same device and chat returns the original `ack`
  (same `seq`) and doesn't fan out again. The same id anywhere else → `conflict`.
- Sends are processed one at a time; `seq` per chat is gap-free and `msg` frames go out in `seq` order.
  Clients still treat a `seq` above `lastSeen + 1` as a gap and fetch `?after=lastSeen`.
- On `stale_epoch`, get the chat, create or fetch the current epoch's key, re-encrypt **with the same
  id**, and resend.

### Sync
On every (re)connect: `GET /users`, `GET /chats`, `GET /keys/wraps`, then per chat
`GET /chats/:id/messages?after=<highest seq stored>` until a short page, then `GET /keys/missing` and
add wraps you can, then resend the outbox.

### Hooks for later plans
- Push (plan 9): `FamilyHub.push.notify({chatId, senderUserId, messageId, userIds})` is called for members
  with no open socket after each new message; it's a no-op until plan 9 replaces it with a Queue producer.
- Device pairing / revocation (plan 6): a new device gets history through missing-wrap repair
  (`/keys/missing` + `PUT /keys/wraps`); revocation should bump epochs like a leave does.
