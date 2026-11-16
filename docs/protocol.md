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
  | `pairing_invalid` | 410 | pairing session expired, cancelled, or already claimed |
  | `rate_limited` | 429 | too many pairing sessions started; wait a few minutes |
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
User      = {id, name, isAdmin, identityPub, adminProof: {byUserId, signerPub, sig}|null,
             devices: Device[], resets: Reset[]}
Reset     = {id, signerUserId, signerKind: "admin"|"recovery", signerPub, recoverySig: string|null,
             oldIdentityPub, claimPub, createdAt, sig, newIdentityPub: string|null,
             claimSig: string|null, completedAt: number|null}            ("Account resets")
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
- `POST /auth/invite/redeem`, `POST /auth/refresh`, `GET /me`, `GET /devices`, `POST /admin/invites`,
  `POST /admin/bootstrap`. Redeeming a reset link also needs `resetClaimSig` ("Account resets").
- `GET /me` → `{userId, deviceId, name, isAdmin, recoveryCodeSet}`; `recoveryCodeSet` says an admin
  recovery key is registered.
- Admin routes check `users.is_admin` in the database, so a promotion counts at once.
- `DELETE /devices/:id` → 204 (your own live device, else 404). Closes that device's WebSocket (code
  4001) and, in the same transaction, moves **every chat of your user** to `currentEpoch + 1` with
  `epochReady: false`; members get `chat {chatId}` per chat and `device {userId, deviceId, revoked: true}`.
  The first member device to react creates the new epoch (`POST /chats/:id/epochs`) without the
  revoked device, exactly as after a leave.

### Pairing a new device (plan 6)
A new device N signs in by being approved from a signed-in device E of the same user. The server only
relays: it can't read the bundle, and can't swap N's keys or forge a bundle without the secret `S`,
which never leaves the two devices.

1. N makes an ephemeral X25519 key `eph`, its device keys, and `S` (12 Crockford base32 characters,
   60 bits). `POST /devices/pair/start` (no auth)
   `{ephPub, encPub, signPub, keysMac, deviceName (1–60), platform}` →
   `201 {sessionId, code, secret, deviceId, expiresAt, expiresIn}`.
   `keysMac = HMAC-SHA256(key = UTF-8(S), "famchat-pair-keys-v1" ‖ ephPub ‖ encPub ‖ signPub ‖ str(deviceName) ‖ str(platform))`.
   `code` is a 4-character lookup code; `secret` is N's claim secret (not `S`). At most 5 starts per
   client IP per 10 minutes and 50 open sessions overall (`rate_limited`). A session can be approved
   for 5 minutes.
2. N shows the typed code `code ‖ S` as `XXXX-XXXX-XXXX-XXXX` and a QR with
   `famchat-pair:1:<code ‖ S, 16 chars>:<ephPub>`. Typed codes are case-insensitive; `O`→`0`, `I`/`L`→`1`;
   spaces and dashes are ignored.
3. E: `GET /devices/pair/:code` (authed) →
   `{session: {code, deviceId, ephPub, encPub, signPub, keysMac, deviceName, platform, expiresAt}}`
   (404 unless open). E recomputes `keysMac` with `S` and, from a QR, checks `ephPub`; a mismatch means
   someone changed the keys: stop. E shows the device name and platform for confirmation.
4. E: `POST /devices/pair/:code/approve {deviceId, certSig, bundle}` (authed) → 204. `certSig` is the
   device cert for N's `encPub`/`signPub` signed by E's user's identity key (else 400); `deviceId` must be
   the session's. `bundle` is a sealed box to N's `ephPub` bound to `S` (below), at most 256 KiB.
   Single use: a second approve → 404.
