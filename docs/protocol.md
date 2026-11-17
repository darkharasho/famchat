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
  | `last_admin` | 409 | the only admin can't delete their account, or leave a family, while anyone else is in it |
| `admin_invite` | 409 | `POST /families/:id/join` with an invite that makes its holder an admin; it is meant for a new person, so it is not used up |
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
             devices: Device[], resets: Reset[], deleted}                 ("Deleting an account")
Reset     = {id, signerUserId, signerKind: "admin"|"recovery", signerPub, recoverySig: string|null,
             oldIdentityPub, claimPub, createdAt, sig, newIdentityPub: string|null,
             claimSig: string|null, completedAt: number|null}            ("Account resets")
Device    = {id, name, platform, encPub, signPub, certSig, revoked}
Chat      = {id, kind: "direct"|"group", title: string|null, createdBy, currentEpoch, epochReady,
             lastSeq, lastMessageAt: number|null, createdAt, mutedUntil: number|null, members: Member[]}
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

A voice message (plan 8) is one blob, an AAC-LC `.m4a` (about 48 kbps mono):

```
{"kind":"voice", "mediaKey",                  media key of the clip
 "key", "sha256",                             b64url 32-byte media key; SHA-256 of the encrypted blob
 "durationMs",                                1..900000 accepted (senders stop at 600000, 10 minutes)
 "waveform",                                  b64url of 0–128 peak bytes (0–255), oldest first; senders send 64
 "bytes", "mime":"audio/mp4"}                 size of the .m4a

{"kind":"video", "mediaKey",                  media key of the MP4
 "key", "sha256",                             b64url 32-byte media key; SHA-256 of the encrypted blob
 "thumbKey"?, "thumbSha256"?,                 a JPEG poster frame (both or neither), under the same key
 "width", "height",                           display size in pixels (after rotation)
 "durationMs",                                1..3600000
 "bytes", "mime":"video/mp4"}                 size of the file (phones compress to 720p first)
```

A text, GIF, photo, voice or video message may say `"forwarded": true`: a copy of a message from another chat. Media blobs are
uploaded again under a new media key (media access follows the chat), so the copy stands alone.

