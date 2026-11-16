# Server Foundation & Auth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Cloudflare Worker on famchat.dev where the first admin is bootstrapped, admins create invite links, family members redeem them to register a device, and devices refresh tokens, list devices and revoke them.

**Architecture:** A Hono app in one Worker, with D1 for users, devices and invites. Access tokens are 15-minute HS256 JWTs. Refresh tokens are random 32-byte values, stored only as SHA-256 hashes and rotated on every use. Each device registers its public keys with a certificate signed by the user's identity key, and the server verifies it with Ed25519 through WebCrypto.

**Tech Stack:** TypeScript, Cloudflare Workers, Wrangler, D1, Hono (`hono`, `hono/jwt`), vitest + `@cloudflare/vitest-pool-workers`.

**Spec:** `docs/superpowers/specs/2026-11-15-famchat-design.md` (roadmap: `docs/superpowers/plans/2026-11-15-famchat-roadmap.md`)

## Global Constraints

- All server code lives in `server/`. Routes live under `/api`. JSON in and out.
- Errors are `{"error": "<code>"}` with these codes and statuses: `invalid_request` 400, `unauthorized` 401, `forbidden` 403, `not_found` 404, `already_bootstrapped` 409, `invite_invalid` 410.
- Binary values (keys, signatures, tokens) are **base64url without padding**.
- Public keys are exactly 32 bytes; signatures are exactly 64 bytes.
- Device certificate message = UTF-8 `"famchat-device-cert-v1"` ‖ `encPub` (32 bytes) ‖ `signPub` (32 bytes), signed with Ed25519 by `identityPub`. Plan 3 (Dart) must produce exactly this.
- Access token: HS256 JWT signed with secret `TOKEN_SECRET`, claims `{ sub: userId, dev: deviceId, adm: boolean, exp: now + 900 }`.
- Refresh and invite tokens: 32 random bytes, base64url. D1 stores only lowercase hex SHA-256.
- Invite lifetime: 7 days. Invite URL: `${APP_ORIGIN}/join#<token>` with `APP_ORIGIN = "https://famchat.dev"`.
- IDs are ULIDs (26 characters, Crockford base32).
- `platform` ∈ `ios | android | macos | windows | linux | web`.
- User names are trimmed, 1–40 characters. Device names are trimmed, 1–60 characters.
- vitest runs with `maxWorkers: 2` (machine constraint).
- Before writing config, check current Wrangler and `@cloudflare/vitest-pool-workers` setup in the Cloudflare docs (context7 or the docs MCP). Don't rely on memory for config shape.

## Review Focus

1. **The same invite redeemed twice, including two requests at once** → exactly one user is created; the second request gets 410 `invite_invalid`. (Task 4 test `redeem twice`.)
2. **A refresh token presented again after it was rotated** → 401, and the device keeps working with the newest token. (Task 5 test `old refresh token rejected`.)
3. **A revoked device still holding an unexpired access token** → 401 on its next request, not up to 15 minutes later. (Task 6 test `revoked device access token rejected`.)
4. **Wrong-length keys or a bad device-cert signature on redeem** → 400 `invalid_request` and the invite is **not** used up. (Task 4 test `bad cert does not burn invite`.)
5. **Bootstrap called after a user exists, or with the wrong secret** → 409 or 401; no invite is created. (Task 3 tests.)

---

## File Structure

```
server/
├── package.json, tsconfig.json, wrangler.jsonc, vitest.config.ts
├── migrations/0001_auth.sql          users, devices, invites
├── src/
│   ├── index.ts                      Hono app: mounts routes, error handler, GET /api/health
│   ├── env.ts                        Env bindings type, AppContext variables type
│   ├── lib/
│   │   ├── encoding.ts               b64urlEncode/Decode, hex
│   │   ├── ids.ts                    newId()
│   │   ├── tokens.ts                 randomToken, sha256Hex, signAccessToken, verifyAccessToken
│   │   ├── devicecert.ts             verifyDeviceCert
│   │   └── errors.ts                 ApiError + helpers
│   ├── middleware/auth.ts            requireAuth, requireAdmin
│   └── routes/{admin,auth,devices}.ts
└── test/
    ├── env.d.ts, apply-migrations.ts, helpers.ts   (helpers: makeKeys(), redeemNewDevice())
    └── {lib,admin,auth,devices}.test.ts
docs/protocol.md                      auth section of the REST contract
```

