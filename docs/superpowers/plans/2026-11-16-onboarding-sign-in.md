# Onboarding & Sign-in Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A family member opens an invite link (web) or pastes it (native), the app generates their identity and device keys, redeems the invite, stores the credentials securely, keeps a valid access token, and shows a signed-in home with a devices screen (revoke, sign out) and, for admins, an invite screen.

**Architecture:** Three layers under `app/lib/`. `session/` holds secure persistence (`SecureKv` interface; `flutter_secure_storage` in the app, an in-memory fake in tests) and the Riverpod `SessionController` (loading → signed out → signed in). `api/` holds a thin `ApiClient` over `package:http` and a `TokenManager` that owns the access token and does single-flight refresh. `screens/` hold the join, home, devices, invite and loading screens; `router.dart` redirects by session state. Tests drive everything through a stateful `FakeServer` (an `http` `MockClient`) that copies the plan 1 refresh-rotation and grace rules.

**Tech Stack:** Flutter 3.50, Riverpod 3, go_router 18, `flutter_secure_storage ^11.2.0`, `http ^1.6.0`, `flutter_web_plugins` (path URL strategy), plan 3 `lib/crypto/`. Server: Hono on Workers, vitest.

**Spec:** `docs/superpowers/specs/2026-11-15-famchat-design.md` ("Decisions: Sign-in", "API surface", "Keys", "Known limits"). Roadmap row 4. Server contract: plan 1 (`server/src/routes/{auth,devices,admin}.ts`).

## Global Constraints

- `lib/crypto/` stays free of Flutter imports; this plan only calls it (`newIdentityKey`, `DeviceKeys`, `signDeviceCert`, `seedOf`, `b64url`).
- API base URL: `const String.fromEnvironment('API_BASE', defaultValue: 'https://famchat.dev')`; every path is `$apiBase/api/...`.
- Redeem body: `{token, deviceName, platform, identityPub, encPub, signPub, certSig}`; `platform` ∈ `ios|android|macos|windows|linux|web`; `deviceName` 1–60 chars after trim. Errors are `{error: code}` (`invalid_request` 400, `unauthorized` 401, `forbidden` 403, `not_found` 404, `invite_invalid` 410, `internal` 500).
- Refresh rotates the token; the previous token is accepted for 60 s; reuse after that revokes the device. Only a **401 from `/api/auth/refresh`** means signed out; network errors and 5xx never do.
- Access tokens are kept in memory only; refresh tokens and key seeds only in `SecureKv`. Never log a token or a seed.
- Nothing may block forever on the OS keyring (Linux CI runs under xvfb with no keyring): every storage call made at startup is bounded by a timeout.
- Tests use `MemorySecureKv` and `FakeServer`; no test touches the network or the real keyring. Vitest `maxWorkers` stays 2.
- Do not touch `server/wrangler.jsonc`, web hosting, or deploy workflows (plan 12). `.github/workflows/app.yml` only gains `libsecret-1-dev`.

## Review Focus

1. **Lost refresh response:** the server rotated but the client got a network error → the stored token is unchanged, the client retries promptly with the same token (grace path) and stays signed in. Task 4 test `lost refresh response is retried with the same token`.
2. **Concurrent 401s:** three requests fail with 401 at once → exactly one `/api/auth/refresh` call, all three retried with the new token. Task 4 test `concurrent 401s share one refresh`.
3. **Lost redeem response:** the join request times out after the server created the device → tapping Join again reuses the same keys (server is idempotent for 10 min) and succeeds instead of `invite_invalid`. Task 5 test `redeem retry after a lost response reuses the keys`.
4. **No keyring (Linux) or a hung keyring:** startup storage read throws or never answers → an explanatory error screen within the timeout, not an endless spinner. Task 5 tests `storage error gives SessionUnavailable` and `storage that never answers gives SessionUnavailable`.
5. **Messy pasted invites:** whitespace/newlines, scheme-less `famchat.dev/join#…`, bare token → accepted; garbage → inline error and no network call. Task 3 tests and Task 6 test `bad invite shows an error without calling the server`.

---

## File Structure