A text may reply to an earlier message: `{"kind":"text","text":"...","replyTo":"<messageId>"}`
(clients that don't know `replyTo` just show the text).

In a group, a text may @mention members: `{"kind":"text","text":"@Mom can you?","mentions":["<userId>"]}`.
The text holds `@<name>`; `mentions` lists who that is. The `send` frame repeats the list (the server
can't read the text) so mentioned members are pushed even when they muted the chat.

Edits and deletes are messages too, and count only when their sender is the target's sender:

```
{"kind":"edit", "target":"<messageId>", "text":"..."}   new text for one of your text messages; the latest edit wins
{"kind":"delete", "target":"<messageId>"}               unsend one of your messages; later edits are ignored
```

A deleted message shows as "This message was deleted" and loses its reactions; replies quote it as
"Deleted message". Neither changes nor deleted messages count as unread, and changes don't move the
chat's `lastMessageAt`.
Reactions, edits and deletes are sent with `silent: true` (see `send`), so they don't notify anyone.

### Link previews
A text may carry a card for its first link, made by the sender:
`{"kind":"text", "text":"look https://…", "preview": {"url", "title", "description"?, "siteName"?,
"image"?: {"mediaKey", "key", "sha256", "width", "height"}}}`. The image is one encrypted `thumb`
blob (its own media key, purpose `thumb`), uploaded before the message is sent, so receivers never
contact the site. A preview that doesn't check out is dropped and the text shows as usual.

- `GET /preview?url=` → `{url, title, description?, siteName?, image? (base64, ≤ 2 MiB), imageType?}`,
  or 404 when there's nothing to show. The app asks while a link is being typed. YouTube links use
  YouTube's oEmbed endpoint; other pages their Open Graph tags (Amazon: its product image).
  Only public http(s) hosts (no loopback, private or bare names); answers are cached for a day.
  The server sees the URL, never the message.

### GIFs
`{"kind":"gif", "slug", "title", "url", "width", "height"}`: a GIF from KLIPY. KLIPY's terms require
apps to call its API and load its media directly (no proxying or re-hosting), so the app searches
`https://api.klipy.com/api/v1/<key>/gifs/{trending,search}` itself (with `customer_id` = a hash of the
user id) and receivers load `url` from KLIPY. Receivers accept only `https` URLs on `klipy.com` or its
subdomains. `GET /me` returns `gifKey` (the Worker's `KLIPY_APP_KEY` secret, or null: no GIF button).

Clients keep unknown kinds (whole body) and show them as unsupported.

### Media blobs
Each blob is `nonce(24) ‖ ct ‖ mac(16)`, XChaCha20-Poly1305 under the message's media key with
`aad = "famchat-media-v1" ‖ str(purpose)`, purpose `"file"` (full photo, voice clip) or `"thumb"`.
Photos are re-encoded as JPEG at most 2048 px on the long side (EXIF dropped); thumbnails at most
320 px. Before decrypting, check the blob's SHA-256 against the message.

## REST

### Auth and devices (plans 1 and 4)
- `POST /auth/invite/redeem`, `POST /auth/refresh`, `GET /me`, `GET /devices`, `POST /admin/invites`,
  `POST /admin/bootstrap`. Redeeming a reset link also needs `resetClaimSig` ("Account resets").
- `GET /me` → `{userId, deviceId, name, isAdmin, recoveryCodeSet, reviewer}`; `recoveryCodeSet` says an
  admin recovery key is registered; `reviewer` marks a reviewer account ("Reviewer accounts").
  Redeeming answers `{userId, deviceId, isAdmin, reviewer, accessToken, refreshToken}`.
- Admin routes check admin of family #1 in `family_members` (not `users.is_admin`, which is only a
  mirror), so a promotion counts at once. `POST /admin/users/:id/admin` writes the proof into family
  #1's row and mirrors `users` in one batch; the target must be a live member of family #1, else 404.
  Reviewer accounts get 403 from every admin route.
- The operator (`users.operator = 1`, set by hand or by redeeming a bootstrap invite) holds the
  account-wide powers: `DELETE /admin/users/:id` and the three reviewer endpoints are operator-only
  (403 for anyone else, family admins included). `POST /admin/recovery-key` takes an admin of any
  non-hidden family. `POST /admin/users/:id/reset` takes an admin of any family (403
  otherwise) and needs a family that is `approved`, where the caller is admin and the target a member
  (else 404); the lowest such family id authorizes the reset.
- Redeeming an invite joins the invite's family (`invites.family_id`: family #1 for admin and
  bootstrap invites, the hidden reviewer family for reviewer invites), as admin when `make_admin`.
  The recovery redeem accepts an admin of any non-hidden family.
- Bootstrap and the operator: `POST /admin/bootstrap` gives 409 `already_bootstrapped` while family
  #1 has a live member or a live operator exists. Redeeming a bootstrap invite (no creator) sets
  `users.operator = 1` and fills family #1's `created_by`. Deleting the operator's account clears
  the flag; no successor is chosen automatically (set `operator` by hand in D1).
- `DELETE /devices/:id` → 204 (your own live device, else 404). Closes that device's WebSocket (code
  4001) and, in the same transaction, moves **every chat of your user** to `currentEpoch + 1` with
  `epochReady: false`; members get `chat {chatId}` per chat and `device {userId, deviceId, revoked: true}`.
  The first member device to react creates the new epoch (`POST /chats/:id/epochs`) without the
  revoked device, exactly as after a leave.

### Push (plan 9)
- `PUT /devices/me/push {token: string | null, previews?: boolean}` → 204: this device's FCM token
  (1–4096 chars), or null to stop pushes. The token is removed from any other device row that had it.
  `previews` (optional boolean, else 400 `invalid_request`) opts this device into message previews
  (`devices.push_previews`): omitted keeps the stored value, and it resets to false whenever the token
  is cleared (null, revoke, sign-out, account reset/delete, stale token) or taken by another device.
  Android, iOS and web register one; desktop apps don't (they notify from the socket).
- `POST /devices/me/push/test` → `{configured, error?, devices: [{id, name, result}]}`: sends "FamChat" /
  "Test notification" to the caller's own devices that have a token, right away. `result` is `ok`,
  `stale` (token cleared), `retry`, `auth` or `error`. `configured: false` means the Worker has no
  `FCM_SERVICE_ACCOUNT` secret, so push is off.
- A push has one of two shapes, chosen per device. Either way the title and body are generic: direct
  chat title = sender's name, body "New message"; group title = group title, body "New message from
  <sender>" ("<sender> mentioned you" for those @mentioned). Tapping it opens `/chats/<chatId>`
  (web: `fcm_options.link`).
  - Plain (previews off, or no envelope on the job): `notification {title, body}` and `data {chatId}`.
    Never message content.
  - Preview (`devices.push_previews = 1` and the envelope was attached): no top-level `notification`.
    `data` holds string values `chatId`, `messageId`, `senderUserId`, `senderDeviceId`, `epoch`,
    `env` (the stored envelope JSON, still encrypted), `title`, `body` and `preview: "1"`. Android
    gets `priority: high` and no notification block; iOS gets `aps.alert {title, body}`,
    `mutable-content: 1`, sound and `thread-id`. The app decrypts `env` and shows the text itself,
    falling back to `title`/`body`. The server never sees readable text.
  - The envelope is attached only when its JSON is at most 3000 bytes (`MAX_PREVIEW_ENVELOPE`);
    larger ones go as the plain shape. A retry after a transient FCM failure keeps the envelope.