---

### Task 1: Scaffold the Worker, test harness and health route

**Files:**
- Create: `server/package.json`, `server/tsconfig.json`, `server/wrangler.jsonc`, `server/vitest.config.ts`, `server/src/index.ts`, `server/src/env.ts`, `server/src/lib/errors.ts`, `server/migrations/0001_auth.sql`, `server/test/env.d.ts`, `server/test/apply-migrations.ts`, `server/test/health.test.ts`
- Modify: `.gitignore` (add `server/node_modules`, `server/.wrangler`, `server/.dev.vars`)

**Interfaces:**
- Produces: `Env { DB: D1Database; TOKEN_SECRET: string; BOOTSTRAP_SECRET: string; APP_ORIGIN: string }`; `AppVars { userId: string; deviceId: string; isAdmin: boolean }`; `app: Hono<{ Bindings: Env; Variables: AppVars }>` exported as default `{ fetch }`; `class ApiError(status: number, code: string)` plus `onError` mapping to `{error: code}`. Unknown errors become 500 `{error:"internal"}`.

- [ ] **Step 1:** Write `wrangler.jsonc`: name `famchat`, `main: "src/index.ts"`, current `compatibility_date`, `nodejs_compat`, D1 binding `DB` (database_name `famchat`, `migrations_dir: "migrations"`), `vars.APP_ORIGIN = "https://famchat.dev"`, observability enabled. Test config supplies `TOKEN_SECRET`/`BOOTSTRAP_SECRET` through miniflare bindings (`test-token-secret`, `test-bootstrap-secret`).
- [ ] **Step 2:** Write `migrations/0001_auth.sql`:

```sql
CREATE TABLE users (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, is_admin INTEGER NOT NULL DEFAULT 0,
  identity_pub TEXT NOT NULL, created_at INTEGER NOT NULL
);
CREATE TABLE devices (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
  name TEXT NOT NULL, platform TEXT NOT NULL,
  enc_pub TEXT NOT NULL, sign_pub TEXT NOT NULL, cert_sig TEXT NOT NULL,
  refresh_hash TEXT UNIQUE, push_token TEXT,
  created_at INTEGER NOT NULL, last_seen INTEGER NOT NULL, revoked_at INTEGER
);
CREATE INDEX devices_user ON devices(user_id);
CREATE TABLE invites (
  token_hash TEXT PRIMARY KEY, name TEXT NOT NULL, make_admin INTEGER NOT NULL DEFAULT 0,
  created_by TEXT REFERENCES users(id), created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL, used_by TEXT, used_at INTEGER
);
```
Times are Unix milliseconds.
- [ ] **Step 3:** Write `test/health.test.ts`: `GET /api/health` → 200 `{ok:true}`; `GET /api/nope` → 404 `{error:"not_found"}`.
- [ ] **Step 4:** `cd server && npm install` then `npx vitest run` → FAIL (route missing).
- [ ] **Step 5:** Implement `index.ts`, `env.ts` and `errors.ts`. Set `notFound` to return `{error:"not_found"}`.
- [ ] **Step 6:** `npx vitest run` → PASS. `npx tsc --noEmit` → no errors.
- [ ] **Step 7:** Commit `feat(server): scaffold worker, D1 schema and test harness`.

### Task 2: Encoding, IDs, tokens and device-cert verification

**Files:**
- Create: `server/src/lib/{encoding,ids,tokens,devicecert}.ts`, `server/test/lib.test.ts`, `server/test/helpers.ts` (only `makeKeys` for now)

**Interfaces:**
- Produces:
  - `b64urlEncode(bytes: Uint8Array): string`, `b64urlDecode(s: string): Uint8Array` (throws `ApiError(400,'invalid_request')` on bad input)
  - `newId(): string` (ULID)
  - `randomToken(): string` (32 bytes, b64url), `sha256Hex(s: string): Promise<string>`
  - `signAccessToken(env: Env, claims: {sub: string; dev: string; adm: boolean}): Promise<string>` and `verifyAccessToken(env: Env, token: string): Promise<{sub; dev; adm} | null>`
  - `verifyDeviceCert(identityPub: string, encPub: string, signPub: string, certSig: string): Promise<boolean>`: returns false for wrong lengths or a bad signature; never throws
  - test helper `makeKeys(): Promise<{identityPub, encPub, signPub, certSig, identityKeyPair}>`, built with WebCrypto Ed25519 (`encPub` can be any 32 random bytes in tests)