| File | Responsibility |
|---|---|
| `server/src/routes/me.ts`, `server/test/me.test.ts` | `GET /api/me` |
| `app/lib/config.dart` | `apiBase` |
| `app/lib/platform_info.dart` | server platform name, default device name |
| `app/lib/session/secure_kv.dart` | `SecureKv`, `FlutterSecureKv`, `MemorySecureKv` |
| `app/lib/session/stored_session.dart` | `StoredSession` model, `SessionStore` (one JSON blob) |
| `app/lib/session/invite_link.dart` | `parseInviteToken`, `inviteTokenFromUri` |
| `app/lib/api/models.dart` | `ApiException`, `NetworkException`, `SignedOutException`, response models |
| `app/lib/api/api_client.dart` | HTTP calls, authed request with retry-after-refresh |
| `app/lib/api/token_manager.dart` | access token, single-flight refresh |
| `app/lib/session/session_controller.dart` | `SessionState`, `SessionController`, providers |
| `app/lib/router.dart` | `routerProvider`, `sessionRedirect` |
| `app/lib/screens/{loading,join,home,devices,invite}_screen.dart` | UI |
| `app/test/support/fake_server.dart` | stateful fake of the plan 1 API |

---

### Task 1: `GET /api/me`

**Files:** Create `server/src/routes/me.ts`, `server/test/me.test.ts`; modify `server/src/index.ts`, spec "API surface".

**Interfaces:** Produces `GET /api/me` → `200 {userId, deviceId, name, isAdmin}` (isAdmin from `users.is_admin`, not the token claim); `401` without a valid token.

- [ ] **Step 1: Failing tests** in `me.test.ts`: `returns own profile` (user from `insertUserWithDevice({admin: true, name: "Mom"})` → `{userId, deviceId, name: "Mom", isAdmin: true}`); `requires auth` (no header → 401); `revoked device is rejected` (set `revoked_at` → 401).
- [ ] **Step 2: Run** `cd server && npx vitest run test/me.test.ts` → FAIL (404).
- [ ] **Step 3: Implement** `me` router with `requireAuth`, mount at `/me`. Add `GET /api/me` to the spec's API surface.
- [ ] **Step 4: Run** `npm test` and `npm run typecheck` → pass.
- [ ] **Step 5: Commit** `feat(server): GET /api/me`

### Task 2: Secure storage and the stored session

**Files:** Modify `app/pubspec.yaml` (`flutter_secure_storage ^11.2.0`, `http ^1.6.0`, `flutter_web_plugins` sdk), `.github/workflows/app.yml` (add `libsecret-1-dev` to the Linux apt line). Create `app/lib/session/secure_kv.dart`, `app/lib/session/stored_session.dart`, `app/test/session/stored_session_test.dart`.

**Interfaces (Produces):**
- `abstract interface class SecureKv { Future<String?> read(String key); Future<void> write(String key, String value); Future<void> delete(String key); }`
- `class MemorySecureKv implements SecureKv` (public `Map<String,String> values` for tests).
- `class FlutterSecureKv implements SecureKv { FlutterSecureKv([FlutterSecureStorage? storage]); }` with options: Android `resetOnError: false`; iOS `KeychainAccessibility.first_unlock_this_device`; macOS `usesDataProtectionKeychain: false`, `accessibility: first_unlock_this_device`.
- `class StoredSession { userId, deviceId, deviceName, refreshToken, identitySeed (b64url), encSeed, signSeed: String; isAdmin: bool; name: String?; toJson(); factory fromJson(Map<String,Object?>) /* FormatException on missing/mistyped */; copyWith({String? refreshToken, bool? isAdmin, String? name}); Future<SimpleKeyPair> identityKey(); Future<DeviceKeys> deviceKeys(); }`
- `class SessionStore { SessionStore(SecureKv kv); static const key = 'famchat.session.v1'; Future<StoredSession?> load() /* null if absent or unreadable JSON */; Future<void> save(StoredSession s); Future<void> clear(); }`

- [ ] **Step 1: Failing tests:** `session round-trips through the store` (save, load in a new `SessionStore` on the same kv, equal fields; `deviceKeys()` gives the same `encPub`/`signPub` as the generated keys; `identityKey()` same public key); `absent session loads as null`; `corrupt blob loads as null` (`kv.values[key] = '{'` and `'{"v":1}'`); `clear removes the blob`; `copyWith rotates only the refresh token`.
- [ ] **Step 2: Run** `flutter test test/session/stored_session_test.dart` → FAIL (missing files).
- [ ] **Step 3: Implement.** One JSON blob with a `v: 1` field, so a rotation rewrites everything atomically.
- [ ] **Step 4: Run** → PASS; `flutter analyze` clean.
- [ ] **Step 5: Commit** `feat(app): secure session storage`