- Who gets one: every device of the other members (except those who muted the chat and weren't
  @mentioned, and none at all for a `silent` send) that has a token and **no open socket** when the
  message is stored (a phone is pushed even while the same user's desktop is connected). Sockets that
  answered no ping for 90 s are closed first (code 4002).
  Mobile apps close their socket when sent to the background.

### Pairing a new device (plan 6)
A new device N signs in by being approved from a signed-in device E of the same user. The server only
relays: it can't read the bundle, and can't swap N's keys or forge a bundle without the secret `S`,
which never leaves the two devices.

1. N makes an ephemeral X25519 key `eph`, its device keys, and `S` (12 Crockford base32 characters,
   60 bits). `POST /devices/pair/start` (no auth)
   `{ephPub, encPub, signPub, keysMac, deviceName (1–60), platform, offer?}` →
   `201 {sessionId, code, secret, deviceId, expiresAt, expiresIn}`.
   `keysMac = HMAC-SHA256(key = UTF-8(S), "famchat-pair-keys-v1" ‖ ephPub ‖ encPub ‖ signPub ‖ str(deviceName) ‖ str(platform))`.
   `code` is a 4-character lookup code; `secret` is N's claim secret (not `S`). At most 5 starts per
   client IP per 10 minutes and 1000 open sessions overall (`rate_limited`). A session can be approved
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

Reverse direction (E shows the code, N scans it; e.g. a desktop without a camera and a new phone). Same
`S`, MAC, approval, bundle and claim; only who shows the code changes:

1. E: `POST /devices/pair/offer` (authed) → `201 {offerId, code, expiresAt, expiresIn}`. E makes `S`
   itself and shows `code ‖ S` as `XXXX-XXXX-XXXX-XXXX` and a QR with `famchat-link:1:<code ‖ S, 16 chars>`.
   An offer can be taken for 5 minutes, once. At most 5 offers per user per 10 minutes (`rate_limited`).
2. N scans (or types) it and starts as in step 1 above with `S` from the code and `offer: code`
   (4 characters, else 400). The session is bound to the offer's user: only that user's devices can look
   it up or approve it (404 for anyone else). An unknown, expired, cancelled or already taken offer →
   404; such a try still counts toward the per-network start limit, so offer codes can't be guessed
   faster than sessions can be started. N then polls `claim` as usual; it shows no code of its own.
3. E polls `GET /devices/pair/offer/:offerId` (authed, own offers only, else 404) every ~2 s →
   `{status: "waiting", expiresAt}` until N takes it, then
   `{status: "ready", session: {code, deviceId, ephPub, encPub, signPub, keysMac, deviceName, platform, expiresAt}}`
   (as from `GET /devices/pair/:code`), and `{status: "approved"}` once approved. Expired or cancelled
   offer, or N's session cancelled or expired → 410 `pairing_invalid`.
4. E checks `keysMac` with its own `S`, shows the device name and platform for confirmation, and
   approves with `POST /devices/pair/<session.code>/approve` exactly as in step 4 above.
5. `POST /devices/pair/offer/:offerId/cancel` (authed, own offers only) → 204: withdraws the offer and
   cancels N's session if it took the offer and isn't approved yet.

The server learns `code` but never `S`: a server (or a guesser) that swaps in its own session can't make
a `keysMac` that E accepts, and can't open or forge the bundle, as in the forward direction.

Bundle: `sealed = ephPubE(32) ‖ nonce(24) ‖ ct ‖ mac(16)`, XChaCha20-Poly1305 with key
`HKDF-SHA256(ikm = X25519(ephE, ephPubN) ‖ UTF-8(S), salt = ephPubE ‖ ephPubN, info = "famchat-pair-bundle-v1")`.
Plaintext is UTF-8 JSON:
`{v: 1, userId, deviceId, identitySeed, certSig, keys: [{chatId, epoch, key}], trust: [{userId, trustedIdentityPub, known: [identityPub], admin?}], familyAdmins?: {"<familyId>": [userId]}}`.
`familyAdmins` holds E's admin pins: for each family E has seen, the users E trusts as its admins
("Account resets"). `admin` is for receivers that predate `familyAdmins`: true if E has pinned the
user in family 1, false if not, and absent (null) if E has never seen family 1. N takes its pins
from `familyAdmins` if it is present. Otherwise, if any `admin` is set, family 1's pins are the users
with `admin: true`. With neither, N pins nothing and sees each family for the first time at its
first directory refresh.
N accepts it only if it opens, `certSig` verifies over N's own keys with the identity key derived from
`identitySeed`, and `userId`/`deviceId` equal the claim's. `keys` are every chat key E holds, so N reads
the history at once; `trust` is E's trust-on-first-use state for other users, so N starts with it instead
of whatever the server shows. Member devices also add wraps for N on the `device` event.

### Families
All `/families` routes need auth and return `403 forbidden` to reviewers. The hidden reviewer family
never appears: it is `404 not_found` everywhere. Names are trimmed, 1-40 characters
(`400 invalid_request` otherwise). The owner of a family is its creator.
- `GET /families` → `{families: Family[]}`: the caller's own families, ordered by id.
  `Family` = `{id, name, status: "pending"|"approved"|"declined", role: "admin"|"member",
  memberCount, owner: boolean, ownerId: string | null, createdAt}`. `memberCount` counts live (not
  deleted) members. `owner` is whether the caller owns it; `ownerId` is the owner's user id (null
  when the family has no owner), so members can tell who it is.
