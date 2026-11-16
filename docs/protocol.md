# FamChat protocol

The REST and WebSocket contract between the FamChat client and the Worker at `https://famchat.dev/api`.

## Conventions

- JSON request and response bodies.
- Binary values (keys, signatures, tokens) are **base64url without padding**.
- Times are Unix **milliseconds**.
- IDs are ULIDs (26 characters, Crockford base32).
- Errors are `{"error": "<code>"}`:

| Code | Status | Meaning |
|---|---|---|
| `invalid_request` | 400 | Malformed body, bad field, or a device certificate that doesn't verify |
| `unauthorized` | 401 | Missing, invalid or expired token; revoked device; wrong bootstrap secret |
| `forbidden` | 403 | Authenticated but not allowed (for example, not an admin) |
| `not_found` | 404 | Unknown route or resource |
| `already_bootstrapped` | 409 | Bootstrap was called after a user exists |
| `invite_invalid` | 410 | Invite unknown, expired or already used |
| `internal` | 500 | Unexpected server error |

## Tokens

- **Access token:** HS256 JWT, valid 15 minutes, claims `{sub: userId, dev: deviceId, adm: boolean, exp}`.
  Send it as `Authorization: Bearer <accessToken>`. A revoked device's token stops working immediately.
- **Refresh token:** an opaque 32-byte value. Each refresh returns a new one. Store it in the platform's secure storage,
  and make sure only one refresh runs at a time per device.
  - If a refresh response is lost, the previous token is accepted again for **60 seconds** after the rotation and
    returns a fresh pair.
  - Presenting the previous token after that window is treated as theft: the device is revoked and must be set up again.

## Device certificate

Each device has an X25519 key (`encPub`) and an Ed25519 key (`signPub`). The user's Ed25519 identity key
(`identityPub`) signs this byte string:

```
UTF-8 "famchat-device-cert-v1" (22 bytes) || encPub (32 bytes) || signPub (32 bytes)
```

The result is `certSig` (64 bytes). Public keys are exactly 32 bytes.

## Endpoints

### `GET /api/health`
→ `200 {"ok": true}`

### `POST /api/admin/bootstrap`
Creates the first admin's invite. It works only while no users exist.
- Header: `Authorization: Bearer <BOOTSTRAP_SECRET>`
- Body: `{"name": string}`, trimmed, 1–40 characters
- → `201 {"inviteToken", "inviteUrl", "expiresAt"}`, where `inviteUrl` is `https://famchat.dev/join#<inviteToken>`
- Errors: 401 for a wrong secret, 409 `already_bootstrapped`, 400 for a bad name

### `POST /api/admin/invites` (admin)
- Body: `{"name": string}`, trimmed, 1–40 characters. This becomes the new member's display name.
- → `201 {"inviteToken", "inviteUrl", "expiresAt"}`. Invites last 7 days and work once.
- Errors: 401, 403, 400

### `POST /api/auth/invite/redeem`
Creates the user and their first device.
- Body: `{"token", "deviceName" (1–60 chars), "platform" (ios|android|macos|windows|linux|web), "identityPub", "encPub", "signPub", "certSig"}`
- → `201 {"userId", "deviceId", "isAdmin", "accessToken", "refreshToken"}`
- Errors: 400 for a bad field or certificate (the invite stays usable), 410 `invite_invalid`
- Retrying with the same invite **and the same keys** within 10 minutes of a successful redeem returns `201` again,
  for the same user and device, with new tokens. This covers a lost response.
- A bootstrap (admin) invite stops working as soon as any user exists.

### `POST /api/auth/refresh`
- Body: `{"refreshToken"}`
- → `200 {"accessToken", "refreshToken"}`. The old refresh token keeps working only for the 60-second grace window.
- Errors: 400 for a missing token, 401 for an unknown or revoked one, or for an old token reused after the window
  (which also revokes the device)

### `GET /api/devices`
- → `200 {"devices": [{"id", "name", "platform", "createdAt", "lastSeen", "current"}]}`: the caller's active devices,
  with `current` set on the calling device

### `DELETE /api/devices/:id`
Revokes one of the caller's own devices, including the calling device (signing out).
- → `204`. The device's tokens and push token are cleared at once.
- Errors: 404 if the device isn't the caller's, doesn't exist or is already revoked