### Task 3: Invite links and platform defaults

**Files:** Create `app/lib/session/invite_link.dart`, `app/lib/platform_info.dart`, `app/lib/config.dart`; tests `app/test/session/invite_link_test.dart`, `app/test/platform_info_test.dart`.

**Interfaces (Produces):**
- `String? parseInviteToken(String input)` — trims; takes the text after the last `#` if any; the token must match `^[A-Za-z0-9_-]{20,128}$`; else null.
- `String? inviteTokenFromUri(Uri uri)` — path ends in `/join` and fragment non-empty → `parseInviteToken(fragment)`; else null.
- `String serverPlatform()` — `kIsWeb` → `web`; else `defaultTargetPlatform` (`fuchsia` → `linux`).
- `String defaultDeviceName()` — ios `iPhone`, android `Android phone`, macos `Mac`, windows `Windows PC`, linux `Linux PC`, web `Web browser`.
- `const String apiBase` in `config.dart`.

- [ ] **Step 1: Failing tests** with `t = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde'` (43 chars like the server's): full URL, `famchat.dev/join#t`, `#t`, `  t\n`, `http://localhost:8787/join#t` → `t`; `''`, `'https://famchat.dev/join'`, `'https://famchat.dev/join#'`, `'hello world'`, `'short'`, token with `+` or `/` → null. `inviteTokenFromUri(Uri.parse('https://famchat.dev/join#t'))` → t; `/chats#t` → null. Platform: with `debugDefaultTargetPlatformOverride` for each of the six-ish values, `serverPlatform()` and `defaultDeviceName()` match the table (VM, so not web).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(app): invite link parsing and platform defaults`

### Task 4: API client and token refresh

**Files:** Create `app/lib/api/models.dart`, `app/lib/api/api_client.dart`, `app/lib/api/token_manager.dart`, `app/test/support/fake_server.dart`, `app/test/api/token_manager_test.dart`, `app/test/api/api_client_test.dart`.

**Interfaces (Produces):**
- `class ApiException implements Exception { final int status; final String code; }` (code `unknown` if the body isn't `{error}`); `class NetworkException implements Exception { final Object cause; }`; `class SignedOutException implements Exception {}`.
- `class TokenPair { accessToken, refreshToken }`, `class RedeemResult { userId, deviceId, accessToken, refreshToken: String; isAdmin: bool }`, `class Me { userId, deviceId, name: String; isAdmin: bool }`, `class DeviceInfo { id, name, platform: String; createdAt, lastSeen: DateTime; current: bool }`, `class Invite { inviteToken, inviteUrl: String; expiresAt: DateTime }`.
- `class TokenManager { TokenManager({required Future<TokenPair> Function(String refreshToken) refreshCall, required Future<String?> Function() readRefreshToken, required Future<void> Function(String) saveRefreshToken, required Future<void> Function() onRevoked, DateTime Function() now = DateTime.now, List<Duration> retryDelays = const [Duration(seconds: 1), Duration(seconds: 3), Duration(seconds: 8)]}); void setAccessToken(String? t); Future<String> accessToken(); Future<String> refreshAfter401(String rejected); }`
  - `accessToken()`: returns the cached token unless missing or its JWT `exp` is within 60 s of `now()`; then refreshes.
  - Refresh is single-flight (one in-flight `Future` shared). It re-reads the refresh token from storage each time (another tab may have rotated it), saves the new refresh token **before** publishing the access token, retries `NetworkException`/5xx after each `retryDelays` entry with the **same** token, then throws the last error. A refresh `ApiException` with status 401 → `onRevoked()` then `SignedOutException`. No stored token → `SignedOutException`.
  - `refreshAfter401(rejected)`: if the cached token already differs from `rejected`, return it (someone refreshed meanwhile); else refresh.
- `class ApiClient { ApiClient({required http.Client http, required Uri base, TokenManager? tokens}); set tokens(TokenManager t); Future<RedeemResult> redeemInvite({required String token, required String deviceName, required String platform, required DeviceCert cert}); Future<TokenPair> refresh(String refreshToken); Future<Me> me(); Future<List<DeviceInfo>> listDevices(); Future<void> revokeDevice(String id); Future<Invite> createInvite(String name); }` — authed calls send `Authorization: Bearer`, and on 401 call `refreshAfter401` and retry once. Transport errors (`http.ClientException`, `TimeoutException`, socket errors) become `NetworkException`; every request has a 20 s timeout.
- `FakeServer` (test support): `MockClient get client`; `String addInvite({String name, bool admin})`; `int refreshCalls`; `bool dropNextRefreshResponse` (rotates, then throws `ClientException`); `bool dropNextRedeemResponse`; `int failNext5xx`; devices map with `revoke(id)`; `expireAccessTokens()`; access tokens are unsigned JWT-shaped strings with `exp` from an injected clock. Implements redeem (incl. 10-min same-keys retry), refresh (rotation, 60 s grace, revoke after grace), me, devices list/delete, admin invites, exactly as `server/src/routes/*.ts`.

- [ ] **Step 1: Failing tests** (`token_manager_test.dart`, against `FakeServer` + `ApiClient`):
  - `expired access token is refreshed before the request` (advance clock 16 min → `me()` succeeds, `refreshCalls == 1`, stored refresh token changed).
  - `concurrent 401s share one refresh` (`expireAccessTokens()` server-side, `Future.wait` of three `listDevices()` → all succeed, `refreshCalls == 1`).
  - `lost refresh response is retried with the same token` (`dropNextRefreshResponse = true`, `retryDelays: [Duration.zero]` → call succeeds, still signed in, `refreshCalls == 2`, device not revoked).
  - `5xx from refresh does not sign out` (`failNext5xx = 5`, `retryDelays: [Duration.zero]` → throws `ApiException` 500, `onRevoked` not called, stored token unchanged).
  - `revoked device signs out` (server revokes the device, expire tokens → `me()` throws `SignedOutException`, `onRevoked` called once).
  - `refresh token is saved before use` (the `saveRefreshToken` callback observed the new token before `accessToken()` returns).
  - `api_client_test.dart`: `error body maps to ApiException code` (410 `invite_invalid`); `non-JSON error body gives code unknown`; `transport error becomes NetworkException`; `devices parse with current flag and dates`.
- [ ] **Step 2: Run** `flutter test test/api/` → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(app): API client with single-flight token refresh`

### Task 5: Session controller

**Files:** Create `app/lib/session/session_controller.dart`, `app/test/session/session_controller_test.dart`.

**Interfaces:**
- Consumes: Tasks 2–4.
- Produces:
  - `sealed class SessionState`; `SessionLoading`; `SignedOut({String? message})`; `SignedIn(StoredSession session)`; `SessionUnavailable(String message)`.
  - Providers: `secureKvProvider` (`FlutterSecureKv()`), `httpClientProvider` (`http.Client()`), `apiBaseProvider` (`Uri.parse(apiBase)`), `clockProvider` (`DateTime.now`), `storageTimeoutProvider` (`Duration(seconds: 10)`), `initialInviteTokenProvider` (`String?`, null), `apiClientProvider`, `tokenManagerProvider`, `sessionProvider` (`NotifierProvider<SessionController, SessionState>`).
  - `class SessionController extends Notifier<SessionState> { Future<void> join({required String token, required String deviceName}); Future<void> updateProfile(Me me); Future<void> signOut(); Future<void> retryRestore(); }` — `build()` starts `SessionLoading` and restores from `SessionStore` with the storage timeout (error/timeout → `SessionUnavailable`). `join` throws `ApiException`/`NetworkException` to the caller; it reuses the generated keys and cert when retried with the same token (held in memory only). After a successful redeem it saves the session, then sets the access token, then `SignedIn`. `signOut` best-effort `DELETE /api/devices/<own id>` (5 s timeout, errors ignored), clears storage and the token manager, → `SignedOut()`. Revocation (`onRevoked`) clears storage → `SignedOut(message: 'This device was signed out. Ask for a new invite to sign in again.')`.

- [ ] **Step 1: Failing tests** (`ProviderContainer` with `MemorySecureKv` and `FakeServer.client`):
  - `starts signed out with empty storage`; `restores a saved session`.
  - `join stores keys and tokens` (state `SignedIn`, stored blob has 32-byte seeds, server device has the session's `signPub`, `name == null`, `isAdmin` as invited).
  - `redeem retry after a lost response reuses the keys` (`dropNextRedeemResponse` → first `join` throws `NetworkException`, second succeeds, server has one device).
  - `used invite throws invite_invalid`.
  - `storage error gives SessionUnavailable` (kv whose `read` throws `PlatformException`); `storage that never answers gives SessionUnavailable` (kv `read` returns a never-completing future, timeout 50 ms).
  - `sign out revokes this device and clears storage`.
  - `revoked device ends signed out with a message` (revoke server-side, expire tokens, `api.me()` → `SignedOutException`, state `SignedOut` with message, storage empty).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(app): session controller (join, restore, sign out, revocation)`

### Task 6: Join screen, router and app entry

**Files:** Create `app/lib/screens/loading_screen.dart`, `app/lib/screens/join_screen.dart`, `app/test/screens/join_screen_test.dart`; modify `app/lib/router.dart`, `app/lib/main.dart`, `app/test/app_test.dart`.

**Interfaces:**
- Produces: `final routerProvider = Provider<GoRouter>`; `String? sessionRedirect(SessionState s, String location)` — loading/unavailable → `/loading`; signed out → `/join` unless at `/join` or `/spikes`; signed in at `/join` or `/loading` → `/`; `/invite` for a non-admin → `/`; else null. Routes `/loading`, `/join`, `/`, `/devices`, `/invite`, `/spikes`.
- `main()`: `usePathUrlStrategy()`; on web, `inviteTokenFromUri(Uri.base)` → `initialInviteTokenProvider` override.
- `JoinScreen`: invite field (prefilled from `initialInviteTokenProvider`; on web with a token, the field is hidden behind a "Joining with the link you opened" note), device-name field (default `defaultDeviceName()`, 1–60 chars), `Join` button with a progress state. Errors inline: bad link "That doesn't look like a FamChat invite link."; `invite_invalid` "This invite has expired or was already used. Ask for a new one."; `NetworkException` "Couldn't reach FamChat. Check your connection and try again."; other "Something went wrong (code)." `LoadingScreen` shows a spinner, or for `SessionUnavailable` the message and a Retry button.

- [ ] **Step 1: Failing tests:** `sessionRedirect` table test; `join with a pasted link signs in` (pump app with overrides, enter full URL, tap Join → home shows "Chats coming soon"); `bad invite shows an error without calling the server` (`FakeServer` request count 0); `used invite shows the expired message`; `web link prefill` (`initialInviteTokenProvider` override → field prefilled/hidden, Join works); `app_test` updated: empty storage → join screen; `/spikes` still reachable.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(app): join screen and session-aware router`

### Task 7: Home, devices and invite screens

**Files:** Create `app/lib/screens/devices_screen.dart`, `app/lib/screens/invite_screen.dart`, `app/test/screens/devices_screen_test.dart`, `app/test/screens/invite_screen_test.dart`; rewrite `app/lib/screens/home_screen.dart`.

**Interfaces:**
- Consumes: `apiClientProvider`, `sessionProvider`.
- Produces: `meProvider` (`FutureProvider<Me>`, calls `updateProfile`), `devicesProvider` (`FutureProvider.autoDispose<List<DeviceInfo>>`).
- Home: app bar title "FamChat", greeting `Hi, <name>` (stored name until `me` loads), body "Chats coming soon", actions: Devices, Invite someone (admin only), overflow with Platform spikes and Sign out (confirm dialog).
- Devices: one tile per device: name, platform, "Last seen <date>"; current device has a "This device" label and no revoke button; others have Revoke with a confirm dialog → `revokeDevice` → reload. A Sign out button at the bottom.
- Invite: name field (1–40 chars) → `createInvite` → shows `inviteUrl`, expiry date, Copy button (`Clipboard.setData`, snackbar "Link copied"), "Only share this with <name>. It works once and expires in 7 days."

- [ ] **Step 1: Failing tests:** `devices list marks the current device` (two devices, one "This device", one Revoke button); `revoking another device removes it` (confirm → list shows one, server device revoked); `sign out returns to join` (confirm → join screen, storage empty); `invite screen shows and copies the link` (admin session; mock clipboard via `TestDefaultBinaryMessengerBinding` `SystemChannels.platform` handler capturing `Clipboard.setData`); `non-admin has no invite action`; `home shows the user's name`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS; full `flutter test`, `flutter analyze`, `flutter test --platform chrome test/crypto/`.
- [ ] **Step 5: Commit** `feat(app): home, devices and invite screens`

### Task 8: Finish

- [ ] Whole-branch review by a fresh reviewer; fix Critical/Important with a test first.
- [ ] Push `plan4-onboarding`, open the PR, watch CI (`app`, `server` workflows) to green.