- `POST /families {name}` → `201 {family: Family}`: requests a new family. It starts `pending`, with
  the caller as its admin (no admin proof). At most 3 pending requests per creator, else
  `429 rate_limited`.
- `PUT /families/:id {name}` → `204`: renames. Allowed for an admin of an approved family, and for
  the creator of their own pending or declined family (a pending or declined family has no other
  admin power). Others get `403 forbidden`. Members get a `family` event.
- `POST /families/:id/invites {name}` → `201 {inviteToken, inviteUrl, expiresAt}`: a member invite
  (`/join#<token>`, 7 days) for family `:id`. Admin of an approved family only, else `403 forbidden`.
  An `email` field is `400 invalid_request` for now.
- `POST /families/invite-lookup {inviteToken}` → `{familyId, familyName, invitedName, alreadyMember}`
  for an invite that is unused, unexpired, not revoked, not a reset or reviewer invite, and for an
  approved family. Anything else is `410 invite_invalid`.
- `POST /families/:id/join {inviteToken}` → `200 {family: Family}`: joins `:id` as a member with the
  caller's existing account and uses up the invite. `410 invite_invalid` if the invite is unusable or
  is for another family; `409 conflict` if the caller is already a member and `409 admin_invite` if the
  invite makes its holder an admin (in both cases the invite stays usable).
  Members get a `family` event.
- Signed-out `POST /auth/invite/redeem` of a family invite joins that family, and is `410` if the
  family is not approved.
- `POST /families/:id/admins/:userId`: promotes a member (see "Account resets", line 431); also reviewer-blocked.
- `DELETE /families/:id/admins/:userId` → `204`: demotes an admin of `:id` to member and clears their
  admin proof (family #1 also clears `isAdmin` and the proof on `users`). Only the owner, while the family
  is approved; anyone else `403 forbidden`. The owner can't be demoted (`403`); a target who isn't an
  admin of `:id` is `404 not_found`. Members get a `family` event.
- `DELETE /families/:id/members/:userId` → `204`: takes someone out of family `:id`.
  - Yourself (leaving): allowed in any family you're in, pending and declined ones too (that's how a
    creator dismisses a declined request). The family's last admin gets
    `409 {error: "last_admin", familyId, familyName}` while any other live member is left (make
    someone else an admin first). Not a member: `404`.
  - Someone else: the caller must be an admin of the approved family, else `403 forbidden`. Admins and
    the owner can't be removed (`403`); a target outside the family is `404 not_found`.
  - In one transaction the person leaves every group chat of that family they're in, exactly like
    `DELETE /chats/:id/members/:userId` (new epoch, kept as a leaver); chats of their other families
    and direct chats stay (a direct chat with someone they no longer share a family with becomes
    read-only: sends get `no_shared_family`). Family #1 also clears their `isAdmin` and proof on `users`.
  - Afterwards: `removed {chatId}` to them and `chat {chatId}` to the rest, per chat; a `family` event to
    the family's members and to them.
- Ownership: when the owner leaves (or deletes their account), the family passes to its
  longest-serving other live admin (earliest `joined_at`, then user id); with none left it has no owner.

### Operator: family requests
Operator-only (`403 forbidden` for everyone else, reviewers included). The hidden reviewer family never
appears and is `404 not_found`.
- `GET /operator/families?status=pending|approved|declined` (default `pending`; other values `400`) →
  `{families: [{id, name, status, createdAt, decidedAt, creator: {id, name} | null, memberCount}]}`, newest first.
- `POST /operator/families/:id/approve` and `POST /operator/families/:id/decline` → `204`. Only a
  `pending` family can be decided, else `409 conflict`. Records `decided_at` / `decided_by`, logs
  `family_approved` / `family_declined`, and sends the family's members a `family` event.

### Directory
- `GET /users` → `{users: User[]}`: the caller, everyone who shares a family with them, and "former"
  chat partners (below). Nobody else is ever listed. Every device is included, revoked ones too
  (`revoked: true`) so old signatures still verify. Wrap only for devices with `revoked: false`.
  `resets` is the user's signed reset history, oldest first: their past identity keys, which clients
  accept only through resets they verify ("Account resets"). A deleted account stays listed to the
  people who shared a family with it, with `deleted: true`, name `"Deleted user"` and every device
  revoked; don't offer it for new chats. `avatarKey` names the user's profile photo, or is null.