5. N polls `POST /devices/pair/claim {sessionId, secret}` every ~2 s → `{status: "waiting"}` or
   `{status: "approved", userId, deviceId, isAdmin, accessToken, refreshToken, bundle}`. The first
   approved claim creates N's device row (within 10 min of approval) and sends `device {userId,
   deviceId}` to the user and everyone sharing a chat with them. Claiming again with the same secret
   within 10 min returns new tokens for the same device (lost response). Wrong secret or unknown session
   → 404; expired, cancelled or too late → 410 `pairing_invalid`. A first claim also fails with 410 if
   the approving device has been revoked since (revoking a device cancels the pairings it approved), or if
   the user's identity key changed (admin reset). Starts are limited per client network (an IPv6 /64, or
   one IPv4 address).
6. `POST /devices/pair/cancel {sessionId, secret}` → 204 (N gave up).

Bundle: `sealed = ephPubE(32) ‖ nonce(24) ‖ ct ‖ mac(16)`, XChaCha20-Poly1305 with key
`HKDF-SHA256(ikm = X25519(ephE, ephPubN) ‖ UTF-8(S), salt = ephPubE ‖ ephPubN, info = "famchat-pair-bundle-v1")`.
Plaintext is UTF-8 JSON:
`{v: 1, userId, deviceId, identitySeed, certSig, keys: [{chatId, epoch, key}], trust: [{userId, trustedIdentityPub, known: [identityPub], admin?}]}` (`admin`: E trusts the user as an admin, plan 10).
N accepts it only if it opens, `certSig` verifies over N's own keys with the identity key derived from
`identitySeed`, and `userId`/`deviceId` equal the claim's. `keys` are every chat key E holds, so N reads
the history at once; `trust` is E's trust-on-first-use state for other users, so N starts with it instead
of whatever the server shows. Member devices also add wraps for N on the `device` event.

### Directory
- `GET /users` → `{users: User[]}`: every family member and every device, revoked ones included
  (`revoked: true`) so old signatures still verify. Wrap only for devices with `revoked: false`.
  `resets` is the user's signed reset history, oldest first: their past identity keys, which clients
  accept only through resets they verify ("Account resets").

### Account resets (plan 10)
An admin resets a user who lost every device. The admin can't read their messages: the new device
gets the history from other members' devices, and every member sees the reset.

Byte strings (`str` = u16be length ‖ UTF-8, keys raw 32 bytes, `u64` = two big-endian u32, high first):
- statement `"famchat-reset-v1" ‖ str(resetId) ‖ str(userId) ‖ str(signerUserId) ‖ str(signerKind) ‖ oldIdentityPub ‖ claimPub ‖ u64(createdAt)`
- claim `"famchat-reset-claim-v1" ‖ claimPub ‖ newIdentityPub`, signed by the claim key
- recovery key registration `"famchat-recovery-key-v1" ‖ str(userId) ‖ recoveryPub`, signed by the identity key

1. The admin's device makes `resetId` (ULID), a one-time Ed25519 **claim key**, and signs the statement
   (kind `admin`, `oldIdentityPub` = the user's identity key from `/users`) with its identity key.
   `POST /admin/users/:id/reset {resetId, oldIdentityPub, claimPub, createdAt, sig}` (admin) →
   `201 {resetId, inviteToken, inviteUrl, expiresAt}`. The server checks the signature against the
   caller's identity key (400), `|createdAt − now| ≤ 10 min` (400), that `oldIdentityPub` is the
   user's key now (409 `conflict`: refresh `/users`), and that the target isn't the caller (400). In
   one transaction it records the reset, revokes every device of the user (sockets closed with 4001),
   moves each of their chats to `currentEpoch + 1` (`epochReady: false`), cancels their unclaimed
   pairings, retires their older unused reset links and makes a one-time invite bound to the user.
   Members get `chat` and `device {revoked: true}` events; everyone gets `reset {userId, resetId}`.
2. The admin gives the user the link `inviteUrl + "." + b64url(claimKeySeed)`, i.e.
   `/join#<token>.<seed>`. The seed is in the fragment and never reaches the server.
3. The new device makes a new identity key and redeems the token with
   `resetClaimSig` = claim signature over its new identity key. The server checks it against the
   reset's `claimPub` (400 if missing or wrong), then sets the user's identity key, adds the device to
   the **same user**, and completes the reset (`newIdentityPub`, `claimSig`, `completedAt`). Sharing
   users get `device {userId, deviceId}`; everyone gets `reset` again. A lost response is retried
   with the same keys like any redeem.
