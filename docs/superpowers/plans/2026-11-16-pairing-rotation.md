# Device Pairing & Key Rotation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed-in device adds another device of the same user by QR code (or a typed code); the new device receives the identity key, a certificate, every chat key and the trusted identity keys over an end-to-end channel, then reads the full history. Revoking a device moves every chat of its user to a new epoch, and member devices repair missing wraps as soon as a device is added.

**Architecture:** Server: a `pair_sessions` table and a `pairing` Hono router mounted at `/api/devices/pair` (before `/devices`, whose `requireAuth` must not catch the unauthenticated routes); the new device's row is created when it claims the approved session; revocation bumps `current_epoch` of the user's chats in the same D1 batch and notifies the hub (`chat` per chat, `device` events). Client: Flutter-free crypto (`lib/crypto/pairing.dart`: key commitment HMAC and a secret-bound sealed box for the bundle), a Flutter-free pairing layer (`lib/pairing/`: code format, bundle building/installing, the new device's polling state machine, the approver), Riverpod wiring, and two screens (`/pair` for the new device, `/devices/add` for the existing one).

**Tech Stack:** Cloudflare Workers + Hono, D1, vitest 5 + `@cloudflare/vitest-plugin`. Flutter 3.50, Riverpod 3, go_router 18, drift 2.35, `cryptography` 2.9, new `qr_flutter ^4.1.0` (render) and `mobile_scanner ^7.5.0` (scan, Android/iOS only).

**Spec:** `docs/superpowers/specs/2026-11-15-famchat-design.md` ("Keys", "Devices and membership", "Missing wraps", "API surface"). Roadmap row 6. Contract: `docs/protocol.md`.

## Pairing protocol (binding for every task)

- New device N makes an ephemeral X25519 key pair `eph`, its device keys (`enc`, `sign`), and a 12-character secret `S` (Crockford base32, 60 bits). `S` never goes to the server.
- `keysMac = HMAC-SHA256(key = UTF-8(S), "famchat-pair-keys-v1" ‖ ephPub ‖ encPub ‖ signPub ‖ str(deviceName) ‖ str(platform))`.
- `POST /devices/pair/start {ephPub, encPub, signPub, keysMac, deviceName, platform}` → server assigns a 4-char lookup code `L` and `deviceId`. N shows the code `L‖S` as `LLLL-SSSS-SSSS-SSSS` and a QR `famchat-pair:1:<LS 16 chars>:<ephPub b64url>`.
- Existing device E (same user) looks the session up by `L`, recomputes `keysMac` with `S` (and, from a QR, checks `ephPub` equals the QR's), shows the device name/platform, then signs N's cert with the identity key and seals the bundle: `sealed = ephE(32) ‖ nonce(24) ‖ ct ‖ mac(16)`, key = `HKDF-SHA256(ikm = X25519(ephE, ephPubN) ‖ UTF-8(S), salt = ephPubE ‖ ephPubN, info = "famchat-pair-bundle-v1")`, XChaCha20-Poly1305.
- Bundle JSON: `{v:1, userId, deviceId, identitySeed, certSig, keys:[{chatId, epoch, key}], trust:[{userId, trustedIdentityPub, known:[…]}]}` (binary values b64url).
- N polls `POST /devices/pair/claim {sessionId, secret}`; once approved it gets tokens + bundle, opens it with `eph` and `S`, checks `certSig` over its own keys against the identity key from `identitySeed`, and that `userId`/`deviceId` match the claim response. Only then are keys installed and the session saved.
- Security: the server never learns `S`, so it can neither swap N's keys past E (the MAC fails) nor forge a bundle N accepts (the AEAD fails); grinding 60 bits within the 5-minute session is out of reach.

## Global Constraints

- Errors stay `{error: code}`. New codes: `rate_limited` 429, `pairing_invalid` 410.
- Session TTL 5 min from start; approve only before expiry; first claim within 10 min of approval; a repeat claim with the same secret within 10 min of the first re-issues tokens (lost response). Bundle ≤ 256 KiB decoded.
- Start rate limits: ≤ 5 sessions per client IP (`cf-connecting-ip`) per 10 min, ≤ 50 live sessions overall.
- Domain strings: `famchat-device-cert-v1`, `famchat-wrap-v1`, `famchat-envelope-v1`, `famchat-sealed-box-v1`, `famchat-pair-keys-v1`, `famchat-pair-bundle-v1`; no domain string may be a prefix of another (rule and list in `encoding.dart`, enforced by a test).
- A wrap whose wrapper device is revoked is not accepted (client) and counts as missing (server `GET /keys/missing`; `PUT /keys/wraps` may replace it).
- `lib/crypto/` and `lib/pairing/` (except `pairing_providers.dart`) stay Flutter-free. No `dart:io` under `lib/`. Camera scanning only on Android/iOS; everything else types the code.
- Never log seeds, secrets, tokens or bundles. Vitest `maxWorkers` ≤ 2; one build/test process at a time.

## Review Focus

1. **Server MITM of the keys or the bundle:** the session lookup returns keys other than N's (or a forged bundle reaches N) → E refuses ("This code doesn't match") / N refuses ("couldn't verify"), no keys installed. Task 3 tests `approver rejects swapped keys`, `bundle from someone without the secret does not open`; Task 4 `forged bundle is rejected`.
2. **Lost claim response / app restart while waiting:** the claim succeeded server-side but the response was lost → the next poll with the same secret gets fresh tokens, device not duplicated. Task 1 test `repeat claim reissues tokens`; Task 4 `lost claim response is retried`.
3. **Expiry while showing the code:** no approval within 5 min → N shows "Code expired" with "Get a new code", stops polling. Task 4 `expired session stops polling`; Task 6 widget `expired code offers a new one`.
4. **Revocation during traffic:** revoke while an outbox message waits → `stale_epoch`, the new epoch excludes the revoked device, which can't get the new key. Task 2 test `revocation bumps every chat`; Task 5 `revoking a device rotates and the revoked device gets no new key`.
5. **New device appears while members are online:** online member devices add wraps on the `device` event without waiting for a reconnect. Task 5 `device event repairs wraps right away`.

---

## File Structure

| File | Responsibility |
|---|---|
| `server/migrations/0004_pairing.sql` | `pair_sessions` |
| `server/src/routes/pairing.ts` | start, lookup, approve, claim, cancel |
| `server/src/routes/devices.ts` | revocation bumps epochs + events |
| `server/src/routes/keys.ts` | revoked wrappers count as missing / replaceable |
| `server/src/lib/family.ts` | `sharingUserIds(db, userId)` |
| `server/test/pairing.test.ts`, `test/revocation.test.ts` | tests |
| `app/lib/crypto/pairing.dart` | `pairKeysMac`, `sealPairBundle`, `openPairBundle` |
| `app/lib/pairing/pair_code.dart` | code/secret/QR formats |
| `app/lib/pairing/bundle.dart` | `PairBundle`, `buildHandover`, `installHandover` |
| `app/lib/pairing/new_device_pairing.dart` | N's state machine |
| `app/lib/pairing/approver.dart` | E's lookup/verify/approve |
| `app/lib/pairing/pairing_providers.dart` | Riverpod wiring, scanner hook |
| `app/lib/screens/pair_screen.dart`, `add_device_screen.dart` | UI |
| `app/test_e2e/pairing_e2e_test.dart`, `scripts/e2e-pairing.sh` | against `wrangler dev` |

---

### Task 1: Server pairing routes

**Files:** Create `server/migrations/0004_pairing.sql`, `server/src/routes/pairing.ts`, `server/src/lib/family.ts`, `server/test/pairing.test.ts`; modify `server/src/index.ts`, `server/src/lib/errors.ts`, `server/test/helpers.ts` (`resetDb` clears `pair_sessions`).

**Interfaces (Produces):**
- `pair_sessions(id PK, code UNIQUE, secret_hash, device_id, eph_pub, enc_pub, sign_pub, keys_mac, device_name, platform, client_ip, created_at, expires_at, user_id, approved_by_device, approved_at, bundle, claimed_at, cancelled_at)` + index on `expires_at`.
- `POST /devices/pair/start` → `201 {sessionId, code, secret, deviceId, expiresAt, expiresIn}`.
- `GET /devices/pair/:code` (authed) → `{session: {code, deviceId, ephPub, encPub, signPub, keysMac, deviceName, platform, expiresAt}}`; unknown/expired/used → 404.
- `POST /devices/pair/:code/approve {deviceId, certSig, bundle}` (authed) → 204; cert must verify against the caller's identity key (else 400); session not pending → 404.
- `POST /devices/pair/claim {sessionId, secret}` → `{status:"waiting"}` or `{status:"approved", userId, deviceId, isAdmin, accessToken, refreshToken, bundle}`; creates the device row on the first claim; `device {userId, deviceId}` event to `sharingUserIds`. Wrong secret/unknown → 404; expired/cancelled/too late → 410 `pairing_invalid`.
- `POST /devices/pair/cancel {sessionId, secret}` → 204.
- `sharingUserIds(db, userId)`: the user plus everyone sharing a chat.

- [ ] **Step 1: Failing tests** `pairing.test.ts`: `start needs no auth and returns a code`; `start validates keys, mac, name and platform`; `start is rate limited per IP`; `happy path: lookup, approve, claim gives working tokens and the bundle` (new device in `/users` with the cert, `GET /me` works with the access token); `claim before approval waits`; `approve is single use` (second approve 404); `claim is single use after the retry window` and `repeat claim reissues tokens` (old refresh token stops working); `wrong secret → 404`; `expired session: lookup 404, approve 404, claim 410`; `approval cert signed by another user's identity → 400`; `cancelled session cannot be approved`; `claim notifies sharing users with a device event` (hub socket of a chat partner gets `{type:"device"}`).
- [ ] **Step 2: Run** `cd server && npx vitest run test/pairing.test.ts` → FAIL.
- [ ] **Step 3: Implement.** Approve and claim are each one conditional `db.batch`; the claim's device insert is `INSERT … SELECT … FROM pair_sessions WHERE id = ? AND claimed_at = ?`.
- [ ] **Step 4: Run** `npm test && npm run typecheck` → pass.
- [ ] **Step 5: Commit** `feat(server): QR device pairing sessions`

### Task 2: Revocation rotates epochs; revoked wrappers

**Files:** Modify `server/src/routes/devices.ts`, `server/src/routes/keys.ts`; create `server/test/revocation.test.ts`; `docs/protocol.md` (all of Tasks 1–2).

- [ ] **Step 1: Failing tests:** `revocation bumps every chat of the user` (two chats → `currentEpoch 2`, `epochReady false`; a chat of others untouched); `revocation notifies members with chat and device events`; `revoking twice bumps once` (404 second time); `missing lists devices whose wrap came from a revoked device`; `PUT replaces a wrap made by a revoked device`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** (bump in the same batch, guarded by `EXISTS (… revoked_at = ?)`). **Step 4: Run** `npm test && npm run typecheck`.
- [ ] **Step 5: Commit** `feat(server): revocation rotates chat keys; revoked wrappers count as missing`

### Task 3: Pairing crypto and bundle

**Files:** Create `app/lib/crypto/pairing.dart`, `app/lib/pairing/pair_code.dart`, `app/lib/pairing/bundle.dart`, tests `app/test/crypto/pairing_test.dart`, `app/test/pairing/pair_code_test.dart`, `app/test/pairing/bundle_test.dart`; modify `app/lib/crypto/encoding.dart` (`famchatDomains` + rule), `sealed_box.dart` (internal `sealBoxWith`/`openBoxWith` taking `info` and `secret`), `app/lib/chat/db/chat_db.dart` (`allKeys()`).

**Interfaces (Produces):**
- `Future<Uint8List> pairKeysMac({required String secret, required List<int> ephPub, encPub, signPub, required String deviceName, platform})`; `Future<bool> checkPairKeysMac({…, required List<int> mac})` (constant time).
- `Future<Uint8List> sealPairBundle({required List<int> recipientEphPub, required String secret, required List<int> plaintext})`; `Future<Uint8List> openPairBundle({required SimpleKeyPair eph, required String secret, required List<int> sealed})` (throws `CryptoFailure`).
- `class PairCode { lookup, secret; display; compact; static PairCode? parse(String); }`, `String newPairSecret()`, `class PairQr { code, ephPub; String encode(); static PairQr? parse(String); }`.
- `class PairBundle { userId, deviceId; Uint8List identitySeed, certSig; List<HandoverKey> keys; List<TrustedIdentity> trust; toJson(); fromJson() /* CryptoFailure */ }`.
- `Future<PairBundle> buildHandover({ChatDb db, String userId, String deviceId, SimpleKeyPair identity, List<int> encPub, signPub})`; `Future<void> installHandover(ChatDb db, PairBundle b, {required String myUserId})` (bindDevice, putKey, trust rows).

- [ ] **Step 1: Failing tests:** `no domain string is a prefix of another`; mac round-trip and `mac fails for other keys, name or secret`; `bundle opens with the right eph and secret`, `bundle from someone without the secret does not open`, `tampered bundle fails`; pair code: parse with dashes/spaces/lowercase/`O`→`0`, rejects wrong length or letters; QR round-trip, garbage → null; bundle JSON round-trip and `bad bundle json → CryptoFailure`; `handover carries every key and trust, install restores them and directory keeps the handed trust` (server shows a different key → flagged).
- [ ] **Step 2: Run** `flutter test test/crypto/pairing_test.dart test/pairing/` → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(app): pairing crypto, codes and history handover bundle`

### Task 4: Pairing API and state machines

**Files:** Modify `app/lib/api/api_client.dart`, `app/lib/api/models.dart`, `app/test/support/fake_server.dart` (pairing routes mirroring Task 1); create `app/lib/pairing/new_device_pairing.dart`, `app/lib/pairing/approver.dart`, `app/test/pairing/new_device_pairing_test.dart`, `app/test/pairing/approver_test.dart`, `app/test/support/pairing_helpers.dart`.

**Interfaces (Produces):**
- `ApiClient`: `pairStart(...) → PairStartResult{sessionId, lookup, secret, deviceId, expiresIn}`, `pairClaim(sessionId, secret) → PairClaim` (sealed `PairWaiting` / `PairApproved{RedeemResult result; String bundle}`), `pairCancel`, `pairLookup(lookup) → PairSessionInfo{deviceId, ephPub, encPub, signPub, keysMac, deviceName, platform}`, `pairApprove(lookup, {deviceId, certSig, bundle})`.
- `sealed class PairState`: `PairStarting`, `PairShowing{PairCode code; String qr; DateTime expiresAt}`, `PairFinishing`, `PairDone{PairedDevice device}`, `PairExpired`, `PairFailed{String message}`.
- `class PairedDevice { StoredSession session; String accessToken; PairBundle bundle; }`
- `class NewDevicePairing { NewDevicePairing({required ApiClient api, required String deviceName, required String platform, Duration pollEvery = 2s, DateTime Function() now}); Stream<PairState> get states; PairState get state; Future<void> start(); Future<void> cancel(); }`.
- `class DeviceApprover { DeviceApprover({required ApiClient api, required ChatDb db, required StoredSession session}); Future<PendingApproval> lookup(String input); Future<void> approve(PendingApproval p); }` — `input` is a typed code or QR text; throws `PairingException(kind: notFound|mismatch|badCode)`.

- [ ] **Step 1: Failing tests:** new device: `shows a code then finishes with a verified session`; `lost claim response is retried`; `network errors keep polling`; `expired session stops polling` (`PairExpired`, cancel sent); `forged bundle is rejected` (`PairFailed`, no session); `cancel stops polling`. approver: `typed code and QR both approve`; `approver rejects swapped keys` (server returns other keys → `mismatch`, nothing posted); `QR eph mismatch is rejected`; `unknown code → notFound`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(app): pairing API, new-device and approver flows`

### Task 5: Sync engine: device events, revocation, history after pairing

**Files:** Modify `app/lib/chat/chat_sync.dart` (`device` event), `app/lib/chat/chat_keys.dart` (skip revoked wrappers), `app/test/support/fake_chat_backend.dart` (`revoke(deviceId)` bumps epochs + events, `pairDevice(userId)` + `device` event, revoked wrappers unusable), `app/test/chat/chat_sync_test.dart`, `app/test/chat/chat_keys_test.dart`.

- [ ] **Step 1: Failing tests:** `device event repairs wraps right away`; `revoking a device rotates and the revoked device gets no new key`; `paired device reads history from the handover` (E builds a handover, N installs, N syncs → all old messages decrypt, N sends and Bob reads); `wrap from a revoked device is not accepted`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `flutter test test/chat/` → PASS.
- [ ] **Step 5: Commit** `feat(app): repair on device events, rotation after revocation`

### Task 6: Screens

**Files:** Modify `app/pubspec.yaml` (`qr_flutter`, `mobile_scanner`), `ios/Runner/Info.plist` (`NSCameraUsageDescription`), `app/lib/session/session_controller.dart` (`adoptPairedDevice(PairedDevice)`), `app/lib/router.dart` (`/pair` signed out, `/devices/add`), `join_screen.dart` ("Sign in with another device"), `devices_screen.dart` ("Add a device"); create `app/lib/pairing/pairing_providers.dart`, `app/lib/screens/pair_screen.dart`, `app/lib/screens/add_device_screen.dart`, tests `app/test/screens/pair_screen_test.dart`, `app/test/screens/add_device_screen_test.dart`.

**Interfaces:** `qrScannerProvider` (`Widget Function(void Function(String))?`; default MobileScanner on Android/iOS, null elsewhere; tests override). `pairing_providers.dart` installs the handover into `chatDbProvider` then calls `adoptPairedDevice`.

- [ ] **Step 1: Failing tests:** pair screen: `join screen links to pairing`; `shows the code and QR, then signs in after approval` (keys installed in the chat db, `/` shown); `expired code offers a new one`; `cancel returns to join`. add device: `typed code shows the device and approves it` (bundle opens with the test's eph and holds the identity seed and chat keys); `wrong code shows an error`; `swapped keys show a warning and nothing is approved`; `scanner result goes straight to confirmation` (fake scanner); devices screen `Add a device opens the flow`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** full `flutter test`, `flutter analyze` → pass.
- [ ] **Step 5: Commit** `feat(app): add-a-device and sign-in-with-another-device screens`

### Task 7: End-to-end against `wrangler dev`, docs, finish

**Files:** Create `app/test_e2e/pairing_e2e_test.dart`, `scripts/e2e-pairing.sh`; modify `docs/protocol.md`, spec "API surface" if needed.

- [ ] E2E (skips without `FAMCHAT_E2E_API`): bootstrap admin, invite Bob, Alice creates a chat and sends; N pairs with Alice's phone and reads the message; Alice revokes N → epoch 2 created by Alice's phone and messages flow.
- [ ] `flutter build web --release` once; whole-branch review; merge `origin/main`; push; PR; CI green.
