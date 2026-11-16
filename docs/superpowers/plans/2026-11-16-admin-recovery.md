# Admin & Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline) with superpowers:test-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An admin resets a family member who lost every device: the member's old devices are signed out at once, a fresh one-time link signs them in with a new identity key on the same account, and every other member's device verifies the admin's signature, shows "Mom's account was reset by Michael" in each shared chat, trusts the new key automatically and re-wraps the history for the new device. Admins can promote a second admin and save a printed admin recovery code that lets its holder recover the admin account without any device. The server keeps every past identity key (as signed reset records) so a device that never saw a user's old key can still verify their older messages.

**Architecture:** Server: migration `0006_admin.sql` (`events` audit table, `resets` table, reset-invite columns on `invites`, `recovery_pub`/`recovery_sig` on `users`); `lib/reset.ts` (signed byte strings, Ed25519 verify); `POST /admin/users/:id/reset` (verifies the admin-signed statement, revokes devices, rotates chats, cancels pairings, makes a reset invite bound to the user, audit row, hub `reset` event); redeem of a reset invite attaches the new identity key and device to the same user if the new device proves it holds the link's claim key; `POST /admin/users/:id/admin`; `POST /admin/recovery-key`; `POST /auth/recover`; `/users` lists each user's `resets`; `/me` gains `recoveryCodeSet`; `requireAdmin` reads the database. Client: `lib/crypto/reset.dart` (statements, claims, recovery code and key); `lib/chat/resets.dart` (pure trust resolution over the directory: verified forward chains are auto-acknowledged, verified backward chains add historical keys, retired keys' devices count as revoked); `Directory.refresh` applies it and records banner-worthy resets in a new `local_resets` table (chat DB schema v2); `ChatSync` handles the `reset` event and re-runs decryption and repair after an automatic acknowledgement; `lib/admin/` (reset/promote/recovery-code service); Family screen, recovery-code screen with a print view, reset banner, join with a reset link, and "Recover admin account" sign-in.

**Tech Stack:** Cloudflare Workers + Hono, D1, vitest 5 + `@cloudflare/vitest-plugin`. Flutter 3.50, Riverpod 3, go_router 18, drift 2.35 (+ build_runner), `cryptography` 2.9. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-15-famchat-design.md` ("Admin recovery (lost every device)", "API surface", "D1 schema", "Testing"). Roadmap row 10. Contract: `docs/protocol.md`.

## Reset protocol (binding for every task)

- Byte strings (`str` = u16be length ‖ UTF-8; keys raw 32 bytes; `u64` = two big-endian u32, high then low):
  - Reset statement: `"famchat-reset-v1" ‖ str(resetId) ‖ str(userId) ‖ str(signerUserId) ‖ str(signerKind) ‖ oldIdentityPub ‖ claimPub ‖ u64(createdAt)`; `signerKind` is `admin` or `recovery`.
  - Claim: `"famchat-reset-claim-v1" ‖ str(resetId) ‖ newIdentityPub`, signed by the claim key.
  - Recovery key registration: `"famchat-recovery-key-v1" ‖ str(userId) ‖ recoveryPub`, signed by the admin's identity key.
  - Recovery key: Ed25519 from seed `HKDF-SHA256(ikm = UTF-8(normalized code), salt = "", info = "famchat-recovery-seed-v1", 32)`.
- **Admin reset:** the admin's device fetches `/users`, makes `resetId` (ULID), a one-time claim key pair and `createdAt`, signs the statement with its identity key and posts it. The server checks the signature against the caller's `identity_pub`, `oldIdentityPub` equals the user's current key, and `|createdAt − now| ≤ 10 min`. The link is `inviteUrl + "." + b64url(claimSeed)`; the seed sits in the URL fragment and never reaches the server. Redeeming it creates a new identity key and posts `resetClaimSig` = claim signature over the new key; the server verifies it against the reset's `claimPub` and attaches the key and device to the same user.
- **Admin recovery code:** 25 Crockford base32 characters (125 bits) shown as `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`, made on the admin's device. Only `recoveryPub` (and the identity key's signature over it) goes to the server, so the server alone can't use the code. `POST /auth/recover` takes a statement of kind `recovery` signed by the recovery key plus the new keys; the server copies `recovery_sig` onto the reset row (so the record stays verifiable) and clears the stored key (single use).
- **Member verification:** a reset counts only if its statement verifies under `signerPub` and either (admin) the signer is another user marked admin whose identity key this device trusts or verified (current or historical), or (recovery) `recoverySig` verifies under `oldIdentityPub`; a completed reset also needs a valid claim signature over `newIdentityPub`. A verified chain from the trusted key to the server's current key is acknowledged automatically (no manual banner) and runs repair; a verified pending reset whose `oldIdentityPub` is the trusted key shows the reset banner. Verified resets ending in a known key add their `oldIdentityPub` as historical (no banner). Devices certified only by a key a verified reset retired are treated as revoked. Unverified changes keep plan 5's manual banner.

## Global Constraints

- Errors stay `{error: code}`; no new codes. `conflict` 409 = stale old identity key or reused reset id.
- Migration number `0006`. Domain strings added to `famchatDomains` (no prefix of another; test enforces).
- `lib/crypto/`, `lib/chat/` (except providers) and `lib/admin/admin_service.dart` stay Flutter-free. No `dart:io` under `lib/`.
- Never log seeds, codes, tokens. Vitest `maxWorkers` ≤ 2; one build/test process at a time.

## Review Focus

1. **Forged reset:** statement signed by a non-admin, by a stale/unknown admin key, or for another user; claim signed by the wrong key → server 400 / client unverified (manual banner stays). Tests: server `reset signature from another key → 400`, `redeem without a valid claim → 400`; client `unverified identity change keeps the manual banner`, `reset signed by a non-admin is not trusted`.
2. **Server swaps the new key after a genuine reset** (redeems with its own key): no valid claim signature → not auto-acknowledged. Client test `completed reset with a bad claim is not acknowledged`.
3. **Reset during traffic:** old devices revoked, sockets closed, chats rotated; the reset user's pending pairings cancelled. Server test `reset revokes devices, rotates chats and cancels pairings`.
4. **History after reset:** members auto-acknowledge on the `device`/`reset` event and wrap past epochs for the new device; a member device created after the reset can verify the user's old messages. Client tests `verified reset is acknowledged and history flows to the new device`, `historical key lets a later device verify old messages`.
5. **Recovery code:** server can't use it (only the public key); single use; lost response retried. Server tests `recover with the code signs in and clears the key`, `recover retry within 10 min reissues tokens`, `recover with an unknown key → 401`.

---

## File Structure

| File | Responsibility |
|---|---|
| `server/migrations/0006_admin.sql` | `events`, `resets`, invite/user columns |
| `server/src/lib/reset.ts` | byte strings, verification, `logEvent` |
| `server/src/routes/admin.ts` | reset, promote, recovery key |
| `server/src/routes/auth.ts` | reset-invite redeem, `/auth/recover` |
| `server/src/routes/users.ts`, `me.ts`, `middleware/auth.ts` | resets in directory, recoveryCodeSet, DB admin check |
| `server/test/reset.test.ts`, `test/recovery.test.ts` | tests |
| `app/lib/crypto/reset.dart` | statements, claims, recovery code/key |
| `app/lib/chat/resets.dart` | pure trust resolution |
| `app/lib/chat/directory.dart`, `wire.dart`, `db/chat_db.dart`, `chat_sync.dart` | apply resets, banner rows, `reset` event |
| `app/lib/admin/admin_service.dart`, `admin_providers.dart` | reset/promote/recovery-code calls |
| `app/lib/session/invite_link.dart`, `session_controller.dart` | reset links, recover sign-in |
| `app/lib/screens/family_screen.dart`, `recovery_code_screen.dart`, `recover_screen.dart` | UI |
| `app/test_e2e/reset_e2e_test.dart` | reset scenario against `wrangler dev` |

---

### Task 1: Server reset, promote, recovery

- [ ] Failing tests (`reset.test.ts`, `recovery.test.ts`): non-admin → 403; self-reset → 400; bad signature → 400; stale old key → 409; stale createdAt → 400; reset revokes devices, rotates chats, cancels pairings, closes sockets, sends `reset`/`device`/`chat` events, writes an `events` row, returns a link; reset invite redeem needs a valid claim (400 otherwise), attaches to the same user (no new user), updates the identity key, completes the reset; lost redeem retried; older reset invite stops working after a newer reset; `/users` lists resets (history kept); promote → admin can create invites at once; recovery key set requires a valid signature; `/me.recoveryCodeSet`; recover signs in, revokes old devices, clears the key, retry reissues tokens, unknown key → 401, used twice → 401.
- [ ] Implement; `npm test && npm run typecheck`. Commit `feat(server): admin reset, second admin, recovery code`.

### Task 2: Client reset crypto

- [ ] Failing tests `test/crypto/reset_test.dart`: statement round-trip and tamper (each field), claim round-trip, recovery code format/parse/normalize, recovery key deterministic per code, registration signature; a fixed vector shared with the server test. Domain test covers the new strings.
- [ ] Implement `lib/crypto/reset.dart`. Commit `feat(app): reset statements and admin recovery code crypto`.

### Task 3: Trust resolution, directory, sync

- [ ] Failing tests `test/chat/resets_test.dart` (pure): forward chain acknowledged; non-admin signer, wrong signer key, bad claim → not; pending reset → banner, no ack; backward history adds old key; retired key; recovery reset verified by registration. `test/chat/chat_sync_test.dart`: `verified reset is acknowledged and history flows to the new device`, `unverified identity change keeps the manual banner`, `historical key lets a later device verify old messages`, `reset event records a banner for shared chats`.
- [ ] Implement `resets.dart`, wire DTOs, `local_resets` (schema v2 + migration), `Directory`, `ChatSync`, `FakeChatBackend.adminReset`. Commit `feat(app): verify admin-signed resets and acknowledge them automatically`.

### Task 4: API, admin service, session

- [ ] Failing tests: `ApiClient` reset/promote/recovery-key/recover/redeem with claim (fake server); invite link with claim seed; `SessionController.join` with a reset link sends the claim; `SessionController.recover`.
- [ ] Implement. Commit `feat(app): admin API, reset links and recovery sign-in`.

### Task 5: Screens

- [ ] Failing widget tests: Family screen lists users, reset with confirmation shows the link, make admin, second-admin and recovery-code prompts; recovery code shown once with copy and print view; reset banner in a conversation (dismiss); recover screen; home prompt for admins.
- [ ] Implement; full `flutter test`, `flutter analyze`. Commit `feat(app): family admin screen, recovery code, reset banners`.

### Task 6: E2E, docs, finish

- [ ] `app/test_e2e/reset_e2e_test.dart` (admin resets Bob, Bob's new device joins with the link, the admin's device auto-acknowledges and Bob reads the history). `docs/protocol.md`, spec API surface.
- [ ] `flutter build web --release` once; final review; merge `origin/main`; push; PR; CI green.