4. Other members' devices verify (client rule, `app/lib/chat/resets.dart`):
   - **Trusted admins:** the server's `isAdmin` alone carries no authority. A device pins the admins
     the server lists when it first sees the family (trust on first use; a paired device takes the
     approving device's list from the handover bundle), then adds only users whose `adminProof` is a
     valid promotion signed by a trusted admin's current key. Its own user always counts.
   - The statement must verify under `signerPub`. Kind `admin`: the signer is a trusted admin other
     than the user. Kind `recovery`: `recoverySig` verifies the recovery key under `oldIdentityPub`,
     a key this device trusts.
   - If `oldIdentityPub` is the trusted key and `signerPub` is the admin's **current** trusted key:
     show "Mom's account was reset by Michael" in every chat shared with the user (a newer reset of
     the same key replaces an unclaimed one), and count devices certified only by the old key as
     revoked. If the reset is completed and its claim verifies, trust `newIdentityPub` automatically
     (no manual key-change banner) and add wraps of every held epoch for the new device.
   - History: if `newIdentityPub` is a known key, `oldIdentityPub` becomes known too (no banner); here
     the admin's older known keys are accepted too, since old resets were signed with them.
   An identity change no verified reset explains keeps the manual "security key changed" banner.

Second admin: `POST /admin/users/:id/admin {sig}` (admin) → 204 (400 bad signature, 404 unknown
user). `sig` is the caller's identity key over `"famchat-admin-v1" ‖ str(userId) ‖ str(callerId)`;
`/users` shows it as `adminProof: {byUserId, signerPub, sig}` (null for the bootstrapped admin).

Admin recovery code: the admin's device makes a 25-character Crockford base32 code (125 bits, shown
as `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`), derives an Ed25519 **recovery key** from seed
`HKDF-SHA256(UTF-8(code), salt = "", info = "famchat-recovery-seed-v1")`, and registers
`POST /admin/recovery-key {recoveryPub, sig}` (admin; `sig` = identity key over the registration) →
204, replacing any earlier key. Only the public key is stored, so the server can't use the code.
A reset of the admin (by another admin) clears the stored key, and a key whose registration doesn't
verify under the admin's current identity key is refused, so a code registered from a lost device
dies with that device's identity key.
To recover without any device: `POST /auth/recover/lookup {recoveryPub}` → `{userId, identityPub}`
(401 if no admin has that key), then `POST /auth/recover {recoveryPub, resetId, oldIdentityPub,
claimPub, createdAt, sig, claimSig, identityPub, encPub, signPub, certSig, deviceName, platform}`
→ `201 {userId, deviceId, isAdmin, accessToken, refreshToken}`: a statement of kind `recovery`
signed by the recovery key plus a claim over the new identity key. Same transaction as a reset, plus
the new identity key and device, and the recovery key is cleared (single use; 401 afterwards). The
reset row keeps `recoverySig` so clients can verify it later. A retry with the same body within
10 minutes reissues tokens.

Every reset, recovery, promotion, recovery-key change, join, pairing and revocation writes an
`events` row (audit log; not exposed by the API yet).

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
  device, its epoch exists, and its recipient is a live device of a current member. An existing wrap is
  kept (first wrap wins) unless its wrapper's user left the chat or its wrapper device was revoked;
  then yours replaces it.
- `GET /keys/missing` → `{missing: [{chatId, epoch, deviceId}]}`: live member devices with no usable
  wrap for an epoch that **your** device holds a wrap for. A wrap made by a device of someone who left,
  or by a revoked device, isn't usable and may be replaced by `PUT /keys/wraps`.

### Accepting a wrap (client rule)
Accept a wrap only if `wrapperDeviceId` is a **live** (not revoked) device whose cert verifies against
its user's identity key, that user is a current member of the chat, and the wrap's signature verifies with that device's
`signPub` over `"famchat-wrap-v1" ‖ str(chatId) ‖ u32(epoch) ‖ str(recipientDeviceId) ‖ str(wrapperDeviceId) ‖ sealed`.

Wraps from a revoked wrapper are refused even if they were made before the revocation: the client
can't tell when a wrap was signed, and a revoked device's sign key may be in someone else's hands
(with the server's help they could otherwise hand out a chat key of their choosing). The server counts
such wraps as missing, so any live member device holding the key re-wraps it. The cost: if every live
device that held an epoch's key is gone, a device that hadn't opened its wrap yet loses that epoch.

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
| `{type:"device", userId, deviceId, revoked?}` | a device of a user you share a chat with (or your own) was added or revoked: `GET /users`, then (if added) `GET /keys/missing` and add wraps |
| `{type:"media_expired", chatId, keys:[...]}` | those media keys were evicted; show "media expired" |
| `{type:"reset", userId, resetId}` | an account was reset, claimed or recovered (to everyone): `GET /users` and check it |
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
- Admin reset (plan 10) reuses plan 6: revoking the user's devices rotates every chat, and the
  `device` event plus missing-wrap repair restores history to the new device ("Account resets").

## Signed and derived byte strings
Every signature, MAC and key derivation starts with its own domain string, and no domain string is a
prefix of another: `famchat-device-cert-v1`, `famchat-wrap-v1`, `famchat-envelope-v1`,
`famchat-sealed-box-v1` (HKDF info), `famchat-pair-keys-v1` (HMAC), `famchat-pair-bundle-v1` (HKDF info),
`famchat-media-v1` (media AEAD associated data), `famchat-reset-v1`, `famchat-reset-claim-v1`,
`famchat-recovery-key-v1`, `famchat-admin-v1` (signatures), `famchat-recovery-seed-v1` (HKDF info).