- `families: {id, role: "admin"|"member", adminProof: {byUserId, signerPub, sig} | null}[]` lists
  only the families that user shares with the caller (a person's other families are never shown).
  `adminProof` is set for admins who have a signed proof. Reviewers see the hidden reviewer family
  in their own and other reviewers' lists.
- `isAdmin` and `adminProof` describe family #1 only, and only when the caller is in family #1 too;
  otherwise `false`/`null`, so family #1's roles don't leak to outsiders.
- `former: true` marks people the caller shares a chat with (including a read-only direct chat or a
  group they left, recorded in `chat_leavers`) but no family. They're listed so history still
  verifies on a new or reset device, with the normal shape but `isAdmin: false`, `adminProof: null`
  and `families: []`. They get no presence, typing or `profile` events and are never offered in
  pickers. Every other entry has `former: false`.
- `GET /me` also returns `operator: boolean`; its `isAdmin` means admin of family #1.

### Profile: name and photo
Not end-to-end encrypted, like names: the server and everyone in the user's directory (family
peers and former chat partners) can see them.

- `PUT /me/avatar` with a JPEG as the raw body (`content-type: image/jpeg`, at most 256 KiB; the app
  sends 512×512) → `{avatarKey}`. Each photo gets a new key; the previous one is deleted.
- `DELETE /me/avatar` → 204.
- `GET /users/:id/avatar?v=<avatarKey>` → the JPEG, cacheable for good (`immutable`); 404 once
  replaced. Without `v`: the current one, not cached. Only people in the caller's own directory
  (themselves, family peers, former chat partners) can be fetched; anyone else gets 404.
- `PUT /me/name {name}` → 204: renames the caller (trimmed, 1–40 characters, no control characters).
- Any of these sends `{type:"profile", userId}` to everyone who shares a family with the user (not
  former chat partners): `GET /users` again.
  Deleting an account deletes its photo.

### Deleting an account
Required by app stores for apps with accounts. Two ways in, one transaction:

- `DELETE /me {confirm: "delete"}` → 204: the caller deletes their own account. Any other body → 400.
  The only admin of a family gets `409 {error: "last_admin", familyId, familyName}` (the first such
  family) while any other live member of it is left (make someone else an admin first; deleted members
  don't count); the last person in the family may delete their account, after which `POST /admin/bootstrap`
  works again.
- `DELETE /admin/users/:id` (operator only) → 204: removes another account the same way (a deletion request, or
  someone who left the family). Yourself → 400 (use `DELETE /me`); unknown or already deleted → 404.

What happens, atomically:
- **Deleted:** every message the user sent (ciphertext rows: their texts, photos, voice messages and
  reactions, so `seq` gaps appear in history), every media object they uploaded (R2 object and row,
  live or expired), every chat-key wrap addressed to their devices, their WebSocket tickets.
- **Revoked:** every device (refresh tokens and push tokens cleared, sockets closed with 4001, unclaimed
  pairings cancelled); device names become `"Deleted device"`.
- **Left:** every chat they were in, direct ones included. Each chat moves to `currentEpoch + 1` with
  `epochReady: false`, exactly as after a leave, and the remaining members create the new epoch
  without them. A direct chat stays with its one remaining member (clients title it "Deleted user").
- **Anonymized, kept:** the `users` row (name `"Deleted user"`, admin flag, admin proof and recovery
  key and `operator` flag cleared, `deleted_at` set). Its `family_members` rows stay, as `member` with
  the admin proof cleared, so the directory still resolves them. Its id and identity key stay because devices, chats, resets and the
  audit log reference them and other members' devices still verify old certificates and resets with
  them. Invites made out to them are renamed; their unused reset links and the invites they made expire.
- **Passed on:** each family they own goes to its longest-serving other live admin, or to no owner
  ("Families"); its members get a `family` event.
- **Logged:** an `events` row `account_deleted {by: "self"|"admin"}` with the user id and who did it.

Afterwards members get `chat {chatId}` per chat, `device {revoked: true}` per device,
`media_expired {chatId, keys}` for their media, and everyone who shared a family with them gets `account_deleted {userId}`.
Messages are end-to-end encrypted, so the server can't reach copies other members' devices already
downloaded and decrypted; those stay on those devices until deleted there. A deleted user can't be
reset, promoted, or added to a chat; their account can't be restored.

### Reviewer accounts
App-store review needs sign-in details for an app nobody can sign up to. Reviewers get accounts of
their own, walled off from the family in both directions: reviewers are the members of the hidden
family #2, and nothing reads `users.reviewer` (a mirror write only). Every isolation rule below is
the ordinary family rule; the 256 MiB media cap is the one reviewer-specific limit.

- `POST /admin/reviewer-invite` (operator) → `201 {inviteToken, inviteUrl, createdAt}`. The link is
  `<origin>/join#review.<token>`; the `review.` marker (never sent to the server) tells the app to ask
  the joiner for a display name. Reusable: any number of redemptions, no expiry. At most one is
  active: creating one revokes the previous one. The server keeps its raw token so admins can show
  the link again. It also stops working if the admin who made it is deleted.
- `DELETE /admin/reviewer-invite` (operator) → 204: revokes it (redeeming → `410 invite_invalid`).
  Reviewer accounts already made stay until removed with `DELETE /admin/users/:id`.
- `GET /admin/reviewers` (operator) → `{invite: {inviteUrl, createdAt} | null, users: [{id, name,
  createdAt, devices}]}`: the active invite and the live reviewer accounts (`devices`: live count).
- Redeeming it: `POST /auth/invite/redeem` with `name` (1–40) as well → a new reviewer account each
  time (`reviewer: true`, never admin). A retry with the same keys within 10 minutes returns the same
  account. `name` is ignored for other invites.

Isolation, enforced by the server:
- `GET /users` lists only users on the caller's side: the family sees no reviewers; a reviewer sees
  only reviewer accounts (themselves included), with their devices and resets.
- `POST /chats` and `POST /chats/:id/members` accept only users on the caller's side (else 400).
- Reviewers are in the hidden reviewer family only, so presence (`hello`, `presence`), `typing`,
  `profile`, `account_deleted` and `reset`, which go only to people sharing a family ("Hub → client"),
  never cross; chat events follow chat membership, which never mixes the two.
- Reviewers can't be promoted or reset (404); they don't count as family for the last-admin rule or
  for `POST /admin/bootstrap`.
- All reviewer accounts together may hold at most 256 MiB of live media (`413 too_large`), so their
  uploads can never push the family's media over the cap and evict family photos.
- A lone reviewer tries the app in a group with only themselves (`userIds: []`, "Note to self"),
  which the new-chat screen offers when there is nobody else to pick.

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
   `201 {resetId, familyId, inviteToken, inviteUrl, expiresAt}`; `familyId` is the family whose admin authorized the reset (also in the `reset` audit event payload). The server checks the signature against the
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
   - **Trusted admins** are kept per family, only for the families the device's own user is in. The
     server's `isAdmin` and `families[].role` alone carry no authority. When a device first sees a
     family (one it has no pins for), it pins the admins the server lists for that family (trust on
     first use). A paired device takes the approving device's pins from the handover bundle. After
     that, the device adds an admin to a family only if their `families[].adminProof` is a valid
     promotion for that family: a v2 proof, or a v1 proof in family 1 only. The proof must be signed
     with the current key of a trusted admin of that family. An admin the server stops listing for a
     family is unpinned there, and needs a fresh proof to be trusted again: the device records the
     `sig` of the valid proof it last saw for them in that family as revoked (and, while they stay
     pinned, any earlier proof a different one replaces), and a revoked `(familyId, userId, sig)`
     never adds that admin again. Ed25519 signatures are deterministic, so the same promoter
     promoting them again makes the same, revoked proof: on a device that saw the demotion they stay
     untrusted (fails safe: their resets get banners only); a proof from a different trusted admin
     trusts them again. Revoked proofs aren't part of the pairing handover. Only proofs this device has seen are revoked: a
     proof it never saw can still re-trust a demoted admin, whether it predates the device's first
     sight of them, comes from another signer, is on a device upgraded from schema 8, or is on a newly
     paired device. Closing that needs a protocol change, such as a counter in the promotion statement,
     which is planned for later. A family the device has
     seen keeps its pins frozen when the server stops listing it (the user left, or the server
     omits it or the user's whole entry): they don't count meanwhile, and if the family is listed
     again they are the starting point, so only never-seen families are trusted on first sight.
     The device's own user always counts. A device upgraded from one-family pinning keeps its
     pinned admins as family 1's.
   - The statement must verify under `signerPub`. Kind `admin`: the signer is a trusted admin, other
     than the user, of a family that the user and this device's user are both in. For history only,
     a former user (no shared family) also accepts a trusted admin of any of this device's families. Kind `recovery`: `recoverySig` verifies the recovery key under `oldIdentityPub`,
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

Per-family promotion: `POST /families/:id/admins/:userId {sig}` (caller an admin of approved family
`:id`) → 204 (400 `invalid_request` bad signature, 403 `forbidden` caller not an admin of `:id` or
`:id` not approved, 404 `not_found` target not a live member of `:id`). It writes the proof on the
target's `family_members` row (`role`, `admin_by`, `admin_signer_pub`, `admin_sig`); for family 1 it
also mirrors it into the `users` columns. Logs `admin_promoted` with `payload {familyId}`. `sig` is the
caller's identity key over the **v2** proof `"famchat-admin-v2" ‖ str(String(familyId)) ‖ str(userId) ‖
str(callerId)` (`str` = u16 big-endian length + UTF-8; the family id is its decimal string). v2
binds the family so a proof can't be replayed into another family; a v1 proof is rejected here, and
the compat route above (family 1 only) keeps accepting v1. Shared test vector:
`server/test/reset-vector.test.ts` (`v2Vector`).

Admin recovery code: the admin's device makes a 25-character Crockford base32 code (125 bits, shown
as `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`), derives an Ed25519 **recovery key** from seed
`HKDF-SHA256(UTF-8(code), salt = "", info = "famchat-recovery-seed-v1")`, and registers
`POST /admin/recovery-key {recoveryPub, sig}` (admin of any non-hidden family; `sig` = identity key over the registration) →
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

Every reset, recovery, promotion, recovery-key change, join, pairing, revocation and account deletion
writes an `events` row (audit log; not exposed by the API yet).

### Chats
- `GET /chats` → `{chats: Chat[]}` (yours, newest activity first). `GET /chats/:id` → `{chat}`.
- `POST /chats` → `201 {chat, created: true}` or `200 {chat, created: false}`.
  - Direct: `{id, kind: "direct", userId, wraps}`. At most one per pair: if it exists, you get it back
    (your wraps are ignored), even if the two no longer share a family. Otherwise the other user must be
    live (`invalid_request`) and share a family with you (`403 no_shared_family`).
  - Group: `{id, kind: "group", title (1–60), userIds (others, 0–100; none = a chat with only yourself), familyId?, wraps}`.
    `familyId` is an integer naming an approved family you are in; you and everyone in `userIds` must be
    live members of it, else `400 invalid_request`. Without it the server uses your only family; if you
    have several, family #1 when you're in it, otherwise `400`. A reviewer's group lands in the hidden
    reviewer family.
  - `Chat.familyId`: the group's family id, `null` for direct chats.
  - `wraps`: epoch 1, exactly one per live device of every member (you included), all with
    `wrapperDeviceId` = your device. Re-posting an id you created returns it.
- `POST /chats/:id/members {userIds, wraps}` → `{chat}`. Groups only. Wraps for the **current** epoch
  must cover every live device of the new users; wraps for older epochs (so they can read history) may
  be included. New members' `joinedSeq` is the chat's `lastSeq`. Fails with `stale_epoch` while the
  current epoch isn't created yet.
  Adding someone to a **direct** chat isn't allowed: clients create a new group instead. New members must
  be live members of the group's `familyId` (`400 invalid_request` otherwise).
- `DELETE /chats/:id/members/:userId` → 204. Groups only. Yourself = leave; someone else = remove
  (creator only). Either moves the chat to `currentEpoch + 1` with `epochReady: false`. The server
  records the person in `chat_leavers`, which keeps the leaver visible as `former` to the group's
  remaining members.
- `PUT /chats/:id/mute {until: number|null}` → 204. Your own mute: no pushes from this chat until
  `until` (Unix ms, 0 to 253402300799000; "until I turn it back on" is a far-off time), or `null` to
  unmute. Shown only to you as the chat's `mutedUntil`; your own sockets get a `chat` event.
- `POST /chats/:id/epochs {epoch, wraps}` → `201 {chat}`. Creates the current epoch's key: `epoch` must
  equal `currentEpoch` and wraps must cover exactly the live devices of current members. The first
  member device wins; the rest get `epoch_exists` and fetch the wraps instead.
- `GET /chats/:id/messages?after=N` (ascending, seq > N) or `?before=N` (the latest `limit` rows with
  seq < N, returned ascending); `limit` 1–200, default 100 → `{messages: Message[]}`.

### Media
- `POST /media?chatId=&key=&kind=&messageId=` with the encrypted blob as the raw body
  (`Content-Length` required) → `201 {key, bytes}`. `key` (the object's id) and `messageId` (the
  message that will reference it) are ULIDs made by the client; `kind` is `photo`, `thumb`, `voice` or `video`
  with caps 15 MiB, 1 MiB, 8 MiB and 64 MiB (`too_large`). You must be a member of `chatId` (`not_found`).
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
| `{type:"send", id, chatId, envelope, silent?, mentions?}` | store and fan out a message (below); `silent: true` pushes no one and marks the `msg` frames; `mentions` (≤ 50 user ids) are pushed through a mute |
| `{type:"typing", chatId}` | relayed to the sockets of the other members who share a family with you; send at most every 3 s while typing |
| `{type:"read", chatId, seq}` | sets your `lastReadSeq` (never backwards, capped at `lastSeq`) |
| `{type:"ping"}` | answered `{type:"pong"}` without waking the hub; send every ~25 s |

### Hub → client
Presence (`hello`, `presence`), `typing`, `profile`, `reset` and `account_deleted` reach only people
who share a family with the user they're about; `device` reaches only chat partners who also share
one. "Former" chat partners get none of these. Chat events (`msg`, `read`, `chat`, `removed`,
`keys`, `media_expired`) follow chat membership.

| frame | when |
|---|---|
| `{type:"hello", online:[userId]}` | right after connecting: who is online among the people sharing a family with you |
| `{type:"presence", userId, online}` | a user sharing a family with you: their first socket opened / last socket closed |
| `{type:"ack", id, seq, createdAt}` | your `send` was stored (or had been stored before) |
| `{type:"error", id?, error}` | `invalid_request`, `not_member`, `stale_epoch`, `conflict`, `internal` |
| `{type:"msg", message: Message, silent?, mentions?}` | a new message in one of your chats (not echoed to the sending socket); `silent: true` means don't notify; `mentions`: members @mentioned (notify them even if muted) |
| `{type:"typing", chatId, userId}` | another member who shares a family with you is typing; show for ~5 s |
| `{type:"read", chatId, userId, seq}` | a member's (or your own other device's) read position moved |
| `{type:"chat", chatId}` | chat created or changed (members, epoch): `GET /chats/:id` |
| `{type:"removed", chatId}` | you left or were removed |
| `{type:"keys", chatId, epoch?}` | new wraps may be waiting: `GET /keys/wraps?chatId=` |
| `{type:"device", userId, deviceId, revoked?}` | a device of a user you share a chat and a family with (or your own) was added or revoked: `GET /users`, then (if added) `GET /keys/missing` and add wraps |
| `{type:"media_expired", chatId, keys:[...]}` | those media keys were evicted; show "media expired" |
| `{type:"reset", userId, resetId}` | an account was reset, claimed or recovered (to everyone sharing a family with them): `GET /users` and check it |
| `{type:"account_deleted", userId}` | that account was deleted (to everyone who shared a family with them): `GET /users` ("Deleting an account") |
| `{type:"family", familyId}` | a family you are in changed: it was renamed or approved, or someone joined, left or was removed, or became or stopped being an admin. Refetch `GET /families` and `GET /users` (the directory carries each family's admins and proofs) |
| `{type:"profile", userId}` | that user changed their name or profile photo (to everyone sharing a family with them): `GET /users` ("Profile: name and photo") |
| close code 4001 | this device was revoked |
| close code 4002 | no ping for 90 s (a half-open socket); reconnect |

### `send` rules
- `envelope.v == 1`, `nonce`/`ct`/`sig` base64url, JSON ≤ 64 KiB, `envelope.epoch == currentEpoch` and
  that epoch created; otherwise `invalid_request` / `stale_epoch`. Not a member → `not_member`.
- In a **direct** chat, the sender and the other member must be live and share a family, else
  `no_shared_family`. A chat whose other member deleted their account is still allowed.
- **Idempotent on `id`:** resending an id from the same device and chat returns the original `ack`
  (same `seq`) and doesn't fan out again. The same id anywhere else → `conflict`.
- Sends are processed one at a time; `seq` per chat is assigned without gaps and `msg` frames go out in
  `seq` order (deleting an account later removes its messages, which leaves holes in history).
  Clients still treat a `seq` above `lastSeen + 1` as a gap and fetch `?after=lastSeen`.
- On `stale_epoch`, get the chat, create or fetch the current epoch's key, re-encrypt **with the same
  id**, and resend.

### Sync
On every (re)connect: `GET /users`, `GET /chats`, `GET /keys/wraps`, then per chat
`GET /chats/:id/messages?after=<highest seq stored>` until a short page, then `GET /keys/missing` and
add wraps you can, then resend the outbox.

### Hooks for later plans
- Push (plan 9, done): `FamilyHub.push.notify(job)` puts a job on the `famchat-push` queue; the Worker's
  `queue()` handler (`src/push/consumer.ts`) sends it through FCM. See "Push" above.
- Admin reset (plan 10) reuses plan 6: revoking the user's devices rotates every chat, and the
  `device` event plus missing-wrap repair restores history to the new device ("Account resets").

## Signed and derived byte strings
Every signature, MAC and key derivation starts with its own domain string, and no domain string is a
prefix of another: `famchat-device-cert-v1`, `famchat-wrap-v1`, `famchat-envelope-v1`,
`famchat-sealed-box-v1` (HKDF info), `famchat-pair-keys-v1` (HMAC), `famchat-pair-bundle-v1` (HKDF info),
`famchat-media-v1` (media AEAD associated data), `famchat-reset-v1`, `famchat-reset-claim-v1`,
`famchat-recovery-key-v1`, `famchat-admin-v1`, `famchat-admin-v2` (signatures), `famchat-recovery-seed-v1` (HKDF info).