- [ ] **Step 1:** Write `lib.test.ts`:
  - `b64url round-trips` for 0, 1, 31, 32 and 64-byte arrays; output contains no `=`, `+` or `/`
  - `newId is 26 chars and increases over time` (two calls 2 ms apart sort in order)
  - `sha256Hex("abc")` equals `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`
  - `access token round-trips`, `expired token → null` (sign with `exp` in the past via a fake clock or a test-only option), `tampered token → null`
  - `valid cert verifies`, `cert over swapped encPub/signPub fails`, `31-byte key → false`, `garbage base64 → false`
- [ ] **Step 2:** `npx vitest run test/lib.test.ts` → FAIL.
- [ ] **Step 3:** Implement. Use `crypto.getRandomValues`, `crypto.subtle.digest`, `hono/jwt` `sign`/`verify` with `HS256`, and `crypto.subtle.importKey('raw', pub, {name:'Ed25519'}, false, ['verify'])`.
- [ ] **Step 4:** `npx vitest run test/lib.test.ts` → PASS.
- [ ] **Step 5:** Commit `feat(server): token, id and device-cert primitives`.

### Task 3: Admin bootstrap and invite creation

**Files:**
- Create: `server/src/routes/admin.ts`, `server/src/middleware/auth.ts`, `server/test/admin.test.ts`
- Modify: `server/src/index.ts` (mount `/api/admin`)

**Interfaces:**
- Consumes: Task 2 primitives.
- Produces:
  - `requireAuth`: middleware that reads `Authorization: Bearer <access>`, verifies it, **checks in D1 that the device exists and `revoked_at IS NULL`**, then sets `userId`, `deviceId` and `isAdmin`. Otherwise 401.
  - `requireAdmin`: `requireAuth` plus `isAdmin`, otherwise 403.
  - `POST /api/admin/bootstrap` with header `Authorization: Bearer <BOOTSTRAP_SECRET>` and body `{name}` → 201 `{inviteToken, inviteUrl, expiresAt}`. Creates an invite with `make_admin=1`. 401 for a wrong secret (compared in constant time); 409 `already_bootstrapped` if any user exists.
  - `POST /api/admin/invites` (admin) with body `{name}` → 201 `{inviteToken, inviteUrl, expiresAt}` with `make_admin=0`.

- [ ] **Step 1:** Write `admin.test.ts`:
  - `bootstrap creates admin invite`: 201, `inviteUrl === "https://famchat.dev/join#" + inviteToken`, `expiresAt - now` ≈ 7 days (±1 min); the D1 row has `make_admin=1` and stores the hash, not the token
  - `bootstrap wrong secret → 401`, and no row in `invites`
  - `bootstrap after a user exists → 409 already_bootstrapped` (insert a user row directly)
  - `bootstrap name "  " → 400`; `41-char name → 400`
  - `invites requires admin`: no token → 401; non-admin token → 403 (helper `redeemNewDevice` comes in Task 4, so insert rows directly here and sign tokens with `signAccessToken`)
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement the middleware and the routes.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat(server): admin bootstrap and invites`.

### Task 4: Redeem an invite (create user and first device)

**Files:**
- Create: `server/src/routes/auth.ts`, `server/test/auth.test.ts`
- Modify: `server/src/index.ts` (mount `/api/auth`), `server/test/helpers.ts` (add `redeemNewDevice`)

**Interfaces:**
- Produces:
  - `POST /api/auth/invite/redeem` with body `{token, deviceName, platform, identityPub, encPub, signPub, certSig}` → 201 `{userId, deviceId, isAdmin, accessToken, refreshToken}`
  - test helper `redeemNewDevice(opts?: {admin?: boolean; name?: string}): Promise<{userId, deviceId, accessToken, refreshToken, keys}>` (creates its own invite rows)

- [ ] **Step 1:** Write `auth.test.ts` (redeem):
  - `redeem creates user and device`: 201; the user row has `name` from the invite, `identity_pub`; the device row has the keys, `refresh_hash = sha256Hex(refreshToken)`; the invite has `used_by = userId`
  - `admin invite makes admin`: `isAdmin === true` and `users.is_admin = 1`
  - `redeem twice`: a second redeem with the same token → 410 `invite_invalid`, and there's still exactly 1 user. Also send two redeems with `Promise.all` → one 201 and one 410.
  - `expired invite → 410` (insert an invite with `expires_at` in the past)
  - `unknown token → 410`
  - `bad cert does not burn invite`: bad `certSig` → 400; then a valid redeem with the same token → 201
  - `platform "amiga" → 400`; `deviceName "" → 400`
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement. Validate the body and `verifyDeviceCert` **before** touching the invite. Then claim it atomically with `UPDATE invites SET used_by=?, used_at=? WHERE token_hash=? AND used_by IS NULL AND expires_at > ?` and require `meta.changes === 1`, otherwise 410. Then `DB.batch` the inserts for the user and the device. Issue tokens.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat(server): invite redemption`.

