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
`{"kind":"text","text":"..."}` or `{"kind":"reaction","target":"<messageId>","emoji":"👍"}`
(`"emoji":""` removes your reaction; the latest reaction per user and target wins). Later plans add
`photo` and `voice`; clients show unknown kinds as unsupported rather than failing.

## REST

### Auth and devices (plans 1 and 4)
- `POST /auth/invite/redeem`, `POST /auth/refresh`, `GET /me`, `GET /devices`, `POST /admin/invites`,
  `POST /admin/bootstrap`.
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
   → 404; expired, cancelled or too late → 410 `pairing_invalid`.
6. `POST /devices/pair/cancel {sessionId, secret}` → 204 (N gave up).

Bundle: `sealed = ephPubE(32) ‖ nonce(24) ‖ ct ‖ mac(16)`, XChaCha20-Poly1305 with key
`HKDF-SHA256(ikm = X25519(ephE, ephPubN) ‖ UTF-8(S), salt = ephPubE ‖ ephPubN, info = "famchat-pair-bundle-v1")`.
Plaintext is UTF-8 JSON:
`{v: 1, userId, deviceId, identitySeed, certSig, keys: [{chatId, epoch, key}], trust: [{userId, trustedIdentityPub, known: [identityPub]}]}`.
N accepts it only if it opens, `certSig` verifies over N's own keys with the identity key derived from
`identitySeed`, and `userId`/`deviceId` equal the claim's. `keys` are every chat key E holds, so N reads
the history at once; `trust` is E's trust-on-first-use state for other users, so N starts with it instead
of whatever the server shows. Member devices also add wraps for N on the `device` event.

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

### Keys
- `GET /keys/wraps[?chatId=]` → `{wraps: Wrap[]}` addressed to your device, for chats you're in.
- `PUT /keys/wraps {wraps}` → `{added}`. Missing-wrap repair: each wrap's `wrapperDeviceId` is your
  device, its epoch exists, and its recipient is a live device of a current member. Existing wraps are
  never replaced (first wrap wins).
- `GET /keys/missing` → `{missing: [{chatId, epoch, deviceId}]}`: live member devices with no usable
  wrap for an epoch that **your** device holds a wrap for. A wrap made by a device of someone who left,
  or by a revoked device, isn't usable and may be replaced by `PUT /keys/wraps`.

### Accepting a wrap (client rule)
Accept a wrap only if `wrapperDeviceId` is a **live** (not revoked) device whose cert verifies against
its user's identity key, that user is a current member of the chat, and the wrap's signature verifies with that device's
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
| `{type:"device", userId, deviceId, revoked?}` | a device of a user you share a chat with (or your own) was added or revoked: `GET /users`, then (if added) `GET /keys/missing` and add wraps |
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
- Admin reset (plan 10) can reuse plan 6: revoking the user's devices already rotates every chat, and
  the `device` event plus missing-wrap repair restores history to the new device.

## Signed and derived byte strings
Every signature, MAC and key derivation starts with its own domain string, and no domain string is a
prefix of another: `famchat-device-cert-v1`, `famchat-wrap-v1`, `famchat-envelope-v1`,
`famchat-sealed-box-v1` (HKDF info), `famchat-pair-keys-v1` (HMAC), `famchat-pair-bundle-v1` (HKDF info).