### Task 5: Token refresh with rotation

**Files:**
- Modify: `server/src/routes/auth.ts`, `server/test/auth.test.ts`

**Interfaces:**
- Produces: `POST /api/auth/refresh` with body `{refreshToken}` → 200 `{accessToken, refreshToken}`. Rotates the hash and updates `last_seen`. 401 for unknown or revoked tokens.

- [ ] **Step 1:** Add tests:
  - `refresh returns new pair`: the new tokens differ from the old ones; the new access token passes `GET /api/devices` (after Task 6; until then check with `verifyAccessToken`)
  - `old refresh token rejected`: after a refresh, the old token → 401; the newest one still works
  - `refresh on revoked device → 401` (set `revoked_at` directly)
  - `missing body → 400`
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement. Swap the token atomically with `UPDATE devices SET refresh_hash=?new, last_seen=? WHERE refresh_hash=?old AND revoked_at IS NULL RETURNING id, user_id`, then load `is_admin` for the claims.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat(server): refresh token rotation`.

### Task 6: List and revoke devices

**Files:**
- Create: `server/src/routes/devices.ts`, `server/test/devices.test.ts`
- Modify: `server/src/index.ts`

**Interfaces:**
- Produces:
  - `GET /api/devices` → 200 `{devices: [{id, name, platform, createdAt, lastSeen, current}]}` (the caller's own non-revoked devices; `current` is true for the calling device)
  - `DELETE /api/devices/:id` → 204. Sets `revoked_at` and clears `refresh_hash` and `push_token`. Another user's device or an unknown id → 404.

- [ ] **Step 1:** Write `devices.test.ts`:
  - `lists own devices only`: user A with 2 devices (insert the second device directly), user B with 1 → A sees 2, with `current` set on exactly one
  - `revoke other device`: 204, then that device disappears from the list
  - `revoked device access token rejected`: revoke the calling device itself → 204, then `GET /api/devices` with the same access token → 401
  - `revoke another user's device → 404`
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Full suite `npx vitest run` → all PASS; `npx tsc --noEmit` clean.
- [ ] **Step 5:** Write the auth section of `docs/protocol.md`: every endpoint above with its request and response shapes and error codes, plus the device-cert byte layout.
- [ ] **Step 6:** Commit `feat(server): device list and revoke; protocol docs`.

### Task 7: Deploy to famchat.dev (needs the user's go-ahead)

**Files:**
- Modify: `server/wrangler.jsonc` (real `database_id`, route), `server/package.json` (`deploy`, `db:migrate` scripts)

- [ ] **Step 1:** Ask the user before creating Cloudflare resources. Then `npx wrangler d1 create famchat` and paste the id into `wrangler.jsonc`.
- [ ] **Step 2:** Add route `{ "pattern": "famchat.dev/api/*", "zone_name": "famchat.dev" }`.
- [ ] **Step 3:** `npx wrangler d1 migrations apply famchat --remote` → 0001 applied.
- [ ] **Step 4:** Set secrets from random values without printing them: `openssl rand -base64 48 | npx wrangler secret put TOKEN_SECRET`, and the same for `BOOTSTRAP_SECRET` (also save `BOOTSTRAP_SECRET` to 1Password as "FamChat bootstrap secret").
- [ ] **Step 5:** `npx wrangler deploy`, then `curl -s https://famchat.dev/api/health` → `{"ok":true}`.
- [ ] **Step 6:** Commit `chore(server): production config for famchat.dev`.
